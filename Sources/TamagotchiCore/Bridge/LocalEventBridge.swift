import Darwin
import Foundation
import TamagotchiWire

/// The app side of the hook → app transport.
///
/// - Unix domain socket inside a 0700 directory, socket file mode 0600; no network port.
/// - Every connection's peer is checked with `getpeereid`; only the current user is accepted.
/// - One bounded line per connection, a short read deadline and a connection cap.
/// - Every line is schema-validated before it reaches the rest of the app.
/// - Runs on its own queue: UI work can never slow down a Claude Code hook.
public final class LocalEventBridge: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case listening(String)
        case failed(String)

        public var isListening: Bool {
            if case .listening = self { return true }
            return false
        }
    }

    public struct Stats: Equatable, Sendable {
        public var accepted = 0
        public var rejected = 0
        public var refusedPeers = 0
        public var overflowed = 0
        public var lastRejection: String?
        public var lastAcceptedAt: Date?
        public var restarts = 0
    }

    public let socketURL: URL
    public let maxConnections: Int
    public let readTimeout: TimeInterval
    public let healthInterval: TimeInterval

    private let queue = DispatchQueue(label: "MacTamagotchi.LocalEventBridge")
    private var listenFD: Int32 = -1
    private var socketInode: ino_t = 0
    private var acceptSource: DispatchSourceRead?
    private var healthTimer: DispatchSourceTimer?
    private var activeConnections = 0
    private var state: State = .stopped
    private var stats = Stats()
    private var deliver: (@Sendable (WireEvent) -> Void)?
    private var stateChanged: (@Sendable (State, Stats) -> Void)?

    public init(socketURL: URL, maxConnections: Int = 16, readTimeout: TimeInterval = 2, healthInterval: TimeInterval = 5) {
        self.socketURL = socketURL
        self.maxConnections = maxConnections
        self.readTimeout = readTimeout
        self.healthInterval = healthInterval
    }

    /// Starts listening. `deliver` receives validated events on the bridge queue.
    public func start(
        deliver: @escaping @Sendable (WireEvent) -> Void,
        stateChanged: @escaping @Sendable (State, Stats) -> Void
    ) {
        queue.async {
            self.deliver = deliver
            self.stateChanged = stateChanged
            self.openListener()
            self.startHealthTimer()
        }
    }

    public func stop() {
        queue.sync {
            self.healthTimer?.cancel()
            self.healthTimer = nil
            self.closeListener(unlink: true)
            self.setState(.stopped)
        }
    }

    public func currentState() -> (State, Stats) {
        queue.sync { (state, stats) }
    }

    // MARK: Listener

    private func setState(_ newState: State) {
        state = newState
        stateChanged?(newState, stats)
    }

    private func openListener() {
        closeListener(unlink: false)
        let directory = socketURL.deletingLastPathComponent()
        guard BridgePaths.ensurePrivateDirectory(directory) else {
            setState(.failed("Cannot create \(directory.path)"))
            return
        }
        let path = socketURL.path
        if FileManager.default.fileExists(atPath: path) {
            // A live listener means another instance owns the bridge; never steal it.
            if case .accepted = BridgeClient.send(Self.probeLine(), to: socketURL, timeout: 0.3) {
                setState(.failed("Another MacTamagotchi instance is already listening"))
                return
            }
            unlink(path)
        }
        guard var address = BridgeClient.makeAddress(path) else {
            setState(.failed("Socket path is too long"))
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            setState(.failed("socket() failed: \(String(cString: strerror(errno)))"))
            return
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            setState(.failed("bind() failed: \(reason)"))
            return
        }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            setState(.failed("listen() failed: \(reason)"))
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var info = stat()
        socketInode = stat(path, &info) == 0 ? info.st_ino : 0
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        setState(.listening(path))
    }

    private func closeListener(unlink shouldUnlink: Bool) {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0, shouldUnlink {
            var info = stat()
            if stat(socketURL.path, &info) == 0, info.st_ino == socketInode {
                unlink(socketURL.path)
            }
        }
        listenFD = -1
    }

    /// Recreates the socket if its file disappeared or was replaced.
    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + healthInterval, repeating: healthInterval, leeway: .milliseconds(Int(healthInterval * 300)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var info = stat()
            let intact = self.listenFD >= 0 && stat(self.socketURL.path, &info) == 0 && info.st_ino == self.socketInode
            if !intact {
                self.stats.restarts += 1
                self.openListener()
            }
        }
        timer.resume()
        healthTimer = timer
    }

    // MARK: Connections

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                stats.refusedPeers += 1
                close(client)
                continue
            }
            guard activeConnections < maxConnections else {
                stats.overflowed += 1
                reply(client, "rejected busy")
                close(client)
                continue
            }
            handle(client)
        }
    }

    /// Per-connection state; only touched on the bridge queue.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        var buffer = Data()
        var finished = false
        var source: DispatchSourceRead?

        init(fd: Int32) { self.fd = fd }
    }

    private func handle(_ fd: Int32) {
        activeConnections += 1
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let connection = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        connection.source = source
        source.setEventHandler { [weak self] in
            self?.readAvailable(connection)
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            self?.activeConnections -= 1
        }
        source.resume()
        queue.asyncAfter(deadline: .now() + readTimeout) { [weak self] in
            guard let self, !connection.finished else { return }
            self.stats.rejected += 1
            self.stats.lastRejection = "read timeout"
            self.finish(connection, line: nil)
        }
    }

    private func readAvailable(_ connection: Connection) {
        guard !connection.finished else { return }
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(connection.fd, &chunk, chunk.count)
            if count > 0 {
                connection.buffer.append(contentsOf: chunk.prefix(count))
                if connection.buffer.count > EventSchemaValidator.maxLineBytes {
                    reject(connection.fd, .tooLarge(connection.buffer.count))
                    finish(connection, line: nil)
                    return
                }
                if let newline = connection.buffer.firstIndex(of: 0x0A) {
                    finish(connection, line: connection.buffer.prefix(upTo: newline))
                    return
                }
            } else if count == 0 {
                finish(connection, line: connection.buffer.isEmpty ? nil : connection.buffer)
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(connection, line: nil)
                return
            }
        }
    }

    private func finish(_ connection: Connection, line: Data?) {
        guard !connection.finished else { return }
        connection.finished = true
        if let line { process(Data(line), fd: connection.fd) }
        connection.source?.cancel()
        connection.source = nil
    }

    private func process(_ line: Data, fd: Int32) {
        do {
            let event = try EventSchemaValidator.decode(line)
            stats.accepted += 1
            stats.lastAcceptedAt = Date()
            reply(fd, "ok")
            deliver?(event)
            stateChanged?(state, stats)
        } catch let rejection as EventSchemaValidator.Rejection {
            reject(fd, rejection)
        } catch {
            reject(fd, .malformed("unknown"))
        }
    }

    private func reject(_ fd: Int32, _ rejection: EventSchemaValidator.Rejection) {
        stats.rejected += 1
        stats.lastRejection = rejection.description
        reply(fd, "rejected \(rejection.code)")
        stateChanged?(state, stats)
    }

    private func reply(_ fd: Int32, _ text: String) {
        let bytes = Array((text + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private static func probeLine() -> Data {
        var event = WireEvent(id: "probe-\(UUID().uuidString.lowercased())", ts: Date().timeIntervalSince1970, origin: .ping, event: "Ping")
        event.helperVersion = "app-probe"
        return (try? event.encodedLine()) ?? Data()
    }
}
