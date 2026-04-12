import Foundation
import os.log

/// Simple logger that writes to both os_log and a file
public final class EdwardLogger {
    public static let shared = EdwardLogger()

    private let osLog = Logger(subsystem: "com.edward.daemon", category: "general")
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.edward.logger")

    public func configure(logPath: String) {
        queue.sync {
            let dir = (logPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            fileHandle = FileHandle(forWritingAtPath: logPath)
            fileHandle?.seekToEndOfFile()
        }
    }

    public func info(_ message: String) {
        osLog.info("\(message)")
        writeToFile("INFO", message)
    }

    public func error(_ message: String) {
        osLog.error("\(message)")
        writeToFile("ERROR", message)
    }

    public func debug(_ message: String) {
        osLog.debug("\(message)")
        writeToFile("DEBUG", message)
    }

    private func writeToFile(_ level: String, _ message: String) {
        queue.async { [weak self] in
            let formatter = ISO8601DateFormatter()
            let timestamp = formatter.string(from: Date())
            let line = "[\(timestamp)] [\(level)] \(message)\n"
            if let data = line.data(using: .utf8) {
                self?.fileHandle?.write(data)
            }
        }
    }
}

public let log = EdwardLogger.shared
