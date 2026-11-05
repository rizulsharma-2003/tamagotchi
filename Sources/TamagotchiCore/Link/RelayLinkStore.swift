import CryptoKit
import Foundation
import os

/// Mochi Link over the relay (docs/MOCHI_LINK_PLAN.md 4.4): one WebSocket to the room; every value sealed with the room
/// key before it leaves this device and opened (and checked against its room, key, id and sender) when it arrives. The
/// relay only routes ciphertext. Reads behave like iCloud's: the latest value per key, including this device's own
/// writes. While offline, writes wait in an outbox; the socket reconnects with backoff.
public final class RelayLinkStore: NSObject, LinkStore, URLSessionWebSocketDelegate, @unchecked Sendable {
    public struct Peer: Equatable, Sendable {
        public var device: String
        public var role: String
        public var name: String?
        public var online: Bool
        public var lastSeen: Double?
    }

    public enum Status: String, Sendable { case connecting, online, offline }

    public let credentials: LinkCredentials
    private let key: SymmetricKey
    private let lock = NSLock()
    private var values: [LinkKey: Any] = [:]
    /// Frames waiting for a connection: messages in order, state only its newest value.
    private var outbox: [(id: String, key: String?, frame: Data)] = []
    /// Frames sent but not yet acknowledged by the relay, by id; sent again after a reconnect (the relay drops repeats).
    /// `key` names the state key a pending write is for, so a `sync` can't clear or overwrite it with an older value.
    private var unacked: [String: (order: Int, key: String?, frame: Data)] = [:]
    private var sendCount = 0
    /// Message ids already applied (newest last), so a redelivery isn't applied twice.
    private var applied: [String] = []
    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var attempt = 0
    private var _status = Status.offline
    private var _peers: [Peer] = []
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    static let log = Logger(subsystem: "com.mochi.link", category: "relay")

    public init?(credentials: LinkCredentials) {
        guard let raw = LinkCrypto.data(base64url: credentials.key), raw.count == 32 else { return nil }
        self.credentials = credentials
        self.key = SymmetricKey(data: raw)
        super.init()
    }

    public var status: Status { lock.withLock { _status } }
    public var peers: [Peer] { lock.withLock { _peers } }
    /// The other devices that are connected right now.
    public var onlinePeers: [Peer] { peers.filter { $0.online && $0.device != credentials.device } }

    // MARK: LinkStore

    public func value(_ key: LinkKey) -> Any? { lock.withLock { values[key] } }

    public func set(_ value: Any?, for key: LinkKey) {
        lock.withLock {
            if let value { values[key] = value } else { values.removeValue(forKey: key) }
        }
        let id = UUID().uuidString.lowercased()
        guard let frame = Self.frame(value, for: key, credentials: credentials, key: self.key, id: id) else { return }
        send(frame, id: id, replaces: key.kind == .message ? nil : key.rawValue)
    }

    /// Frames go out as soon as they're written.
    public func flush() {}

    public var hasAnyValue: Bool { lock.withLock { !values.isEmpty } }

    // MARK: Pushes (phase 4)

    /// A notification for the phone, sealed with K; the relay pushes it with generic text and the phone's notification
    /// extension opens it (docs/MOCHI_LINK_PLAN.md 4.6.1).
    public func sendAlert(_ inner: [String: Any], category: String?, threadId: String?, priority: Int = 10, collapse: String? = nil,
                          ttl: Int = 3600) {
        let id = UUID().uuidString.lowercased()
        guard let plain = try? JSONSerialization.data(withJSONObject: inner),
              let sealed = try? LinkCrypto.seal(plain, ad: LinkCrypto.associatedData(room: credentials.room, key: "alert", id: id,
                                                                                       from: credentials.device), key: key) else { return }
        var push: [String: Any] = ["kind": "alert", "priority": priority]
        if let collapse { push["collapse"] = collapse }
        if let category { push["category"] = category }
        if let threadId { push["threadId"] = threadId }
        let frame: [String: Any] = ["v": 1, "op": "send", "key": "alert", "id": id, "to": ["pocket"], "ttl": ttl,
                                    "at": Date().timeIntervalSince1970.rounded(), "push": push, "nonce": sealed.nonce, "box": sealed.box]
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        send(data, id: id, replaces: nil)
    }

    /// A Live Activity start, update or end for the phone; `apns` comes from `LinkPush.liveActivity`.
    public func sendLiveActivity(_ apns: [String: Any], priority: Int, collapse: String = "live-activity") {
        let id = UUID().uuidString.lowercased()
        let frame: [String: Any] = ["v": 1, "op": "send", "key": "liveActivity", "id": id, "to": ["pocket"], "ttl": 600,
                                    "at": Date().timeIntervalSince1970.rounded(),
                                    "push": ["kind": "liveactivity", "priority": priority, "collapse": collapse], "apns": apns]
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        // Only the newest waiting update matters; a start or end always goes.
        let event = apns["event"] as? String
        send(data, id: id, replaces: event == "update" ? "liveActivity" : nil)
    }

    /// The phone's push addresses, for the relay only (they never reach other devices).
    public func register(tokens: [String: Any], apnsEnv: String, topic: String) {
        let id = UUID().uuidString.lowercased()
        let frame: [String: Any] = ["v": 1, "op": "register", "id": id, "tokens": tokens, "apnsEnv": apnsEnv, "topic": topic]
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        send(data, id: id, replaces: "register")
    }

    // MARK: Connection

    public func start() {
        lock.withLock { running = true }
        connect()
    }

    public func stop() {
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            running = false
            defer { socket = nil }
            return socket
        }
        task?.cancel(with: .goingAway, reason: nil)
        setStatus(.offline)
    }

    /// Reconnects right away (after waking, or when the network comes back).
    public func reconnectNow() {
        guard lock.withLock({ running && _status != .online }) else { return }
        lock.withLock { attempt = 0 }
        connect()
    }

    private func connect() {
        guard lock.withLock({ running }),
              let url = LinkPairing.url(relay: credentials.relay, path: "/v1/rooms/\(credentials.room)/socket", scheme: "wss") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.bearer)", forHTTPHeaderField: "authorization")
        let task = session.webSocketTask(with: request)
        let old = lock.withLock { () -> URLSessionWebSocketTask? in
            defer { socket = task }
            return socket
        }
        old?.cancel(with: .goingAway, reason: nil)
        setStatus(.connecting)
        task.resume()
        receive(on: task)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard lock.withLock({ socket === webSocketTask }) else { return }
        lock.withLock { attempt = 0 }
        setStatus(.online)
        let hello: [String: Any] = ["v": 1, "op": "hello", "platform": Self.platform, "app": Self.appVersion]
        if let data = try? JSONSerialization.data(withJSONObject: hello) { webSocketTask.send(.data(data)) { _ in } }
        // Whatever the relay never confirmed goes again (oldest first), then what waited offline; everything stays
        // tracked until the relay acknowledges it, so another drop can't lose it.
        let waiting = lock.withLock { () -> [Data] in
            for entry in outbox {
                sendCount += 1
                unacked[entry.id] = (sendCount, entry.key, entry.frame)
            }
            outbox.removeAll()
            return unacked.values.sorted { $0.order < $1.order }.map(\.frame)
        }
        for frame in waiting { webSocketTask.send(.data(frame)) { _ in } }
        schedulePing(for: webSocketTask)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                           reason: Data?) {
        if closeCode.rawValue == 4001 || closeCode.rawValue == 4004 {
            // This device was removed from the room, or the room was deleted: retrying can't help.
            Self.log.notice("relay closed the link for good (\(closeCode.rawValue)): pair again")
            lock.withLock { running = false }
            removed = true
        }
        dropped(webSocketTask, why: "closed \(closeCode.rawValue)")
    }

    /// The relay removed this device or deleted the room; Settings should offer to pair again.
    public private(set) var removed = false

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let socket = task as? URLSessionWebSocketTask else { return }
        dropped(socket, why: error.map { "\($0.localizedDescription)" } ?? "ended")
    }

    private func dropped(_ task: URLSessionWebSocketTask, why: String) {
        let retry = lock.withLock { () -> TimeInterval? in
            guard socket === task else { return nil }
            socket = nil
            guard running else { return nil }
            attempt += 1
            return min(60, pow(2, Double(min(attempt, 6)))) + Double.random(in: 0...1)
        }
        setStatus(.offline)
        guard let retry else { return }
        Self.log.notice("relay connection lost (\(why, privacy: .public)); retrying in \(Int(retry))s")
        DispatchQueue.global().asyncAfter(deadline: .now() + retry) { [weak self] in self?.connect() }
    }

    private func schedulePing(for task: URLSessionWebSocketTask) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.lock.withLock({ self.socket === task }) else { return }
            task.sendPing { [weak self] error in
                if let error { self?.dropped(task, why: "ping: \(error.localizedDescription)") } else { self?.schedulePing(for: task) }
            }
        }
    }

    private func send(_ frame: Data, id: String, replaces stateKey: String?) {
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            if _status == .online, let socket {
                sendCount += 1
                unacked[id] = (sendCount, stateKey, frame)
                if unacked.count > 128, let oldest = unacked.min(by: { $0.value.order < $1.value.order })?.key {
                    unacked.removeValue(forKey: oldest)
                }
                return socket
            }
            if let stateKey { outbox.removeAll { $0.key == stateKey } }
            outbox.append((id, stateKey, frame))
            if outbox.count > 64 { outbox.removeFirst(outbox.count - 64) }
            return nil
        }
        task?.send(.data(frame)) { error in
            // Stays in `unacked`, so the next connection sends it again.
            if let error { Self.log.error("relay send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: Receiving

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let data: Data?
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: data = nil
                }
                if let data, let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.handle(frame, on: task) }
                self.receive(on: task)
            case .failure(let error):
                self.dropped(task, why: error.localizedDescription)
            }
        }
    }

    private func handle(_ frame: [String: Any], on task: URLSessionWebSocketTask) {
        switch frame["op"] as? String {
        case "put", "send":
            apply(frame, on: task)
        case "sync":
            // The room's whole state (a key that's missing was cleared), then what was queued for this device.
            let state = Self.envelopes(in: frame["state"])
            clearState(except: Set(state.compactMap { ($0["key"] as? String).flatMap(LinkKey.init(rawValue:)) }))
            for envelope in state { apply(envelope, on: task) }
            for envelope in Self.envelopes(in: frame["queue"]) { apply(envelope, on: task) }
            if let devices = frame["devices"] { updatePeers(devices, names: true) }
            if let presence = frame["presence"] { updatePeers(presence, names: false) }
        case "devices":
            updatePeers(frame["devices"] ?? [], names: true)
        case "presence":
            updatePeers(frame["presence"] ?? [], names: false)
        case "ack":
            // The relay has this frame: it no longer needs sending again.
            if let id = frame["id"] as? String { lock.withLock { _ = unacked.removeValue(forKey: id) } }
        case "error":
            let code = frame["code"] as? String ?? "?"
            Self.log.error("relay refused \(frame["key"] as? String ?? "a frame", privacy: .public): \(code, privacy: .public) \(frame["message"] as? String ?? "", privacy: .public)")
            // A refusal is final: don't keep sending it.
            if let id = frame["id"] as? String { lock.withLock { _ = unacked.removeValue(forKey: id) } }
        default:
            break
        }
    }

    /// Opens one envelope from another device and makes it the current value of its key.
    private func apply(_ envelope: [String: Any], on task: URLSessionWebSocketTask) {
        if envelope["op"] as? String == "send", let id = envelope["id"] as? String,
           let name = envelope["key"] as? String, LinkKey(rawValue: name) == nil {
            acknowledge(id, on: task)
            return
        }
        guard let name = envelope["key"] as? String, let key = LinkKey(rawValue: name), let id = envelope["id"] as? String,
              let from = envelope["from"] as? String,
              let nonce = envelope["nonce"] as? String, let box = envelope["box"] as? String else { return }
        let isMessage = envelope["op"] as? String == "send" || key.kind == .message
        if isMessage { acknowledge(id, on: task) }
        let fresh = lock.withLock { () -> Bool in
            guard !applied.contains(id) else { return false }
            applied.append(id)
            if applied.count > 300 { applied.removeFirst(applied.count - 300) }
            return true
        }
        guard fresh else { return }
        let ad = LinkCrypto.associatedData(room: credentials.room, key: name, id: id, from: from)
        guard let plain = LinkCrypto.open(.init(nonce: nonce, box: box), ad: ad, key: self.key),
              let wrapper = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            Self.log.error("couldn't open a \(name, privacy: .public) from the relay")
            return
        }
        let value = wrapper["v"]
        let applied = lock.withLock { () -> Bool in
            // This device's own newer write is still on its way: the relay's copy is older.
            if !isMessage, pendingStateKeys().contains(name) { return false }
            if let value, !(value is NSNull) { values[key] = value } else { values.removeValue(forKey: key) }
            return true
        }
        guard applied else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .linkStoreDidChange, object: nil, userInfo: ["keys": [key]])
        }
    }

    private func acknowledge(_ id: String, on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["v": 1, "op": "ack", "id": id]) else { return }
        task.send(.data(data)) { _ in }
    }

    /// `devices` frames list everyone with their names; `presence` frames only who's online. Merged by device id.
    private func updatePeers(_ raw: Any, names: Bool) {
        let list = raw as? [[String: Any]] ?? []
        lock.withLock {
            var merged = names ? [] : _peers
            for item in list {
                guard let device = (item["id"] ?? item["device"]) as? String else { continue }
                var peer = merged.first { $0.device == device }
                    ?? _peers.first { $0.device == device }
                    ?? Peer(device: device, role: "", name: nil, online: false, lastSeen: nil)
                if let role = item["role"] as? String { peer.role = role }
                if let name = item["name"] as? String { peer.name = name }
                if let online = item["online"] as? Bool { peer.online = online }
                if let seen = item["lastSeen"] as? Double { peer.lastSeen = seen }
                merged.removeAll { $0.device == device }
                merged.append(peer)
            }
            _peers = merged
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .linkPresenceDidChange, object: nil) }
    }

    /// State keys with a write from this device still waiting or unacknowledged (call with the lock held).
    private func pendingStateKeys() -> Set<String> {
        Set(outbox.compactMap(\.key)).union(unacked.values.compactMap(\.key))
    }

    /// After a `sync`: state keys the room no longer has were cleared while this device was away.
    private func clearState(except present: Set<LinkKey>) {
        let cleared = lock.withLock { () -> [LinkKey] in
            let waiting = pendingStateKeys()
            let gone = values.keys.filter { $0.kind != .message && !present.contains($0) && !waiting.contains($0.rawValue) }
            gone.forEach { values.removeValue(forKey: $0) }
            return gone
        }
        guard !cleared.isEmpty else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .linkStoreDidChange, object: nil, userInfo: ["keys": cleared]) }
    }

    private func setStatus(_ status: Status) {
        let changed = lock.withLock { () -> Bool in
            defer { _status = status }
            return _status != status
        }
        guard changed else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .linkPresenceDidChange, object: nil) }
    }

    // MARK: Frames

    /// A sealed `put` (state) or `send` (message) frame for `value` (nil clears a state key).
    static func frame(_ value: Any?, for key: LinkKey, credentials: LinkCredentials, key roomKey: SymmetricKey,
                      id: String = UUID().uuidString.lowercased(), at: Double = Date().timeIntervalSince1970) -> Data? {
        guard let plain = try? JSONSerialization.data(withJSONObject: ["v": value ?? NSNull()]),
              let sealed = try? LinkCrypto.seal(plain, ad: LinkCrypto.associatedData(room: credentials.room, key: key.rawValue, id: id,
                                                                                       from: credentials.device), key: roomKey) else {
            return nil
        }
        var frame: [String: Any] = ["v": 1, "op": key.kind == .message ? "send" : "put", "key": key.rawValue, "id": id,
                                    "at": at.rounded(), "nonce": sealed.nonce, "box": sealed.box]
        if let to = key.relayTargets { frame["to"] = to }
        if let ttl = key.relayTTL { frame["ttl"] = ttl }
        return try? JSONSerialization.data(withJSONObject: frame)
    }

    /// Opens a frame made by `frame(_:for:...)` (tests, and devices reading their own outbox).
    static func open(_ data: Data, credentials: LinkCredentials, from: String, key roomKey: SymmetricKey) -> Any? {
        guard let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let name = frame["key"] as? String,
              let id = frame["id"] as? String, let nonce = frame["nonce"] as? String, let box = frame["box"] as? String,
              let plain = LinkCrypto.open(.init(nonce: nonce, box: box),
                                          ad: LinkCrypto.associatedData(room: credentials.room, key: name, id: id, from: from), key: roomKey),
              let wrapper = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { return nil }
        return wrapper["v"]
    }

    private static func envelopes(in raw: Any?) -> [[String: Any]] {
        if let list = raw as? [[String: Any]] { return list }
        if let byKey = raw as? [String: Any] { return byKey.values.compactMap { $0 as? [String: Any] } }
        return []
    }

    private static var platform: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

public extension LinkKey {
    /// Who a message goes to: commands and verdicts to the computer, replies and pokes to the phone.
    var relayTargets: [String]? {
        switch self {
        case .command, .verdict, .phoneInteraction: ["host"]
        case .reply, .macInteraction, .activityEnded: ["pocket"]
        default: nil
        }
    }

    /// Seconds a message waits for an offline device before the relay drops it.
    var relayTTL: Int? {
        switch self {
        case .command, .verdict, .reply: 600
        case .phoneInteraction, .macInteraction: 90
        case .activityEnded: 3600
        default: nil
        }
    }
}

public extension Notification.Name {
    /// Posted on the main queue when the relay connection or the list of connected devices changes.
    static let linkPresenceDidChange = Notification.Name("MochiLinkPresenceDidChange")
}

/// What the apps talk through: with a paired relay, the relay first and iCloud as a backup (both get every write until
/// iCloud is switched off in phase 6); without one, iCloud alone.
public final class HybridLinkStore: LinkStore, @unchecked Sendable {
    public let relay: RelayLinkStore
    private let backup: LinkStore

    public init(relay: RelayLinkStore, backup: LinkStore = ICloudLinkStore.shared) {
        self.relay = relay
        self.backup = backup
    }

    public func value(_ key: LinkKey) -> Any? { relay.value(key) ?? backup.value(key) }

    public func set(_ value: Any?, for key: LinkKey) {
        relay.set(value, for: key)
        backup.set(value, for: key)
    }

    public func flush() { backup.flush() }

    public var hasAnyValue: Bool { relay.hasAnyValue || backup.hasAnyValue }
}

/// The link this app uses right now. Starts on iCloud; `use(_:)` switches to the relay once this device is paired.
public enum MochiLink {
    nonisolated(unsafe) public private(set) static var store: LinkStore = ICloudLinkStore.shared

    /// The relay connection, when paired.
    public static var relay: RelayLinkStore? { (store as? HybridLinkStore)?.relay }

    /// Uses the relay with these credentials (keeping iCloud as a backup), or iCloud alone with nil.
    public static func use(_ credentials: LinkCredentials?) {
        relay?.stop()
        if let credentials, let relay = RelayLinkStore(credentials: credentials) {
            store = HybridLinkStore(relay: relay)
            relay.start()
        } else {
            store = ICloudLinkStore.shared
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .linkStoreDidChange, object: nil)
            NotificationCenter.default.post(name: .linkPresenceDidChange, object: nil)
        }
    }
}
