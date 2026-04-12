import Foundation
import SpeechVAD
import AudioCommon

/// Wraps Silero VAD + StreamingVADProcessor for continuous speech detection
public final class VADProcessor {
    private var model: SileroVADModel?
    private var processor: StreamingVADProcessor?
    private let config: EdwardConfig

    public var onSpeechStarted: ((Float) -> Void)?
    public var onSpeechEnded: ((AudioCommon.SpeechSegment) -> Void)?

    public init(config: EdwardConfig) {
        self.config = config
    }

    /// Load the VAD model (downloads ~1.2MB on first run)
    public func load() async throws {
        log.info("Loading Silero VAD model...")
        let vad = try await SileroVADModel.fromPretrained()
        self.model = vad
        self.processor = StreamingVADProcessor(model: vad)
        log.info("Silero VAD loaded")
    }

    /// Process a chunk of audio samples (should be 512 samples = 32ms at 16kHz)
    /// Fires onSpeechStarted/onSpeechEnded callbacks
    public func process(samples: [Float]) {
        guard let processor = processor else { return }

        let events = processor.process(samples: samples)
        for event in events {
            switch event {
            case .speechStarted(let time):
                log.debug("Speech started at \(String(format: "%.2f", time))s")
                onSpeechStarted?(time)
            case .speechEnded(let segment):
                log.debug("Speech ended: \(String(format: "%.2f", segment.startTime))s - \(String(format: "%.2f", segment.endTime))s")
                onSpeechEnded?(segment)
            }
        }
    }

    /// Flush any pending speech at stream end
    public func flush() {
        guard let processor = processor else { return }
        // Reset processor state instead of flushing — upstream flush() can crash
        // when the internal buffer exceeds chunkSize (negative array count).
        processor.reset()
    }

    /// Reset VAD state (call between different audio streams)
    public func reset() {
        model?.resetState()
    }
}
