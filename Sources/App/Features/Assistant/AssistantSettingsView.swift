import SwiftUI
import TamagotchiCore

/// Settings › Assistant: the shortcut, the helper Claude session, approvals, voice and Mac control.
struct AssistantSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore
    @State private var accessibilityTrusted = MacActions.accessibilityTrusted

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    private var assistant: AssistantController { environment.assistant }
    private var name: String { store.settings.petName }

    var body: some View {
        Form {
            Section {
                Toggle("Ask \(name)", isOn: $store.settings.assistant.enabled)
                    .onChange(of: store.settings.assistant.enabled) { _, _ in assistant.applySettings() }
                Picker("Shortcut", selection: $store.settings.assistant.shortcut) {
                    ForEach(AssistantShortcut.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!store.settings.assistant.enabled)
                .onChange(of: store.settings.assistant.shortcut) { _, _ in assistant.applySettings() }
                if let problem = assistant.shortcutProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                Text("Tap the shortcut to type a request, or hold it to talk. Try “pause the music”, “open Slack”, "
                     + "“play lo-fi beats on YouTube” or “tell the Tamagotchi Claude to make the animations smoother”.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Ask \(name)") { assistant.showPanel() }
                    .disabled(!store.settings.assistant.enabled)
            }

            Section("Claude") {
                Picker("Helper model", selection: $store.settings.assistant.model) {
                    ForEach(AssistantModel.allCases) { Text($0.title).tag($0) }
                }
                Text(claudeStatus).font(.caption).foregroundStyle(.secondary)
                Toggle("Ask me before sending a prompt to a Claude session", isOn: $store.settings.assistant.confirmBeforeSending)
                Text("Prompts reach your sessions through Claude Code's own session messaging, never by typing into a window. "
                     + "They show up there as “Message from @\(BrainLaunch.sessionName)”, and that session's permission prompts still apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Voice") {
                Toggle("Hold the shortcut to talk", isOn: $store.settings.assistant.voice)
                if !assistant.voice.isSupported {
                    Text("Talking needs macOS 26 or later.").font(.caption).foregroundStyle(.secondary)
                } else if assistant.voice.microphoneDenied {
                    Text("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Speech is turned into text on this Mac. The microphone is on only while you hold the shortcut; audio is never saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("\(name) reads answers aloud", isOn: $store.settings.assistant.spokenReplies)
            }

            Section("Mac control") {
                HStack {
                    Label(accessibilityTrusted ? "Accessibility allowed" : "Accessibility not allowed",
                          systemImage: accessibilityTrusted ? "checkmark.circle.fill" : "hand.raised")
                        .foregroundStyle(accessibilityTrusted ? Color.green : Color.secondary)
                    Spacer()
                    if !accessibilityTrusted {
                        Button("Allow…") { MacActions.requestAccessibility() }
                    }
                }
                Text("Needed only to press music keys and to bring a specific window forward. \(name) reads window titles on this Mac "
                     + "to find the one you mean; titles are never sent to Claude.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("What you ask goes to Claude (Anthropic) like any prompt, with the names of your running apps and Claude sessions "
                     + "when they help. \(name) keeps the conversation in memory only and stops the helper session after 10 quiet minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibilityTrusted = MacActions.accessibilityTrusted
        }
    }

    private var claudeStatus: String {
        if let installation = environment.integration.installation {
            return "Uses your Claude Code login (version \(installation.version ?? "unknown")) — no API key needed. "
                + "Each request uses a little of your plan, like a short prompt."
        }
        return "Claude Code wasn't found. Install it from claude.com/claude-code to ask \(name) for anything beyond quick commands."
    }
}
