import Foundation
import SpeechVAD
import AudioCommon

/// Runs offline speaker diarization on saved audio segments.
/// Concatenates all segments, runs the full DiarizationPipeline,
/// then maps diarized speaker labels back to transcript entries.
public final class OfflineDiarizer {
    private let config: EdwardConfig

    public init(config: EdwardConfig) {
        self.config = config
    }

    /// Run offline diarization on a set of transcript entries that have saved audio.
    /// Updates speaker labels in the database.
    public func diarize(entries: [TranscriptEntry], storage: Storage) async throws -> OfflineDiarizationResult {
        guard !entries.isEmpty else {
            return OfflineDiarizationResult(numSpeakers: 0, entriesUpdated: 0)
        }

        // Limit to prevent hanging on very large batches
        let maxEntries = 30
        let entriesToProcess = entries.count > maxEntries ? Array(entries.suffix(maxEntries)) : entries

        if entries.count > maxEntries {
            print("Limiting diarization to last \(maxEntries) of \(entries.count) segments")
            fflush(stdout)
        }

        print("Loading diarization pipeline (pyannote + WeSpeaker)...")
        fflush(stdout)
        var pipeline: PyannoteDiarizationPipeline? = try await PyannoteDiarizationPipeline.fromPretrained()

        // Load and concatenate all audio segments with gaps between them
        print("Loading \(entriesToProcess.count) audio segments...")
        fflush(stdout)

        var allAudio: [Float] = []
        var segmentMap: [(entryId: Int64, startSample: Int, endSample: Int)] = []

        for entry in entriesToProcess {
            guard let audioPath = entry.audioPath,
                  FileManager.default.fileExists(atPath: audioPath) else {
                continue
            }

            let audio = try Storage.loadAudio(path: audioPath)
            guard !audio.isEmpty else { continue }

            let startSample = allAudio.count
            allAudio.append(contentsOf: audio)

            // Add a small silence gap between segments (0.5s) to help diarization
            let gapSamples = Int(0.5 * Double(config.sampleRate))
            allAudio.append(contentsOf: [Float](repeating: 0, count: gapSamples))

            let endSample = startSample + audio.count
            segmentMap.append((entryId: entry.id, startSample: startSample, endSample: endSample))
        }

        guard !allAudio.isEmpty, !segmentMap.isEmpty else {
            return OfflineDiarizationResult(numSpeakers: 0, entriesUpdated: 0)
        }

        let totalDuration = Double(allAudio.count) / Double(config.sampleRate)
        print("Running diarization on \(String(format: "%.1f", totalDuration))s of audio...")
        fflush(stdout)

        // Run full pipeline with config to get DiarizationResult (not just [DiarizedSegment])
        let diarResult = pipeline!.diarize(audio: allAudio, sampleRate: config.sampleRate, config: DiarizationConfig(clusteringThreshold: 0.6))

        // Release the pipeline immediately to free VRAM
        pipeline = nil

        print("Found \(diarResult.numSpeakers) speakers in \(diarResult.segments.count) diarized segments")
        fflush(stdout)

        // Map diarized segments back to transcript entries
        var updatedCount = 0

        for mapping in segmentMap {
            let entryStartTime = Float(mapping.startSample) / Float(config.sampleRate)
            let entryEndTime = Float(mapping.endSample) / Float(config.sampleRate)

            // Find which diarized speaker has the most overlap with this entry
            var bestSpeaker: (id: Int, overlap: Float)?

            for seg in diarResult.segments {
                let overlapStart = max(seg.startTime, entryStartTime)
                let overlapEnd = min(seg.endTime, entryEndTime)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > 0 {
                    if let current = bestSpeaker {
                        if overlap > current.overlap {
                            bestSpeaker = (id: seg.speakerId, overlap: overlap)
                        }
                    } else {
                        bestSpeaker = (id: seg.speakerId, overlap: overlap)
                    }
                }
            }

            if let speaker = bestSpeaker {
                let speakerId = "speaker_\(speaker.id + 1)"
                let entryDuration = entryEndTime - entryStartTime
                let confidence = entryDuration > 0 ? speaker.overlap / entryDuration : 0

                try storage.updateSpeaker(
                    id: mapping.entryId,
                    speakerId: speakerId,
                    speakerName: nil,
                    confidence: min(confidence, 1.0)
                )
                updatedCount += 1
            }
        }

        print("Updated \(updatedCount) transcript entries with speaker labels")
        fflush(stdout)

        return OfflineDiarizationResult(
            numSpeakers: diarResult.numSpeakers,
            entriesUpdated: updatedCount
        )
    }
}

public struct OfflineDiarizationResult {
    public let numSpeakers: Int
    public let entriesUpdated: Int
}
