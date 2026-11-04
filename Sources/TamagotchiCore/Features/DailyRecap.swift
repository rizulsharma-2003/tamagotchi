import Foundation

/// Settings for the end-of-day recap card.
public struct RecapSettings: Codable, Sendable, Equatable {
    /// Announce the day's recap once in the evening, when there was real activity.
    public var announce = true
    /// Local hour (0–23) from which the recap is announced.
    public var hour = 18
    /// Also post a notification banner (off by default, like every banner).
    public var banner = false
    /// The last day ("yyyy-MM-dd") the recap was announced, so it happens once a day.
    public var lastAnnouncedDay: String?
    public init() {}

    /// Missing keys keep their defaults, so adding a setting never resets the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        announce = try c.decodeIfPresent(Bool.self, forKey: .announce) ?? true
        hour = min(23, max(0, try c.decodeIfPresent(Int.self, forKey: .hour) ?? 18))
        banner = try c.decodeIfPresent(Bool.self, forKey: .banner) ?? false
        lastAnnouncedDay = try c.decodeIfPresent(String.self, forKey: .lastAnnouncedDay)
    }

    /// True when the evening announcement is due now: on, past the hour, not yet done
    /// today, and only for a day with real activity.
    public func isAnnouncementDue(at now: Date, hasActivity: Bool, calendar: Calendar = .current) -> Bool {
        guard announce, hasActivity, calendar.component(.hour, from: now) >= hour else { return false }
        return lastAnnouncedDay != DailyRecap.dayKey(now, calendar: calendar)
    }
}

/// One day's real Claude Code activity, computed from the event journal and the focus log.
///
/// Every number comes from recorded, non-simulated events. What isn't recorded stays
/// zero/nil and its tile is left out; nothing is estimated. When history doesn't reach
/// back far enough, the recap says so (`coverage`, `streakIsLowerBound`).
public struct DailyRecap: Sendable, Equatable {
    public enum Coverage: Sendable, Equatable {
        /// History covers the whole day.
        case full
        /// History only starts during the day (retention or the event cap).
        case partial(since: Date)
        /// The day is older than the history kept.
        case none
    }

    /// Start of the day.
    public var day: Date
    public var coverage: Coverage
    /// Distinct Claude Code sessions with events that day.
    public var sessions = 0
    public var turnsFinished = 0
    public var toolCalls = 0
    /// The most used kind of tool (never "other").
    public var topToolCategory: ToolCategory?
    /// Passing builds/tests from explicit reports or build/test commands with a trustworthy exit status.
    public var buildsPassed = 0
    public var testsPassed = 0
    /// Failures (tool errors, API errors, failed builds/tests) followed later by a finished turn in the same session.
    public var errorsBouncedBack = 0
    public var milestones = 0
    public var firstActivity: Date?
    public var lastActivity: Date?
    /// Completed focus blocks that ended that day.
    public var focusBlocks = 0
    public var focusMinutes = 0.0
    /// Consecutive days with real activity, ending on this day (0 when the day had none).
    public var streak = 0
    /// The streak reaches the start of the kept history, so it may well be longer.
    public var streakIsLowerBound = false

    public var hasActivity: Bool { firstActivity != nil }
    /// Nothing at all to show.
    public var isQuiet: Bool { !hasActivity && focusBlocks == 0 }

    /// Time from the first to the last event, when that is at least a minute.
    public var activeSpan: TimeInterval? {
        guard let first = firstActivity, let last = lastActivity, last.timeIntervalSince(first) >= 60 else { return nil }
        return last.timeIntervalSince(first)
    }

    // MARK: Computing

    /// - Parameters:
    ///   - events: the journal (simulated and unknown events are ignored here too).
    ///   - historyStart: from when on the history is complete (the later of the retention cutoff,
    ///     the oldest event when the journal is at its size cap, and when the app first ran).
    public static func compute(day date: Date, events: [CompanionEvent], focus: [FocusBlock], historyStart: Date,
                               calendar: Calendar = .current) -> DailyRecap {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let coverage: Coverage = historyStart <= dayStart ? .full : (historyStart < dayEnd ? .partial(since: historyStart) : .none)
        var recap = DailyRecap(day: dayStart, coverage: coverage)

        let real = events.filter { !$0.isSimulated && $0.kind != .unknown }
        let today = real.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }.sorted { $0.timestamp < $1.timestamp }

        recap.sessions = Set(today.compactMap(\.sessionID)).count
        recap.turnsFinished = today.filter { $0.kind == .turnCompleted }.count
        let starts = today.filter { $0.kind == .toolStarting }
        let finishes = today.filter { $0.kind == .toolSucceeded || $0.kind == .toolFailed }
        recap.toolCalls = max(starts.count, finishes.count)
        recap.topToolCategory = topCategory(starts.isEmpty ? finishes : starts)
        for outcome in today.compactMap(\.buildTestOutcome) where outcome.passed {
            if outcome.kind == .build { recap.buildsPassed += 1 } else { recap.testsPassed += 1 }
        }
        recap.milestones = today.filter { $0.kind == .report && $0.report?.kind == .milestone }.count
        recap.errorsBouncedBack = bouncedBack(today)
        recap.firstActivity = today.first?.timestamp
        recap.lastActivity = today.last?.timestamp

        let blocks = focus.filter { $0.endedAt >= dayStart && $0.endedAt < dayEnd }
        recap.focusBlocks = blocks.count
        recap.focusMinutes = blocks.reduce(0) { $0 + $1.minutes }

        let activeDays = Set(real.map { calendar.startOfDay(for: $0.timestamp) })
        (recap.streak, recap.streakIsLowerBound) = streak(endingOn: dayStart, activeDays: activeDays, historyStart: historyStart,
                                                          calendar: calendar)
        return recap
    }

    static func topCategory(_ events: [CompanionEvent]) -> ToolCategory? {
        var counts: [ToolCategory: Int] = [:]
        for event in events {
            if let category = event.toolCategory, category != .other { counts[category, default: 0] += 1 }
        }
        // Ties go to the earlier category in `allCases`, so the result is stable.
        return ToolCategory.allCases.filter { counts[$0] != nil }.max { counts[$0]! < counts[$1]! }
    }

    /// Failures followed later (that day) by a finished turn in the same session.
    static func bouncedBack(_ events: [CompanionEvent]) -> Int {
        var pending: [String: Int] = [:]
        var bounced = 0
        for event in events {
            guard let session = event.sessionID else { continue }
            if isFailure(event) {
                pending[session, default: 0] += 1
            } else if event.kind == .turnCompleted, let count = pending[session] {
                bounced += count
                pending[session] = nil
            }
        }
        return bounced
    }

    static func isFailure(_ event: CompanionEvent) -> Bool {
        switch event.kind {
        case .toolFailed: return !event.interrupted
        case .turnFailed: return true
        case .report: return event.report?.status == .failed
        default: return false
        }
    }

    /// Walks back day by day from `day` while there was activity. Stops at the first day
    /// without any; if that day isn't fully inside the kept history, the count is a lower bound.
    static func streak(endingOn day: Date, activeDays: Set<Date>, historyStart: Date, calendar: Calendar) -> (Int, Bool) {
        var count = 0
        var cursor = day
        for _ in 0..<3_660 {
            if activeDays.contains(cursor) {
                count += 1
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
                continue
            }
            return (count, count > 0 && historyStart > cursor)
        }
        return (count, true)
    }

    // MARK: Presenting

    /// A stat worth a tile on the card. Zero and missing values never get one.
    public enum Tile: Sendable, Equatable {
        case turns(Int)
        case sessions(Int)
        case toolCalls(Int, top: ToolCategory?)
        case buildsAndTests(builds: Int, tests: Int)
        case bouncedBack(Int)
        case focus(minutes: Int, blocks: Int)
        case activeSpan(from: Date, to: Date)
        case milestones(Int)
    }

    /// The day's tiles in display order (at most eight).
    public var tiles: [Tile] {
        var tiles: [Tile] = []
        if turnsFinished > 0 { tiles.append(.turns(turnsFinished)) }
        if sessions > 0 { tiles.append(.sessions(sessions)) }
        if toolCalls > 0 { tiles.append(.toolCalls(toolCalls, top: topToolCategory)) }
        if buildsPassed + testsPassed > 0 { tiles.append(.buildsAndTests(builds: buildsPassed, tests: testsPassed)) }
        if errorsBouncedBack > 0 { tiles.append(.bouncedBack(errorsBouncedBack)) }
        if focusBlocks > 0 { tiles.append(.focus(minutes: Int(focusMinutes.rounded()), blocks: focusBlocks)) }
        if activeSpan != nil, let first = firstActivity, let last = lastActivity { tiles.append(.activeSpan(from: first, to: last)) }
        if milestones > 0 { tiles.append(.milestones(milestones)) }
        return Array(tiles.prefix(8))
    }

    /// One friendly line about the day, built only from its real numbers.
    public func summary(petName: String, companionName: String) -> String {
        let focus = Int(focusMinutes.rounded())
        if !hasActivity {
            if focusBlocks > 0 { return "\(focus) minutes of deep focus while \(petName) napped. Lovely." }
            return "A quiet day. \(petName) and \(companionName) saved their energy for tomorrow."
        }
        let turns = Self.count(turnsFinished, "turn")
        let passed = buildsPassed + testsPassed
        if errorsBouncedBack > 0, turnsFinished > 0 {
            return "Bounced back from \(Self.count(errorsBouncedBack, "error")) and still finished \(turns). Resilient!"
        }
        if passed > 0, turnsFinished > 0 {
            return "\(turns) finished and \(Self.count(passed, "green build", plural: "green builds")) — \(petName) is proud of you."
        }
        if focus > 0, turnsFinished > 0 {
            return "\(turns) finished and \(focus) focused minutes. Nicely done!"
        }
        if turnsFinished > 0 {
            return "\(turns) finished across \(Self.count(max(1, sessions), "session")). Nice and steady."
        }
        if sessions > 0 {
            return "\(companionName) dropped by for \(Self.count(sessions, "session")) today."
        }
        return "\(companionName) checked in today. \(petName) kept the seat warm."
    }

    /// "Today", "Yesterday" or the weekday.
    public static func dayName(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: day)
    }

    /// "yyyy-MM-dd" in the calendar's time zone.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The evening notification, for users who turned recap banners on.
    public func readyBanner(petName: String, companionName: String) -> BannerContent {
        var bits: [String] = []
        if turnsFinished > 0 { bits.append(Self.count(turnsFinished, "turn") + " finished") }
        if sessions > 0 { bits.append(Self.count(sessions, "session")) }
        if focusBlocks > 0 { bits.append("\(Int(focusMinutes.rounded())) min of focus") }
        let detail = bits.isEmpty ? "" : " " + bits.joined(separator: " · ") + "."
        return BannerContent(title: "Your day with Claude is ready", body: "\(petName) & \(companionName) made you a recap card.\(detail)")
    }

    static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }
}

extension ToolCategory {
    /// How the recap names the most used kind of tool.
    public var recapTitle: String {
        switch self {
        case .read: return "Mostly reading"
        case .search: return "Mostly searching"
        case .edit: return "Mostly editing"
        case .shell: return "Mostly in the shell"
        case .web: return "Mostly on the web"
        case .agent: return "Mostly delegating"
        case .plan: return "Mostly planning"
        case .ask: return "Mostly asking you"
        case .skill: return "Mostly skills"
        case .mcp: return "Mostly MCP tools"
        case .other: return "Many kinds of tools"
        }
    }
}
