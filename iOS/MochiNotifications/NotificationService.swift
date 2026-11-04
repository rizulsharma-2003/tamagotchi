import UserNotifications
import WidgetKit

/// Every Mochi agent notification passes through here before it shows. Your Mac and Mochi Cloud can both
/// find the same new mail; when a notification marked `quietIfKnown` brings nothing you haven't already been
/// told (or have marked done), it arrives quietly — in Notification Center, without a sound or a banner.
/// Morning briefings, "Check now" answers and meeting heads-ups always come through. Each card also refreshes
/// the Lock Screen widget, even when Mochi Pocket isn't running.
final class NotificationService: UNNotificationServiceExtension {
    private static let toldKey = "toldItems"
    private static let keepFor: TimeInterval = 3 * 86_400

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let info = request.content.userInfo
        guard info["kind"] as? String == "agent", let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let card = info["pending"] as? [String: Any]
        let items = card?["items"] as? [[String: Any]] ?? []
        let ids = items.compactMap { $0["id"] as? String }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let done = WaitingSnapshot.done
        var told = (defaults.dictionary(forKey: Self.toldKey) as? [String: Double] ?? [:]).filter { now - $0.value < Self.keepFor }
        if info["quietIfKnown"] as? Bool == true, !ids.isEmpty, ids.allSatisfy({ told[$0] != nil || done[$0] != nil }) {
            content.sound = nil
            content.interruptionLevel = .passive
        }
        for id in ids where told[id] == nil { told[id] = now }
        defaults.set(told, forKey: Self.toldKey)
        if let card, let snapshot = WaitingSnapshot.receiving(card: card, previous: WaitingSnapshot.load()) {
            snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
        contentHandler(content)
    }
}
