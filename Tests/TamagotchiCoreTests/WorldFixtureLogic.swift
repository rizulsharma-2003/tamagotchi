import Foundation
@testable import TamagotchiCore
import TamagotchiWire

/// Logic fixtures: the interaction scheduler, friendship/achievements/growing up, the celebration rules for real
/// Claude events (Sprint 2 G2) and whole CompanionWorld timelines.
@MainActor
enum LogicFixtures {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Wire events

    static func wire(_ id: String, _ event: String, at date: Date, session: String? = "s1", project: String = "InsideEdge",
                     key: String = "key-insideedge", origin: WireOrigin = .hook, tool: String? = nil, toolUse: String? = nil,
                     configure: (inout WireEvent) -> Void = { _ in }) -> WireEvent {
        var wire = WireEvent(id: id, ts: date.timeIntervalSince1970, origin: origin, event: event, session: session)
        wire.project = project
        wire.projectKey = key
        if let tool {
            wire.tool = tool
            wire.toolCategory = ToolCategoryClassifier.category(forTool: tool)
            wire.toolUseId = toolUse ?? "tu-\(id)"
        }
        configure(&wire)
        return wire
    }

    static func wireJSON(_ wire: WireEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(data: try! encoder.encode(wire), encoding: .utf8)!
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - Scheduler

    struct Segment {
        var from: Int
        var activity: AmbientActivity = .idle
        var companionPresent = true
        var busy = false
        var paused = false
        var reducedMotion = false
        var intensity: AnimationIntensity = .normal
        var petAsleep = false
        /// Seconds of idleness already behind at the segment's start.
        var idleOffset = 0.0
        var postpone: Double?
        var noteTriggered: InteractionID?
    }

    static func scheduler() -> String {
        var cases: [String] = []
        func run(seed: UInt64, step: Double, count: Int, dayEvery: Double, segments: [Segment], note: String) {
            let start = 500.0
            var scheduler = InteractionScheduler(seed: seed, now: start)
            var events: [String] = []
            var checkpoints: [String] = []
            for index in 0..<count {
                let now = start + Double(index) * step
                let day = 20_000 + Int(Double(index) * step / dayEvery)
                let segment = segments.last { $0.from <= index }!
                if segment.from == index {
                    if let by = segment.postpone { scheduler.postpone(now: now, by: by) }
                    if let id = segment.noteTriggered { scheduler.noteTriggered(id, now: now) }
                }
                let idle = now - (start + Double(segment.from) * step) + segment.idleOffset
                let context = SchedulerContext(companionPresent: segment.companionPresent, activity: segment.activity, idleSeconds: idle,
                                               charactersBusy: segment.busy, paused: segment.paused, reducedMotion: segment.reducedMotion,
                                               intensity: segment.intensity, petAsleep: segment.petAsleep)
                if let (id, variant) = scheduler.nextInteraction(now: now, day: day, context: context) {
                    events.append("[\(index),\"interaction\",\"\(id.rawValue)\",\(variant)]")
                } else if let solo = scheduler.nextSolo(now: now, context: context) {
                    events.append("[\(index),\"solo\",\"\(solo.rawValue)\"]")
                }
                if index % 200 == 199 || index == count - 1 {
                    var c = FixtureObject()
                    c.int("after", index)
                    c.raw("rng", FixtureJSON.str(String(scheduler.rng.state)))
                    c.exact("nextInteractionAt", scheduler.nextInteractionAt)
                    c.exact("nextSoloAt", scheduler.nextSoloAt)
                    c.list("recent", scheduler.recent.map { FixtureJSON.str($0.rawValue) }, omitEmpty: false)
                    var counts = FixtureObject()
                    for id in InteractionID.allCases { if let n = scheduler.dailyCounts[id] { counts.int(id.rawValue, n) } }
                    c.object("dailyCounts", counts)
                    checkpoints.append(c.json)
                }
            }
            var o = FixtureObject()
            o.str("note", note)
            o.raw("seed", FixtureJSON.str(String(seed)))
            o.exact("start", start)
            o.exact("step", step)
            o.int("count", count)
            o.exact("dayEvery", dayEvery)
            o.list("segments", segments.map { s in
                var j = FixtureObject()
                j.int("from", s.from)
                j.str("activity", s.activity.rawValue, default: "idle")
                j.bool("companionPresent", s.companionPresent, default: true)
                j.bool("busy", s.busy, default: false)
                j.bool("paused", s.paused, default: false)
                j.bool("reducedMotion", s.reducedMotion, default: false)
                j.str("intensity", s.intensity.rawValue, default: "normal")
                j.bool("petAsleep", s.petAsleep, default: false)
                j.num("idleOffset", s.idleOffset, default: 0)
                j.optionalNum("postpone", s.postpone)
                j.str("noteTriggered", s.noteTriggered?.rawValue)
                return j.json
            }, omitEmpty: false)
            o.list("events", events, omitEmpty: false, multiline: true)
            o.list("checkpoints", checkpoints, omitEmpty: false, multiline: true)
            cases.append(o.json)
        }

        // Long idle days: rare picks, cooldowns and daily caps (days are 10 hours here).
        run(seed: 42, step: 15, count: 7200, dayEvery: 36_000, segments: [
            Segment(from: 0, idleOffset: 600),
            Segment(from: 900, activity: .working, idleOffset: 0, postpone: 30),
            Segment(from: 1300, idleOffset: 30),
            Segment(from: 2500, busy: true),
            Segment(from: 2560, idleOffset: 300),
            Segment(from: 4000, activity: .waiting),
            Segment(from: 4100, companionPresent: false, idleOffset: 100),
            Segment(from: 4400, idleOffset: 400, noteTriggered: .highFive),
            Segment(from: 6000, petAsleep: true),
            Segment(from: 6100, idleOffset: 900),
        ], note: "idle days with work, busy, waiting, absent and asleep stretches")
        run(seed: 0xDEAD_BEEF_CAFE_F00D, step: 9, count: 4000, dayEvery: 20_000, segments: [
            Segment(from: 0, intensity: .lively, idleOffset: 200),
            Segment(from: 1500, reducedMotion: true, idleOffset: 250),
            Segment(from: 2500, intensity: .calm, idleOffset: 0, postpone: 40),
            Segment(from: 3200, paused: true),
            Segment(from: 3300, idleOffset: 1000),
        ], note: "a seed above 2^63, lively, Reduced Motion, calm and paused")
        run(seed: 9, step: 4, count: 3000, dayEvery: 3_000, segments: [
            Segment(from: 0, activity: .working),
            Segment(from: 500, idleOffset: 5000),
            Segment(from: 2000, activity: .working, noteTriggered: .trophyCelebration),
        ], note: "short days (daily counts reset often) and working")

        var root = FixtureObject()
        root.str("about", "TamagotchiCore's InteractionScheduler driven directly (mochi_world's must match). For step i of count: now = start + "
                 + "i·step, day = 20000 + floor(i·step / dayEvery); the segment is the last with from ≤ i; at a segment's first step apply "
                 + "postpone(now, by) then noteTriggered(id, now); idleSeconds = now − (start + from·step) + idleOffset. Each step asks "
                 + "nextInteraction(now, day, context) and, only when that gives nothing, nextSolo(now, context), as CompanionWorld does. "
                 + "events lists every non-empty answer [step, kind, value, variant]; checkpoints the scheduler state after a step.")
        root.list("cases", cases, omitEmpty: false, multiline: true)
        return root.json
    }

    // MARK: - Progress (friendship, achievements, growing up)

    static func progress() -> String {
        let engine = AchievementEngine(state: ProgressState(), calendar: WorldFixtures.utc)
        var registry = SessionRegistry()
        var steps: [String] = []
        var n = 0
        func summary(_ date: Date) -> FixtureObject {
            let state = engine.state
            var s = FixtureObject()
            s.int("affectionPoints", state.affectionPoints)
            s.int("level", state.friendshipLevel)
            s.optionalInt("pointsToNextLevel", state.pointsToNextLevel)
            s.list("interactionDays", state.interactionDays.map(FixtureJSON.str), omitEmpty: false)
            var daily = FixtureObject()
            for key in state.dailyPoints.keys.sorted() { daily.int(key, state.dailyPoints[key]!) }
            s.object("dailyPoints", daily)
            s.str("dailyPointsDay", state.dailyPointsDay)
            var unlocked = FixtureObject()
            for id in AchievementID.allCases { if let at = state.unlocked[id.rawValue] { unlocked.str(id.rawValue, iso(at)) } }
            s.object("unlocked", unlocked)
            s.list("projectKeys", state.projectKeys.map(FixtureJSON.str), omitEmpty: false)
            s.int("observedSessions", state.observedSessions)
            s.int("observedTurns", state.observedTurns)
            s.int("milestones", state.milestones)
            s.str("firstMetAt", state.firstMetAt.map(iso))
            s.str("lifeStage", LifeStage.stage(for: state, now: date).title)
            s.str("nextStep", LifeStage.nextStep(for: state, now: date))
            return s
        }
        func interact(_ kind: PetInteraction, day: Int, hour: Double, times: Int = 1) {
            for _ in 0..<times {
                let date = start.addingTimeInterval(Double(day) * 86_400 + hour * 3600 + Double(n))
                n += 1
                let result = engine.recordInteraction(kind, at: date)
                var o = FixtureObject()
                o.str("interact", kind.rawValue)
                o.str("at", iso(date))
                o.int("pointsAwarded", result.pointsAwarded)
                o.bool("levelUp", result.levelUp)
                o.list("unlocked", result.unlocked.map { FixtureJSON.str($0.rawValue) }, omitEmpty: false)
                o.object("state", summary(date))
                steps.append(o.json)
            }
        }
        func event(_ wire: WireEvent, delivery: EventDelivery = .live) {
            let date = Date(timeIntervalSince1970: wire.ts)
            let event = EventNormalizer.normalize(wire, receivedAt: date, delivery: delivery)
            let transition = registry.apply(event)
            let session = transition.flatMap { registry[$0.sessionID] }
            let unlocked = engine.record(event, transition: transition, session: session)
            var o = FixtureObject()
            o.raw("wire", wireJSON(wire))
            o.str("delivery", delivery.rawValue, default: "live")
            o.list("unlocked", unlocked.map { FixtureJSON.str($0.rawValue) }, omitEmpty: false)
            o.object("state", summary(date))
            steps.append(o.json)
        }
        func at(_ day: Int, _ minutes: Double) -> Date { start.addingTimeInterval(Double(day) * 86_400 + minutes * 60) }

        // Day 0: petting past its cap, play, treats past theirs.
        interact(.pet, day: 0, hour: 1, times: 10)
        interact(.play, day: 0, hour: 2, times: 5)
        interact(.treat, day: 0, hour: 3, times: 4)
        // Claude: sessions in three projects, a turn, a passing test command, a milestone; simulated and late ones don't count.
        event(wire("p1", "SessionStart", at: at(0, 300)))
        event(wire("p2", "UserPromptSubmit", at: at(0, 301)))
        event(wire("p3", "PreToolUse", at: at(0, 302), tool: "Bash", toolUse: "b1"))
        event(wire("p4", "PostToolUse", at: at(0, 303), tool: "Bash", toolUse: "b1") { $0.commandKind = "test"; $0.commandReliable = true })
        event(wire("p5", "Stop", at: at(0, 304)))
        event(wire("p6", "SessionStart", at: at(0, 310), session: "sim", project: "Demo", key: "key-demo", origin: .simulator))
        event(wire("p7", "Stop", at: at(0, 311), session: "sim", project: "Demo", key: "key-demo", origin: .simulator))
        event(wire("p8", "SessionStart", at: at(0, 320), session: "s2", project: "Second", key: "key-second"))
        event(wire("p9", "Report", at: at(0, 321), session: nil, project: "Second", key: "key-second", origin: .report) {
            $0.report = WireReport(kind: "milestone", status: "reached", label: "late milestone")
        }, delivery: .late)
        event(wire("p10", "SessionStart", at: at(0, 330), session: "s3", project: "Third", key: "key-third"))
        // Detective mode, then the turn closes the case.
        event(wire("p11", "UserPromptSubmit", at: at(0, 340), session: "s3", project: "Third", key: "key-third"))
        for index in 0..<3 {
            event(wire("p12-\(index)", "PostToolUseFailure", at: at(0, 341 + Double(index)), session: "s3", project: "Third", key: "key-third", tool: "Bash"))
        }
        event(wire("p13", "Stop", at: at(0, 350), session: "s3", project: "Third", key: "key-third"))
        event(wire("p14", "Report", at: at(0, 360), session: nil, project: "Third", key: "key-third", origin: .report) {
            $0.report = WireReport(kind: "milestone", status: "reached", label: "v1")
        })
        // More days of play: levels, good friends after 7 days, growing up over days and weeks.
        for day in [1, 2, 4, 5, 8, 9, 10, 12, 15, 16] {
            interact(.pet, day: day, hour: 9, times: 8)
            interact(.play, day: day, hour: 10, times: 4)
            interact(.treat, day: day, hour: 11, times: 3)
        }
        interact(.pet, day: 30, hour: 9)
        interact(.play, day: 40, hour: 9, times: 3)

        var root = FixtureObject()
        root.str("about", "TamagotchiCore's AchievementEngine (with a UTC calendar), SessionRegistry and LifeStage (mochi_world's must match). "
                 + "Steps run in order on one engine and one registry: an interaction at a time, or a wire event (normalized at its own ts, "
                 + "applied to the registry, then recorded); after each, the result and the whole progress. Dates are ISO 8601 UTC.")
        root.exact("start", start.timeIntervalSince1970)
        root.list("steps", steps, omitEmpty: false, multiline: true)
        return root.json
    }

    // MARK: - Celebrations (G2)

    static func celebrations() -> String {
        var scenarios: [String] = []
        func scenario(_ name: String, settings configure: (inout AppSettings) -> Void = { _ in }, milestoneReached: Bool = false,
                      _ events: [(WireEvent, EventDelivery)]) {
            var settings = AppSettings()
            settings.soundEnabled = true
            configure(&settings)
            var registry = SessionRegistry()
            var reached = milestoneReached
            var steps: [String] = []
            for (wire, delivery) in events {
                let received = Date(timeIntervalSince1970: wire.ts)
                let event = EventNormalizer.normalize(wire, receivedAt: received, delivery: delivery)
                let previousPrimary = registry.primarySession(pinned: nil, now: received)?.id
                let transition = registry.apply(event)
                let session = transition.flatMap { registry[$0.sessionID] }
                var o = FixtureObject()
                o.raw("wire", wireJSON(wire))
                o.str("delivery", delivery.rawValue, default: "live")
                o.str("kind", event.kind.rawValue)
                o.str("summary", event.summary)
                if let transition {
                    var t = FixtureObject()
                    t.str("session", transition.sessionID)
                    t.str("previousPhase", transition.previousPhase?.rawValue)
                    t.str("phase", transition.phase.rawValue)
                    t.bool("isNewSession", transition.isNewSession, default: false)
                    t.bool("startedInvestigating", transition.startedInvestigating, default: false)
                    t.optionalExact("turnDuration", transition.turnDuration)
                    t.bool("turnDurationTrusted", transition.turnDurationTrusted, default: false)
                    o.object("transition", t)
                }
                if let session {
                    var s = FixtureObject()
                    s.int("consecutiveFailures", session.consecutiveFailures)
                    s.bool("investigatedThisTurn", session.investigatedThisTurn)
                    s.bool("isInvestigating", session.isInvestigating)
                    s.int("turnsCompleted", session.turnsCompleted)
                    if let outcome = session.buildTestThisTurn {
                        s.str("buildTest", "\(outcome.kind.rawValue) \(outcome.passed ? "passed" : "failed") (\(outcome.source.rawValue))")
                    }
                    s.str("statusLine", session.statusLine(now: received))
                    o.object("session", s)
                }
                if delivery == .live {
                    let firstMilestone = !event.isSimulated && event.kind == .report && event.report?.kind == .milestone && !reached
                    if firstMilestone { reached = true }
                    let primaryID = registry.primarySession(pinned: nil, now: received)?.id
                    let context = MapperContext(
                        companionPresent: true,
                        isPrimary: session == nil || session?.id == primaryID || previousPrimary == nil,
                        multipleLiveSessions: registry.all.filter { $0.phase != .ended }.count > 1,
                        celebrateCommandResults: settings.celebrateCommandResults,
                        longTurnThreshold: TimeInterval(settings.longTurnMinutes * 60),
                        firstMilestone: firstMilestone
                    )
                    if let reaction = EventToAnimationMapper.reaction(for: event, transition: transition, session: session, context: context) {
                        var r = FixtureObject()
                        r.str("category", reaction.category.rawValue)
                        r.str("pet", reaction.pet?.rawValue)
                        r.str("companion", reaction.companion?.rawValue)
                        r.str("interaction", reaction.interaction?.rawValue)
                        r.str("priority", "\(reaction.priority)")
                        r.str("sound", reaction.sound?.rawValue)
                        r.str("attention", reaction.attention.map { "\($0)" })
                        if let banner = reaction.banner {
                            var b = FixtureObject()
                            b.str("title", banner.title)
                            b.str("body", banner.body)
                            r.object("banner", b)
                        }
                        r.str("caption", reaction.caption)
                        r.bool("burst", reaction.burst, default: false)
                        r.bool("resultCard", reaction.resultCard, default: false)
                        o.object("reaction", r)
                        let decision = NotificationPolicy.decide(reaction.category, settings: settings,
                                                                 context: NotificationContext(now: received, isSimulated: event.isSimulated,
                                                                                              isLate: event.delivery != .live),
                                                                 calendar: WorldFixtures.utc)
                        var d = FixtureObject()
                        d.bool("animate", decision.animate)
                        d.bool("badge", decision.badge)
                        d.bool("banner", decision.banner)
                        d.bool("sound", decision.sound)
                        o.object("decision", d)
                        // The strict G2 view: a celebration only for live, real events.
                        if !event.isSimulated, let interaction = reaction.interaction { o.str("celebrates", interaction.rawValue) }
                    }
                }
                steps.append(o.json)
            }
            var s = FixtureObject()
            s.str("name", name)
            var overrides = FixtureObject()
            overrides.bool("celebrateCommandResults", settings.celebrateCommandResults, default: true)
            overrides.int("longTurnMinutes", settings.longTurnMinutes, default: 10)
            s.object("settings", overrides)
            s.bool("milestoneReached", milestoneReached, default: false)
            s.list("events", steps, omitEmpty: false, multiline: true)
            scenarios.append(s.json)
        }
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        let live = EventDelivery.live

        scenario("a finished turn: high five", [
            (wire("a1", "SessionStart", at: at(0)), live),
            (wire("a2", "UserPromptSubmit", at: at(5)), live),
            (wire("a3", "PreToolUse", at: at(6), tool: "Edit", toolUse: "e1"), live),
            (wire("a4", "PostToolUse", at: at(8), tool: "Edit", toolUse: "e1"), live),
            (wire("a5", "Stop", at: at(40)), live),
        ])
        scenario("a long turn seen live at both ends: victory dance", [
            (wire("b1", "SessionStart", at: at(0)), live),
            (wire("b2", "UserPromptSubmit", at: at(5)), live),
            (wire("b3", "PreToolUse", at: at(60), tool: "Read", toolUse: "r1"), live),
            (wire("b4", "PostToolUse", at: at(62), tool: "Read", toolUse: "r1"), live),
            (wire("b5", "Stop", at: at(5 + 11 * 60)), live),
        ])
        scenario("a long turn whose start arrived late: only a high five", [
            (wire("c1", "SessionStart", at: at(0)), .late),
            (wire("c2", "UserPromptSubmit", at: at(5)), .late),
            (wire("c3", "Stop", at: at(5 + 12 * 60)), live),
        ])
        scenario("a long turn whose end arrived late: nothing", [
            (wire("d1", "SessionStart", at: at(0)), live),
            (wire("d2", "UserPromptSubmit", at: at(5)), live),
            (wire("d3", "Stop", at: at(5 + 12 * 60)), .late),
        ])
        scenario("a real passing test command: trophy", [
            (wire("e1", "SessionStart", at: at(0)), live),
            (wire("e2", "UserPromptSubmit", at: at(3)), live),
            (wire("e3", "PreToolUse", at: at(4), tool: "Bash", toolUse: "t1") { $0.commandKind = "test" }, live),
            (wire("e4", "PostToolUse", at: at(30), tool: "Bash", toolUse: "t1") { $0.commandKind = "test"; $0.commandReliable = true }, live),
            (wire("e5", "Stop", at: at(31)), live),
        ])
        scenario("a test command whose exit status can't be trusted: high five", [
            (wire("f1", "SessionStart", at: at(0)), live),
            (wire("f2", "UserPromptSubmit", at: at(3)), live),
            (wire("f3", "PostToolUse", at: at(30), tool: "Bash", toolUse: "t1") { $0.commandKind = "test"; $0.commandReliable = false }, live),
            (wire("f4", "Stop", at: at(31)), live),
        ])
        scenario("a backgrounded build: not a result", [
            (wire("f5", "SessionStart", at: at(0)), live),
            (wire("f6", "UserPromptSubmit", at: at(3)), live),
            (wire("f7", "PostToolUse", at: at(30), tool: "Bash", toolUse: "t1") {
                $0.commandKind = "build"; $0.commandReliable = true; $0.backgrounded = true
            }, live),
            (wire("f8", "Stop", at: at(31)), live),
        ])
        scenario("a failed build, then a long turn ends: victory dance", [
            (wire("g1", "SessionStart", at: at(0)), live),
            (wire("g2", "UserPromptSubmit", at: at(3)), live),
            (wire("g3", "PostToolUseFailure", at: at(30), tool: "Bash", toolUse: "t1") {
                $0.commandKind = "build"; $0.commandReliable = true; $0.exitCode = 1
            }, live),
            (wire("g4", "Stop", at: at(3 + 10 * 60)), live),
        ])
        scenario("three tool errors in a row: detective, then case closed", [
            (wire("h1", "SessionStart", at: at(0)), live),
            (wire("h2", "UserPromptSubmit", at: at(3)), live),
            (wire("h3", "PostToolUseFailure", at: at(10), tool: "Bash", toolUse: "x1") { $0.exitCode = 2 }, live),
            (wire("h4", "PostToolUseFailure", at: at(20), tool: "Grep", toolUse: "x2"), live),
            (wire("h5", "PostToolUseFailure", at: at(30), tool: "Bash", toolUse: "x3") { $0.exitCode = 127 }, live),
            (wire("h6", "PostToolUseFailure", at: at(40), tool: "Bash", toolUse: "x4"), live),
            (wire("h7", "PostToolUse", at: at(50), tool: "Bash", toolUse: "x5"), live),
            (wire("h8", "Stop", at: at(60)), live),
        ])
        scenario("errors broken up by a success: no detective", [
            (wire("i1", "SessionStart", at: at(0)), live),
            (wire("i2", "UserPromptSubmit", at: at(3)), live),
            (wire("i3", "PostToolUseFailure", at: at(10), tool: "Bash", toolUse: "x1"), live),
            (wire("i4", "PostToolUseFailure", at: at(20), tool: "Bash", toolUse: "x2"), live),
            (wire("i5", "PostToolUse", at: at(25), tool: "Bash", toolUse: "x3"), live),
            (wire("i6", "PostToolUseFailure", at: at(30), tool: "Bash", toolUse: "x4") { $0.isInterrupt = true }, live),
            (wire("i7", "PostToolUseFailure", at: at(35), tool: "Bash", toolUse: "x5"), live),
            (wire("i8", "Stop", at: at(60)), live),
        ])
        scenario("explicit reports, milestones and commits", [
            (wire("j1", "SessionStart", at: at(0)), live),
            (wire("j2", "Report", at: at(10), session: nil, origin: .report) { $0.report = WireReport(kind: "test", status: "passed", label: "unit") }, live),
            (wire("j3", "Report", at: at(20), session: nil, origin: .report) { $0.report = WireReport(kind: "build", status: "failed") }, live),
            (wire("j4", "Report", at: at(30), session: nil, origin: .report) { $0.report = WireReport(kind: "milestone", status: "reached", label: "Beta") }, live),
            (wire("j5", "Report", at: at(40), session: nil, origin: .report) { $0.report = WireReport(kind: "milestone", status: "reached") }, live),
            (wire("j-ms0", "Report", at: at(50), session: nil, origin: .report) { $0.report = WireReport(kind: "milestone", status: "reached") }, live),
            (wire("j7", "Report", at: at(55), session: nil, origin: .report) { $0.report = WireReport(kind: "milestone", status: "reached") }, live),
            (wire("j8", "Report", at: at(60), session: nil, origin: .report) { $0.report = WireReport(kind: "commit", status: "reached", label: "abc123") }, live),
            (wire("j9", "Report", at: at(70), session: nil, project: "Elsewhere", key: "key-elsewhere", origin: .report) {
                $0.report = WireReport(kind: "test", status: "passed")
            }, live),
            (wire("j10", "UserPromptSubmit", at: at(80)), live),
            (wire("j11", "Stop", at: at(90)), live),
        ])
        scenario("a milestone after an earlier one: no graduation", milestoneReached: true, [
            (wire("k1", "Report", at: at(10), session: nil, origin: .report) { $0.report = WireReport(kind: "milestone", status: "reached") }, live),
            (wire("k2", "Report", at: at(20), session: nil, origin: .report) { $0.report = WireReport(kind: "milestone", status: "reached") }, .late),
        ])
        scenario("simulated activity animates but never celebrates", [
            (wire("l1", "SessionStart", at: at(0), session: "sim", origin: .simulator), live),
            (wire("l2", "UserPromptSubmit", at: at(5), session: "sim", origin: .simulator), live),
            (wire("l3", "PostToolUse", at: at(30), session: "sim", origin: .simulator, tool: "Bash", toolUse: "t1") {
                $0.commandKind = "test"; $0.commandReliable = true
            }, live),
            (wire("l4", "Stop", at: at(40), session: "sim", origin: .simulator), live),
            (wire("l5", "Report", at: at(50), session: nil, origin: .simulator) { $0.report = WireReport(kind: "milestone", status: "reached") }, live),
        ])
        scenario("two sessions: the other one finishing gets a bounce, not the scene", [
            (wire("m1", "SessionStart", at: at(0)), live),
            (wire("m2", "SessionStart", at: at(1), session: "s2", project: "Other", key: "key-other"), live),
            (wire("m3", "UserPromptSubmit", at: at(5)), live),
            (wire("m4", "UserPromptSubmit", at: at(6), session: "s2", project: "Other", key: "key-other"), live),
            (wire("m5", "PermissionRequest", at: at(10), tool: "Bash"), live),
            (wire("m6", "Notification", at: at(10.2)) { $0.notificationType = "permission_prompt"; $0.message = "Claude needs your permission to use Bash" }, live),
            (wire("m7", "Stop", at: at(20), session: "s2", project: "Other", key: "key-other"), live),
            (wire("m8", "PreToolUse", at: at(30), tool: "Bash", toolUse: "b1"), live),
            (wire("m9", "PostToolUse", at: at(31), tool: "Bash", toolUse: "b1"), live),
            (wire("m10", "Stop", at: at(40)), live),
        ])
        scenario("celebrating command results turned off: a passing test command isn't a trophy", settings: { $0.celebrateCommandResults = false }, [
            (wire("n1", "SessionStart", at: at(0)), live),
            (wire("n2", "UserPromptSubmit", at: at(3)), live),
            (wire("n3", "PostToolUse", at: at(30), tool: "Bash", toolUse: "t1") { $0.commandKind = "test"; $0.commandReliable = true }, live),
            (wire("n4", "Stop", at: at(31)), live),
            (wire("n5", "Report", at: at(40), session: nil, origin: .report) { $0.report = WireReport(kind: "test", status: "passed") }, live),
            (wire("n6", "UserPromptSubmit", at: at(50)), live),
            (wire("n7", "Report", at: at(55), session: nil, origin: .report) { $0.report = WireReport(kind: "build", status: "passed") }, live),
            (wire("n8", "Stop", at: at(60)), live),
        ])
        scenario("a shorter long-turn setting", settings: { $0.longTurnMinutes = 2 }, [
            (wire("o1", "UserPromptSubmit", at: at(0)), live),
            (wire("o2", "Stop", at: at(150)), live),
            (wire("o3", "UserPromptSubmit", at: at(200)), live),
            (wire("o4", "Stop", at: at(260)), live),
        ])
        scenario("the rest of a session's life", [
            (wire("q1", "SessionStart", at: at(0)) { $0.source = "resume"; $0.model = "claude-opus" }, live),
            (wire("q2", "SessionStart", at: at(2)) { $0.source = "compact" }, live),
            (wire("q3", "UserPromptSubmit", at: at(5)), live),
            (wire("q4", "SubagentStart", at: at(6)) { $0.agentType = "Explore"; $0.agentId = "ag1" }, live),
            (wire("q5", "SubagentStop", at: at(9)) { $0.agentType = "Explore"; $0.agentId = "ag1" }, live),
            (wire("q6", "PermissionDenied", at: at(10), tool: "Bash"), live),
            (wire("q7", "PostToolBatch", at: at(11)) { $0.batchCount = 3; $0.batchTools = ["Read", "Grep", "Read"] }, live),
            (wire("q8", "Notification", at: at(12)) { $0.notificationType = "agent_completed" }, live),
            (wire("q9", "Notification", at: at(13)) { $0.notificationType = "idle_prompt" }, live),
            (wire("q10", "StopFailure", at: at(14)) { $0.reason = "rate_limit" }, live),
            (wire("q11", "PreToolUse", at: at(20), tool: "mcp__claude_ai_Notion__notion-search", toolUse: "n1"), live),
            (wire("q12", "SessionEnd", at: at(30)) { $0.reason = "prompt_input_exit" }, live),
            (wire("q13", "Mystery", at: at(31)), live),
        ])

        // The commandKind behind "real build/test results" is decided in the hook helper (TamagotchiWire's
        // CommandClassifier; mochi_wire's on Windows): the same commands must classify the same way.
        let commands = [
            "npm test", "npm run build && npm test", "swift build | tee log", "flutter test; echo done", "swift test",
            "cargo build --release", "cargo test", "pytest -q", "python -m pytest tests/", "go test ./...", "go build ./...",
            "make", "make test", "xcodebuild -scheme App test", "./gradlew assembleDebug", "gradle test", "yarn build",
            "pnpm test", "bun test", "dotnet build", "dotnet test", "mvn package", "mvn test", "env CI=1 npm test",
            "time cargo test", "npm test || true", "npm test &", "set -o pipefail; npm test | tee out", "ls -la", "git status",
            "echo \"npm test\"", "cd app && npm run build", "npx jest", "npx tsc --noEmit", "dart test", "flutter build windows",
            "deno test", "rspec", "bundle exec rspec", "npm run lint",
        ]
        let commandList = commands.map { command -> String in
            let result = CommandClassifier.classify(command)
            var o = FixtureObject()
            o.str("command", command)
            o.str("kind", result.kind)
            o.bool("reliable", result.reliable)
            return o.json
        }

        var root = FixtureObject()
        root.str("about", "Sprint 2 G2, celebrations from real Claude events, from TamagotchiCore's SessionRegistry, EventToAnimationMapper and "
                 + "NotificationPolicy (mochi_world's must match). Each scenario's wire events are normalized at their own ts (received then) "
                 + "with the given delivery and applied in order to one registry; the mapper context is CompanionWorld's (companion present, "
                 + "primary = the registry's primary session before or after the event, firstMilestone = the first live real milestone unless "
                 + "milestoneReached). reaction and decision (AppSettings with sound on) are only for live events, as the world only maps those; "
                 + "celebrates is the strict view: the interaction, for live events that aren't simulated. commands are CommandClassifier's "
                 + "build/test detection.")
        root.list("scenarios", scenarios, omitEmpty: false, multiline: true)
        root.list("commands", commandList, omitEmpty: false, multiline: true)
        return root.json
    }
}
