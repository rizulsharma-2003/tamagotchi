import Foundation
import Security

/// This device's place in a Mochi Link room: where the relay is, the room, this device's credential, and the room key
/// K. Kept in the Keychain (the Mac's login Keychain; on the iPhone a group shared with its extensions).
public struct LinkCredentials: Codable, Equatable, Sendable {
    /// The relay's host, e.g. `mochi-link.example.workers.dev`.
    public var relay: String
    public var room: String
    public var device: String
    public var secret: String
    /// The room key K, base64url. Never sent to the relay.
    public var key: String
    /// host · pocket · cloud
    public var role: String
    /// What this device is paired with ("Rizul's MacBook"), for Settings.
    public var peerName: String?

    public init(relay: String, room: String, device: String, secret: String, key: String, role: String, peerName: String? = nil) {
        self.relay = relay
        self.room = room
        self.device = device
        self.secret = secret
        self.key = key
        self.role = role
        self.peerName = peerName
    }

    /// `Authorization: Bearer <device>.<secret>`.
    public var bearer: String { "\(device).\(secret)" }
}

public enum LinkCredentialStore {
    private static let service = "com.insideedge.mochi.link.credentials"
    private static let account = "room"

    /// `accessGroup`: the iPhone's shared Keychain group, so its extensions can read it; nil on the Mac.
    @discardableResult
    public static func save(_ credentials: LinkCredentials, accessGroup: String? = nil) -> Bool {
        delete(accessGroup: accessGroup)
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        var item = base(accessGroup)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Mochi Link"
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func load(accessGroup: String? = nil) -> LinkCredentials? {
        var query = base(accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(LinkCredentials.self, from: data)
    }

    @discardableResult
    public static func delete(accessGroup: String? = nil) -> Bool {
        SecItemDelete(base(accessGroup) as CFDictionary) == errSecSuccess
    }

    private static func base(_ accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// The relay's HTTP calls for pairing (docs/MOCHI_LINK_PLAN.md 4.2).
public enum LinkPairing {
    public struct Problem: Error, LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }

        public init(message: String) { self.message = message }
    }

    /// The host makes a room and becomes its first device. The room key K is made here and never leaves the devices.
    public static func createRoom(relay: String, platform: String, name: String) async throws -> LinkCredentials {
        let body = try await call(relay: relay, path: "/v1/rooms", method: "POST", body: ["platform": platform, "name": name])
        guard let room = body["room"] as? String, let device = body["device"] as? String, let secret = body["secret"] as? String else {
            throw Problem(message: "The relay's answer didn't include a room.")
        }
        return LinkCredentials(relay: relay, room: room, device: device, secret: secret,
                               key: LinkCrypto.base64url(LinkCrypto.newRoomKey().withUnsafeBytes { Data($0) }), role: "host")
    }

    /// A single-use invitation (10 minutes) for the QR code.
    public static func invite(_ credentials: LinkCredentials, hostName: String, role: String? = nil) async throws -> PairingCode {
        let body = try await call(relay: credentials.relay, path: "/v1/rooms/\(credentials.room)/invites", method: "POST",
                                  body: role.map { ["role": $0] } ?? [:], bearer: credentials.bearer)
        guard let invite = body["invite"] as? String else { throw Problem(message: "The relay didn't make an invitation.") }
        return PairingCode(relay: credentials.relay, room: credentials.room, invite: invite, key: credentials.key, name: hostName)
    }

    /// The scanning device joins with the code and gets its own credential.
    public static func join(_ code: PairingCode, role: String, platform: String, name: String) async throws -> LinkCredentials {
        let body = try await call(relay: code.relay, path: "/v1/rooms/\(code.room)/join", method: "POST",
                                  body: ["invite": code.invite, "role": role, "platform": platform, "name": name])
        guard let device = body["device"] as? String, let secret = body["secret"] as? String else {
            throw Problem(message: "The relay didn't let this device join. The code may have expired: make a new one.")
        }
        return LinkCredentials(relay: code.relay, room: code.room, device: device, secret: secret, key: code.key, role: role,
                               peerName: code.name)
    }

    /// Deletes the whole room on the relay (host only): every device has to pair again.
    public static func deleteRoom(_ credentials: LinkCredentials) async throws {
        _ = try await call(relay: credentials.relay, path: "/v1/rooms/\(credentials.room)", method: "DELETE", body: nil,
                           bearer: credentials.bearer)
    }

    /// Removes a device from the room (host only).
    public static func remove(device: String, from credentials: LinkCredentials) async throws {
        _ = try await call(relay: credentials.relay, path: "/v1/rooms/\(credentials.room)/devices/\(device)", method: "DELETE",
                           body: nil, bearer: credentials.bearer)
    }

    /// `https`/`wss` for a real relay; `http`/`ws` for a local one (`localhost:8787` while developing).
    static func url(relay: String, path: String, scheme: String = "https") -> URL? {
        let local = relay.hasPrefix("localhost") || relay.hasPrefix("127.0.0.1")
        let realScheme = local ? (scheme == "wss" ? "ws" : "http") : scheme
        return URL(string: "\(realScheme)://\(relay)\(path)")
    }

    private static func call(relay: String, path: String, method: String, body: [String: Any]?, bearer: String? = nil) async throws -> [String: Any] {
        guard let url = url(relay: relay, path: path) else { throw Problem(message: "That relay address doesn't look right.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let reason = (json["error"] as? String) ?? (json["message"] as? String) ?? "status \(status)"
            throw Problem(message: "The relay said no (\(reason)).")
        }
        return json
    }
}
