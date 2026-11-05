import Foundation

/// What a device in a Mochi Link room is, from the relay's `platform` tag. Tags come in any case: the Mac says
/// `macOS`, the iPhone `iOS`, Android `android`, Windows `windows`, Mochi Cloud `cloud`.
public enum LinkPlatform: String, Sendable, CaseIterable {
    case macOS, windows, iOS, android, cloud

    /// Nil for a missing or unknown tag (older relay data).
    public init?(tag: String?) {
        switch tag?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "macos", "mac", "osx", "darwin": self = .macOS
        case "windows", "win32", "win": self = .windows
        case "ios", "ipados", "iphone": self = .iOS
        case "android": self = .android
        case "cloud": self = .cloud
        default: return nil
        }
    }

    /// What people call the device: "Mac", "PC", "iPhone", "Android", "Mochi Cloud".
    public var label: String {
        switch self {
        case .macOS: "Mac"
        case .windows: "PC"
        case .iOS: "iPhone"
        case .android: "Android"
        case .cloud: "Mochi Cloud"
        }
    }

    /// Its system, for device lists: "macOS", "Windows", "iOS", "Android", "Cloud".
    public var systemName: String {
        switch self {
        case .macOS: "macOS"
        case .windows: "Windows"
        case .iOS: "iOS"
        case .android: "Android"
        case .cloud: "Cloud"
        }
    }

    public var isComputer: Bool { self == .macOS || self == .windows }
    public var isPhone: Bool { self == .iOS || self == .android }
}

public extension RelayLinkStore.Peer {
    var linkPlatform: LinkPlatform? { LinkPlatform(tag: platform) }

    /// When it was last seen (the relay counts seconds; very large numbers are taken as milliseconds).
    var lastSeenDate: Date? {
        lastSeen.map { Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1000 : $0) }
    }
}

/// The computer a phone talks to, named for the phone's screens: "your Mac", "your PC", or (when the relay hasn't
/// said which) the name it had when the phone paired, else "your computer".
public struct LinkHostName: Equatable, Sendable {
    /// `.macOS` or `.windows`; nil when unknown.
    public var platform: LinkPlatform?
    /// Its own name ("BELPL-LT-636"), from the relay's device list or the pairing code.
    public var name: String?
    public var online: Bool
    public var lastSeen: Date?

    public init(platform: LinkPlatform? = nil, name: String? = nil, online: Bool = false, lastSeen: Date? = nil) {
        self.platform = platform
        self.name = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.online = online
        self.lastSeen = lastSeen
    }

    /// "Mac" or "PC" (nil when unknown).
    public var kind: String? { platform.flatMap { $0.isComputer ? $0.label : nil } }

    /// For pills and short labels: "Mac", "PC" or "Computer".
    public var short: String { kind ?? "Computer" }

    /// "your Mac", "your PC"; when the platform isn't known, its name, else "your computer".
    public var yours: String {
        if let kind { return "your \(kind)" }
        return name ?? "your computer"
    }

    /// `yours` at the start of a sentence: "Your Mac", "BELPL-LT-636".
    public var yoursCapitalized: String { yours.hasPrefix("your ") ? "Y" + yours.dropFirst() : yours }

    /// "BELPL-LT-636 (Mac)"; only the name when the platform isn't known; `yours` without a name.
    public var labeled: String {
        guard let name else { return yours }
        guard let kind, name.caseInsensitiveCompare(kind) != .orderedSame else { return name }
        return "\(name) (\(kind))"
    }

    /// The status pill while it's connected: "Mac online".
    public var onlineText: String { "\(short) online" }

    /// The status pill while it isn't: "PC away since 2:02 PM" (`since` is the time, formatted by the screen), "Mac away".
    public func awayText(since: String?) -> String {
        since.map { "\(short) away since \($0)" } ?? "\(short) away"
    }
}

/// Names for the devices in a Mochi Link room, the same on every screen: a phone names its computer ("your Mac",
/// "your PC"), a computer names its phones ("your phones", "realme RMX3242 · Android"). Flutter has the same rules
/// in mochi_link's `LinkPeerNames`.
public enum LinkPeerNames {
    /// What a computer calls its phones when it doesn't mean one in particular.
    public static let yourPhones = "your phones"

    // MARK: A phone naming its computer

    /// The room's computers (not `me`), best first: connected ones, then the most recently seen.
    public static func hosts(in peers: [RelayLinkStore.Peer], excluding me: String? = nil) -> [RelayLinkStore.Peer] {
        let hosts = peers.filter { $0.device != me && ($0.role == "host" || $0.linkPlatform?.isComputer == true) }
        return hosts.enumerated().sorted { a, b in
            if a.element.online != b.element.online { return a.element.online }
            let seenA = a.element.lastSeenDate ?? .distantPast, seenB = b.element.lastSeenDate ?? .distantPast
            return seenA != seenB ? seenA > seenB : a.offset < b.offset
        }.map(\.element)
    }

    /// The computer a phone names: an online one first, else the one seen most recently. Until the relay's device
    /// list arrives (or when it doesn't say the platform), `pairedName` (the name in the pairing code) and
    /// `knownPlatform` (the platform this phone last saw for its room) fill in.
    public static func host(in peers: [RelayLinkStore.Peer], excluding me: String? = nil, pairedName: String? = nil,
                            knownPlatform: LinkPlatform? = nil) -> LinkHostName {
        guard let peer = hosts(in: peers, excluding: me).first else {
            return LinkHostName(platform: knownPlatform?.isComputer == true ? knownPlatform : nil, name: pairedName)
        }
        let platform = peer.linkPlatform.flatMap { $0.isComputer ? $0 : nil }
        return LinkHostName(platform: platform ?? (knownPlatform?.isComputer == true ? knownPlatform : nil),
                            name: peer.name ?? pairedName, online: peer.online, lastSeen: peer.lastSeenDate)
    }

    /// Every computer in the room, labeled ("BELPL-LT-636 (Mac) and DESKTOP-7 (PC)"), for "Paired with …". With no
    /// device list yet, the one from the pairing code.
    public static func hostList(in peers: [RelayLinkStore.Peer], excluding me: String? = nil, pairedName: String? = nil,
                                knownPlatform: LinkPlatform? = nil) -> String {
        let all = hosts(in: peers, excluding: me)
        guard !all.isEmpty else { return host(in: [], pairedName: pairedName, knownPlatform: knownPlatform).labeled }
        let labels = all.map { peer in
            LinkHostName(platform: peer.linkPlatform.flatMap { $0.isComputer ? $0 : nil }, name: peer.name ?? pairedName).labeled
        }
        return list(labels)
    }

    // MARK: A computer naming its phones

    /// The phones in the room (not `me`), in the relay's order.
    public static func phones(in peers: [RelayLinkStore.Peer], excluding me: String? = nil) -> [RelayLinkStore.Peer] {
        peers.filter { $0.device != me && ($0.role == "pocket" || $0.linkPlatform?.isPhone == true) }
    }

    /// Whether an iPhone is in the room: the Live Activity, Siri and the Lock Screen widget need one.
    public static func hasIPhone(in peers: [RelayLinkStore.Peer], excluding me: String? = nil) -> Bool {
        phones(in: peers, excluding: me).contains { $0.linkPlatform == .iOS }
    }

    /// What a device is: "iPhone", "Android", "Mac", "PC", "Mochi Cloud"; "Phone" or "Computer" by its role when the
    /// platform isn't known.
    public static func label(for peer: RelayLinkStore.Peer) -> String {
        if let platform = peer.linkPlatform { return platform.label }
        switch peer.role {
        case "pocket": return "Phone"
        case "host": return "Computer"
        case "cloud": return "Mochi Cloud"
        default: return peer.role.isEmpty ? "Device" : peer.role.capitalized
        }
    }

    /// A device list row: its own name and its system, "realme RMX3242 · Android", "iPhone · iOS"; the label alone
    /// when there's nothing more to say.
    public static func row(for peer: RelayLinkStore.Peer) -> String {
        let name = peer.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? label(for: peer)
        guard let system = peer.linkPlatform?.systemName, name.caseInsensitiveCompare(system) != .orderedSame else { return name }
        return "\(name) · \(system)"
    }

    /// The phones by name for a sentence ("realme RMX3242 and iPhone"); `yourPhones` when there are none.
    public static func phoneNames(in peers: [RelayLinkStore.Peer], excluding me: String? = nil) -> String {
        let names = phones(in: peers, excluding: me).map { $0.name ?? label(for: $0) }
        return names.isEmpty ? yourPhones : list(names)
    }

    /// "A", "A and B", "A, B and C".
    public static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
