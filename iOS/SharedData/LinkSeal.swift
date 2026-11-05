import CryptoKit
import Foundation
import Security

/// Mochi Link's encryption where TamagotchiCore isn't linked: the notification extension (opens sealed alerts with the
/// room key K from the shared Keychain) and the Live Activity widget (opens the sealed title and detail with the derived
/// key K_la from a file in the app group, because the Keychain can't be read while a Live Activity renders; spike 0.2).
/// Byte-compatible with `LinkCrypto` / `LinkPush` (docs/MOCHI_LINK_PLAN.md 4.3 and 4.6.1).
enum LinkSeal {
    /// The Keychain group the app shares with its extensions (`keychain-access-groups` in the entitlements).
    static let accessGroup = "CZDJF6N2RH.com.insideedge.mochi.link"
    /// Same as `LinkPush.liveActivityAD`.
    static let liveActivityAD = "mochi-link/v1|live-activity|detail"
    private static let group = "group.com.insideedge.mochi"

    // MARK: The Live Activity key (app group file)

    private static var liveActivityKeyFile: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("link-la-key.bin")
    }

    /// Written by the app when it's paired; readable after the phone's first unlock.
    static func storeLiveActivityKey(_ key: Data) {
        guard let file = liveActivityKeyFile else { return }
        try? key.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func deleteLiveActivityKey() {
        guard let file = liveActivityKeyFile else { return }
        try? FileManager.default.removeItem(at: file)
    }

    static func loadLiveActivityKey() -> SymmetricKey? {
        guard let file = liveActivityKeyFile, let data = try? Data(contentsOf: file), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// The title and detail out of a Live Activity's `sealed` ("nonce.box"); nil when there's no key or it won't open.
    static func openLiveActivity(_ sealed: String) -> (title: String?, detail: String?)? {
        let parts = sealed.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let key = loadLiveActivityKey(),
              let plain = open(nonce: parts[0], box: parts[1], ad: liveActivityAD, key: key),
              let object = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { return nil }
        return (object["title"] as? String, object["detail"] as? String)
    }

    // MARK: Sealed alerts (notification extension)

    /// The room and K from the pairing saved by the app (`LinkCredentialStore`, the same Keychain item).
    private static func room() -> (room: String, key: SymmetricKey)? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.insideedge.mochi.link.credentials",
                                    kSecAttrAccount as String: "room", kSecAttrAccessGroup as String: accessGroup,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let room = saved["room"] as? String, let key = (saved["key"] as? String).flatMap(decode), key.count == 32 else { return nil }
        return (room, SymmetricKey(data: key))
    }

    /// Opens the `mochi` object of a pushed alert: `{"title", "subtitle", "body", "userInfo"}`, or nil.
    static func openAlert(_ mochi: [String: Any]) -> [String: Any]? {
        guard let saved = room(), let id = mochi["id"] as? String, let from = mochi["from"] as? String,
              let nonce = mochi["nonce"] as? String, let box = mochi["box"] as? String,
              (mochi["room"] as? String).map({ $0 == saved.room }) ?? true else { return nil }
        let ad = "mochi-link/v1|\(saved.room)|\(mochi["key"] as? String ?? "alert")|\(id)|\(from)"
        guard let plain = open(nonce: nonce, box: box, ad: ad, key: saved.key) else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    // MARK: AES-GCM

    private static func open(nonce: String, box: String, ad: String, key: SymmetricKey) -> Data? {
        guard let nonceData = decode(nonce), let boxData = decode(box), boxData.count >= 16,
              let gcmNonce = try? AES.GCM.Nonce(data: nonceData),
              let sealed = try? AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: boxData.dropLast(16), tag: boxData.suffix(16)) else {
            return nil
        }
        return try? AES.GCM.open(sealed, using: key, authenticating: Data(ad.utf8))
    }

    static func decode(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }
}
