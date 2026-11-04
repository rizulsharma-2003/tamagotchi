import Foundation

/// When Mochi sets off on an adventure by itself: after a seeded stretch of eligible time (about
/// 45–60 min "sometimes", 2–3 h "rarely"), counted only while nothing needs anyone (no Claude
/// session working or waiting, no quiet hours, not paused, no Reduced Motion).
public struct AdventureScheduler: Equatable, Sendable {
    public private(set) var frequency: AdventureFrequency
    /// Eligible time counted towards the next adventure.
    public private(set) var accumulated: TimeInterval = 0
    /// Eligible time the next adventure waits for (infinite for "never").
    public private(set) var threshold: TimeInterval = .infinity
    private var rng: SplitMix64
    private var lastTick: TimeInterval?

    /// Gaps between ticks longer than this (sleep, a stalled run loop) count as this much.
    static let maxStep: TimeInterval = 5

    public init(seed: UInt64, frequency: AdventureFrequency) {
        rng = SplitMix64(seed: seed ^ 0x5350_4F4E_5441_4E45)
        self.frequency = frequency
        threshold = drawThreshold()
    }

    /// The stretch of eligible time between two adventures.
    public static func interval(for frequency: AdventureFrequency) -> ClosedRange<TimeInterval>? {
        switch frequency {
        case .never: return nil
        case .rarely: return 2 * 3_600...3 * 3_600
        case .sometimes: return 45 * 60...60 * 60
        }
    }

    /// Counts the time since the last tick if `eligible`; true when an adventure should start now.
    public mutating func tick(now: TimeInterval, eligible: Bool, frequency: AdventureFrequency) -> Bool {
        if frequency != self.frequency {
            self.frequency = frequency
            accumulated = 0
            threshold = drawThreshold()
        }
        defer { lastTick = now }
        guard let last = lastTick, eligible else { return false }
        accumulated += Swift.min(Self.maxStep, Swift.max(0, now - last))
        guard accumulated >= threshold else { return false }
        reset()
        return true
    }

    /// An adventure happened (by itself or because you asked): the next one is a whole stretch away.
    public mutating func reset() {
        accumulated = 0
        threshold = drawThreshold()
    }

    private mutating func drawThreshold() -> TimeInterval {
        guard let interval = Self.interval(for: frequency) else { return .infinity }
        return rng.next(in: interval)
    }
}
