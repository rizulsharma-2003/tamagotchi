import AppIntents
import SwiftUI
import TamagotchiCore

/// "Hey Siri, what's waiting in Mochi?": Mochi reads it out itself (Siri stays silent when you're looking at
/// the phone) and Siri shows the list. An audio intent, so the app may speak from the background.
struct WhatsWaitingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "What's Waiting"
    static let description = IntentDescription("Hear what's waiting for you: new mail, coming meetings and Notion tasks.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        MacLink.shared.start()
        let items = UpdatesStore.shared.waitingNow()
        UpdatesReader.shared.speak(items, after: 1.2)
        let dialog: IntentDialog = items.isEmpty ? "Nothing is waiting for you." : "Here's what's waiting."
        return .result(dialog: dialog, view: WaitingSnippet(items: items))
    }
}

/// Siri's view of the list.
struct WaitingSnippet: View {
    let items: [AgentNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.prefix(5)) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.source.symbol).foregroundStyle(item.important ? .orange : .secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((item.vip == true ? "★ " : "") + item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(item.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if items.count > 5 {
                Text("and \(items.count - 5) more").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

/// "Hey Siri, check Mochi": Mochi Cloud looks now; the answer arrives as a notification.
struct CheckNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for Updates"
    static let description = IntentDescription("Mochi Cloud checks your mail, calendar and Notion now, even while your Mac is off.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MacLink.shared.start()
        if let problem = await MacLink.shared.checkInCloudNow() {
            return .result(dialog: IntentDialog(stringLiteral: problem))
        }
        return .result(dialog: "Checking now. I'll send you a notification in a minute or two.")
    }
}

struct MochiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatsWaitingIntent(), phrases: [
            "What's waiting in \(.applicationName)",
            "What's waiting for me in \(.applicationName)",
            "Ask \(.applicationName) what's waiting",
            "\(.applicationName) updates",
        ], shortTitle: "What's Waiting", systemImageName: "tray.full")
        AppShortcut(intent: CheckNowIntent(), phrases: [
            "Check \(.applicationName)",
            "Ask \(.applicationName) to check my mail",
        ], shortTitle: "Check Now", systemImageName: "arrow.clockwise")
    }
}
