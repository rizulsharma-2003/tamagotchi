import Darwin
import Foundation

/// Client side of the local event bridge: a Unix domain socket in a private
/// directory. Each event is one connection carrying one newline-terminated JSON
/// line; the app answers with a one-line acknowledgement.
public enum BridgeClient {
    public enum Outcome: Equatable, Sendable {
        /// The app validated and accepted the event.
        case accepted
        /// The app received the event but refused it (invalid, paused, ...).
        case rejected(String)
        /// Nothing is listening, or the exchange did not complete.
        case unavailable(String)
    }

    public static func send(_ line: Data, to socket: URL, timeout: TimeInterval = 0.75) -> Outcome {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable("socket() failed: \(errno)") }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard var address = makeAddress(socket.path) else { return .unavailable("socket path too long") }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .unavailable("not running (\(String(cString: strerror(errno))))") }

        var offset = 0
        while offset < line.count {
            let written = line.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress!.advanced(by: offset), line.count - offset)
            }
            if written <= 0 { return .unavailable("write failed") }
            offset += written
        }
        shutdown(fd, SHUT_WR)

        var reply = [UInt8](repeating: 0, count: 128)
        let count = read(fd, &reply, reply.count)
        guard count > 0 else { return .unavailable("no acknowledgement") }
        let text = String(decoding: reply.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "ok" { return .accepted }
        if text.hasPrefix("rejected") {
            return .rejected(String(text.dropFirst("rejected".count)).trimmingCharacters(in: .whitespaces))
        }
        return .unavailable("unexpected reply")
    }

    public static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}
