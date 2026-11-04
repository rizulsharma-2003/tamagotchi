import Foundation
import Observation
import TamagotchiWire

/// The tiny world: sessions, both characters, their interactions and everything
/// the UI shows. All state changes happen on the main actor; rendering reads the
/// animator states and evaluates poses per frame.
@MainActor
@Observable
public final class CompanionWorld {
    // MARK: Dependencies

    @ObservationIgnored public let journal: EventJournal
    @ObservationIgnored public let achievements: AchievementEngine
    @ObservationIgnored public weak var effects: WorldEffects?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private var scheduler: InteractionScheduler
    @ObservationIgnored private var recentIDs: [String] = []
    @ObservationIgnored private var recentIDSet: Set<String> = []
    @ObservationIgnored private var bannerCoalescer = BannerCoalescer()
    @ObservationIgnored private var lastSoundAt: [SoundCue: TimeInterval] = [:]
    @ObservationIgnored private var lastPruneAt: TimeInterval = 0
    @ObservationIgnored private var lastUserInteractionAt: Date
    @ObservationIgnored private var lastLiveActivityAt: Date
    @ObservationIgnored private var lastSessionEndedAt: Date?
    @ObservationIgnored private var departing = false
    @ObservationIgnored private var pendingInteraction: PendingInteraction?
    /// Patch has just arrived while Mochi was off along the bar: Mochi runs home to say hello.
    @ObservationIgnored private var pendingGreeting: TimeInterval?
    /// The pet one-shot (a Play or a Treat) whose menu-bar version the roamer is playing as a game.
    @ObservationIgnored private var barGameToken: Int?
    /// A Play or Treat given in the popover: once it closes, the menu bar plays a short follow-up.
    @ObservationIgnored private var popoverFollowUp: (game: RoamUserGame, at: TimeInterval)?
    @ObservationIgnored public private(set) var seed: UInt64

    /// An interaction with Patch waiting for Mochi to run home along the menu bar.
    private struct PendingInteraction {
        var id: InteractionID
        var priority: AnimationPriority
        var variant: Int
        var label: String?
        var requestedAt: TimeInterval
        /// For a real event: the pet's own reaction, played if the interaction never happens.
        var fallback: PetAnimation?
    }

    /// What became of a request to start an interaction.
    public enum InteractionRequest: Equatable, Sendable {
        case started
        /// Waiting for Mochi to run home along the menu bar.
        case deferred
        case refused
    }

    // MARK: Observable state

    @ObservationIgnored public let settingsStore: SettingsStore

    /// Settings live in the store (single source of truth); changes made here persist.
    public var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    public private(set) var registry = SessionRegistry()
    public private(set) var pet: CharacterAnimator<PetAnimation>
    public private(set) var companion: CharacterAnimator<CompanionAnimation>
    public private(set) var interaction: InteractionPlayback?
    public private(set) var companionPresent = false
    public private(set) var petAsleep = false
    /// The Mac is resting (see `updateSystem`); the pet sleeps through it unless Claude is working.
    public private(set) var macResting = false
    /// nil until the Mac has reported how it's used; until then naps follow the pet's own quiet time.
    @ObservationIgnored private var system: SystemActivity?
    public private(set) var timeline: [CompanionEvent] = []
    public private(set) var connection = ConnectionStatus()
    public private(set) var attention: AttentionBadge?
    public private(set) var resultCards: [String: ResultCard] = [:]
    public private(set) var caption: SceneCaption?
    public private(set) var burst: CelebrationBurst?
    public private(set) var toast: WorldToast?
    public private(set) var missed: MissedEventsNotice?
    public private(set) var diagnostics = WorldDiagnostics()
    public private(set) var progress: ProgressState
    public private(set) var popoverVisible = false
    public private(set) var systemReducedMotion = false
    public private(set) var simulatorRunning = false
    /// Mochi's life along the menu bar (position, activities, props). Inactive until
    /// the app hands it a zone; the world ticks it and freezes it for real reactions.
    public internal(set) var roamer: MenuBarRoamer

    // MARK: Feature state (changed by the feature extensions)

    /// Mochi is out exploring the desktop, away from the menu bar.
    public internal(set) var adventureActive = false
    /// The focus buddy's current phase, while a focus session runs.
    public internal(set) var focus: FocusStatus?
    /// What one of the characters is saying right now.
    public internal(set) var speech: SpeechBubble?
    /// Mochi's agent has news the user hasn't looked at yet (shown on the menu bar like Claude's own badge).
    public var agentBadge: AttentionLevel?

    public init(
        journal: EventJournal,
        achievements: AchievementEngine,
        settingsStore: SettingsStore,
        seed: UInt64 = UInt64.random(in: 1...UInt64.max),
        clock: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.journal = journal
        self.achievements = achievements
        self.settingsStore = settingsStore
        self.seed = seed
        self.clock = clock
        self.uptime = uptime
        let now = uptime()
        self.pet = CharacterAnimator(base: .idle, at: now)
        self.companion = CharacterAnimator(base: .absent, at: now)
        self.scheduler = InteractionScheduler(seed: seed, now: now)
        self.roamer = MenuBarRoamer(seed: seed)
        self.progress = achievements.state
        let date = clock()
        self.lastUserInteractionAt = date
        self.lastLiveActivityAt = date
        journal.storeProjectPaths = settingsStore.settings.storeProjectPaths
        journal.retention = EventJournal.Retention(days: settingsStore.settings.historyRetentionDays)
        if settingsStore.settings.companionVisibility == .always {
            companionPresent = true
            companion.setBase(.idleAtDesk, at: now)
        }
        settingsStore.onChange = { [weak self] old, _ in
            MainActor.assumeIsolated { self?.settingsChanged(from: old) }
        }
    }

    // MARK: Derived state

    public var now: TimeInterval { uptime() }

    public var reducedMotion: Bool {
        switch settings.reducedMotion {
        case .system: return systemReducedMotion
        case .always: return true
        case .never: return false
        }
    }

    public var sessions: [SessionSnapshot] { registry.all }

    public var primarySession: SessionSnapshot? {
        registry.primarySession(pinned: settings.pinnedSessionID, now: clock())
    }

    public var liveSessions: [SessionSnapshot] {
        let date = clock()
        return registry.all.filter { $0.phase != .ended || date.timeIntervalSince($0.endedAt ?? $0.lastEventAt) < 600 }
    }

    public var latestResult: ResultCard? {
        resultCards.values.max { $0.completedAt < $1.completedAt }
    }

    public var activeCaption: SceneCaption? {
        guard let caption, caption.until > uptime() else { return nil }
        return caption
    }

    public var activeToast: WorldToast? {
        guard let toast, toast.until > uptime() else { return nil }
        return toast
    }

    /// What the menu-bar roamer needs to know right now.
    public var roamContext: RoamContext { roamContext(at: uptime(), date: clock()) }

    /// The interaction Mochi is running home for, if any.
    public var pendingInteractionID: InteractionID? { pendingInteraction?.id }

    private var companionAvailable: Bool {
        companionPresent && companion.current.animation != .absent && !departing
    }

    private func roamContext(at t: TimeInterval, date: Date) -> RoamContext {
        let barGame = barGameToken != nil && pet.current.token == barGameToken
        let reacting = interaction != nil
            || (pet.isPlayingOneShot && !pet.current.isFinished(at: t) && pet.current.priority >= .reaction && !barGame)
        var activity = activity(date: date)
        if pet.base == .waveGently { activity = .waiting }
        return RoamContext(
            companionPresent: companionAvailable,
            activity: activity,
            reacting: reacting,
            summoned: pendingInteraction != nil || pendingGreeting != nil,
            popoverOpen: popoverVisible,
            // Focus naps happen in the bed (or the notch den) too.
            asleep: petAsleep || (focus?.petNaps ?? false),
            quietHours: settings.quietHours.isActive(at: date),
            reducedMotion: reducedMotion,
            paused: settings.pauseReactions,
            intensity: settings.animationIntensity,
            idleSeconds: date.timeIntervalSince(max(lastUserInteractionAt, lastLiveActivityAt)),
            notchDen: settings.notchDen,
            attentionBadge: attention != nil,
            celebrating: burst.map { t >= $0.startedAt && t - $0.startedAt < 2.5 } ?? false,
            away: adventureActive
        )
    }

    public var companionDetail: CompanionDetail {
        let session = primarySession
        return CompanionDetail(waitingFor: session?.waitingFor, subagents: session?.activeSubagents.count ?? 0)
    }

    public var menuBarStatus: MenuBarStatus {
        let session = primarySession
        let date = clock()
        let celebrating = burst.map { uptime() - $0.startedAt < 2.5 } ?? false
        var mood: MenuBarMood = .content
        if settings.pauseReactions {
            mood = .paused
        } else if connection.bridgeError != nil {
            mood = .offline
        } else if celebrating {
            mood = .celebrating
        } else if let session, !session.isStale(now: date) {
            switch session.phase {
            case .waitingForUser: mood = .waiting
            case .promptSubmitted, .thinking, .runningTool:
                if let failure = session.lastFailureAt, date.timeIntervalSince(failure) < 20 { mood = .concerned } else { mood = .watching }
            case .turnFailed: mood = .concerned
            default: mood = petAsleep ? .sleeping : .content
            }
        } else if petAsleep {
            mood = .sleeping
        }
        let working = session.map { $0.phase.isWorking && !$0.isStale(now: date) } ?? false
        return MenuBarStatus(
            mood: mood,
            companionVisible: companionPresent,
            companionWorking: working,
            badge: [attention?.level, agentBadge].compactMap { $0 }.max(),
            celebrationStartedAt: celebrating ? burst?.startedAt : nil,
            simulated: session?.isSimulated ?? false
        )
    }

    // MARK: Event intake

    /// Entry point for wire events from any provider.
    public func ingest(_ wire: WireEvent, delivery: EventDelivery = .live) {
        if wire.origin == .ping {
            connection.lastPingAt = clock()
            return
        }
        let source = settings.keepNotificationText ? wire : stripMessage(wire)
        ingest(EventNormalizer.normalize(source, receivedAt: clock(), delivery: delivery))
    }

    private func stripMessage(_ wire: WireEvent) -> WireEvent {
        var copy = wire
        copy.message = nil
        return copy
    }

    public func ingest(_ event: CompanionEvent) {
        guard rememberID(event.id) else {
            diagnostics.duplicatesIgnored += 1
            return
        }
        if event.isSimulated { diagnostics.simulatedEvents += 1 }
        if event.delivery == .late { diagnostics.lateEvents += 1 }
        let date = clock()

        if event.kind == .unknown {
            diagnostics.unknownEvents += 1
            diagnostics.lastUnknownName = event.rawName
            appendTimeline(event)
            return
        }
        if !event.isSimulated, event.delivery != .restored {
            journal.append(event, now: date)
            // Only live events say anything about the connection right now.
            if event.origin == .claudeHook, event.delivery == .live { connection.lastEventAt = date }
        }

        let previousPrimary = primarySession?.id
        let transition = registry.apply(event)
        let session = transition.flatMap { registry[$0.sessionID] }
        appendTimeline(event)

        var unlocked: [AchievementID] = []
        if event.delivery == .live {
            unlocked = achievements.record(event, transition: transition, session: session)
            if !unlocked.isEmpty || progress != achievements.state { progress = achievements.state }
            lastLiveActivityAt = date
            scheduler.postpone(now: uptime())
        }
        if event.kind == .sessionEnded, !registry.hasLiveSessions(now: date) {
            lastSessionEndedAt = date
        }

        updateAttention(after: event, session: session)
        if event.kind == .turnCompleted, event.delivery == .live, let session {
            recordResult(event: event, session: session, transition: transition)
        }

        if event.delivery == .live {
            if petAsleep, !settings.pauseReactions, session?.id == primarySession?.id {
                petAsleep = false
                pet.play(.wakeUp, priority: .reaction, at: uptime(), ignoreCooldown: true)
            }
            let primaryID = primarySession?.id
            let context = MapperContext(
                companionPresent: companionPresent || settings.companionVisibility != .never,
                isPrimary: session == nil || session?.id == primaryID || previousPrimary == nil,
                multipleLiveSessions: registry.all.filter { $0.phase != .ended }.count > 1,
                celebrateCommandResults: settings.celebrateCommandResults,
                longTurnThreshold: TimeInterval(settings.longTurnMinutes * 60),
                firstMilestone: unlocked.contains(.firstMilestone)
            )
            // Presence first, so a session start becomes a proper arrival.
            updatePresence()
            if let reaction = EventToAnimationMapper.reaction(for: event, transition: transition, session: session, context: context) {
                perform(reaction, for: event, session: session)
            }
            if !settings.pauseReactions { effects?.worldDidReact(to: event, session: session) }
            for id in unlocked { announce(id) }
        }
        updateBases()
        syncRoamer()
    }

    /// Late events are history: shown and stored, never animated.
    public func noteSpoolDrained(delivered: Int, dropped: Int) {
        guard delivered > 0 || dropped > 0 else { return }
        missed = MissedEventsNotice(delivered: delivered, dropped: dropped, at: clock())
    }

    public func dismissMissedNotice() { missed = nil }

    /// Rebuilds session state from recent history after a restart. No reactions.
    public func restoreFromJournal(window: TimeInterval = 3 * 3600) {
        let date = clock()
        let recent = journal.events(since: date.addingTimeInterval(-window))
        for var event in recent {
            event.delivery = .restored
            // These ids are in the journal by definition; only skip ones already applied.
            guard !recentIDSet.contains(event.id) else { continue }
            markSeen(event.id)
            registry.apply(event)
        }
        timeline = Array(recent.suffix(40).map { var e = $0; e.delivery = .restored; return e })
        registry.prune(now: date)
        updatePresence(animated: false)
        updateBases()
    }

    // MARK: Reactions

    private func perform(_ reaction: Reaction, for event: CompanionEvent, session: SessionSnapshot?) {
        let date = clock()
        let decision = NotificationPolicy.decide(
            reaction.category,
            settings: settings,
            context: NotificationContext(now: date, popoverVisible: popoverVisible, reducedMotion: reducedMotion,
                                         isSimulated: event.isSimulated, isLate: event.delivery != .live,
                                         focusing: focus?.phase == .focus)
        )
        let t = uptime()
        if decision.animate {
            var started = false
            if let id = reaction.interaction {
                let request = requestInteraction(id, priority: max(reaction.priority, .reaction), variant: Int(scheduler.rng.state % 1000),
                                                 label: session?.displayName, fallback: reaction.pet)
                started = request != .refused
            }
            if !started {
                // Mochi says hello to a newly arrived Patch once it has run home (see `pendingGreeting`).
                let greetingLater = event.kind == .sessionStarted && pendingGreeting != nil
                if let animation = reaction.pet, !greetingLater {
                    pet.play(animation, priority: reaction.priority, at: t)
                }
                if let animation = reaction.companion, companionPresent, !departing, companion.current.animation != .absent {
                    companion.play(animation, priority: reaction.priority, at: t)
                }
            }
            if reaction.burst { burst = CelebrationBurst(startedAt: t, big: reaction.interaction != .highFive) }
            if let text = reaction.caption {
                caption = SceneCaption(text: text, until: t + 6, isSimulated: event.isSimulated)
            }
        }
        if decision.sound, let cue = reaction.sound { playSound(cue) }
        if decision.badge, let level = reaction.attention {
            let kind: AttentionBadge.Kind
            switch event.kind {
            case .permissionRequested, .attentionNeeded: kind = .needsYou
            case .turnFailed: kind = .apiError
            case .report: kind = .buildFailed
            default: kind = event.buildTestOutcome != nil ? .buildFailed : .toolError
            }
            if attention == nil || level >= attention!.level || attention?.kind == kind {
                attention = AttentionBadge(kind: kind, level: level, sessionID: session?.id, summary: event.summary, at: date)
            }
        }
        if decision.banner, let banner = reaction.banner {
            let key = "\(reaction.category.rawValue)-\(session?.id ?? "none")"
            if case .show(let suppressed) = bannerCoalescer.register(key: key, at: date) {
                var content = banner
                if suppressed > 0 { content.body += " (+\(suppressed) similar)" }
                effects?.postBanner(content, category: reaction.category, sessionID: session?.id)
            }
        }
    }

    private func updateAttention(after event: CompanionEvent, session: SessionSnapshot?) {
        guard let current = attention else { return }
        // Badges for sessions that are gone go away with them.
        if let id = current.sessionID, registry[id] == nil {
            attention = nil
            return
        }
        guard current.sessionID == nil || current.sessionID == session?.id else { return }
        switch current.kind {
        case .needsYou:
            if session?.phase != .waitingForUser { attention = nil }
        case .toolError, .buildFailed:
            if [.turnCompleted, .promptSubmitted, .sessionEnded].contains(event.kind) { attention = nil }
        case .apiError:
            if [.promptSubmitted, .sessionEnded].contains(event.kind) { attention = nil }
        }
    }

    private func recordResult(event: CompanionEvent, session: SessionSnapshot, transition: SessionTransition?) {
        let duration = transition?.turnDurationTrusted == true ? transition?.turnDuration : nil
        resultCards[session.id] = ResultCard(
            id: event.id,
            sessionID: session.id,
            projectName: session.displayName,
            projectPath: session.project?.path,
            completedAt: event.timestamp,
            statusLine: "Claude finished responding",
            buildTest: session.buildTestThisTurn,
            observedTurnDuration: duration,
            isSimulated: event.isSimulated
        )
        if resultCards.count > 12, let oldest = resultCards.values.min(by: { $0.completedAt < $1.completedAt }) {
            resultCards[oldest.sessionID] = nil
        }
    }

    private func announce(_ id: AchievementID) {
        let t = uptime()
        let reward = id.reward.map { " · unlocked \($0.title)" } ?? ""
        toast = WorldToast(title: "Achievement: \(id.title)", detail: id.criteria + reward, until: t + 7)
        let decision = NotificationPolicy.decide(.achievement, settings: settings,
                                                 context: NotificationContext(now: clock(), popoverVisible: popoverVisible, focusing: focus?.phase == .focus))
        if decision.animate, interaction == nil, pendingInteraction == nil, pendingGreeting == nil {
            pet.play(.excitedJump, priority: .reaction, at: t)
        }
        if decision.sound { playSound(.achievement) }
        if decision.banner {
            effects?.postBanner(BannerContent(title: "Achievement unlocked: \(id.title)", body: id.criteria), category: .achievement, sessionID: nil)
        }
    }

    private func playSound(_ cue: SoundCue) {
        let t = uptime()
        let minimumGap: TimeInterval = cue == .keyboard ? 4 : 1.5
        if let last = lastSoundAt[cue], t - last < minimumGap { return }
        lastSoundAt[cue] = t
        effects?.play(cue)
    }

    // MARK: Interactions

    /// Starts an interaction. While Mochi is roaming far from home on the menu bar it first
    /// runs home (fast, never teleporting) and the interaction starts beside Patch on arrival.
    /// Returns true when it started or is waiting for Mochi.
    @discardableResult
    public func startInteraction(_ id: InteractionID, priority: AnimationPriority = .interaction, variant: Int = 0, label: String? = nil) -> Bool {
        requestInteraction(id, priority: priority, variant: variant, label: label) != .refused
    }

    /// Like `startInteraction`, saying whether it started now or waits for Mochi to come home.
    /// `fallback` (a real event's own pet reaction) plays if a waiting interaction is dropped.
    @discardableResult
    public func requestInteraction(_ id: InteractionID, priority: AnimationPriority = .interaction, variant: Int = 0, label: String? = nil,
                                   fallback: PetAnimation? = nil) -> InteractionRequest {
        let script = InteractionLibrary.script(id, variant: variant)
        guard !script.requiresCompanion || companionAvailable else { return .refused }
        // Mochi is out on a desktop adventure: nobody beside Patch.
        guard !script.requiresCompanion || !adventureActive else { return .refused }
        let t = uptime()
        if script.requiresCompanion, roamer.isActive, !reducedMotion,
           roamer.distanceFromHome(at: t) > MenuBarRoamer.besideDistance {
            if id == .welcome {
                // Patch's arrival never waits: he lands at once, and Mochi runs home to say hello.
                if !settings.pauseReactions { pendingGreeting = t }
                syncRoamer()
                return .refused
            }
            if let pending = pendingInteraction, pending.priority > priority { return .refused }
            if pet.isPlayingOneShot, !pet.current.isFinished(at: t), priority < pet.current.priority { return .refused }
            pendingInteraction = PendingInteraction(id: id, priority: priority, variant: variant, label: label, requestedAt: t, fallback: fallback)
            syncRoamer()
            return .deferred
        }
        let started = beginInteraction(id, priority: priority, variant: variant, label: label)
        if started { syncRoamer() }
        return started ? .started : .refused
    }

    @discardableResult
    private func beginInteraction(_ id: InteractionID, priority: AnimationPriority, variant: Int, label: String?) -> Bool {
        let script = InteractionLibrary.script(id, variant: variant)
        guard !script.requiresCompanion || companionAvailable else { return false }
        let t = uptime()
        var playback = InteractionPlayback(id: id, startedAt: t, variant: variant, companionLoop: companionLoopForScripts(), sessionLabel: label)
        guard case .started(let petToken, _) = pet.play(.scripted, priority: priority, at: t, duration: script.duration,
                                                        scriptID: id.rawValue, ignoreCooldown: true) else {
            return false
        }
        guard case .started(let companionToken, _) = companion.play(.scripted, priority: priority, at: t, duration: script.duration,
                                                                    scriptID: id.rawValue, ignoreCooldown: true) else {
            pet.cancel(token: petToken, at: t)
            return false
        }
        playback.petToken = petToken
        playback.companionToken = companionToken
        interaction = playback
        if petAsleep { petAsleep = false }
        scheduler.noteTriggered(id, now: t)
        return true
    }

    private func companionLoopForScripts() -> CompanionAnimation {
        let base = companion.base
        return base == .absent || base == .sleep ? .idleAtDesk : base
    }

    // MARK: User interactions

    public func interact(_ kind: PetInteraction) {
        let date = clock()
        lastUserInteractionAt = date
        let t = uptime()
        scheduler.postpone(now: t, by: 40)
        let result = achievements.recordInteraction(kind, at: date)
        progress = achievements.state
        let wasAsleep = petAsleep
        petAsleep = false
        let animation: PetAnimation
        switch kind {
        case .pet: animation = wasAsleep ? .wakeUp : .petted
        case .play: animation = .play
        case .treat: animation = .treat
        }
        if !settings.pauseReactions {
            pet.play(animation, priority: .user, at: t, ignoreCooldown: true)
            if kind != .pet { startBarGame(kind == .play ? .play : .treat, at: t) }
            if companionPresent, kind != .pet, companion.current.animation.isLoop, companion.base != .waiting {
                companion.play(.nod, priority: .ambient, at: t + 0.01)
            }
            if settings.soundEnabled, !NotificationPolicy.isQuiet(settings, at: date) {
                playSound(kind == .pet ? .pop : .greeting)
            }
            effects?.userDidInteract(kind)
        }
        if result.levelUp {
            toast = WorldToast(title: "Friendship level \(progress.friendshipLevel)", detail: "\(settings.petName) is happy you're here.", until: t + 6)
        }
        for id in result.unlocked { announce(id) }
        updateBases()
        syncRoamer()
    }

    /// A milestone the user marks by hand. Recorded as a real, user-originated event.
    public func markMilestone(label: String?) {
        let date = clock()
        var wire = WireEvent(id: "manual-\(UUID().uuidString.lowercased())", ts: date.timeIntervalSince1970, origin: .report, event: "Report")
        wire.report = WireReport(kind: "milestone", status: "reached", label: WireText.clean(label, maxLength: 60) ?? "Marked by you")
        wire.session = primarySession.flatMap { $0.phase != .ended && !$0.isSimulated ? $0.id : nil }
        if let project = primarySession?.project {
            wire.project = project.displayName
            wire.projectKey = project.key
        }
        lastUserInteractionAt = date
        ingest(wire)
    }

    /// The user clicked the companion: a small, purely cosmetic hello.
    public func pokeCompanion() {
        guard companionPresent, !departing, !settings.pauseReactions, interaction == nil else { return }
        let t = uptime()
        lastUserInteractionAt = clock()
        scheduler.postpone(now: t, by: 30)
        switch companion.base {
        case .sleep: companion.play(.wakeUp, priority: .user, at: t, ignoreCooldown: true)
        case .waiting: return
        default: companion.play(companion.base.isWorking ? .nod : .greet, priority: .user, at: t, ignoreCooldown: true)
        }
    }

    public func acknowledgeAttention() {
        if attention?.kind != .needsYou { attention = nil }
    }

    public func dismissResult(_ sessionID: String) { resultCards[sessionID] = nil }

    public func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        if visible { acknowledgeAttention() }
        syncRoamer()
        if !visible, let followUp = popoverFollowUp {
            popoverFollowUp = nil
            let t = uptime()
            if t - followUp.at < 60 { startBarGame(followUp.game == .play ? .playFollowUp : .treatFollowUp, at: t) }
        }
    }

    /// Play and Treat on the menu bar: with the popover closed the roamer turns them into a game
    /// along the bar (the world's own clip still plays for the popover and the desktop pet);
    /// with it open, the clip plays in place and a short follow-up runs once it closes.
    private func startBarGame(_ game: RoamUserGame, at t: TimeInterval) {
        guard roamer.isActive, !reducedMotion, !settings.pauseReactions, interaction == nil, pendingInteraction == nil else { return }
        if popoverVisible {
            if game == .play || game == .treat { popoverFollowUp = (game, t) }
            return
        }
        var copy = roamer
        let token = pet.current.token
        let wasGame = barGameToken
        barGameToken = token
        if copy.startUserGame(game, now: t, context: roamContext(at: t, date: clock())) {
            roamer = copy
        } else {
            barGameToken = wasGame
        }
    }

    public func setSystemReducedMotion(_ value: Bool) {
        systemReducedMotion = value
        syncRoamer()
    }

    // MARK: Menu bar roaming

    /// Hands the roamer its strip of menu bar (nil turns roaming off, e.g. for the classic icon).
    public func setRoamZone(_ zone: RoamZone?) {
        let t = uptime()
        var copy = roamer
        copy.setZone(zone, now: t, context: roamContext(at: t, date: clock()))
        if copy != roamer { roamer = copy }
        if zone == nil {
            pendingGreeting = nil
            if let pending = pendingInteraction {
                pendingInteraction = nil
                if !beginInteraction(pending.id, priority: pending.priority, variant: pending.variant, label: pending.label),
                   let fallback = pending.fallback {
                    pet.play(fallback, priority: pending.priority, at: t)
                }
            }
        }
    }

    /// Development helper: Mochi plays one roaming activity now.
    public func forceRoamActivity(_ activity: RoamActivity) {
        let t = uptime()
        var copy = roamer
        copy.force(activity, now: t, context: roamContext(at: t, date: clock()))
        if copy != roamer { roamer = copy }
    }

    /// Tests and development: puts Mochi somewhere on the bar.
    public func placeRoamer(at x: Double) {
        let t = uptime()
        var copy = roamer
        copy.place(at: x, now: t)
        copy.update(now: t, context: roamContext(at: t, date: clock()))
        roamer = copy
    }

    /// Re-evaluates the roamer against the current context; starts a pending interaction
    /// once Mochi is home. Mutates only when something changed.
    func syncRoamer() {
        guard roamer.isActive else { return }
        let t = uptime()
        let date = clock()
        var copy = roamer
        copy.update(now: t, context: roamContext(at: t, date: date))
        if copy != roamer { roamer = copy }
        var changed = false
        if let greeting = pendingGreeting {
            if !companionAvailable || settings.pauseReactions || interaction != nil || t - greeting > 10 {
                pendingGreeting = nil
                changed = true
            } else if pendingInteraction == nil, roamer.mode == .summoned, roamer.isHome(at: t) || t - greeting > 7 {
                // Home: a hello beside Patch.
                pendingGreeting = nil
                pet.play(.greet, priority: .reaction, at: t, ignoreCooldown: true)
                changed = true
            }
        }
        if let pending = pendingInteraction {
            if !companionAvailable || settings.pauseReactions || t - pending.requestedAt > 12 {
                pendingInteraction = nil
                // The real event still gets its own reaction.
                if let fallback = pending.fallback, !settings.pauseReactions { pet.play(fallback, priority: pending.priority, at: t) }
                changed = true
            } else if roamer.mode == .summoned, roamer.isHome(at: t) || t - pending.requestedAt > 8 {
                pendingInteraction = nil
                if !beginInteraction(pending.id, priority: pending.priority, variant: pending.variant, label: pending.label),
                   let fallback = pending.fallback {
                    pet.play(fallback, priority: pending.priority, at: t)
                }
                changed = true
            }
        }
        if changed { settleRoamer(at: t, date: date) }
    }

    private func settleRoamer(at t: TimeInterval, date: Date) {
        var settled = roamer
        settled.update(now: t, context: roamContext(at: t, date: date))
        if settled != roamer { roamer = settled }
    }

    /// True while the roamer is busy with something other than a calm rest (ambient fidgets wait).
    private var roamerBusy: Bool {
        guard roamer.isActive else { return false }
        return !roamer.isResting(at: uptime(), for: 4.5)
    }

    public func setSimulatorRunning(_ running: Bool) {
        simulatorRunning = running
    }

    // MARK: Connection

    public func updateBridge(listening: Bool, error: String?, accepted: Int, rejected: Int, lastRejection: String?, refusedPeers: Int) {
        var status = connection
        status.bridgeListening = listening
        status.bridgeError = error
        status.eventsAccepted = accepted
        status.eventsRejected = rejected
        status.lastRejection = lastRejection
        status.refusedPeers = refusedPeers
        if status != connection { connection = status }
        updateBases()
    }

    public func updateIntegration(_ state: IntegrationState, claude: ClaudeAvailability? = nil) {
        var status = connection
        status.integration = state
        if let claude { status.claude = claude }
        if status != connection { connection = status }
    }

    // MARK: Maintenance

    public func clearHistory() {
        journal.clear()
        timeline.removeAll { !$0.isSimulated }
        resultCards = resultCards.filter { $0.value.isSimulated }
    }

    public func clearSimulated() {
        registry.remove { $0.isSimulated }
        timeline.removeAll { $0.isSimulated }
        resultCards = resultCards.filter { !$0.value.isSimulated }
        if let id = attention?.sessionID, registry[id] == nil { attention = nil }
        if let pinned = settings.pinnedSessionID, registry[pinned] == nil { settings.pinnedSessionID = nil }
        updatePresence()
        updateBases()
    }

    public func pin(sessionID: String?) {
        settings.pinnedSessionID = sessionID
        updateBases()
    }

    /// Development helpers used by the simulator panel.
    public func preview(pet animation: PetAnimation) {
        petAsleep = false
        pet.play(animation, priority: .critical, at: uptime(), ignoreCooldown: true)
        syncRoamer()
    }

    public func preview(companion animation: CompanionAnimation) {
        guard companionPresent else { return }
        companion.play(animation, priority: .critical, at: uptime(), ignoreCooldown: true)
    }

    // MARK: Feature hooks

    /// Plays a one-shot for the pet on behalf of a feature (focus breaks, games, seasons, adventures).
    @discardableResult
    public func playPet(_ animation: PetAnimation, priority: AnimationPriority = .user) -> Bool {
        guard !settings.pauseReactions else { return false }
        if animation != .sleep { petAsleep = false }
        _ = pet.play(animation, priority: priority, at: uptime(), ignoreCooldown: true)
        syncRoamer()
        return true
    }

    /// Plays a one-shot for the companion on behalf of a feature, if it is here.
    @discardableResult
    public func playCompanion(_ animation: CompanionAnimation, priority: AnimationPriority = .user) -> Bool {
        guard companionPresent, !departing, !settings.pauseReactions else { return false }
        _ = companion.play(animation, priority: priority, at: uptime(), ignoreCooldown: true)
        return true
    }

    /// A short note at the top of the scene.
    public func showToast(title: String, detail: String, seconds: TimeInterval = 6) {
        toast = WorldToast(title: title, detail: detail, until: uptime() + seconds)
    }

    // MARK: Ticking

    /// Advances animations, interactions and ambient behaviour. Call a few times a second.
    public func tick() {
        let t = uptime()
        let date = clock()

        var companionCopy = companion
        if let completion = companionCopy.update(at: t), completion.animation == .depart {
            companionPresent = false
            departing = false
            companionCopy.setBase(.absent, at: t)
        } else if departing, companionCopy.current.animation != .depart {
            // Something interrupted the departure: finish leaving rather than lingering.
            companionCopy.play(.depart, priority: .critical, at: t, ignoreCooldown: true)
        }
        if companionCopy != companion { companion = companionCopy }
        var petCopy = pet
        _ = petCopy.update(at: t)
        if petCopy != pet { pet = petCopy }

        if let playback = interaction {
            let petIntact = pet.current.token == playback.petToken
            let companionIntact = companion.current.token == playback.companionToken
            if !petIntact || !companionIntact {
                // One side was interrupted by something more important: end cleanly.
                if petIntact, let token = playback.petToken { pet.cancel(token: token, at: t) }
                if companionIntact, let token = playback.companionToken { companion.cancel(token: token, at: t) }
                interaction = nil
            } else if playback.isFinished(at: t) {
                interaction = nil
            }
        }

        if let caption, caption.until <= t { self.caption = nil }
        if let toast, toast.until <= t { self.toast = nil }
        if let burst, t - burst.startedAt > 4 { self.burst = nil }

        if t - lastPruneAt > 60 {
            lastPruneAt = t
            registry.prune(now: date)
            if let pinned = settings.pinnedSessionID, registry[pinned] == nil { settings.pinnedSessionID = nil }
            resultCards = resultCards.filter { date.timeIntervalSince($0.value.completedAt) < 3600 }
        }

        updatePresence()
        updateNap(date: date, t: t)
        scheduleAmbient(date: date, t: t)
        updateBases()
        syncRoamer()
    }

    private func activity(date: Date) -> AmbientActivity {
        guard let session = primarySession, !session.isStale(now: date) else { return .idle }
        if session.phase == .waitingForUser { return .waiting }
        return session.phase.isWorking ? .working : .idle
    }

    /// How the Mac is being used: with "follow my Mac" on, the pet sleeps while it rests and wakes
    /// with a stretch when you're back.
    public func updateSystem(_ activity: SystemActivity) {
        system = activity
        let resting = activity.isResting(after: TimeInterval(max(1, settings.restAfterMinutes)) * 60)
        if resting != macResting { macResting = resting }
    }

    private func updateNap(date: Date, t: TimeInterval) {
        let followsMac = settings.followSystem && system != nil
        if followsMac, petAsleep, !macResting, system?.userActive == true, interaction == nil, !settings.pauseReactions {
            petAsleep = false
            pet.play(.wakeUp, priority: .reaction, at: t, ignoreCooldown: true)
            return
        }
        guard !petAsleep, interaction == nil, !pet.isPlayingOneShot, !settings.pauseReactions else { return }
        let idleFor = date.timeIntervalSince(max(lastUserInteractionAt, lastLiveActivityAt))
        if followsMac {
            // Asleep while the Mac rests, unless Claude is at work or you just played with it.
            guard macResting, idleFor > 60, activity(date: date) == .idle else { return }
        } else {
            let napAfter: TimeInterval = 8 * 60 * settings.animationIntensity.gapMultiplier
            guard idleFor > napAfter, activity(date: date) == .idle else { return }
        }
        pet.play(.yawn, priority: .ambient, at: t, ignoreCooldown: true)
        petAsleep = true
    }

    private func scheduleAmbient(date: Date, t: TimeInterval) {
        let idleSeconds = date.timeIntervalSince(max(lastUserInteractionAt, lastLiveActivityAt))
        let context = SchedulerContext(
            companionPresent: companionPresent && !departing && companion.current.animation != .absent,
            activity: activity(date: date),
            idleSeconds: idleSeconds,
            charactersBusy: interaction != nil || pendingInteraction != nil || pendingGreeting != nil || pet.isPlayingOneShot
                || companion.isPlayingOneShot || roamerBusy,
            paused: settings.pauseReactions,
            reducedMotion: reducedMotion,
            intensity: settings.animationIntensity,
            petAsleep: petAsleep
        )
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        if let (id, variant) = scheduler.nextInteraction(now: t, day: day, context: context) {
            startInteraction(id, priority: .interaction, variant: variant)
            return
        }
        if let solo = scheduler.nextSolo(now: t, context: context) {
            pet.play(solo, priority: .ambient, at: t)
        }
    }

    // MARK: Presence and base loops

    private func updatePresence(animated: Bool = true) {
        let date = clock()
        let t = uptime()
        let wantsCompanion: Bool
        switch settings.companionVisibility {
        case .always: wantsCompanion = true
        case .never: wantsCompanion = false
        case .duringSessions:
            let lingering = lastSessionEndedAt.map { date.timeIntervalSince($0) < TimeInterval(settings.companionLingerMinutes * 60) } ?? false
            wantsCompanion = registry.hasLiveSessions(now: date) || lingering
        }

        if wantsCompanion, !companionPresent || departing {
            companionPresent = true
            departing = false
            let loop = EventToAnimationMapper.companionLoop(for: primarySession, now: date, sleepAfter: sleepAfter, offline: false)
            companion.setBase(loop == .sleep ? .idleAtDesk : loop, at: t)
            if animated, !settings.pauseReactions {
                if !startInteraction(.welcome, priority: .user) {
                    companion.play(.arrive, priority: .user, at: t, ignoreCooldown: true)
                }
            }
        } else if !wantsCompanion, companionPresent, !departing {
            if !animated || settings.pauseReactions {
                companionPresent = false
                companion.setBase(.absent, at: t)
                return
            }
            if case .started = companion.play(.depart, priority: .reaction, at: t, ignoreCooldown: true) {
                departing = true
            }
        }
    }

    private var sleepAfter: TimeInterval { TimeInterval(max(1, settings.companionSleepAfterMinutes) * 60) }

    private func updateBases() {
        let date = clock()
        let t = uptime()
        let session = primarySession
        var companionCopy = companion
        if companionPresent, !departing {
            let offline = connection.bridgeError != nil
            let loop = EventToAnimationMapper.companionLoop(for: session, now: date, sleepAfter: sleepAfter, offline: offline)
            if companionCopy.base == .sleep, loop != .sleep, !companionCopy.isPlayingOneShot, !settings.pauseReactions {
                companionCopy.play(.wakeUp, priority: .ambient, at: t)
            }
            companionCopy.setBase(loop, at: t)
        } else if !companionPresent {
            companionCopy.setBase(.absent, at: t)
        }
        if companionCopy != companion { companion = companionCopy }
        var petCopy = pet
        petCopy.setBase(EventToAnimationMapper.petLoop(for: session, now: date, asleep: petAsleep || (focus?.petNaps ?? false)), at: t)
        if settings.pauseReactions, let token = interaction?.petToken {
            petCopy.cancel(token: token, at: t)
        }
        if petCopy != pet { pet = petCopy }
    }

    private func settingsChanged(from old: AppSettings) {
        journal.storeProjectPaths = settings.storeProjectPaths
        let retention = EventJournal.Retention(days: settings.historyRetentionDays)
        if journal.retention != retention {
            journal.retention = retention
            journal.enforceRetention(now: clock())
        }
        if old.companionVisibility != settings.companionVisibility || old.pauseReactions != settings.pauseReactions {
            updatePresence()
        }
        if !old.pauseReactions, settings.pauseReactions {
            let t = uptime()
            pet.cancelOneShot(at: t)
            companion.cancelOneShot(at: t)
            interaction = nil
            pendingInteraction = nil
            pendingGreeting = nil
            popoverFollowUp = nil
        }
        syncRoamer()
    }

    // MARK: Helpers

    private func rememberID(_ id: String) -> Bool {
        if recentIDSet.contains(id) || journal.contains(id: id) { return false }
        markSeen(id)
        return true
    }

    private func markSeen(_ id: String) {
        recentIDs.append(id)
        recentIDSet.insert(id)
        if recentIDs.count > 1_024 {
            let removed = recentIDs.removeFirst()
            recentIDSet.remove(removed)
        }
    }

    private func appendTimeline(_ event: CompanionEvent) {
        timeline.append(event)
        if timeline.count > 120 { timeline.removeFirst(timeline.count - 120) }
    }
}
