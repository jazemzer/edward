import AVFoundation
import Foundation

/// Captures audio from the microphone using AVAudioEngine
/// Delivers 16kHz mono Float32 samples via a callback
public final class AudioCapture: AudioSource {
    private let engine = AVAudioEngine()
    private let sampleRate: Int
    private var onSamples: (([Float]) -> Void)?

    public let sourceId = "mic"
    public let sourceLabel = "Microphone"
    public private(set) var isRunning = false

    public init(config: EdwardConfig) {
        self.sampleRate = config.sampleRate
    }

    /// Start capturing audio from the default input device
    /// `onSamples` is called on the audio thread with 16kHz mono Float32 chunks
    public func start(onSamples: @escaping ([Float]) -> Void) throws {
        // Check mic permission without prompting
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            log.info("Microphone permission not yet determined — requesting...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    try? self.startEngine(onSamples: onSamples)
                } else {
                    log.info("Microphone permission denied by user")
                }
            }
            return
        default:
            log.info("Microphone permission not granted — grant in System Settings > Privacy > Microphone")
            print("No microphone permission — grant in System Settings > Privacy > Microphone")
            fflush(stdout)
            return
        }

        try startEngine(onSamples: onSamples)
    }

    private func startEngine(onSamples: @escaping ([Float]) -> Void) throws {
        self.onSamples = onSamples

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        log.info("Audio input: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw EdwardError.audioFormatError("Cannot create target audio format")
        }

        // Install converter if needed
        let converter: AVAudioConverter?
        if hwFormat.sampleRate != Double(sampleRate) || hwFormat.channelCount != 1 {
            converter = AVAudioConverter(from: hwFormat, to: targetFormat)
            if converter == nil {
                log.error("Cannot create audio converter from \(hwFormat) to \(targetFormat)")
            }
        } else {
            converter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 512, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let samples: [Float]
            if let converter = converter {
                samples = self.convert(buffer: buffer, converter: converter, targetFormat: targetFormat)
            } else {
                guard let channelData = buffer.floatChannelData else { return }
                let count = Int(buffer.frameLength)
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
            }

            guard !samples.isEmpty else { return }

            self.onSamples?(samples)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        log.info("Audio capture started")
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        log.info("Audio capture stopped")
    }

    private func convert(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) -> [Float] {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return []
        }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            log.error("Audio conversion error: \(error)")
            return []
        }

        guard let channelData = outputBuffer.floatChannelData else { return [] }
        let count = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}

public enum EdwardError: Error, LocalizedError {
    case audioFormatError(String)
    case modelLoadError(String)
    case transcriptionError(String)
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case .audioFormatError(let msg): return "Audio format error: \(msg)"
        case .modelLoadError(let msg): return "Model load error: \(msg)"
        case .transcriptionError(let msg): return "Transcription error: \(msg)"
        case .storageError(let msg): return "Storage error: \(msg)"
        }
    }
}
