import Foundation
import Testing
@testable import TamagotchiCore

@Suite("Session state machine")
struct SessionRegistryTests {
    @Test func fullTurnTransitions() {
        var registry = SessionRegistry()
        let t0 = Date()
        registry.apply(TestSupport.event("SessionStart", at: t0))
        #expect(registry["s1"]?.phase == .idle)
        registry.apply(TestSupport.event("UserPromptSubmit", at: t0 + 1))
        #expect(registry["s1"]?.phase == .promptSubmitted)
        registry.apply(TestSupport.event("PreToolUse", tool: "Read", toolUseId: "t1", at: t0 + 2))
        #expect(registry["s1"]?.phase == .runningTool)
        registry.apply(TestSupport.event("PostToolUse", tool: "Read", toolUseId: "t1", at: t0 + 3))
        // A successful tool is not a finished turn.
        #expect(registry["s1"]?.phase == .thinking)
        registry.apply(TestSupport.event("Stop", at: t0 + 4))
        #expect(registry["s1"]?.phase == .turnCompleted)
        #expect(registry["s1"]?.turnsCompleted == 1)
        registry.apply(TestSupport.event("SessionEnd", at: t0 + 5) { $0.reason = "prompt_input_exit" })
        #expect(registry["s1"]?.phase == .ended)
    }

    @Test func parallelToolsTrackedByToolUseID() {
        var registry = SessionRegistry()
        let t0 = Date()
        registry.apply(TestSupport.event("UserPromptSubmit", at: t0))
        registry.apply(TestSupport.event("PreToolUse", tool: "Read", toolUseId: "a", at: t0 + 1))
        registry.apply(TestSupport.event("PreToolUse", tool: "Grep", toolUseId: "b", at: t0 + 1))
        registry.apply(TestSupport.event("PostToolUse", tool: "Read", toolUseId: "a", at: t0 + 2))
        #expect(registry["s1"]?.phase == .runningTool)
        #expect(registry["s1"]?.currentTool?.name == "Grep")
        registry.apply(TestSupport.event("PostToolUse", tool: "Grep", toolUseId: "b", at: t0 + 2))
        #expect(registry["s1"]?.phase == .thinking)
    }

    @Test func failuresDriveDetectiveModeAndResetOnSuccess() {
        var registry = SessionRegistry()
        let t0 = Date()
        registry.apply(TestSupport.event("UserPromptSubmit", at: t0))
        var started = false
        for index in 0..<3 {
            registry.apply(TestSupport.event("PreToolUse", tool: "Bash", toolUseId: "f\(index)", at: t0 + Double(index)))
            let transition = registry.apply(TestSupport.event("PostToolUseFailure", tool: "Bash", toolUseId: "f\(index)", at: t0 + Double(index) + 0.5))
            if transition?.startedInvestigating == true { started = true }
        }
        #expect(started)
        #expect(registry["s1"]?.isInvestigating == true)
        registry.apply(TestSupport.event("PreToolUse", tool: "Read", toolUseId: "ok", at: t0 + 5))
        registry.apply(TestSupport.event("PostToolUse", tool: "Read", toolUseId: "ok", at: t0 + 6))
        #expect(registry["s1"]?.consecutiveFailures == 0)
        #expect(registry["s1"]?.investigatedThisTurn == true)
    }

    @Test func interruptsAreNotFailures() {
        var registry = SessionRegistry()
        registry.apply(TestSupport.event("PostToolUseFailure", tool: "Bash") { $0.isInterrupt = true })
        #expect(registry["s1"]?.failuresThisTurn == 0)
    }

    @Test func permissionWaitClearsWhenToolProceeds() {
        var registry = SessionRegistry()
        let t0 = Date()
        registry.apply(TestSupport.event("PreToolUse", tool: "Bash", toolUseId: "p", at: t0))
        registry.apply(TestSupport.event("PermissionRequest", tool: "Bash", at: t0 + 0.2))
        #expect(registry["s1"]?.phase == .waitingForUser)
        #expect(registry["s1"]?.waitingFor == .permission)
        registry.apply(TestSupport.event("PostToolUse", tool: "Bash", toolUseId: "p", at: t0 + 5))
        #expect(registry["s1"]?.phase == .thinking)
        #expect(registry["s1"]?.waitingFor == nil)
    }

    @Test func sessionsNeverMix() {
        var registry = SessionRegistry()
        let t0 = Date()
        registry.apply(TestSupport.event("UserPromptSubmit", session: "a", project: "/p/InsideEdge", at: t0))
        registry.apply(TestSupport.event("PermissionRequest", session: "b", project: "/p/Deskdrop", tool: "Bash", at: t0 + 1))
        registry.apply(TestSupport.event("Stop", session: "a", project: "/p/InsideEdge", at: t0 + 2))
        #expect(registry["a"]?.phase == .turnCompleted)
        #expect(registry["b"]?.phase == .waitingForUser)
        #expect(registry["a"]?.displayName == "InsideEdge")
        #expect(registry["b"]?.displayName == "Deskdrop")
    }

    @Test func primaryRuleFollowsDocumentedPriorities() {
        var registry = SessionRegistry()
        let t0 = Date()
        registry.apply(TestSupport.event("UserPromptSubmit", session: "working", at: t0))
        registry.apply(TestSupport.event("Stop", session: "done", at: t0 + 1))
        #expect(registry.primarySession(pinned: nil, now: t0 + 2)?.id == "working")
        registry.apply(TestSupport.event("PermissionRequest", session: "waiting", tool: "Bash", at: t0 + 3))
        #expect(registry.primarySession(pinned: nil, now: t0 + 4)?.id == "waiting")
        // Pinning overrides the ranking while the pinned session is alive.
        #expect(registry.primarySession(pinned: "done", now: t0 + 4)?.id == "done")
        registry.apply(TestSupport.event("SessionEnd", session: "done", at: t0 + 5))
        #expect(registry.primarySession(pinned: "done", now: t0 + 6)?.id == "waiting")
    }

    @Test func staleSessionsAreReportedHonestly() {
        var registry = SessionRegistry()
        let t0 = Date()
        registry.apply(TestSupport.event("PreToolUse", tool: "Bash", at: t0))
        let later = t0 + SessionRegistry.staleAfter + 60
        #expect(registry["s1"]?.isStale(now: later) == true)
        #expect(registry["s1"]?.statusLine(now: later).contains("may have closed") == true)
    }

    @Test func lateOutOfOrderEventsDoNotRewindState() {
        var registry = SessionRegistry()
        let t0 = Date()
        registry.apply(TestSupport.event("Stop", at: t0 + 10))
        registry.apply(TestSupport.event("PreToolUse", tool: "Bash", at: t0, delivery: .late))
        #expect(registry["s1"]?.phase == .turnCompleted)
        #expect(registry["s1"]?.lateEvents == 1)
    }

    @Test func joiningMidSessionWorks() {
        var registry = SessionRegistry()
        let transition = registry.apply(TestSupport.event("PreToolUse", tool: "Edit"))
        #expect(transition?.isNewSession == true)
        #expect(registry["s1"]?.startObserved == false)
        #expect(registry["s1"]?.phase == .runningTool)
    }

    @Test func reportsAttachToSessionOfSameProject() {
        var registry = SessionRegistry()
        registry.apply(TestSupport.event("UserPromptSubmit", session: "a", project: "/p/App"))
        var report = TestSupport.event("Report", session: nil, project: "/p/App")
        report.kind = .report
        report.report = ExplicitReport(kind: .test, status: .passed, label: nil)
        registry.apply(report)
        #expect(registry["a"]?.buildTestThisTurn?.passed == true)
        #expect(registry["a"]?.buildTestThisTurn?.source == .explicitReport)
    }
}

@Suite("Event to animation mapping")
struct MapperTests {
    func react(_ event: CompanionEvent, registry: inout SessionRegistry, primary: Bool = true, companion: Bool = true) -> Reaction? {
        let transition = registry.apply(event)
        let session = transition.flatMap { registry[$0.sessionID] }
        return EventToAnimationMapper.reaction(for: event, transition: transition, session: session,
                                               context: MapperContext(companionPresent: companion, isPrimary: primary))
    }

    @Test func toolSuccessIsSmallAndNotACelebration() {
        var registry = SessionRegistry()
        _ = react(TestSupport.event("UserPromptSubmit"), registry: &registry)
        let reaction = react(TestSupport.event("PostToolUse", tool: "Bash"), registry: &registry)
        #expect(reaction?.category == .toolActivity)
        #expect(reaction?.interaction == nil)
        #expect(reaction?.burst == false)
        #expect(reaction?.resultCard == false)
    }

    @Test func turnCompletionCelebratesTogether() {
        var registry = SessionRegistry()
        _ = react(TestSupport.event("UserPromptSubmit"), registry: &registry)
        let reaction = react(TestSupport.event("Stop"), registry: &registry)
        #expect(reaction?.category == .turnCompleted)
        #expect(reaction?.interaction == .highFive)
        #expect(reaction?.resultCard == true)
        #expect(reaction?.banner?.body.contains("No build or test result") == true)
    }

    @Test func explicitPassingTestsEarnTheTrophy() {
        var registry = SessionRegistry()
        _ = react(TestSupport.event("UserPromptSubmit"), registry: &registry)
        var report = TestSupport.event("Report")
        report.kind = .report
        report.report = ExplicitReport(kind: .test, status: .passed, label: "swift test")
        _ = react(report, registry: &registry)
        let reaction = react(TestSupport.event("Stop"), registry: &registry)
        #expect(reaction?.interaction == .trophyCelebration)
    }

    @Test func toolFailureIsConcernNotDoom() {
        var registry = SessionRegistry()
        _ = react(TestSupport.event("UserPromptSubmit"), registry: &registry)
        let reaction = react(TestSupport.event("PostToolUseFailure", tool: "Bash") { $0.exitCode = 2 }, registry: &registry)
        #expect(reaction?.pet == .concerned)
        #expect(reaction?.companion == .concerned)
        #expect(reaction?.category == .toolFailure)
        #expect(reaction?.banner?.body.contains("may still be working") == true)
    }

    @Test func thirdFailureStartsDetectiveMode() {
        var registry = SessionRegistry()
        _ = react(TestSupport.event("UserPromptSubmit"), registry: &registry)
        var last: Reaction?
        for _ in 0..<3 { last = react(TestSupport.event("PostToolUseFailure", tool: "Bash"), registry: &registry) }
        #expect(last?.interaction == .detectiveHat)
        let done = react(TestSupport.event("Stop"), registry: &registry)
        #expect(done?.interaction == .caseClosed)
    }

    @Test func permissionPairReactsOnce() {
        var registry = SessionRegistry()
        let first = react(TestSupport.event("PermissionRequest", tool: "Bash"), registry: &registry)
        let second = react(TestSupport.event("Notification") { $0.notificationType = "permission_prompt" }, registry: &registry)
        #expect(first?.category == .needsAttention)
        #expect(first?.priority == .attention)
        #expect(second == nil)
    }

    @Test func nonPrimaryCompletionDoesNotHijackTheScene() {
        var registry = SessionRegistry()
        _ = react(TestSupport.event("UserPromptSubmit", session: "b"), registry: &registry)
        let reaction = react(TestSupport.event("Stop", session: "b"), registry: &registry, primary: false)
        #expect(reaction?.interaction == nil)
        #expect(reaction?.caption?.hasPrefix("InsideEdge · ") == true)
    }

    @Test func workLoopsOnlyGetSpecificWhenToolSaysSo() {
        #expect(EventToAnimationMapper.workLoop(for: .read) == .reading)
        #expect(EventToAnimationMapper.workLoop(for: .search) == .searching)
        #expect(EventToAnimationMapper.workLoop(for: .mcp) == .typing)
        #expect(EventToAnimationMapper.workLoop(for: .other) == .typing)
        #expect(EventToAnimationMapper.workLoop(for: nil) == .typing)
    }

    @Test func unknownEventsDoNotAnimate() {
        var registry = SessionRegistry()
        #expect(react(TestSupport.event("FutureEvent"), registry: &registry) == nil)
    }

    @Test func longTrustedTurnsGetTheVictoryDance() {
        var registry = SessionRegistry()
        let t0 = Date().addingTimeInterval(-900)
        _ = react(TestSupport.event("UserPromptSubmit", at: t0), registry: &registry)
        let reaction = react(TestSupport.event("Stop", at: t0 + 700), registry: &registry)
        #expect(reaction?.interaction == .victoryDance)
    }

    @Test func lateTurnStartsAreNotTrustedForDuration() {
        var registry = SessionRegistry()
        let t0 = Date().addingTimeInterval(-900)
        _ = react(TestSupport.event("UserPromptSubmit", at: t0, delivery: .late), registry: &registry)
        let reaction = react(TestSupport.event("Stop", at: t0 + 700), registry: &registry)
        #expect(reaction?.interaction == .highFive)
    }
}

@Suite("Character animator")
struct AnimatorTests {
    @Test func higherPriorityInterruptsLowerIsDropped() {
        var animator = CharacterAnimator<PetAnimation>(base: .idle, at: 0)
        guard case .started = animator.play(.lookAround, priority: .ambient, at: 0) else { Issue.record("not started"); return }
        guard case .started(_, let interrupted) = animator.play(.concerned, priority: .reaction, at: 0.5) else { Issue.record("not started"); return }
        #expect(interrupted != nil)
        #expect(animator.play(.blep, priority: .ambient, at: 0.6) == .busy)
        #expect(animator.current.animation == .concerned)
    }

    @Test func oneShotsFallBackToCurrentBase() {
        var animator = CharacterAnimator<PetAnimation>(base: .idle, at: 0)
        animator.play(.happyBounce, priority: .reaction, at: 0)
        animator.setBase(.watch, at: 0.2)
        #expect(animator.current.animation == .happyBounce)
        let completion = animator.update(at: 5)
        #expect(completion?.finished == true)
        #expect(animator.current.animation == .watch)
    }

    @Test func cooldownsPreventRepetition() {
        var animator = CharacterAnimator<PetAnimation>(base: .idle, at: 0)
        animator.play(.nod, priority: .ambient, at: 0)
        _ = animator.update(at: 2)
        #expect(animator.play(.nod, priority: .ambient, at: 3) == .coolingDown)
        if case .started = animator.play(.nod, priority: .ambient, at: 20) {} else { Issue.record("cooldown should have expired") }
    }

    @Test func cancellingObsoleteTokensIsSafe() {
        var animator = CharacterAnimator<PetAnimation>(base: .idle, at: 0)
        guard case .started(let first, _) = animator.play(.dance, priority: .ambient, at: 0) else { return }
        animator.play(.concerned, priority: .reaction, at: 0.1)
        #expect(animator.cancel(token: first, at: 0.2) == nil)
        #expect(animator.current.animation == .concerned)
    }

    @Test func everyPoseIsFiniteThroughoutEveryAnimation() {
        for reduced in [false, true] {
            let context = PoseContext(time: 12.3, reducedMotion: reduced)
            for animation in PetAnimation.allCases {
                for step in stride(from: 0.0, through: animation.defaultDuration + 0.5, by: 0.1) {
                    let pose = PetPoseEvaluator.pose(animation, elapsed: step, context: context)
                    #expect(pose.x.isFinite && pose.y.isFinite && pose.rotation.isFinite && pose.scaleX > 0.5 && pose.scaleY > 0.5)
                    if reduced { #expect(abs(pose.y) < 0.001 && abs(pose.x) < 0.001) }
                }
            }
            for animation in CompanionAnimation.allCases {
                for step in stride(from: 0.0, through: animation.defaultDuration + 0.5, by: 0.1) {
                    let pose = CompanionPoseEvaluator.pose(animation, elapsed: step, context: context)
                    #expect(pose.y.isFinite && pose.rotation.isFinite && pose.opacity >= 0 && pose.opacity <= 1)
                    if reduced { #expect(abs(pose.rotation) < 0.001) }
                }
            }
        }
    }

    @Test func interactionScriptsAreWellFormed() {
        for id in InteractionID.allCases {
            for variant in 0..<9 {
                let script = InteractionLibrary.script(id, variant: variant)
                #expect(script.pet.first?.start == 0)
                #expect(script.companion.first?.start == 0)
                #expect(script.pet.last!.end <= script.duration + 0.001)
                // Characters must end where they started, so nothing snaps afterwards.
                let finalPet = script.pet.last!
                #expect(abs(finalPet.to) < 0.001, "pet ends away from home in \(id)")
                #expect(abs(finalPet.lift.1) < 0.001, "pet ends lifted in \(id)")
                let finalCompanion = script.companion.last!
                #expect(abs(finalCompanion.to) < 0.001, "companion ends away from home in \(id)")
            }
        }
    }
}

@Suite("Interaction scheduler")
struct SchedulerTests {
    func context(_ activity: AmbientActivity = .idle, idle: TimeInterval = 600) -> SchedulerContext {
        SchedulerContext(companionPresent: true, activity: activity, idleSeconds: idle)
    }

    @Test func deterministicForASeed() {
        func run(seed: UInt64) -> [InteractionID] {
            var scheduler = InteractionScheduler(seed: seed, now: 0)
            var picks: [InteractionID] = []
            var now = 0.0
            while now < 4 * 3600 {
                now += 30
                if let (id, _) = scheduler.nextInteraction(now: now, day: 1, context: context()) { picks.append(id) }
            }
            return picks
        }
        #expect(run(seed: 7) == run(seed: 7))
        #expect(!run(seed: 7).isEmpty)
    }

    @Test func respectsGapsCooldownsAndNoImmediateRepeats() {
        var scheduler = InteractionScheduler(seed: 3, now: 0)
        var starts: [(InteractionID, Double)] = []
        var now = 0.0
        while now < 6 * 3600 {
            now += 10
            if let (id, _) = scheduler.nextInteraction(now: now, day: 1, context: context()) { starts.append((id, now)) }
        }
        for (a, b) in zip(starts, starts.dropFirst()) {
            #expect(b.1 - a.1 >= InteractionScheduler.baseInteractionGap * 0.7 - 10)
            #expect(a.0 != b.0)
        }
        let rare = starts.filter { $0.0 == .chairSteal }
        #expect(rare.count <= 1)
    }

    @Test func nothingWhileWaitingOrPaused() {
        var scheduler = InteractionScheduler(seed: 1, now: 0)
        #expect(scheduler.nextInteraction(now: 10_000, day: 1, context: context(.waiting)) == nil)
        var paused = context()
        paused.paused = true
        #expect(scheduler.nextInteraction(now: 10_000, day: 1, context: paused) == nil)
        #expect(scheduler.nextSolo(now: 10_000, context: paused) == nil)
    }

    @Test func workingContextOnlyAllowsWorkFriendlyInteractions() {
        var scheduler = InteractionScheduler(seed: 11, now: 0)
        var now = 0.0
        while now < 8 * 3600 {
            now += 20
            if let (id, _) = scheduler.nextInteraction(now: now, day: 1, context: context(.working, idle: 0)) {
                #expect([.coffeeDelivery, .showCode, .ballDistraction].contains(id))
            }
        }
    }

    @Test func realEventsPostponeAmbientBehaviour() {
        var scheduler = InteractionScheduler(seed: 5, now: 0)
        scheduler.postpone(now: 1_000, by: 30)
        #expect(scheduler.nextInteraction(now: 1_010, day: 1, context: context()) == nil)
        #expect(scheduler.nextSolo(now: 1_010, context: context()) == nil)
    }
}
