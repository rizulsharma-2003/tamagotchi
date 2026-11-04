import AppKit
import Carbon.HIToolbox
import ServiceManagement
import TamagotchiCore
import UserNotifications

/// Native notifications. Only used when the user enables banners for a category.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    enum Authorization: Equatable { case unknown, unavailable, notDetermined, denied, allowed }

    private(set) var authorization: Authorization = .unknown

    /// UNUserNotificationCenter requires a real app bundle; `swift run` has none.
    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func refreshAuthorization() async {
        guard isAvailable else { authorization = .unavailable; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: authorization = .allowed
        case .denied: authorization = .denied
        case .notDetermined: authorization = .notDetermined
        @unknown default: authorization = .unknown
        }
    }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        UNUserNotificationCenter.current().delegate = self
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
        await refreshAuthorization()
        return granted
    }

    func post(_ content: BannerContent, category: NotificationCategory, sessionID: String?) {
        guard isAvailable else { return }
        Task {
            if authorization == .unknown || authorization == .notDetermined { _ = await requestAuthorization() }
            guard authorization == .allowed else { return }
            let notification = UNMutableNotificationContent()
            notification.title = content.title
            notification.body = content.body
            notification.threadIdentifier = sessionID ?? category.rawValue
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: notification, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

/// Global shortcuts via Carbon hot keys, which need no Accessibility permission and never observe
/// other keystrokes: ⌃⌥⌘P shows or hides the desktop pet, and the Ask Mochi shortcut opens the
/// command bar (or listens while it is held).
@MainActor
final class HotKey {
    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    private struct Entry {
        var reference: EventHotKeyRef
        var onPress: @MainActor () -> Void
        var onRelease: (@MainActor () -> Void)?
    }

    private static var entries: [UInt32: Entry] = [:]
    private static var handler: EventHandlerRef?
    private static let desktopPetID: UInt32 = 1

    static let displayString = "⌃⌥⌘P"

    /// The desktop-pet shortcut.
    func register(action: @escaping @MainActor () -> Void) {
        Self.register(id: Self.desktopPetID, combo: Combo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey | controlKey)),
                      onPress: action)
    }

    func unregister() { Self.unregister(id: Self.desktopPetID) }

    /// Returns false when the combination is taken (by this app or another one).
    @discardableResult
    static func register(id: UInt32, combo: Combo, onPress: @escaping @MainActor () -> Void,
                         onRelease: (@MainActor () -> Void)? = nil) -> Bool {
        unregister(id: id)
        installHandler()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: OSType(0x4D544730), id: id),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        entries[id] = Entry(reference: reference, onPress: onPress, onRelease: onRelease)
        return true
    }

    static func unregister(id: UInt32) {
        if let entry = entries.removeValue(forKey: id) { UnregisterEventHotKey(entry.reference) }
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.dispatch(id: id, pressed: pressed) }
            }
            return noErr
        }, types.count, &types, nil, &handler)
    }

    private static func dispatch(id: UInt32, pressed: Bool) {
        guard let entry = entries[id] else { return }
        if pressed { entry.onPress() } else { entry.onRelease?() }
    }
}

/// Launch at login via the modern Service Management API.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "MacTamagotchi opens when you log in."
        case .requiresApproval: return "Approve MacTamagotchi in System Settings › General › Login Items."
        case .notFound: return "Install the app in /Applications to use this option."
        case .notRegistered: return "MacTamagotchi does not open at login."
        @unknown default: return ""
        }
    }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Follows the system Reduce Motion accessibility setting.
@MainActor
final class ReducedMotionObserver {
    private var token: NSObjectProtocol?

    func start(_ changed: @escaping @MainActor (Bool) -> Void) {
        changed(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { changed(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
        }
    }
}
