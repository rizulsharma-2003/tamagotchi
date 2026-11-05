import AppKit
import SwiftUI
import TamagotchiCore
import UniformTypeIdentifiers

/// Settings › iPhone: Mochi's Live Activity on the user's iPhone.
struct PhoneSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore
    @State private var keyProblem: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    private var phone: PhoneController { environment.phone }
    private var link: LinkController { environment.link }
    @State private var confirmUnpair = false
    private var name: String { store.settings.petName }
    private var ready: Bool { phone.hasKey && phone.teamSigned && phone.pushToStartToken != nil }

    var body: some View {
        Form {
            Section {
                Toggle("Show \(name) on my iPhone", isOn: $store.settings.phone.enabled)
                Text("A Live Activity on your Lock Screen and in the Dynamic Island while Claude works. It lights up when Claude "
                     + "needs you and celebrates when Claude is done. Needs the Mochi Pocket app on your iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            linkSection

            Section("iCloud link") {
                status("iCloud on this Mac", ok: phone.teamSigned && phone.iCloudSignedIn,
                       detail: !phone.teamSigned ? "This build isn't signed with your team" : phone.iCloudSignedIn ? "Ready" : "Sign in to iCloud")
                status("Your iPhone", ok: phone.pushToStartToken != nil,
                       detail: phone.pushToStartToken == nil ? "Open Mochi Pocket on your iPhone once"
                           : "Linked" + (phone.tokensSavedAt.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                status("Live Activity", ok: phone.activityRunning,
                       detail: phone.activityRunning ? "Showing “\(phone.shown?.title ?? "")”" : "Not showing")
            }

            Section("Apple push key") {
                TextField("Key ID", text: $store.settings.phone.keyID)
                    .onChange(of: store.settings.phone.keyID) { _, _ in phone.keyIDChanged() }
                TextField("Team ID", text: $store.settings.phone.teamID)
                HStack {
                    Label(phone.usesBuiltInKey ? "Built into this copy (Key ID \(PhoneController.builtInKey?.keyID ?? ""))"
                              : phone.hasKey ? "Key saved in your Keychain" : "No key yet",
                          systemImage: phone.hasKey ? "checkmark.circle.fill" : "key")
                        .foregroundStyle(phone.hasKey ? Color.green : Color.secondary)
                    Spacer()
                    Button("Choose .p8 File…") { chooseKey() }
                }
                if let keyProblem {
                    Label(keyProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                Text("Create one on developer.apple.com › Certificates, Identifiers & Profiles › Keys, with Apple Push "
                     + "Notifications service turned on. The file is named AuthKey_<Key ID>.p8; it stays in this Mac's Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Talking from the iPhone") {
                Toggle("Run what I tell \(name) on my iPhone", isOn: $store.settings.phone.acceptCommands)
                Text("Press and hold \(name) in Mochi Pocket's room and talk: your words reach this Mac through your iCloud and run in Ask "
                     + "\(name) exactly as if you typed them here. Approvals for messages to Claude sessions show on both devices.")
                    .font(.caption).foregroundStyle(.secondary)
                if let command = phone.lastCommand {
                    Label("Last: “\(command)”", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Claude's summaries") {
                Toggle("Send Claude's summaries to my iPhone", isOn: $store.settings.phone.shareSummaries)
                Text("When a Claude session finishes, your iPhone gets a notification with the project, the files Claude "
                     + "changed and a short summary of what it said, written by Claude Haiku on this Mac. Reply there, or in "
                     + "Mochi Pocket, to send that session its next request. While this is off, none of Claude's words leave this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Only notify me when I'm away from this Mac", isOn: $store.settings.phone.notifyOnlyWhenAway)
                    .disabled(!store.settings.phone.shareSummaries)
                if store.settings.phone.shareSummaries, phone.deviceToken == nil {
                    Label("Open Mochi Pocket and allow notifications to get them on your iPhone.", systemImage: "bell.badge")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let summary = phone.lastSummary {
                    Label(summary, systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }

            Section("Privacy") {
                Toggle("Show project names on my iPhone", isOn: $store.settings.phone.shareProjectNames)
                Text("Otherwise your iPhone only sees “Claude is working”, “needs you” or “finished”, a timer and a tool count. "
                     + "Updates travel through Apple's push service; nothing else leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Try it") {
                HStack {
                    Button("Send a Test to My iPhone") { phone.sendTest() }.disabled(!ready)
                    Button("End It") { phone.endNow() }
                }
                if let result = phone.lastResult {
                    Label(result, systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
                }
                if let error = phone.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { phone.readTokens() }
    }

    /// Mochi Link: the fast, end-to-end encrypted link through the relay.
    @ViewBuilder
    private var linkSection: some View {
        Section("Mochi Link") {
            if link.paired {
                status("Relay", ok: link.status == .online,
                       detail: link.status == .online ? "Connected" : link.status == .connecting ? "Connecting…" : "Offline, retrying")
                if link.devices.isEmpty {
                    status("Your iPhone", ok: false, detail: "Not paired yet")
                }
                ForEach(link.devices, id: \.device) { peer in
                    status(peer.name ?? (peer.role == "pocket" ? "iPhone" : peer.role.capitalized), ok: peer.online,
                           detail: peer.online ? "Online" : "Away" + (peer.lastSeen.map {
                               " · \(Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1000 : $0).formatted(.relative(presentation: .named)))"
                           } ?? ""))
                }
            }
            if let code = link.code {
                HStack(alignment: .top, spacing: 16) {
                    if let image = LinkController.qrImage(code.url.absoluteString) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                            .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Pairing QR code")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On your iPhone, open Mochi Pocket › Settings › Pair with your Mac, and scan this code.")
                        if let expires = link.codeExpires {
                            Text("Works once, until \(expires.formatted(date: .omitted, time: .shortened)).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Copy Link") { link.copyCode() }
                            Button("Done") { link.hideCode() }
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    Button(link.paired ? "Pair Another Device…" : "Pair Your iPhone…") { Task { await link.showCode() } }
                        .disabled(link.working)
                    if link.working { ProgressView().controlSize(.small) }
                    Spacer()
                    if link.paired {
                        Button("Unpair This Mac…", role: .destructive) { confirmUnpair = true }
                    }
                }
            }
            if let problem = link.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            Text("Messages between this Mac and your iPhone go through your own relay in under a second, end-to-end encrypted: "
                 + "the relay passes them on but can't read them. iCloud stays on as a backup for now.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Unpair this Mac from Mochi Link?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { link.unpair() }
        } message: {
            Text("Your iPhone will need to scan a new code to use Mochi Link again. iCloud keeps working meanwhile.")
        }
    }

    private func status(_ title: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? .green : .secondary)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary).font(.callout)
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose the AuthKey_….p8 file you downloaded from developer.apple.com"
        if panel.runModal() == .OK, let url = panel.url { keyProblem = phone.importKey(from: url) }
    }
}
