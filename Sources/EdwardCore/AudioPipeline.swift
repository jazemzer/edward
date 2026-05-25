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

    /// Accumulates audio samples from the moment speech starts, so no data is lost
    private var speechBuffer: [Float] = []
    private var isSpeechActive = false

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
            if self.isSpeechActive {
                self.speechBuffer.append(contentsOf: samples)
            }
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
        partialGeneration += 1
        audioTimeoutTimer?.cancel()
        audioTimeoutTimer = nil
        isSpeechActive = false
        speechBuffer = []
        vadProcessor.flush()
        source.stop()
        onPartialTranscription?(nil)
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
        speechBuffer = []
        isSpeechActive = true
        partialGeneration += 1
        startPartialTimer()
    }

    private func handleSpeechEnded(segment: AudioCommon.SpeechSegment) {
        let duration = segment.endTime - segment.startTime
        guard Double(duration) >= config.minSpeechDuration else {
            isSpeechActive = false
            speechBuffer = []
            return
        }

        partialTimer?.cancel()
        partialTimer = nil
        partialGeneration += 1
        isSpeechActive = false

        // Use the dedicated speech buffer — contains all audio since speech started
        let fullAudio = speechBuffer
        speechBuffer = []
        guard !fullAudio.isEmpty else { return }

        let sourceId = source.sourceId
        let maxChunkSamples = 30 * config.sampleRate // 30s chunks to avoid ASR loops

        // Split into chunks if longer than 30s
        var chunks: [[Float]] = []
        var offset = 0
        while offset < fullAudio.count {
            let end = min(offset + maxChunkSamples, fullAudio.count)
            chunks.append(Array(fullAudio[offset..<end]))
            offset = end
        }

        Task {
            for chunk in chunks {
                do {
                    var entry = try await transcriber.transcribe(audio: chunk, sampleRate: config.sampleRate)

                    let trimmed = Self.truncateRepetition(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    guard !trimmed.isEmpty, trimmed.count > 1 else { continue }

                    entry = TranscriptEntry(
                        id: entry.id, timestamp: entry.timestamp, duration: entry.duration,
                        text: trimmed, processingTime: entry.processingTime,
                        source: sourceId
                    )

                    let audioPath = try storage.saveAudio(chunk, sampleRate: config.sampleRate, timestamp: entry.timestamp)
                    entry.audioPath = audioPath

                    entry = try storage.save(entry)

                    onTranscription?(entry)
                    onPostTranscription?(entry, chunk)
                } catch {
                    log.error("[\(sourceId)] Transcription failed: \(error)")
                }
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
            guard self.speechBuffer.count > self.config.sampleRate / 2 else { return }
            // Use the tail of the speech buffer for partials (last 10s max)
            let maxPartialSamples = self.config.sampleRate * 10
            let startIdx = max(0, self.speechBuffer.count - maxPartialSamples)
            let audio = Array(self.speechBuffer[startIdx...])
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
