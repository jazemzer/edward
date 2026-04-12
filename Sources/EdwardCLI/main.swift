import Foundation
import EdwardCore

@main
struct EdwardCLIApp {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        let command = args.first ?? "start"

        switch command {
        case "start":
            await startDaemon(foreground: args.contains("--foreground") || args.count <= 1)

        case "stop":
            stopDaemon()

        case "status":
            showStatus()

        case "tail":
            tailSocket()

        case "query":
            let query = args.dropFirst().joined(separator: " ")
            searchTranscripts(query: query)

        case "recent":
            showRecent()

        case "diarize":
            await runDiarize()

        case "install":
            installLaunchAgent()

        case "uninstall":
            uninstallLaunchAgent()

        case "help", "--help", "-h":
            printUsage()

        default:
            print("Unknown command: \(command)")
            printUsage()
        }
    }

    static func startDaemon(foreground: Bool) async {
        var config = EdwardConfig.load()

        // Parse --language flag (e.g., --language en,he,ar)
        let argsArray = Array(CommandLine.arguments.dropFirst())
        if let langIdx = argsArray.firstIndex(of: "--language"), langIdx + 1 < argsArray.count {
            config.languages = argsArray[langIdx + 1]
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            print("Languages: \(config.languages.joined(separator: ", "))")
        }

        // Prevent sleep
        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = ["-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        try? caffeinate.run()

        let daemon = EdwardDaemon(config: config)

        do {
            print("Edward — Always-On Speech Daemon")
            fflush(stdout)
            print("Initializing (downloading models on first run)...")
            fflush(stdout)

            print("  Opening database...")
            fflush(stdout)

            try config.ensureDirectories()

            print("  Loading VAD model...")
            fflush(stdout)
            try await daemon.initialize()

            daemon.onTranscription = { entry in
                let time = entry.timeString
                let speaker = entry.speakerLabel
                print("[\(time)] [\(speaker)] \(entry.text)")
                fflush(stdout)
            }

            try daemon.start()
            print("Listening... (Ctrl+C to stop)")
            print("Transcripts: \(config.transcriptsDir)")
            print("Database: \(config.dbPath)")
            print("Socket: \(config.socketPath)")
            print("")
            fflush(stdout)

            // Keep running — use a semaphore to block the main thread
            let semaphore = DispatchSemaphore(value: 0)

            // Handle signals
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                print("\nShutting down...")
                daemon.stop()
                semaphore.signal()
            }
            sigintSource.resume()
            signal(SIGINT, SIG_IGN) // Let dispatch source handle it

            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            sigtermSource.setEventHandler {
                daemon.stop()
                semaphore.signal()
            }
            sigtermSource.resume()
            signal(SIGTERM, SIG_IGN)

            semaphore.wait()
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func stopDaemon() {
        // Find and kill running daemon process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "edward start"]
        try? task.run()
        task.waitUntilExit()
        print("Sent stop signal to Edward daemon")
    }

    static func showStatus() {
        let config = EdwardConfig.load()
        let dbPath = config.dbPath

        // Check if daemon is running
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "edward start"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()

        let running = task.terminationStatus == 0
        print("Status: \(running ? "running" : "stopped")")
        print("Database: \(dbPath)")

        if FileManager.default.fileExists(atPath: dbPath) {
            let config = EdwardConfig.load()
            let storage = Storage(config: config)
            if let _ = try? storage.open(),
               let entries = try? storage.recent(limit: 1),
               let last = entries.last {
                print("Last transcript: [\(last.timeString)] \(last.text)")
            }
        }
    }

    static func tailSocket() {
        let config = EdwardConfig.load()
        let socketPath = config.socketPath

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("Cannot create socket")
            exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            print("Cannot connect to Edward daemon (is it running?)")
            close(fd)
            exit(1)
        }

        print("Connected to Edward daemon. Live transcriptions:")
        print("")

        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            if let str = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                print(str, terminator: "")
            }
        }

        close(fd)
    }

    static func searchTranscripts(query: String) {
        guard !query.isEmpty else {
            print("Usage: edward query <search term>")
            return
        }

        let config = EdwardConfig.load()
        let storage = Storage(config: config)
        guard let _ = try? storage.open() else {
            print("Cannot open database")
            return
        }

        guard let results = try? storage.search(query: query) else {
            print("Search failed")
            return
        }

        if results.isEmpty {
            print("No results for '\(query)'")
        } else {
            for entry in results {
                print("[\(entry.timestampString)] [\(entry.speakerLabel)] \(entry.text)")
            }
            print("\n\(results.count) result(s)")
        }
    }

    static func showRecent() {
        let config = EdwardConfig.load()
        let storage = Storage(config: config)
        guard let _ = try? storage.open() else {
            print("Cannot open database")
            return
        }

        guard let results = try? storage.recent(limit: 20) else {
            print("Query failed")
            return
        }

        if results.isEmpty {
            print("No transcripts yet")
        } else {
            for entry in results {
                print("[\(entry.timeString)] [\(entry.speakerLabel)] \(entry.text)")
            }
        }
    }

    static func runDiarize() async {
        let config = EdwardConfig.load()
        let storage = Storage(config: config)

        do {
            try storage.open()

            // Check for --date flag, default to today
            let argsArray = Array(CommandLine.arguments.dropFirst())
            var targetDate: Date? = Date()
            if let dateIdx = argsArray.firstIndex(of: "--date"), dateIdx + 1 < argsArray.count {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                targetDate = formatter.date(from: argsArray[dateIdx + 1])
            } else if argsArray.contains("--all") {
                targetDate = nil
            }

            let entries = try storage.entriesWithAudio(date: targetDate)

            if entries.isEmpty {
                print("No audio segments found to diarize")
                return
            }

            print("Found \(entries.count) segments with saved audio")

            let diarizer = OfflineDiarizer(config: config)
            let result = try await diarizer.diarize(entries: entries, storage: storage)

            print("")
            print("Diarization complete:")
            print("  Speakers found: \(result.numSpeakers)")
            print("  Entries updated: \(result.entriesUpdated)")
            print("")
            print("View results: edward recent")
        } catch {
            print("Error: \(error)")
        }
    }

    static func installLaunchAgent() {
        let plistDir = NSHomeDirectory() + "/Library/LaunchAgents"
        let plistPath = plistDir + "/com.edward.daemon.plist"

        let execPath = ProcessInfo.processInfo.arguments[0]

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.edward.daemon</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(execPath)</string>
                <string>start</string>
                <string>--foreground</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(NSHomeDirectory())/.edward/logs/stdout.log</string>
            <key>StandardErrorPath</key>
            <string>\(NSHomeDirectory())/.edward/logs/stderr.log</string>
        </dict>
        </plist>
        """

        do {
            try FileManager.default.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
            try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["load", plistPath]
            try task.run()
            task.waitUntilExit()
            print("Installed and loaded launch agent: \(plistPath)")
        } catch {
            print("Error installing: \(error)")
        }
    }

    static func uninstallLaunchAgent() {
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.edward.daemon.plist"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["unload", plistPath]
        try? task.run()
        task.waitUntilExit()
        try? FileManager.default.removeItem(atPath: plistPath)
        print("Uninstalled launch agent")
    }

    static func printUsage() {
        print("""
        Edward — Always-On Speech Daemon

        Usage: edward <command> [options]

        Commands:
          start [options]       Start the daemon (default: foreground)
            --foreground        Run in foreground (default)
            --language en,he    Comma-separated language hints (default: en)
          stop                  Stop the running daemon
          status                Show daemon status
          tail                  Stream live transcriptions
          recent                Show recent transcriptions
          query <term>          Search transcripts
          diarize [options]     Run offline speaker diarization on saved audio
            --date 2026-03-28   Diarize a specific day (default: today)
            --all               Diarize all saved audio
          install               Install as launchd service (auto-start on login)
          uninstall             Remove launchd service
          help                  Show this help

        Supported languages (52):
          en, zh, ja, ko, he, ar, fr, de, es, pt, ru, it, nl, pl, tr,
          vi, th, id, ms, hi, bn, ta, te, ur, fa, uk, cs, ro, hu, el,
          sv, da, fi, no, bg, hr, sk, sl, sr, lt, lv, et, ka, az, kk,
          uz, mn, my, km, lo, si, ne

        Data:
          Database:    ~/.edward/edward.db
          Transcripts: ~/.edward/transcripts/
          Logs:        ~/.edward/logs/
          Socket:      ~/.edward/edward.sock
          Speakers:    ~/.edward/speakers.json
        """)
    }
}
