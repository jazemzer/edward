import Foundation
import AVFoundation
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
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            duration REAL NOT NULL,
            audio_path TEXT NOT NULL,
            num_speakers INTEGER,
            transcript_text TEXT,
            summary TEXT,
            model_used TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_start ON sessions(start_time);
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

    /// Delete a transcript entry and its associated audio file
    public func deleteTranscript(id: Int64) throws {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        // First, get the audio path so we can delete the file
        var audioPath: String?
        let selectSql = "SELECT audio_path FROM transcripts WHERE id = ?;"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(selectStmt, 1, id)
            if sqlite3_step(selectStmt) == SQLITE_ROW, sqlite3_column_type(selectStmt, 0) != SQLITE_NULL {
                audioPath = String(cString: sqlite3_column_text(selectStmt, 0))
            }
        }
        sqlite3_finalize(selectStmt)

        // Delete the database row
        try queue.sync {
            let sql = "DELETE FROM transcripts WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare delete: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot delete: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        // Delete the audio file if it exists
        if let path = audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        log.info("Deleted transcript \(id)")
    }

    /// Rename a session's audio file and update the database path
    public func renameSession(id: Int64, newName: String) throws -> String {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        // Get current audio path
        let selectSql = "SELECT audio_path FROM sessions WHERE id = ?;"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else {
            throw EdwardError.storageError("Cannot prepare select")
        }
        defer { sqlite3_finalize(selectStmt) }
        sqlite3_bind_int64(selectStmt, 1, id)

        guard sqlite3_step(selectStmt) == SQLITE_ROW else {
            throw EdwardError.storageError("Session not found")
        }
        let currentPath = String(cString: sqlite3_column_text(selectStmt, 0))

        let fm = FileManager.default
        let dir = (currentPath as NSString).deletingLastPathComponent
        let sanitized = newName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var isDir: ObjCBool = false
        let newPath: String
        if fm.fileExists(atPath: currentPath, isDirectory: &isDir), isDir.boolValue {
            newPath = "\(dir)/\(sanitized)"
        } else {
            let ext = (currentPath as NSString).pathExtension
            newPath = "\(dir)/\(sanitized).\(ext)"
        }

        // Rename the audio file
        if fm.fileExists(atPath: currentPath) {
            try fm.moveItem(atPath: currentPath, toPath: newPath)
        }

        // Update database
        try queue.sync {
            let sql = "UPDATE sessions SET audio_path = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare update: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (newPath as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot update: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        log.info("Renamed session \(id) to \(newPath)")
        return newPath
    }

    /// Delete a session and its audio file
    public func deleteSession(id: Int64) throws {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        // Get audio path
        var audioPath: String?
        let selectSql = "SELECT audio_path FROM sessions WHERE id = ?;"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(selectStmt, 1, id)
            if sqlite3_step(selectStmt) == SQLITE_ROW {
                audioPath = String(cString: sqlite3_column_text(selectStmt, 0))
            }
        }
        sqlite3_finalize(selectStmt)

        // Delete database row
        try queue.sync {
            let sql = "DELETE FROM sessions WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare delete: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot delete: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        // Delete audio file
        if let path = audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        log.info("Deleted session \(id)")
    }

    /// Update a session's summary
    public func updateSessionSummary(id: Int64, summary: String) throws {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        try queue.sync {
            let sql = "UPDATE sessions SET summary = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare update: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (summary as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot update: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        log.info("Updated summary for session \(id)")
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

    /// Load raw audio from a saved file or session folder
    public static func loadAudio(path: String) throws -> [Float] {
        var audioPath = path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            audioPath = "\(path)/audio.raw"
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: audioPath))
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

    /// Delete all transcript entries between two timestamps (for retranscription)
    public func deleteEntriesBetween(start: Date, end: Date) throws {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        let formatter = ISO8601DateFormatter()
        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)

        try queue.sync {
            let sql = "DELETE FROM transcripts WHERE timestamp >= ? AND timestamp <= ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare delete: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (startStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (endStr as NSString).utf8String, -1, nil)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot delete: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        log.info("Deleted transcript entries between \(startStr) and \(endStr)")
    }

    /// Update a session's transcript text and speaker count
    public func updateSessionTranscript(id: Int64, transcriptText: String, numSpeakers: Int) throws {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        try queue.sync {
            let sql = "UPDATE sessions SET transcript_text = ?, num_speakers = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare update: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (transcriptText as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(numSpeakers))
            sqlite3_bind_int64(stmt, 3, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot update: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        log.info("Updated transcript for session \(id)")
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

    /// Get all entries between two timestamps (for session finalization)
    public func entriesBetween(start: Date, end: Date) throws -> [TranscriptEntry] {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        let formatter = ISO8601DateFormatter()
        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)

        let sql = "SELECT id, timestamp, duration, text, processing_time, speaker_id, speaker_name, speaker_confidence, audio_path, word_timestamps, source FROM transcripts WHERE timestamp >= ? AND timestamp <= ? ORDER BY id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EdwardError.storageError("Cannot prepare query")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (startStr as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (endStr as NSString).utf8String, -1, nil)

        return parseRowsWithAudio(stmt)
    }

    /// Save a session record to the database. Returns the session ID.
    @discardableResult
    public func saveSession(startTime: Date, endTime: Date, duration: Double, audioPath: String, numSpeakers: Int, transcriptText: String?, summary: String?, modelUsed: String?) throws -> Int64 {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        let formatter = ISO8601DateFormatter()
        let startStr = formatter.string(from: startTime)
        let endStr = formatter.string(from: endTime)

        var sessionId: Int64 = 0
        try queue.sync {
            let sql = "INSERT INTO sessions (start_time, end_time, duration, audio_path, num_speakers, transcript_text, summary, model_used) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EdwardError.storageError("Cannot prepare session insert: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (startStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (endStr as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, duration)
            sqlite3_bind_text(stmt, 4, (audioPath as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 5, Int32(numSpeakers))
            if let text = transcriptText {
                sqlite3_bind_text(stmt, 6, (text as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            if let sum = summary {
                sqlite3_bind_text(stmt, 7, (sum as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if let model = modelUsed {
                sqlite3_bind_text(stmt, 8, (model as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 8)
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EdwardError.storageError("Cannot insert session: \(String(cString: sqlite3_errmsg(db)))")
            }
            sessionId = sqlite3_last_insert_rowid(db)
        }

        return sessionId
    }

    /// Query recent sessions
    public func recentSessions(limit: Int = 20) throws -> [SessionRecord] {
        guard let db = db else { throw EdwardError.storageError("Database not open") }

        let sql = "SELECT id, start_time, end_time, duration, audio_path, num_speakers, transcript_text, summary, model_used FROM sessions ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EdwardError.storageError("Cannot prepare sessions query")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        let formatter = ISO8601DateFormatter()
        var results: [SessionRecord] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let startStr = String(cString: sqlite3_column_text(stmt, 1))
            let endStr = String(cString: sqlite3_column_text(stmt, 2))
            let duration = sqlite3_column_double(stmt, 3)
            let audioPath = String(cString: sqlite3_column_text(stmt, 4))
            let numSpeakers = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 5)) : nil
            let transcriptText: String? = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let summary: String? = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
            let modelUsed: String? = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil

            results.append(SessionRecord(
                id: id,
                startTime: formatter.date(from: startStr) ?? Date(),
                endTime: formatter.date(from: endStr) ?? Date(),
                duration: duration,
                audioPath: audioPath,
                numSpeakers: numSpeakers,
                transcriptText: transcriptText,
                summary: summary,
                modelUsed: modelUsed
            ))
        }

        return results
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

}

// MARK: - Session Folder Files

public struct TranscriptDocument: Codable {
    public let version: Int
    public let startTime: String
    public let duration: Double
    public let numSpeakers: Int
    public let segments: [TranscriptSegment]

    public init(startTime: Date, duration: Double, numSpeakers: Int, segments: [TranscriptSegment]) {
        self.version = 1
        let fmt = ISO8601DateFormatter()
        self.startTime = fmt.string(from: startTime)
        self.duration = duration
        self.numSpeakers = numSpeakers
        self.segments = segments
    }
}

public struct TranscriptSegment: Codable {
    public let speaker: String
    public let start: Double
    public let end: Double
    public let text: String

    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct SessionMetadata: Codable {
    public let startTime: String
    public let endTime: String
    public let duration: Double
    public let numSpeakers: Int
    public let modelUsed: String?

    public init(startTime: Date, endTime: Date, duration: Double, numSpeakers: Int, modelUsed: String?) {
        let fmt = ISO8601DateFormatter()
        self.startTime = fmt.string(from: startTime)
        self.endTime = fmt.string(from: endTime)
        self.duration = duration
        self.numSpeakers = numSpeakers
        self.modelUsed = modelUsed
    }
}

extension Storage {
    /// Write transcript.json to session folder
    public static func saveTranscriptJSON(sessionDir: String, document: TranscriptDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: URL(fileURLWithPath: "\(sessionDir)/transcript.json"))
    }

    /// Load transcript.json from session folder
    public static func loadTranscriptJSON(sessionDir: String) -> TranscriptDocument? {
        let path = "\(sessionDir)/transcript.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(TranscriptDocument.self, from: data)
    }

    /// Write transcript.txt to session folder
    public static func saveTranscriptText(sessionDir: String, text: String) throws {
        try text.write(toFile: "\(sessionDir)/transcript.txt", atomically: true, encoding: .utf8)
    }

    /// Write summary.md to session folder
    public static func saveSummary(sessionDir: String, summary: String) throws {
        try summary.write(toFile: "\(sessionDir)/summary.md", atomically: true, encoding: .utf8)
    }

    /// Write metadata.json to session folder
    public static func saveMetadata(sessionDir: String, metadata: SessionMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: URL(fileURLWithPath: "\(sessionDir)/metadata.json"))
    }

    /// Resolve the audio file path from a session path (folder or legacy file)
    public static func audioFilePath(for sessionPath: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sessionPath, isDirectory: &isDir), isDir.boolValue {
            return "\(sessionPath)/audio.raw"
        }
        return sessionPath
    }

    /// Resolve the playback audio file path (ALAC .m4a in folder, or legacy)
    public static func playbackFilePath(for sessionPath: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sessionPath, isDirectory: &isDir), isDir.boolValue {
            return "\(sessionPath)/audio.m4a"
        }
        return (sessionPath as NSString).deletingPathExtension + ".m4a"
    }

    /// Convert raw Float32 PCM to ALAC (.m4a) on disk using AVFoundation
    public static func convertRawToALAC(rawPath: String, outputPath: String, sampleRate: Int) throws {
        let rawData = try Data(contentsOf: URL(fileURLWithPath: rawPath))
        let sampleCount = rawData.count / MemoryLayout<Float>.size

        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            throw EdwardError.storageError("Cannot create audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        rawData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            let dst = buffer.floatChannelData![0]
            for i in 0..<sampleCount {
                dst[i] = src[i]
            }
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16
        ]
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        try outputFile.write(from: buffer)
    }

    /// Load audio from any supported format (raw PCM, or AVAudioFile-compatible like .m4a/.wav/.flac)
    public static func loadAudioFromFile(path: String, sampleRate: Int) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if ext == "raw" {
            return try loadAudio(path: path)
        }

        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw EdwardError.storageError("Cannot create read buffer")
        }
        try file.read(into: buffer)
        let floatPtr = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: floatPtr, count: Int(buffer.frameLength)))
    }
}
