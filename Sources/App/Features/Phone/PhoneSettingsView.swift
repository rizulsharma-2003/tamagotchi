import AppKit
import SwiftUI
import TamagotchiCore

/// Settings › Phones: pairing your phones (iPhone and Android) with Mochi Link, then what goes to them (Claude's
/// summaries, talking to Mochi, and the iPhone's Live Activity). Nothing reaches a phone until it's paired. Each phone is
/// named as the relay lists it (`LinkPeerNames`); iPhone-only features say so and explain themselves when no iPhone
/// is paired.
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
    /// The Live Activity needs an iPhone: one is in the room, or one has shared its Live Activity address.
    private var hasIPhone: Bool { link.hasIPhone || phone.pushToStartToken != nil }
    /// The paired iPhone's own name ("Rizul's iPhone").
    private var iPhoneName: String {
        link.phones.first { $0.linkPlatform == .iOS }?.name ?? "Your iPhone"
    }

    var body: some View {
        Form {
            linkSection

            Section("Talking from your phones") {
                Toggle("Run what I tell \(name) on my phones", isOn: $store.settings.phone.acceptCommands)
                Text("Type to \(name) on any phone, or press and hold \(name) on your iPhone and talk: your words reach "
                     + "this Mac through Mochi Link and run in Ask \(name) exactly as if you typed them here. Approvals for "
                     + "messages to Claude sessions show on this Mac and your phones.")
                    .font(.caption).foregroundStyle(.secondary)
                if let command = phone.lastCommand {
                    Label("Last: “\(command)”", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Claude's summaries") {
                Toggle("Send Claude's summaries to my phones", isOn: $store.settings.phone.shareSummaries)
                Text("When a Claude session finishes, your phones get a notification with the project, the files Claude "
                     + "changed and a short summary of what it said, written by Claude Haiku on this Mac. Reply from the "
                     + "session's card in Mochi (or the notification on iPhone) to send that session its next request. While "
                     + "this is off, or while no phone is paired, none of Claude's words leave this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Only notify me when I'm away from this Mac", isOn: $store.settings.phone.notifyOnlyWhenAway)
                    .disabled(!store.settings.phone.shareSummaries)
                if store.settings.phone.shareSummaries {
                    if !link.paired {
                        Label("Pair a phone (Mochi Link, above) to get them.", systemImage: "link")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if link.hasIPhone, phone.deviceToken == nil {
                        Label("Open Mochi on your iPhone and allow notifications to get them there.", systemImage: "bell.badge")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = phone.lastSummary {
                    Label(summary, systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }

            Section("Live Activity on iPhone") {
                Toggle("Show \(name) on my iPhone", isOn: $store.settings.phone.enabled)
                Text("A Live Activity on your iPhone's Lock Screen and in the Dynamic Island while Claude works. It lights up "
                     + "when Claude needs you and celebrates when Claude is done. Needs Mochi on your iPhone, paired above.")
                    .font(.caption).foregroundStyle(.secondary)
                if link.paired, !hasIPhone {
                    Label("Live Activities need an iPhone, and none is paired. Your other phones still get notifications.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if link.paired {
                    status(iPhoneName, ok: phone.pushToStartToken != nil,
                           detail: phone.pushToStartToken == nil ? "Open Mochi on your iPhone once"
                               : "Ready" + (phone.tokensSavedAt.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                    status("Live Activity", ok: phone.activityRunning,
                           detail: phone.activityRunning ? "Showing “\(phone.shown?.title ?? "")”" : "Not showing")
                }
                HStack {
                    Button("Send a Test to My iPhone") { phone.sendTest() }.disabled(!ready)
                    Button("End It") { phone.endNow() }.disabled(!link.paired || !hasIPhone)
                }
                if !link.paired {
                    Text(PhoneController.pairFirst).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Toggle("Show project names on my phones", isOn: $store.settings.phone.shareProjectNames)
                Text("Otherwise your phones only see “Claude is working”, “needs you” or “finished”, a timer and a tool count. "
                     + "Everything goes through your Mochi Link relay, end-to-end encrypted: the relay, and the push services "
                     + "that wake your phones, see at most the phase and the timer. Only your phones can read the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if phone.lastResult != nil || phone.lastError != nil {
                Section("Last test") {
                    if let result = phone.lastResult {
                        Label(result, systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
                    }
                    if let error = phone.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    }
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
                if link.phones.isEmpty {
                    status("Your phones", ok: false, detail: "None paired yet")
                }
                ForEach(link.devices, id: \.device) { peer in
                    let seen = peer.lastSeenDate?.formatted(.relative(presentation: .named))
                    if peer.role == "cloud" {
                        // The cloud never stays connected: it posts when a check runs, so "away" would look like a fault.
                        status(peer.name ?? "Mochi Cloud", ok: seen != nil,
                               detail: seen.map { "Last check \($0)" } ?? "Hasn't checked in yet")
                    } else {
                        status(LinkPeerNames.row(for: peer), ok: peer.online,
                               detail: peer.online ? "Online" : "Away" + (seen.map { " · \($0)" } ?? ""))
                    }
                }
            } else {
                status("Your phones", ok: false, detail: "Not paired")
            }
            if let code = link.code {
                HStack(alignment: .top, spacing: 16) {
                    if let image = LinkController.qrImage(code.url.absoluteString) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                            .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Pairing QR code")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On your iPhone or Android phone, open Mochi, tap Scan the Code and point it at this code. "
                             + "(On iPhone, it's in Settings › Mochi Link.)")
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
                    Button("Pair a Phone…") { Task { await link.showCode() } }
                        .disabled(link.working)
                    if link.working { ProgressView().controlSize(.small) }
                    Spacer()
                    if link.paired {
                        Button("Send a Test to All Phones") { phone.sendTestNotification() }
                            .disabled(link.status != .online || link.phones.isEmpty)
                            .help(link.phones.isEmpty ? "Pair a phone first" : "Every paired phone gets it: \(link.phoneNames)")
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
                    + "a code with Mochi on your iPhone or Android phone; until then, nothing from this Mac goes to your phones.")
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
