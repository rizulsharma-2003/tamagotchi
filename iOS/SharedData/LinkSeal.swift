import CryptoKit
import Foundation
import Security

/// Mochi Link's room key on this iPhone and AES-256-GCM sealing (docs/MOCHI_LINK_PLAN.md 4.3). The key lives in a
/// Keychain group the app shares with its Lock Screen and notification extensions, readable after the first unlock so
/// a locked phone can still open a Live Activity or a notification. Sealed text is "nonce.box" in base64url without
/// padding, box = ciphertext || tag, exactly as in link-spec/vectors.json.
enum LinkSeal {
    /// The shared Keychain group (`$(AppIdentifierPrefix)com.insideedge.mochi.link` in the entitlements).
    static let accessGroup = "CZDJF6N2RH.com.insideedge.mochi.link"
    private static let service = "com.insideedge.mochi.link"
    private static let account = "room-key"

    // MARK: The room key

    @discardableResult
    static func storeKey(_ key: SymmetricKey) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecAttrAccessGroup as String: accessGroup]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        lastStatus = status
        // Spike 0.2: also a copy in the app group, protected until the first unlock, to compare with the Keychain.
        if let file = keyFile {
            try? key.withUnsafeBytes { Data($0) }.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return status == errSecSuccess
    }

    /// The last Keychain result (for the spike log).
    nonisolated(unsafe) static var lastStatus: OSStatus = 0

    private static var keyFile: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.insideedge.mochi")?
            .appendingPathComponent("link-key.bin")
    }

    /// Spike 0.2: the key from the app group file instead of the Keychain.
    static func loadFileKey() -> SymmetricKey? {
        guard let file = keyFile, let data = try? Data(contentsOf: file), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecAttrAccessGroup as String: accessGroup,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        lastStatus = status
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    /// Associated data for a Live Activity's sealed detail line.
    static let liveActivityAD = "mochi-link/v1|live-activity|detail"

    // MARK: Sealing

    static func seal(_ text: String, ad: String, key: SymmetricKey) -> String? {
        guard let box = try? AES.GCM.seal(Data(text.utf8), using: key, nonce: AES.GCM.Nonce(), authenticating: Data(ad.utf8)) else {
            return nil
        }
        return encode(Data(box.nonce)) + "." + encode(box.ciphertext + box.tag)
    }

    /// Opens "nonce.box" with the room key in the Keychain; nil when there's no key or it doesn't open.
    static func open(_ sealed: String, ad: String, key: SymmetricKey? = loadKey()) -> String? {
        let parts = sealed.split(separator: ".")
        guard let key, parts.count == 2, let nonceData = decode(String(parts[0])), let box = decode(String(parts[1])),
              box.count >= 16, let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: box.dropLast(16), tag: box.suffix(16)),
              let plain = try? AES.GCM.open(sealedBox, using: key, authenticating: Data(ad.utf8)) else {
            return nil
        }
        return String(data: plain, encoding: .utf8)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }

    // MARK: Spike 0.2 log

    /// Notes what an extension managed to open, in the app group (read back with devicectl).
    static func note(_ line: String) {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.insideedge.mochi") else { return }
        let url = folder.appendingPathComponent("link-spike.txt")
        let entry = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }
}
