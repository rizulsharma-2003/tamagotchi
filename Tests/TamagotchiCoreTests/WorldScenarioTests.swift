import Foundation
import Testing
@testable import TamagotchiCore
import TamagotchiWire

/// End-to-end scenarios through the whole pipeline (normalize → sessions →
/// journal → progress → mapper → policy → animators), with a controllable clock.
@Suite("World scenarios")
@MainActor
struct WorldScenarioTests {
    @Test func worksWithoutClaudeCode() {
        let h = WorldHarness()
        h.run(for: 120)
        #expect(h.world.sessions.isEmpty)
        #expect(!h.world.companionPresent)
        #expect(h.world.menuBarStatus.companionVisible == false)
        h.world.interact(.pet)
        #expect(h.world.pet.current.animation == .petted)
        #expect(h.world.progress.affectionPoints == 1)
    }

    @Test func sessionStartBringsTheCompanion() {
        let h = WorldHarness()
        h.send("SessionStart") { $0.source = "startup" }
        #expect(h.world.companionPresent)
        #expect(h.world.interaction?.id == .welcome)
        h.run(for: 5)
        #expect(h.world.interaction == nil)
        #expect(h.world.companion.current.animation == .idleAtDesk)
    }

    @Test func toolSuccessDoesNotCompleteTheTurn() {
        let h = WorldHarness()
        h.send("SessionStart")
        h.run(for: 5)
        h.send("UserPromptSubmit")
        h.send("PreToolUse", tool: "Read", toolUseId: "r1")
        h.run(for: 3)
        #expect(h.world.companion.current.animation == .reading)
        #expect(h.world.pet.base == .watch)
        h.send("PostToolUse", tool: "Read", toolUseId: "r1")
        #expect(h.world.primarySession?.phase == .thinking)
        #expect(h.world.latestResult == nil)
        #expect(h.world.burst == nil)
        h.run(for: 3)
        #expect(h.world.companion.base == .thinking)
    }

    @Test func turnCompletionCelebratesAndCreatesAResultCard() {
        let h = WorldHarness()
        h.send("SessionStart")
        h.run(for: 5)
        h.send("UserPromptSubmit")
        h.send("PreToolUse", tool: "Edit", toolUseId: "e1")
        h.send("PostToolUse", tool: "Edit", toolUseId: "e1")
        h.run(for: 3)
        h.send("Stop")
        #expect(h.world.interaction?.id == .highFive)
        #expect(h.world.burst != nil)
        let card = h.world.latestResult
        #expect(card?.projectName == "InsideEdge")
        #expect(card?.buildTest == nil)
        #expect(card?.statusLine == "Claude finished responding")
        h.run(for: 6)
        #expect(h.world.interaction == nil)
        #expect(h.world.companion.current.animation == .idleAtDesk)
    }

    @Test func toolFailureShowsConcernAndBadge() {
        let h = WorldHarness()
        h.send("SessionStart")
        h.run(for: 5)
        h.send("UserPromptSubmit")
        h.send("PreToolUse", tool: "Bash", toolUseId: "b1")
        h.send("PostToolUseFailure", tool: "Bash", toolUseId: "b1") { $0.exitCode = 1 }
        #expect(h.world.pet.current.animation == .concerned)
        #expect(h.world.companion.current.animation == .concerned)
        #expect(h.world.attention?.kind == .toolError)
        #expect(h.world.primarySession?.phase == .thinking)
        h.send("Stop")
        #expect(h.world.attention == nil)
    }

    @Test func permissionRequestWaitsAttentively() {
        let h = WorldHarness()
        h.send("SessionStart")
        h.run(for: 5)
        h.send("PreToolUse", tool: "Bash", toolUseId: "p1")
        h.send("PermissionRequest", tool: "Bash")
        h.send("Notification") { $0.notificationType = "permission_prompt"; $0.message = "Claude needs your permission to use Bash" }
        #expect(h.world.attention?.kind == .needsYou)
        h.run(for: 3)
        #expect(h.world.companion.current.animation == .waiting)
        #expect(h.world.pet.current.animation == .waveGently)
        #expect(h.world.menuBarStatus.mood == .waiting)
        h.send("PostToolUse", tool: "Bash", toolUseId: "p1", after: 4)
        #expect(h.world.attention == nil)
    }

    @Test func twoSessionsStaySeparate() {
        let h = WorldHarness()
        h.send("SessionStart", session: "a", project: "/p/InsideEdge")
        h.send("SessionStart", session: "b", project: "/p/Deskdrop")
        h.run(for: 5)
        h.send("UserPromptSubmit", session: "a", project: "/p/InsideEdge")
        h.send("PreToolUse", session: "a", project: "/p/InsideEdge", tool: "Edit")
        h.send("PermissionRequest", session: "b", project: "/p/Deskdrop", tool: "Bash")
        #expect(h.world.primarySession?.id == "b")
        h.send("Stop", session: "a", project: "/p/InsideEdge")
        #expect(h.world.sessions.first { $0.id == "a" }?.phase == .turnCompleted)
        #expect(h.world.sessions.first { $0.id == "b" }?.phase == .waitingForUser)
        #expect(h.world.resultCards["a"] != nil)
        #expect(h.world.resultCards["b"] == nil)
        // The waiting session keeps the focus; the completion is captioned with its project.
        #expect(h.world.primarySession?.id == "b")
        #expect(h.world.activeCaption?.text.hasPrefix("InsideEdge") == true)
    }

    @Test func duplicatesAreIgnored() {
        let h = WorldHarness()
        h.send("SessionStart")
        h.run(for: 5)
        let stop = TestSupport.wire("Stop", at: h.clock.date, id: "same-id")
        h.world.ingest(stop)
        h.world.ingest(stop)
        #expect(h.world.diagnostics.duplicatesIgnored == 1)
        #expect(h.world.sessions.first?.turnsCompleted == 1)
    }

    @Test func simulatedEventsStayOutOfHistoryAndProgress() {
        let h = WorldHarness()
        h.world.ingest(TestSupport.wire("SessionStart", session: "sim-x", at: h.clock.date, origin: .simulator))
        h.world.ingest(TestSupport.wire("Stop", session: "sim-x", at: h.clock.date, origin: .simulator))
        #expect(h.journal.all.isEmpty)
        #expect(h.world.progress.unlocked.isEmpty)
        #expect(h.world.sessions.first?.isSimulated == true)
        #expect(h.effects.banners.isEmpty)
        h.world.clearSimulated()
        #expect(h.world.sessions.isEmpty)
    }

    @Test func lateEventsAreHistoryNotReactions() {
        let h = WorldHarness()
        let earlier = h.clock.date.addingTimeInterval(-600)
        h.world.ingest(TestSupport.wire("SessionStart", at: earlier), delivery: .late)
        h.world.ingest(TestSupport.wire("Stop", at: earlier.addingTimeInterval(5)), delivery: .late)
        h.world.noteSpoolDrained(delivered: 2, dropped: 1)
        #expect(h.world.interaction == nil || h.world.interaction?.id == .welcome)
        #expect(h.world.burst == nil)
        #expect(h.world.latestResult == nil)
        #expect(h.journal.all.count == 2)
        #expect(h.world.missed?.delivered == 2)
        #expect(h.world.missed?.dropped == 1)
    }

    @Test func restartRestoresSessionsWithoutReplayingReactions() {
        let first = WorldHarness()
        first.send("SessionStart")
        first.send("UserPromptSubmit")
        first.send("PreToolUse", tool: "Bash")
        let journal = EventJournal(fileURL: first.journal.fileURL, retention: .init(days: 7))
        journal.load(now: first.clock.date)
        let store = SettingsStore(fileURL: nil)
        let clock = first.clock
        let world = CompanionWorld(journal: journal, achievements: AchievementEngine(state: ProgressState()), settingsStore: store, seed: 1,
                                   clock: { clock.date }, uptime: { clock.uptime })
        world.restoreFromJournal()
        #expect(world.sessions.first?.phase == .runningTool)
        #expect(world.burst == nil)
        #expect(world.interaction == nil)
        #expect(world.companionPresent)
        // Events of the ongoing session keep working after the restart, without duplicates.
        world.ingest(TestSupport.wire("Stop", at: clock.date.addingTimeInterval(1)))
        #expect(world.sessions.first?.phase == .turnCompleted)
    }

    @Test func quietHoursSilenceSounds() {
        var settings = AppSettings()
        settings.soundEnabled = true
        settings.quietMode = true
        let h = WorldHarness(settings: settings)
        h.send("SessionStart")
        h.run(for: 5)
        h.send("Stop")
        #expect(h.effects.sounds.isEmpty)
        #expect(h.world.burst != nil)
    }

    @Test func soundsPlayWhenEnabledAndNotQuiet() {
        var settings = AppSettings()
        settings.soundEnabled = true
        let h = WorldHarness(settings: settings)
        h.send("SessionStart")
        h.run(for: 5)
        h.send("Stop")
        #expect(h.effects.sounds.contains(.success))
    }

    @Test func pausedReactionsStillTrackState() {
        var settings = AppSettings()
        settings.pauseReactions = true
        let h = WorldHarness(settings: settings)
        h.send("SessionStart")
        h.send("UserPromptSubmit")
        h.send("Stop")
        #expect(h.world.sessions.first?.phase == .turnCompleted)
        #expect(h.world.interaction == nil)
        #expect(h.world.menuBarStatus.mood == .paused)
    }

    @Test func reducedMotionKeepsCharactersInPlace() {
        var settings = AppSettings()
        settings.reducedMotion = .always
        let h = WorldHarness(settings: settings)
        h.send("SessionStart")
        h.run(for: 5)
        h.send("Stop")
        guard let playback = h.world.interaction else { Issue.record("expected a celebration"); return }
        let context = PoseContext(time: h.clock.uptime, reducedMotion: h.world.reducedMotion)
        for step in stride(from: 0.0, to: playback.duration, by: 0.1) {
            let frame = InteractionLibrary.frame(playback, elapsed: step, petContext: context, companionContext: context)
            #expect(abs(frame.pet.x) < 0.001 && abs(frame.pet.y) < 0.001)
            #expect(abs(frame.companion.rotation) < 0.001)
        }
    }

    @Test func companionLeavesAfterTheLastSessionEnds() {
        var settings = AppSettings()
        settings.companionLingerMinutes = 1
        let h = WorldHarness(settings: settings)
        h.send("SessionStart")
        h.run(for: 5)
        h.send("SessionEnd") { $0.reason = "prompt_input_exit" }
        h.run(for: 30)
        #expect(h.world.companionPresent)
        h.run(for: 45)
        #expect(!h.world.companionPresent)
        #expect(h.world.companion.current.animation == .absent)
    }

    @Test func connectionLossShowsOfflineAndRecovers() {
        let h = WorldHarness()
        h.send("SessionStart")
        h.run(for: 5)
        h.world.updateBridge(listening: false, error: "bind() failed", accepted: 0, rejected: 0, lastRejection: nil, refusedPeers: 0)
        h.run(for: 1)
        #expect(h.world.companion.current.animation == .offline)
        #expect(h.world.menuBarStatus.mood == .offline)
        #expect(h.world.connection.level == .problem)
        h.world.updateBridge(listening: true, error: nil, accepted: 0, rejected: 0, lastRejection: nil, refusedPeers: 0)
        h.run(for: 1)
        #expect(h.world.companion.base != .offline)
    }

    @Test func petNapsAfterInactivityAndWakesForEvents() {
        let h = WorldHarness()
        h.run(for: 9 * 60, step: 2)
        #expect(h.world.petAsleep)
        h.send("SessionStart")
        #expect(!h.world.petAsleep)
    }

    @Test func petKeepsTheMacsRhythm() {
        let h = WorldHarness()
        // However long you work, no nap.
        h.world.updateSystem(SystemActivity(idleSeconds: 2))
        h.run(for: 12 * 60, step: 2)
        #expect(!h.world.petAsleep)
        // You step away: once the Mac rests, Mochi sleeps.
        h.world.updateSystem(SystemActivity(idleSeconds: 6 * 60))
        #expect(h.world.macResting)
        h.run(for: 60, step: 0.5)
        #expect(h.world.petAsleep)
        // Back at the keyboard: awake with a stretch.
        h.world.updateSystem(SystemActivity(idleSeconds: 1))
        h.run(for: 1)
        #expect(!h.world.petAsleep)
        #expect(h.world.pet.current.animation == .wakeUp)
        // Claude at work keeps Mochi up while the Mac rests.
        h.send("SessionStart")
        h.send("UserPromptSubmit")
        h.world.updateSystem(SystemActivity(idleSeconds: 3600))
        h.run(for: 90, step: 0.5)
        #expect(!h.world.petAsleep)
    }

    @Test func restingFollowsDisplaysVideosAndLoad() {
        let rest: TimeInterval = 300
        #expect(SystemActivity(idleSeconds: 0, displaysAsleep: true).isResting(after: rest))
        #expect(SystemActivity(idleSeconds: 301).isResting(after: rest))
        #expect(!SystemActivity(idleSeconds: 299).isResting(after: rest))
        #expect(!SystemActivity(idleSeconds: 3600, keepsDisplayAwake: true).isResting(after: rest))
        #expect(!SystemActivity(idleSeconds: 3600, cpuLoad: 0.85).isResting(after: rest))
        #expect(SystemActivity(idleSeconds: 3600, cpuLoad: 0.1).isResting(after: rest))
        #expect(SystemActivity(idleSeconds: 3).userActive && !SystemActivity(idleSeconds: 3, displaysAsleep: true).userActive)
    }

    @Test func ambientInteractionsHappenButNotWhileWaiting() {
        let h = WorldHarness()
        h.send("SessionStart")
        h.send("PermissionRequest", tool: "Bash")
        var sawInteraction = false
        for _ in 0..<(20 * 60 / 2) {
            h.clock.advance(2)
            h.world.tick()
            if let id = h.world.interaction?.id, id != .welcome { sawInteraction = true }
        }
        #expect(!sawInteraction)
        h.send("PostToolUse", tool: "Bash")
        h.send("Stop")
        var ambient: Set<InteractionID> = []
        for _ in 0..<(60 * 60 / 2) {
            h.clock.advance(2)
            h.world.tick()
            if let id = h.world.interaction?.id { ambient.insert(id) }
        }
        #expect(!ambient.subtracting([.highFive, .welcome]).isEmpty)
    }

    @Test func manualMilestoneUnlocksGraduation() {
        let h = WorldHarness()
        h.send("SessionStart")
        h.run(for: 5)
        h.world.markMilestone(label: "Shipped v1")
        #expect(h.world.interaction?.id == .graduation)
        #expect(h.world.progress.unlockedIDs.contains(.firstMilestone))
        #expect(h.journal.all.contains { $0.report?.kind == .milestone })
    }

    @Test func explicitReportWithoutSessionStillCelebrates() {
        let h = WorldHarness()
        var report = TestSupport.wire("Report", session: nil, at: h.clock.date, origin: .report)
        report.report = WireReport(kind: "test", status: "passed", label: "CI")
        h.world.ingest(report)
        #expect(h.world.timeline.last?.kind == .report)
        #expect(h.world.pet.current.animation == .excitedJump)
    }
}
