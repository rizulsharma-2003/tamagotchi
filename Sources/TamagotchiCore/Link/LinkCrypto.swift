import CryptoKit
import Foundation

/// Mochi Link's end-to-end encryption (docs/MOCHI_LINK_PLAN.md 4.3): AES-256-GCM with the room key K, a random
/// 12-byte nonce, and associated data that ties each message to its room, key name, id and sender, so the relay can't
/// move it anywhere else without it failing to open. Byte-for-byte compatible with `link-spec/vectors.json`, which the
/// relay (TypeScript), Mochi Cloud (Python) and the Flutter apps (Dart) check too.
public enum LinkCrypto {
    public struct Sealed: Equatable, Sendable {
        /// base64url, no padding.
        public var nonce: String
        /// base64url, no padding: ciphertext || 16-byte tag.
        public var box: String

        public init(nonce: String, box: String) {
            self.nonce = nonce
            self.box = box
        }
    }

    /// `mochi-link/v1|<room>|<key>|<id>|<from>`.
    public static func associatedData(room: String, key: String, id: String, from: String) -> String {
        "mochi-link/v1|\(room)|\(key)|\(id)|\(from)"
    }

    /// A new room key: 32 random bytes.
    public static func newRoomKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func seal(_ plaintext: Data, ad: String, key: SymmetricKey, nonce: Data? = nil) throws -> Sealed {
        let gcmNonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: gcmNonce, authenticating: Data(ad.utf8))
        return Sealed(nonce: base64url(Data(gcmNonce)), box: base64url(sealed.ciphertext + sealed.tag))
    }

    /// The plaintext, or nil when the box doesn't open (wrong key, changed AD or tampered bytes).
    public static func open(_ sealed: Sealed, ad: String, key: SymmetricKey) -> Data? {
        guard let nonceData = data(base64url: sealed.nonce), let box = data(base64url: sealed.box), box.count >= 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: box.dropLast(16), tag: box.suffix(16)) else {
            return nil
        }
        return try? AES.GCM.open(sealedBox, using: key, authenticating: Data(ad.utf8))
    }

    /// The key the Live Activity widget gets instead of K (it can't read the Keychain while it renders; spike 0.2).
    /// A leaked copy opens Live Activity text and nothing else.
    public static func liveActivityKey(from roomKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: roomKey, info: Data("mochi-link/v1 live-activity".utf8), outputByteCount: 32)
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64url text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }
}

/// A pairing invitation, shown by the host as a QR code (docs/MOCHI_LINK_PLAN.md 4.2):
/// `mochi://pair?v=1&relay=<host>&room=<roomId>&invite=<code>&key=<base64url(K)>&name=<host name>`.
public struct PairingCode: Equatable, Sendable {
    public var relay: String
    public var room: String
    public var invite: String
    /// The room key K, base64url.
    public var key: String
    /// The host's name, shown on the device that scans ("Pair with Rizul's MacBook?").
    public var name: String

    public init(relay: String, room: String, invite: String, key: String, name: String) {
        self.relay = relay
        self.room = room
        self.invite = invite
        self.key = key
        self.name = name
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "mochi"
        parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "relay", value: relay),
                            URLQueryItem(name: "room", value: room), URLQueryItem(name: "invite", value: invite),
                            URLQueryItem(name: "key", value: key), URLQueryItem(name: "name", value: name)]
        return parts.url!
    }

    /// Reads a scanned or pasted code; nil unless it's a complete version 1 code with a 32-byte key.
    public init?(url: URL) {
        guard url.scheme == "mochi", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard item("v") == "1", let relay = item("relay"), let room = item("room"), let invite = item("invite"),
              let key = item("key"), LinkCrypto.data(base64url: key)?.count == 32 else { return nil }
        self.init(relay: relay, room: room, invite: invite, key: key, name: item("name") ?? "Mochi")
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }
}

/// One frame on the wire (docs/MOCHI_LINK_PLAN.md 4.4). `box` and `nonce` carry the sealed inner JSON; everything
/// else is routing the relay may read.
public struct LinkEnvelope: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case put, send, ack, hello, sync, presence, devices, register, error }

    public struct PushHint: Codable, Equatable, Sendable {
        /// alert · background · liveactivity
        public var kind: String
        public var priority: Int?
        public var collapse: String?

        public init(kind: String, priority: Int? = nil, collapse: String? = nil) {
            self.kind = kind
            self.priority = priority
            self.collapse = collapse
        }
    }

    public var v = 1
    public var op: Op
    public var key: String?
    public var id: String?
    /// Filled in by the relay from the device's credential; never trusted from a client.
    public var from: String?
    /// A role ("host") or device ids; nil means everyone else in the room.
    public var to: [String]?
    public var at: Double?
    /// Messages only: seconds before the relay drops it undelivered.
    public var ttl: Int?
    public var push: PushHint?
    public var nonce: String?
    public var box: String?

    public init(op: Op, key: String? = nil, id: String? = nil, from: String? = nil, to: [String]? = nil, at: Double? = nil,
                ttl: Int? = nil, push: PushHint? = nil, sealed: LinkCrypto.Sealed? = nil) {
        self.op = op
        self.key = key
        self.id = id
        self.from = from
        self.to = to
        self.at = at
        self.ttl = ttl
        self.push = push
        self.nonce = sealed?.nonce
        self.box = sealed?.box
    }

    public var sealed: LinkCrypto.Sealed? {
        guard let nonce, let box else { return nil }
        return LinkCrypto.Sealed(nonce: nonce, box: box)
    }
}
