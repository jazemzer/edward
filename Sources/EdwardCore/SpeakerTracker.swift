import Foundation
import SpeechVAD
import AudioCommon

/// Tracks speakers across segments using WeSpeaker embeddings.
/// Maintains a registry of known speakers and matches new audio against them.
public final class SpeakerTracker {
    private var embeddingModel: WeSpeakerModel?
    private var speakers: [Speaker] = []
    private let lock = NSLock()
    private let config: EdwardConfig

    /// Cosine similarity threshold for matching a speaker (0-1, higher = stricter)
    /// WeSpeaker embeddings on short segments typically yield 0.3-0.7 for same speaker
    public var matchThreshold: Float = 0.45

    /// Minimum audio duration (seconds) to attempt speaker identification
    /// Short utterances produce unreliable embeddings
    public var minDurationForId: Double = 1.0

    public init(config: EdwardConfig) {
        self.config = config
    }

    /// Load WeSpeaker model (downloads ~25MB on first run)
    public func load() async throws {
        log.info("Loading WeSpeaker speaker embedding model...")
        embeddingModel = try await WeSpeakerModel.fromPretrained()
        log.info("WeSpeaker loaded (256-dim embeddings)")
    }

    /// Identify the speaker for an audio segment.
    /// Returns a SpeakerInfo with the matched or newly created speaker.
    public func identify(audio: [Float], sampleRate: Int = 16000) -> SpeakerInfo {
        guard let model = embeddingModel else {
            return SpeakerInfo(id: "unknown", name: nil, isNew: false, confidence: 0)
        }

        // Skip speaker ID for very short segments — embeddings are unreliable
        let duration = Double(audio.count) / Double(sampleRate)
        if duration < minDurationForId {
            // Assign to the most recently active speaker if available
            lock.lock()
            defer { lock.unlock() }
            if let recent = speakers.max(by: { $0.lastSeen < $1.lastSeen }) {
                return SpeakerInfo(id: recent.id, name: recent.name, isNew: false, confidence: 0.5)
            }
            return SpeakerInfo(id: "unknown", name: nil, isNew: false, confidence: 0)
        }

        // Extract 256-dim L2-normalized embedding
        let embedding = model.embed(audio: audio, sampleRate: sampleRate)

        // Sanity check: skip if embedding is all zeros (failed extraction)
        let norm = embedding.reduce(Float(0)) { $0 + $1 * $1 }
        if norm < 0.01 {
            return SpeakerInfo(id: "unknown", name: nil, isNew: false, confidence: 0)
        }

        lock.lock()
        defer { lock.unlock() }

        // Find best matching speaker
        var bestMatch: (index: Int, similarity: Float)?
        for (i, speaker) in speakers.enumerated() {
            let sim = cosineSimilarity(embedding, speaker.centroid)
            if let current = bestMatch {
                if sim > current.similarity {
                    bestMatch = (i, sim)
                }
            } else {
                bestMatch = (i, sim)
            }
        }

        if let match = bestMatch, match.similarity >= matchThreshold {
            // Known speaker — update centroid conservatively
            var speaker = speakers[match.index]
            speaker.segmentCount += 1
            speaker.centroid = updateCentroid(
                old: speaker.centroid,
                new: embedding,
                count: speaker.segmentCount
            )
            speaker.lastSeen = Date()
            speakers[match.index] = speaker

            log.debug("Speaker matched: \(speaker.label) (similarity: \(String(format: "%.3f", match.similarity)))")

            return SpeakerInfo(
                id: speaker.id,
                name: speaker.name,
                isNew: false,
                confidence: match.similarity
            )
        } else {
            // New speaker
            let speakerNum = speakers.count + 1
            let id = "speaker_\(speakerNum)"
            let speaker = Speaker(
                id: id,
                name: nil,
                centroid: embedding,
                segmentCount: 1,
                firstSeen: Date(),
                lastSeen: Date()
            )
            speakers.append(speaker)

            log.info("New speaker detected: \(id) (total: \(speakers.count))")

            return SpeakerInfo(
                id: id,
                name: nil,
                isNew: true,
                confidence: 1.0
            )
        }
    }

    /// Assign a name to a speaker ID (e.g., "speaker_1" → "Alice")
    public func nameSpeaker(id: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = speakers.firstIndex(where: { $0.id == id }) {
            speakers[idx].name = name
        }
    }

    /// Get all known speakers
    public var knownSpeakers: [SpeakerInfo] {
        lock.lock()
        defer { lock.unlock() }
        return speakers.map {
            SpeakerInfo(id: $0.id, name: $0.name, isNew: false, confidence: 1.0)
        }
    }

    /// Number of known speakers
    public var speakerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return speakers.count
    }

    /// Save speaker embeddings to disk for persistence across restarts
    public func save() throws {
        let path = "\(config.dataDir)/speakers.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(speakers)
        try data.write(to: URL(fileURLWithPath: path))
        log.info("Saved \(speakers.count) speaker profiles to \(path)")
    }

    /// Load speaker embeddings from disk
    public func loadProfiles() {
        let path = "\(config.dataDir)/speakers.json"
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([Speaker].self, from: data) {
            lock.lock()
            speakers = loaded
            lock.unlock()
            log.info("Loaded \(loaded.count) speaker profiles")
        }
    }

    // MARK: - Private

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    private func updateCentroid(old: [Float], new: [Float], count: Int) -> [Float] {
        // Conservative update — stabilize quickly, then barely move
        // First 5 segments: build the centroid. After that: very slow updates.
        let alpha: Float = count <= 5 ? (1.0 / Float(count)) : 0.05
        var result = zip(old, new).map { (1 - alpha) * $0 + alpha * $1 }
        // Re-normalize to unit length
        let norm = sqrt(result.reduce(Float(0)) { $0 + $1 * $1 })
        if norm > 0 {
            result = result.map { $0 / norm }
        }
        return result
    }
}

// MARK: - Types

struct Speaker: Codable {
    let id: String
    var name: String?
    var centroid: [Float]
    var segmentCount: Int
    var firstSeen: Date
    var lastSeen: Date

    var label: String {
        name ?? id
    }
}

/// Public speaker info (without embedding data)
public struct SpeakerInfo: Codable, Sendable {
    public let id: String
    public let name: String?
    public let isNew: Bool
    public let confidence: Float

    public var label: String {
        name ?? id
    }
}
