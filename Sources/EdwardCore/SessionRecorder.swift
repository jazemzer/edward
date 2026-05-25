import Foundation

public struct SessionInfo {
    public let path: String
    public let startTime: Date
    public let endTime: Date
    public let totalSamples: Int
    public let sampleRate: Int

    public var duration: Double {
        Double(totalSamples) / Double(sampleRate)
    }
}

public struct SessionRecord: Identifiable, Hashable {
    public let id: Int64
    public let startTime: Date
    public let endTime: Date
    public let duration: Double
    public let audioPath: String
    public let numSpeakers: Int?
    public let transcriptText: String?
    public let summary: String?
    public let modelUsed: String?

    public init(id: Int64, startTime: Date, endTime: Date, duration: Double, audioPath: String, numSpeakers: Int?, transcriptText: String?, summary: String?, modelUsed: String?) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.audioPath = audioPath
        self.numSpeakers = numSpeakers
        self.transcriptText = transcriptText
        self.summary = summary
        self.modelUsed = modelUsed
    }

    public static func == (lhs: SessionRecord, rhs: SessionRecord) -> Bool {
        lhs.id == rhs.id && lhs.audioPath == rhs.audioPath && lhs.summary == rhs.summary
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(audioPath)
    }

    public var durationString: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    public var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: startTime)
    }
}

/// Records all audio from a session into a single continuous file.
/// Thread-safe — multiple pipelines can write concurrently.
public final class SessionRecorder {
    private var fileHandle: FileHandle?
    private(set) public var sessionPath: String?
    private(set) public var startTime: Date?
    private var totalSamples: Int = 0
    private let sampleRate: Int
    private let lock = NSLock()

    public init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    @discardableResult
    public func start(sessionsDir: String) throws -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sessionsDir) {
            try fm.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folderName = formatter.string(from: Date())
        let folderPath = "\(sessionsDir)/\(folderName)"
        try fm.createDirectory(atPath: folderPath, withIntermediateDirectories: true)

        let audioPath = "\(folderPath)/audio.raw"
        fm.createFile(atPath: audioPath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: audioPath)
        sessionPath = folderPath
        startTime = Date()
        totalSamples = 0

        log.info("Session recording started: \(folderPath)")
        return folderPath
    }

    public func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = fileHandle else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        handle.write(data)
        totalSamples += samples.count
    }

    public func stop() -> SessionInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let path = sessionPath, let start = startTime else { return nil }

        fileHandle?.closeFile()
        fileHandle = nil

        let info = SessionInfo(
            path: path,
            startTime: start,
            endTime: Date(),
            totalSamples: totalSamples,
            sampleRate: sampleRate
        )

        log.info("Session recording stopped: \(String(format: "%.1f", info.duration))s, \(totalSamples) samples")

        sessionPath = nil
        startTime = nil
        totalSamples = 0

        return info
    }
}
