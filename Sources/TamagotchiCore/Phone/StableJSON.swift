import Foundation

extension JSONEncoder {
    /// The same value always encodes to the same text: keys sorted. `JSONEncoder`'s default key order isn't stable from
    /// one call to the next (on macOS 27 the same value gave 11 different strings in 200 encodes), and the link
    /// compares these strings to decide whether something changed: unstable text meant resending unchanged state every
    /// tick until the relay rate-limited the Mac.
    public static func stableString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }
}
