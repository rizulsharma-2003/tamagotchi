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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The computer this phone is paired with, by name ("your Mac", "your PC").
    private var host: LinkHostName { PocketLink.shared.host }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) {
                    titleButton
                    Spacer(minLength: Theme.Space.xs)
                    headerButtons
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    titleButton
                    HStack(spacing: Theme.Space.s) { headerButtons }
                }
            }
            if let headline = pending.headline, !headline.isEmpty {
                Text(headline).font(.mochi(.subheadline)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if waiting.isEmpty {
                Label {
                    Text("Nothing waiting. \(petName) will tell you when something comes in.")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
                }
                .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
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
                        if item.id != waiting.prefix(Self.shown).last?.id {
                            Divider().overlay(Theme.stroke).padding(.leading, 44)
                        }
                    }
                }
            }
            if waiting.count > Self.shown || historyCount > 0 {
                Button(action: open) {
                    HStack {
                        Text(waiting.count > Self.shown ? "See all \(waiting.count) and earlier updates" : "See earlier updates")
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .font(.mochi(.subheadline, .semibold))
                    .foregroundStyle(Theme.tint)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(minHeight: Theme.touch)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous).fill(Theme.sunken))
                    .contentShape(Rectangle())
                }
                .buttonStyle(ClayPressStyle())
            }
            if let asked = cloudAskedAt, Date().timeIntervalSince(asked) < 300,
               (pending.lookedAt ?? 0) < asked.timeIntervalSince1970 {
                Label("Mochi Cloud is checking. Results arrive as a notification in a minute or two.", systemImage: "cloud.fill")
                    .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
            }
            if let cloudError {
                Label(cloudError, systemImage: "exclamationmark.triangle.fill")
                    .font(.mochi(.footnote, .medium)).foregroundStyle(Theme.warning)
            }
            if !cloudAvailable {
                Label(cloudSeen
                      ? "Mochi Cloud keeps checking while \(host.yours) is off. Add its API trigger on \(host.yours) (Settings › Agent › Mochi Cloud) so Check now works then too."
                      : "Only \(host.yours) can check right now. Set up Mochi Cloud on \(host.yours) (Settings › Agent) to check while it's off.",
                      systemImage: cloudSeen ? "cloud" : "cloud.slash")
                    .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    checkedText
                    checkButton
                }
            } else {
                HStack(spacing: Theme.Space.s) {
                    checkedText
                    Spacer(minLength: Theme.Space.xs)
                    checkButton
                }
            }
        }
        .mochiCard()
    }

    private var titleButton: some View {
        Button(action: open) {
            HStack(spacing: Theme.Space.s) {
                IconTile(symbol: "tray.full.fill", tint: Theme.tint)
                Text("Waiting for you").font(.mochi(.headline)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: true, vertical: false)
                if !waiting.isEmpty {
                    Text("\(waiting.count)")
                        .font(.mochi(.footnote, .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.tint))
                        .accessibilityLabel("\(waiting.count) waiting")
                }
            }
            .frame(minHeight: Theme.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens every update")
    }

    @ViewBuilder
    private var headerButtons: some View {
        RoundIconButton(symbol: speaking ? "stop.fill" : "speaker.wave.2.fill",
                        label: speaking ? "Stop reading" : "Read out loud", prominent: speaking, action: speak)
        RoundIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Open all updates", tint: Theme.inkSecondary,
                        action: open)
    }

    @ViewBuilder
    private var checkedText: some View {
        if let looked = pending.lookedAt {
            Text("Checked by \(checkedBy == "cloud" ? "Mochi Cloud" : host.yours) · \(Date(timeIntervalSince1970: looked).formatted(.relative(presentation: .named)))")
                .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checkButton: some View {
        Button(action: checkNow) {
            HStack(spacing: 6) {
                if checking { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                Text(checking ? "Checking…" : "Check now").fixedSize()
            }
            .font(.mochi(.subheadline, .semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(checking)
    }
}
