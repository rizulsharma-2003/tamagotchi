import Foundation
import Observation
import TamagotchiCore
import WidgetKit

/// Everything Mochi has told you on this iPhone in the last week, and what you've marked done. Kept in the
/// app's own Documents folder; what you mark done also goes to your Mac through Mochi Link ("phoneDone"), and
/// what you mark done there comes back ("macDone"), so each item is done everywhere.
@MainActor
@Observable
final class UpdatesStore {
    static let shared = UpdatesStore()

    struct Entry: Codable, Identifiable, Equatable {
        var note: AgentNote
        /// When it first reached this iPhone (Unix time).
        var firstSeen: Double
        var id: String { note.id }
    }

    /// Newest first.
    private(set) var entries: [Entry] = []
    /// Item id → when you marked it done.
    private(set) var done: [String: Double] = [:]

    /// Mac marks already taken in, so undoing one here sticks.
    private var fromMac: [String: Double] = [:]
    /// The card as it stands, for the widget and Siri.
    private var card: AgentPending?

    private static let keep: TimeInterval = 7 * 86_400
    private static let maxEntries = 300
    private struct Saved: Codable {
        var entries: [Entry]
        var done: [String: Double]
        var fromMac: [String: Double]?
    }

    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("updates.json")

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            entries = saved.entries
            done = saved.done
            fromMac = saved.fromMac ?? [:]
        }
    }

    /// The items of a new Pending card: new ones join the history, known ones get their latest words.
    func record(_ notes: [AgentNote]) {
        let now = Date().timeIntervalSince1970
        var changed = false
        for note in notes {
            if let index = entries.firstIndex(where: { $0.id == note.id }) {
                if entries[index].note != note {
                    entries[index].note = note
                    changed = true
                }
            } else {
                entries.insert(Entry(note: note, firstSeen: now), at: 0)
                changed = true
            }
        }
        guard changed else { return }
        prune(now: now)
        save()
    }

    func isDone(_ id: String) -> Bool { done[id] != nil }

    func toggleDone(_ id: String) {
        done[id] = done[id] == nil ? Date().timeIntervalSince1970.rounded() : nil
        save()
        shareDone()
        publishSnapshot()
    }

    func markDone(_ ids: [String]) {
        let now = Date().timeIntervalSince1970.rounded()
        for id in ids where done[id] == nil { done[id] = now }
        save()
        shareDone()
        publishSnapshot()
    }

    /// What you marked done on your Mac (through Mochi Link): done here too, once.
    func applyMacDone(_ list: AgentDoneList) {
        let new = list.trimmed().ids.filter { fromMac[$0.key] == nil }
        guard !new.isEmpty else { return }
        for (id, at) in new {
            fromMac[id] = at
            if done[id] == nil { done[id] = at }
        }
        save()
        publishSnapshot()
    }

    /// The card's items you haven't marked done.
    func waiting(in pending: AgentPending?) -> [AgentNote] {
        (pending?.items ?? []).filter { done[$0.id] == nil }
    }

    /// What's waiting right now, for Siri: the card if the app has it, else the widget's snapshot.
    func waitingNow() -> [AgentNote] {
        if let card { return waiting(in: card) }
        guard let snapshot = WaitingSnapshot.load(), let data = try? JSONEncoder().encode(snapshot.current(done: done)),
              let notes = try? JSONDecoder().decode([AgentNote].self, from: data) else { return [] }
        return notes
    }

    /// A new card from the Mac or Mochi Cloud.
    func cardChanged(_ card: AgentPending) {
        self.card = card
        record(card.items)
        publishSnapshot()
    }

    private func shareDone() {
        let linkStore = MochiLink.store
        linkStore.set(AgentDoneList(ids: done).trimmed().json, for: .phoneDone)
    }

    /// The Lock Screen widget's copy of the card (and the done list the notification extension checks).
    private func publishSnapshot() {
        let defaults = WaitingSnapshot.defaults
        defaults?.set(AgentDoneList(ids: done).trimmed().ids, forKey: WaitingSnapshot.doneKey)
        if let card, card.enabled {
            let items = (try? JSONEncoder().encode(Array(waiting(in: card).prefix(WaitingSnapshot.maxItems))))
                .flatMap { try? JSONDecoder().decode([WaitingSnapshot.Item].self, from: $0) } ?? []
            let snapshot = WaitingSnapshot(headline: card.headline, items: items, updatedAt: Date().timeIntervalSince1970)
            if snapshot.items != WaitingSnapshot.load()?.items || snapshot.headline != WaitingSnapshot.load()?.headline { snapshot.save() }
        } else if card != nil {
            defaults?.removeObject(forKey: WaitingSnapshot.key)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Earlier updates by day, newest day first, leaving out what's on the card now.
    func history(excluding ids: Set<String>, calendar: Calendar = .current) -> [(day: Date, entries: [Entry])] {
        let earlier = entries.filter { !ids.contains($0.id) }
        let byDay = Dictionary(grouping: earlier) { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.firstSeen)) }
        return byDay.keys.sorted(by: >).map { day in (day, byDay[day]!.sorted { $0.firstSeen > $1.firstSeen }) }
    }

    private func prune(now: Double) {
        entries = Array(entries.filter { now - $0.firstSeen < Self.keep }.prefix(Self.maxEntries))
        let ids = Set(entries.map(\.id))
        // Done marks stay a week even for items this iPhone hasn't seen (marked on the Mac first).
        done = done.filter { ids.contains($0.key) || now - $0.value < Self.keep }
        fromMac = fromMac.filter { now - $0.value < Self.keep }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(entries: entries, done: done, fromMac: fromMac)) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
