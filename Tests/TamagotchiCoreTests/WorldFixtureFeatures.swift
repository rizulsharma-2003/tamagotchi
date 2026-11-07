import Foundation
@testable import TamagotchiCore
import TamagotchiWire

/// Golden fixtures for the Sprint 2 features ported to mochi_world (link-spec/world): what Mochi says (W11), the
/// mini-games (W14), the focus timer (W15), the daily recap (W16), the room makeover (W18) and holidays (W20). Only
/// TamagotchiCore's deterministic logic is recorded here; the App target's rules (when to speak, toasts and lines)
/// are ported with Dart-only tests.
@MainActor
enum FeatureFixtures {
    static let utc = WorldFixtures.utc
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func seconds(_ date: Date) -> String { FixtureJSON.num(date.timeIntervalSince1970) }

    static func wireEvent(_ id: String, _ event: String, at date: Date, session: String? = "s1", tool: String? = nil,
                          origin: WireOrigin = .hook, configure: (inout WireEvent) -> Void = { _ in }) -> WireEvent {
        LogicFixtures.wire(id, event, at: date, session: session, origin: origin, tool: tool, configure: configure)
    }

    // MARK: - W11 speech

    static func speech() -> String {
        let seeds: [UInt64] = [0, 1, 7, 42, 123_456_789, 0x9E37_79B9_7F4A_7C15, 0xDEAD_BEEF_CAFE_F00D, UInt64.max]
        var occasions: [String] = []
        for occasion in SpeechOccasion.allCases {
            let lines = SpeechLines.lines(for: occasion)
            var o = FixtureObject()
            o.str("occasion", occasion.rawValue)
            o.str("importance", "\(occasion.importance)")
            o.str("situation", occasion.situation)
            o.list("lines", lines.map { "[\(FixtureJSON.str($0.speaker.rawValue)),\(FixtureJSON.str($0.text)),\($0.text.count)]" },
                   omitEmpty: false)
            var picks: [String] = []
            for seed in seeds {
                for avoid in [0, 2, lines.count] {
                    let line = SpeechLines.pick(occasion, seed: seed, avoiding: lines.prefix(avoid).map(\.text))!
                    picks.append("[\(FixtureJSON.str(String(seed))),\(avoid),\(FixtureJSON.str(line.text))]")
                }
            }
            o.list("picks", picks, omitEmpty: false)
            occasions.append(o.json)
        }

        let sinces: [Double] = [0, 4.9, 5, 7.9, 8, 11.9, 12, 19.9, 20, 29.9, 30, 89.9, 90, 1e9]
        var pacing: [String] = []
        for chattiness in Chattiness.allCases {
            let p = SpeechPacing(chattiness: chattiness)
            var o = FixtureObject()
            o.str("chattiness", chattiness.rawValue)
            o.optionalNum("idleInterval", p.idleInterval)
            o.optionalNum("sleepInterval", p.sleepInterval)
            var allows = FixtureObject()
            for occasion in SpeechOccasion.allCases {
                allows.str(occasion.rawValue, String(sinces.map { p.allows(occasion, since: $0) ? "1" : "0" }))
            }
            o.object("allows", allows)
            pacing.append(o.json)
        }

        let raws: [(String, Int?)] = [
            ("\"Purr… more scritches please!\"", nil),
            ("  Hello there!  \nSecond line", nil),
            ("\n\nAfter blank lines", nil),
            ("Sorry, I can't help with that.", nil),
            ("As an AI language model, meow", nil),
            ("Your friendly assistant is here", nil),
            ("*stretches*", nil),
            ("“Curly quotes” and ‘single’ ones", nil),
            ("This line is far too long to fit inside one tiny speech bubble, honestly", nil),
            ("Supercalifragilisticexpialidocious-and-even-longer-without-spaces-at-all", nil),
            ("Coffee, cookies, and code: the perfect afternoon for a cat!", nil),
            ("Good morning! ☀️ Ready to build something wonderful today?", nil),
            ("👋🏽 Hi friend!", nil),
            ("Flags 🇮🇳🇯🇵 everywhere and more words to cut here", 20),
            ("Family 👨‍👩‍👧 time together", 12),
            ("Keycap 1️⃣ and café crème brûlée for everyone tonight", 24),
            ("", nil),
            ("   ", nil),
            ("'", nil),
            ("Line one\r\nline two", nil),
            ("Tabs\tinside — dashes… and more text to make this long enough", 30),
            ("Ends with punctuation, right before the cut... yes", 40),
            ("Wow!!! (so) many [brackets] here — truly, madly, deeply", 33),
        ]
        var sanitize: [String] = []
        for (raw, maxLength) in raws {
            var o = FixtureObject()
            o.str("raw", raw)
            o.optionalInt("maxLength", maxLength)
            o.int("count", raw.count)
            let result = maxLength.map { SpeechLines.sanitize(raw, maxLength: $0) } ?? SpeechLines.sanitize(raw)
            if let result {
                o.str("result", result)
                o.int("resultCount", result.count)
            } else {
                o.raw("result", "null")
            }
            sanitize.append(o.json)
        }

        var t = start
        func next() -> Date {
            t = t.addingTimeInterval(7)
            return t
        }
        let wires: [WireEvent] = [
            wireEvent("sp1", "SessionStart", at: next()),
            wireEvent("sp2", "UserPromptSubmit", at: next()),
            wireEvent("sp3", "PreToolUse", at: next(), tool: "Read"),
            wireEvent("sp4", "PostToolUse", at: next(), tool: "Read"),
            wireEvent("sp5", "PostToolUseFailure", at: next(), tool: "Bash") { $0.exitCode = 1 },
            wireEvent("sp6", "PostToolUseFailure", at: next(), tool: "Bash") { $0.isInterrupt = true },
            wireEvent("sp7", "PermissionRequest", at: next(), tool: "Bash"),
            wireEvent("sp8", "Notification", at: next()) { $0.notificationType = "permission_prompt" },
            wireEvent("sp9", "Notification", at: next()) { $0.notificationType = "idle_prompt" },
            wireEvent("sp10", "Notification", at: next()) { $0.notificationType = "auth_success" },
            wireEvent("sp11", "SubagentStart", at: next()),
            wireEvent("sp12", "SubagentStop", at: next()),
            wireEvent("sp13", "PostToolUse", at: next(), tool: "Bash") {
                $0.commandKind = "test"
                $0.commandReliable = true
                $0.exitCode = 0
            },
            wireEvent("sp14", "PostToolUseFailure", at: next(), tool: "Bash") {
                $0.commandKind = "build"
                $0.commandReliable = true
                $0.exitCode = 1
            },
            wireEvent("sp15", "PostToolUse", at: next(), tool: "Bash") { $0.commandKind = "build" },
            wireEvent("sp16", "Report", at: next(), origin: .report) { $0.report = WireReport(kind: "build", status: "passed") },
            wireEvent("sp17", "Report", at: next(), origin: .report) { $0.report = WireReport(kind: "test", status: "failed", label: "unit") },
            wireEvent("sp18", "Report", at: next(), origin: .report) { $0.report = WireReport(kind: "milestone", status: "reached") },
            wireEvent("sp19", "Stop", at: next()),
            wireEvent("sp20", "StopFailure", at: next()) { $0.reason = "rate_limit" },
            wireEvent("sp21", "SessionEnd", at: next()) { $0.reason = "logout" },
            wireEvent("sp22", "PostToolBatch", at: next()),
        ]
        var events: [String] = []
        for wire in wires {
            let event = EventNormalizer.normalize(wire, receivedAt: Date(timeIntervalSince1970: wire.ts), delivery: .live)
            var o = FixtureObject()
            o.raw("wire", LogicFixtures.wireJSON(wire))
            o.str("kind", event.kind.rawValue)
            if let occasion = SpeechOccasion.forEvent(event) { o.str("occasion", occasion.rawValue) } else { o.raw("occasion", "null") }
            events.append(o.json)
        }

        var root = FixtureObject()
        root.str("about", "W11, TamagotchiCore's SpeechLines, SpeechOccasion and SpeechPacing (mochi_world's must match). occasions: "
                 + "importance, situation, lines as [speaker, text, Swift's character count] and picks as [seed, n, text] for "
                 + "pick(occasion, seed, avoiding: the first n lines' texts). pacing: per chattiness, the intervals and, per "
                 + "occasion, allows(occasion, since) for each of sinces as 1/0. greetings: greeting(hour) for 0…23. sanitize: "
                 + "raw (Swift's count), maxLength (default 44) and the result. events: forEvent of each wire event normalized at its ts.")
        root.list("occasions", occasions, omitEmpty: false, multiline: true)
        root.list("sinces", sinces.map(FixtureJSON.num), omitEmpty: false)
        root.list("pacing", pacing, omitEmpty: false, multiline: true)
        root.list("greetings", (0..<24).map { FixtureJSON.str(SpeechOccasion.greeting(hour: $0).rawValue) }, omitEmpty: false)
        root.list("sanitize", sanitize, omitEmpty: false, multiline: true)
        root.list("events", events, omitEmpty: false, multiline: true)
        return root.json
    }

    // MARK: - W14 games

    enum CatchPlan {
        case autopilot
        case keys([(from: Int, direction: Double)])
        case drag([(from: Int, x: Double?)])
    }

    static func games() -> String {
        var tables = FixtureObject()
        tables.list("multiplier", (0...41).map { String(CatchGame.multiplier(combo: $0)) }, omitEmpty: false)
        tables.list("fallSpeed", (1...8).map { FixtureJSON.num(CatchGame.fallSpeed(level: $0)) }, omitEmpty: false)
        tables.list("spawnInterval", (1...8).map { FixtureJSON.num(CatchGame.spawnInterval(level: $0)) }, omitEmpty: false)

        var catchCases: [String] = []
        func play(_ note: String, seed: UInt64, dts: [Double], steps: Int, autoSpawn: Bool = true,
                  drops: [(step: Int, kind: CatchGame.TreatKind, x: Double, y: Double, speed: Double?)] = [],
                  plan: CatchPlan, every: Int, poseSteps: Set<Int>) {
            var game = CatchGame(seed: seed)
            game.autoSpawn = autoSpawn
            var events: [String] = []
            var checkpoints: [String] = []
            var poses: [String] = []
            for index in 0..<steps {
                for drop in drops where drop.step == index {
                    game.drop(drop.kind, at: drop.x, y: drop.y, speed: drop.speed)
                }
                let input: CatchGame.Input
                switch plan {
                case .autopilot:
                    input = CatchGame.Input(targetX: game.treats.min { $0.y < $1.y }?.x)
                case .keys(let segments):
                    input = CatchGame.Input(direction: segments.last { $0.from <= index }?.direction ?? 0)
                case .drag(let segments):
                    input = CatchGame.Input(targetX: segments.last { $0.from <= index }?.x ?? nil)
                }
                for event in game.step(dt: dts[index % dts.count], input: input) {
                    switch event {
                    case .caught(let kind, let points, let combo):
                        events.append("[\(index),\"caught\",\"\(kind.rawValue)\",\(points),\(combo)]")
                    case .missed(let kind): events.append("[\(index),\"missed\",\"\(kind.rawValue)\"]")
                    case .faster(let level): events.append("[\(index),\"faster\",\(level)]")
                    case .gameOver(let score): events.append("[\(index),\"gameOver\",\(score)]")
                    }
                }
                if index % every == every - 1 || index == steps - 1 {
                    var c = FixtureObject()
                    c.int("after", index)
                    c.num("time", game.time)
                    c.str("phase", game.phase == .playing ? "playing" : "over")
                    c.int("score", game.score)
                    c.int("combo", game.combo)
                    c.int("bestCombo", game.bestCombo)
                    c.int("caught", game.caught)
                    c.int("misses", game.misses)
                    c.int("level", game.level)
                    c.num("petX", game.petX)
                    c.num("petVelocity", game.petVelocity)
                    c.num("facing", game.facing)
                    c.list("treats", game.treats.map { t in
                        "[\(t.id),\"\(t.kind.rawValue)\",\(FixtureJSON.num(t.x)),\(FixtureJSON.num(t.y)),\(FixtureJSON.num(t.speed)),"
                            + "\(FixtureJSON.num(t.spin)),\(FixtureJSON.num(t.age))]"
                    }, omitEmpty: false)
                    c.list("splashes", game.splashes.map { s in
                        "[\"\(s.kind.rawValue)\",\(FixtureJSON.num(s.x)),\(FixtureJSON.num(s.y)),\(s.points),\(FixtureJSON.num(s.at))]"
                    }, omitEmpty: false)
                    if let reaction = game.reaction {
                        c.raw("reaction", "[\"\(reaction.kind)\",\(FixtureJSON.num(reaction.at))]")
                    }
                    checkpoints.append(c.json)
                }
                if poseSteps.contains(index) {
                    let context = PoseContext(time: 1000 + game.time, seed: 0x5EED_CA7C)
                    var p = FixtureObject()
                    p.int("after", index)
                    p.raw("context", PoseJSON.context(context))
                    p.raw("pose", PoseJSON.pet(game.petPose(context: context)))
                    poses.append(p.json)
                }
            }
            var o = FixtureObject()
            o.str("note", note)
            o.raw("seed", FixtureJSON.str(String(seed)))
            o.list("dts", dts.map { "\($0)" }, omitEmpty: false)
            o.int("steps", steps)
            o.bool("autoSpawn", autoSpawn, default: true)
            o.list("drops", drops.map { d in
                "[\(d.step),\"\(d.kind.rawValue)\",\(d.x),\(d.y),\(d.speed.map { "\($0)" } ?? "null")]"
            })
            switch plan {
            case .autopilot: o.str("plan", "autopilot")
            case .keys(let segments): o.list("keys", segments.map { "[\($0.from),\($0.direction)]" }, omitEmpty: false)
            case .drag(let segments): o.list("drag", segments.map { "[\($0.from),\($0.x.map { "\($0)" } ?? "null")]" }, omitEmpty: false)
            }
            o.int("every", every)
            o.list("events", events, omitEmpty: false, multiline: true)
            o.list("checkpoints", checkpoints, omitEmpty: false, multiline: true)
            o.list("poses", poses, omitEmpty: false, multiline: true)
            catchCases.append(o.json)
        }

        let posesEvery = Set(stride(from: 3, to: 7200, by: 37))
        play("autopilot at 60 fps for two minutes: levels, golden treats, combos past ×4", seed: 42, dts: [1.0 / 60], steps: 7200,
             plan: .autopilot, every: 300, poseSteps: posesEvery)
        play("autopilot at 10 fps (the longest step) to the top speed level", seed: 2026, dts: [0.1], steps: 1700, plan: .autopilot,
             every: 50, poseSteps: Set(stride(from: 2, to: 1700, by: 17)))
        play("keys, uneven frames (some longer than 0.1 s), until the game is over", seed: 0xDEAD_BEEF_CAFE_F00D,
             dts: [1.0 / 60, 1.0 / 30, 0.25, 1.0 / 120], steps: 2400,
             plan: .keys([(0, 1), (40, 0), (90, -1), (200, 0.5), (320, 0), (400, -1), (700, 1), (1000, 0)]),
             every: 100, poseSteps: Set(stride(from: 1, to: 2400, by: 23)))
        play("dragging to fixed spots, a seed above 2^63", seed: UInt64.max - 12_345, dts: [1.0 / 50], steps: 3000,
             plan: .drag([(0, 0.2), (150, nil), (300, 0.9), (600, 0.02), (900, 0.98), (1200, 0.5), (1600, nil)]),
             every: 150, poseSteps: Set(stride(from: 5, to: 3000, by: 41)))
        play("treats placed by hand: catches, a free golden miss, combos, a long step through Mochi, three misses", seed: 7,
             dts: [1.0 / 60], steps: 900, autoSpawn: false,
             drops: [(0, .cookie, 0.5, 0.6, nil), (40, .fish, 0.5, 0.5, nil), (80, .golden, 0.5, 0.5, nil), (120, .golden, 0.95, 0.5, nil),
                     (200, .berry, 0.52, 0.3, 2.5), (260, .cookie, 0.05, 0.3, nil), (300, .fish, 0.95, 0.3, nil),
                     (360, .berry, 0.9, 0.3, nil), (370, .cookie, 0.5, 0.9, nil)],
             plan: .drag([(0, nil)]), every: 30, poseSteps: Set(stride(from: 0, to: 900, by: 9)))

        var rpsCases: [String] = []
        for (seed, withCompanion) in [(UInt64(1), true), (0xDEAD_BEEF_CAFE_F00D, false), (UInt64.max, true), (UInt64(20_261_108), false)] {
            var match = RPSMatch(seed: seed, withCompanion: withCompanion)
            var records = GameRecords()
            var rounds: [String] = []
            for index in 0..<60 {
                let choice = RPSChoice(rawValue: (index * 7 + index / 3) % 3)!
                let round = match.play(choice)
                let best = records.recordRPS(round, streak: match.streak)
                rounds.append("[\"\(round.player)\",\"\(round.pet)\",\(round.companion.map { "\"\($0)\"" } ?? "null"),\(round.vsPet),"
                              + "\(round.vsCompanion.map(String.init) ?? "null"),\(round.isWin),\(round.isLoss),\(match.streak),\(best)]")
            }
            var o = FixtureObject()
            o.raw("seed", FixtureJSON.str(String(seed)))
            o.bool("withCompanion", withCompanion)
            o.list("rounds", rounds, omitEmpty: false, multiline: true)
            o.raw("vsPet", "[\(match.vsPet.wins),\(match.vsPet.losses),\(match.vsPet.draws)]")
            o.raw("vsCompanion", "[\(match.vsCompanion.wins),\(match.vsCompanion.losses),\(match.vsCompanion.draws)]")
            o.int("kept", match.rounds.count)
            o.raw("records", recordsJSON(records))
            rpsCases.append(o.json)
        }

        var records = GameRecords()
        var catchRecords: [String] = []
        for (score, combo) in [(0, 0), (12, 4), (8, 9), (12, 2), (40, 7), (39, 30)] {
            let high = records.recordCatch(score: score, bestCombo: combo)
            catchRecords.append("[\(score),\(combo),\(high),\(recordsJSON(records))]")
        }

        var root = FixtureObject()
        root.str("about", "W14, TamagotchiCore's CatchGame, RPSMatch and GameRecords (mochi_world's must match). tables: multiplier(combo) "
                 + "for 0…41, fallSpeed and spawnInterval for levels 1…8. catch: each case steps CatchGame(seed) (autoSpawn as given) "
                 + "with dts[i % count]; before step i its drops [step, kind, x, y, speed|null] are dropped; the input is the plan's: "
                 + "autopilot (targetX = the lowest treat's x, the first on ties, or none), keys [from, direction] or drag [from, x|null] "
                 + "(the last segment with from ≤ i). events [step, kind, …]; checkpoints after every `every` steps and the last; poses "
                 + "petPose(context) after the given steps. rps: 60 rounds of RPSMatch(seed).play(choice) with choice = (7i + i/3) % 3, each "
                 + "recorded with recordRPS(round, streak): [player, pet, companion, vsPet, vsCompanion, isWin, isLoss, streak, newBest]. "
                 + "catchRecords: recordCatch(score, bestCombo) in order: [score, combo, newHigh, records].")
        root.raw("tables", tables.json)
        root.list("catch", catchCases, omitEmpty: false, multiline: true)
        root.list("rps", rpsCases, omitEmpty: false, multiline: true)
        root.list("catchRecords", catchRecords, omitEmpty: false, multiline: true)
        return root.json
    }

    static func recordsJSON(_ records: GameRecords) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try! encoder.encode(records), encoding: .utf8)!
    }

    // MARK: - W15 focus

    static func focus() -> String {
        var settingsCases: [String] = []
        for (w, b, l, c) in [(25, 5, 15, 4), (0, 0, 0, 0), (500, 100, 200, 40), (-3, 61, 91, 13), (1, 1, 1, 1), (50, 10, 30, 2), (180, 60, 90, 12)] {
            var settings = FocusSettings()
            settings.workMinutes = w
            settings.breakMinutes = b
            settings.longBreakMinutes = l
            settings.cyclesBeforeLongBreak = c
            let d = FocusTimer.Durations(settings)
            settingsCases.append("[\(w),\(b),\(l),\(c),\(FixtureJSON.num(d.focus)),\(FixtureJSON.num(d.shortBreak)),"
                                 + "\(FixtureJSON.num(d.longBreak)),\(d.cyclesBeforeLongBreak)]")
        }
        let raw = FocusTimer.Durations(focus: 0, shortBreak: -5, longBreak: 0.5, cyclesBeforeLongBreak: 0)
        let clocks: [Double] = [0, 0.2, 1, 59.01, 59.99, 60, 61, 599.5, 1500, 3599.5, 3600, 3725, 36_000, -5]

        func transitionJSON(_ t: FocusTimer.Transition) -> String {
            switch t {
            case .started(let phase, let cycle): return "[\"started\",\"\(phase.rawValue)\",\(cycle)]"
            case .focusCompleted(let block): return "[\"completed\",\(seconds(block.endedAt)),\(FixtureJSON.num(block.minutes))]"
            case .finished(let blocks): return "[\"finished\",\(blocks)]"
            case .stopped: return "[\"stopped\"]"
            case .expired: return "[\"expired\"]"
            }
        }
        var timers: [String] = []
        func scenario(_ note: String, _ durations: FocusTimer.Durations, _ ops: [(String, Double)]) {
            var timer = FocusTimer(durations: durations)
            var steps: [String] = []
            for (op, offset) in ops {
                let at = start.addingTimeInterval(offset)
                let transitions: [FocusTimer.Transition]
                switch op {
                case "start": transitions = timer.start(at: at)
                case "stop": transitions = timer.stop(at: at)
                case "skip": transitions = timer.skip(at: at)
                default: transitions = timer.advance(to: at)
                }
                var o = FixtureObject()
                o.str("op", op)
                o.exact("at", offset)
                o.list("transitions", transitions.map(transitionJSON), omitEmpty: false)
                if let running = timer.running {
                    o.raw("running", "[\"\(running.phase.rawValue)\",\(FixtureJSON.num(running.startedAt.timeIntervalSince(start))),"
                          + "\(FixtureJSON.num(running.duration)),\(running.cycle)]")
                    let status = timer.status(naps: true)!
                    o.bool("petNaps", status.petNaps)
                    o.num("remaining", status.remaining(at: at))
                    o.num("progress", status.progress(at: at))
                } else {
                    o.raw("running", "null")
                }
                o.int("completedBlocks", timer.completedBlocks)
                steps.append(o.json)
            }
            var o = FixtureObject()
            o.str("note", note)
            o.raw("durations", "[\(FixtureJSON.num(durations.focus)),\(FixtureJSON.num(durations.shortBreak)),"
                  + "\(FixtureJSON.num(durations.longBreak)),\(durations.cyclesBeforeLongBreak)]")
            o.list("steps", steps, omitEmpty: false, multiline: true)
            timers.append(o.json)
        }
        let pomodoro = FocusTimer.Durations(focus: 1500, shortBreak: 300, longBreak: 900, cyclesBeforeLongBreak: 2)
        scenario("a whole set noticed on time (and half a second late, which still chains exactly)", pomodoro, [
            ("advance", 0), ("start", 0), ("advance", 1), ("advance", 1499), ("advance", 1500), ("advance", 1700), ("advance", 1800),
            ("advance", 3300.5), ("advance", 3301), ("advance", 4200), ("advance", 4201), ("stop", 4300),
        ])
        let quick = FocusTimer.Durations(focus: 60, shortBreak: 30, longBreak: 45, cyclesBeforeLongBreak: 3)
        scenario("noticed late: under 2 s chains, later starts from now; exactly 10 minutes late still counts", quick, [
            ("start", 0), ("advance", 61.5), ("advance", 95), ("advance", 125), ("advance", 160), ("advance", 190.5), ("advance", 260),
            ("advance", 905), ("advance", 2000),
        ])
        scenario("slept through: more than 10 minutes late expires without counting", quick, [
            ("start", 0), ("advance", 660), ("advance", 1290.5), ("advance", 1291), ("advance", 1292),
        ])
        scenario("skipping: a skipped block doesn't count", pomodoro, [
            ("start", 10), ("skip", 20), ("skip", 30), ("advance", 1530), ("skip", 1600), ("skip", 1700), ("advance", 3200), ("skip", 3300),
            ("skip", 3400),
        ])
        scenario("restarting and stopping", quick, [
            ("start", 0), ("advance", 60), ("start", 100), ("advance", 159), ("advance", 160), ("stop", 170), ("stop", 171), ("skip", 172),
            ("advance", 1000),
        ])
        scenario("one cycle per set: every block is followed by the long break", FocusTimer.Durations(focus: 10, shortBreak: 5, longBreak: 7,
                                                                                                    cyclesBeforeLongBreak: 1), [
            ("start", 0), ("advance", 10), ("advance", 17), ("advance", 18),
        ])

        let log = FocusLog(fileURL: nil, retentionDays: 7)
        var logSteps: [String] = []
        let day = 86_400.0
        for (ended, minutes, now) in [(0.0, 25.0, 0.0), (-3 * day, 25, 0), (-8 * day, 25, 0), (100, 0, 100), (200, -5, 200), (-day, 50, 300),
                                      (2 * day, 25, 2 * day), (5 * day, 12.5, 5 * day), (12 * day, 25, 12 * day)] {
            log.append(FocusBlock(endedAt: start.addingTimeInterval(ended), minutes: minutes), now: start.addingTimeInterval(now))
            logSteps.append("[\(FixtureJSON.num(ended)),\(FixtureJSON.num(minutes)),\(FixtureJSON.num(now)),"
                            + FixtureJSON.array(log.blocks.map { "[\(FixtureJSON.num($0.endedAt.timeIntervalSince(start))),\(FixtureJSON.num($0.minutes))]" })
                            + "]")
        }
        let within = log.blocks(in: DateInterval(start: start.addingTimeInterval(5 * day), end: start.addingTimeInterval(12 * day)))
        let memory = FocusLog(fileURL: nil, retentionDays: 0)
        memory.append(FocusBlock(endedAt: start.addingTimeInterval(-30 * day), minutes: 25), now: start)
        memory.append(FocusBlock(endedAt: start, minutes: 25), now: start)

        var root = FixtureObject()
        root.str("about", "W15, TamagotchiCore's FocusTimer, its Durations and FocusLog (mochi_world's must match). settings: [work, break, "
                 + "long, cycles minutes] → Durations(settings) [focus, shortBreak, longBreak seconds, cycles]; raw: Durations(focus: 0, "
                 + "shortBreak: -5, longBreak: 0.5, cycles: 0). clocks: [seconds, FocusStatus.clock]. timers: ops at start + at seconds "
                 + "(start = 1800000000), with the transitions, then running [phase, startedAt − start, duration, cycle] and, while "
                 + "running, status(naps: true)'s petNaps, remaining and progress at that moment. log: FocusLog(retention 7 days) "
                 + "appends [endedAt, minutes, now] (seconds from start), each followed by the blocks kept; within: blocks(in: start + 5 "
                 + "days … start + 12 days); memory: a log with retention 0 after two appends.")
        root.list("settings", settingsCases, omitEmpty: false, multiline: true)
        root.raw("raw", "[\(FixtureJSON.num(raw.focus)),\(FixtureJSON.num(raw.shortBreak)),\(FixtureJSON.num(raw.longBreak)),\(raw.cyclesBeforeLongBreak)]")
        root.list("clocks", clocks.map { "[\($0),\(FixtureJSON.str(FocusStatus.clock($0)))]" }, omitEmpty: false)
        root.list("timers", timers, omitEmpty: false, multiline: true)
        root.list("log", logSteps, omitEmpty: false, multiline: true)
        root.list("within", within.map { FixtureJSON.num($0.endedAt.timeIntervalSince(start)) }, omitEmpty: false)
        root.list("memory", memory.blocks.map { FixtureJSON.num($0.endedAt.timeIntervalSince(start)) }, omitEmpty: false)
        return root.json
    }

    // MARK: - W16 recap

    static func recap() -> String {
        /// 2027-01-15 00:00 UTC, a Friday.
        let day = Date(timeIntervalSince1970: 1_799_971_200)
        func at(_ hour: Double, _ dayOffset: Int = 0) -> Date { day.addingTimeInterval(Double(dayOffset) * 86_400 + hour * 3_600) }
        var n = 0
        func ev(_ event: String, _ hour: Double, _ dayOffset: Int = 0, session: String? = "s1", tool: String? = nil, origin: WireOrigin = .hook,
                delivery: EventDelivery = .live, configure: (inout WireEvent) -> Void = { _ in }) -> (WireEvent, EventDelivery) {
            n += 1
            return (wireEvent("r\(n)", event, at: at(hour, dayOffset), session: session, tool: tool, origin: origin, configure: configure), delivery)
        }
        let busy: [(WireEvent, EventDelivery)] = [
            ev("SessionStart", 9.0),
            ev("UserPromptSubmit", 9.1),
            ev("PreToolUse", 9.2, tool: "Read"),
            ev("PostToolUse", 9.25, tool: "Read"),
            ev("PreToolUse", 9.3, tool: "Edit"),
            ev("PostToolUse", 9.35, tool: "Edit"),
            ev("PreToolUse", 9.4, tool: "Grep"),
            ev("PostToolUse", 9.45, tool: "Grep"),
            ev("PreToolUse", 9.5, tool: "Bash"),
            ev("PostToolUseFailure", 9.55, tool: "Bash") { $0.exitCode = 1 },
            ev("PreToolUse", 9.6, tool: "Read"),
            ev("PostToolUse", 9.65, tool: "Read"),
            ev("PreToolUse", 9.66, tool: "Edit"),
            ev("Stop", 9.8),
            ev("UserPromptSubmit", 14.0, session: "s2"),
            ev("PreToolUse", 14.1, session: "s2", tool: "Bash"),
            ev("PostToolUse", 14.2, session: "s2", tool: "Bash") {
                $0.commandKind = "test"
                $0.commandReliable = true
                $0.exitCode = 0
            },
            ev("PostToolUse", 14.25, session: "s2", tool: "Bash") { $0.commandKind = "build" },
            ev("Report", 14.3, session: nil, origin: .report) { $0.report = WireReport(kind: "build", status: "passed", label: "app") },
            ev("Report", 14.31, session: "s2", origin: .report) { $0.report = WireReport(kind: "test", status: "failed") },
            ev("PostToolUseFailure", 14.32, session: "s2", tool: "Bash") { $0.isInterrupt = true },
            ev("Report", 14.4, session: nil, origin: .report) { $0.report = WireReport(kind: "milestone", status: "reached", label: "v1") },
            ev("Stop", 14.5, session: "s2"),
            ev("StopFailure", 15.0, session: "s3"),
            ev("Stop", 16.0, session: "sim", origin: .simulator),
            ev("Bogus", 17.0, session: "s4"),
            ev("Stop", 23.999, session: "s5", delivery: .late),
            ev("Stop", 24.0, session: "s6"),
            ev("Stop", 0.0, session: "s7"),
            ev("Stop", 9.0, -1),
            ev("Stop", 22.0, -2),
            ev("Stop", 10.0, -4),
        ]
        let blocks = [FocusBlock(endedAt: at(10), minutes: 25), FocusBlock(endedAt: at(11), minutes: 25),
                      FocusBlock(endedAt: at(23.9, -1), minutes: 25), FocusBlock(endedAt: at(24), minutes: 50)]
        var cases: [String] = []
        func recapCase(_ note: String, _ events: [(WireEvent, EventDelivery)], focus: [FocusBlock] = [], day dayDate: Date, historyStart: Date) {
            let normalized = events.map { EventNormalizer.normalize($0.0, receivedAt: Date(timeIntervalSince1970: $0.0.ts), delivery: $0.1) }
            let recap = DailyRecap.compute(day: dayDate, events: normalized, focus: focus, historyStart: historyStart, calendar: utc)
            var o = FixtureObject()
            o.str("note", note)
            o.list("events", events.map { pair in
                var e = FixtureObject()
                e.raw("wire", LogicFixtures.wireJSON(pair.0))
                e.str("delivery", pair.1.rawValue, default: "live")
                return e.json
            }, omitEmpty: false, multiline: true)
            o.list("focus", focus.map { "[\(seconds($0.endedAt)),\(FixtureJSON.num($0.minutes))]" })
            o.raw("day", seconds(dayDate))
            o.raw("historyStart", seconds(historyStart))
            var r = FixtureObject()
            r.raw("day", seconds(recap.day))
            switch recap.coverage {
            case .full: r.str("coverage", "full")
            case .none: r.str("coverage", "none")
            case .partial(let since): r.raw("coverage", "{\"partial\":\(seconds(since))}")
            }
            r.int("sessions", recap.sessions)
            r.int("turnsFinished", recap.turnsFinished)
            r.int("toolCalls", recap.toolCalls)
            r.str("topToolCategory", recap.topToolCategory?.rawValue)
            r.int("buildsPassed", recap.buildsPassed)
            r.int("testsPassed", recap.testsPassed)
            r.int("errorsBouncedBack", recap.errorsBouncedBack)
            r.int("milestones", recap.milestones)
            if let first = recap.firstActivity { r.raw("firstActivity", seconds(first)) }
            if let last = recap.lastActivity { r.raw("lastActivity", seconds(last)) }
            r.int("focusBlocks", recap.focusBlocks)
            r.num("focusMinutes", recap.focusMinutes)
            r.int("streak", recap.streak)
            r.bool("streakIsLowerBound", recap.streakIsLowerBound)
            o.object("recap", r)
            o.bool("hasActivity", recap.hasActivity)
            o.bool("isQuiet", recap.isQuiet)
            o.optionalNum("activeSpan", recap.activeSpan)
            o.list("tiles", recap.tiles.map(tileJSON), omitEmpty: false)
            o.str("summary", recap.summary(petName: "Mochi", companionName: "Patch"))
            o.str("banner", recap.readyBanner(petName: "Mochi", companionName: "Patch").body)
            cases.append(o.json)
        }
        recapCase("a busy day: two sessions, tools, results, a bounce back, a milestone; simulated, unknown and other days left out",
                  busy, focus: blocks, day: at(12), historyStart: at(0, -7))
        recapCase("history starts during the day", busy, day: at(12), historyStart: at(8))
        recapCase("the day is older than the history", busy, day: at(12), historyStart: at(0, 2))
        recapCase("the streak reaches the start of history", busy, day: at(12), historyStart: at(12, -2))
        recapCase("the day before (streak 2: the day before that was active too)", busy, day: at(5, -1), historyStart: at(0, -7))
        recapCase("a day with focus only", [], focus: blocks, day: at(12), historyStart: at(0, -7))
        recapCase("a quiet day", [ev("Stop", 9, -1)], day: at(12), historyStart: at(0, -7))
        recapCase("sessions without a finished turn", [ev("SessionStart", 9), ev("UserPromptSubmit", 9.5, session: "s2")], day: at(12),
                  historyStart: at(0, -7))
        recapCase("only a milestone, outside any session", [ev("Report", 9, session: nil, origin: .report) {
            $0.report = WireReport(kind: "milestone", status: "reached")
        }], day: at(12), historyStart: at(0, -7))
        recapCase("turns and focus", [ev("Stop", 9), ev("Stop", 9.5), ev("Stop", 10, session: "s2")], focus: blocks, day: at(12),
                  historyStart: at(0, -7))
        recapCase("turns and green builds", [ev("Stop", 9), ev("Report", 9.2, origin: .report) {
            $0.report = WireReport(kind: "build", status: "passed")
        }], day: at(12), historyStart: at(0, -30))
        recapCase("tied tool categories go to the earlier one; finishes count when nothing started",
                  [ev("PostToolUse", 9, tool: "Edit"), ev("PostToolUse", 9.1, tool: "Read"), ev("PostToolUse", 9.2, tool: "WebFetch"),
                   ev("PostToolUse", 9.3, tool: "Read"), ev("PostToolUse", 9.4, tool: "Edit"), ev("PostToolUse", 9.5, tool: "mcp__x__y")],
                  day: at(12), historyStart: at(0, -7))
        recapCase("only unknown tools", [ev("PreToolUse", 9, tool: "Mystery"), ev("PreToolUse", 9.1, tool: "Mystery")], day: at(12),
                  historyStart: at(0, -7))
        recapCase("errors that bounce back and errors that don't",
                  [ev("PostToolUseFailure", 9, tool: "Bash"), ev("PostToolUseFailure", 9.1, tool: "Bash") { $0.isInterrupt = true },
                   ev("StopFailure", 9.2, session: "s2"), ev("Stop", 9.5, session: "s2"), ev("PostToolUseFailure", 10, session: "s3", tool: "Bash"),
                   ev("Stop", 9.9, session: "s3"), ev("PostToolUseFailure", 11, session: "s4", tool: "Bash"),
                   ev("PostToolUseFailure", 11.1, session: "s4", tool: "Bash"), ev("Stop", 11.2, session: "s4"), ev("Stop", 11.3, session: "s4")],
                  day: at(12), historyStart: at(0, -7))

        var announce: [String] = []
        for (enabled, hour, last) in [(true, 18, nil), (false, 18, nil), (true, 0, nil), (true, 23, nil), (true, 18, "2027-01-15"),
                                      (true, 18, "2027-01-14")] as [(Bool, Int, String?)] {
            var settings = RecapSettings()
            settings.announce = enabled
            settings.hour = hour
            settings.lastAnnouncedDay = last
            var due: [String] = []
            for hourNow in [0.5, 17.99, 18.0, 22.5, 23.5] {
                for activity in [true, false] {
                    due.append(settings.isAnnouncementDue(at: at(hourNow), hasActivity: activity, calendar: utc) ? "1" : "0")
                }
            }
            announce.append("[\(enabled),\(hour),\(last.map(FixtureJSON.str) ?? "null"),\(FixtureJSON.str(due.joined()))]")
        }
        let decoder = JSONDecoder()
        let clamped = [#"{"hour": 40}"#, #"{"hour": -2, "banner": true}"#, #"{}"#].map { text -> String in
            let s = try! decoder.decode(RecapSettings.self, from: Data(text.utf8))
            return "[\(FixtureJSON.str(text)),\(s.announce),\(s.hour),\(s.banner)]"
        }
        let names = [(at(12), at(15)), (at(0), at(23.99)), (at(12, -1), at(1)), (at(12, -2), at(1)), (at(12, -3), at(1)), (at(12, -6), at(1)),
                     (at(12, 1), at(1))].map { pair in
            "[\(seconds(pair.0)),\(seconds(pair.1)),\(FixtureJSON.str(DailyRecap.dayName(pair.0, now: pair.1, calendar: utc)))]"
        }
        let keys = [at(0), at(23.99), at(0, 366), Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 951_782_400)].map {
            "[\(seconds($0)),\(FixtureJSON.str(DailyRecap.dayKey($0, calendar: utc)))]"
        }
        let titles = ToolCategory.allCases.map { "[\"\($0.rawValue)\",\(FixtureJSON.str($0.recapTitle))]" }

        var root = FixtureObject()
        root.str("about", "W16, TamagotchiCore's DailyRecap and RecapSettings with a UTC calendar (mochi_world's must match). cases: the "
                 + "wire events (normalized at their ts with the delivery), focus blocks [endedAt, minutes] and compute(day, events, focus, "
                 + "historyStart), with the tiles, summary(Mochi, Patch) and readyBanner's body. announce: [announce, hour, "
                 + "lastAnnouncedDay, isAnnouncementDue on 2027-01-15 at 00:30, 17:59, 18:00, 22:30 and 23:30, each with activity then "
                 + "without, as 1/0]. decoded: RecapSettings decoded from JSON (the hour clamped) [json, announce, hour, banner]. dayNames: "
                 + "[day, now, dayName]. dayKeys: [date, dayKey]. recapTitles: ToolCategory.recapTitle.")
        root.list("cases", cases, omitEmpty: false, multiline: true)
        root.list("announce", announce, omitEmpty: false, multiline: true)
        root.list("decoded", clamped, omitEmpty: false)
        root.list("dayNames", names, omitEmpty: false)
        root.list("dayKeys", keys, omitEmpty: false)
        root.list("recapTitles", titles, omitEmpty: false)
        return root.json
    }

    static func tileJSON(_ tile: DailyRecap.Tile) -> String {
        switch tile {
        case .turns(let count): return "{\"kind\":\"turns\",\"count\":\(count)}"
        case .sessions(let count): return "{\"kind\":\"sessions\",\"count\":\(count)}"
        case .toolCalls(let count, let top):
            return "{\"kind\":\"toolCalls\",\"count\":\(count)\(top.map { ",\"top\":\"\($0.rawValue)\"" } ?? "")}"
        case .buildsAndTests(let builds, let tests): return "{\"kind\":\"buildsAndTests\",\"builds\":\(builds),\"tests\":\(tests)}"
        case .bouncedBack(let count): return "{\"kind\":\"bouncedBack\",\"count\":\(count)}"
        case .focus(let minutes, let blocks): return "{\"kind\":\"focus\",\"minutes\":\(minutes),\"blocks\":\(blocks)}"
        case .activeSpan(let from, let to): return "{\"kind\":\"activeSpan\",\"from\":\(seconds(from)),\"to\":\(seconds(to))}"
        case .milestones(let count): return "{\"kind\":\"milestones\",\"count\":\(count)}"
        }
    }

    // MARK: - W18 room

    static func room() -> String {
        func unlockJSON(_ unlock: FurnitureUnlock) -> String {
            switch unlock {
            case .always: return "\"always\""
            case .friendshipLevel(let level): return "{\"level\":\(level)}"
            case .achievement(let id): return "{\"achievement\":\"\(id.rawValue)\"}"
            }
        }
        let catalog = FurnitureCatalog.all.map { k in
            var o = FixtureObject()
            o.str("id", k.id)
            o.str("title", k.title)
            o.str("placement", k.placement.rawValue)
            o.bool("isFlat", k.isFlat)
            o.num("width", k.width)
            o.num("height", k.height)
            o.raw("unlock", unlockJSON(k.unlock))
            o.num("defaultX", k.defaultX)
            o.num("defaultY", k.defaultY)
            o.str("unlockHint", k.unlockHint)
            return o.json
        }

        var unlocks: [String] = []
        let progressCases: [(Int, [AchievementID])] = [(0, []), (10, []), (25, [.firstSession]), (60, [.firstTurn, .firstGreenBuild]),
                                                       (100, [.goodFriends]), (1000, AchievementID.allCases)]
        for (points, ids) in progressCases {
            var progress = ProgressState()
            progress.affectionPoints = points
            for id in ids { progress.unlocked[id.rawValue] = start }
            unlocks.append("[\(points),\(FixtureJSON.array(ids.map { FixtureJSON.str($0.rawValue) })),\(progress.friendshipLevel),"
                           + "\(FixtureJSON.array(FurnitureCatalog.unlocked(progress).map { FixtureJSON.str($0.id) }))]")
        }

        let specials: [(String, Double)] = [("nan", .nan), ("inf", .infinity), ("-inf", -.infinity)]
        func value(_ x: Double) -> String {
            if let special = specials.first(where: { $0.1 == x || ($0.1.isNaN && x.isNaN) }) { return FixtureJSON.str(special.0) }
            return "\(x)"
        }
        var snaps: [String] = []
        for kind in FurnitureCatalog.all {
            for (x, y) in [(0.5, 0.5), (-1.0, 2.0), (0.0, 0.0), (1.0, 1.0), (0.999, 0.91), (Double.nan, 0.3), (0.3, Double.infinity),
                           (-Double.infinity, -Double.infinity)] {
                let s = RoomLayout.snapped(kind, x: x, y: y)
                snaps.append("[\"\(kind.id)\",\(value(x)),\(value(y)),\(FixtureJSON.num(s.x)),\(FixtureJSON.num(s.y))]")
            }
        }

        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        func itemsJSON(_ items: [PlacedFurniture]) -> String {
            FixtureJSON.array(items.map { "[\(FixtureJSON.str($0.id.uuidString)),\"\($0.kind)\",\(FixtureJSON.num($0.x)),\(FixtureJSON.num($0.y)),\($0.flipped)]" })
        }
        var room = RoomLayout()
        var steps: [String] = []
        var counter = 0
        func record(_ op: String, _ result: String) {
            steps.append("[\(FixtureJSON.str(op)),\(result),\(itemsJSON(room.items)),\(room.isFull),"
                         + "\(FixtureJSON.array(room.drawingOrder.map { FixtureJSON.str($0.id.uuidString) }))]")
        }
        func add(_ kindID: String, _ x: Double? = nil, _ y: Double? = nil) {
            counter += 1
            let placed = room.add(FurnitureCatalog.kind(kindID)!, x: x, y: y, id: id(counter))
            record("add \(kindID)\(x.map { " \($0)" } ?? "")\(y.map { " \($0)" } ?? "")", placed.map { FixtureJSON.str($0.id.uuidString) } ?? "null")
        }
        for kind in ["rug", "cushion", "cushion", "cushion", "poster", "poster", "clock", "plant"] { add(kind) }
        room.move(id(2), x: 0.1, y: 0.99)
        record("move 2 0.1 0.99", "null")
        room.move(id(5), x: 2, y: -1)
        record("move 5 2 -1", "null")
        room.move(UUID(uuidString: "00000000-0000-0000-0000-000000009999")!, x: 0.5, y: 0.5)
        record("move 9999 0.5 0.5", "null")
        room.toggleFlip(id(3))
        record("flip 3", "null")
        add("lamp")
        room.remove(id(1))
        record("remove 1", "null")
        add("lamp", 0.5, 0.2)
        add("toyBox")
        room.remove(id(4))
        room.remove(id(7))
        record("remove 4 and 7", "null")
        add("beanbag")
        add("beanbag")
        add("fishBowl")

        var messy = RoomLayout()
        for (n, kind, x, y) in [(1, "rug", 0.5, 0.2), (2, "sofa", 0.5, 0.9), (3, "poster", -3.0, 0.9), (4, "lamp", 0.5, 0.5),
                                (5, "clock", 0.5, 0.1), (6, "plant", 2.0, 0.89), (7, "photo", 0.3, 0.3), (8, "toyBox", 0.4, 0.95),
                                (9, "catTree", 0.6, 0.87), (10, "beanbag", 0.7, 0.88), (11, "cushion", 0.2, 0.9)] as [(Int, String, Double, Double)] {
            messy.items.append(PlacedFurniture(id: id(n), kind: kind, x: x, y: y, flipped: n % 2 == 0))
        }
        let clean = messy.sanitized()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(data: try! encoder.encode(clean), encoding: .utf8)!

        var root = FixtureObject()
        root.str("about", "W18, TamagotchiCore's FurnitureCatalog and RoomLayout (mochi_world's must match). catalog: every piece. unlocks: "
                 + "[affectionPoints, achievements unlocked, friendship level, unlocked piece ids]. snapped: [kind, x, y, snapped x, "
                 + "snapped y] (\"nan\"/\"inf\"/\"-inf\" for non-finite inputs). steps: one RoomLayout changed in order (pieces added "
                 + "with ids 00000000-0000-0000-0000-00000000000N, N counting adds from 1; add without x and y uses freeSpot), each step "
                 + "[op, the added id or null, items [id, kind, x, y, flipped], isFull, drawingOrder ids]. messy: a layout with "
                 + "unknown kinds, out-of-band positions and too many pieces; sanitized: its sanitized() items, and encoded: that "
                 + "layout as the Mac stores it.")
        root.list("catalog", catalog, omitEmpty: false, multiline: true)
        root.list("unlocks", unlocks, omitEmpty: false, multiline: true)
        root.list("snapped", snaps, omitEmpty: false, multiline: true)
        root.list("steps", steps, omitEmpty: false, multiline: true)
        root.raw("messy", itemsJSON(messy.items))
        root.raw("sanitized", itemsJSON(clean.items))
        root.raw("encoded", encoded)
        return root.json
    }

    // MARK: - W20 seasons

    static func seasons() -> String {
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }
        let first = date(2025, 1, 1)
        let last = date(2031, 1, 3)
        var variants: [String] = []
        func variant(_ note: String, configure: (inout SeasonalSettings) -> Void = { _ in }, adopted: Date? = nil) {
            var settings = SeasonalSettings()
            configure(&settings)
            var runs: [String] = []
            var overlaps: [String] = []
            var previous: SeasonalEvent?? = .none
            var day = first
            while day < last {
                let event = SeasonCalendar.event(on: day, settings: settings, mochiBirthday: adopted, calendar: utc)
                if previous == nil || previous! != event {
                    runs.append("[\(FixtureJSON.str(DailyRecap.dayKey(day, calendar: utc))),\(event.map { FixtureJSON.str($0.rawValue) } ?? "null")]")
                    previous = .some(event)
                }
                let active = SeasonCalendar.activeEvents(on: day, settings: settings, mochiBirthday: adopted, calendar: utc)
                if active.count > 1 {
                    overlaps.append("[\(FixtureJSON.str(DailyRecap.dayKey(day, calendar: utc))),\(FixtureJSON.array(active.map { FixtureJSON.str($0.rawValue) }))]")
                }
                day = utc.date(byAdding: .day, value: 1, to: day)!
            }
            var samples: [String] = []
            for sample in [date(2025, 1, 1), date(2025, 2, 12), date(2025, 10, 18), date(2025, 10, 30), date(2026, 3, 1), date(2026, 11, 8),
                           date(2026, 12, 20), date(2026, 12, 31), date(2027, 2, 28), date(2028, 2, 28), date(2028, 2, 29),
                           date(2030, 12, 25), date(2031, 1, 1)].map({ $0.addingTimeInterval(13 * 3600) }) {
                var o = FixtureObject()
                o.raw("at", seconds(sample))
                if let next = SeasonCalendar.nextEvent(after: sample, settings: settings, mochiBirthday: adopted, calendar: utc) {
                    o.raw("next", "[\(FixtureJSON.str(next.event.rawValue)),\(seconds(next.starts))]")
                } else {
                    o.raw("next", "null")
                }
                if let event = SeasonCalendar.event(on: sample, settings: settings, mochiBirthday: adopted, calendar: utc) {
                    o.str("event", event.rawValue)
                    o.optionalNum("lastDay", SeasonCalendar.lastDay(of: event, from: sample, settings: settings, mochiBirthday: adopted,
                                                                    calendar: utc)?.timeIntervalSince1970)
                    o.str("key", SeasonCalendar.occasionKey(event, on: sample, calendar: utc))
                }
                samples.append(o.json)
            }
            var o = FixtureObject()
            o.str("note", note)
            o.bool("enabled", settings.enabled, default: true)
            o.optionalInt("birthdayMonth", settings.birthdayMonth)
            o.optionalInt("birthdayDay", settings.birthdayDay)
            if let adopted { o.raw("adopted", seconds(adopted)) }
            o.list("runs", runs, omitEmpty: false, multiline: true)
            o.list("overlaps", overlaps, omitEmpty: false)
            o.list("samples", samples, omitEmpty: false, multiline: true)
            variants.append(o.json)
        }
        variant("the calendar alone")
        variant("a birthday on Halloween and Mochi adopted on Diwali 2026", configure: {
            $0.birthdayMonth = 10
            $0.birthdayDay = 31
        }, adopted: date(2026, 11, 8).addingTimeInterval(20 * 3600))
        variant("a leap-day birthday and a leap-day adoption", configure: {
            $0.birthdayMonth = 2
            $0.birthdayDay = 29
        }, adopted: date(2024, 2, 29).addingTimeInterval(9 * 3600))
        variant("an impossible birthday (31 February) and Christmas Eve adoption", configure: {
            $0.birthdayMonth = 2
            $0.birthdayDay = 31
        }, adopted: date(2025, 12, 24))
        variant("decorations off", configure: {
            $0.enabled = false
            $0.birthdayMonth = 1
            $0.birthdayDay = 1
        })

        let keyDates = [date(2026, 12, 31), date(2027, 1, 1), date(2026, 6, 30), date(2026, 7, 1), date(2026, 10, 31)]
        var keys: [String] = []
        for d in keyDates {
            for event in SeasonalEvent.allCases {
                keys.append("[\(seconds(d)),\"\(event.rawValue)\",\(FixtureJSON.str(SeasonCalendar.occasionKey(event, on: d, calendar: utc)))]")
            }
        }
        let years = [(date(2025, 11, 8), date(2026, 11, 8)), (date(2025, 12, 31), date(2026, 1, 1)), (date(2026, 1, 1), date(2025, 1, 1)),
                     (date(2020, 2, 29), date(2031, 2, 28))].map {
            "[\(seconds($0.0)),\(seconds($0.1)),\(SeasonCalendar.yearsSince($0.0, on: $0.1, calendar: utc))]"
        }
        var root = FixtureObject()
        root.str("about", "W20, TamagotchiCore's SeasonCalendar with a UTC calendar (mochi_world's must match). Each variant's settings "
                 + "(and adoption date, the pet's birthday) are checked for every day from 2025-01-01 to 2031-01-02: runs lists each "
                 + "day the shown event changes [yyyy-MM-dd, event|null], overlaps the days with more than one active event (highest "
                 + "priority first); samples at 13:00 UTC give nextEvent, the event, its lastDay and occasionKey. keys: occasionKey "
                 + "[date, event, key]; years: yearsSince [start, date, years].")
        root.list("variants", variants, omitEmpty: false, multiline: true)
        root.list("keys", keys, omitEmpty: false, multiline: true)
        root.list("years", years, omitEmpty: false)
        root.raw("diwali", "{" + SeasonCalendar.diwaliDates.keys.sorted().map { year in
            let c = SeasonCalendar.diwaliDates[year]!
            return "\"\(year)\":[\(c.month!),\(c.day!)]"
        }.joined(separator: ",") + "}")
        return root.json
    }
}
