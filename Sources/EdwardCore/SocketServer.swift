import Foundation

/// Unix domain socket server for broadcasting transcriptions to connected clients
public final class SocketServer {
    private let socketPath: String
    private var serverFd: Int32 = -1
    private var clientFds: [Int32] = []
    private let lock = NSLock()
    private var listenThread: Thread?
    private var isRunning = false

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func start() throws {
        // Remove existing socket file
        unlink(socketPath)

        // Create socket
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw EdwardError.storageError("Cannot create socket: \(String(cString: strerror(errno)))")
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFd)
            throw EdwardError.storageError("Cannot bind socket: \(String(cString: strerror(errno)))")
        }

        // Listen
        guard Darwin.listen(serverFd, 5) == 0 else {
            close(serverFd)
            throw EdwardError.storageError("Cannot listen on socket: \(String(cString: strerror(errno)))")
        }

        // Set non-blocking for accept
        let flags = fcntl(serverFd, F_GETFL)
        _ = fcntl(serverFd, F_SETFL, flags | O_NONBLOCK)

        isRunning = true

        // Accept loop in background thread
        listenThread = Thread {
            while self.isRunning {
                var clientAddr = sockaddr_un()
                var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(self.serverFd, sockPtr, &clientLen)
                    }
                }
                if clientFd >= 0 {
                    self.lock.lock()
                    self.clientFds.append(clientFd)
                    self.lock.unlock()
                    log.info("Socket client connected (fd=\(clientFd))")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        listenThread?.start()

        log.info("Socket server started at \(socketPath)")
    }

    /// Broadcast a transcript entry as a JSON line to all connected clients
    public func broadcast(_ entry: TranscriptEntry) {
        let json = entry.toJSON() + "\n"
        guard let data = json.data(using: .utf8) else { return }

        lock.lock()
        var deadClients: [Int32] = []

        for fd in clientFds {
            let result = data.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress!, buf.count)
            }
            if result <= 0 {
                deadClients.append(fd)
            }
        }

        // Remove dead clients
        for fd in deadClients {
            close(fd)
            clientFds.removeAll { $0 == fd }
            log.debug("Socket client disconnected (fd=\(fd))")
        }
        lock.unlock()
    }

    public func stop() {
        isRunning = false
        lock.lock()
        for fd in clientFds {
            close(fd)
        }
        clientFds.removeAll()
        lock.unlock()

        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
        log.info("Socket server stopped")
    }

    public var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clientFds.count
    }
}
