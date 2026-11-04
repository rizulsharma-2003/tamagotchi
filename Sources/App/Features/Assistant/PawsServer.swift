import Darwin
import Foundation
import TamagotchiCore
import TamagotchiWire

/// The app's end of Mochi's tools ("paws"): the helper Claude session reaches it through
/// `mactamagotchi-hook paws`, which relays MCP over a Unix socket.
///
/// - Socket file mode 0600 in the app's 0700 run directory; peers must be the current user.
/// - A connection must open with the one-time token of the helper session the app started;
///   anything else is closed. The token changes with every helper session.
/// - Lines are capped; tool calls run on the main actor, replies go back on this queue.
final class PawsServer: @unchecked Sendable {
    typealias Perform = @Sendable (_ name: String, _ arguments: AnyJSON) async -> (text: String, isError: Bool)

    private let socketURL: URL
    private let core: MCPServerCore
    private let perform: Perform
    private let queue = DispatchQueue(label: "MacTamagotchi.Paws")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var token: String?
    private static let maxLineBytes = 1 << 20

    init(socketURL: URL, core: MCPServerCore, perform: @escaping Perform) {
        self.socketURL = socketURL
        self.core = core
        self.perform = perform
    }

    /// Accept connections that present this token (nil refuses everyone).
    func expect(token: String?) {
        queue.sync { self.token = token }
    }

    var isListening: Bool { queue.sync { listenFD >= 0 } }

    /// Starts listening if needed; false when the socket could not be opened.
    @discardableResult
    func start() -> Bool {
        queue.sync {
            if listenFD >= 0 { return true }
            let directory = socketURL.deletingLastPathComponent()
            guard BridgePaths.ensurePrivateDirectory(directory), var address = BridgeClient.makeAddress(socketURL.path) else { return false }
            unlink(socketURL.path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let previousMask = umask(0o077)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            umask(previousMask)
            guard bound == 0, listen(fd, 4) == 0 else {
                close(fd)
                return false
            }
            chmod(socketURL.path, 0o600)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            listenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { close(fd) }
            source.resume()
            acceptSource = source
            return true
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 { unlink(socketURL.path) }
            listenFD = -1
            token = nil
        }
    }

    // MARK: Connections

    /// Only touched on the server queue.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        var buffer = Data()
        var authenticated = false
        var closed = false
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), token != nil else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let connection = Connection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            connection.source = source
            source.setEventHandler { [weak self] in self?.readAvailable(connection) }
            source.setCancelHandler { close(fd) }
            source.resume()
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                if !connection.authenticated { self?.finish(connection) }
            }
        }
    }

    private func readAvailable(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while !connection.closed {
            let count = read(connection.fd, &chunk, chunk.count)
            if count > 0 {
                connection.buffer.append(contentsOf: chunk.prefix(count))
                while let newline = connection.buffer.firstIndex(of: 0x0A) {
                    let line = Data(connection.buffer[connection.buffer.startIndex..<newline])
                    connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
                    handle(line, on: connection)
                    if connection.closed { return }
                }
                if connection.buffer.count > Self.maxLineBytes { finish(connection) }
            } else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                finish(connection)
            } else {
                return
            }
        }
    }

    private func handle(_ line: Data, on connection: Connection) {
        guard connection.authenticated else {
            guard let expected = token, AnyJSON.parse(line)?["auth"]?.stringValue.map({ constantTimeEqual($0, expected) }) == true else {
                finish(connection)
                return
            }
            connection.authenticated = true
            return
        }
        switch core.handle(line) {
        case .reply(let data):
            write(data, to: connection)
        case .ignore:
            break
        case .call(let id, let name, let arguments):
            let perform = perform
            Task {
                let result = await perform(name, arguments)
                self.queue.async {
                    self.write(MCPServerCore.toolResult(id: id, text: result.text, isError: result.isError), to: connection)
                }
            }
        }
    }

    private func write(_ data: Data, to connection: Connection) {
        guard !connection.closed else { return }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(connection.fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                usleep(2000)
            } else {
                finish(connection)
                return
            }
        }
    }

    private func finish(_ connection: Connection) {
        guard !connection.closed else { return }
        connection.closed = true
        connection.source?.cancel()
        connection.source = nil
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
