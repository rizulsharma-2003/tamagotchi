import AVFoundation
import SwiftUI
import UIKit
import UserNotifications

/// Mochi Pocket's settings: the Lock Screen and Dynamic Island preview, notifications for Claude's
/// summaries, and how the phone is linked with the Mac.
struct PocketSettingsView: View {
    let coordinator: ActivityCoordinator
    let link: MacLink
    let phone: PhoneWorld
    @State private var notifications = PhoneNotifications.shared
    @State private var previewPhase = "working"
    @AppStorage("checkNowUsesCloud") private var checkNowUsesCloud = true
    @AppStorage(MochiVoice.characterKey) private var voiceCharacter = MochiVoice.Character.mochi.rawValue
    @AppStorage(MochiVoice.voiceKey) private var voiceID = ""
    @AppStorage(MochiVoice.siriReadsKey) private var siriReads = false
    @AppStorage(KokoroVoice.enabledKey) private var natural = false
    @AppStorage(KokoroVoice.styleKey) private var naturalStyle = KokoroVoice.Style.all[0].id
    @State private var kokoro = KokoroVoice.shared
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var personalVoice = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    @State private var reader = UpdatesReader.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        LinkCard()
                        liveActivityCard
                        voiceCard
                        summariesCard
                        cloudCard
                        macCard
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.tint)
        .task { await notifications.refresh() }
        .onDisappear { reader.stop() }
    }

    // MARK: Lock Screen & Dynamic Island

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lock Screen & Dynamic Island").font(.mochi(.headline)).foregroundStyle(Theme.ink)
                Spacer()
                Tag(text: coordinator.activitiesEnabled ? "On" : "Off", symbol: coordinator.activitiesEnabled ? "checkmark" : "xmark",
                    tint: coordinator.activitiesEnabled ? Theme.success : Theme.inkSecondary)
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                let frame = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 10
                MochiLockScreenView(attributes: .init(petName: "Mochi", companionName: "Patch"),
                                    state: ActivityCoordinator.demoState(previewPhase, frame: frame))
                    .background(MochiLockScreenBackground())
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["working", "waiting", "done", "error", "idle", "asleep"], id: \.self) { phase in
                        Chip(title: phase.capitalized, selected: previewPhase == phase) { previewPhase = phase }
                    }
                }
            }
            HStack(spacing: 10) {
                Button { coordinator.startDemo(phase: previewPhase) } label: {
                    Label("Show on Lock Screen", systemImage: "lock.iphone").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if !coordinator.runningPhases.isEmpty {
                    Button { coordinator.endAll() } label: { Image(systemName: "xmark") }.buttonStyle(.bordered)
                }
            }
            Text(coordinator.activitiesEnabled
                 ? "Your Mac shows Mochi here automatically while Claude works."
                 : "Live Activities are off — turn them on in Settings › Mochi.")
                .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
        }
        .mochiCard()
    }

    // MARK: Mochi's voice

    private var petName: String { phone.world.settings.petName }

    private var character: MochiVoice.Character { MochiVoice.Character(rawValue: voiceCharacter) ?? .mochi }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(petName)'s voice").font(.mochi(.headline)).foregroundStyle(Theme.ink)
                Spacer()
                Button { hear() } label: {
                    Label(reader.speaking ? "Stop" : "Hear It", systemImage: reader.speaking ? "stop.fill" : "play.fill")
                        .font(.mochi(.caption, .semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            Picker("Kind of voice", selection: $natural) {
                Text("Natural").tag(true)
                Text("iPhone voice").tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: natural) { reader.stop() }
            if natural {
                naturalControls
            } else {
                iPhoneControls
            }
            Divider()
            Text("When you ask Siri “What's waiting in Mochi”").font(.mochi(.subheadline))
            Picker("Who reads it", selection: $siriReads) {
                Text("\(petName) reads it").tag(false)
                Text("Siri reads it").tag(true)
            }
            .pickerStyle(.segmented)
            Text(siriReads
                 ? "Siri reads it in Siri's voice, but only when Siri talks: by default it stays quiet when it thinks you're "
                   + "looking at the screen. To hear it every time, search “Siri Responses” in Settings and pick Prefer Spoken Responses."
                 : "\(petName) reads it in this voice every time, while Siri shows the list. Siri's own voice isn't open to apps, "
                   + "so this is the way to always hear it the same.")
                .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
        }
        .mochiCard()
        .onAppear { voices = MochiVoice.choices() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            voices = MochiVoice.choices()
        }
    }

    /// Kokoro: download it once, then pick one of Mochi's natural voices.
    @ViewBuilder
    private var naturalControls: some View {
        if kokoro.downloaded {
            HStack(spacing: 8) {
                ForEach(KokoroVoice.Style.all) { style in
                    Chip(title: style.title, selected: naturalStyle == style.id) {
                        naturalStyle = style.id
                        hear(restart: true)
                        }
                }
            }
            Text(KokoroVoice.Style.current.blurb).font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
            if kokoro.phase == .loading {
                Label("Getting \(petName)'s voice ready…", systemImage: "hourglass")
                    .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
            }
        } else {
            switch kokoro.phase {
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading \(petName)'s voice… \(Int(fraction * 100))%").font(.mochi(.footnote))
                }
            case .loading:
                ProgressView { Text("Getting it ready…").font(.mochi(.footnote)) }
            default:
                Button {
                    Task {
                        if await kokoro.prepare() {
                            hear(restart: true)
                        }
                    }
                } label: {
                    Label("Download \(petName)'s Voice (\(KokoroVoice.downloadSize))", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        if case .failed(let problem) = kokoro.phase {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.mochi(.footnote, .medium)).foregroundStyle(Theme.warning)
        }
        Text(kokoro.downloaded
             ? "Kokoro, an open-source voice, speaks on this iPhone: nothing is sent anywhere. If it can't talk for a moment, "
               + "the iPhone voice reads instead."
             : "Kokoro is an open-source voice that runs on this iPhone. It downloads once (best on Wi-Fi); after that "
               + "nothing is sent anywhere. Until then \(petName) uses the iPhone voice.")
            .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
        if kokoro.downloaded {
            Button("Remove the Download", role: .destructive) {
                reader.stop()
                kokoro.remove()
            }
            .font(.mochi(.footnote))
        }
    }

    /// The iPhone's own voices, made Mochi's with a character.
    @ViewBuilder
    private var iPhoneControls: some View {
        HStack(spacing: 8) {
            ForEach(MochiVoice.Character.allCases) { option in
                Chip(title: option.title, selected: character == option) {
                    voiceCharacter = option.rawValue
                    hear(restart: true)
                    }
            }
        }
        Text(character.blurb).font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
        HStack {
            Text("Voice").font(.mochi(.subheadline))
            Spacer()
            Picker("Voice", selection: $voiceID) {
                Text("Best on this iPhone" + (MochiVoice.automatic().map { " (\($0.name))" } ?? "")).tag("")
                voiceSection("Personal Voice", voices.filter { $0.voiceTraits.contains(.isPersonalVoice) })
                voiceSection("Premium & Enhanced", voices.filter { !$0.voiceTraits.contains(.isPersonalVoice) && $0.quality != .default })
                voiceSection("Standard", voices.filter { !$0.voiceTraits.contains(.isPersonalVoice) && $0.quality == .default })
            }
            .pickerStyle(.menu)
            .onChange(of: voiceID) { hear(restart: true) }
        }
        if personalVoice == .notDetermined {
            Button("Use a Personal Voice…") {
                Task {
                    personalVoice = await AVSpeechSynthesizer.requestPersonalVoiceAuthorization()
                    voices = MochiVoice.choices()
                }
            }
            .buttonStyle(.bordered)
        }
        Text(voiceHint).font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
    }

    @ViewBuilder
    private func voiceSection(_ title: String, _ list: [AVSpeechSynthesisVoice]) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list, id: \.identifier) { Text(MochiVoice.label($0)).tag($0.identifier) }
            }
        }
    }

    private var voiceHint: String {
        let hasPersonal = voices.contains { $0.voiceTraits.contains(.isPersonalVoice) }
        if personalVoice == .authorized, !hasPersonal {
            return "No Personal Voice on this iPhone yet: make one in Settings › Accessibility › Personal Voice (it takes a "
                + "few minutes of reading aloud), then pick it here: \(petName) talks in your voice, with its own character on top."
        }
        if !voices.contains(where: { $0.quality != .default }) {
            return "For a far more natural \(petName), download a Premium voice: in Settings, search “Voices”, pick English "
                + "and tap a voice marked Premium. It shows up here once it's downloaded."
        }
        return "Everything is spoken on this iPhone; nothing is sent anywhere."
    }

    /// Plays a sample in the voice as set now; a second tap stops it.
    private func hear(restart: Bool = false) {
        if reader.speaking, !restart {
            reader.stop()
            return
        }
        reader.say("Hi, I'm \(petName)! Two things are waiting for you. Your design review is at 4 pm, "
                   + "and Priya needs you: the invoice for October. That's everything.",
                   voice: MochiVoice(character: character, voiceID: voiceID.isEmpty ? nil : voiceID,
                                     natural: natural && kokoro.downloaded, style: .current))
    }

    // MARK: Claude's summaries

    private var summariesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude's summaries").font(.mochi(.headline)).foregroundStyle(Theme.ink)
            row("Shared by your Mac", ok: link.summariesShared == true,
                detail: link.summariesShared == true ? "On" : link.summariesShared == false ? "Off on the Mac" : "Waiting for your Mac")
            row("Notifications", ok: notificationsAllowed, detail: notificationText)
            switch notifications.status {
            case .notDetermined:
                Button("Allow Notifications") { Task { await notifications.refresh(asking: true) } }.buttonStyle(.bordered)
            case .denied:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.bordered)
            default:
                EmptyView()
            }
            Text("When a Claude session on your Mac finishes, you get what it did and the files it changed. Reply from the "
                 + "notification, or from the session's card, and your words go to that session. Turn it on in "
                 + "\(phone.world.settings.petName)'s Settings › iPhone on your Mac.")
                .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
        }
        .mochiCard()
    }

    private var notificationsAllowed: Bool {
        notifications.status == .authorized || notifications.status == .provisional || notifications.status == .ephemeral
    }

    private var notificationText: String {
        switch notifications.status {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Off in Settings"
        default: return "Not asked yet"
        }
    }

    // MARK: Your Mac

    private var macCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Mac").font(.mochi(.headline)).foregroundStyle(Theme.ink)
            row("Mochi Link", ok: PocketLink.shared.paired, detail: PocketLink.shared.paired ? "Paired" : "Not paired yet")
            row("Room and pet", ok: phone.linkedToMac, detail: phone.linkedToMac ? "Following your Mac" : "Waiting for your Mac")
            row("Live Activity address", ok: coordinator.hasPushToStartToken,
                detail: coordinator.hasPushToStartToken
                    ? "Shared" + (coordinator.lastSaved.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? "")
                    : "Not shared yet")
            Text("Your iPhone and Mac talk through Mochi Link (above): your own relay, end-to-end encrypted, no account.")
                .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
        }
        .mochiCard()
    }

    // MARK: Mochi Cloud

    private var cloudCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mochi Cloud").font(.mochi(.headline)).foregroundStyle(Theme.ink)
            row("Hourly checks", ok: link.cloudSeenAt != nil,
                detail: link.cloudSeenAt.map { "Last news \($0.formatted(.relative(presentation: .named)))" } ?? "No news from the cloud yet")
            row("Check now without your Mac", ok: link.cloudAvailable, detail: link.cloudAvailable ? "Ready" : "Add the API trigger on your Mac")
            Toggle("Check now always asks Mochi Cloud", isOn: $checkNowUsesCloud)
                .font(.mochi(.subheadline))
            Text(checkNowUsesCloud
                 ? "Check now goes straight to the cloud, whether your Mac is on or off. Answers take a minute or two and arrive as a notification."
                 : "Check now asks your Mac first (faster when it's on) and the cloud only when your Mac doesn't answer.")
                .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
            Text("While your Mac is off, a Claude task in Anthropic's cloud checks your mail, calendar and Notion every hour from 8 am "
                 + "to 11 pm and notifies you here. News your Mac already gave you arrives quietly. Set it up in your Mac's "
                 + "Settings › Agent › Mochi Cloud.")
                .font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
        }
        .mochiCard()
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Theme.success : Theme.inkSecondary)
                .accessibilityHidden(true)
            Text(title).font(.mochi(.subheadline))
            Spacer()
            Text(detail).font(.mochi(.footnote)).foregroundStyle(Theme.inkSecondary)
        }
    }
}
