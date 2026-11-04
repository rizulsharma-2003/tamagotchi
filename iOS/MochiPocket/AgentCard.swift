import SwiftUI
import TamagotchiCore

/// What's waiting for you: new mail, coming meetings and Notion tasks, from your Mac or Mochi Cloud. The top few
/// show here; tap the card (or "See all") to open every update, or the speaker to hear them.
struct AgentCard: View {
    let pending: AgentPending
    /// The card's items you haven't marked done.
    let waiting: [AgentNote]
    let petName: String
    let checking: Bool
    var speaking = false
    /// Earlier updates kept on this iPhone (for "See all").
    var historyCount = 0
    /// When "Check now" went to Mochi Cloud.
    var cloudAskedAt: Date?
    /// Mochi Cloud is set up, so "Check now" works while the Mac is off.
    var cloudAvailable = false
    /// Mochi Cloud's news has reached this phone before.
    var cloudSeen = false
    /// "mac" or "cloud": who made the latest update.
    var checkedBy: String?
    /// Why the last request to Mochi Cloud failed.
    var cloudError: String?
    /// Mochi Cloud can draft replies (it's set up).
    var canDraft = false
    let speak: () -> Void
    let open: () -> Void
    let checkNow: () -> Void
    let markDone: (AgentNote) -> Void
    var draft: (AgentNote) -> Void = { _ in }

    private static let shown = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.full.fill").foregroundStyle(MochiStyle.accent)
                        Text("Waiting for you").font(.system(.headline, design: .rounded)).foregroundStyle(.primary)
                        if !waiting.isEmpty {
                            Text("\(waiting.count)")
                                .font(.system(.caption, design: .rounded).weight(.bold))
                                .foregroundStyle(MochiStyle.accent)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(MochiStyle.accent.opacity(0.13)))
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Button(action: speak) {
                    Image(systemName: speaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(MochiStyle.accent.opacity(speaking ? 0.22 : 0.12)))
                }
                .accessibilityLabel(speaking ? "Stop reading" : "Read out loud")
                Button(action: open) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.black.opacity(0.05)))
                }
                .accessibilityLabel("Open all updates")
            }
            if let headline = pending.headline, !headline.isEmpty {
                Text(headline).font(.system(.subheadline, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if waiting.isEmpty {
                Text("Nothing waiting. \(petName) will tell you when something comes in.")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(waiting.prefix(Self.shown)) { item in
                        UpdateRow(note: item) { markDone(item) }
                            .contextMenu {
                                Button { markDone(item) } label: { Label("Mark as done", systemImage: "checkmark.circle") }
                                if item.threadID != nil, item.link != nil {
                                    Button { OpenLinks.openGmail(thread: item.threadID ?? "", fallback: item.link.flatMap(URL.init(string:))) } label: {
                                        Label("Open Gmail", systemImage: "envelope")
                                    }
                                    Button { OpenLinks.openInBrowser(item) } label: { Label("Open This Email in Safari", systemImage: "safari") }
                                }
                                if item.threadID != nil, canDraft {
                                    Button { draft(item) } label: { Label("Draft a reply…", systemImage: "arrowshape.turn.up.left") }
                                }
                            }
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                        if item.id != waiting.prefix(Self.shown).last?.id { Divider() }
                    }
                }
            }
            if waiting.count > Self.shown || historyCount > 0 {
                Button(action: open) {
                    Label(waiting.count > Self.shown ? "See all \(waiting.count) and earlier updates" : "See earlier updates",
                          systemImage: "list.bullet.rectangle")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MochiStyle.accent)
            }
            if let asked = cloudAskedAt, Date().timeIntervalSince(asked) < 300,
               (pending.lookedAt ?? 0) < asked.timeIntervalSince1970 {
                Label("Mochi Cloud is checking. Results arrive as a notification in a minute or two.", systemImage: "cloud")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            }
            if let cloudError {
                Label(cloudError, systemImage: "exclamationmark.triangle")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.orange)
            }
            if !cloudAvailable {
                Label(cloudSeen
                      ? "Mochi Cloud keeps checking while your Mac is off. Add its API trigger on your Mac (Settings › Agent › Mochi Cloud) so Check now works then too."
                      : "Only your Mac can check right now. Set up Mochi Cloud on your Mac (Settings › Agent) to check while it's off.",
                      systemImage: cloudSeen ? "cloud" : "cloud.slash")
                    .font(.system(.caption2, design: .rounded)).foregroundStyle(.tertiary)
            }
            HStack {
                if let looked = pending.lookedAt {
                    Text("Checked by \(checkedBy == "cloud" ? "Mochi Cloud" : "your Mac") · \(Date(timeIntervalSince1970: looked).formatted(.relative(presentation: .named)))")
                        .font(.system(.caption2, design: .rounded)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(action: checkNow) {
                    Label(checking ? "Checking…" : "Check now", systemImage: "arrow.clockwise")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(checking)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.85)))
    }
}
