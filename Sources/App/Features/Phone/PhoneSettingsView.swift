import AppKit
import SwiftUI
import TamagotchiCore

/// Settings › iPhone: pairing your phones with Mochi Link, then what goes to them (the Live Activity, Claude's summaries,
/// talking to Mochi). Nothing reaches a phone until it's paired.
struct PhoneSettingsView: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    private var phone: PhoneController { environment.phone }
    private var link: LinkController { environment.link }
    @State private var confirmUnpair = false
    private var name: String { store.settings.petName }
    private var ready: Bool { link.paired && phone.pushToStartToken != nil }

    var body: some View {
        Form {
            linkSection

            Section("Live Activity") {
                Toggle("Show \(name) on my iPhone", isOn: $store.settings.phone.enabled)
                Text("A Live Activity on your Lock Screen and in the Dynamic Island while Claude works. It lights up when Claude "
                     + "needs you and celebrates when Claude is done. Needs the Mochi Pocket app on your iPhone, paired above.")
                    .font(.caption).foregroundStyle(.secondary)
                if link.paired {
                    status("Your iPhone", ok: phone.pushToStartToken != nil,
                           detail: phone.pushToStartToken == nil ? "Open Mochi Pocket on your iPhone once"
                               : "Ready" + (phone.tokensSavedAt.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                    status("Live Activity", ok: phone.activityRunning,
                           detail: phone.activityRunning ? "Showing “\(phone.shown?.title ?? "")”" : "Not showing")
                }
            }

            Section("Talking from the iPhone") {
                Toggle("Run what I tell \(name) on my iPhone", isOn: $store.settings.phone.acceptCommands)
                Text("Press and hold \(name) in Mochi Pocket's room and talk: your words reach this Mac through Mochi Link and run in Ask "
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
                     + "Mochi Pocket, to send that session its next request. While this is off, or while no phone is paired, "
                     + "none of Claude's words leave this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Only notify me when I'm away from this Mac", isOn: $store.settings.phone.notifyOnlyWhenAway)
                    .disabled(!store.settings.phone.shareSummaries)
                if store.settings.phone.shareSummaries {
                    if !link.paired {
                        Label("Pair your iPhone (Mochi Link, above) to get them.", systemImage: "link")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if phone.deviceToken == nil {
                        Label("Open Mochi Pocket and allow notifications to get them on your iPhone.", systemImage: "bell.badge")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = phone.lastSummary {
                    Label(summary, systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }

            Section("Privacy") {
                Toggle("Show project names on my iPhone", isOn: $store.settings.phone.shareProjectNames)
                Text("Otherwise your iPhone only sees “Claude is working”, “needs you” or “finished”, a timer and a tool count. "
                     + "Everything goes through your Mochi Link relay, end-to-end encrypted: the relay, and Apple's push service "
                     + "that wakes your iPhone, see only the phase and the timer. Only your phones can read the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Try it") {
                HStack {
                    Button("Send a Test to My iPhone") { phone.sendTest() }.disabled(!ready)
                    Button("End It") { phone.endNow() }.disabled(!link.paired)
                }
                if !link.paired {
                    Text(PhoneController.pairFirst).font(.caption).foregroundStyle(.secondary)
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

    /// Mochi Link: the only way between this Mac and your phones, through your own relay, end-to-end encrypted.
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
                    let seen = peer.lastSeen.map {
                        Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1000 : $0).formatted(.relative(presentation: .named))
                    }
                    if peer.role == "cloud" {
                        // The cloud never stays connected: it posts when a check runs, so "away" would look like a fault.
                        status(peer.name ?? "Mochi Cloud", ok: seen != nil,
                               detail: seen.map { "Last check \($0)" } ?? "Hasn't checked in yet")
                    } else {
                        status(peer.name ?? (peer.role == "pocket" ? "iPhone" : peer.role.capitalized), ok: peer.online,
                               detail: peer.online ? "Online" : "Away" + (seen.map { " · \($0)" } ?? ""))
                    }
                }
            } else {
                status("Your iPhone", ok: false, detail: "Not paired")
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
                        Button("Send a Test to All Phones") { phone.sendTestNotification() }
                            .disabled(link.status != .online)
                            .help("Every paired phone gets it: iPhone and Android")
                        Button("Unpair This Mac…", role: .destructive) { confirmUnpair = true }
                    }
                }
            }
            if let problem = link.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            Text(link.paired
                 ? "Messages between this Mac and your phones go through your own relay in under a second, end-to-end encrypted: "
                    + "the relay passes them on, and wakes your phones, but can't read them."
                 : "Your phones reach this Mac only through Mochi Link, your own end-to-end encrypted relay. Pair once by scanning "
                    + "a code with Mochi Pocket; until then, nothing from this Mac goes to your phone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Unpair this Mac from Mochi Link?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { link.unpair() }
        } message: {
            Text("This deletes the room on your relay: your phones and Mochi Cloud are cut off, and their old keys stop working. "
                 + "Nothing reaches your phones until you pair again with a new code (and copy new cloud settings).")
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
}
