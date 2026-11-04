import Foundation

/// How the Mac is being used, sampled every few seconds, so Mochi can keep its rhythm: how long
/// since the last keyboard, mouse or trackpad input (the duration only, never what it was), whether
/// the displays are asleep, whether something keeps them on (a video, a call, a presentation) and
/// how busy the processor is.
public struct SystemActivity: Equatable, Sendable {
    public var idleSeconds: TimeInterval
    public var displaysAsleep: Bool
    public var keepsDisplayAwake: Bool
    /// 0…1 across all cores, smoothed over about a minute.
    public var cpuLoad: Double

    public init(idleSeconds: TimeInterval, displaysAsleep: Bool = false, keepsDisplayAwake: Bool = false, cpuLoad: Double = 0) {
        self.idleSeconds = idleSeconds
        self.displaysAsleep = displaysAsleep
        self.keepsDisplayAwake = keepsDisplayAwake
        self.cpuLoad = cpuLoad
    }

    /// Above this the Mac counts as busy, even with nobody at it (a build, an export).
    public static let busyLoad = 0.6

    /// Someone is at the Mac right now.
    public var userActive: Bool { !displaysAsleep && idleSeconds < 30 }

    /// The Mac is resting: its displays are asleep, or nobody has touched it for `restAfter` while
    /// nothing keeps the screen on and the processor is calm.
    public func isResting(after restAfter: TimeInterval) -> Bool {
        displaysAsleep || (idleSeconds >= restAfter && !keepsDisplayAwake && cpuLoad < Self.busyLoad)
    }
}
