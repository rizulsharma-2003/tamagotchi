import Foundation

/// Settings for the focus buddy (Pomodoro-style timer).
public struct FocusSettings: Codable, Sendable, Equatable {
    public var workMinutes = 25
    public var breakMinutes = 5
    public var longBreakMinutes = 15
    public var cyclesBeforeLongBreak = 4
    public var napsDuringFocus = true
    public var chimeAtBreak = true
    /// Also post a notification banner when a break starts (off by default, like every banner).
    public var bannerAtBreak = false
    public init() {}

    /// Missing keys keep their defaults, so adding a setting never resets the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workMinutes = try c.decodeIfPresent(Int.self, forKey: .workMinutes) ?? 25
        breakMinutes = try c.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 5
        longBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .longBreakMinutes) ?? 15
        cyclesBeforeLongBreak = try c.decodeIfPresent(Int.self, forKey: .cyclesBeforeLongBreak) ?? 4
        napsDuringFocus = try c.decodeIfPresent(Bool.self, forKey: .napsDuringFocus) ?? true
        chimeAtBreak = try c.decodeIfPresent(Bool.self, forKey: .chimeAtBreak) ?? true
        bannerAtBreak = try c.decodeIfPresent(Bool.self, forKey: .bannerAtBreak) ?? false
    }
}

/// The focus buddy's current phase, as the world sees it.
public struct FocusStatus: Sendable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case focus, shortBreak, longBreak
    }

    public var phase: Phase
    public var startedAt: Date
    public var duration: TimeInterval
    /// 1-based focus block number.
    public var cycle: Int
    /// Mochi naps through this phase.
    public var petNaps: Bool

    public init(phase: Phase, startedAt: Date, duration: TimeInterval, cycle: Int, petNaps: Bool) {
        self.phase = phase
        self.startedAt = startedAt
        self.duration = duration
        self.cycle = cycle
        self.petNaps = petNaps
    }

    public func remaining(at date: Date) -> TimeInterval { max(0, duration - date.timeIntervalSince(startedAt)) }

    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(startedAt) / duration))
    }
}

extension FocusStatus.Phase {
    public var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Break"
        case .longBreak: return "Long break"
        }
    }

    public var isBreak: Bool { self != .focus }
}

extension FocusStatus {
    /// "18:42" (or "1:05:00" past an hour), rounded up so it never shows 0:00 early.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
