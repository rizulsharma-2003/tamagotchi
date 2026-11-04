import Foundation

/// "Waiting for you" as the Lock Screen widget and Siri see it. Mochi Pocket writes it whenever the card or
/// what you marked done changes, and the notification extension whenever news arrives (so the widget is fresh
/// even when the app hasn't run). It lives in the app group, on this iPhone only.
struct WaitingSnapshot: Codable, Equatable {
    /// The fields of a Pending card item (an `AgentNote`) that the widget shows.
    struct Item: Codable, Equatable, Identifiable {
        var id: String
        var source: String
        var title: String
        var detail: String
        var important: Bool?
        var at: Double?
        var due: Double?
        var link: String?
        var subject: String?
        var vip: Bool?

        init(id: String, source: String, title: String, detail: String, important: Bool? = nil, at: Double? = nil,
             due: Double? = nil, link: String? = nil, subject: String? = nil, vip: Bool? = nil) {
            self.id = id
            self.source = source
            self.title = title
            self.detail = detail
            self.important = important
            self.at = at
            self.due = due
            self.link = link
            self.subject = subject
            self.vip = vip
        }
    }

    var headline: String?
    var items: [Item]
    var updatedAt: Double

    static let group = "group.com.insideedge.mochi"
    static let key = "waiting"
    /// Item id → when you marked it done (written by the app).
    static let doneKey = "doneIDs"
    static let maxItems = 8

    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func load() -> WaitingSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WaitingSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults?.set(data, forKey: Self.key)
    }

    static var done: [String: Double] { defaults?.dictionary(forKey: doneKey) as? [String: Double] ?? [:] }

    /// What's still ahead: not done, and meetings until ten minutes after they start.
    func current(at now: Date = Date(), done: [String: Double] = WaitingSnapshot.done) -> [Item] {
        let time = now.timeIntervalSince1970
        return items.filter { done[$0.id] == nil && ($0.due.map { $0 > time - 600 } ?? true) }
    }

    /// A notification's card: Mochi Cloud's hourly finds ("cloud") add to what's there; anything else is the whole card.
    static func receiving(card: [String: Any], previous: WaitingSnapshot?, now: Date = Date()) -> WaitingSnapshot? {
        guard let raw = card["items"] as? [Any], JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return nil }
        let headline = card["headline"] as? String
        guard card["origin"] as? String == "cloud", let previous else {
            return WaitingSnapshot(headline: headline, items: Array(items.prefix(maxItems)), updatedAt: now.timeIntervalSince1970)
        }
        let ids = Set(items.map(\.id))
        let merged = items + previous.items.filter { !ids.contains($0.id) }
        return WaitingSnapshot(headline: items.isEmpty ? previous.headline : (headline ?? previous.headline),
                               items: Array(merged.prefix(maxItems)), updatedAt: now.timeIntervalSince1970)
    }
}
