import Foundation

public enum SoundCue: String, Sendable, CaseIterable {
    case greeting, keyboard, success, celebration, sleep, attention, investigate, pop, achievement
}

public enum AttentionLevel: Int, Comparable, Sendable {
    case info = 0
    case attention = 1
    case alert = 2

    public static func < (lhs: AttentionLevel, rhs: AttentionLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct BannerContent: Equatable, Sendable {
    public var title: String
    public var body: String
}

/// What the characters (and notification layer) should do about one event.
///
/// These are visual responses, not claims about Claude's reasoning: detailed
/// animations are only chosen when the event itself carries that information.
public struct Reaction: Equatable, Sendable {
    public var category: NotificationCategory
    public var pet: PetAnimation?
    public var companion: CompanionAnimation?
    public var interaction: InteractionID?
    public var priority: AnimationPriority
    public var sound: SoundCue?
    public var attention: AttentionLevel?
    public var banner: BannerContent?
    public var caption: String?
    /// Sparkle in the menu bar.
    public var burst: Bool = false
    public var resultCard: Bool = false

    public init(category: NotificationCategory, pet: PetAnimation? = nil, companion: CompanionAnimation? = nil,
                interaction: InteractionID? = nil, priority: AnimationPriority = .reaction, sound: SoundCue? = nil,
                attention: AttentionLevel? = nil, banner: BannerContent? = nil, caption: String? = nil,
                burst: Bool = false, resultCard: Bool = false) {
        self.category = category
        self.pet = pet
        self.companion = companion
        self.interaction = interaction
        self.priority = priority
        self.sound = sound
        self.attention = attention
        self.banner = banner
        self.caption = caption
        self.burst = burst
        self.resultCard = resultCard
    }
}

public struct MapperContext: Sendable {
    public var companionPresent: Bool
    public var isPrimary: Bool
    public var multipleLiveSessions: Bool
    public var celebrateCommandResults: Bool
    public var longTurnThreshold: TimeInterval
    /// True if this milestone just unlocked the graduation achievement.
    public var firstMilestone: Bool

    public init(companionPresent: Bool, isPrimary: Bool, multipleLiveSessions: Bool = false, celebrateCommandResults: Bool = true,
                longTurnThreshold: TimeInterval = 600, firstMilestone: Bool = false) {
        self.companionPresent = companionPresent
        self.isPrimary = isPrimary
        self.multipleLiveSessions = multipleLiveSessions
        self.celebrateCommandResults = celebrateCommandResults
        self.longTurnThreshold = longTurnThreshold
        self.firstMilestone = firstMilestone
    }
}

public enum EventToAnimationMapper {
    /// The looping animation that represents a session's current phase.
    public static func companionLoop(for session: SessionSnapshot?, now: Date, sleepAfter: TimeInterval, offline: Bool) -> CompanionAnimation {
        if offline { return .offline }
        guard let session else { return .idleAtDesk }
        let quietFor = now.timeIntervalSince(session.lastEventAt)
        if session.isStale(now: now) { return quietFor > sleepAfter ? .sleep : .idleAtDesk }
        switch session.phase {
        case .promptSubmitted, .thinking:
            if session.isInvestigating { return .detective }
            return session.activeSubagents.isEmpty ? .thinking : .delegating
        case .runningTool:
            if session.isInvestigating { return .detective }
            return workLoop(for: session.currentTool?.category)
        case .waitingForUser:
            return .waiting
        case .idle, .turnCompleted, .turnFailed:
            return quietFor > sleepAfter ? .sleep : .idleAtDesk
        case .ended:
            return quietFor > sleepAfter ? .sleep : .rest
        }
    }

    /// Generic work unless the tool name genuinely says what kind of work it is.
    public static func workLoop(for category: ToolCategory?) -> CompanionAnimation {
        switch category {
        case .read?: return .reading
        case .search?: return .searching
        case .edit?, .plan?: return .typing
        case .shell?: return .runningCommand
        case .web?: return .browsing
        case .agent?: return .delegating
        case .ask?: return .waiting
        default: return .typing
        }
    }

    public static func petLoop(for session: SessionSnapshot?, now: Date, asleep: Bool) -> PetAnimation {
        if asleep { return .sleep }
        guard let session, !session.isStale(now: now) else { return .idle }
        switch session.phase {
        case .promptSubmitted, .thinking:
            return .watch
        case .runningTool:
            return session.currentTool?.category == .ask ? .waveGently : .watch
        case .waitingForUser:
            return .waveGently
        default:
            return .idle
        }
    }

    public static func reaction(
        for event: CompanionEvent,
        transition: SessionTransition?,
        session: SessionSnapshot?,
        context: MapperContext
    ) -> Reaction? {
        let label = session?.displayName ?? event.project?.displayName
        let prefix = (context.multipleLiveSessions || !context.isPrimary) ? label.map { "\($0) · " } ?? "" : ""
        let bannerBody = label ?? "Claude Code"

        switch event.kind {
        case .sessionStarted:
            if event.metadata["source"] == "compact" { return nil }
            let greeting = Reaction(
                category: .sessionLifecycle,
                pet: .greet,
                companion: context.companionPresent ? .greet : nil,
                sound: .greeting,
                banner: BannerContent(title: event.summary, body: bannerBody),
                caption: prefix + (event.metadata["source"] == "resume" ? "session resumed" : "session started")
            )
            return greeting

        case .promptSubmitted:
            guard context.isPrimary else { return nil }
            return Reaction(category: .toolActivity, pet: .leanForward, companion: .readTaskCard)

        case .toolStarting:
            guard context.isPrimary else { return nil }
            let typing = event.toolCategory == .edit || event.toolCategory == .shell
            return Reaction(category: .toolActivity, priority: .ambient, sound: typing ? .keyboard : nil)

        case .toolSucceeded:
            guard context.isPrimary else { return nil }
            if context.celebrateCommandResults, let outcome = event.buildTestOutcome, outcome.passed {
                return Reaction(category: .buildTest, pet: .happyBounce, companion: .nod, sound: .success,
                                caption: prefix + (outcome.kind == .test ? "test command passed" : "build command succeeded"))
            }
            return Reaction(category: .toolActivity, pet: .nod, priority: .ambient)

        case .toolFailed:
            if event.interrupted {
                guard context.isPrimary else { return nil }
                return Reaction(category: .toolActivity, pet: .confusedTilt, caption: prefix + "tool interrupted")
            }
            let outcome = event.buildTestOutcome
            let category: NotificationCategory = outcome != nil && context.celebrateCommandResults ? .buildTest : .toolFailure
            let tool = event.toolName.map(EventNormalizer.friendlyToolName) ?? "A tool"
            let caption: String
            if let outcome {
                caption = prefix + (outcome.kind == .test ? "a test command failed" : "a build command failed")
            } else {
                caption = prefix + "\(tool) reported an error"
            }
            let banner = BannerContent(
                title: outcome.map { $0.summary } ?? "\(tool) reported an error",
                body: "\(bannerBody) — Claude may still be working on it."
            )
            if transition?.startedInvestigating == true, context.isPrimary {
                return Reaction(category: category, interaction: .detectiveHat, sound: .investigate, attention: .info,
                                banner: banner, caption: prefix + "several tool errors — investigating")
            }
            return Reaction(category: category, pet: context.isPrimary ? .concerned : nil,
                            companion: context.isPrimary ? .concerned : nil,
                            sound: .investigate, attention: .info, banner: banner, caption: caption)

        case .toolBatchFinished:
            return nil

        case .permissionRequested, .attentionNeeded:
            // PermissionRequest and its Notification arrive together: react once.
            if transition?.previousPhase == .waitingForUser { return nil }
            let level: AttentionLevel = event.attention == .input ? .info : .attention
            let title: String
            switch event.attention {
            case .permission?: title = "Claude needs your permission"
            case .input?: title = "Claude is waiting for your input"
            case .mcpDialog?: title = "An MCP server needs your input"
            case .backgroundAgent?: title = "A background agent needs input"
            case nil: title = "Claude Code needs your attention"
            }
            let detail = event.kind == .permissionRequested
                ? event.toolName.map { "Wants to use \(EventNormalizer.friendlyToolName($0))" }
                : event.message
            return Reaction(category: .needsAttention, pet: .wave, priority: .attention, sound: .attention, attention: level,
                            banner: BannerContent(title: title, body: [bannerBody, detail].compactMap { $0 }.joined(separator: " — ")),
                            caption: prefix + (event.attention == .permission ? "waiting for permission" : "waiting for you"))

        case .permissionDenied:
            guard context.isPrimary else { return nil }
            return Reaction(category: .toolActivity, pet: .confusedTilt, caption: prefix + "auto mode declined a call")

        case .notification:
            if event.metadata["notificationType"] == "agent_completed" {
                return Reaction(category: .turnCompleted, pet: .happyBounce, caption: prefix + "background agent finished")
            }
            return nil

        case .subagentStarted:
            guard context.isPrimary else { return nil }
            return Reaction(category: .toolActivity, pet: .lookAround, priority: .ambient)

        case .subagentStopped:
            guard context.isPrimary else { return nil }
            return Reaction(category: .toolActivity, companion: .nod, priority: .ambient)

        case .turnCompleted:
            let buildTest = session?.buildTestThisTurn
            let summary = buildTest.map { $0.summary } ?? "No build or test result was received this turn."
            let banner = BannerContent(title: "Claude finished responding", body: "\(bannerBody) — \(summary)")
            guard context.isPrimary else {
                // Another session is in focus: acknowledge without hijacking the scene.
                return Reaction(category: .turnCompleted, pet: .happyBounce, sound: .success, banner: banner,
                                caption: prefix + "turn complete", burst: true, resultCard: true)
            }
            let interaction: InteractionID
            var sound = SoundCue.success
            if session?.investigatedThisTurn == true {
                interaction = .caseClosed
            } else if let buildTest, buildTest.passed, buildTest.source == .explicitReport || context.celebrateCommandResults {
                interaction = .trophyCelebration
                sound = .celebration
            } else if transition?.turnDurationTrusted == true, let duration = transition?.turnDuration, duration >= context.longTurnThreshold {
                interaction = .victoryDance
                sound = .celebration
            } else {
                interaction = .highFive
            }
            return Reaction(category: .turnCompleted, pet: .victory, interaction: interaction, sound: sound, banner: banner,
                            caption: prefix + "turn complete", burst: true, resultCard: true)

        case .turnFailed:
            let reason = event.metadata["reason"]?.replacingOccurrences(of: "_", with: " ")
            return Reaction(category: .turnError, pet: .concerned, companion: context.isPrimary ? .concerned : nil,
                            sound: .investigate, attention: .alert,
                            banner: BannerContent(title: "Turn ended with an API error", body: [bannerBody, reason].compactMap { $0 }.joined(separator: " — ")),
                            caption: prefix + "API error" + (reason.map { " (\($0))" } ?? ""))

        case .sessionEnded:
            return Reaction(category: .sessionLifecycle, pet: .wave, companion: context.isPrimary ? .packUp : nil,
                            banner: BannerContent(title: event.summary, body: bannerBody), caption: prefix + "session ended")

        case .report:
            guard let report = event.report else { return nil }
            let labelText = report.label.map { " — \($0)" } ?? ""
            switch (report.kind, report.status) {
            case (.build, .failed), (.test, .failed):
                return Reaction(category: .buildTest, pet: .concerned, companion: .concerned, sound: .investigate, attention: .info,
                                banner: BannerContent(title: event.summary, body: "Reported by your script"),
                                caption: (report.kind == .test ? "tests failed" : "build failed") + labelText)
            case (.build, _), (.test, _):
                return Reaction(category: .buildTest, pet: .excitedJump, interaction: .trophyCelebration, sound: .celebration,
                                banner: BannerContent(title: event.summary, body: "Reported by your script"),
                                caption: (report.kind == .test ? "tests passed" : "build passed") + labelText, burst: true)
            case (.milestone, _):
                let stableHash = event.id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF_FFFF }
                let rare = Ease.hash(stableHash, 7) < 0.34
                let interaction: InteractionID = context.firstMilestone ? .graduation : (rare ? .syncDance : .victoryDance)
                return Reaction(category: .milestone, pet: .victory, interaction: interaction, priority: .user, sound: .celebration,
                                banner: BannerContent(title: "Milestone reached", body: report.label ?? "Nice work!"),
                                caption: "milestone" + labelText, burst: true)
            case (.commit, _):
                return Reaction(category: .milestone, pet: .happyBounce, interaction: .highFive, sound: .success,
                                caption: "commit recorded" + labelText, burst: true)
            }

        case .unknown:
            return nil
        }
    }
}
