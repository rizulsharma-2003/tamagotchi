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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        liveActivityCard
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
        .tint(MochiStyle.accent)
        .task { await notifications.refresh() }
    }

    // MARK: Lock Screen & Dynamic Island

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lock Screen & Dynamic Island").font(.system(.headline, design: .rounded))
                Spacer()
                Circle().fill(coordinator.activitiesEnabled ? Color.green : Color.gray).frame(width: 8, height: 8)
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
                        Button(phase.capitalized) { previewPhase = phase }
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(previewPhase == phase ? MochiStyle.accent : Color.white.opacity(0.8)))
                            .foregroundStyle(previewPhase == phase ? Color.white : Color.primary)
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
                .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
        }
        .pocketCard()
    }

    // MARK: Claude's summaries

    private var summariesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude's summaries").font(.system(.headline, design: .rounded))
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
                .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
        }
        .pocketCard()
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
            Text("Your Mac").font(.system(.headline, design: .rounded))
            row("iCloud", ok: coordinator.iCloudAvailable, detail: coordinator.iCloudAvailable ? "Signed in" : "Sign in to iCloud")
            row("Room and pet", ok: phone.linkedToMac, detail: phone.linkedToMac ? "Following your Mac" : "Waiting for your Mac")
            row("Live Activity address", ok: coordinator.hasPushToStartToken,
                detail: coordinator.hasPushToStartToken
                    ? "Shared" + (coordinator.lastSaved.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? "")
                    : "Not shared yet")
            Text("Your iPhone and Mac find each other through your iCloud: same Apple ID, no account or server.")
                .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
        }
        .pocketCard()
    }

    // MARK: Mochi Cloud

    private var cloudCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mochi Cloud").font(.system(.headline, design: .rounded))
            row("Hourly checks", ok: link.cloudSeenAt != nil,
                detail: link.cloudSeenAt.map { "Last news \($0.formatted(.relative(presentation: .named)))" } ?? "No news from the cloud yet")
            row("Check now without your Mac", ok: link.cloudAvailable, detail: link.cloudAvailable ? "Ready" : "Add the API trigger on your Mac")
            Toggle("Check now always asks Mochi Cloud", isOn: $checkNowUsesCloud)
                .font(.system(.subheadline, design: .rounded))
            Text(checkNowUsesCloud
                 ? "Check now goes straight to the cloud, whether your Mac is on or off. Answers take a minute or two and arrive as a notification."
                 : "Check now asks your Mac first (faster when it's on) and the cloud only when your Mac doesn't answer.")
                .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
            Text("While your Mac is off, a Claude task in Anthropic's cloud checks your mail, calendar and Notion every hour from 8 am "
                 + "to 11 pm and notifies you here. News your Mac already gave you arrives quietly. Set it up in your Mac's "
                 + "Settings › Agent › Mochi Cloud.")
                .font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
        }
        .pocketCard()
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Color.green : Color.secondary)
            Text(title).font(.system(.subheadline, design: .rounded))
            Spacer()
            Text(detail).font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}

/// The app's warm backdrop.
struct PocketBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 1.0, green: 0.96, blue: 0.92), Color(red: 0.98, green: 0.88, blue: 0.80)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

extension View {
    /// A rounded white card, as used across Mochi Pocket.
    func pocketCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.75)))
    }
}
