import Foundation
import ScreenCaptureKit
import AVFoundation

/// Captures audio from a specific application using ScreenCaptureKit
public final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate {
    public let sourceId: String
    public let sourceLabel: String
    public private(set) var isRunning = false

    private let bundleId: String
    private var stream: SCStream?
    private var onSamples: (([Float]) -> Void)?
    private var converter: AVAudioConverter?
    private let targetSampleRate: Double = 16000
    private var hasReceivedAudio = false

    public init(bundleId: String, label: String) {
        self.bundleId = bundleId
        self.sourceId = "system:\(label.lowercased())"
        self.sourceLabel = label
        super.init()
    }

    public func start(onSamples: @escaping ([Float]) -> Void) throws {
        self.onSamples = onSamples

        // Start capture asynchronously but log all errors
        Task {
            do {
                try await startCapture()
            } catch {
                log.error("[\(sourceId)] Failed to start system audio capture: \(error)")
                print("[\(sourceId)] System audio capture failed: \(error)")
                fflush(stdout)
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        Task {
            try? await stream?.stopCapture()
        }
        stream = nil
        isRunning = false
        converter = nil
        hasReceivedAudio = false
        log.info("[\(sourceId)] System audio capture stopped")
    }

    // MARK: - Private

    private func startCapture() async throws {
        log.info("[\(sourceId)] Requesting shareable content...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        log.info("[\(sourceId)] Found \(content.applications.count) apps, looking for \(bundleId)")

        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleId }) else {
            log.info("[\(sourceId)] App not running: \(bundleId)")
            print("[\(sourceId)] App not running: \(bundleId)")
            fflush(stdout)
            return
        }

        log.info("[\(sourceId)] Found app: \(app.applicationName) (PID: \(app.processID))")

        // Use app-level audio capture filter
        guard let display = content.displays.first else {
            log.error("[\(sourceId)] No display found")
            return
        }

        // Include ONLY this app by excluding everything else
        let excludedApps = content.applications.filter { $0.processID != app.processID }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 48000

        // Minimize video overhead — we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: SCStreamOutputType.audio, sampleHandlerQueue: DispatchQueue(label: "com.edward.system-audio.\(bundleId)"))

        log.info("[\(sourceId)] Starting capture stream...")
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
        log.info("[\(sourceId)] System audio capture started for \(app.applicationName)")
        print("[\(sourceId)] Capturing audio from \(app.applicationName)")
        fflush(stdout)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("[\(sourceId)] Stream stopped with error: \(error)")
        print("[\(sourceId)] Stream error: \(error)")
        fflush(stdout)
        isRunning = false
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let formatDesc = sampleBuffer.formatDescription else { return }

        let audioDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        guard let desc = audioDesc else { return }

        if !hasReceivedAudio {
            hasReceivedAudio = true
            log.info("[\(sourceId)] First audio received: \(desc.mSampleRate)Hz, \(desc.mChannelsPerFrame)ch, \(desc.mBitsPerChannel)bit, flags=\(desc.mFormatFlags)")
            print("[\(sourceId)] Receiving audio: \(Int(desc.mSampleRate))Hz \(desc.mChannelsPerFrame)ch")
            fflush(stdout)
        }

        // Get audio data from sample buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { rawBuffer in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawBuffer.baseAddress!)
        }

        // Convert to Float32 samples
        let samples: [Float]
        if desc.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            samples = data.withUnsafeBytes { raw in
                let buffer = raw.bindMemory(to: Float.self)
                return Array(buffer)
            }
        } else if desc.mBitsPerChannel == 16 {
            samples = data.withUnsafeBytes { raw in
                let buffer = raw.bindMemory(to: Int16.self)
                return buffer.map { Float($0) / 32768.0 }
            }
        } else {
            log.error("[\(sourceId)] Unsupported audio format: \(desc.mBitsPerChannel)bit, flags=\(desc.mFormatFlags)")
            return
        }

        guard !samples.isEmpty else { return }

        // Check if audio is silent (all zeros)
        let maxAmp = samples.reduce(Float(0)) { max(abs($0), abs($1)) }
        guard maxAmp > 0.0001 else { return } // skip silence

        // Resample to 16kHz if needed
        let sourceSampleRate = desc.mSampleRate
        if abs(sourceSampleRate - targetSampleRate) < 1.0 {
            onSamples?(samples)
        } else {
            if let resampled = resample(samples: samples, from: sourceSampleRate, to: targetSampleRate) {
                onSamples?(resampled)
            }
        }
    }

    private func resample(samples: [Float], from sourceSR: Double, to targetSR: Double) -> [Float]? {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceSR, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSR, channels: 1, interleaved: false) else {
            return nil
        }

        if converter == nil || converter?.inputFormat.sampleRate != sourceSR {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter = converter else { return nil }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return nil }
        inputBuffer.frameLength = frameCount
        memcpy(inputBuffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * targetSR / sourceSR)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return nil }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard error == nil, let channelData = outputBuffer.floatChannelData else { return nil }
        let count = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
