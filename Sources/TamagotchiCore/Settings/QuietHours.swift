import Foundation

/// A daily quiet window, e.g. 22:00–08:00 (wrapping past midnight is supported).
public struct QuietHours: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Minutes after midnight.
    public var startMinute: Int
    public var endMinute: Int

    public init(enabled: Bool = false, startMinute: Int = 22 * 60, endMinute: Int = 8 * 60) {
        self.enabled = enabled
        self.startMinute = QuietHours.clamp(startMinute)
        self.endMinute = QuietHours.clamp(endMinute)
    }

    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinute != endMinute else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }

    static func clamp(_ minute: Int) -> Int {
        ((minute % 1440) + 1440) % 1440
    }

    public static func format(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
