import Foundation
@testable import TamagotchiCore
import TamagotchiWire

/// Whole-world fixtures: CompanionWorld runs scripted timelines (ticks, Claude's events, petting, play and treats,
/// settings changes) with a fixed seed and clock, and its state is recorded at every snapshot.
@MainActor
enum WorldTimelineFixtures {
    final class Recorder: WorldEffects {
        var sounds: [String] = []
        var banners: [String] = []
        var reacted: [String] = []
        var interactions: [String] = []
        func play(_ sound: SoundCue) { sounds.append(sound.rawValue) }
        func postBanner(_ content: BannerContent, category: NotificationCategory, sessionID: String?) {
            banners.append("\(category.rawValue): \(content.title) | \(content.body)")
        }
        func worldDidReact(to event: CompanionEvent, session: SessionSnapshot?) { reacted.append(event.id) }
        func userDidInteract(_ kind: PetInteraction) { interactions.append(kind.rawValue) }
    }

    /// One step of a timeline (also written to the fixture, which the Dart test replays).
    enum Step {
        /// Advance the clock by `step` and tick, until `seconds` have passed.
        case run(Double, step: Double = 0.25)
        /// Advance the clock by `after`, ingest the event, then tick.
        case wire(WireEvent, delivery: EventDelivery = .live, after: Double = 0.5)
        case interact(PetInteraction)
        case poke
        case system(idleSeconds: Double)
        case window(Bool)
        case start(InteractionID, variant: Int, priority: AnimationPriority)
        case settings((inout AppSettings) -> Void, json: String)
        case say(String)
        case snapshot
    }

    static func stepJSON(_ step: Step) -> String {
        var o = FixtureObject()
        switch step {
        case .run(let seconds, let every):
            o.str("op", "run")
            o.exact("seconds", seconds)
            o.exact("step", every)
        case .wire(let wire, let delivery, let after):
            o.str("op", "wire")
            o.raw("wire", LogicFixtures.wireJSON(wire))
            o.str("delivery", delivery.rawValue, default: "live")
            o.exact("after", after)
        case .interact(let kind):
            o.str("op", "interact")
            o.str("kind", kind.rawValue)
        case .poke:
            o.str("op", "poke")
        case .system(let idle):
            o.str("op", "system")
            o.exact("idleSeconds", idle)
        case .window(let visible):
            o.str("op", "window")
            o.bool("visible", visible)
        case .start(let id, let variant, let priority):
            o.str("op", "start")
            o.str("interaction", id.rawValue)
            o.int("variant", variant)
            o.str("priority", "\(priority)")
        case .settings(_, let json):
            o.str("op", "settings")
            o.raw("settings", json)
        case .say(let text):
            o.str("op", "say")
            o.str("text", text)
        case .snapshot:
            o.str("op", "snapshot")
        }
        return o.json
    }

    static func playing<A: CharacterAnimationKind & RawRepresentable>(_ p: CharacterAnimator<A>.Playing, base: Double) -> FixtureObject
    where A.RawValue == String {
        var o = FixtureObject()
        o.str("animation", p.animation.rawValue)
        o.str("priority", "\(p.priority)")
        o.exact("startedAt", p.startedAt - base)
        o.optionalExact("duration", p.duration)
        o.int("token", p.token)
        o.str("scriptID", p.scriptID)
        return o
    }

    static func snapshot(_ world: CompanionWorld, clock: TestClock, recorder: Recorder, base: Double) -> String {
        var o = FixtureObject()
        o.exact("t", clock.uptime - base)
        o.object("pet", playing(world.pet.current, base: base))
        o.str("petBase", world.pet.base.rawValue)
        o.object("companion", playing(world.companion.current, base: base))
        o.str("companionBase", world.companion.base.rawValue)
        o.bool("companionPresent", world.companionPresent)
        o.bool("petAsleep", world.petAsleep)
        if let playback = world.interaction {
            var i = FixtureObject()
            i.str("id", playback.id.rawValue)
            i.int("variant", playback.variant)
            i.exact("startedAt", playback.startedAt - base)
            i.str("companionLoop", playback.companionLoop.rawValue)
            i.str("sessionLabel", playback.sessionLabel)
            o.object("interaction", i)
        }
        if let primary = world.primarySession {
            var p = FixtureObject()
            p.str("id", primary.id)
            p.str("phase", primary.phase.rawValue)
            o.object("primary", p)
        }
        o.str("mood", world.menuBarStatus.mood.rawValue)
        if let attention = world.attention {
            o.str("attention", "\(attention.kind.rawValue) \(attention.level)")
        }
        o.str("caption", world.activeCaption?.text)
        if let burst = world.burst { o.str("burst", burst.big ? "big" : "small") }
        o.str("toast", world.activeToast.map { "\($0.title) | \($0.detail)" })
        o.str("speech", world.activeSpeech?.text)
        o.int("resultCards", world.resultCards.count, default: 0)
        var progress = FixtureObject()
        progress.int("points", world.progress.affectionPoints)
        progress.int("level", world.progress.friendshipLevel)
        progress.list("unlocked", AchievementID.allCases.filter { world.progress.unlocked[$0.rawValue] != nil }.map { FixtureJSON.str($0.rawValue) },
                      omitEmpty: false)
        o.object("progress", progress)
        o.list("sounds", recorder.sounds.map(FixtureJSON.str))
        o.list("banners", recorder.banners.map(FixtureJSON.str))
        o.list("reacted", recorder.reacted.map(FixtureJSON.str))
        o.list("interacted", recorder.interactions.map(FixtureJSON.str))
        recorder.sounds = []
        recorder.banners = []
        recorder.reacted = []
        recorder.interactions = []
        // The frame the Mac's scene would draw now (SceneRenderer.poses).
        let time = clock.uptime
        let frame = scene(world, time: time)
        var f = FixtureObject()
        f.raw("pet", PoseJSON.pet(frame.0))
        f.raw("companion", PoseJSON.companion(frame.1))
        f.list("props", frame.2.map(PoseJSON.prop))
        f.bool("companionVisible", world.companionPresent && world.companion.current.animation != .absent)
        o.object("frame", f)
        return o.json
    }

    /// SceneRenderer.poses (Sources/App/Rendering/SceneRenderer.swift), which the app target holds.
    static func scene(_ world: CompanionWorld, time: Double) -> (PetPose, CompanionPose, [SceneProp]) {
        let petContext = PoseContext(time: time, reducedMotion: world.reducedMotion, intensity: world.settings.animationIntensity, seed: world.seed)
        let companionContext = PoseContext(time: time, reducedMotion: world.reducedMotion, intensity: world.settings.animationIntensity,
                                           seed: world.seed &+ 0x5EED)
        let pet = world.pet.current
        let companion = world.companion.current
        let detail = world.companionDetail
        func singlePet() -> PetPose {
            var context = petContext
            context.returnLoop = world.pet.base
            return PetPoseEvaluator.pose(pet.animation == .scripted ? .idle : pet.animation, elapsed: pet.elapsed(at: time), duration: pet.duration,
                                         context: context)
        }
        func singleCompanion() -> CompanionPose {
            CompanionPoseEvaluator.pose(companion.animation == .scripted ? .idleAtDesk : companion.animation, elapsed: companion.elapsed(at: time),
                                        duration: companion.duration, context: companionContext, detail: detail)
        }
        if let playback = world.interaction, pet.scriptID == playback.id.rawValue || companion.scriptID == playback.id.rawValue {
            let frame = InteractionLibrary.frame(playback, elapsed: time - playback.startedAt, petContext: petContext,
                                                 companionContext: companionContext, detail: detail)
            return (pet.scriptID != playback.id.rawValue ? singlePet() : frame.pet,
                    companion.scriptID != playback.id.rawValue ? singleCompanion() : frame.companion, frame.props)
        }
        return (singlePet(), singleCompanion(), [])
    }

    static func run(name: String, seed: UInt64, settings configure: (inout AppSettings) -> Void, settingsJSON: String, steps: [Step]) -> String {
        var settings = AppSettings()
        configure(&settings)
        let directory = TestSupport.temporaryDirectory("world-fixture-\(seed)")
        let journal = EventJournal(fileURL: directory.appendingPathComponent("history.jsonl"), retention: .init(days: 7))
        let clock = TestClock(date: LogicFixtures.start, uptime: 1_000)
        let base = clock.uptime
        let world = CompanionWorld(journal: journal, achievements: AchievementEngine(state: ProgressState(), calendar: WorldFixtures.utc),
                                   settingsStore: SettingsStore(fileURL: nil, initial: settings), seed: seed,
                                   clock: { clock.date }, uptime: { clock.uptime })
        let recorder = Recorder()
        world.effects = recorder
        var snapshots: [String] = []
        for step in steps {
            switch step {
            case .run(let seconds, let every):
                var elapsed = 0.0
                while elapsed < seconds {
                    clock.advance(every)
                    world.tick()
                    elapsed += every
                }
            case .wire(let wire, let delivery, let after):
                clock.advance(after)
                world.ingest(wire, delivery: delivery)
                world.tick()
            case .interact(let kind): world.interact(kind)
            case .poke: world.pokeCompanion()
            case .system(let idle): world.updateSystem(SystemActivity(idleSeconds: idle))
            case .window(let visible): world.setPopoverVisible(visible)
            case .start(let id, let variant, let priority): world.startInteraction(id, priority: priority, variant: variant)
            case .settings(let change, _):
                var s = world.settings
                change(&s)
                world.settings = s
            case .say(let text): world.say(text)
            case .snapshot: snapshots.append(snapshot(world, clock: clock, recorder: recorder, base: base))
            }
        }
        var o = FixtureObject()
        o.str("name", name)
        o.raw("seed", FixtureJSON.str(String(seed)))
        o.raw("settings", settingsJSON)
        o.exact("date", LogicFixtures.start.timeIntervalSince1970)
        o.exact("uptime", base)
        o.list("steps", steps.map(stepJSON), omitEmpty: false, multiline: true)
        o.list("snapshots", snapshots, omitEmpty: false, multiline: true)
        return o.json
    }

    static func world() -> String {
        typealias W = LogicFixtures
        func at(_ seconds: Double) -> Date { LogicFixtures.start.addingTimeInterval(seconds) }
        var cases: [String] = []

        // 1. A session from start to finish, then a long idle where the scheduler picks ambient moments.
        do {
            var steps: [Step] = [.run(20), .snapshot, .run(40, step: 0.5), .snapshot]
            steps += [.wire(W.wire("w1", "SessionStart", at: at(61)), after: 1), .snapshot, .run(2), .snapshot, .run(3), .snapshot]
            steps += [.wire(W.wire("w2", "UserPromptSubmit", at: at(67)), after: 1), .snapshot]
            steps += [.wire(W.wire("w3", "PreToolUse", at: at(68), tool: "Edit", toolUse: "e1"), after: 1), .snapshot, .run(1.5), .snapshot]
            steps += [.wire(W.wire("w4", "PostToolUse", at: at(70), tool: "Edit", toolUse: "e1"), after: 1), .snapshot]
            steps += [.wire(W.wire("w5", "PreToolUse", at: at(71), tool: "Bash", toolUse: "b1") { $0.commandKind = "test" }, after: 1), .snapshot]
            steps += [.wire(W.wire("w6", "PostToolUse", at: at(80), tool: "Bash", toolUse: "b1") { $0.commandKind = "test"; $0.commandReliable = true },
                            after: 9), .snapshot]
            steps += [.wire(W.wire("w7", "Stop", at: at(82)), after: 2), .snapshot, .run(1), .snapshot, .run(2), .snapshot, .run(4), .snapshot]
            for _ in 0..<40 { steps += [.run(15), .snapshot] }
            cases.append(run(name: "a session, then an idle afternoon", seed: 42, settings: { $0.soundEnabled = true },
                             settingsJSON: #"{"soundEnabled":true}"#, steps: steps))
        }

        // 2. Friendship: petting, play and treats with Patch always there; a nap after a quiet while; poking Patch.
        do {
            var steps: [Step] = [.run(1), .snapshot, .interact(.pet), .snapshot, .run(1), .snapshot, .run(3), .snapshot]
            for _ in 0..<6 { steps += [.interact(.pet), .run(0.5), .snapshot] }
            steps += [.interact(.play), .snapshot, .run(2), .snapshot, .run(4), .snapshot]
            steps += [.interact(.treat), .run(1.3), .snapshot, .run(3.5), .snapshot]
            for _ in 0..<4 { steps += [.interact(.play), .run(5.5), .snapshot] }
            steps += [.poke, .snapshot, .run(2), .snapshot, .window(true), .say("Hello there"), .snapshot, .window(false)]
            for _ in 0..<24 { steps += [.run(25), .snapshot] }
            steps += [.interact(.pet), .snapshot, .run(1.5), .snapshot]
            cases.append(run(name: "petting, play and treats, then a nap", seed: 7, settings: { $0.companionVisibility = .always; $0.followSystem = false },
                             settingsJSON: #"{"companionVisibility":"always","followSystem":false}"#, steps: steps))
        }

        // 3. The computer's rhythm: Mochi sleeps while it rests and wakes when you're back.
        do {
            var steps: [Step] = [.system(idleSeconds: 0), .run(10), .snapshot, .system(idleSeconds: 400), .run(30), .snapshot, .run(40), .snapshot]
            steps += [.run(5), .snapshot, .system(idleSeconds: 2), .run(0.5), .snapshot, .run(2), .snapshot]
            steps += [.wire(W.wire("r1", "SessionStart", at: at(90))), .snapshot, .system(idleSeconds: 900), .run(70), .snapshot]
            steps += [.wire(W.wire("r2", "UserPromptSubmit", at: at(161)), after: 0.5), .snapshot, .run(5), .snapshot]
            cases.append(run(name: "following the computer's rhythm", seed: 0xDEAD_BEEF_CAFE_F00D, settings: { _ in }, settingsJSON: "{}", steps: steps))
        }

        // 4. Detective mode, case closed, a long turn's victory dance, a milestone's graduation, pausing.
        do {
            var steps: [Step] = [.wire(W.wire("d1", "SessionStart", at: at(1)), after: 1), .run(4), .snapshot]
            steps += [.wire(W.wire("d2", "UserPromptSubmit", at: at(6)), after: 1), .snapshot]
            for index in 0..<3 {
                steps += [.wire(W.wire("d3-\(index)", "PostToolUseFailure", at: at(10 + Double(index) * 5), tool: "Bash", toolUse: "x\(index)") {
                    $0.exitCode = 1
                }, after: 5), .snapshot, .run(1), .snapshot]
            }
            steps += [.run(3), .snapshot, .wire(W.wire("d4", "Stop", at: at(30)), after: 2), .snapshot, .run(2.5), .snapshot, .run(3), .snapshot]
            steps += [.wire(W.wire("d5", "UserPromptSubmit", at: at(40)), after: 4), .snapshot, .run(3), .snapshot]
            steps += [.run(600, step: 1), .snapshot]
            steps += [.wire(W.wire("d6", "Stop", at: at(40 + 11 * 60)), after: 0.5), .snapshot, .run(2), .snapshot, .run(4), .snapshot]
            steps += [.wire(W.wire("d7", "Report", at: at(760), session: nil, origin: .report) {
                $0.report = WireReport(kind: "milestone", status: "reached", label: "v1")
            }, after: 1), .snapshot, .run(3), .snapshot, .run(4), .snapshot]
            steps += [.wire(W.wire("d8", "PermissionRequest", at: at(775), tool: "Bash"), after: 1), .snapshot]
            steps += [.wire(W.wire("d9", "Notification", at: at(775.2)) { $0.notificationType = "permission_prompt" }, after: 0.2), .snapshot]
            steps += [.settings({ $0.pauseReactions = true }, json: #"{"pauseReactions":true}"#), .snapshot, .run(3), .snapshot]
            steps += [.settings({ $0.pauseReactions = false }, json: #"{"pauseReactions":false}"#), .run(1), .snapshot]
            steps += [.wire(W.wire("d10", "SessionEnd", at: at(790)) { $0.reason = "prompt_input_exit" }, after: 1), .snapshot, .run(2), .snapshot]
            for _ in 0..<14 { steps += [.run(60, step: 0.5), .snapshot] }
            cases.append(run(name: "detective, case closed, a long turn and a milestone", seed: 1234, settings: { $0.soundEnabled = true },
                             settingsJSON: #"{"soundEnabled":true}"#, steps: steps))
        }

        // 5. A phone mirroring the computer (simulated events) and spooled (late) events: animation without progress, history without news.
        do {
            var steps: [Step] = [.wire(W.wire("s1", "SessionStart", at: at(1), session: "mirror", origin: .simulator)), .run(4), .snapshot]
            steps += [.wire(W.wire("s2", "UserPromptSubmit", at: at(6), session: "mirror", origin: .simulator)), .snapshot]
            steps += [.wire(W.wire("s3", "Stop", at: at(10), session: "mirror", origin: .simulator), after: 4), .snapshot, .run(2), .snapshot]
            steps += [.run(6), .snapshot]
            steps += [.wire(W.wire("l1", "SessionStart", at: at(-600), session: "old"), delivery: .late), .snapshot]
            steps += [.wire(W.wire("l2", "UserPromptSubmit", at: at(-590), session: "old"), delivery: .late), .snapshot]
            steps += [.wire(W.wire("l3", "Stop", at: at(-500), session: "old"), delivery: .late), .snapshot, .run(5), .snapshot]
            steps += [.wire(W.wire("l3", "Stop", at: at(-500), session: "old"), delivery: .live), .snapshot]
            cases.append(run(name: "simulated and late events", seed: 99, settings: { $0.reducedMotion = .always; $0.soundEnabled = true },
                             settingsJSON: #"{"reducedMotion":"always","soundEnabled":true}"#, steps: steps))
        }

        var root = FixtureObject()
        root.str("about", "Whole CompanionWorld timelines (mochi_world's MochiWorld must match), without a menu-bar roam zone, with a UTC "
                 + "achievement calendar, the clock at date/uptime and the given seed and settings (AppSettings keys). Steps: run (advance "
                 + "the clock by step and tick until seconds have passed), wire (advance by after, ingest with the delivery, tick), interact, "
                 + "poke (pokeCompanion), system (updateSystem with that idle time), window (the popover), start (startInteraction), "
                 + "settings, say, snapshot. Times in snapshots are uptime minus the starting uptime; sounds, banners, reacted and interacted "
                 + "are what the world's effects received since the previous snapshot; frame is SceneRenderer.poses at that moment.")
        root.list("cases", cases, omitEmpty: false, multiline: true)
        return root.json
    }
}
