import CoreGraphics
import Foundation
import Testing
@testable import TamagotchiCore

/// Mochi on the menu bar: deterministic, continuous, inside its zone, considerate of other
/// apps' icons, and obedient to the context rules (sessions, reactions, popover, quiet hours,
/// Reduced Motion, games the user asks for).
@Suite("Menu bar roaming")
struct RoamingTests {
    /// The geometry measured on a notched MacBook: free bar from the notch to the status item,
    /// other apps' icons from the item to the clock (which Mochi never reaches).
    static let zone = RoamZone(minX: 836.5, maxX: 1_278, homeX: 962, companionX: 938, occupied: [978...1_470])

    /// Runs a roamer at the world's 4 Hz tick and samples it like a renderer.
    @discardableResult
    static func simulate(seed: UInt64 = 7, seconds: Double, zone: RoamZone = zone, start: Double = 1_000, fps: Double = 30,
                         place: Double? = nil, context: (Double) -> RoamContext = { _ in RoamContext() },
                         visit: (Double, RoamSample, MenuBarRoamer) -> Void) -> MenuBarRoamer {
        var roamer = MenuBarRoamer(seed: seed)
        roamer.setZone(zone, now: start, context: context(0))
        if let place {
            roamer.place(at: place, now: start)
            roamer.update(now: start, context: context(0))
        }
        var t = start
        var nextTick = start
        let step = 1.0 / fps
        while t < start + seconds {
            if t >= nextTick {
                roamer.update(now: t, context: context(t - start))
                nextTick += 0.25
            }
            visit(t - start, roamer.sample(at: t), roamer)
            t += step
        }
        return roamer
    }

    static let maxStep = MenuBarRoamer.Speed.dash / 30 * 1.1 + 0.01

    // MARK: Determinism and continuity

    @Test func sameSeedSamePath() {
        var first: [Double] = []
        var second: [Double] = []
        var other: [Double] = []
        Self.simulate(seed: 11, seconds: 600) { _, sample, _ in first.append(sample.x) }
        Self.simulate(seed: 11, seconds: 600) { _, sample, _ in second.append(sample.x) }
        Self.simulate(seed: 12, seconds: 600) { _, sample, _ in other.append(sample.x) }
        #expect(first == second)
        #expect(first != other)
    }

    @Test func staysInsideTheZone() {
        for seed in [1, 2, 3] as [UInt64] {
            Self.simulate(seed: seed, seconds: 1_200) { _, sample, _ in
                #expect(sample.x >= Self.zone.minX - 0.001 && sample.x <= Self.zone.maxX + 0.001)
                for prop in sample.props {
                    #expect(prop.x >= Self.zone.minX - 25 && prop.x <= Self.zone.maxX + 25)
                    #expect(prop.y >= -0.01 && prop.y <= 40)
                    #expect(prop.opacity >= -0.001 && prop.opacity <= 1.001)
                }
            }
        }
    }

    @Test func neverTeleports() {
        for seed in [4, 5, 6] as [UInt64] {
            var last: RoamSample?
            Self.simulate(seed: seed, seconds: 1_200) { _, sample, roamer in
                if let last { #expect(abs(sample.x - last.x) <= Self.maxStep, "jumped \(sample.x - last.x)") }
                last = sample
                // Every segment starts where (and when) the previous one ended.
                for (a, b) in zip(roamer.segments, roamer.segments.dropFirst()) {
                    #expect(abs(b.fromX - a.toX) < 1e-6)
                    #expect(b.start >= a.end - 1e-6)
                    #expect(abs(b.lift - a.liftTo) < 1e-6)
                }
            }
        }
    }

    /// Travel eases in and out: no jump from standing to full speed (or back) between two frames.
    @Test func speedChangesSmoothly() {
        for seed in [8, 9] as [UInt64] {
            var last: RoamSample?
            var worst = 0.0
            var fastest = 0.0
            Self.simulate(seed: seed, seconds: 900, fps: 60) { _, sample, _ in
                defer { last = sample }
                fastest = max(fastest, sample.speed)
                guard let last else { return }
                worst = max(worst, abs(sample.speed - last.speed))
            }
            #expect(fastest > MenuBarRoamer.Speed.run * 0.9)
            #expect(worst < 26, "speed jumped by \(worst) pt/s in one frame")
        }
    }

    @Test func liftNeverPops() {
        var last: RoamSample?
        var context = RoamContext()
        Self.simulate(seed: 3, seconds: 1_800, fps: 60, context: { time in
            // A nap in bed, a reaction while asleep, waking up again.
            context.asleep = time > 200 && time < 400
            context.reacting = time > 300 && time < 303
            context.quietHours = time > 600
            return context
        }) { _, sample, _ in
            defer { last = sample }
            guard let last, sample.style != .drop, last.style != .drop else { return }
            // Turning around is a tiny hop (1.3 pt in a tenth of a second); anything faster is a pop.
            #expect(abs(sample.lift - last.lift) < 0.45, "lift popped \(last.lift) → \(sample.lift) (\(sample.activity.rawValue))")
        }
    }

    @Test func propsMoveContinuously() {
        for seed in [3, 14, 15] as [UInt64] {
            var last: [SceneProp.Kind: RoamPropSample] = [:]
            Self.simulate(seed: seed, seconds: 1_800, fps: 120) { _, sample, _ in
                var seen: [SceneProp.Kind: RoamPropSample] = [:]
                for prop in sample.props where prop.kind != .crumb { seen[prop.kind] = prop }
                for (kind, prop) in seen {
                    if let before = last[kind], before.opacity > 0.05, prop.opacity > 0.05 {
                        #expect(abs(prop.x - before.x) < 2.0, "\(kind) jumped \(prop.x - before.x)")
                        #expect(abs(prop.y - before.y) < 2.0, "\(kind) jumped \(prop.y - before.y)")
                    }
                }
                last = seen
            }
        }
    }

    @Test func actuallyRoamsWithRestsBetweenBursts() {
        var travelled = 0.0
        var last: Double?
        var minX = Double.infinity
        var maxX = -Double.infinity
        var activities = Set<RoamActivity>()
        var restRun = 0.0
        var rests: [Double] = []
        Self.simulate(seed: 21, seconds: 1_800) { _, sample, _ in
            if let last { travelled += abs(sample.x - last) }
            last = sample.x
            minX = min(minX, sample.x)
            maxX = max(maxX, sample.x)
            activities.insert(sample.activity)
            if sample.activity == .rest {
                restRun += 1.0 / 30
            } else if restRun > 0 {
                rests.append(restRun)
                restRun = 0
            }
        }
        #expect(travelled > 2_000)
        // All along the bar: from the notch side right across the icons.
        #expect(maxX - minX > Self.zone.width * 0.6)
        #expect(activities.subtracting([.rest, .wander, .trotHome]).count >= 4)
        // Rests of roughly 15–60 s between bursts.
        let long = rests.filter { $0 > 8 }
        #expect(long.count >= 10)
        #expect(long.allSatisfy { $0 < 75 })
    }

    @Test func playBringsProps() {
        var kinds = Set<SceneProp.Kind>()
        Self.simulate(seed: 3, seconds: 3_600) { _, sample, _ in
            for prop in sample.props { kinds.insert(prop.kind) }
        }
        #expect(kinds.count >= 3)
        #expect(kinds.isSubset(of: [.ball, .yarn, .butterfly, .leaf]))
    }

    /// Mochi plays across other apps' icons but only lingers where the bar is free: at most a
    /// tenth of its standing-still time is over an icon (short pauses mid-game), and it never
    /// rests, naps, sniffs or fidgets there.
    @Test func lingersOnlyWhereTheBarIsFree() {
        for seed in [1, 2, 3, 4, 5] as [UInt64] {
            var still = 0.0
            var stillOverIcons = 0.0
            var overIcons = 0.0
            Self.simulate(seed: seed, seconds: 1_800) { _, sample, _ in
                if Self.zone.isOccupied(sample.x) { overIcons += 1.0 / 30 }
                guard sample.speed < 0.5 else { return }
                still += 1.0 / 30
                guard Self.zone.isOccupied(sample.x) else { return }
                stillOverIcons += 1.0 / 30
                let lingering: Set<RoamActivity> = [.rest, .nap, .sleepAtHome, .sniffAround, .fidget]
                #expect(!lingering.contains(sample.activity) || sample.isOneShot && sample.animation == .wakeUp,
                        "\(sample.activity.rawValue) \(sample.animation.rawValue) over an icon at \(sample.x)")
            }
            #expect(stillOverIcons / still <= 0.1, "seed \(seed): \(stillOverIcons / still) of the still time over icons")
            // …but it does visit them.
            #expect(overIcons > 20)
        }
    }

    // MARK: Context rules

    @Test func reducedMotionKeepsMochiAtHome() {
        let context = RoamContext(reducedMotion: true)
        Self.simulate(seconds: 900, context: { _ in context }) { _, sample, _ in
            #expect(abs(sample.x - Self.zone.homeX) < 0.001)
            #expect(sample.props.isEmpty)
            #expect(sample.lift == 0)
        }
        // Switching it on while away: an invisible move home, then nothing but expressions.
        Self.simulate(seconds: 300, place: 1_200, context: { _ in context }) { time, sample, _ in
            if time > 1.0 { #expect(abs(sample.x - Self.zone.homeX) < 0.001) }
            if abs(sample.x - Self.zone.homeX) > 0.001, abs(sample.x - 1_200) > 0.001 { Issue.record("walked with reduced motion") }
        }
    }

    /// Reduced Motion while far away and Claude waits, Mochi sleeps or the popover opens:
    /// never any visible travel.
    @Test func reducedMotionNeverTravelsWhateverTheMode() {
        let modes: [RoamContext] = [
            RoamContext(companionPresent: true, activity: .waiting, reducedMotion: true),
            RoamContext(asleep: true, reducedMotion: true),
            RoamContext(popoverOpen: true, reducedMotion: true),
            RoamContext(companionPresent: true, activity: .working, reducedMotion: true),
        ]
        for context in modes {
            Self.simulate(seconds: 120, place: 1_200, context: { _ in context }) { _, sample, _ in
                let atStart = abs(sample.x - 1_200) < 0.001
                let atHome = abs(sample.x - Self.zone.homeX) < 0.001
                #expect(atStart || atHome, "travelled to \(sample.x) with reduced motion")
                #expect(!sample.isTravelling)
            }
        }
    }

    @Test func busySessionsKeepMochiNearHome() {
        for activity in [AmbientActivity.working, .waiting] {
            let context = RoamContext(companionPresent: true, activity: activity)
            var last: Double?
            Self.simulate(seconds: 900, place: 1_250, context: { _ in context }) { time, sample, _ in
                if let last { #expect(abs(sample.x - last) <= Self.maxStep) }
                last = sample.x
                if time > 12 {
                    #expect(abs(sample.x - Self.zone.homeX) <= MenuBarRoamer.nearHomeRadius + 0.001)
                    #expect(sample.props.isEmpty)
                    if activity == .waiting { #expect(abs(sample.x - Self.zone.homeX) < 0.001) }
                }
            }
        }
        // Patch around but idle: stays near home too, and sits facing Patch when resting.
        let companion = RoamContext(companionPresent: true)
        Self.simulate(seconds: 900, context: { _ in companion }) { _, sample, _ in
            #expect(abs(sample.x - Self.zone.homeX) <= MenuBarRoamer.nearHomeRadius + 0.001)
            if sample.activity == .sitWithCompanion { #expect(sample.facing == Self.zone.companionSide) }
        }
    }

    /// Waiting for the user: a wave, then a calm, attentive watch, and one reminder wave a minute (at most ten).
    @Test func waitingWavesThenWatchesCalmly() {
        let context = RoamContext(companionPresent: true, activity: .waiting)
        var waving = 0.0
        var attentive = 0.0
        var waves = 0
        var wasWaving = false
        Self.simulate(seconds: 900, context: { _ in context }) { time, sample, _ in
            let wave = sample.animation == .waveGently
            if wave, !wasWaving { waves += 1 }
            wasWaving = wave
            guard time > 1 else { return }
            if wave { waving += 1.0 / 30 }
            if sample.style == .attentive { attentive += 1.0 / 30 }
            if time > 1, time < 9 { #expect(wave) }
            if time > 12, time < 60 { #expect(!wave) }
        }
        #expect(waves == 11)
        #expect(waving < 8.4 + 10 * 4.2 + 1)
        #expect(attentive > 800)
    }

    @Test func reactionsFreezeTravelAndResumeContinuously() {
        // Find a moment when Mochi is travelling, then react there.
        var reactAt: Double?
        Self.simulate(seed: 9, seconds: 400) { time, sample, _ in
            if reactAt == nil, time > 20, sample.isTravelling { reactAt = time }
        }
        guard let reactAt else { Issue.record("never travelled"); return }
        var frozenX: Double?
        var last: Double?
        var movedAfter = false
        Self.simulate(seed: 9, seconds: reactAt + 60, context: { time in
            RoamContext(reacting: time >= reactAt && time < reactAt + 3)
        }) { time, sample, _ in
            if let last { #expect(abs(sample.x - last) <= Self.maxStep) }
            if time >= reactAt + 0.3, time < reactAt + 3 {
                if frozenX == nil { frozenX = sample.x }
                #expect(sample.x == frozenX)
            }
            if time > reactAt + 3.5, let frozenX, abs(sample.x - frozenX) > 1 { movedAfter = true }
            last = sample.x
        }
        #expect(frozenX != nil)
        #expect(movedAfter)
    }

    @Test func openingThePopoverStopsTravel() {
        var openAt: Double?
        Self.simulate(seed: 13, seconds: 400) { time, sample, _ in
            if openAt == nil, time > 20, sample.isTravelling { openAt = time }
        }
        guard let openAt else { Issue.record("never travelled"); return }
        var settled: Double?
        Self.simulate(seed: 13, seconds: openAt + 40, context: { time in RoamContext(popoverOpen: time >= openAt) }) { time, sample, _ in
            guard time > openAt + 6 else { return }
            if settled == nil { settled = sample.x }
            #expect(sample.x == settled)
            #expect(sample.animation == .watch)
        }
    }

    @Test func quietHoursMakeMochiSleepier() {
        func sleepyShare(_ quiet: Bool) -> Double {
            var sleepy = 0.0
            var total = 0.0
            Self.simulate(seed: 17, seconds: 7_200, context: { _ in RoamContext(quietHours: quiet) }) { _, sample, _ in
                total += 1
                if sample.animation == .curl || sample.animation == .sleep { sleepy += 1 }
            }
            return sleepy / total
        }
        let normal = sleepyShare(false)
        let quiet = sleepyShare(true)
        #expect(quiet > normal * 2)
        #expect(quiet > 0.2)
    }

    @Test func sleepingHappensInTheBedAtHome() {
        Self.simulate(seconds: 120, place: 1_200, context: { _ in RoamContext(asleep: true) }) { time, sample, _ in
            if sample.animation == .sleep {
                #expect(abs(sample.x - Self.zone.homeX) < 0.001)
                #expect(abs(sample.lift - MenuBarRoamer.bedLift) < 0.001)
            }
            if time > 30 { #expect(sample.animation == .sleep) }
        }
    }

    @Test func summonsRunHomeFast() {
        var arrived: Double?
        Self.simulate(seconds: 20, place: 1_250, context: { _ in RoamContext(companionPresent: true, summoned: true) }) { time, sample, roamer in
            if arrived == nil, roamer.isHome(at: 1_000 + time) { arrived = time }
        }
        let distance = 1_250 - Self.zone.homeX
        #expect(arrived != nil)
        // A beat to notice, a crouch, the dash with its ease in and out.
        #expect((arrived ?? 99) < distance / MenuBarRoamer.Speed.dash + 1.0)
    }

    @Test func intensityScalesRests() {
        func restTime(_ intensity: AnimationIntensity) -> Double {
            var rest = 0.0
            Self.simulate(seed: 5, seconds: 3_600, context: { _ in RoamContext(intensity: intensity) }) { _, sample, _ in
                if sample.activity == .rest { rest += 1 }
            }
            return rest
        }
        #expect(restTime(.lively) < restTime(.calm))
    }

    @Test func freshZonesStartWithAHopIntoTheBed() {
        var roamer = MenuBarRoamer(seed: 2)
        roamer.setZone(Self.zone, now: 50, context: RoamContext())
        let start = roamer.sample(at: 50)
        #expect(abs(start.x - Self.zone.homeX) < 0.001)
        #expect(start.lift > 15)
        #expect(start.activity == .arrive)
        #expect(roamer.sample(at: 50.6).lift < 0.01)
        // Reduced Motion: just there.
        var calm = MenuBarRoamer(seed: 2)
        calm.setZone(Self.zone, now: 50, context: RoamContext(reducedMotion: true))
        #expect(calm.sample(at: 50).lift == 0)
    }

    @Test func zoneChangesNeverTeleport() {
        var roamer = MenuBarRoamer(seed: 3)
        let context = RoamContext()
        roamer.setZone(Self.zone, now: 0, context: context)
        var t = 0.0
        var last = roamer.sample(at: 0).x
        while t < 300 {
            t += 0.25
            if Int(t * 4) % 240 == 0 {
                // A status item to the right appeared or went away: the whole bar shifts a little.
                let shift = Double(Int(t) % 2 == 0 ? 24 : -24)
                roamer.setZone(roamer.zone!.shifted(by: shift), now: t, context: context)
                // Mochi either rides along in its bed or keeps its place.
                let x = roamer.sample(at: t).x
                #expect(abs(x - last) < 0.01 || abs(x - last - shift) < 0.01 || abs(x - last) <= MenuBarRoamer.Speed.dash * 0.25 + 0.01)
                last = x
            }
            roamer.update(now: t, context: context)
            let x = roamer.sample(at: t).x
            #expect(abs(x - last) <= MenuBarRoamer.Speed.dash * 0.25 + 0.01)
            last = x
        }
        // A different screen altogether: start over in the new bed.
        let elsewhere = RoamZone(minX: 2_000, maxX: 2_600, homeX: 2_400)
        roamer.setZone(elsewhere, now: t, context: context)
        #expect(abs(roamer.sample(at: t).x - 2_400) < 0.001)
    }

    /// The status item shifting a few points (the clock ticking over, another app's item
    /// resizing) must not cancel what Mochi is doing or pull it out of bed.
    @Test func smallHomeShiftsKeepTheActivityGoing() {
        // During a ball game away from home.
        var roamer = MenuBarRoamer(seed: 4)
        let context = RoamContext()
        roamer.setZone(Self.zone, now: 0, context: context)
        var t = 0.0
        for _ in 0..<8 {
            t += 0.25
            roamer.update(now: t, context: context)
        }
        roamer.place(at: 1_100, now: t)
        roamer.update(now: t, context: context)
        roamer.force(.ballPlay, now: t, context: context)
        t += 4
        roamer.update(now: t, context: context)
        #expect(roamer.sample(at: t).activity == .ballPlay)
        let before = roamer.sample(at: t)
        roamer.setZone(roamer.zone!.shifted(by: 6), now: t, context: context)
        let after = roamer.sample(at: t)
        #expect(after.activity == .ballPlay)
        #expect(abs(after.x - before.x) < 0.001)
        #expect(after.props.count == before.props.count)
        #expect(after.props.allSatisfy { $0.opacity > 0.5 } == before.props.allSatisfy { $0.opacity > 0.5 })

        // Asleep in bed: it rides along with the bed and keeps sleeping.
        var sleeper = MenuBarRoamer(seed: 5)
        let asleep = RoamContext(asleep: true)
        sleeper.setZone(Self.zone, now: 0, context: asleep)
        var s = 0.0
        while s < 20 {
            s += 0.25
            sleeper.update(now: s, context: asleep)
        }
        #expect(sleeper.sample(at: s).animation == .sleep)
        sleeper.setZone(sleeper.zone!.shifted(by: -8), now: s, context: asleep)
        let moved = sleeper.sample(at: s)
        #expect(moved.animation == .sleep)
        #expect(abs(moved.x - (Self.zone.homeX - 8)) < 0.001)
        #expect(abs(moved.lift - MenuBarRoamer.bedLift) < 0.001)
        for _ in 0..<20 {
            s += 0.25
            sleeper.update(now: s, context: asleep)
            #expect(sleeper.sample(at: s).animation == .sleep)
        }
    }

    // MARK: Games the user asks for

    static func game(_ game: RoamUserGame, from x: Double, context: RoamContext = RoamContext(), seed: UInt64 = 6)
        -> (roamer: MenuBarRoamer, start: Double, end: Double) {
        var roamer = MenuBarRoamer(seed: seed)
        roamer.setZone(Self.zone, now: 0, context: context)
        roamer.update(now: 1, context: context)
        roamer.place(at: x, now: 1)
        let before = roamer.sample(at: 1).x
        let started = roamer.startUserGame(game, now: 1, context: context)
        #expect(started)
        // The game starts exactly where Mochi was.
        #expect(abs(roamer.sample(at: 1).x - before) < 0.001)
        return (roamer, 1, roamer.userGameUntil ?? 1)
    }

    @Test func userGamesPlayAlongTheBar() {
        for game in RoamUserGame.allCases {
            for origin in [Self.zone.homeX, 900, 1_150] {
                var (roamer, start, end) = Self.game(game, from: origin)
                #expect(end - start > 3, "\(game) lasted \(end - start) s")
                #expect(end - start < 25)
                var t = start
                var last = roamer.sample(at: t)
                var kinds = Set<SceneProp.Kind>()
                var span = (lo: origin, hi: origin)
                while t < end + 1 {
                    t += 1.0 / 60
                    if Int(t * 60) % 15 == 0 { roamer.update(now: t, context: RoamContext()) }
                    let sample = roamer.sample(at: t)
                    #expect(abs(sample.x - last.x) <= MenuBarRoamer.Speed.dash / 60 * 1.1 + 0.01)
                    if t < end { #expect(sample.activity == game.activity || sample.activity == .rest) }
                    for prop in sample.props { kinds.insert(prop.kind) }
                    span = (min(span.lo, sample.x), max(span.hi, sample.x))
                    last = sample
                }
                switch game {
                case .play, .playFollowUp:
                    #expect(kinds.contains(.ball))
                    // It travels with the ball, and carries it back to bed (or somewhere free).
                    #expect(span.hi - span.lo > 30)
                    #expect(Self.zone.canLinger(at: last.x))
                case .treat:
                    #expect(kinds.contains(.treat))
                    #expect(kinds.contains(.crumb))
                case .treatFollowUp:
                    #expect(kinds.contains(.crumb))
                }
            }
        }
    }

    @Test func userGamesGiveWayOnlyToRealThings() {
        // Claude starting to work does not stop the game the user asked for…
        var (roamer, start, end) = Self.game(.play, from: 1_000)
        let working = RoamContext(companionPresent: true, activity: .working)
        roamer.update(now: start + 1, context: working)
        #expect(roamer.sample(at: start + 1.2).activity == .userPlay)
        #expect(roamer.userGameUntil == end)
        // …and once it is over, Mochi goes home to watch Patch.
        var t = end
        while t < end + 30 {
            t += 0.25
            roamer.update(now: t, context: working)
        }
        #expect(abs(roamer.sample(at: t).x - Self.zone.homeX) <= MenuBarRoamer.nearHomeRadius)
        // A real reaction stops it where Mochi is.
        var (other, otherStart, _) = Self.game(.treat, from: 1_000)
        let x = other.sample(at: otherStart + 1).x
        other.update(now: otherStart + 1, context: RoamContext(reacting: true))
        #expect(other.userGameUntil == nil)
        #expect(abs(other.sample(at: otherStart + 2).x - x) < 0.001)
        // Reduced Motion and pausing never start one.
        var calm = MenuBarRoamer(seed: 1)
        calm.setZone(Self.zone, now: 0, context: RoamContext(reducedMotion: true))
        let reduced = calm.startUserGame(.play, now: 1, context: RoamContext(reducedMotion: true))
        let paused = calm.startUserGame(.play, now: 1, context: RoamContext(paused: true))
        let popover = calm.startUserGame(.play, now: 1, context: RoamContext(popoverOpen: true))
        #expect(!reduced && !paused && !popover)
    }

    @Test func gamesNearPatchStayNearHome() {
        let context = RoamContext(companionPresent: true)
        var (roamer, start, end) = Self.game(.play, from: Self.zone.homeX, context: context)
        var t = start
        while t < end {
            t += 1.0 / 30
            if Int(t * 30) % 8 == 0 { roamer.update(now: t, context: context) }
            #expect(abs(roamer.sample(at: t).x - Self.zone.homeX) <= 90.001)
        }
    }

    // MARK: Zones

    @Test func lingerSpansAvoidOccupiedBar() {
        let zone = RoamZone(minX: 0, maxX: 300, homeX: 100, companionX: 76, occupied: [110...180, 220...260])
        #expect(zone.canLinger(at: 50))
        #expect(zone.canLinger(at: 100))
        #expect(!zone.canLinger(at: 120))
        #expect(!zone.canLinger(at: 105))
        #expect(zone.canLinger(at: 200))
        #expect(!zone.canLinger(at: 240))
        #expect(zone.nearestLinger(to: 150) == 189 || zone.nearestLinger(to: 150) == 100)
        #expect(zone.nearestLinger(to: 240) == 211 || zone.nearestLinger(to: 240) == 269)
        let spans = zone.lingerSpans
        #expect(spans.contains { $0.contains(50) })
        #expect(spans.contains { $0.contains(100) })
        #expect(!spans.contains { $0.contains(150) })
    }

    // MARK: Geometry

    static let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    static let notchLeft = CGRect(x: 0, y: 924, width: 645.5, height: 32)
    static let notchRight = CGRect(x: 824.5, y: 924, width: 645.5, height: 32)

    static func notched(item x: Double, width: Double = 30, range: Double? = nil, rightToLeft: Bool = false) -> MenuBarGeometry? {
        RoamGeometry.compute(screenFrame: screen, notchLeftArea: notchLeft, notchRightArea: notchRight,
                             barWindowFrame: CGRect(x: x - 8, y: 923, width: width + 16, height: 33),
                             itemFrame: CGRect(x: x, y: 928.5, width: width, height: 22), range: range, rightToLeft: rightToLeft)
    }

    @Test func geometryOfANotchedMenuBar() {
        let geometry = Self.notched(item: 947)
        #expect(geometry != nil)
        guard let geometry else { return }
        // From the notch to just before the clock.
        #expect(geometry.overlayFrame == CGRect(x: 824.5, y: 923, width: 1_290 - 824.5, height: 33))
        #expect(geometry.zone.homeX == 962)
        #expect(geometry.zone.companionX == 960)
        #expect(geometry.zone.minX == 824.5 + RoamGeometry.edgeMargin)
        #expect(geometry.zone.maxX == 1_470 - RoamGeometry.clockGuard - RoamGeometry.edgeMargin)
        // Everything from the item to the clock is other apps' icons; the notch side is free.
        #expect(geometry.zone.occupied == [978...1_470])
        #expect(geometry.zone.canLinger(at: 900))
        #expect(!geometry.zone.canLinger(at: 1_100))
    }

    @Test func roamingRangeAppliesOnBothSides() {
        let full = Self.notched(item: 1_040)!.zone
        let wide = Self.notched(item: 1_040, range: 420)!.zone
        let near = Self.notched(item: 1_040, range: 200)!.zone
        #expect(near.width < wide.width)
        #expect(wide.width < full.width)
        #expect(near.minX > full.minX)
        #expect(near.maxX < full.maxX)
        #expect(abs((near.homeX - near.minX) - (near.maxX - near.homeX)) < 1)
        // Against an edge the spare range goes to the other side.
        let edge = Self.notched(item: 840, range: 200)!.zone
        #expect(edge.minX == 824.5 + RoamGeometry.edgeMargin)
        #expect(edge.maxX - edge.homeX > 120)
    }

    @Test func geometryLeftOfTheNotchNeverCrossesIt() {
        // A menu-bar manager showing hidden items left of the camera housing.
        let left = Self.notched(item: 507)
        #expect(left != nil)
        guard let left else { return }
        #expect(left.zone.homeX == 522)
        #expect(left.zone.minX >= 503 + RoamGeometry.edgeMargin - 0.001)
        #expect(left.zone.maxX <= 645.5)
        #expect(left.overlayFrame.maxX <= 645.5)
        #expect(left.overlayFrame.minX >= 503 - 0.001)
        // Inside the housing itself: hidden.
        #expect(Self.notched(item: 700) == nil)
        #expect(Self.notched(item: 630) == nil)
    }

    @Test func geometryWithoutANotchStaysRightOfTheMiddle() {
        let geometry = RoamGeometry.compute(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), notchRightArea: nil,
                                            barWindowFrame: CGRect(x: 1100, y: 876, width: 40, height: 24),
                                            itemFrame: CGRect(x: 1105, y: 877, width: 30, height: 22), range: nil)
        #expect(geometry?.overlayFrame.minX == 720)
        #expect(geometry?.bandHeight == 24)
        // A crowded bar: never left of the item itself, where the app menus may be.
        let crowded = RoamGeometry.compute(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), notchRightArea: nil,
                                           barWindowFrame: CGRect(x: 600, y: 876, width: 40, height: 24),
                                           itemFrame: CGRect(x: 605, y: 877, width: 30, height: 22), range: nil)
        #expect(crowded?.overlayFrame.minX == 601)
        #expect(crowded?.zone.minX == 613)
    }

    @Test func geometryOnASecondaryDisplay() {
        // Measured: the active menu bar on an external display to the left of the built-in one,
        // whose status-bar window sits 2 pt above the screen's top edge.
        let geometry = RoamGeometry.compute(screenFrame: CGRect(x: -1920, y: 340, width: 1920, height: 1080), notchRightArea: nil,
                                            barWindowFrame: CGRect(x: -535, y: 1389, width: 46, height: 33),
                                            itemFrame: CGRect(x: -527, y: 1395, width: 30, height: 22), range: nil)
        #expect(geometry != nil)
        #expect(geometry?.overlayFrame == CGRect(x: -960, y: 1389, width: 780, height: 31))
        #expect(geometry?.zone.homeX == -512)
    }

    @Test func geometryRightToLeftIsMirrored() {
        // Status items left of the notch, app menus on the right.
        let geometry = Self.notched(item: 470, rightToLeft: true)
        #expect(geometry != nil)
        guard let geometry else { return }
        #expect(geometry.zone.homeX == 485)
        #expect(geometry.zone.companionX > geometry.zone.homeX)
        #expect(geometry.zone.maxX <= 645.5)
        #expect(geometry.zone.minX >= RoamGeometry.clockGuard)
        #expect(geometry.zone.occupied.first?.upperBound ?? 0 <= 470)
        #expect(geometry.zone.canLinger(at: 600))
        #expect(!geometry.zone.canLinger(at: 300))
    }

    @Test func geometryRejectsHiddenItems() {
        // macOS parks status items that do not fit right of the notch below the screen.
        let parked = RoamGeometry.compute(screenFrame: Self.screen, notchRightArea: Self.notchRight,
                                          barWindowFrame: CGRect(x: 0, y: -33, width: 80, height: 33),
                                          itemFrame: CGRect(x: 8, y: -27.5, width: 64, height: 22), range: nil)
        #expect(parked == nil)
    }

    @Test func stageZonesKeepPatchBesideTheBed() {
        for width in MenuBarStageWidth.allCases {
            let zone = RoamGeometry.stageZone(width: width.points)
            #expect(zone.minX >= 0 && zone.maxX <= width.points)
            #expect(zone.homeX == width.points - 11)
            #expect(zone.homeX - zone.companionX <= 26.001)
            #expect(zone.companionX >= 7)
            #expect(zone.occupied.isEmpty)
        }
    }

    // MARK: Change detection

    @Test func poseSignaturesCoverEveryChannel() {
        var signature = PoseSignature()
        signature.pet(PetPose())
        let children = Mirror(reflecting: PetPose()).children.count
        #expect(signature.values.count >= children)
        func sig(_ change: (inout PetPose) -> Void) -> [Int32] {
            var pose = PetPose()
            change(&pose)
            var s = PoseSignature()
            s.pet(pose)
            return s.values
        }
        let base = sig { _ in }
        #expect(sig { $0.lookX += 0.5 } != base)
        #expect(sig { $0.earPerk += 0.5 } != base)
        #expect(sig { $0.tailWag += 0.5 } != base)
        #expect(sig { $0.eyes = .happy } != base)
        #expect(sig { $0.held = .ball } != base)
        #expect(sig { $0.effects = [Effect(.heart, x: 0.2, y: 1)] } != base)
        #expect(sig { $0.effects = [Effect(.heart, x: 0.2, y: 1)] } != sig { $0.effects = [Effect(.heart, x: 0.5, y: 1)] })
        // Sub-pixel drifts do not count.
        #expect(sig { $0.y += 0.001 } == base)
        var companion = PoseSignature()
        companion.companion(CompanionPose())
        #expect(companion.values.count >= Mirror(reflecting: CompanionPose()).children.count)
    }
}

/// The world drives the roamer: reactions freeze it, interactions wait for Mochi to get home,
/// Play and Treat become games along the bar.
@Suite("Menu bar roaming in the world")
@MainActor
struct RoamingWorldTests {
    static let zone = RoamZone(minX: 836.5, maxX: 1_278, homeX: 962, companionX: 938, occupied: [978...1_470])

    @Test func interactionWhileFarAwayRunsHomeFirst() {
        let h = WorldHarness()
        h.world.setRoamZone(Self.zone)
        h.send("SessionStart")
        h.run(for: 6)
        #expect(h.world.companionPresent)
        h.send("UserPromptSubmit")
        h.send("PreToolUse", tool: "Edit", toolUseId: "e1")
        h.send("PostToolUse", tool: "Edit", toolUseId: "e1")
        h.run(for: 3)
        h.world.placeRoamer(at: 1_250)
        h.send("Stop", after: 0.25)
        // Not yet: Mochi dashes home first, the celebration waits.
        #expect(h.world.interaction == nil)
        #expect(h.world.pendingInteractionID == .highFive)
        #expect(h.world.roamer.mode == .summoned)
        var last = h.world.roamer.sample(at: h.clock.uptime).x
        var started: Double?
        for _ in 0..<60 {
            h.clock.advance(0.1)
            h.world.tick()
            let x = h.world.roamer.sample(at: h.clock.uptime).x
            #expect(x <= last + 0.001)
            #expect(last - x <= MenuBarRoamer.Speed.dash * 0.1 + 0.01)
            last = x
            if started == nil, h.world.interaction?.id == .highFive {
                started = h.clock.uptime
                #expect(abs(x - Self.zone.homeX) < 1.5)
            }
        }
        #expect(started != nil)
        #expect(h.world.roamer.mode == .frozen)
        h.run(for: 6)
        #expect(h.world.interaction == nil)
        #expect(h.world.roamer.mode == .companion || h.world.roamer.mode == .working)
    }

    @Test func patchArrivesAtOnceAndMochiRunsHomeToSayHello() {
        let h = WorldHarness()
        h.world.setRoamZone(Self.zone)
        h.run(for: 2)
        h.world.placeRoamer(at: 1_200)
        h.send("SessionStart", after: 0.25) { $0.source = "startup" }
        // Patch never waits for Mochi.
        #expect(h.world.companionPresent)
        #expect(h.world.companion.current.animation == .arrive)
        #expect(h.world.pendingInteractionID == nil)
        // Mochi heads home…
        #expect(h.world.roamer.mode == .summoned)
        var greeted = false
        for _ in 0..<(8 * 10) {
            h.clock.advance(0.1)
            h.world.tick()
            if h.world.pet.current.animation == .greet, h.world.pet.isPlayingOneShot {
                greeted = true
                #expect(abs(h.world.roamer.sample(at: h.clock.uptime).x - Self.zone.homeX) < 1.5)
                break
            }
        }
        // …and says hello beside him.
        #expect(greeted)
        h.run(for: 6)
        #expect(abs(h.world.roamer.sample(at: h.clock.uptime).x - Self.zone.homeX) <= MenuBarRoamer.nearHomeRadius)
    }

    @Test func interactionNearHomeStartsRightAway() {
        let h = WorldHarness()
        h.world.setRoamZone(Self.zone)
        h.send("SessionStart")
        h.run(for: 6)
        h.send("UserPromptSubmit")
        h.run(for: 2)
        h.send("Stop")
        #expect(h.world.interaction?.id == .highFive)
        #expect(h.world.roamer.mode == .frozen)
    }

    /// A real event's interaction that never happens (Patch left, reactions paused, the zone went
    /// away) still shows: dropped ones fall back to the pet's own reaction, a removed zone starts it at once.
    @Test func deferredReactionsAreNeverLost() {
        func farAwayTurnEnd(_ settings: AppSettings = AppSettings()) -> WorldHarness {
            let h = WorldHarness(settings: settings)
            h.world.setRoamZone(Self.zone)
            h.send("SessionStart")
            h.run(for: 6)
            h.send("UserPromptSubmit")
            h.run(for: 3)
            h.world.placeRoamer(at: 1_250)
            h.send("Stop", after: 0.25)
            #expect(h.world.pendingInteractionID == .highFive)
            return h
        }
        // The zone goes away (classic icon): the high five starts at once.
        let removed = farAwayTurnEnd()
        removed.world.setRoamZone(nil)
        #expect(removed.world.pendingInteractionID == nil)
        #expect(removed.world.interaction?.id == .highFive)
        // Pausing reactions drops it quietly.
        let paused = farAwayTurnEnd()
        paused.world.settings.pauseReactions = true
        paused.run(for: 0.5)
        #expect(paused.world.pendingInteractionID == nil)
        #expect(paused.world.interaction == nil)
        // Patch leaving drops it, and the pet still reacts to the real event.
        var settings = AppSettings()
        settings.companionVisibility = .duringSessions
        settings.companionLingerMinutes = 0
        let gone = farAwayTurnEnd(settings)
        gone.send("SessionEnd", after: 0.1)
        gone.run(for: 0.5)
        #expect(gone.world.pendingInteractionID == nil)
        #expect(gone.world.pet.isPlayingOneShot)
        #expect(gone.world.pet.current.animation == .victory)
    }

    @Test func pettingFreezesTravel() {
        let h = WorldHarness()
        h.world.setRoamZone(Self.zone)
        var travelling = false
        for _ in 0..<(400 * 4) {
            h.clock.advance(0.25)
            h.world.tick()
            if h.world.roamer.sample(at: h.clock.uptime).isTravelling, h.world.interaction == nil, !h.world.pet.isPlayingOneShot {
                travelling = true
                break
            }
        }
        #expect(travelling)
        h.world.interact(.pet)
        #expect(h.world.roamer.mode == .frozen)
        let x = h.world.roamer.sample(at: h.clock.uptime).x
        for _ in 0..<6 {
            h.clock.advance(0.25)
            h.world.tick()
            #expect(h.world.roamer.sample(at: h.clock.uptime).x == x)
        }
        h.run(for: 4)
        #expect(h.world.roamer.mode != .frozen)
    }

    /// Play and Treat from the menu bar become games along it; from the popover they play in
    /// place and a short follow-up runs once it closes.
    @Test func playAndTreatUseTheBar() {
        let h = WorldHarness()
        h.world.setRoamZone(Self.zone)
        h.run(for: 3)
        h.world.interact(.play)
        #expect(h.world.roamer.userGameUntil != nil)
        #expect(h.world.roamer.mode != .frozen)
        #expect(h.world.roamer.sample(at: h.clock.uptime + 0.5).activity == .userPlay)
        #expect(h.world.pet.current.animation == .play)
        h.run(for: 20)
        h.world.interact(.treat)
        #expect(h.world.roamer.sample(at: h.clock.uptime + 0.5).activity == .userTreat)
        h.run(for: 15)

        h.world.setPopoverVisible(true)
        h.run(for: 1)
        h.world.interact(.play)
        #expect(h.world.roamer.userGameUntil == nil)
        #expect(h.world.roamer.mode == .frozen || h.world.roamer.mode == .lookingUp)
        h.run(for: 2)
        h.world.setPopoverVisible(false)
        #expect(h.world.roamer.userGameUntil != nil)
        #expect(h.world.roamer.sample(at: h.clock.uptime + 0.5).activity == .followUpPlay)

        // Petting during a game stops it where Mochi is.
        h.run(for: 1)
        h.world.interact(.pet)
        #expect(h.world.roamer.mode == .frozen)
        #expect(h.world.roamer.userGameUntil == nil)
    }

    @Test func ambientFidgetsOnlyStartDuringRests() {
        let h = WorldHarness()
        h.world.setRoamZone(Self.zone)
        var token: Int?
        var solos = 0
        for _ in 0..<(1_800 * 4) {
            h.clock.advance(0.25)
            h.world.tick()
            let current = h.world.pet.current
            guard h.world.pet.isPlayingOneShot, current.priority == .ambient, current.token != token else { continue }
            token = current.token
            guard current.animation != .yawn else { continue }
            solos += 1
            #expect(h.world.roamer.isResting(at: current.startedAt, for: min(4.5, current.duration ?? 4.5)),
                    "\(current.animation.rawValue) started while Mochi was \(h.world.roamer.sample(at: current.startedAt).activity.rawValue)")
        }
        #expect(solos >= 3)
    }

    @Test func withoutAZoneNothingChanges() {
        let h = WorldHarness()
        h.send("SessionStart")
        h.run(for: 60)
        #expect(!h.world.roamer.isActive)
        #expect(h.world.pendingInteractionID == nil)
        h.world.interact(.play)
        #expect(h.world.roamer.userGameUntil == nil)
    }
}

/// The menu-bar settings survive upgrades and bad values.
@Suite("Menu bar settings")
struct MenuBarSettingsTests {
    @Test func defaultsAndUpgrades() {
        let fresh = AppSettings.decodeTolerantly(Data("{}".utf8))
        #expect(fresh.menuBarStyle == .roam)
        #expect(fresh.menuBarRoamRange == .full)
        #expect(fresh.menuBarStageWidth == .medium)
        // Someone who chose the static classic icon keeps a classic icon.
        let staticIcon = AppSettings.decodeTolerantly(Data(#"{"menuBarAnimation": "off"}"#.utf8))
        #expect(staticIcon.menuBarStyle == .icon)
        let subtle = AppSettings.decodeTolerantly(Data(#"{"menuBarAnimation": "subtle"}"#.utf8))
        #expect(subtle.menuBarStyle == .roam)
        // An explicit choice always wins.
        let chosen = AppSettings.decodeTolerantly(Data(#"{"menuBarAnimation": "off", "menuBarStyle": "stage"}"#.utf8))
        #expect(chosen.menuBarStyle == .stage)
    }

    @Test func unknownValuesResetOnlyThemselves() {
        let data = Data(#"{"menuBarStyle": "dance", "menuBarRoamRange": "galaxy", "menuBarStageWidth": 12, "petName": "Bean"}"#.utf8)
        let settings = AppSettings.decodeTolerantly(data)
        #expect(settings.menuBarStyle == .roam)
        #expect(settings.menuBarRoamRange == .full)
        #expect(settings.menuBarStageWidth == .medium)
        #expect(settings.petName == "Bean")
        let near = AppSettings.decodeTolerantly(Data(#"{"menuBarRoamRange": "near", "menuBarStageWidth": "large"}"#.utf8))
        #expect(near.menuBarRoamRange == .near)
        #expect(near.menuBarStageWidth == .large)
    }
}
