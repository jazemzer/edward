import Foundation

/// Unified interface for all audio sources (mic, system audio, etc.)
public protocol AudioSource: AnyObject {
    /// Stable identifier stored in the database (e.g., "mic", "system:zoom")
    var sourceId: String { get }
    /// Human-readable label for display (e.g., "Microphone", "Zoom")
    var sourceLabel: String { get }
    var isRunning: Bool { get }

    /// Start capturing audio. Callback delivers 16kHz mono Float32 chunks.
    func start(onSamples: @escaping ([Float]) -> Void) throws
    func stop()
}
