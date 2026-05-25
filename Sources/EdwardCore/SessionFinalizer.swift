import Foundation
import SpeechVAD
import AudioCommon

public struct SessionResult {
    public let sessionId: Int64
    public let duration: Double
    public let numSpeakers: Int
    public let diarizedTranscript: String
    public let summary: String?
    public let audioPath: String
}

/// Orchestrates end-of-session processing: diarization on full audio + LLM summary.
public final class SessionFinalizer {
    private let config: EdwardConfig

    public init(config: EdwardConfig) {
        self.config = config
    }

    /// Re-transcribe a session from its raw audio file.
    /// Uses offline VAD (relaxed settings) → ASR → diarization → replaces stored entries.
    public func retranscribe(session: SessionRecord, storage: Storage) async throws -> SessionResult {
        log.info("Retranscribing session \(session.id) (\(String(format: "%.1f", session.duration))s)")

        // 1. Load full session audio
        let audio = try Storage.loadAudio(path: session.audioPath)
        guard !audio.isEmpty else {
            throw EdwardError.storageError("Session audio file is empty")
        }

        // 2. Run offline VAD with relaxed settings for fewer, longer segments
        let vad = try await SileroVADModel.fromPretrained()
        var offlineVadConfig = VADConfig.sileroDefault
        offlineVadConfig.onset = 0.5
        offlineVadConfig.offset = 0.3
        offlineVadConfig.minSpeechDuration = 0.5
        offlineVadConfig.minSilenceDuration = 1.5
        let speechSegments = vad.detectSpeech(audio: audio, sampleRate: config.sampleRate, config: offlineVadConfig)

        log.info("Offline VAD found \(speechSegments.count) segments")

        // 3. Transcribe each segment
        let transcriber = Transcriber(config: config)
        try await transcriber.load()

        struct SegmentResult {
            let startTime: Float
            let endTime: Float
            let text: String
            let audio: [Float]
        }

        var segmentResults: [SegmentResult] = []
        for seg in speechSegments {
            let startSample = Int(seg.startTime * Float(config.sampleRate))
            let endSample = min(Int(seg.endTime * Float(config.sampleRate)), audio.count)
            guard endSample > startSample else { continue }
            let segAudio = Array(audio[startSample..<endSample])

            let entry = try await transcriber.transcribe(audio: segAudio, sampleRate: config.sampleRate)
            let trimmed = AudioPipeline.truncateRepetition(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !trimmed.isEmpty, trimmed.count > 1 else { continue }

            segmentResults.append(SegmentResult(
                startTime: seg.startTime,
                endTime: seg.endTime,
                text: trimmed,
                audio: segAudio
            ))
        }

        // 4. Run diarization on full audio
        var pipeline: PyannoteDiarizationPipeline? = try await PyannoteDiarizationPipeline.fromPretrained()
        let diarConfig = DiarizationConfig(clusteringThreshold: 0.6)
        let diarResult = pipeline!.diarize(audio: audio, sampleRate: config.sampleRate, config: diarConfig)
        pipeline = nil

        log.info("Diarization: \(diarResult.numSpeakers) speakers, \(diarResult.segments.count) segments")

        // 5. Delete old transcript entries for this session
        try storage.deleteEntriesBetween(start: session.startTime, end: session.endTime)

        // 6. Assign speaker labels to each segment
        struct LabeledSegment {
            let startTime: Float
            let endTime: Float
            let text: String
            let audio: [Float]
            let speakerId: String?
            let confidence: Float?
        }

        var labeledSegments: [LabeledSegment] = []
        for result in segmentResults {
            var bestSpeaker: (id: Int, overlap: Float)?
            for diarSeg in diarResult.segments {
                let overlapStart = max(diarSeg.startTime, result.startTime)
                let overlapEnd = min(diarSeg.endTime, result.endTime)
                let overlap = max(0, overlapEnd - overlapStart)
                if overlap > 0 {
                    if let current = bestSpeaker {
                        if overlap > current.overlap { bestSpeaker = (id: diarSeg.speakerId, overlap: overlap) }
                    } else {
                        bestSpeaker = (id: diarSeg.speakerId, overlap: overlap)
                    }
                }
            }

            let speakerId = bestSpeaker.map { "speaker_\($0.id + 1)" }
            let segDuration = result.endTime - result.startTime
            let confidence = bestSpeaker.map { segDuration > 0 ? min($0.overlap / segDuration, 1.0) : Float(0) }

            labeledSegments.append(LabeledSegment(
                startTime: result.startTime,
                endTime: result.endTime,
                text: result.text,
                audio: result.audio,
                speakerId: speakerId,
                confidence: confidence
            ))
        }

        // 7. Merge consecutive segments from the same speaker
        struct MergedSegment {
            var startTime: Float
            var endTime: Float
            var text: String
            var audio: [Float]
            var speakerId: String?
            var confidence: Float?
        }

        var merged: [MergedSegment] = []
        for seg in labeledSegments {
            if let last = merged.last, last.speakerId == seg.speakerId, last.speakerId != nil {
                merged[merged.count - 1].endTime = seg.endTime
                merged[merged.count - 1].text += " " + seg.text
                merged[merged.count - 1].audio += seg.audio
                if let lastConf = merged[merged.count - 1].confidence, let segConf = seg.confidence {
                    merged[merged.count - 1].confidence = min(lastConf, segConf)
                }
            } else {
                merged.append(MergedSegment(
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: seg.text,
                    audio: seg.audio,
                    speakerId: seg.speakerId,
                    confidence: seg.confidence
                ))
            }
        }

        log.info("Merged \(labeledSegments.count) segments into \(merged.count) entries")

        // 8. Save merged entries
        for seg in merged {
            let timestamp = session.startTime.addingTimeInterval(Double(seg.startTime))
            let segDuration = Double(seg.endTime - seg.startTime)

            var entry = TranscriptEntry(
                id: 0,
                timestamp: timestamp,
                duration: segDuration,
                text: seg.text,
                processingTime: 0,
                speakerId: seg.speakerId,
                speakerName: nil,
                speakerConfidence: seg.confidence
            )

            let audioPath = try storage.saveAudio(seg.audio, sampleRate: config.sampleRate, timestamp: timestamp)
            entry.audioPath = audioPath
            try storage.save(entry)
        }

        // 9. Build diarized transcript and update session
        let updatedEntries = try storage.entriesBetween(start: session.startTime, end: session.endTime)
        let diarizedTranscript = formatDiarizedTranscript(entries: updatedEntries, sessionStart: session.startTime)
        try storage.updateSessionTranscript(id: session.id, transcriptText: diarizedTranscript, numSpeakers: diarResult.numSpeakers)

        // 10. Write session folder files
        let sessionDir = session.audioPath
        let segments = buildTranscriptSegments(entries: updatedEntries, sessionStart: session.startTime)
        let transcriptDoc = TranscriptDocument(
            startTime: session.startTime,
            duration: session.duration,
            numSpeakers: diarResult.numSpeakers,
            segments: segments
        )
        try? Storage.saveTranscriptJSON(sessionDir: sessionDir, document: transcriptDoc)
        try? Storage.saveTranscriptText(sessionDir: sessionDir, text: diarizedTranscript)

        log.info("Retranscription complete: \(merged.count) entries, \(diarResult.numSpeakers) speakers")

        return SessionResult(
            sessionId: session.id,
            duration: session.duration,
            numSpeakers: diarResult.numSpeakers,
            diarizedTranscript: diarizedTranscript,
            summary: session.summary,
            audioPath: session.audioPath
        )
    }

    public func finalize(session: SessionInfo, storage: Storage) async throws -> SessionResult {
        log.info("Session finalization started (\(String(format: "%.1f", session.duration))s of audio)")
        print("[Finalizing session: \(String(format: "%.1f", session.duration))s of audio...]")
        fflush(stdout)

        // 1. Load full session audio
        let audio = try Storage.loadAudio(path: session.path)
        guard !audio.isEmpty else {
            throw EdwardError.storageError("Session audio file is empty")
        }

        // 2. Run diarization on the full continuous audio
        print("[Loading diarization pipeline...]")
        fflush(stdout)
        var pipeline: PyannoteDiarizationPipeline? = try await PyannoteDiarizationPipeline.fromPretrained()

        print("[Running diarization on full session audio...]")
        fflush(stdout)
        let diarResult = pipeline!.diarize(audio: audio, sampleRate: config.sampleRate, config: DiarizationConfig(clusteringThreshold: 0.6))
        pipeline = nil // free VRAM

        print("[Diarization complete: \(diarResult.numSpeakers) speakers, \(diarResult.segments.count) segments]")
        fflush(stdout)

        // 3. Get transcript entries from this session's time range
        let entries = try storage.entriesBetween(start: session.startTime, end: session.endTime)

        // 4. Map diarization speaker labels onto transcript entries
        for entry in entries {
            let entryStartOffset = entry.timestamp.timeIntervalSince(session.startTime)
            let entryEndOffset = entryStartOffset + entry.duration
            let entryStartSample = Int(entryStartOffset * Double(config.sampleRate))
            let entryEndSample = Int(entryEndOffset * Double(config.sampleRate))

            var bestSpeaker: (id: Int, overlap: Float)?
            for seg in diarResult.segments {
                let segStartSample = Int(seg.startTime * Float(config.sampleRate))
                let segEndSample = Int(seg.endTime * Float(config.sampleRate))
                let overlapStart = max(segStartSample, entryStartSample)
                let overlapEnd = min(segEndSample, entryEndSample)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > 0 {
                    if let current = bestSpeaker {
                        if overlap > Int(current.overlap) {
                            bestSpeaker = (id: seg.speakerId, overlap: Float(overlap))
                        }
                    } else {
                        bestSpeaker = (id: seg.speakerId, overlap: Float(overlap))
                    }
                }
            }

            if let speaker = bestSpeaker {
                let speakerId = "speaker_\(speaker.id + 1)"
                let entryDuration = Float(entryEndSample - entryStartSample)
                let confidence = entryDuration > 0 ? speaker.overlap / entryDuration : 0
                try storage.updateSpeaker(
                    id: entry.id,
                    speakerId: speakerId,
                    speakerName: nil,
                    confidence: min(confidence, 1.0)
                )
            }
        }

        // 5. Build diarized transcript text
        let updatedEntries = try storage.entriesBetween(start: session.startTime, end: session.endTime)
        let diarizedTranscript = formatDiarizedTranscript(entries: updatedEntries, sessionStart: session.startTime)

        // 6. Generate summary via Ollama
        var summary: String?
        let ollama = OllamaClient(model: config.ollamaModel, baseURL: config.ollamaBaseURL)
        if await ollama.isAvailable() {
            print("[Generating summary via Ollama (\(config.ollamaModel))...]")
            fflush(stdout)
            summary = try? await generateSummary(transcript: diarizedTranscript, ollama: ollama)
        } else {
            print("[Ollama not available — skipping summary generation]")
            fflush(stdout)
            log.info("Ollama not available at \(config.ollamaBaseURL), skipping summary")
        }

        // 7. Save session record
        let sessionId = try storage.saveSession(
            startTime: session.startTime,
            endTime: session.endTime,
            duration: session.duration,
            audioPath: session.path,
            numSpeakers: diarResult.numSpeakers,
            transcriptText: diarizedTranscript,
            summary: summary,
            modelUsed: summary != nil ? config.ollamaModel : nil
        )

        // 8. Write session folder files
        let sessionDir = session.path
        let segments = buildTranscriptSegments(entries: updatedEntries, sessionStart: session.startTime)
        let transcriptDoc = TranscriptDocument(
            startTime: session.startTime,
            duration: session.duration,
            numSpeakers: diarResult.numSpeakers,
            segments: segments
        )
        try? Storage.saveTranscriptJSON(sessionDir: sessionDir, document: transcriptDoc)
        try? Storage.saveTranscriptText(sessionDir: sessionDir, text: diarizedTranscript)
        if let summary = summary {
            try? Storage.saveSummary(sessionDir: sessionDir, summary: summary)
        }
        let metadata = SessionMetadata(
            startTime: session.startTime,
            endTime: session.endTime,
            duration: session.duration,
            numSpeakers: diarResult.numSpeakers,
            modelUsed: summary != nil ? config.ollamaModel : nil
        )
        try? Storage.saveMetadata(sessionDir: sessionDir, metadata: metadata)

        print("[Session finalization complete]")
        fflush(stdout)
        log.info("Session finalized: \(diarResult.numSpeakers) speakers, session ID \(sessionId)")

        return SessionResult(
            sessionId: sessionId,
            duration: session.duration,
            numSpeakers: diarResult.numSpeakers,
            diarizedTranscript: diarizedTranscript,
            summary: summary,
            audioPath: session.path
        )
    }

    private func formatDiarizedTranscript(entries: [TranscriptEntry], sessionStart: Date) -> String {
        struct Line {
            var offset: TimeInterval
            var speaker: String
            var text: String
        }

        // Merge consecutive entries from the same speaker
        var lines: [Line] = []
        for entry in entries {
            let offset = entry.timestamp.timeIntervalSince(sessionStart)
            let speaker = entry.speakerLabel
            if let last = lines.last, last.speaker == speaker {
                lines[lines.count - 1].text += " " + entry.text
            } else {
                lines.append(Line(offset: offset, speaker: speaker, text: entry.text))
            }
        }

        return lines.map { line in
            let hours = Int(line.offset) / 3600
            let minutes = (Int(line.offset) % 3600) / 60
            let seconds = Int(line.offset) % 60
            let timeStr = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            return "[\(timeStr)] \(line.speaker): \(line.text)"
        }.joined(separator: "\n")
    }

    private func generateSummary(transcript: String, ollama: OllamaClient) async throws -> String {
        let systemPrompt = """
        You are a meeting summarizer. Given a diarized transcript of a conversation, produce a concise summary that captures:
        1. Key topics discussed
        2. Decisions made
        3. Action items (if any)
        4. Key points per speaker (if distinguishable)
        Keep the summary concise but informative.
        """

        let prompt = """
        Summarize the following conversation transcript:

        \(transcript)
        """

        return try await ollama.generate(prompt: prompt, system: systemPrompt)
    }

    private func buildTranscriptSegments(entries: [TranscriptEntry], sessionStart: Date) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for entry in entries {
            let startOffset = entry.timestamp.timeIntervalSince(sessionStart)
            let endOffset = startOffset + entry.duration
            let speaker = entry.speakerLabel
            if let last = segments.last, last.speaker == speaker {
                segments[segments.count - 1] = TranscriptSegment(
                    speaker: speaker,
                    start: last.start,
                    end: endOffset,
                    text: last.text + " " + entry.text
                )
            } else {
                segments.append(TranscriptSegment(
                    speaker: speaker,
                    start: startOffset,
                    end: endOffset,
                    text: entry.text
                ))
            }
        }
        return segments
    }
}
