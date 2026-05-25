import Foundation

/// Configuration for the Edward daemon
public struct EdwardConfig: Codable {
    public var sampleRate: Int
    public var vadOnsetThreshold: Float
    public var vadOffsetThreshold: Float
    public var minSpeechDuration: Double
    public var minSilenceDuration: Double
    public var ringBufferDuration: Double
    public var asrModelId: String?
    public var languages: [String]
    public var enableNoiseSupression: Bool
    public var enableForcedAlignment: Bool
    public var partialTranscriptionInterval: Double
    public var enableMicCapture: Bool
    public var enableSystemAudioCapture: Bool
    public var systemAudioApps: [SystemAudioApp]
    public var dataDir: String
    public var socketPath: String
    public var logPath: String

    public static let `default` = EdwardConfig(
        sampleRate: 16000,
        vadOnsetThreshold: 0.5,
        vadOffsetThreshold: 0.3,
        minSpeechDuration: 0.3,
        minSilenceDuration: 0.8,
        ringBufferDuration: 120.0,
        asrModelId: nil,
        languages: ["en"],
        enableNoiseSupression: false,
        enableForcedAlignment: false,
        partialTranscriptionInterval: 1.5,
        enableMicCapture: true,
        enableSystemAudioCapture: true,
        systemAudioApps: SystemAudioApp.defaults,
        dataDir: "~/.edward".expandingTildeInPath,
        socketPath: "~/.edward/edward.sock".expandingTildeInPath,
        logPath: "~/.edward/logs/edward.log".expandingTildeInPath
    )

    public var dbPath: String { "\(dataDir)/edward.db" }
    public var transcriptsDir: String { "\(dataDir)/transcripts" }
    public var audioDir: String { "\(dataDir)/audio" }
    public var logsDir: String { "\(dataDir)/logs" }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [dataDir, transcriptsDir, audioDir, logsDir] {
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }

    public static func load(from path: String? = nil) -> EdwardConfig {
        let configPath = path ?? "~/.edward/config.json".expandingTildeInPath
        guard FileManager.default.fileExists(atPath: configPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONDecoder().decode(EdwardConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    public func save(to path: String? = nil) throws {
        let configPath = path ?? "\(dataDir)/config.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: configPath))
    }
}

extension String {
    var expandingTildeInPath: String {
        if self.hasPrefix("~/") {
            return NSString(string: self).expandingTildeInPath
        }
        return self
    }
}

extension EdwardConfig {
    /// Hash of source-related settings to detect when daemon needs recreation
    public var configHash: Int {
        var hasher = Hasher()
        hasher.combine(enableMicCapture)
        hasher.combine(enableSystemAudioCapture)
        for app in systemAudioApps {
            hasher.combine(app.bundleId)
            hasher.combine(app.enabled)
        }
        for lang in languages.sorted() {
            hasher.combine(lang)
        }
        return hasher.finalize()
    }
}

/// App configuration for system audio capture
public struct SystemAudioApp: Codable {
    public var bundleId: String
    public var label: String
    public var enabled: Bool

    public init(bundleId: String, label: String, enabled: Bool) {
        self.bundleId = bundleId
        self.label = label
        self.enabled = enabled
    }

    public static let defaults: [SystemAudioApp] = [
        SystemAudioApp(bundleId: "us.zoom.xos", label: "Zoom", enabled: true),
        SystemAudioApp(bundleId: "com.google.Chrome", label: "Chrome", enabled: true),
        SystemAudioApp(bundleId: "com.microsoft.teams2", label: "Teams", enabled: false),
    ]
}
