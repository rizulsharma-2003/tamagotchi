import Darwin
import Foundation

/// A small bounded journal of events that could not be delivered because the app
/// was not running. The app drains it at launch and marks those events as late,
/// so reactions are never played for stale events and missed time is visible.
public enum EventSpool {
    public static let maxBytes = 512 * 1024

    /// Appends one line. When the spool is full the oldest half is discarded and
    /// the number of discarded events is recorded so the app can report it.
    @discardableResult
    public static func append(_ line: Data, to url: URL, maxBytes: Int = EventSpool.maxBytes) -> Bool {
        guard line.count < maxBytes / 4 else { return false }
        BridgePaths.ensurePrivateDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return false }
        if Int(info.st_size) + line.count > maxBytes {
            guard let existing = readAll(fd: fd, size: Int(info.st_size)) else { return false }
            var lines = existing.split(separator: 0x0A, omittingEmptySubsequences: true)
            var dropped = 0
            var kept: [Data.SubSequence] = []
            for item in lines {
                if let count = droppedMarkerCount(Data(item)) { dropped += count } else { kept.append(item) }
            }
            let removeCount = max(1, kept.count / 2)
            dropped += min(removeCount, kept.count)
            lines = Array(kept.dropFirst(removeCount))
            var rebuilt = Data("{\"spoolDropped\":\(dropped)}\n".utf8)
            for item in lines {
                rebuilt.append(contentsOf: item)
                rebuilt.append(0x0A)
            }
            guard ftruncate(fd, 0) == 0, writeAll(fd: fd, data: rebuilt) else { return false }
        }
        return writeAll(fd: fd, data: line)
    }

    public struct Drained: Sendable {
        public var lines: [Data]
        public var droppedCount: Int
    }

    /// Reads and empties the spool atomically with respect to concurrent appends.
    public static func drain(_ url: URL) -> Drained {
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return Drained(lines: [], droppedCount: 0) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return Drained(lines: [], droppedCount: 0) }
        defer { flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0,
              let data = readAll(fd: fd, size: Int(min(info.st_size, off_t(maxBytes * 2)))) else {
            return Drained(lines: [], droppedCount: 0)
        }
        ftruncate(fd, 0)
        var lines: [Data] = []
        var dropped = 0
        for item in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(item)
            if let count = droppedMarkerCount(line) { dropped += count } else { lines.append(line) }
        }
        return Drained(lines: lines, droppedCount: dropped)
    }

    static func droppedMarkerCount(_ line: Data) -> Int? {
        guard line.starts(with: Data("{\"spoolDropped\":".utf8)),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let count = object["spoolDropped"] as? Int else { return nil }
        return count
    }

    private static func readAll(fd: Int32, size: Int) -> Data? {
        var data = Data(count: size)
        var offset = 0
        while offset < size {
            let count = data.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress!.advanced(by: offset), size - offset, off_t(offset))
            }
            if count <= 0 { break }
            offset += count
        }
        return offset == size ? data : data.prefix(offset)
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count <= 0 { return false }
            offset += count
        }
        return true
    }
}
