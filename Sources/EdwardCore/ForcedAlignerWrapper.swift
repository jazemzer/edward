import Foundation
@preconcurrency import Qwen3ASR

/// Wraps Qwen3ForcedAligner for word-level timestamp alignment
public final class ForcedAlignerWrapper {
    private var model: Qwen3ForcedAligner?
    private let queue = DispatchQueue(label: "com.edward.aligner", qos: .utility)
    private var isLoaded = false

    /// Load the forced aligner model (downloads ~600MB on first run)
    public func load() async throws {
        guard !isLoaded else { return }
        log.info("Loading ForcedAligner model...")
        model = try await Qwen3ForcedAligner.fromPretrained()
        isLoaded = true
        log.info("ForcedAligner loaded")
    }

    /// Align transcribed text to audio, returning word-level timestamps
    public func align(audio: [Float], text: String, sampleRate: Int = 16000, language: String = "English") async -> [WordTimestamp]? {
        guard let model = model else { return nil }

        let aligned = await withCheckedContinuation { continuation in
            queue.async {
                let result = model.align(audio: audio, text: text, sampleRate: sampleRate, language: language)
                continuation.resume(returning: result)
            }
        }

        guard !aligned.isEmpty else { return nil }
        return aligned.map { WordTimestamp(text: $0.text, startTime: $0.startTime, endTime: $0.endTime) }
    }
}
