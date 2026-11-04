import Foundation

/// The observed phase of one Claude Code session.
public enum SessionPhase: String, Codable, Sendable {
    /// Session detected; no turn in progress.
    case idle
    /// A prompt was submitted; Claude has not used a tool yet.
    case promptSubmitted
    /// A turn is in progress and no tool is currently running.
    case thinking
    /// At least one tool call has started and not yet reported back.
    case runningTool
    /// Claude Code reported it is waiting on the user.
    case waitingForUser
    /// `Stop` received: the turn finished.
    case turnCompleted
    /// `StopFailure` received: the turn ended with an API error.
    case turnFailed
    case ended

    public var isWorking: Bool {
        self == .promptSubmitted || self == .thinking || self == .runningTool
    }
}

public struct SessionSnapshot: Identifiable, Sendable, Equatable {
    public struct RunningTool: Sendable, Equatable {
        public var name: String
        public var category: ToolCategory
        public var startedAt: Date
    }

    public var id: String
    public var project: ProjectRef?
    public var phase: SessionPhase = .idle
    public var runningTools: [String: RunningTool] = [:]
    /// The most recently started tool, for display.
    public var currentTool: RunningTool?
    public var waitingFor: AttentionKind?
    public var waitingTool: String?
    public var firstSeen: Date
    public var lastEventAt: Date
    /// True when this session's SessionStart was observed (not joined mid-way).
    public var startObserved = false
    public var turnStartedAt: Date?
    /// The turn's prompt was observed live (not late or restored), so its
    /// duration can be trusted for "long turn" celebrations.
    public var turnStartObservedLive = false
    public var lastTurnCompletedAt: Date?
    public var turnsCompleted = 0
    public var toolCallsThisTurn = 0
    public var failuresThisTurn = 0
    public var consecutiveFailures = 0
    /// Detective mode was entered at some point during the current turn.
    public var investigatedThisTurn = false
    public var lastFailureAt: Date?
    public var lastFailureSummary: String?
    public var activeSubagents: Set<String> = []
    /// A build/test outcome actually received during the current (or last) turn.
    public var lastBuildTest: BuildTestOutcome?
    public var buildTestThisTurn: BuildTestOutcome?
    public var lastEventSummary: String = ""
    public var lastEventKind: EventKind?
    public var model: String?
    /// Bundle identifier of the app the session runs in (VS Code, Terminal, …), when known.
    public var hostApp: String?
    public var endedReason: String?
    public var endedAt: Date?
    public var isSimulated: Bool
    public var lateEvents = 0
    public var turnFailureReason: String?

    public var displayName: String {
        project?.displayName ?? "Session \(id.prefix(6))"
    }

    /// Detective mode: several tool failures in the current turn while it continues.
    public var isInvestigating: Bool {
        phase.isWorking && consecutiveFailures >= SessionRegistry.detectiveFailureThreshold
    }

    public func isStale(now: Date, after: TimeInterval = SessionRegistry.staleAfter) -> Bool {
        (phase.isWorking || phase == .waitingForUser) && now.timeIntervalSince(lastEventAt) > after
    }

    /// Plain-language status line, e.g. "Running Bash" or "Waiting for your permission".
    public func statusLine(now: Date) -> String {
        if isStale(now: now) {
            return "No events for a while — the session may have closed"
        }
        switch phase {
        case .idle: return startObserved ? "Session open" : "Session detected"
        case .promptSubmitted: return "Prompt received"
        case .thinking:
            return isInvestigating ? "Working after several tool errors" : "Working"
        case .runningTool:
            let name = currentTool.map { EventNormalizer.friendlyToolName($0.name) } ?? "a tool"
            if runningTools.count > 1 { return "Running \(runningTools.count) tools" }
            return "Running \(name)"
        case .waitingForUser:
            switch waitingFor {
            case .permission:
                return waitingTool.map { "Waiting for your permission (\(EventNormalizer.friendlyToolName($0)))" } ?? "Waiting for your permission"
            case .input: return "Waiting for your input"
            case .mcpDialog: return "An MCP server is waiting for input"
            case .backgroundAgent: return "A background agent needs input"
            case nil: return "Waiting for you"
            }
        case .turnCompleted: return "Turn complete"
        case .turnFailed: return "Turn ended with an API error"
        case .ended: return "Session ended"
        }
    }
}

/// What changed when an event was applied.
public struct SessionTransition: Sendable, Equatable {
    public var sessionID: String
    public var previousPhase: SessionPhase?
    public var phase: SessionPhase
    public var isNewSession: Bool
    /// The event was the first of a new run of tool failures reaching the detective threshold.
    public var startedInvestigating: Bool
    public var turnDuration: TimeInterval?
    public var turnDurationTrusted: Bool
}

/// Tracks each session independently. Events are only ever applied to the session
/// they carry, so activity from different projects is never merged.
public struct SessionRegistry: Sendable {
    public static let detectiveFailureThreshold = 3
    public static let staleAfter: TimeInterval = 20 * 60
    public static let endedRetention: TimeInterval = 30 * 60
    public static let idleRetention: TimeInterval = 6 * 3600

    public private(set) var sessions: [String: SessionSnapshot] = [:]
    /// Explicit reports that arrive without a session are attached to the most
    /// recently active session of the same project, or kept here.
    public private(set) var unattachedReports: [CompanionEvent] = []

    public init() {}

    public var all: [SessionSnapshot] {
        sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    public subscript(id: String) -> SessionSnapshot? { sessions[id] }

    /// Resolves which session an event belongs to (explicit reports may carry none).
    public func sessionID(for event: CompanionEvent) -> String? {
        if let id = event.sessionID { return id }
        guard event.kind == .report, let key = event.project?.key else { return nil }
        return sessions.values
            .filter { $0.project?.key == key && $0.phase != .ended && $0.isSimulated == event.isSimulated }
            .max { $0.lastEventAt < $1.lastEventAt }?.id
    }

    @discardableResult
    public mutating func apply(_ event: CompanionEvent) -> SessionTransition? {
        guard let id = sessionID(for: event) else {
            if event.kind == .report {
                unattachedReports.append(event)
                if unattachedReports.count > 20 { unattachedReports.removeFirst() }
            }
            return nil
        }
        let isNew = sessions[id] == nil
        var session = sessions[id] ?? SessionSnapshot(
            id: id,
            project: event.project,
            firstSeen: event.timestamp,
            lastEventAt: event.timestamp,
            isSimulated: event.isSimulated
        )
        let previous = isNew ? nil : session.phase
        if session.project == nil { session.project = event.project }
        if event.project?.path != nil, session.project?.key == event.project?.key { session.project = event.project }
        // Late events update history but never move a session backwards in time.
        let isOutOfOrder = event.timestamp < session.lastEventAt.addingTimeInterval(-1)
        session.lastEventAt = max(session.lastEventAt, event.timestamp)
        session.lastEventSummary = event.summary
        session.lastEventKind = event.kind
        if let host = event.metadata["host"] { session.hostApp = host }
        if event.delivery == .late { session.lateEvents += 1 }

        var startedInvestigating = false
        var turnDuration: TimeInterval?
        var turnDurationTrusted = false

        if !isOutOfOrder || isNew {
            switch event.kind {
            case .sessionStarted:
                session.startObserved = true
                session.model = event.metadata["model"] ?? session.model
                if event.metadata["source"] != "compact" {
                    session.phase = .idle
                    session.runningTools = [:]
                    session.currentTool = nil
                    session.waitingFor = nil
                    session.endedAt = nil
                    session.endedReason = nil
                }

            case .promptSubmitted:
                session.phase = .promptSubmitted
                session.turnStartedAt = event.timestamp
                session.turnStartObservedLive = event.delivery == .live
                session.runningTools = [:]
                session.currentTool = nil
                session.waitingFor = nil
                session.waitingTool = nil
                session.toolCallsThisTurn = 0
                session.failuresThisTurn = 0
                session.consecutiveFailures = 0
                session.investigatedThisTurn = false
                session.buildTestThisTurn = nil
                session.turnFailureReason = nil

            case .toolStarting:
                let tool = SessionSnapshot.RunningTool(
                    name: event.toolName ?? "tool",
                    category: event.toolCategory ?? .other,
                    startedAt: event.timestamp
                )
                session.runningTools[event.toolUseID ?? "tool-\(event.id)"] = tool
                session.currentTool = tool
                session.toolCallsThisTurn += 1
                session.waitingFor = nil
                session.waitingTool = nil
                session.phase = .runningTool

            case .toolSucceeded, .toolFailed:
                if let toolUseID = event.toolUseID {
                    session.runningTools[toolUseID] = nil
                } else if let name = event.toolName,
                          let key = session.runningTools.first(where: { $0.value.name == name })?.key {
                    session.runningTools[key] = nil
                }
                session.currentTool = session.runningTools.values.max { $0.startedAt < $1.startedAt }
                session.waitingFor = nil
                session.waitingTool = nil
                if event.kind == .toolFailed, !event.interrupted {
                    session.failuresThisTurn += 1
                    session.consecutiveFailures += 1
                    session.lastFailureAt = event.timestamp
                    session.lastFailureSummary = event.summary
                    startedInvestigating = session.consecutiveFailures == SessionRegistry.detectiveFailureThreshold
                    if startedInvestigating { session.investigatedThisTurn = true }
                } else if event.kind == .toolSucceeded {
                    session.consecutiveFailures = 0
                }
                if let outcome = event.buildTestOutcome {
                    session.lastBuildTest = outcome
                    session.buildTestThisTurn = outcome
                }
                if session.phase != .turnCompleted, session.phase != .ended {
                    session.phase = session.runningTools.isEmpty ? .thinking : .runningTool
                }

            case .toolBatchFinished:
                session.runningTools = [:]
                session.currentTool = nil
                if session.phase == .runningTool || session.phase == .waitingForUser { session.phase = .thinking }
                session.waitingFor = nil

            case .permissionRequested, .attentionNeeded:
                session.phase = .waitingForUser
                session.waitingFor = event.attention ?? .permission
                if let tool = event.toolName { session.waitingTool = tool }

            case .subagentStarted:
                session.activeSubagents.insert(event.metadata["agentId"] ?? event.id)
                if session.phase == .idle || session.phase == .turnCompleted { session.phase = .thinking }

            case .subagentStopped:
                if let agent = event.metadata["agentId"] {
                    session.activeSubagents.remove(agent)
                } else if let any = session.activeSubagents.first {
                    session.activeSubagents.remove(any)
                }

            case .turnCompleted:
                if let start = session.turnStartedAt {
                    turnDuration = event.timestamp.timeIntervalSince(start)
                    turnDurationTrusted = session.turnStartObservedLive && event.delivery == .live
                }
                session.phase = .turnCompleted
                session.lastTurnCompletedAt = event.timestamp
                session.turnsCompleted += 1
                session.runningTools = [:]
                session.currentTool = nil
                session.waitingFor = nil
                session.waitingTool = nil
                session.activeSubagents = []

            case .turnFailed:
                session.phase = .turnFailed
                session.turnFailureReason = event.metadata["reason"]
                session.runningTools = [:]
                session.currentTool = nil
                session.waitingFor = nil

            case .sessionEnded:
                session.phase = .ended
                session.endedAt = event.timestamp
                session.endedReason = event.metadata["reason"]
                session.runningTools = [:]
                session.currentTool = nil
                session.waitingFor = nil
                session.activeSubagents = []

            case .report:
                if let outcome = event.buildTestOutcome {
                    session.lastBuildTest = outcome
                    session.buildTestThisTurn = outcome
                }

            case .permissionDenied, .notification, .unknown:
                break
            }
        }

        sessions[id] = session
        return SessionTransition(
            sessionID: id,
            previousPhase: previous,
            phase: session.phase,
            isNewSession: isNew,
            startedInvestigating: startedInvestigating,
            turnDuration: turnDuration,
            turnDurationTrusted: turnDurationTrusted
        )
    }

    /// Drops ended and long-idle sessions.
    public mutating func prune(now: Date) {
        sessions = sessions.filter { _, session in
            if session.phase == .ended {
                return now.timeIntervalSince(session.endedAt ?? session.lastEventAt) < SessionRegistry.endedRetention
            }
            return now.timeIntervalSince(session.lastEventAt) < SessionRegistry.idleRetention
        }
    }

    public mutating func remove(where predicate: (SessionSnapshot) -> Bool) {
        sessions = sessions.filter { !predicate($0.value) }
    }

    public mutating func removeAll() {
        sessions = [:]
        unattachedReports = []
    }

    // MARK: Primary session

    /// The documented rule for which session the menu bar represents:
    ///
    /// 1. A session the user pinned in the selector, while it has not ended.
    /// 2. Otherwise the highest-ranked session:
    ///    waiting for the user › turn failed or tool failure in the last minute ›
    ///    working › turn completed in the last 5 minutes › open/idle › recently ended.
    /// 3. Ties go to the session with the most recent event.
    ///
    /// Stale sessions (working but silent for 20 minutes) rank as idle.
    public func primarySession(pinned: String?, now: Date) -> SessionSnapshot? {
        if let pinned, let session = sessions[pinned], session.phase != .ended {
            return session
        }
        return sessions.values.max { a, b in
            let ra = SessionRegistry.rank(a, now: now)
            let rb = SessionRegistry.rank(b, now: now)
            if ra != rb { return ra < rb }
            return a.lastEventAt < b.lastEventAt
        }
    }

    public static func rank(_ session: SessionSnapshot, now: Date) -> Int {
        let stale = session.isStale(now: now)
        switch session.phase {
        case .waitingForUser:
            return stale ? 2 : 6
        case .turnFailed:
            return now.timeIntervalSince(session.lastEventAt) < 300 ? 5 : 2
        case .promptSubmitted, .thinking, .runningTool:
            if stale { return 2 }
            if let failure = session.lastFailureAt, now.timeIntervalSince(failure) < 60 { return 5 }
            return 4
        case .turnCompleted:
            let completed = session.lastTurnCompletedAt ?? session.lastEventAt
            return now.timeIntervalSince(completed) < 300 ? 3 : 2
        case .idle:
            return 2
        case .ended:
            return now.timeIntervalSince(session.endedAt ?? session.lastEventAt) < 120 ? 1 : 0
        }
    }

    /// Sessions that should keep the companion around.
    public func hasLiveSessions(now: Date) -> Bool {
        sessions.values.contains { $0.phase != .ended && now.timeIntervalSince($0.lastEventAt) < 3600 }
    }
}
