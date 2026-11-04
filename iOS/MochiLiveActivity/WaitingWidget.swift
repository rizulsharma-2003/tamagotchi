import SwiftUI
import WidgetKit

/// "Waiting for you" on the Lock Screen (and the Home Screen): how many things, and the first one or two.
/// Mochi Pocket and its notification extension keep the app group's snapshot fresh; this only reads it.
struct WaitingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MochiWaiting", provider: WaitingProvider()) { entry in
            WaitingWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Waiting for you")
        .description("What Mochi found in your mail, calendar and Notion.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .systemSmall])
    }
}

struct WaitingEntry: TimelineEntry {
    let date: Date
    let items: [WaitingSnapshot.Item]
    let known: Bool
}

struct WaitingProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaitingEntry {
        WaitingEntry(date: Date(), items: [
            .init(id: "1", source: "calendar", title: "Standup", detail: "10:00 AM", due: Date().addingTimeInterval(1800).timeIntervalSince1970),
            .init(id: "2", source: "gmail", title: "Amogh", detail: "Wants the deck by tonight"),
        ], known: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (WaitingEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WaitingEntry>) -> Void) {
        // Meetings leave ten minutes after they start, so look again then (or in an hour).
        let now = Date()
        let snapshot = WaitingSnapshot.load()
        let nextDrop = snapshot?.current(at: now).compactMap(\.due).map { $0 + 601 }.filter { $0 > now.timeIntervalSince1970 }.min()
        let refresh = nextDrop.map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry(at: now)], policy: .after(min(refresh, now.addingTimeInterval(3600)))))
    }

    private func entry(at date: Date) -> WaitingEntry {
        let snapshot = WaitingSnapshot.load()
        return WaitingEntry(date: date, items: snapshot?.current(at: date) ?? [], known: snapshot != nil)
    }
}

struct WaitingWidgetView: View {
    let entry: WaitingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: entry.items.isEmpty ? "checkmark" : "tray.full.fill").font(.system(size: 13, weight: .semibold))
                    if !entry.items.isEmpty { Text("\(entry.items.count)").font(.system(.title3, design: .rounded).weight(.bold)) }
                }
            }
            .widgetAccentable()
        case .accessoryInline:
            if let first = entry.items.first {
                Label(entry.items.count == 1 ? line(first) : "\(entry.items.count) waiting · \(line(first))", systemImage: "tray.full")
            } else {
                Label("Nothing waiting", systemImage: "checkmark.circle")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full.fill")
                    Text(entry.items.isEmpty ? "All clear" : "\(entry.items.count) waiting").fontWeight(.semibold)
                }
                .font(.system(.headline, design: .rounded))
                .widgetAccentable()
                if entry.items.isEmpty {
                    Text(entry.known ? "Mochi will tell you when something comes in." : "Open Mochi once to see updates here.")
                        .font(.caption).lineLimit(2)
                } else {
                    ForEach(entry.items.prefix(2)) { item in
                        Text(rowText(item)).font(.caption).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "tray.full.fill").foregroundStyle(MochiStyle.accent)
                    Text(entry.items.isEmpty ? "All clear" : "\(entry.items.count) waiting")
                        .font(.system(.headline, design: .rounded))
                }
                if entry.items.isEmpty {
                    Text("Nothing waiting.").font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                }
                ForEach(entry.items.prefix(3)) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        Text((item.vip == true ? "★ " : "") + item.title).font(.system(.caption, design: .rounded).weight(.semibold)).lineLimit(1)
                        Text(item.detail).font(.system(.caption2, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func line(_ item: WaitingSnapshot.Item) -> String {
        item.source == "calendar" ? "\(item.title) \(item.detail)" : item.title
    }

    private func rowText(_ item: WaitingSnapshot.Item) -> String {
        let mark = switch item.source {
        case "calendar": "📅 "
        case "notion": "☑︎ "
        default: item.vip == true ? "★ " : "✉︎ "
        }
        return mark + item.title + (item.source == "calendar" ? " · " + item.detail : ": " + item.detail)
    }
}
