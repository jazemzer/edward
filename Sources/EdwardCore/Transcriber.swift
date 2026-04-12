import Foundation
@preconcurrency import Qwen3ASR
import AudioCommon

/// Transcribes audio segments using Qwen3-ASR
public final class Transcriber {
    private var model: Qwen3ASRModel?
    private let config: EdwardConfig
    private let queue = DispatchQueue(label: "com.edward.transcriber", qos: .userInitiated)

    public init(config: EdwardConfig) {
        self.config = config
    }

    /// Load the ASR model (downloads ~680MB on first run)
    public func load() async throws {
        log.info("Loading Qwen3-ASR model...")
        if let modelId = config.asrModelId {
            model = try await Qwen3ASRModel.fromPretrained(modelId: modelId)
        } else {
            model = try await Qwen3ASRModel.fromPretrained()
        }
        log.info("Qwen3-ASR loaded")
    }

    /// Transcribe an audio segment asynchronously
    /// Uses the configured language hint(s) — pass nil to auto-detect
    public func transcribe(audio: [Float], sampleRate: Int = 16000, language: String? = nil) async throws -> TranscriptEntry {
        guard let model = model else {
            throw EdwardError.modelLoadError("ASR model not loaded")
        }

        let startTime = Date()

        // Use explicit language or first configured language, nil = auto-detect
        let langHint = language ?? config.languages.first

        // Run transcription on dedicated queue
        let text = await withCheckedContinuation { continuation in
            queue.async {
                let result = model.transcribe(audio: audio, sampleRate: sampleRate, language: langHint)
                continuation.resume(returning: result)
            }
        }

        let duration = Double(audio.count) / Double(sampleRate)
        let processingTime = Date().timeIntervalSince(startTime)

        log.info("Transcribed \(String(format: "%.1f", duration))s audio in \(String(format: "%.2f", processingTime))s: \(text)")

        return TranscriptEntry(
            id: 0, // assigned by storage
            timestamp: startTime,
            duration: duration,
            text: text,
            processingTime: processingTime
        )
    }

    /// Transcribe partial audio during speech (returns just the text, no metadata)
    public func transcribePartial(audio: [Float], sampleRate: Int = 16000) async -> String? {
        guard let model = model else { return nil }
        let langHint = config.languages.first
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = model.transcribe(audio: audio, sampleRate: sampleRate, language: langHint)
                continuation.resume(returning: result)
            }
        }
    }
}

/// Word-level timestamp from forced alignment
public struct WordTimestamp: Codable, Sendable {
    public let text: String
    public let startTime: Float
    public let endTime: Float

    public init(text: String, startTime: Float, endTime: Float) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A single transcript entry
public struct TranscriptEntry: Codable, Sendable {
    public var id: Int64
    public let timestamp: Date
    public let duration: Double
    public let text: String
    public let processingTime: Double
    public var speakerId: String?
    public var speakerName: String?
    public var speakerConfidence: Float?
    public var audioPath: String?
    public var wordTimestamps: [WordTimestamp]?

    public var timestampString: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: timestamp)
    }

    public var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    public var speakerLabel: String {
        speakerName ?? speakerId ?? "?"
    }

    /// JSON representation for socket streaming
    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }
}
