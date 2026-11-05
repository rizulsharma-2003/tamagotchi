import Observation
import TamagotchiCore
import UIKit
import UserNotifications

/// Claude's summaries arrive as notifications, sealed by the Mac and pushed by the Mochi Link relay (the notification
/// extension opens them). "Reply" sends that session its next request without opening the app. The phone's push
/// address goes to the relay, like the Live Activity's.
@MainActor
@Observable
final class PhoneNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PhoneNotifications()
    static let replyAction = "reply"
    static let joinAction = "join"
    static let openDraftAction = "open-draft"

    private(set) var status: UNAuthorizationStatus = .notDetermined
    private var started = false

    /// Called while the app finishes launching, so a Reply that launched it is handled.
    func start() {
        guard !started else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "What should Claude do next?")
        // Meeting heads-ups with a video link get Join; "Reply drafted" gets Open in Gmail.
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground],
                                        icon: UNNotificationActionIcon(systemImageName: "video.fill"))
        let openDraft = UNNotificationAction(identifier: Self.openDraftAction, title: "Open in Gmail", options: [.foreground],
                                             icon: UNNotificationActionIcon(systemImageName: "envelope.open"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: PhoneAlertPayload.turnCategory, actions: [reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "mochi-agent", actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "mochi-meeting", actions: [join], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "mochi-draft", actions: [openDraft], intentIdentifiers: [], options: []),
        ])
        // Simulator screenshots (`-demoContent 1`) skip the permission prompt.
        Task { await refresh(asking: !UserDefaults.standard.bool(forKey: "demoContent")) }
        catchUp()
    }

    /// Summaries that arrived while the app wasn't looking: their cards go straight into the list.
    func catchUp() {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let cards = notifications.compactMap { PhoneSessionCard.decode(notification: $0.request.content.userInfo) }
            let pending = notifications.compactMap { AgentPending.decode(notification: $0.request.content.userInfo) }
                .max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }
            Task { @MainActor in
                cards.forEach { MacLink.shared.merge($0) }
                if let pending { MacLink.shared.mergeAgent(pending) }
            }
        }
    }

    /// Asks once, then registers for pushes whenever notifications are allowed.
    func refresh(asking: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        if asking, await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        status = await center.notificationSettings().authorizationStatus
        if status == .authorized || status == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func save(deviceToken: Data) {
        let linkStore = MochiLink.store
        guard linkStore.string(.deviceToken) != deviceToken.hex else { return }
        linkStore.set(deviceToken.hex, for: .deviceToken)
        PocketLink.shared.registerPush()
        MacLink.shared.log("push address saved for summaries")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if let card = PhoneSessionCard.decode(notification: notification.request.content.userInfo) {
            await MainActor.run { MacLink.shared.merge(card) }
        }
        if let pending = AgentPending.decode(notification: notification.request.content.userInfo) {
            await MainActor.run { MacLink.shared.mergeAgent(pending) }
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let card = PhoneSessionCard.decode(notification: response.notification.request.content.userInfo) {
            await MainActor.run { MacLink.shared.merge(card) }
        }
        if let pending = AgentPending.decode(notification: response.notification.request.content.userInfo) {
            await MainActor.run { MacLink.shared.mergeAgent(pending) }
        }
        // Join (or a tap on a heads-up) opens the meeting; a tap on "Reply drafted" opens the draft in Gmail.
        let info = response.notification.request.content.userInfo
        let tapped = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let target: String? = switch response.actionIdentifier {
        case Self.joinAction: info["join"] as? String
        case Self.openDraftAction: info["link"] as? String
        default: tapped ? (info["join"] as? String ?? (info["kind"] as? String == "draft" ? info["link"] as? String : nil)) : nil
        }
        if let target, target.hasPrefix("https://"), let url = URL(string: target) {
            let thread = info["kind"] as? String == "draft" ? info["thread"] as? String : nil
            await MainActor.run {
                // A draft opens in the Gmail app when it's installed; a meeting in Meet, Zoom or Teams.
                if let thread { OpenLinks.openGmail(thread: thread, fallback: url) } else { OpenLinks.openApp(url) }
            }
            return
        }
        guard response.actionIdentifier == Self.replyAction, let reply = response as? UNTextInputNotificationResponse else { return }
        let text = reply.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = info["project"] as? String
        let session = info["session"] as? String
        guard !text.isEmpty else { return }
        await MainActor.run { _ = MacLink.shared.send(text, project: project, session: session, typed: true) }
    }
}

/// Hands the app's push address to `PhoneNotifications`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PhoneNotifications.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PhoneNotifications.shared.save(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MacLink.shared.log("push registration failed: \(error.localizedDescription)")
    }
}
