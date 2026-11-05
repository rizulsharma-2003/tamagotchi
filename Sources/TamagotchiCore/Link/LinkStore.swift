import Foundation
import os

/// Everything Mochi's apps share with each other (docs/MOCHI_LINK_PLAN.md section 3). A key is **state** (only the
/// latest value matters), a **message** (meant to be handled once) or a **registration** (a device's push address,
/// which with Mochi Link goes to the relay instead of the other apps).
public enum LinkKey: String, CaseIterable, Sendable {
    // State, Mac → phone
    case look, claude, sessions, agent, cloud, approval, macDone
    // State, phone → Mac
    case phoneDone
    // Messages
    case activityEnded, macInteraction, phoneInteraction, command, reply, verdict
    // Registration (phone → Mac today; phone → relay with Mochi Link)
    case pushToStart, updateTokens, deviceToken, tokensSavedAt

    public enum Kind: Sendable { case state, message, registration }

    public var kind: Kind {
        switch self {
        case .look, .claude, .sessions, .agent, .cloud, .approval, .macDone, .phoneDone: .state
        case .activityEnded, .macInteraction, .phoneInteraction, .command, .reply, .verdict: .message
        case .pushToStart, .updateTokens, .deviceToken, .tokensSavedAt: .registration
        }
    }

    /// The name it has in iCloud key-value storage, unchanged from before Mochi Link so old and new builds agree.
    public var iCloudName: String {
        switch self {
        case .look: "macLook"
        case .claude: "macClaude"
        case .sessions: "macSessions"
        case .agent: "macAgent"
        case .cloud: "macCloud"
        case .approval: "macApproval"
        case .macDone: "macDone"
        case .phoneDone: "phoneDone"
        case .activityEnded: "macEnded"
        case .macInteraction: "macInteraction"
        case .phoneInteraction: "phoneInteraction"
        case .command: "phoneCommand"
        case .reply: "macReply"
        case .verdict: "phoneApproval"
        case .pushToStart: "pushToStart"
        case .updateTokens: "updateTokens"
        case .deviceToken: "deviceToken"
        case .tokensSavedAt: "savedAt"
        }
    }

    public init?(iCloudName: String) {
        guard let key = Self.allCases.first(where: { $0.iCloudName == iCloudName }) else { return nil }
        self = key
    }
}

/// Where Mochi's apps meet: today iCloud key-value storage (`ICloudLinkStore`), with Mochi Link the relay. Values are
/// JSON-compatible property-list values (String, Double, Bool, and dictionaries or arrays of those), in the same shapes
/// the apps have always written, so swapping the store doesn't change what's sent.
public protocol LinkStore: AnyObject, Sendable {
    func value(_ key: LinkKey) -> Any?
    /// Replaces state or sends a message; nil clears it.
    func set(_ value: Any?, for key: LinkKey)
    /// Pushes changes out now (iCloud: `synchronize()`).
    func flush()
    /// Something has been stored at all (with iCloud: an account is signed in and an app has written).
    var hasAnyValue: Bool { get }
}

public extension LinkStore {
    func string(_ key: LinkKey) -> String? { value(key) as? String }
    func dictionary(_ key: LinkKey) -> [String: Any]? { value(key) as? [String: Any] }
    func double(_ key: LinkKey) -> Double? { value(key) as? Double }
}

public extension Notification.Name {
    /// Posted on the main queue when another device changed something. `userInfo["keys"]` holds the changed
    /// `[LinkKey]` when the store knows them.
    static let linkStoreDidChange = Notification.Name("MochiLinkStoreDidChange")
}

/// The link as it has always been: the user's iCloud key-value storage, shared by the team's Mac and iPhone apps.
public final class ICloudLinkStore: LinkStore, @unchecked Sendable {
    public static let shared = ICloudLinkStore()

    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                          object: store, queue: .main) { note in
            let names = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int ?? -1
            // 0 server change, 1 initial sync, 2 quota exceeded, 3 iCloud account changed.
            Self.log.notice("iCloud changed (reason \(reason)): \(names?.joined(separator: ", ") ?? "?", privacy: .public)")
            let keys = names?.compactMap(LinkKey.init(iCloudName:))
            NotificationCenter.default.post(name: .linkStoreDidChange, object: nil, userInfo: keys.map { ["keys": $0] })
        }
        store.synchronize()
    }

    public func value(_ key: LinkKey) -> Any? { store.object(forKey: key.iCloudName) }

    public func set(_ value: Any?, for key: LinkKey) {
        if let value {
            store.set(value, forKey: key.iCloudName)
        } else {
            store.removeObject(forKey: key.iCloudName)
        }
    }

    public func flush() {
        if !store.synchronize() { Self.log.error("iCloud synchronize failed") }
    }

    /// `log show --last 10m --predicate 'subsystem == "com.mochi.link"'`
    static let log = Logger(subsystem: "com.mochi.link", category: "icloud")

    public var hasAnyValue: Bool { !store.dictionaryRepresentation.isEmpty }
}
