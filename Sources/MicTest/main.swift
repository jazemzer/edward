import Foundation
import AVFoundation

// Minimal test: just try to access the mic
print("Edward mic test starting...")
print("Bundle ID: \(Bundle.main.bundleIdentifier ?? "none")")
print("Bundle path: \(Bundle.main.bundlePath)")

let engine = AVAudioEngine()
let inputNode = engine.inputNode
let format = inputNode.inputFormat(forBus: 0)
print("Input format: \(format)")
print("Sample rate: \(format.sampleRate)")
print("Channels: \(format.channelCount)")

inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
    let samples = buffer.floatChannelData?[0]
    let count = Int(buffer.frameLength)
    if let samples = samples, count > 0 {
        let rms = sqrt(samples.withMemoryRebound(to: Float.self, capacity: count) { ptr in
            var sum: Float = 0
            for i in 0..<count { sum += ptr[i] * ptr[i] }
            return sum / Float(count)
        })
        print("Audio level: \(rms)")
    }
}

do {
    engine.prepare()
    try engine.start()
    print("Audio engine started! Listening for 5 seconds...")
    Thread.sleep(forTimeInterval: 5)
    engine.stop()
    print("Done.")
} catch {
    print("Error: \(error)")
}
