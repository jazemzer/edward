import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Handles persistence: SQLite database + daily transcript files
public final class Storage {
    private var db: OpaquePointer?
    private let config: EdwardConfig
    private let queue = DispatchQueue(label: "com.edward.storage")

    public init(config: EdwardConfig) {
        self.config = config
    }

    public func open() throws {
        try config.ensureDirectories()

        var dbPtr: OpaquePointer?
        let rc = sqlite3_open(config.dbPath, &dbPtr)
        guard rc == SQLITE_OK, let db = dbPtr else {
            let msg = String(cString: sqlite3_errmsg(dbPtr))
            throw EdwardError.storageError("Cannot open database: \(msg)")
        }
        self.db = db

        // Create tables with speaker columns
        let sql = """
        CREATE TABLE IF NOT EXISTS transcripts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            duration REAL NOT NULL,
            text TEXT NOT NULL,
            processing_time REAL NOT NULL,
            audio_path TEXT,
            speaker_id TEXT,
            speaker_name TEXT,
            speaker_confidence REAL
        );
        CREATE INDEX IF NOT EXISTS idx_transcripts_timestamp ON transcripts(timestamp);
        CREATE INDEX IF NOT EXISTS idx_transcripts_speaker ON transcripts(speaker_id);
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        let execRc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if execRc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw EdwardError.storageError("Cannot create table: \(msg)")
        }

        // Migrate: add speaker columns if they don't exist (for existing DBs)
        migrate(db)

        log.info("Database opened at \(config.dbPath)")
    }

    private func migrate(_ db: OpaquePointer) {
        // Check if speaker_id column exists
        var stmt: OpaquePointer?
        let checkSql = "PRAGMA table_info(transcripts);"
        guard sqlite3_prepare_v2(db, checkSql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var hasSpeakerId = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let colName = String(cString: sqlite3_column_text(stmt, 1))
            if colName == "speaker_id" { hasSpeakerId = true }
        }

        if !hasSpeakerId {
            let alterSql = """
            ALTER TABLE transcripts ADD COLUMN speaker_id TEXT;
            ALTER TABLE transcripts ADD COLUMN speaker_name TEXT;
            ALTER TABLE transcripts ADD COLUMN speaker_confidence REAL;
            ALTER TABLE transcripts ADD COLUMN audio_path TEXT;
            """
            sqlite3_exec(db, alterSql, nil, nil, nil)
            log.info("Migrated database: added speaker + audio columns")
        }

        // Check if word_timestamps column exists
        var hasWordTimestamps = false
        var stmt2: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSql, -1, &stmt2, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt2) }
        while sqlite3_step(stmt2) == SQLITE_ROW {
            let colName = String(cString: sqlite3_column_text(stmt2, 1))
            if colName == "word_timestamps" { hasWordTimestamps = true }
        }

        if !hasWordTimestamps {
            sqlite3_exec(db, "ALTER TABLE transcripts ADD COLUMN word_timestamps TEXT;", nil, nil, nil)
            log.info("Migrated database: added word_timestamps column")
        }

        // Check if source column exists
        var hasSource = false
        var stmt3: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSql, -1, &stmt3, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt3) }
        while sqlite3_step(stmt3) == SQLITE_ROW {
            let colName = String(cString: sqlite3_column_text(stmt3, 1))
            if colName == "source" { hasSource = true }
        }

        if !hasSource {
            sqlite3_exec(db, "ALTER TABLE transcripts ADD COLUMN source TEXT;", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_transcripts_source ON transcripts(source);", nil, nil, nil)
            log.info("Migrated database: added source column")
        }
    }

    /// Save a transcript entry to SQLite and daily file
    @discardableResult
    public func save(_ entry: TranscriptEntry) throws -> TranscriptEntry {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        var updated = entry

        // Insert into SQLite
        try queue.sync {
            let sql = """
            INSERT INTO transcripts (timestamp, duration, text, processing_time, speaker_id, speaker_name, speaker_confidence, audio_path, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare insert: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }

            let ts = entry.timestampString
            sqlite3_bind_text(stmt, 1, (ts as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, entry.duration)
            sqlite3_bind_text(stmt, 3, (entry.text as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, entry.processingTime)

            if let sid = entry.speakerId {
                sqlite3_bind_text(stmt, 5, (sid as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if let sname = entry.speakerName {
                sqlite3_bind_text(stmt, 6, (sname as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            if let conf = entry.speakerConfidence {
                sqlite3_bind_double(stmt, 7, Double(conf))
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if let ap = entry.audioPath {
                sqlite3_bind_text(stmt, 8, (ap as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            if let src = entry.source {
                sqlite3_bind_text(stmt, 9, (src as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 9)
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot insert: \(String(cString: sqlite3_errmsg(db)))")
            }
            updated.id = sqlite3_last_insert_rowid(db)
        }

        // Append to daily file
        appendToDailyFile(entry)

        return updated
    }

    /// Query recent transcripts
    public func recent(limit: Int = 20) throws -> [TranscriptEntry] {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        let sql = "SELECT id, timestamp, duration, text, processing_time, speaker_id, speaker_name, speaker_confidence, word_timestamps, source FROM transcripts ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EdwardError.storageError("Cannot prepare query")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))
        return parseRows(stmt).reversed()
    }

    /// Search transcripts by text
    public func search(query: String, limit: Int = 50) throws -> [TranscriptEntry] {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        let sql = "SELECT id, timestamp, duration, text, processing_time, speaker_id, speaker_name, speaker_confidence, word_timestamps, source FROM transcripts WHERE text LIKE ? ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EdwardError.storageError("Cannot prepare search")
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(query)%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        return parseRows(stmt)
    }

    /// Query transcripts by speaker
    public func bySpeaker(speakerId: String, limit: Int = 50) throws -> [TranscriptEntry] {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        let sql = "SELECT id, timestamp, duration, text, processing_time, speaker_id, speaker_name, speaker_confidence, word_timestamps, source FROM transcripts WHERE speaker_id = ? ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EdwardError.storageError("Cannot prepare speaker query")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (speakerId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        return parseRows(stmt)
    }

    public func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
            log.info("Database closed")
        }
    }

    /// Save raw audio segment to disk. Returns the file path.
    public func saveAudio(_ audio: [Float], sampleRate: Int, timestamp: Date) throws -> String {
        let audioDir = "\(config.dataDir)/audio"
        try FileManager.default.createDirectory(atPath: audioDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let filename = formatter.string(from: timestamp) + ".raw"
        let path = "\(audioDir)/\(filename)"

        // Save as raw Float32 PCM — compact and fast to read back
        let data = audio.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: URL(fileURLWithPath: path))

        return path
    }

    /// Load raw audio from a saved file
    public static func loadAudio(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }

    /// Update speaker info for a transcript entry
    public func updateSpeaker(id: Int64, speakerId: String, speakerName: String?, confidence: Float) throws {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        try queue.sync {
            let sql = "UPDATE transcripts SET speaker_id = ?, speaker_name = ?, speaker_confidence = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare update: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (speakerId as NSString).utf8String, -1, nil)
            if let name = speakerName {
                sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_double(stmt, 3, Double(confidence))
            sqlite3_bind_int64(stmt, 4, id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot update: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// Update word timestamps for a transcript entry
    public func updateWordTimestamps(id: Int64, timestamps: [WordTimestamp]) throws {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        let json = try JSONEncoder().encode(timestamps)
        let jsonStr = String(data: json, encoding: .utf8) ?? "[]"

        try queue.sync {
            let sql = "UPDATE transcripts SET word_timestamps = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare update: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (jsonStr as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot update: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// Get all entries that have audio files (for offline diarization)
    public func entriesWithAudio(date: Date? = nil) throws -> [TranscriptEntry] {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        var sql: String
        if let date = date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: date)
            sql = "SELECT id, timestamp, duration, text, processing_time, speaker_id, speaker_name, speaker_confidence, audio_path, word_timestamps, source FROM transcripts WHERE audio_path IS NOT NULL AND timestamp LIKE '\(dateStr)%' ORDER BY id;"
        } else {
            sql = "SELECT id, timestamp, duration, text, processing_time, speaker_id, speaker_name, speaker_confidence, audio_path, word_timestamps, source FROM transcripts WHERE audio_path IS NOT NULL ORDER BY id;"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EdwardError.storageError("Cannot prepare query")
        }
        defer { sqlite3_finalize(stmt) }

        return parseRowsWithAudio(stmt)
    }

    // MARK: - Private

    private func parseRowsWithAudio(_ stmt: OpaquePointer?) -> [TranscriptEntry] {
        let formatter = ISO8601DateFormatter()
        var results: [TranscriptEntry] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let tsStr = String(cString: sqlite3_column_text(stmt, 1))
            let duration = sqlite3_column_double(stmt, 2)
            let text = String(cString: sqlite3_column_text(stmt, 3))
            let processingTime = sqlite3_column_double(stmt, 4)
            let speakerId: String? = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 5)) : nil
            let speakerName: String? = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let speakerConfidence: Float? = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Float(sqlite3_column_double(stmt, 7)) : nil
            let audioPath: String? = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil

            var wordTimestamps: [WordTimestamp]?
            if sqlite3_column_type(stmt, 9) != SQLITE_NULL,
               let jsonStr = sqlite3_column_text(stmt, 9) {
                let str = String(cString: jsonStr)
                if let data = str.data(using: .utf8) {
                    wordTimestamps = try? JSONDecoder().decode([WordTimestamp].self, from: data)
                }
            }

            let source: String? = sqlite3_column_type(stmt, 10) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 10)) : nil

            let timestamp = formatter.date(from: tsStr) ?? Date()
            results.append(TranscriptEntry(
                id: id, timestamp: timestamp, duration: duration, text: text,
                processingTime: processingTime, speakerId: speakerId,
                speakerName: speakerName, speakerConfidence: speakerConfidence,
                audioPath: audioPath, wordTimestamps: wordTimestamps,
                source: source
            ))
        }
        return results
    }

    private func parseRows(_ stmt: OpaquePointer?) -> [TranscriptEntry] {
        let formatter = ISO8601DateFormatter()
        var results: [TranscriptEntry] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let tsStr = String(cString: sqlite3_column_text(stmt, 1))
            let duration = sqlite3_column_double(stmt, 2)
            let text = String(cString: sqlite3_column_text(stmt, 3))
            let processingTime = sqlite3_column_double(stmt, 4)

            let speakerId: String? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 5)) : nil
            let speakerName: String? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let speakerConfidence: Float? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                ? Float(sqlite3_column_double(stmt, 7)) : nil

            var wordTimestamps: [WordTimestamp]?
            if sqlite3_column_type(stmt, 8) != SQLITE_NULL,
               let jsonStr = sqlite3_column_text(stmt, 8) {
                let str = String(cString: jsonStr)
                if let data = str.data(using: .utf8) {
                    wordTimestamps = try? JSONDecoder().decode([WordTimestamp].self, from: data)
                }
            }

            let source: String? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 9)) : nil

            let timestamp = formatter.date(from: tsStr) ?? Date()
            results.append(TranscriptEntry(
                id: id,
                timestamp: timestamp,
                duration: duration,
                text: text,
                processingTime: processingTime,
                speakerId: speakerId,
                speakerName: speakerName,
                speakerConfidence: speakerConfidence,
                wordTimestamps: wordTimestamps,
                source: source
            ))
        }

        return results
    }

    private func appendToDailyFile(_ entry: TranscriptEntry) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = formatter.string(from: entry.timestamp)
        let path = "\(config.transcriptsDir)/\(filename).txt"

        let speaker = entry.speakerLabel
        let line = "[\(entry.timeString)] [\(speaker)] \(entry.text)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
