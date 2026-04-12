import Foundation

/// Thread-safe circular buffer for audio samples
public final class RingBuffer: @unchecked Sendable {
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var totalWritten: Int = 0
    private let capacity: Int
    private let lock = NSLock()

    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    /// Write samples into the buffer
    public func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            buffer[writeIndex % capacity] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        totalWritten += samples.count
    }

    /// Read the last `count` samples from the buffer
    /// Returns fewer samples if not enough have been written yet
    public func readLast(_ count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let available = min(count, min(totalWritten, capacity))
        if available == 0 { return [] }

        var result = [Float](repeating: 0, count: available)
        let startIdx = (writeIndex - available + capacity) % capacity

        for i in 0..<available {
            result[i] = buffer[(startIdx + i) % capacity]
        }
        return result
    }

    /// Read samples from a specific time range (in seconds, relative to current time)
    public func readRange(startSecondsAgo: Double, endSecondsAgo: Double, sampleRate: Int) -> [Float] {
        let startSamples = Int(startSecondsAgo * Double(sampleRate))
        let endSamples = Int(endSecondsAgo * Double(sampleRate))
        let totalSamples = startSamples - endSamples
        if totalSamples <= 0 { return [] }

        lock.lock()
        defer { lock.unlock() }

        let available = min(totalWritten, capacity)
        let startOffset = min(startSamples, available)
        let endOffset = min(endSamples, available)
        let count = startOffset - endOffset
        if count <= 0 { return [] }

        var result = [Float](repeating: 0, count: count)
        let readStart = (writeIndex - startOffset + capacity) % capacity

        for i in 0..<count {
            result[i] = buffer[(readStart + i) % capacity]
        }
        return result
    }

    public var availableSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return min(totalWritten, capacity)
    }
}
