import AppIntents
import SwiftUI
import TamagotchiCore

/// "Hey Siri, what's waiting in Mochi?" and Siri shows the list. Who reads it is set in Settings › Mochi's voice:
/// - Mochi (the default) reads it in its own voice, every time, while Siri stays quiet. If both talked, Siri
///   would cut Mochi off, and Siri only talks when it thinks you can't see the screen.
/// - Siri reads it all in Siri's voice, but only when Siri talks (its "Siri Responses" setting).
/// An audio intent, so Mochi may keep talking after Siri closes.
struct WhatsWaitingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "What's Waiting"
    static let description = IntentDescription("Hear what's waiting for you: new mail, coming meetings and Notion tasks.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        MacLink.shared.start()
        let items = UpdatesStore.shared.waitingNow()
        let snippet = WaitingSnippet(items: items)
        if UserDefaults.standard.bool(forKey: MochiVoice.siriReadsKey) {
            UpdatesReader.shared.stop()
            return .result(dialog: IntentDialog(stringLiteral: AgentSpeech.script(items: items)), view: snippet)
        }
        // Mochi is talking before Siri hands back; with no dialog Siri doesn't talk over it.
        await UpdatesReader.shared.speakForSiri(items)
        var quiet: IntentResultContainer<Never, Never, _SnippetViewContainer, IntentDialog> = .result(dialog: "", view: snippet)
        quiet.dialog = nil
        return quiet
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
            "What's waiting on \(.applicationName)",
            "What's waiting for me in \(.applicationName)",
            "What's waiting for me on \(.applicationName)",
            "What's new in \(.applicationName)",
            "What's new on \(.applicationName)",
            "Any updates in \(.applicationName)",
            "Any updates on \(.applicationName)",
            "Ask \(.applicationName) what's waiting",
            "Read my \(.applicationName) updates",
            "\(.applicationName) what's waiting",
            "\(.applicationName) updates",
        ], shortTitle: "What's Waiting", systemImageName: "tray.full")
        AppShortcut(intent: CheckNowIntent(), phrases: [
            "Check \(.applicationName)",
            "Ask \(.applicationName) to check my mail",
        ], shortTitle: "Check Now", systemImageName: "arrow.clockwise")
    }
}
