import Foundation
import AudioCommon

/// The main Edward daemon — orchestrates audio capture, VAD, transcription, and output
public final class EdwardDaemon {
    private let config: EdwardConfig
    private let ringBuffer: RingBuffer
    private let audioCapture: AudioCapture
    private let vadProcessor: VADProcessor
    private let transcriber: Transcriber
    private let speakerTracker: SpeakerTracker
    private let forcedAligner: ForcedAlignerWrapper
    private let storage: Storage
    private let socketServer: SocketServer

    private var sampleCounter: Int = 0
    private var captureStartTime: Date?
    private var isRunning = false

    // Partial transcription state
    private var partialTimer: DispatchSourceTimer?
    private var speechStartSampleCount: Int = 0
    private var partialGeneration: Int = 0

    // Auto-diarization state
    private var lastSpeechTime: Date?
    private var undiarizedEntryCount: Int = 0
    private var silenceTimer: DispatchSourceTimer?
    private var isDiarizing = false
    private let silenceCheckInterval: TimeInterval = 10 // check every 10s
    private let silenceThreshold: TimeInterval = 60     // 1 minute of silence triggers diarization

    /// Callback fired on every new transcription (for UI integration)
    public var onTranscription: ((TranscriptEntry) -> Void)?

    /// Callback fired with partial transcription text during speech (nil = speech ended)
    public var onPartialTranscription: ((String?) -> Void)?

    /// Callback fired when word timestamps are ready for an entry
    public var onWordTimestampsReady: ((Int64, [WordTimestamp]) -> Void)?

    /// Callback fired when offline diarization completes
    public var onDiarizationComplete: ((Int, Int) -> Void)? // (numSpeakers, entriesUpdated)

    public init(config: EdwardConfig = .default) {
        self.config = config
        self.ringBuffer = RingBuffer(capacity: Int(config.ringBufferDuration) * config.sampleRate)
        self.audioCapture = AudioCapture(config: config, ringBuffer: ringBuffer)
        self.vadProcessor = VADProcessor(config: config)
        self.transcriber = Transcriber(config: config)
        self.speakerTracker = SpeakerTracker(config: config)
        self.forcedAligner = ForcedAlignerWrapper()
        self.storage = Storage(config: config)
        self.socketServer = SocketServer(socketPath: config.socketPath)
    }

    /// Initialize all components (loads models, opens database)
    public func initialize() async throws {
        log.configure(logPath: config.logPath)
        log.info("Edward initializing...")

        try config.ensureDirectories()
        try storage.open()

        // Load models sequentially for better error reporting
        print("  Loading VAD model...")
        fflush(stdout)
        try await vadProcessor.load()

        print("  Loading ASR model (this may download ~680MB on first run)...")
        fflush(stdout)
        try await transcriber.load()

        print("  Loading speaker embedding model (~25MB)...")
        fflush(stdout)
        try await speakerTracker.load()
        speakerTracker.loadProfiles()

        if config.enableForcedAlignment {
            print("  Loading forced aligner model (~600MB on first run)...")
            fflush(stdout)
            try await forcedAligner.load()
        }

        // Set up VAD callbacks
        vadProcessor.onSpeechStarted = { [weak self] time in
            self?.handleSpeechStarted(time: time)
        }
        vadProcessor.onSpeechEnded = { [weak self] segment in
            self?.handleSpeechEnded(segment: segment)
        }

        // Start socket server
        try socketServer.start()

        // Request notification permission
        NotificationManager.shared.requestPermission()

        log.info("Edward initialized")
    }

    /// Start the daemon — begins listening
    public func start() throws {
        guard !isRunning else { return }

        captureStartTime = Date()
        sampleCounter = 0

        try audioCapture.start { [weak self] samples in
            self?.vadProcessor.process(samples: samples)
            self?.sampleCounter += samples.count
        }

        // Start silence monitoring timer
        startSilenceMonitor()

        isRunning = true
        log.info("Edward daemon started — listening...")
    }

    /// Stop the daemon.
    public func stop() {
        guard isRunning else { return }

        silenceTimer?.cancel()
        silenceTimer = nil
        partialTimer?.cancel()
        partialTimer = nil
        vadProcessor.flush()
        audioCapture.stop()

        socketServer.stop()
        try? speakerTracker.save()
        storage.close()

        isRunning = false
        log.info("Edward daemon stopped")
    }

    /// Status info
    public var status: DaemonStatus {
        let uptime = captureStartTime.map { Date().timeIntervalSince($0) } ?? 0
        return DaemonStatus(
            isRunning: isRunning,
            uptime: uptime,
            samplesProcessed: sampleCounter,
            connectedClients: socketServer.clientCount
        )
    }

    // MARK: - Private

    private func handleSpeechStarted(time: Float) {
        lastSpeechTime = Date()
        speechStartSampleCount = sampleCounter
        partialGeneration += 1
        startPartialTimer()
    }

    private func handleSpeechEnded(segment: AudioCommon.SpeechSegment) {
        let duration = segment.endTime - segment.startTime
        guard Double(duration) >= config.minSpeechDuration else { return }

        lastSpeechTime = Date()
        partialTimer?.cancel()
        partialTimer = nil
        partialGeneration += 1

        // Extract audio from ring buffer
        let sampleCount = Int(Double(duration) * Double(config.sampleRate))
        let audio = ringBuffer.readLast(sampleCount)
        guard !audio.isEmpty else { return }

        // Transcribe asynchronously (speaker labeling done offline)
        Task {
            do {
                var entry = try await transcriber.transcribe(audio: audio, sampleRate: config.sampleRate)

                // Skip empty or very short transcriptions
                let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count > 1 else { return }

                // Save audio segment for offline diarization
                let audioPath = try storage.saveAudio(audio, sampleRate: config.sampleRate, timestamp: entry.timestamp)
                entry.audioPath = audioPath

                // Save to storage
                entry = try storage.save(entry)
                undiarizedEntryCount += 1

                // Broadcast to socket clients
                socketServer.broadcast(entry)

                // Send notification
                NotificationManager.shared.notify(entry: entry)

                // Fire callback for UI
                onTranscription?(entry)

                // Run forced alignment if enabled
                if config.enableForcedAlignment {
                    let entryId = entry.id
                    let entryText = entry.text
                    let lang = config.languages.first ?? "English"
                    Task {
                        if let timestamps = await self.forcedAligner.align(audio: audio, text: entryText, sampleRate: self.config.sampleRate, language: lang) {
                            try? self.storage.updateWordTimestamps(id: entryId, timestamps: timestamps)
                            self.onWordTimestampsReady?(entryId, timestamps)
                        }
                    }
                }
            } catch {
                log.error("Transcription failed: \(error)")
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
            let samplesSinceSpeech = self.sampleCounter - self.speechStartSampleCount
            guard samplesSinceSpeech > self.config.sampleRate / 2 else { return } // at least 0.5s
            let audio = self.ringBuffer.readLast(samplesSinceSpeech)
            guard !audio.isEmpty else { return }
            Task {
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

    // MARK: - Auto Diarization

    private func startSilenceMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + silenceCheckInterval, repeating: silenceCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.checkSilenceAndDiarize()
        }
        timer.resume()
        silenceTimer = timer
    }

    private func checkSilenceAndDiarize() {
        // Don't run if already diarizing or no undiarized entries
        guard !isDiarizing, undiarizedEntryCount >= 2 else { return }

        // Check if we've had enough silence
        guard let lastSpeech = lastSpeechTime else { return }
        let silenceDuration = Date().timeIntervalSince(lastSpeech)

        guard silenceDuration >= silenceThreshold else { return }

        // Trigger offline diarization
        isDiarizing = true
        let count = undiarizedEntryCount
        log.info("Auto-diarization triggered after \(Int(silenceDuration))s of silence (\(count) segments)")
        print("\n[Auto-diarizing \(count) segments after \(Int(silenceDuration))s of silence...]")
        fflush(stdout)

        Task {
            do {
                let entries = try storage.entriesWithAudio(date: Date())
                // Only diarize entries that don't have speaker labels yet
                let unlabeled = entries.filter { $0.speakerId == nil }

                guard !unlabeled.isEmpty else {
                    isDiarizing = false
                    undiarizedEntryCount = 0
                    return
                }

                let diarizer = OfflineDiarizer(config: config)
                let result = try await diarizer.diarize(entries: unlabeled, storage: storage)

                undiarizedEntryCount = 0
                isDiarizing = false

                print("[Diarization complete: \(result.numSpeakers) speakers, \(result.entriesUpdated) entries updated]")
                fflush(stdout)

                onDiarizationComplete?(result.numSpeakers, result.entriesUpdated)

                log.info("Auto-diarization complete: \(result.numSpeakers) speakers, \(result.entriesUpdated) entries")
            } catch {
                isDiarizing = false
                log.error("Auto-diarization failed: \(error)")
            }
        }
    }
}

public struct DaemonStatus: Codable {
    public let isRunning: Bool
    public let uptime: Double
    public let samplesProcessed: Int
    public let connectedClients: Int

    public var uptimeString: String {
        let hours = Int(uptime) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        let seconds = Int(uptime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
