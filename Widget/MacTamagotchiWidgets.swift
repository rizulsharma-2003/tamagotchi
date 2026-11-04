import SwiftUI
import WidgetKit

// A desktop / Notification Center widget: Mochi and Claude at a glance.
// Built by scripts/build-app.sh into MacTamagotchi.app/Contents/PlugIns. It runs sandboxed and
// may read exactly one folder, where the app publishes a small status file and a picture:
// ~/Library/Application Support/MacTamagotchi/Widget/

struct WidgetStatus: Codable {
    var headline: String
    var detail: String
    var petName: String
    var companionName: String
    /// working, waiting, done, snag, napping, happy
    var mood: String
    var friendshipLevel: Int
    var updatedAt: Date

    static let placeholder = WidgetStatus(headline: "Claude is working", detail: "Editing files", petName: "Mochi",
                                          companionName: "Claude", mood: "working", friendshipLevel: 2, updatedAt: Date())
}

enum SharedFolder {
    static var url: URL {
        // The sandbox's home is a container; the app writes under the real home.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MacTamagotchi/Widget", isDirectory: true)
    }

    static func load() -> StatusEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let status = (try? Data(contentsOf: url.appendingPathComponent("status.json"))).flatMap { try? decoder.decode(WidgetStatus.self, from: $0) }
        let scene = NSImage(contentsOf: url.appendingPathComponent("scene.png"))
        return StatusEntry(date: Date(), status: status, scene: scene)
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let status: WidgetStatus?
    let scene: NSImage?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), status: .placeholder, scene: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : SharedFolder.load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app asks for a reload when something changes; this is only the fallback.
        completion(Timeline(entries: [SharedFolder.load()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    private var status: WidgetStatus { entry.status ?? WidgetStatus(headline: "Open MacTamagotchi", detail: "to wake Mochi up", petName: "Mochi",
                                                                    companionName: "Claude", mood: "napping", friendshipLevel: 0, updatedAt: Date()) }

    private var tint: Color {
        switch status.mood {
        case "working": return Color(red: 0.89, green: 0.50, blue: 0.35)
        case "waiting": return Color(red: 1.0, green: 0.62, blue: 0.2)
        case "done": return Color(red: 0.33, green: 0.72, blue: 0.5)
        case "snag": return Color(red: 0.9, green: 0.38, blue: 0.38)
        default: return Color(red: 0.62, green: 0.52, blue: 0.75)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scene = entry.scene {
                Image(nsImage: scene)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: family == .systemSmall ? 70 : 92)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(status.headline)
                    .font(.system(size: family == .systemSmall ? 12 : 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack {
                Text(status.detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if family != .systemSmall {
                    HStack(spacing: 1) {
                        ForEach(0..<5, id: \.self) { index in
                            Image(systemName: index < status.friendshipLevel ? "heart.fill" : "heart")
                                .font(.system(size: 8))
                                .foregroundStyle(index < status.friendshipLevel ? Color.pink : Color.secondary.opacity(0.5))
                        }
                    }
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [tint.opacity(0.18), Color(nsColor: .windowBackgroundColor)], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct MochiStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MochiStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Mochi & Claude")
        .description("What Claude Code is up to, with Mochi.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MacTamagotchiWidgets: WidgetBundle {
    var body: some Widget {
        MochiStatusWidget()
    }
}
