import Foundation

/// Everything Mochi's apps share with each other (docs/MOCHI_LINK_PLAN.md section 3). A key is **state** (only the
/// latest value matters), a **message** (meant to be handled once) or a **registration** (a phone's push addresses,
/// which the Mac reads to know where a Live Activity can be reached). The raw values are the key names in the relay's
/// room, so they never change.
public enum LinkKey: String, CaseIterable, Sendable {
    // State, Mac → phone
    case look, claude, sessions, agent, cloud, approval, macDone
    // State, phone → Mac
    case phoneDone
    // Messages
    case activityEnded, macInteraction, phoneInteraction, command, reply, verdict
    // Registration (phone → relay and Mac)
    case pushToStart, updateTokens, deviceToken, tokensSavedAt

    public enum Kind: Sendable { case state, message, registration }

    public var kind: Kind {
        switch self {
        case .look, .claude, .sessions, .agent, .cloud, .approval, .macDone, .phoneDone: .state
        case .activityEnded, .macInteraction, .phoneInteraction, .command, .reply, .verdict: .message
        case .pushToStart, .updateTokens, .deviceToken, .tokensSavedAt: .registration
        }
    }

    /// The role of the app that writes this key: `host` (the Mac) or `pocket` (the phone). The relay allows the same.
    public var writer: String {
        switch self {
        case .look, .claude, .sessions, .agent, .cloud, .approval, .macDone, .activityEnded, .macInteraction, .reply: "host"
        case .phoneDone, .phoneInteraction, .command, .verdict, .pushToStart, .updateTokens, .deviceToken, .tokensSavedAt: "pocket"
        }
    }
}

/// Where Mochi's apps meet: the Mochi Link relay once this device is paired (`RelayLinkStore`), and a store that keeps
/// only this device's own writes until then (`LocalLinkStore`). Values are JSON-compatible (String, Double, Bool, and
/// dictionaries or arrays of those), in the same shapes the apps have always written.
public protocol LinkStore: AnyObject, Sendable {
    func value(_ key: LinkKey) -> Any?
    /// Replaces state or sends a message; nil clears it.
    func set(_ value: Any?, for key: LinkKey)
}

public extension LinkStore {
    func string(_ key: LinkKey) -> String? { value(key) as? String }
    func dictionary(_ key: LinkKey) -> [String: Any]? { value(key) as? [String: Any] }
    func double(_ key: LinkKey) -> Double? { value(key) as? Double }
}

public extension Notification.Name {
    /// Posted on the main queue when another device changed something, or when the store itself changed (pairing,
    /// unpairing). `userInfo["keys"]` holds the changed `[LinkKey]` when the store knows them.
    static let linkStoreDidChange = Notification.Name("MochiLinkStoreDidChange")
}

/// No link: this device isn't paired, so nothing it writes goes anywhere. It keeps its own latest values (reads behave
/// like the relay's), so the app runs normally on its own, and its state is carried into the relay when it pairs.
public final class LocalLinkStore: LinkStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LinkKey: Any]

    public init(_ values: [LinkKey: Any] = [:]) {
        self.values = values
    }

    public func value(_ key: LinkKey) -> Any? { lock.withLock { values[key] } }

    public func set(_ value: Any?, for key: LinkKey) {
        lock.withLock {
            if let value { values[key] = value } else { _ = values.removeValue(forKey: key) }
        }
    }
}
