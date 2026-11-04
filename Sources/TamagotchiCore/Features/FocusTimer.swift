import Foundation

/// A focus block that ran to the end. Only these go into the focus log and the recap.
public struct FocusBlock: Codable, Sendable, Equatable {
    public var endedAt: Date
    public var minutes: Double

    public init(endedAt: Date, minutes: Double) {
        self.endedAt = endedAt
        self.minutes = minutes
    }
}

/// The focus buddy's phase machine: focus → short break → focus … with a long break after
/// every `cyclesBeforeLongBreak` focus blocks; the set is done when the long break ends.
/// Pure: the app feeds it the time and acts on the transitions it returns.
public struct FocusTimer: Sendable, Equatable {
    public struct Durations: Sendable, Equatable {
        public var focus: TimeInterval
        public var shortBreak: TimeInterval
        public var longBreak: TimeInterval
        public var cyclesBeforeLongBreak: Int

        public init(focus: TimeInterval, shortBreak: TimeInterval, longBreak: TimeInterval, cyclesBeforeLongBreak: Int) {
            self.focus = max(1, focus)
            self.shortBreak = max(1, shortBreak)
            self.longBreak = max(1, longBreak)
            self.cyclesBeforeLongBreak = max(1, cyclesBeforeLongBreak)
        }

        /// From the user's settings (minutes), within sensible bounds.
        public init(_ settings: FocusSettings) {
            self.init(focus: TimeInterval(min(max(settings.workMinutes, 1), 180) * 60),
                      shortBreak: TimeInterval(min(max(settings.breakMinutes, 1), 60) * 60),
                      longBreak: TimeInterval(min(max(settings.longBreakMinutes, 1), 90) * 60),
                      cyclesBeforeLongBreak: min(max(settings.cyclesBeforeLongBreak, 1), 12))
        }

        func length(of phase: FocusStatus.Phase) -> TimeInterval {
            switch phase {
            case .focus: return focus
            case .shortBreak: return shortBreak
            case .longBreak: return longBreak
            }
        }
    }

    public struct Running: Sendable, Equatable {
        public var phase: FocusStatus.Phase
        public var startedAt: Date
        public var duration: TimeInterval
        /// 1-based focus block number.
        public var cycle: Int

        public var endsAt: Date { startedAt.addingTimeInterval(duration) }
    }

    public enum Transition: Sendable, Equatable {
        /// A phase began (the first focus block, a break, the next focus block).
        case started(FocusStatus.Phase, cycle: Int)
        /// A focus block ran to its end.
        case focusCompleted(FocusBlock)
        /// The long break ended: the whole set is done.
        case finished(blocks: Int)
        /// The user stopped the session.
        case stopped
        /// The current phase ended long ago (the Mac was asleep): the session ends quietly
        /// and nothing is counted for the unseen time.
        case expired
    }

    /// A phase whose end is noticed later than this is treated as slept through.
    public static let staleAfter: TimeInterval = 10 * 60

    public var durations: Durations
    public private(set) var running: Running?
    /// Focus blocks completed in this session (skipped ones don't count).
    public private(set) var completedBlocks = 0

    public init(durations: Durations) {
        self.durations = durations
    }

    public var isRunning: Bool { running != nil }

    /// The world's view of the session; Mochi naps through focus blocks when `naps` is on.
    public func status(naps: Bool) -> FocusStatus? {
        running.map { FocusStatus(phase: $0.phase, startedAt: $0.startedAt, duration: $0.duration, cycle: $0.cycle,
                                  petNaps: naps && $0.phase == .focus) }
    }

    /// Starts a new session with the first focus block (restarts a running one).
    @discardableResult
    public mutating func start(at date: Date) -> [Transition] {
        completedBlocks = 0
        running = Running(phase: .focus, startedAt: date, duration: durations.focus, cycle: 1)
        return [.started(.focus, cycle: 1)]
    }

    @discardableResult
    public mutating func stop(at date: Date) -> [Transition] {
        guard running != nil else { return [] }
        running = nil
        return [.stopped]
    }

    /// Ends the current phase now: a skipped focus block is not counted as completed.
    @discardableResult
    public mutating func skip(at date: Date) -> [Transition] {
        guard let current = running else { return [] }
        return next(after: current, at: date, completed: false)
    }

    /// Moves on when the current phase is over. Call about once a second.
    @discardableResult
    public mutating func advance(to now: Date) -> [Transition] {
        guard let current = running, now >= current.endsAt else { return [] }
        if now.timeIntervalSince(current.endsAt) > Self.staleAfter {
            running = nil
            return [.expired]
        }
        // Chain exactly when noticed on time, so the schedule doesn't drift; otherwise from now.
        let start = now.timeIntervalSince(current.endsAt) < 2 ? current.endsAt : now
        return next(after: current, at: start, completed: true)
    }

    private mutating func next(after current: Running, at date: Date, completed: Bool) -> [Transition] {
        var transitions: [Transition] = []
        switch current.phase {
        case .focus:
            if completed {
                completedBlocks += 1
                transitions.append(.focusCompleted(FocusBlock(endedAt: current.endsAt, minutes: current.duration / 60)))
            }
            let phase: FocusStatus.Phase = current.cycle % durations.cyclesBeforeLongBreak == 0 ? .longBreak : .shortBreak
            running = Running(phase: phase, startedAt: date, duration: durations.length(of: phase), cycle: current.cycle)
            transitions.append(.started(phase, cycle: current.cycle))
        case .shortBreak:
            running = Running(phase: .focus, startedAt: date, duration: durations.focus, cycle: current.cycle + 1)
            transitions.append(.started(.focus, cycle: current.cycle + 1))
        case .longBreak:
            running = nil
            transitions.append(.finished(blocks: completedBlocks))
        }
        return transitions
    }
}

extension FocusTimer {
    /// The notification for a break, if the user asked for banners.
    public static func breakBanner(phase: FocusStatus.Phase, petName: String) -> BannerContent {
        BannerContent(title: phase == .longBreak ? "Long break!" : "Stretch break!",
                      body: "\(petName) is awake. Stand up, stretch and rest your eyes.")
    }
}
