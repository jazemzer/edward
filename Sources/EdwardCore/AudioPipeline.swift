import Foundation
import AudioCommon

/// Per-source audio processing pipeline: source → ringBuffer → VAD → transcription
public final class AudioPipeline {
    public let source: AudioSource
    public let ringBuffer: RingBuffer
    private let vadProcessor: VADProcessor
    private let transcriber: Transcriber
    private let storage: Storage
    private let config: EdwardConfig

    private var sampleCounter: Int = 0
    private var partialTimer: DispatchSourceTimer?
    private var speechStartSampleCount: Int = 0
    private var partialGeneration: Int = 0
    private var lastSampleTime: Date?
    private var audioTimeoutTimer: DispatchSourceTimer?
    private let audioTimeoutInterval: TimeInterval = 2.0 // finalize if no audio for 2s
    private var isPartialRunning = false

    /// Callback fired on every new transcription
    public var onTranscription: ((TranscriptEntry) -> Void)?
    /// Callback fired with partial transcription text during speech (nil = cleared)
    public var onPartialTranscription: ((String?) -> Void)?
    /// Callback for post-transcription tasks (alignment, diarization tracking)
    public var onPostTranscription: ((TranscriptEntry, [Float]) -> Void)?

    public init(source: AudioSource, config: EdwardConfig, transcriber: Transcriber, storage: Storage) {
        self.source = source
        self.config = config
        self.transcriber = transcriber
        self.storage = storage
        self.ringBuffer = RingBuffer(capacity: Int(config.ringBufferDuration) * config.sampleRate)
        self.vadProcessor = VADProcessor(config: config)
    }

    /// Load the VAD model
    public func loadVAD() async throws {
        try await vadProcessor.load()
    }

    /// Start the pipeline
    public func start() throws {
        sampleCounter = 0

        vadProcessor.onSpeechStarted = { [weak self] time in
            self?.handleSpeechStarted(time: time)
        }
        vadProcessor.onSpeechEnded = { [weak self] segment in
            self?.handleSpeechEnded(segment: segment)
        }

        try source.start { [weak self] samples in
            guard let self = self else { return }
            self.lastSampleTime = Date()
            self.ringBuffer.write(samples)
            self.vadProcessor.process(samples: samples)
            self.sampleCounter += samples.count
        }

        startAudioTimeoutTimer()

        log.info("Pipeline started: \(source.sourceId)")
    }

    /// Stop the pipeline
    public func stop() {
        partialTimer?.cancel()
        partialTimer = nil
        audioTimeoutTimer?.cancel()
        audioTimeoutTimer = nil
        vadProcessor.flush()
        source.stop()
        log.info("Pipeline stopped: \(source.sourceId)")
    }

    // MARK: - Audio Timeout

    private func startAudioTimeoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard let lastTime = self.lastSampleTime else { return }
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed >= self.audioTimeoutInterval {
                // No audio received for 2s — inject silence to trigger VAD end-of-speech
                let silenceSamples = [Float](repeating: 0, count: self.config.sampleRate) // 1s of silence
                self.ringBuffer.write(silenceSamples)
                self.vadProcessor.process(samples: silenceSamples)
                self.sampleCounter += silenceSamples.count
                self.lastSampleTime = nil // prevent repeated triggers
            }
        }
        timer.resume()
        audioTimeoutTimer = timer
    }

    // MARK: - Speech Handling

    private func handleSpeechStarted(time: Float) {
        speechStartSampleCount = sampleCounter
        partialGeneration += 1
        startPartialTimer()
    }

    private func handleSpeechEnded(segment: AudioCommon.SpeechSegment) {
        let duration = segment.endTime - segment.startTime
        guard Double(duration) >= config.minSpeechDuration else { return }

        partialTimer?.cancel()
        partialTimer = nil
        partialGeneration += 1

        // Cap audio at 30 seconds to prevent ASR model from looping
        let maxDuration = 30.0
        let effectiveDuration = min(Double(duration), maxDuration)
        let sampleCount = Int(effectiveDuration * Double(config.sampleRate))
        let audio = ringBuffer.readLast(sampleCount)
        guard !audio.isEmpty else { return }

        let sourceId = source.sourceId

        Task {
            do {
                var entry = try await transcriber.transcribe(audio: audio, sampleRate: config.sampleRate)

                // Detect and truncate repetition loops
                let trimmed = Self.truncateRepetition(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !trimmed.isEmpty, trimmed.count > 1 else { return }

                entry = TranscriptEntry(
                    id: entry.id, timestamp: entry.timestamp, duration: entry.duration,
                    text: trimmed, processingTime: entry.processingTime,
                    source: sourceId
                )

                let audioPath = try storage.saveAudio(audio, sampleRate: config.sampleRate, timestamp: entry.timestamp)
                entry.audioPath = audioPath

                entry = try storage.save(entry)

                onTranscription?(entry)
                onPostTranscription?(entry, audio)
            } catch {
                log.error("[\(sourceId)] Transcription failed: \(error)")
            }
        }
    }

    // MARK: - Partial Transcription

    private func startPartialTimer() {
        partialTimer?.cancel()
        let interval = config.partialTranscriptionInterval
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        let gen = partialGeneration
        timer.setEventHandler { [weak self] in
            guard let self = self, self.partialGeneration == gen else { return }
            // Skip if previous partial is still running
            guard !self.isPartialRunning else { return }
            let samplesSinceSpeech = self.sampleCounter - self.speechStartSampleCount
            guard samplesSinceSpeech > self.config.sampleRate / 2 else { return }
            // Cap partial audio to last 10 seconds
            let maxPartialSamples = self.config.sampleRate * 10
            let samplesToRead = min(samplesSinceSpeech, maxPartialSamples)
            let audio = self.ringBuffer.readLast(samplesToRead)
            guard !audio.isEmpty else { return }
            self.isPartialRunning = true
            Task {
                defer { self.isPartialRunning = false }
                guard self.partialGeneration == gen else { return }
                if let text = await self.transcriber.transcribePartial(audio: audio, sampleRate: self.config.sampleRate) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, self.partialGeneration == gen else { return }
                    self.onPartialTranscription?(trimmed)
                }
            }
        }
        timer.resume()
        partialTimer = timer
    }

    // MARK: - Repetition Detection

    /// Detects when ASR output gets stuck in a loop and truncates at the first repetition
    static func truncateRepetition(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 10 else { return text }

        // Look for repeating phrases of length 3-8 words
        for phraseLen in 3...min(8, words.count / 3) {
            for start in 0...(words.count - phraseLen * 2) {
                let phrase = words[start..<(start + phraseLen)]
                let next = words[(start + phraseLen)..<min(start + phraseLen * 2, words.count)]
                if Array(phrase) == Array(next) {
                    // Found repetition — keep up to and including the first occurrence
                    let kept = words[0..<(start + phraseLen)]
                    return kept.joined(separator: " ")
                }
            }
        }

        return text
    }
}
