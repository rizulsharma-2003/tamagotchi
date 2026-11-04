import Foundation
import Testing
@testable import TamagotchiCore
import TamagotchiWire

@Suite("Speech lines and pacing")
struct SpeechTests {
    @Test func everyOccasionHasShortLines() {
        for occasion in SpeechOccasion.allCases {
            let lines = SpeechLines.lines(for: occasion)
            #expect(!lines.isEmpty, "\(occasion)")
            for line in lines { #expect(line.text.count <= 36, "\(line.text)") }
            #expect(!occasion.situation.isEmpty)
        }
    }

    @Test func realEventsMapToOccasions() {
        #expect(SpeechOccasion.forEvent(TestSupport.event("Stop")) == .turnCompleted)
        #expect(SpeechOccasion.forEvent(TestSupport.event("SessionStart")) == .sessionStarted)
        #expect(SpeechOccasion.forEvent(TestSupport.event("PermissionRequest", tool: "Bash")) == .permission)
        #expect(SpeechOccasion.forEvent(TestSupport.event("PreToolUse", tool: "Read")) == nil)
        let wire = TestSupport.wire("Report", origin: .report) { $0.report = WireReport(kind: "test", status: "passed", label: nil) }
        let passed = EventNormalizer.normalize(wire, receivedAt: Date(), delivery: .live)
        #expect(SpeechOccasion.forEvent(passed) == .testsPassed)
    }

    @Test func picksAvoidRecentLinesAndAreDeterministic() {
        let all = SpeechLines.lines(for: .treat).map(\.text)
        let recent = Array(all.dropLast())
        #expect(SpeechLines.pick(.treat, seed: 3, avoiding: recent)?.text == all.last)
        #expect(SpeechLines.pick(.idle, seed: 11) == SpeechLines.pick(.idle, seed: 11))
        #expect(SpeechLines.pick(.treat, seed: 5, avoiding: all) != nil)
    }

    @Test func pacingFollowsChattiness() {
        let quiet = SpeechPacing(chattiness: .quiet)
        #expect(quiet.allows(.turnCompleted, since: 30))
        #expect(!quiet.allows(.petted, since: 1_000))
        #expect(quiet.idleInterval == nil)
        let normal = SpeechPacing(chattiness: .normal)
        #expect(normal.allows(.waitingForUser, since: 9))
        #expect(!normal.allows(.petted, since: 10))
        #expect(normal.allows(.petted, since: 31))
        #expect(!normal.allows(.idle, since: 60))
        let chatty = SpeechPacing(chattiness: .chatty)
        #expect(chatty.allows(.idle, since: 13))
        #expect(chatty.idleInterval! < normal.idleInterval!)
    }

    @Test func generatedLinesAreCleanedOrRejected() {
        #expect(SpeechLines.sanitize("\"Yay, snack time!\"\nMore text") == "Yay, snack time!")
        #expect(SpeechLines.sanitize("I'm sorry, I can't help with that.") == nil)
        #expect(SpeechLines.sanitize("   ") == nil)
        let long = SpeechLines.sanitize("This is a rather long line that keeps going and going well past the limit")
        #expect(long != nil && long!.count <= 45 && long!.hasSuffix("…"))
    }

    @MainActor
    @Test func sayRespectsTheSwitchAndExpires() {
        var settings = AppSettings()
        settings.speech.enabled = false
        let off = WorldHarness(settings: settings)
        off.world.say("Hello")
        #expect(off.world.speech == nil)

        let harness = WorldHarness()
        harness.world.say("  Hello!  ", speaker: .companion, duration: 2)
        #expect(harness.world.activeSpeech?.text == "Hello!")
        #expect(harness.world.activeSpeech?.speaker == .companion)
        harness.clock.advance(2.5)
        #expect(harness.world.activeSpeech == nil)
        let id = harness.world.speech!.id
        harness.world.clearSpeech(id: id + 1)
        #expect(harness.world.speech != nil)
        harness.world.clearSpeech(id: id)
        #expect(harness.world.speech == nil)
    }

    @MainActor
    @Test func reactionsReachTheEffectsForSpeech() {
        final class Listener: WorldEffects {
            var events: [EventKind] = []
            var interactions: [PetInteraction] = []
            func play(_ sound: SoundCue) {}
            func postBanner(_ content: BannerContent, category: NotificationCategory, sessionID: String?) {}
            func worldDidReact(to event: CompanionEvent, session: SessionSnapshot?) { events.append(event.kind) }
            func userDidInteract(_ kind: PetInteraction) { interactions.append(kind) }
        }
        let harness = WorldHarness()
        let listener = Listener()
        harness.world.effects = listener
        harness.send("SessionStart")
        harness.send("Stop")
        harness.world.interact(.treat)
        #expect(listener.events.contains(.sessionStarted))
        #expect(listener.events.contains(.turnCompleted))
        #expect(listener.interactions == [.treat])
    }
}

@Suite("Life stages")
struct LifeStageTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func progress(points: Int, days: Int, metWeeksAgo weeks: Double?) -> ProgressState {
        var state = ProgressState()
        state.affectionPoints = points
        state.interactionDays = (0..<days).map { "2027-01-\(String(format: "%02d", $0 + 1))" }
        state.firstMetAt = weeks.map { now.addingTimeInterval(-$0 * 7 * 86_400) }
        return state
    }

    @Test func growsWithFriendshipAndTime() {
        #expect(LifeStage.stage(for: progress(points: 0, days: 0, metWeeksAgo: nil), now: now) == .kitten)
        // Friendship alone isn't enough: it takes time together too.
        #expect(LifeStage.stage(for: progress(points: 40, days: 1, metWeeksAgo: 0.2), now: now) == .kitten)
        #expect(LifeStage.stage(for: progress(points: 40, days: 3, metWeeksAgo: 0.2), now: now) == .young)
        #expect(LifeStage.stage(for: progress(points: 40, days: 1, metWeeksAgo: 1.5), now: now) == .young)
        #expect(LifeStage.stage(for: progress(points: 120, days: 4, metWeeksAgo: 1.5), now: now) == .young)
        #expect(LifeStage.stage(for: progress(points: 120, days: 10, metWeeksAgo: 1.5), now: now) == .grownUp)
        #expect(LifeStage.stage(for: progress(points: 120, days: 2, metWeeksAgo: 3.2), now: now) == .grownUp)
    }

    @Test func neverGoesBackwards() {
        // Points and days only accumulate; walking forward through them never lowers the stage.
        var last = LifeStage.kitten
        var state = progress(points: 0, days: 0, metWeeksAgo: 0)
        for step in 0..<60 {
            state.affectionPoints += 3
            if step % 3 == 0 { state.interactionDays.append("day-\(step)") }
            let stage = LifeStage.stage(for: state, now: now.addingTimeInterval(Double(step) * 86_400))
            #expect(stage >= last)
            last = stage
        }
        #expect(last == .grownUp)
    }

    @Test func explainsTheNextStep() {
        let kitten = progress(points: 5, days: 1, metWeeksAgo: 0.1)
        let hint = LifeStage.nextStep(for: kitten, now: now)
        #expect(hint?.contains("friendship level 2") == true)
        #expect(LifeStage.nextStep(for: progress(points: 200, days: 30, metWeeksAgo: 8), now: now) == nil)
    }
}
