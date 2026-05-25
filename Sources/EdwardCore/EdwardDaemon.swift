import Foundation
import AudioCommon

/// The main Edward engine — orchestrates audio pipelines, transcription, and storage
public final class EdwardDaemon {
    private let config: EdwardConfig
    private let transcriber: Transcriber
    private let speakerTracker: SpeakerTracker
    private let forcedAligner: ForcedAlignerWrapper
    private let storage: Storage

    private var pipelines: [AudioPipeline] = []
    private var captureStartTime: Date?
    private var isRunning = false
    public let configHash: Int

    // Session recording
    private var sessionRecorder: SessionRecorder?

    // Auto-diarization state
    private var lastSpeechTime: Date?
    private var undiarizedEntryCount: Int = 0
    private var silenceTimer: DispatchSourceTimer?
    private var isDiarizing = false
    private let silenceCheckInterval: TimeInterval = 10
    private let silenceThreshold: TimeInterval = 60

    /// Callback fired on every new transcription (for UI integration)
    public var onTranscription: ((TranscriptEntry) -> Void)?

    /// Callback fired with partial transcription text during speech (nil = speech ended)
    public var onPartialTranscription: ((String?) -> Void)?

    /// Callback fired when word timestamps are ready for an entry
    public var onWordTimestampsReady: ((Int64, [WordTimestamp]) -> Void)?

    /// Callback fired when offline diarization completes
    public var onDiarizationComplete: ((Int, Int) -> Void)?

    /// Callback fired when session finalization completes (diarized transcript + summary)
    public var onSessionComplete: ((SessionResult) -> Void)?

    /// Callback fired immediately when session finalization begins (provides session metadata)
    public var onSessionFinalizing: ((SessionInfo) -> Void)?

    /// Apple Speech parallel transcription callbacks
    public var onAppleSpeechPartial: ((String) -> Void)?
    public var onAppleSpeechTranscription: ((String, Date) -> Void)?
    public var enableAppleSpeech: Bool = false

    private var appleSpeechTranscriber: AppleSpeechTranscriber?

    public init(config: EdwardConfig = .default) {
        self.config = config
        self.configHash = config.configHash
        self.transcriber = Transcriber(config: config)
        self.speakerTracker = SpeakerTracker(config: config)
        self.forcedAligner = ForcedAlignerWrapper()
        self.storage = Storage(config: config)
    }

    /// Initialize all components (loads models, opens database)
    public func initialize() async throws {
        log.configure(logPath: config.logPath)
        log.info("Edward initializing...")

        try config.ensureDirectories()
        try storage.open()

        // Load ASR model
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

        // Build pipelines
        pipelines = []

        if config.enableMicCapture {
            let micSource = AudioCapture(config: config)
            let micPipeline = AudioPipeline(source: micSource, config: config, transcriber: transcriber, storage: storage)
            print("  Loading VAD model (mic)...")
            fflush(stdout)
            try await micPipeline.loadVAD()
            pipelines.append(micPipeline)
        }

        if config.enableSystemAudioCapture {
            for app in config.systemAudioApps where app.enabled {
                let systemSource = SystemAudioSource(bundleId: app.bundleId, label: app.label)
                let pipeline = AudioPipeline(source: systemSource, config: config, transcriber: transcriber, storage: storage)
                print("  Loading VAD model (\(app.label))...")
                fflush(stdout)
                try await pipeline.loadVAD()
                pipelines.append(pipeline)
            }
        }

        // Wire pipeline callbacks
        for pipeline in pipelines {
            pipeline.onTranscription = { [weak self] entry in
                self?.handleTranscription(entry: entry)
            }
            pipeline.onPartialTranscription = { [weak self] text in
                self?.onPartialTranscription?(text)
            }
            pipeline.onPostTranscription = { [weak self] entry, audio in
                self?.handlePostTranscription(entry: entry, audio: audio)
            }
        }

        // Request notification permission
        NotificationManager.shared.requestPermission()

        log.info("Edward initialized with \(pipelines.count) pipeline(s)")
    }

    /// Start the daemon — begins listening on all pipelines
    public func start() throws {
        guard !isRunning else { return }

        captureStartTime = Date()

        // Start session recording
        if config.enableSessionRecording {
            let recorder = SessionRecorder(sampleRate: config.sampleRate)
            try recorder.start(sessionsDir: config.sessionsDir)
            self.sessionRecorder = recorder
            for pipeline in pipelines {
                pipeline.sessionRecorder = recorder
            }
        }

        for pipeline in pipelines {
            do {
                try pipeline.start()
            } catch {
                log.error("Failed to start pipeline \(pipeline.source.sourceId): \(error)")
            }
        }

        // Start Apple Speech parallel transcription if enabled
        if enableAppleSpeech {
            AppleSpeechTranscriber.requestAuthorization { [weak self] authorized in
                guard let self = self, authorized else {
                    log.info("[AppleSpeech] Authorization denied or unavailable")
                    return
                }
                let apple = AppleSpeechTranscriber(sampleRate: self.config.sampleRate)
                apple.onPartialResult = { [weak self] text in
                    self?.onAppleSpeechPartial?(text)
                }
                apple.onFinalResult = { [weak self] text, timestamp in
                    self?.onAppleSpeechTranscription?(text, timestamp)
                }
                apple.start()
                self.appleSpeechTranscriber = apple

                // Feed mic pipeline audio to Apple Speech
                for pipeline in self.pipelines where pipeline.source.sourceId == "mic" {
                    pipeline.onRawSamples = { [weak apple] samples in
                        apple?.feedSamples(samples)
                    }
                }
                log.info("[AppleSpeech] Parallel transcription started")
            }
        }

        startSilenceMonitor()

        isRunning = true
        log.info("Edward daemon started — \(pipelines.count) pipeline(s) listening...")
    }

    /// Stop the daemon — pauses pipelines but keeps resources alive for restart
    public func stop() {
        guard isRunning else { return }

        silenceTimer?.cancel()
        silenceTimer = nil

        // Stop Apple Speech
        appleSpeechTranscriber?.stop()
        appleSpeechTranscriber = nil

        let pipelinesToFlush = pipelines
        let recorder = sessionRecorder
        sessionRecorder = nil
        isRunning = false

        Task {
            // Flush all pipelines and await pending transcriptions
            for pipeline in pipelinesToFlush {
                pipeline.sessionRecorder = nil
                await pipeline.stopAndFlush()
            }

            // Finalize session recording after all transcriptions are saved
            if let sessionInfo = recorder?.stop() {
                self.onSessionFinalizing?(sessionInfo)
                let finalizer = SessionFinalizer(config: self.config)
                do {
                    let result = try await finalizer.finalize(session: sessionInfo, storage: self.storage)
                    self.onSessionComplete?(result)
                } catch {
                    log.error("Session finalization failed: \(error)")
                }
            }
        }

        log.info("Edward daemon stopped")
    }

    /// Fully shut down — releases all resources
    public func shutdown() {
        stop()
        try? speakerTracker.save()
        storage.close()
    }

    /// Whether a session is currently being recorded
    public var hasActiveSession: Bool {
        sessionRecorder != nil
    }

    /// Active source labels
    public var activeSources: [String] {
        pipelines.filter { $0.source.isRunning }.map { $0.source.sourceLabel }
    }

    /// Sources that failed to start, with error messages
    public var failedSources: [(label: String, error: String)] {
        pipelines.compactMap { pipeline in
            if let sys = pipeline.source as? SystemAudioSource, let err = sys.lastError {
                return (label: sys.sourceLabel, error: err)
            }
            return nil
        }
    }

    /// Status info
    public var status: DaemonStatus {
        let uptime = captureStartTime.map { Date().timeIntervalSince($0) } ?? 0
        return DaemonStatus(
            isRunning: isRunning,
            uptime: uptime,
            samplesProcessed: 0
        )
    }

    // MARK: - Pipeline Callbacks

    private func handleTranscription(entry: TranscriptEntry) {
        lastSpeechTime = Date()
        undiarizedEntryCount += 1

        NotificationManager.shared.notify(entry: entry)
        onTranscription?(entry)
    }

    private func handlePostTranscription(entry: TranscriptEntry, audio: [Float]) {
        guard config.enableForcedAlignment else { return }
        let entryId = entry.id
        let entryText = entry.text
        let lang = config.languages.first ?? "English"
        Task {
            if let timestamps = await forcedAligner.align(audio: audio, text: entryText, sampleRate: config.sampleRate, language: lang) {
                try? storage.updateWordTimestamps(id: entryId, timestamps: timestamps)
                onWordTimestampsReady?(entryId, timestamps)
            }
        }
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
        guard !isDiarizing, undiarizedEntryCount >= 2 else { return }
        guard let lastSpeech = lastSpeechTime else { return }
        let silenceDuration = Date().timeIntervalSince(lastSpeech)
        guard silenceDuration >= silenceThreshold else { return }

        isDiarizing = true
        let count = undiarizedEntryCount
        log.info("Auto-diarization triggered after \(Int(silenceDuration))s of silence (\(count) segments)")
        print("\n[Auto-diarizing \(count) segments after \(Int(silenceDuration))s of silence...]")
        fflush(stdout)

        Task {
            do {
                let entries = try storage.entriesWithAudio(date: Date())
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

    public var uptimeString: String {
        let hours = Int(uptime) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        let seconds = Int(uptime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
