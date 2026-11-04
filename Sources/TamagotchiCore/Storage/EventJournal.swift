import Foundation
import TamagotchiWire

/// A small local history of sanitized events (JSON Lines).
///
/// - Simulated events are refused outright: they can never enter the real history.
/// - Full project paths are stripped unless the user opted in.
/// - Retention is enforced by age and by count.
@MainActor
public final class EventJournal {
    public struct Retention: Equatable, Sendable {
        public var maxAge: TimeInterval
        public var maxEvents: Int

        public init(days: Int, maxEvents: Int = 2_000) {
            self.maxAge = TimeInterval(max(0, days)) * 86_400
            self.maxEvents = max(0, maxEvents)
        }
    }

    public let fileURL: URL
    public var retention: Retention
    public var storeProjectPaths: Bool
    private var events: [CompanionEvent] = []
    private var knownIDs: Set<String> = []
    private var appendedSinceCompaction = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public init(fileURL: URL, retention: Retention, storeProjectPaths: Bool = false) {
        self.fileURL = fileURL
        self.retention = retention
        self.storeProjectPaths = storeProjectPaths
    }

    /// Loads history from disk, discarding anything malformed or out of retention.
    public func load(now: Date = Date()) {
        events = []
        knownIDs = []
        guard let data = try? Data(contentsOf: fileURL) else { return }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let event = try? decoder.decode(CompanionEvent.self, from: Data(line)),
                  !event.isSimulated,
                  !knownIDs.contains(event.id) else { continue }
            events.append(event)
            knownIDs.insert(event.id)
        }
        events.sort { $0.timestamp < $1.timestamp }
        if applyRetention(now: now) { rewrite() }
    }

    public var all: [CompanionEvent] { events }

    public func contains(id: String) -> Bool { knownIDs.contains(id) }

    public func recent(_ count: Int, session: String? = nil) -> [CompanionEvent] {
        let filtered = session.map { id in events.filter { $0.sessionID == id } } ?? events
        return Array(filtered.suffix(count))
    }

    public func events(since date: Date) -> [CompanionEvent] {
        events.filter { $0.timestamp >= date }
    }

    /// Appends an event. Returns false for simulated or duplicate events.
    @discardableResult
    public func append(_ event: CompanionEvent, now: Date = Date()) -> Bool {
        guard !event.isSimulated, !knownIDs.contains(event.id) else { return false }
        var stored = event
        if !storeProjectPaths { stored.project?.path = nil }
        events.append(stored)
        knownIDs.insert(stored.id)
        if retention.maxEvents == 0 || retention.maxAge == 0 {
            // History disabled: keep in memory for this run only.
            return true
        }
        if let line = try? encoder.encode(stored) {
            appendLine(line)
        }
        appendedSinceCompaction += 1
        if appendedSinceCompaction >= 200 || events.count > retention.maxEvents + 200 {
            appendedSinceCompaction = 0
            if applyRetention(now: now) { rewrite() }
        }
        return true
    }

    /// Re-applies retention now (e.g. after the user changes it).
    public func enforceRetention(now: Date = Date()) {
        if applyRetention(now: now) || retention.maxAge == 0 || retention.maxEvents == 0 { rewrite() }
    }

    public func clear() {
        events = []
        knownIDs = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Returns true when something was removed.
    private func applyRetention(now: Date) -> Bool {
        let before = events.count
        if retention.maxAge > 0 {
            let cutoff = now.addingTimeInterval(-retention.maxAge)
            events.removeAll { $0.timestamp < cutoff }
        }
        if events.count > retention.maxEvents {
            events.removeFirst(events.count - retention.maxEvents)
        }
        if events.count != before {
            knownIDs = Set(events.map(\.id))
            return true
        }
        return false
    }

    private func rewrite() {
        BridgePaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        if retention.maxAge == 0 || retention.maxEvents == 0 {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        var data = Data()
        for event in events {
            var stored = event
            if !storeProjectPaths { stored.project?.path = nil }
            if let line = try? encoder.encode(stored) {
                data.append(line)
                data.append(0x0A)
            }
        }
        try? data.write(to: fileURL, options: [.atomic])
        chmod(fileURL.path, 0o600)
    }

    private func appendLine(_ line: Data) {
        BridgePaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        var data = line
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }
}
