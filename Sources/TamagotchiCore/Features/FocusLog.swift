import Foundation
import TamagotchiWire

/// A small local log of completed focus blocks (JSON), for the daily recap.
/// Only blocks that ran to the end are recorded. It follows the history retention:
/// older blocks are dropped, and with history off it lives in memory only.
@MainActor
public final class FocusLog {
    public let fileURL: URL?
    public private(set) var blocks: [FocusBlock] = []
    /// Days to keep; 0 keeps blocks for this run only and nothing on disk.
    public var retentionDays: Int

    /// `fileURL == nil` keeps the log in memory only (tests, previews).
    public init(fileURL: URL?, retentionDays: Int = 7) {
        self.fileURL = fileURL
        self.retentionDays = retentionDays
    }

    public func load(now: Date = Date()) {
        guard retentionDays > 0, let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([FocusBlock].self, from: data) else {
            blocks = []
            return
        }
        blocks = decoded.filter { $0.minutes > 0 && $0.minutes.isFinite }.sorted { $0.endedAt < $1.endedAt }
        prune(now: now)
    }

    public func append(_ block: FocusBlock, now: Date = Date()) {
        guard block.minutes > 0, block.minutes.isFinite else { return }
        blocks.append(block)
        blocks.sort { $0.endedAt < $1.endedAt }
        prune(now: now)
        save()
    }

    /// Blocks that ended within `interval`.
    public func blocks(in interval: DateInterval) -> [FocusBlock] {
        blocks.filter { interval.contains($0.endedAt) }
    }

    public func clear() {
        blocks = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func prune(now: Date) {
        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            blocks.removeAll { $0.endedAt < cutoff }
        }
        if blocks.count > 2_000 { blocks.removeFirst(blocks.count - 2_000) }
    }

    private func save() {
        guard let fileURL else { return }
        guard retentionDays > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        BridgePaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        guard let data = try? Self.encoder.encode(blocks) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        chmod(fileURL.path, 0o600)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
