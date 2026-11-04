import Foundation

/// Mochi's life along the menu bar: where it is (in screen points) and what it is
/// doing, as a timeline of continuous segments that are pure functions of time.
///
/// - Deterministic: every choice comes from a seeded SplitMix64.
/// - Never teleports: each segment starts where the previous one ended, and a
///   context change cuts the plan at the current position and continues from there
///   (braking out of a run rather than stopping dead).
/// - Considerate: it runs, leaps and plays across other apps' status items, but only
///   rests, naps, sniffs and fidgets where the bar is free (or in its bed), and never
///   goes near the clock.
/// - Honest: Claude only decides *where* Mochi stays (beside Patch while a session
///   is busy or waiting); real reactions freeze travel while the world plays them.
/// - Lively but not frantic: rests of roughly 15–60 s between 4–20 s bursts of play,
///   scaled by the animation intensity.
public struct MenuBarRoamer: Equatable, Sendable {
    /// Travel speeds in points per second (Mochi is ~17 pt wide on the bar).
    public enum Speed {
        public static let walk = 24.0
        public static let trot = 44.0
        public static let run = 84.0
        public static let zoom = 110.0
        public static let dash = 130.0
    }

    /// While a session is busy or Patch is around, Mochi stays this close to home.
    public static let nearHomeRadius = 60.0
    /// Within this distance of home Mochi counts as beside Patch: interactions start in place.
    public static let besideDistance = 15.0
    /// Height of the bed cushion Mochi sleeps on (points).
    public static let bedLift = 1.6
    /// The longest Mochi pauses on top of another app's status item.
    public static let maxPauseOverIcons = 1.4
    /// The plan always reaches at least this far into the future, so renderers never wait for a tick.
    static let lookahead: TimeInterval = 1.0

    public private(set) var zone: RoamZone?
    public private(set) var mode: RoamMode = .inactive
    public private(set) var segments: [RoamSegment] = []
    public private(set) var props: [RoamPropTrack] = []
    /// A game the user asked for plays until then; context changes that yield to it wait.
    public private(set) var userGameUntil: TimeInterval?
    private var rng: SplitMix64
    private var recent: [RoamActivity] = []

    public init(seed: UInt64) {
        rng = SplitMix64(seed: seed ^ 0x524F_414D_4D4F_4348)
    }

    public var isActive: Bool { zone != nil }

    // MARK: Driving

    /// Sets (or clears) the strip Mochi may use. When the bar only shifted, Mochi keeps
    /// doing what it was doing (riding along if it is in its bed); a zone somewhere else
    /// entirely (another display, launch) starts over with a hop down into the bed.
    public mutating func setZone(_ newZone: RoamZone?, now: TimeInterval, context: RoamContext) {
        guard newZone != zone else { return }
        let old = zone
        zone = newZone
        guard let newZone else {
            mode = .inactive
            props = []
            userGameUntil = nil
            return
        }
        guard let old, !segments.isEmpty else {
            restart(at: now, context: context, zone: newZone)
            return
        }
        var current = sample(at: now).x
        let dHome = newZone.homeX - old.homeX
        if abs(dHome) > 0.01 {
            shiftHomeAnchored(by: dHome, oldHome: old.homeX, now: now, riding: abs(current - old.homeX) < 3)
            props = props.map { $0.shiftingKeys(near: old.homeX, by: dHome, after: now) }
            current = sample(at: now).x
        }
        // Somewhere else altogether, or out of the new range: start over in the bed.
        if !newZone.holds(current), current < newZone.minX - 0.5 || current > newZone.maxX + 0.5 {
            restart(at: now, context: context, zone: newZone)
            return
        }
        let futureOutside = segments.contains { segment in
            segment.end > now && !segment.hidden && (!newZone.holds(segment.toX) || !newZone.holds(segment.curveToX)
                || (segment.start > now && !newZone.holds(segment.fromX)))
        }
        // A long rest that now sits on another app's item moves on.
        let restingOnIcons: Bool = {
            guard !newZone.canLinger(at: current), !(newZone.den?.shelters(current) ?? false), mode != .away,
                  let segment = segments.last(where: { $0.start <= now }), segment.motion == .hold,
                  segment.end - now > Self.maxPauseOverIcons else { return false }
            return true
        }()
        if futureOutside || restingOnIcons {
            userGameUntil = nil
            replan(at: now, to: RoamMode.from(context), context: context, zone: newZone)
        }
        update(now: now, context: context)
    }

    /// Advances the plan: re-plans when the context asks for a different behaviour and
    /// keeps the timeline extended. Mutates only when something actually changes.
    public mutating func update(now: TimeInterval, context: RoamContext) {
        guard let zone else { return }
        let desired = RoamMode.from(context)
        if let until = userGameUntil {
            if now >= until {
                userGameUntil = nil
                replan(at: now, to: desired, context: context, zone: zone)
            } else if !desired.yieldsToUserGames {
                // A real reaction, the popover, a summons…: the game stops where Mochi is.
                userGameUntil = nil
                replan(at: now, to: desired, context: context, zone: zone)
            }
        } else if desired != mode || segments.isEmpty || denCalls(now: now, context: context, zone: zone) {
            replan(at: now, to: desired, context: context, zone: zone)
        }
        prune(now: now)
        var guardrail = 0
        while let last = segments.last, last.end.isFinite, last.end < now + Self.lookahead, guardrail < 8 {
            appendChunk(start: Swift.max(last.end, now), context: context, zone: zone)
            guardrail += 1
        }
    }

    /// Starts a game the user asked for (Play or Treat from the menu bar, or the follow-up
    /// after one in the popover), from wherever Mochi is. Returns false when the context
    /// does not allow it (a reaction, a summons, the popover, Reduced Motion, pausing).
    @discardableResult
    public mutating func startUserGame(_ game: RoamUserGame, now: TimeInterval, context: RoamContext) -> Bool {
        guard let zone, !context.reducedMotion else { return false }
        let desired = RoamMode.from(context)
        guard desired.yieldsToUserGames else { return false }
        mode = desired
        let start = cut(segmentsAt: now, immediate: true)
        let state = endState(at: start)
        var builder = RoamBuilder(t: start, x: state.x, facing: state.facing, odometer: state.odometer, zone: zone, rng: rng, context: context)
        builder.leave(state)
        // Near Patch the game stays close to home; alone, the whole bar is the playground.
        if desired != .free {
            builder.zone = RoamZone(minX: Swift.max(zone.minX, zone.homeX - 90), maxX: Swift.min(zone.maxX, zone.homeX + 90),
                                    homeX: zone.homeX, companionX: zone.companionX, occupied: zone.occupied)
            if builder.x < builder.zone.minX || builder.x > builder.zone.maxX { builder.goHome(hurry: true) }
        }
        builder.play(game)
        userGameUntil = builder.t
        builder.zone = zone
        builder.activity = .rest
        builder.hold(.idle, 2)
        commit(builder)
        return true
    }

    /// Off the bar for a desktop adventure: a hop down through the bottom of the bar, or gone at
    /// once (picked up by the pointer). The bed stays empty until `returnFromAdventure`.
    public mutating func leaveForAdventure(now: TimeInterval, context: RoamContext, instantly: Bool) {
        guard let zone else { return }
        userGameUntil = nil
        let start = cut(segmentsAt: now, immediate: true)
        let state = endState(at: start)
        mode = .away
        var builder = RoamBuilder(t: start, x: zone.holds(state.x) ? state.x : zone.clamp(state.x), facing: state.facing,
                                  odometer: state.odometer, zone: zone, rng: rng, context: context)
        builder.lift = state.lift
        if instantly {
            builder.activity = .exploring
            builder.holdForever(.idle, hidden: true)
        } else {
            builder.goAway(from: state)
        }
        commit(builder)
    }

    /// Back from a desktop adventure: Mochi pops up through the bottom of the bar at `x` (or where it
    /// left) and carries on from there, trotting home first when it is free to roam.
    public mutating func returnFromAdventure(at x: Double?, now: TimeInterval, context: RoamContext) {
        guard let zone else { return }
        let desired = RoamMode.from(context)
        guard desired != .away else { return }
        userGameUntil = nil
        let start = cut(segmentsAt: now, immediate: true)
        let state = endState(at: start)
        mode = desired
        var builder = RoamBuilder(t: start, x: state.x, facing: state.facing, odometer: state.odometer, zone: zone, rng: rng, context: context)
        builder.lift = state.lift
        builder.activity = .returning
        builder.reappear(at: zone.clamp(x ?? state.x))
        if desired == .free {
            builder.activity = .trotHome
            builder.goHome()
        }
        builder.open(desired, from: RoamBuilder.Start(lift: 0, sleeping: false))
        commit(builder)
    }

    /// When Mochi drops out of sight for a desktop adventure, and where (nil unless it is away).
    public var awayDeparture: (time: TimeInterval, x: Double)? {
        guard mode == .away, let hidden = segments.first(where: { $0.hidden }) else { return nil }
        return (hidden.start, hidden.fromX)
    }

    /// Development helper: plays one activity right away (free roaming only).
    public mutating func force(_ activity: RoamActivity, now: TimeInterval, context: RoamContext) {
        guard let zone else { return }
        update(now: now, context: context)
        guard mode == .free || mode == .companion else { return }
        userGameUntil = nil
        let start = cut(segmentsAt: now, immediate: false)
        let state = endState(at: start)
        var builder = RoamBuilder(t: start, x: state.x, facing: state.facing, odometer: state.odometer, zone: zone, rng: rng, context: context)
        builder.leave(state)
        builder.perform(activity)
        builder.activity = .rest
        builder.settleForRest()
        builder.rest(.idle, builder.uniform(6...12))
        commit(builder)
    }

    /// Places Mochi at `x` (tests and development only).
    public mutating func place(at x: Double, now: TimeInterval) {
        guard let zone else { return }
        segments = [RoamSegment(start: now - 0.01, end: .infinity, fromX: zone.clamp(x), toX: zone.clamp(x), animation: .idle,
                                facing: 1, motion: .hold, activity: .hold)]
        props = []
        userGameUntil = nil
        mode = .inactive
    }

    // MARK: Sampling (pure)

    public func sample(at t: TimeInterval) -> RoamSample {
        guard let first = segments.first else {
            let home = zone?.homeX ?? 0
            return RoamSample(x: home, lift: 0, facing: 1, opacity: 1, animation: .idle, elapsed: 0, duration: nil, activity: .rest,
                              props: [], speed: 0, held: nil, segmentEnd: .infinity)
        }
        var segment = first
        if t >= first.start, let found = segments.last(where: { $0.start <= t }) { segment = found }
        let props = self.props.compactMap { $0.sample(at: t) }
        if segment.end.isFinite, t >= segment.end {
            // Between segments or after the plan: hold the end state.
            let animation: PetAnimation = segment.animation.isLoop && segment.motion == .hold ? segment.animation : .idle
            let next = segments.first { $0.start > t }?.start ?? .infinity
            return RoamSample(x: segment.toX, lift: segment.liftTo, facing: segment.facing, opacity: segment.hidden ? 0 : 1,
                              animation: animation, elapsed: t - segment.end, duration: nil, activity: segment.activity, props: props, speed: 0,
                              held: nil, segmentEnd: next, odometer: segment.odometer + abs(segment.toX - segment.fromX),
                              style: .plain, progress: 1, segmentDuration: .infinity)
        }
        let time = Swift.max(t, segment.start)
        return RoamSample(x: segment.x(at: time), lift: segment.lift(at: time), facing: segment.facing, opacity: segment.opacity(at: time),
                          animation: segment.animation, elapsed: time - segment.start,
                          duration: segment.animation.isLoop ? nil : segment.duration, activity: segment.activity,
                          props: props, speed: segment.speed(at: time), held: segment.held, segmentEnd: segment.end,
                          odometer: segment.odometer + segment.travelled(at: time), style: segment.style,
                          progress: segment.progress(at: time), segmentDuration: segment.duration)
    }

    public func distanceFromHome(at t: TimeInterval) -> Double {
        guard let zone else { return 0 }
        return abs(sample(at: t).x - zone.homeX)
    }

    /// Standing (or sitting) in the bed spot.
    public func isHome(at t: TimeInterval) -> Bool {
        let sample = sample(at: t)
        return distanceFromHome(at: t) < 1.5 && !sample.isTravelling
    }

    /// True when Mochi is calmly resting from `t` for at least `duration` seconds: the world
    /// only lets ambient fidgets play then, so the menu bar never switches clips mid-move.
    public func isResting(at t: TimeInterval, for duration: TimeInterval) -> Bool {
        guard let segment = segments.last(where: { $0.start <= t }), t < segment.end else { return false }
        let calm: Set<PetAnimation> = [.idle, .sit, .watch]
        return segment.motion == .hold && calm.contains(segment.animation) && segment.end >= t + duration && segment.style == .plain
            && props.allSatisfy { $0.end < t || $0.start > t + duration }
    }

    // MARK: Planning

    private mutating func restart(at now: TimeInterval, context: RoamContext, zone: RoamZone) {
        segments = []
        props = []
        userGameUntil = nil
        let desired = RoamMode.from(context)
        var builder = RoamBuilder(t: now - 0.01, x: zone.homeX, facing: zone.companionSide, odometer: 0, zone: zone, rng: rng, context: context)
        if desired != .frozen, desired != .away, !context.reducedMotion { builder.arrive() }
        mode = desired
        builder.open(desired, from: RoamBuilder.Start(lift: 0, sleeping: false))
        commit(builder)
    }

    private mutating func replan(at now: TimeInterval, to newMode: RoamMode, context: RoamContext, zone: RoamZone) {
        let urgent = newMode == .frozen || newMode == .summoned || newMode == .away
        let start = cut(segmentsAt: now, immediate: urgent)
        let state = endState(at: start)
        mode = newMode
        var builder = RoamBuilder(t: start, x: zone.holds(state.x) ? state.x : zone.clamp(state.x), facing: state.facing,
                                  odometer: state.odometer, zone: zone, rng: rng, context: context)
        builder.lift = state.lift
        if newMode == .away {
            builder.goAway(from: state)
            commit(builder)
            return
        }
        if state.hidden {
            // Back without `returnFromAdventure` (called off): it pops up where it left.
            builder.reappear(at: zone.clamp(state.x))
        } else if let den = zone.den, den.shelters(state.x), !context.reducedMotion, builder.stayInDen(den, mode: newMode, state: state) {
            commit(builder)
            return
        }
        let inBed = state.sleeping && abs(state.x - zone.homeX) < 0.5 && abs(state.lift - MenuBarRoamer.bedLift) < 0.01
        if newMode != .frozen {
            // Never stop dead out of a run, never snap out of bed.
            if state.cruising, state.speed > 20, !context.reducedMotion { builder.brake(from: state.speed, direction: state.direction) }
            if !(newMode == .asleep && inBed), !state.hidden { builder.leave(state) }
        }
        builder.open(newMode, from: RoamBuilder.Start(lift: builder.lift, sleeping: state.sleeping && (newMode == .frozen || inBed)))
        commit(builder)
    }

    /// In the den, something changes the plan without a change of mode: a celebration bursts Mochi
    /// out, an attention badge brings it to the edge to peek, and once that is dealt with it comes out.
    private func denCalls(now: TimeInterval, context: RoamContext, zone: RoamZone) -> Bool {
        guard let den = zone.den, !context.reducedMotion, let segment = segments.last(where: { $0.start <= now }), now < segment.end else {
            return false
        }
        let inside = den.shelters(segment.x(at: now))
        switch segment.activity {
        case .denNap: return inside && (context.celebrating || (context.attentionBadge && mode.peeksFromDen))
        case .denPeek: return context.celebrating || (!context.attentionBadge && mode != .attending)
        default: return false
        }
    }

    /// Cuts the future off the timeline and returns the time the new plan starts.
    /// A short one-shot already in progress may finish first, so Mochi never snaps
    /// out of a leap mid-air — except when the change is immediate (reactions, summons, games).
    private mutating func cut(segmentsAt now: TimeInterval, immediate: Bool) -> TimeInterval {
        var start = now
        if !immediate, let current = segments.last(where: { $0.start <= now && now < $0.end }),
           !current.animation.isLoop, current.end.isFinite, current.end - now <= 0.9 {
            start = current.end
        }
        segments = segments.compactMap { segment in
            guard segment.start < start else { return nil }
            guard segment.end > start else { return segment }
            var trimmed = segment
            trimmed.toX = segment.x(at: start)
            trimmed.liftTo = segment.lift(at: start)
            if abs(trimmed.liftTo - trimmed.lift) > 0.0001 {
                // Keep the eased lift exactly where it was at the cut.
                trimmed.lift = segment.lift(at: start)
                trimmed.liftTo = trimmed.lift
            }
            trimmed.end = start
            return trimmed
        }
        props = props.compactMap { $0.fadedOut(after: start) }
        return start
    }

    struct EndState {
        var x: Double
        var facing: Double
        var lift: Double
        var sleeping: Bool
        var speed: Double
        var direction: Double
        var odometer: Double
        var cruising: Bool
        /// Away on a desktop adventure.
        var hidden = false
    }

    private func endState(at t: TimeInterval) -> EndState {
        guard let last = segments.last(where: { $0.start <= t }) ?? segments.last else {
            return EndState(x: zone?.homeX ?? 0, facing: 1, lift: 0, sleeping: false, speed: 0, direction: 1, odometer: 0, cruising: false)
        }
        let ended = last.end.isFinite && t >= last.end
        let x = ended ? last.toX : last.x(at: t)
        let sleeping = last.animation == .sleep || last.animation == .curl
        let direction: Double = last.curveToX >= last.fromX ? 1 : -1
        return EndState(x: x, facing: last.facing, lift: ended ? last.liftTo : last.lift(at: t), sleeping: sleeping,
                        speed: ended ? 0 : last.speed(at: t), direction: direction, odometer: last.odometer + abs(x - last.fromX),
                        cruising: !ended && last.motion == .cruise, hidden: last.hidden)
    }

    /// The bed moved with the status item: plans that end (or start) in the bed follow it.
    /// When Mochi is in the bed it rides along, like every other item on the bar.
    private mutating func shiftHomeAnchored(by dx: Double, oldHome: Double, now: TimeInterval, riding: Bool) {
        func atHome(_ x: Double) -> Bool { abs(x - oldHome) < 0.5 }
        var result: [RoamSegment] = []
        for segment in segments {
            var s = segment
            let current = s.start <= now && now < s.end
            if riding || s.start >= now {
                if atHome(s.fromX) { s.fromX += dx }
                if atHome(s.toX) { s.toX += dx }
                if atHome(s.curveToX) { s.curveToX += dx }
                result.append(s)
            } else if current, atHome(s.curveToX), s.travels {
                // On the way home: keep where Mochi is now, and head for the bed's new spot.
                let x = s.x(at: now)
                var first = s
                first.toX = x
                first.end = now
                var second = RoamSegment(start: now, end: s.curveEnd, fromX: x, toX: oldHome + dx, animation: s.animation, facing: s.facing,
                                         motion: s.motion == .cruise ? .cruise : .smooth, lift: s.lift(at: now), liftTo: s.liftTo,
                                         held: s.held, activity: s.activity, style: s.style, odometer: s.odometer + abs(x - s.fromX),
                                         easeIn: 0, easeOut: s.easeOut)
                let newDirection: Double = oldHome + dx >= x ? 1 : -1
                if newDirection != s.facing, abs(oldHome + dx - x) > 0.5 { second.facing = newDirection }
                result.append(first)
                result.append(second)
            } else {
                result.append(s)
            }
        }
        segments = result
    }

    private mutating func appendChunk(start: TimeInterval, context: RoamContext, zone: RoamZone) {
        let state = endState(at: start)
        var builder = RoamBuilder(t: start, x: state.x, facing: state.facing, odometer: state.odometer, zone: zone, rng: rng, context: context)
        builder.lift = state.lift
        let restScale = RoamBuilder.restScale(context)
        let playScale = RoamBuilder.playScale(context)
        switch mode {
        case .inactive, .frozen, .summoned, .attending, .lookingUp, .asleep, .paused, .away:
            // Open-ended holds normally never run out; if one did, open the mode again.
            builder.open(mode, from: RoamBuilder.Start(lift: state.lift, sleeping: state.sleeping))
        case .reducedMotion:
            builder.activity = .settleHome
            if abs(builder.x - zone.homeX) > 0.5 { builder.fade(to: zone.homeX) }
            builder.hold(builder.chance(0.5) ? .sit : .idle, builder.uniform(14...36) * restScale, facing: zone.companionSide)
            var options: [(PetAnimation, Double)] = [(.blep, 1), (.lookAround, 1.2), (.nod, 0.4)]
            if context.idleSeconds > 120 || context.quietHours { options.append((.yawn, 0.8)) }
            builder.act(builder.pick(options))
        case .working:
            if builder.chance(0.22 * playScale) { builder.potterNearHome() }
            builder.activity = .watchCompanion
            if abs(builder.x - zone.homeX) > 0.5 { builder.goHome() }
            builder.rest(.watch, builder.uniform(14...40) * restScale, facing: zone.companionSide)
        case .companion:
            if builder.chance(0.45 * playScale) { builder.potterNearHome() }
            builder.activity = .sitWithCompanion
            if abs(builder.x - zone.homeX) > 0.5 { builder.goHome() }
            builder.rest(builder.chance(0.55) ? .sit : .idle, builder.uniform(12...40) * restScale, facing: zone.companionSide)
        case .free:
            let activity = builder.chooseFreeActivity(recent: recent)
            builder.perform(activity)
            remember(activity)
            builder.activity = .rest
            builder.settleForRest()
            let base: PetAnimation = builder.chance(0.7) ? .idle : .sit
            builder.rest(base, builder.uniform(14...48) * restScale)
        }
        commit(builder)
    }

    private mutating func commit(_ builder: RoamBuilder) {
        rng = builder.rng
        segments.append(contentsOf: builder.segments)
        props.append(contentsOf: builder.props)
    }

    private mutating func remember(_ activity: RoamActivity) {
        recent.append(activity)
        if recent.count > 3 { recent.removeFirst() }
    }

    private mutating func prune(now: TimeInterval) {
        if let index = segments.lastIndex(where: { $0.end.isFinite && $0.end < now - 1 }), index < segments.count - 1 {
            segments.removeFirst(index + 1)
        }
        props.removeAll { $0.end < now - 0.5 }
    }
}

extension RoamPropTrack {
    /// The track cut at `t`: the prop fades out where it is instead of finishing its flight.
    func fadedOut(after t: TimeInterval) -> RoamPropTrack? {
        guard start < t else { return nil }
        guard end > t, let here = sample(at: t) else { return self }
        var copy = self
        copy.keys = keys.filter { $0.t < t }
        copy.keys.append(RoamPropKey(t: t, x: here.x, y: here.y, opacity: here.opacity, path: .linear))
        copy.keys.append(RoamPropKey(t: t + 0.45, x: here.x, y: here.y + (kind == .butterfly ? 8 : 0), opacity: 0, path: .linear))
        return copy
    }

    /// Keys still to come that sit in the bed follow it when the status item moves.
    func shiftingKeys(near home: Double, by dx: Double, after t: TimeInterval) -> RoamPropTrack {
        var copy = self
        copy.keys = keys.map { key in
            guard key.t > t, abs(key.x - home) < 4 else { return key }
            var shifted = key
            shifted.x += dx
            return shifted
        }
        return copy
    }
}

// MARK: - Builder

/// Appends segments and prop keys for activities, starting at a time and place.
struct RoamBuilder {
    var t: TimeInterval
    var x: Double
    var facing: Double
    var lift = 0.0
    var odometer: Double
    var zone: RoamZone
    var rng: SplitMix64
    let context: RoamContext
    var activity: RoamActivity = .rest
    /// Something Mochi carries through every segment until it is put down (a caught ball).
    var carrying: HeldItem?
    var segments: [RoamSegment] = []
    var props: [RoamPropTrack] = []

    /// Where a new plan picks up: on the bed cushion or not, asleep or not.
    struct Start {
        var lift: Double
        var sleeping: Bool
    }

    init(t: TimeInterval, x: Double, facing: Double, odometer: Double, zone: RoamZone, rng: SplitMix64, context: RoamContext) {
        self.t = t
        self.x = x
        self.facing = facing >= 0 ? 1 : -1
        self.odometer = odometer
        self.zone = zone
        self.rng = rng
        self.context = context
    }

    static func restScale(_ context: RoamContext) -> Double {
        let intensity: Double
        switch context.intensity {
        case .calm: intensity = 1.4
        case .normal: intensity = 1
        case .lively: intensity = 0.6
        }
        return intensity * (context.quietHours ? 1.4 : 1)
    }

    static func playScale(_ context: RoamContext) -> Double {
        switch context.intensity {
        case .calm: return 0.6
        case .normal: return 1
        case .lively: return 1.4
        }
    }

    // MARK: Randomness

    mutating func uniform(_ range: ClosedRange<Double>) -> Double { rng.next(in: range) }

    mutating func chance(_ p: Double) -> Bool { rng.nextUnit() < p }

    mutating func pick<T>(_ options: [(T, Double)]) -> T {
        let total = options.reduce(0) { $0 + Swift.max(0, $1.1) }
        var roll = rng.nextUnit() * total
        for (value, weight) in options where weight > 0 {
            roll -= weight
            if roll <= 0 { return value }
        }
        return options.last!.0
    }

    /// Prefers the side with more room, without always picking it.
    mutating func roomyDirection() -> Double {
        let right = zone.room(from: x, direction: 1)
        let left = zone.room(from: x, direction: -1)
        guard right + left > 1 else { return facing }
        return chance(0.15 + 0.7 * right / (right + left)) ? 1 : -1
    }

    /// A random free spot `distance` points away in `direction` (nil if there is none).
    mutating func lingerTarget(from origin: Double, direction: Double, distance: ClosedRange<Double>) -> Double? {
        let a = origin + direction * distance.lowerBound
        let b = origin + direction * distance.upperBound
        let spans = zone.lingerSpans(between: a, and: b)
        let total = spans.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard !spans.isEmpty else { return nil }
        if total < 0.5 { return spans[Int(uniform(0...Double(spans.count) - 0.001))].lowerBound }
        var roll = uniform(0...total)
        for span in spans {
            let length = span.upperBound - span.lowerBound
            if roll <= length { return span.lowerBound + roll }
            roll -= length
        }
        return spans.last?.upperBound
    }

    // MARK: Primitives

    mutating func append(_ segment: RoamSegment) {
        var s = segment
        if s.held == nil { s.held = carrying }
        s.odometer = odometer
        odometer += abs(s.toX - s.fromX)
        segments.append(s)
    }

    mutating func hold(_ animation: PetAnimation, _ duration: TimeInterval, facing newFacing: Double? = nil, lift newLift: Double? = nil,
                       liftTo: Double? = nil, held: HeldItem? = nil, style: RoamSegment.Style = .plain, hidden: Bool = false) {
        if let newFacing { facing = newFacing >= 0 ? 1 : -1 }
        if let newLift { lift = newLift }
        guard duration > 0.01 else {
            if let liftTo { lift = liftTo }
            return
        }
        let end = liftTo ?? lift
        append(RoamSegment(start: t, end: t + duration, fromX: x, toX: x, animation: animation, facing: facing, motion: .hold,
                           lift: lift, liftTo: end, held: held, activity: activity, style: style, hidden: hidden))
        lift = end
        t += duration
    }

    mutating func holdForever(_ animation: PetAnimation, facing newFacing: Double? = nil, lift newLift: Double? = nil,
                              style: RoamSegment.Style = .plain, hidden: Bool = false) {
        if let newFacing { facing = newFacing >= 0 ? 1 : -1 }
        if let newLift { lift = newLift }
        append(RoamSegment(start: t, end: .infinity, fromX: x, toX: x, animation: animation, facing: facing, motion: .hold,
                           lift: lift, activity: activity, style: style, hidden: hidden))
        t = .infinity
    }

    /// Turning around: a tiny hop, mirroring at the top of it (instant in Reduced Motion).
    mutating func turn(to direction: Double) {
        let wanted: Double = direction >= 0 ? 1 : -1
        guard wanted != facing else { return }
        if context.reducedMotion {
            hold(.idle, 0.2, facing: wanted)
            return
        }
        let base = lift
        hold(.idle, 0.1, liftTo: base + 1.3)
        hold(.idle, 0.12, facing: wanted, liftTo: base)
    }

    /// Walks or runs to `target` (kept inside the zone), easing in and out. Never faster
    /// than `speed`; slower when it must take at least `minimum` seconds.
    @discardableResult
    mutating func move(to target: Double, speed: Double, animation: PetAnimation? = nil, atLeast minimum: TimeInterval = 0,
                       held: HeldItem? = nil, skid: Bool = false) -> Double {
        let goal = zone.clamp(target)
        let distance = abs(goal - x)
        guard distance > 0.5 else { return 0 }
        if context.reducedMotion {
            // No visible travel with Reduced Motion.
            fade(to: goal)
            return distance
        }
        let direction: Double = goal > x ? 1 : -1
        turn(to: direction)
        let fast = speed >= MenuBarRoamer.Speed.run - 1
        if fast { hold(.idle, 0.12, style: .crouch) }
        let easeIn = fast ? 0.2 : 0.15
        let easeOut = skid ? 0 : (fast ? 0.18 : 0.18)
        let duration = Swift.max(distance / speed + (easeIn + easeOut) / 2, minimum)
        let gait = animation ?? (distance / duration >= 60 ? .run : .walk)
        append(RoamSegment(start: t, end: t + duration, fromX: x, toX: goal, animation: gait, facing: direction, motion: .cruise,
                           lift: lift, held: held, activity: activity, style: fast ? .launch : .plain, easeIn: easeIn, easeOut: easeOut))
        t += duration
        x = goal
        if skid {
            // Sliding to a stop, leaning back: a braking run from full speed.
            let cruiseSpeed = distance / (duration - (easeIn + easeOut) / 2)
            brake(from: cruiseSpeed, direction: direction, style: .skid, duration: 0.2)
            hold(.idle, 0.12, style: .land)
        }
        return distance
    }

    /// Slows to a stop from `speed`, carrying on a little in `direction`.
    mutating func brake(from speed: Double, direction: Double, style: RoamSegment.Style = .plain, duration: TimeInterval = 0.18) {
        let distance = Swift.min(speed * duration / 2, zone.room(from: x, direction: direction))
        guard distance > 0.3 else { return }
        let goal = x + direction * distance
        append(RoamSegment(start: t, end: t + duration, fromX: x, toX: goal, animation: speed >= 60 ? .run : .walk, facing: direction,
                           motion: .brake, lift: lift, activity: activity, style: style))
        t += duration
        x = goal
        facing = direction >= 0 ? 1 : -1
    }

    /// A one-shot animation, optionally covering `travel` points in the facing direction (eased).
    mutating func act(_ animation: PetAnimation, _ duration: TimeInterval? = nil, travel: Double = 0, lift newLift: Double? = nil,
                      held: HeldItem? = nil, style: RoamSegment.Style = .plain) {
        if let newLift { lift = newLift }
        let length = duration ?? animation.defaultDuration
        let goal = context.reducedMotion || travel == 0 ? x : zone.clamp(x + travel * facing)
        let moves = abs(goal - x) > 0.01
        append(RoamSegment(start: t, end: t + length, fromX: x, toX: goal, animation: animation, facing: facing,
                           motion: moves ? .smooth : .hold, lift: lift, held: held, activity: activity, style: style))
        t += length
        x = goal
    }

    /// Reduced Motion: disappears and reappears at `target` instead of walking.
    mutating func fade(to target: Double, duration: TimeInterval = 0.9) {
        let goal = zone.clamp(target)
        append(RoamSegment(start: t, end: t + duration, fromX: x, toX: goal, animation: .idle, facing: facing,
                           motion: .fade, lift: 0, activity: activity))
        lift = 0
        t += duration
        x = goal
    }

    static func autoSpeed(_ distance: Double) -> Double {
        distance > 150 ? MenuBarRoamer.Speed.run : (distance > 50 ? MenuBarRoamer.Speed.trot : MenuBarRoamer.Speed.walk)
    }

    mutating func goHome(face: Double? = nil, hurry: Bool = false) {
        let distance = abs(zone.homeX - x)
        move(to: zone.homeX, speed: hurry ? MenuBarRoamer.Speed.dash : Self.autoSpeed(distance))
        if let face { turn(to: face) }
    }

    /// Off to a free spot first when Mochi is standing on another app's status item.
    mutating func goToLingerSpot() {
        guard !zone.canLinger(at: x) else { return }
        let spot = zone.nearestLinger(to: x)
        move(to: spot, speed: Self.autoSpeed(abs(spot - x)))
    }

    /// Before a long rest: never on top of another app's item — the nearest free spot, or the bed.
    mutating func settleForRest() {
        let homeDistance = abs(x - zone.homeX)
        var target: Double?
        if !zone.canLinger(at: x) {
            let spot = zone.nearestLinger(to: x)
            target = abs(spot - x) > 150 || chance(0.35) ? zone.homeX : spot
        } else if homeDistance > 1, chance(0.2 + 0.4 * Swift.min(1, homeDistance / 400)) {
            target = zone.homeX
        }
        guard let target, abs(target - x) > 0.5 else { return }
        let previous = activity
        activity = abs(target - zone.homeX) < 1 ? .trotHome : .wander
        move(to: target, speed: Self.autoSpeed(abs(target - x)))
        hold(.idle, 0.5)
        activity = previous
    }

    /// Getting up before doing anything else: out of a nap, off the bed cushion.
    mutating func leave(_ state: MenuBarRoamer.EndState) {
        lift = state.lift
        if state.sleeping {
            let previous = activity
            activity = .rest
            act(.wakeUp)
            activity = previous
        }
        stepDown()
        if let den = zone.den, den.shelters(x) { comeOutOfDen(den) }
    }

    /// Off the bed cushion (eased, never a pop).
    mutating func stepDown() {
        guard lift > 0.01 else { return }
        hold(.idle, 0.3, liftTo: 0)
    }

    /// Into the bed, onto the cushion.
    mutating func climbIntoBed() {
        guard abs(lift - MenuBarRoamer.bedLift) > 0.01 else { return }
        hold(.idle, 0.35, liftTo: MenuBarRoamer.bedLift)
    }

    /// A rest with a little something in the middle when it is long enough.
    mutating func rest(_ base: PetAnimation, _ duration: TimeInterval, facing newFacing: Double? = nil) {
        if let newFacing { turn(to: newFacing) }
        guard duration >= 14 else { return hold(base, duration) }
        // Long rests are never frozen: a glance around, a blep, a scratch… once or twice.
        let fidgets = duration >= 30 ? 2 : 1
        var remaining = duration
        var options: [(PetAnimation, Double)] = [(.lookAround, 1.0), (.blep, 0.6), (.scratch, 0.5), (.stretch, 0.35), (.sniff, 0.3)]
        if context.idleSeconds > 120 || context.quietHours { options.append((.yawn, 0.7)) }
        for index in 0..<fidgets {
            let share = fidgets == 1 ? uniform(0.3...0.6) : (index == 0 ? uniform(0.22...0.4) : uniform(0.35...0.6))
            let first = remaining * share
            hold(base, first)
            let fidget = pick(options)
            options.removeAll { $0.0 == fidget }
            act(fidget)
            remaining = Swift.max(1, remaining - first - fidget.defaultDuration)
        }
        hold(base, remaining)
    }

    // MARK: Modes

    /// The opening of a new behaviour, starting from the current position.
    mutating func open(_ mode: RoamMode, from start: Start) {
        switch mode {
        case .inactive:
            activity = .rest
            holdForever(.idle)
        case .away:
            activity = .exploring
            holdForever(.idle, hidden: true)
        case .frozen:
            activity = .hold
            holdForever(.idle, lift: start.lift)
        case .summoned:
            activity = .dashHome
            stepDown()
            if abs(x - zone.homeX) > 1 {
                // Ears up, a look towards home… and off it goes.
                hold(.idle, 0.3, facing: zone.homeX > x ? 1 : -1, style: .notice)
                goHome(hurry: true)
            }
            holdForever(.idle, facing: zone.companionSide)
        case .reducedMotion:
            activity = .settleHome
            if abs(x - zone.homeX) > 0.5 { fade(to: zone.homeX) }
            hold(.idle, uniform(2...4), facing: zone.companionSide, lift: 0)
        case .attending:
            // Claude waits for the user: a wave from home, then a calm watch facing you, and one
            // reminder wave a minute (at most ten), so it never waves for ever in the corner of your eye.
            activity = .attend
            stepDown()
            goHome()
            hold(.waveGently, 8.4, facing: zone.companionSide)
            for _ in 0..<10 {
                hold(.sit, 55.8, style: .attentive)
                hold(.waveGently, 4.2)
            }
            holdForever(.sit, style: .attentive)
        case .lookingUp:
            activity = .lookUp
            stepDown()
            if abs(x - zone.homeX) <= 80 { goHome() }
            let towardsHome: Double = abs(x - zone.homeX) < 1 ? zone.companionSide : (zone.homeX > x ? 1 : -1)
            holdForever(.watch, facing: towardsHome)
        case .asleep:
            activity = .sleepAtHome
            if start.sleeping, abs(x - zone.homeX) < 0.5, abs(lift - MenuBarRoamer.bedLift) < 0.01 {
                holdForever(.sleep)
                return
            }
            goHome()
            act(.yawn)
            climbIntoBed()
            holdForever(.sleep)
        case .paused:
            activity = .pausedRest
            goHome()
            holdForever(.sit, facing: zone.companionSide)
        case .working, .companion:
            activity = .nearHome
            goHome(face: zone.companionSide)
            hold(mode == .working ? .watch : .sit, uniform(1.5...3.5))
        case .free:
            activity = .rest
            settleForRest()
            hold(chance(0.6) ? .idle : .sit, uniform(2...5))
        }
    }

    /// Hopping down into the bed from the top of the menu bar (launch, a new display).
    mutating func arrive() {
        activity = .arrive
        hold(.idle, 0.42, facing: zone.companionSide, lift: 22, liftTo: 0, style: .drop)
        hold(.idle, 0.22, style: .land)
        hold(.idle, 0.4)
    }

    // MARK: Choosing

    mutating func chooseFreeActivity(recent: [RoamActivity]) -> RoamActivity {
        let play = RoamBuilder.playScale(context)
        let distance = abs(x - zone.homeX) / Swift.max(1, zone.width)
        var options: [(RoamActivity, Double)] = [
            (.wander, 3), (.sniffAround, 2), (.zoomies, 1.0 * play), (.chaseButterfly, 1.2 * play), (.ballPlay, 1.0 * play),
            (.yarnPlay, 0.5 * play), (.leafPlay, 0.6), (.fidget, 1.8), (.nap, 0.45 / play), (.trotHome, 0.4 + 3 * distance),
        ]
        if context.quietHours {
            options = options.map { activity, weight in
                switch activity {
                case .nap: return (activity, weight * 3)
                case .zoomies: return (activity, weight * 0.25)
                case .ballPlay, .yarnPlay, .chaseButterfly: return (activity, weight * 0.5)
                default: return (activity, weight)
                }
            }
            options.append((.sleepAtHome, 1.5))
        }
        if context.idleSeconds > 300 {
            options = options.map { $0.0 == .nap ? ($0.0, $0.1 * 2) : $0 }
            options.append((.sleepAtHome, 0.5))
        }
        if zone.width < 90 {
            // A tiny stage: no long runs.
            options = options.map { $0.0 == .zoomies || $0.0 == .chaseButterfly ? ($0.0, $0.1 * 0.3) : $0 }
        }
        if let last = recent.last { options.removeAll { $0.0 == last } }
        if recent.count > 1 {
            let previous = recent[recent.count - 2]
            options = options.map { $0.0 == previous ? ($0.0, $0.1 * 0.4) : $0 }
        }
        return pick(options)
    }

    mutating func perform(_ activity: RoamActivity) {
        switch activity {
        case .wander: wander()
        case .trotHome: trotHome()
        case .zoomies: zoomies()
        case .sniffAround: sniffAround()
        case .chaseButterfly: chaseButterfly()
        case .ballPlay: ballPlay(yarn: false)
        case .yarnPlay: ballPlay(yarn: true)
        case .leafPlay: leafPlay()
        case .fidget: fidget()
        case .nap: nap()
        case .sleepAtHome: sleepAtHome()
        case .nearHome: potterNearHome()
        case .userPlay: play(.play)
        case .userTreat: play(.treat)
        case .followUpPlay: play(.playFollowUp)
        case .crumbHunt: play(.treatFollowUp)
        case .denNap:
            if let den = zone.den { napInDen(den, sleep: uniform(18...50)) } else { nap() }
        default:
            self.activity = .rest
            hold(.idle, uniform(2...4))
        }
    }

    mutating func play(_ game: RoamUserGame) {
        switch game {
        case .play: userBall(followUp: false)
        case .playFollowUp: userBall(followUp: true)
        case .treat: userTreat()
        case .treatFollowUp: crumbHunt()
        }
    }

    // MARK: Activities

    mutating func wander() {
        activity = .wander
        var direction = roomyDirection()
        if zone.room(from: x, direction: direction) < 45 { direction = -direction }
        move(to: x + direction * uniform(45...230), speed: MenuBarRoamer.Speed.walk)
        if zone.canLinger(at: x) {
            hold(.idle, uniform(0.6...1.4))
            if chance(0.45) { act(.lookAround) }
            if chance(0.25), let back = lingerTarget(from: x, direction: -direction, distance: 20...60) {
                move(to: back, speed: MenuBarRoamer.Speed.walk)
            }
        } else {
            // On top of other apps' icons: just a moment's pause, then on to somewhere free.
            hold(.idle, uniform(0.5...1.1), style: .notice)
            let spot = lingerTarget(from: x, direction: direction, distance: 8...120) ?? zone.nearestLinger(to: x)
            move(to: spot, speed: abs(spot - x) > 90 ? MenuBarRoamer.Speed.trot : MenuBarRoamer.Speed.walk)
            if chance(0.4) { act(.lookAround) }
        }
    }

    mutating func trotHome() {
        activity = .trotHome
        goHome()
        turn(to: zone.midX < zone.homeX ? -1 : 1)
        hold(.idle, 0.6)
    }

    mutating func zoomies() {
        activity = .zoomies
        goToLingerSpot()
        act(chance(0.5) ? .happyBounce : .shake)
        var direction = roomyDirection()
        let legs = Int(uniform(3...5.99))
        let skidRoom = MenuBarRoamer.Speed.zoom * 0.1 + 2
        for leg in 0..<legs {
            if zone.room(from: x, direction: direction) < 40 + skidRoom { direction = -direction }
            let room = zone.room(from: x, direction: direction)
            if leg < legs - 1 {
                let distance = Swift.min(uniform(70...230), room - skidRoom)
                guard distance > 20 else { break }
                // Sprint, skid to a stop, hop around, go again.
                move(to: x + direction * distance, speed: MenuBarRoamer.Speed.zoom, animation: .run, skid: true)
                direction = -direction
            } else {
                // The last dash ends somewhere free, where the finale plays.
                let spot = lingerTarget(from: x, direction: direction, distance: 50...Swift.max(50, Swift.min(230, room)))
                    ?? zone.nearestLinger(to: x + direction * Swift.min(120, room))
                move(to: spot, speed: MenuBarRoamer.Speed.zoom, animation: .run)
            }
        }
        if chance(0.5), zone.canLinger(at: x + 14 * facing), zone.room(from: x, direction: facing) > 15 {
            act(.tumble, travel: 14)
        } else {
            act(.happyBounce)
        }
        act(.blep)
    }

    mutating func sniffAround() {
        activity = .sniffAround
        goToLingerSpot()
        var direction = roomyDirection()
        let rounds = Int(uniform(2...3.99))
        for _ in 0..<rounds {
            if chance(0.3) { direction = -direction }
            // The next interesting smell: somewhere free nearby (or right here).
            let spot = lingerTarget(from: x, direction: direction, distance: 18...70)
                ?? lingerTarget(from: x, direction: -direction, distance: 18...70)
            if let spot {
                direction = spot >= x ? 1 : -1
                move(to: spot, speed: MenuBarRoamer.Speed.walk)
            }
            act(.sniff)
            let roll = rng.nextUnit()
            if roll < 0.25 { act(.scratch) } else if roll < 0.4 { act(.blep) }
        }
    }

    mutating func fidget() {
        activity = .fidget
        goToLingerSpot()
        let count = chance(0.35) ? 2 : 1
        for _ in 0..<count {
            var options: [(PetAnimation, Double)] = [(.stretch, 1), (.scratch, 1), (.shake, 0.7), (.lookAround, 1), (.blep, 0.6), (.tumble, 0.55)]
            if context.idleSeconds > 120 || context.quietHours { options.append((.yawn, 0.7)) }
            let animation = pick(options)
            if animation == .tumble {
                if !zone.canLinger(at: x + 14 * facing) || zone.room(from: x, direction: facing) < 20 { turn(to: -facing) }
                if !zone.canLinger(at: x + 14 * facing) || zone.room(from: x, direction: facing) < 20 {
                    act(.stretch)
                    continue
                }
            }
            act(animation, travel: animation == .tumble ? 14 : 0)
        }
    }

    mutating func nap() {
        if let den = denForNaps, chance(0.5) {
            napInDen(den, sleep: uniform(18...50) * (context.quietHours ? 2 : 1))
            return
        }
        activity = .nap
        let inBed = chance(0.45)
        if inBed {
            goHome()
        } else {
            let spot = lingerTarget(from: x, direction: roomyDirection(), distance: 0...60) ?? zone.nearestLinger(to: x)
            move(to: spot, speed: MenuBarRoamer.Speed.walk)
        }
        act(.yawn)
        if inBed { climbIntoBed() }
        hold(.curl, uniform(18...50) * (context.quietHours ? 2 : 1))
        act(.wakeUp)
        stepDown()
        act(.stretch)
    }

    mutating func sleepAtHome() {
        if let den = denForNaps, chance(0.5) {
            napInDen(den, sleep: uniform(60...160))
            return
        }
        activity = .sleepAtHome
        goHome()
        act(.yawn)
        climbIntoBed()
        hold(.sleep, uniform(60...160))
        act(.wakeUp)
        stepDown()
        act(.stretch)
    }

    /// Small moves near home while Patch is around: a sniff on the free bar past Patch,
    /// a few steps the other way and back, or a stretch in place. Never far.
    mutating func potterNearHome() {
        activity = .nearHome
        let patchSide = zone.companionSide
        let patchGap = abs(zone.companionX - zone.homeX)
        let farthest = MenuBarRoamer.nearHomeRadius - 3
        let roll = rng.nextUnit()
        if roll < 0.45, farthest - patchGap > 16,
           let spot = lingerTarget(from: zone.homeX, direction: patchSide, distance: (patchGap + 14)...farthest) {
            move(to: spot, speed: MenuBarRoamer.Speed.walk)
            act(chance(0.5) ? .sniff : .lookAround)
            goHome(face: patchSide)
        } else if roll < 0.7 {
            move(to: zone.homeX - patchSide * uniform(14...30), speed: MenuBarRoamer.Speed.walk)
            if zone.canLinger(at: x) {
                act(chance(0.5) ? .sniff : .lookAround)
            } else {
                hold(.idle, uniform(0.5...1.0), style: .notice)
            }
            goHome(face: patchSide)
        } else {
            if abs(x - zone.homeX) > 0.5 { goHome(face: patchSide) }
            let options: [(PetAnimation, Double)] = [(.stretch, 1), (.scratch, 1), (.lookAround, 1.2), (.blep, 0.8), (.shake, 0.5)]
            act(pick(options))
        }
    }

    // MARK: Ball games

    enum BallFinish {
        /// Leap, catch it and carry it back to the bed (or the nearest free spot when far).
        case carryHome
        /// Pounce, tumble together and let it roll off (yarn).
        case tumble
    }

    /// A rally with a ball that is already on the bar at `bx` (resting height `resting`):
    /// bat, chase, pounce… then the finish. Appends keys to `keys`.
    mutating func rally(_ keys: inout [RoamPropKey], ball start: Double, direction initial: Double, resting: Double, swipes: Int,
                        yarn: Bool, finish: BallFinish) {
        var bx = start
        var direction = initial
        let swipeTime = PetAnimation.bat.defaultDuration
        let contactAt = swipeTime * 0.5
        for swipe in 0..<swipes {
            if zone.room(from: bx, direction: direction) < 24 {
                direction = -direction
                turn(to: direction)
            }
            let contact = t + contactAt
            act(.bat, swipeTime)
            keys.append(RoamPropKey(t: contact, x: bx, y: resting))
            let room = Swift.max(0, zone.room(from: bx, direction: direction) - 6)
            var distance = Swift.min(room, yarn ? uniform(28...55) : uniform(45...95))
            // Prefer to send it somewhere Mochi can stand without covering an icon.
            if let free = lingerTarget(from: bx, direction: direction, distance: Swift.min(distance, 30)...Swift.max(30, distance)) {
                distance = abs(free + direction * 14 - bx)
                distance = Swift.min(distance, room)
            }
            let rollTime = 0.5 + distance / (yarn ? 42 : 58)
            bx += direction * distance
            keys.append(RoamPropKey(t: contact + rollTime, x: bx, y: resting, path: .easeOut))
            // Chase, arriving just behind it as it settles (never overtaking a rolling ball).
            move(to: bx - direction * 14, speed: MenuBarRoamer.Speed.run, atLeast: Swift.max(0, contact + rollTime - 0.05 - t))
            if t < contact + rollTime { hold(.watch, contact + rollTime - t) }
            if swipe < swipes - 1 {
                let pounceTime = PetAnimation.pounce.defaultDuration
                act(.pounce, pounceTime, travel: 5)
                keys.append(RoamPropKey(t: t, x: bx, y: resting))
                // Back off a step to line up the next swipe.
                hold(.idle, 0.2)
                if abs(bx - x) < 13 { act(.idle, 0.3, travel: -(13 - abs(bx - x))) }
            }
        }
        switch finish {
        case .tumble:
            act(.pounce, PetAnimation.pounce.defaultDuration, travel: 6)
            let tumbleStart = t
            let roomAhead = zone.room(from: x, direction: facing)
            act(.tumble, travel: Swift.min(18, Swift.max(0, roomAhead - 2)))
            keys.append(RoamPropKey(t: tumbleStart, x: bx, y: resting))
            bx = zone.clamp(x + direction * 13)
            keys.append(RoamPropKey(t: t, x: bx, y: resting, path: .easeInOut))
            act(.happyBounce)
            keys.append(RoamPropKey(t: t, x: bx, y: resting))
            keys.append(RoamPropKey(t: t + 0.6, x: bx, y: resting, opacity: 0))
        case .carryHome:
            // Leap and catch it: it pops up into Mochi's paws.
            let leap = PetAnimation.leapCatch.defaultDuration
            let leapStart = t
            act(.leapCatch, leap, travel: 10)
            keys.append(RoamPropKey(t: leapStart + leap * 0.28, x: bx, y: resting))
            keys.append(RoamPropKey(t: leapStart + leap * 0.5, x: x - direction * 2, y: 9, opacity: 0, path: .arc, arc: 4))
            carrying = .ball
            act(.happyBounce)
            // Carried proudly back to bed, or to the nearest free spot when the bed is far.
            let home = abs(zone.homeX - x) <= 260 ? zone.homeX : zone.nearestLinger(to: x)
            if abs(home - x) > 2 {
                move(to: home, speed: MenuBarRoamer.Speed.trot, animation: .carry)
            }
            hold(.idle, 0.35)
            carrying = nil
            // Drops it; it rolls off a little and is gone.
            let dropAt = t
            let out = zone.room(from: x, direction: facing) > 30 ? facing : -facing
            keys.append(RoamPropKey(t: dropAt, x: x + out * 8, y: resting, opacity: 0))
            keys.append(RoamPropKey(t: dropAt + 0.05, x: x + out * 8, y: resting, opacity: 1))
            keys.append(RoamPropKey(t: dropAt + 1.2, x: zone.clamp(x + out * 26), y: resting, opacity: 0, path: .easeOut))
            act(.blep)
        }
    }

    /// Bat the ball, chase it, pounce, bat again, then catch it (or tumble with the yarn).
    mutating func ballPlay(yarn: Bool) {
        activity = yarn ? .yarnPlay : .ballPlay
        goToLingerSpot()
        var direction = roomyDirection()
        if zone.room(from: x, direction: direction) < 70 { direction = -direction }
        turn(to: direction)
        let resting = yarn ? RoamToys.yarnRest : RoamToys.ballRest
        var keys: [RoamPropKey] = []
        // Tossed in from above: it lands in front of Mochi and bounces.
        let bx = zone.clamp(x + direction * 15)
        keys.append(RoamPropKey(t: t, x: bx + direction * 6, y: 21, opacity: 0))
        keys.append(RoamPropKey(t: t + 0.16, x: bx + direction * 5, y: 18))
        keys.append(RoamPropKey(t: t + 0.5, x: bx, y: resting, path: .drop))
        keys.append(RoamPropKey(t: t + 0.8, x: bx, y: resting, path: .arc, arc: 3.4))
        keys.append(RoamPropKey(t: t + 0.98, x: bx, y: resting, path: .arc, arc: 0.9))
        hold(.watch, 1.05)
        rally(&keys, ball: bx, direction: direction, resting: resting, swipes: yarn ? 2 : Int(uniform(2...3.99)), yarn: yarn,
              finish: yarn ? .tumble : .carryHome)
        props.append(RoamPropTrack(kind: yarn ? .yarn : .ball, keys: keys, scale: yarn ? RoamToys.yarnScale : RoamToys.ballScale))
    }

    /// A butterfly drifts in; Mochi spots it, stalks it and leaps for it a few times,
    /// and ends up somewhere free, puzzled or delighted, as it flutters off.
    mutating func chaseButterfly() {
        activity = .chaseButterfly
        goToLingerSpot()
        var direction = roomyDirection()
        if zone.room(from: x, direction: direction) < 80 { direction = -direction }
        turn(to: direction)
        var keys: [RoamPropKey] = []
        var bx = zone.clamp(x + direction * uniform(34...52))
        var by = uniform(11...15)
        keys.append(RoamPropKey(t: t, x: zone.clamp(bx + direction * 18), y: 24, opacity: 0))
        keys.append(RoamPropKey(t: t + 1.3, x: bx, y: by, path: .flutter))
        act(.leanForward)
        let rounds = Int(uniform(3...4.99))
        let leap = PetAnimation.leapCatch.defaultDuration
        for round in 0..<rounds {
            move(to: bx - direction * 7, speed: round == 0 ? MenuBarRoamer.Speed.trot : MenuBarRoamer.Speed.run)
            if let last = keys.last, t < last.t { hold(.watch, last.t - t + 0.1) }
            keys.append(RoamPropKey(t: t + 0.25, x: bx, y: by, path: .flutter))
            let leapStart = t
            act(.leapCatch, leap, travel: 8)
            // It dodges up and flutters on ahead; the last hover is over free bar, where Mochi ends up.
            let beforeFinalLeap = round == rounds - 2
            var next: Double
            if beforeFinalLeap, let free = lingerTarget(from: bx, direction: direction, distance: 26...90) {
                next = free
            } else if beforeFinalLeap {
                next = zone.nearestLinger(to: bx)
                if abs(next - bx) < 20 { next = zone.clamp(bx + direction * uniform(26...52)) }
            } else {
                next = bx + direction * uniform(26...52)
                if next > zone.maxX - 4 || next < zone.minX + 4 {
                    direction = -direction
                    next = bx + direction * uniform(26...52)
                }
            }
            next = zone.clamp(next)
            by = uniform(9...16)
            keys.append(RoamPropKey(t: leapStart + leap * 0.9, x: bx + (next - bx) * 0.3, y: by + 7, path: .flutter))
            keys.append(RoamPropKey(t: leapStart + uniform(1.7...2.2), x: next, y: by, path: .flutter))
            bx = next
            turn(to: bx > x ? 1 : -1)
            direction = facing
            if chance(0.3) { hold(.watch, 0.5) }
        }
        if let last = keys.last, t < last.t { hold(.watch, last.t - t) }
        keys.append(RoamPropKey(t: t + 0.4, x: bx, y: by, path: .flutter))
        keys.append(RoamPropKey(t: t + 2.0, x: zone.clamp(bx + direction * 30), y: 27, opacity: 0, path: .flutter))
        hold(.watch, 1.0)
        act(chance(0.55) ? .confusedTilt : .happyBounce)
        props.append(RoamPropTrack(kind: .butterfly, keys: keys, scale: RoamToys.butterflyScale, variant: Int(uniform(0...1.999))))
    }

    /// A leaf drifts down; Mochi watches it land, sniffs it and bats it away.
    mutating func leafPlay() {
        activity = .leafPlay
        goToLingerSpot()
        var direction = roomyDirection()
        if zone.room(from: x, direction: direction) < 60 { direction = -direction }
        turn(to: direction)
        var keys: [RoamPropKey] = []
        var lx = zone.clamp(x + direction * uniform(24...44))
        if !zone.canLinger(at: lx - direction * 12), let free = lingerTarget(from: x, direction: direction, distance: 12...40) {
            lx = zone.clamp(free + direction * 12)
        }
        let landing = t + 2.8
        keys.append(RoamPropKey(t: t, x: lx - direction * 8, y: 26, opacity: 0))
        keys.append(RoamPropKey(t: t + 0.4, x: lx - direction * 7, y: 22))
        keys.append(RoamPropKey(t: landing, x: lx, y: RoamToys.leafRest, path: .drift, arc: 4))
        hold(.watch, 1.6)
        move(to: lx - direction * 12, speed: MenuBarRoamer.Speed.walk, atLeast: Swift.max(0, landing - t))
        act(.sniff)
        let contact = t + PetAnimation.bat.defaultDuration * 0.5
        act(.bat)
        keys.append(RoamPropKey(t: contact, x: lx, y: RoamToys.leafRest))
        let flyTo = zone.clamp(lx + direction * 26)
        keys.append(RoamPropKey(t: contact + 0.8, x: lx + (flyTo - lx) * 0.6, y: 10, path: .arc, arc: 5))
        keys.append(RoamPropKey(t: contact + 2.0, x: flyTo, y: RoamToys.leafRest, opacity: 0, path: .drift, arc: 3))
        act(chance(0.5) ? .happyBounce : .blep)
        props.append(RoamPropTrack(kind: .leaf, keys: keys, scale: RoamToys.leafScale, variant: Int(uniform(0...2.999))))
    }

    // MARK: Games the user asked for

    /// Play: a ball tossed out of the bed (where the user clicked) lands in front of Mochi.
    /// Mochi spots it, chases it along the bar, bats and pounces, catches it in a leap and
    /// carries it back to bed. The follow-up after Play in the popover is a shorter rally.
    mutating func userBall(followUp: Bool) {
        activity = followUp ? .followUpPlay : .userPlay
        let home = zone.homeX
        let away = abs(x - home) > 30
        var direction: Double = away ? (home > x ? 1 : -1) : roomyDirection()
        if !away, zone.room(from: home, direction: direction) < 60 { direction = -direction }
        let resting = RoamToys.ballRest
        var keys: [RoamPropKey] = []
        var landing: Double
        if away {
            landing = zone.clamp(x + direction * uniform(24...36))
        } else {
            landing = zone.clamp(home + direction * uniform(42...66))
        }
        let throwStart = t
        if followUp {
            // It rolls out of the bed by itself.
            keys.append(RoamPropKey(t: throwStart, x: home, y: resting, opacity: 0))
            keys.append(RoamPropKey(t: throwStart + 0.1, x: home + direction * 2, y: resting))
            keys.append(RoamPropKey(t: throwStart + 1.1, x: landing, y: resting, path: .easeOut))
        } else {
            // Tossed out of the bed in a high arc, two bounces.
            keys.append(RoamPropKey(t: throwStart, x: home, y: 8, opacity: 0))
            keys.append(RoamPropKey(t: throwStart + 0.08, x: home + direction * 2, y: 10))
            keys.append(RoamPropKey(t: throwStart + 0.62, x: landing, y: resting, path: .arc, arc: 11))
            keys.append(RoamPropKey(t: throwStart + 0.88, x: landing + direction * 4, y: resting, path: .arc, arc: 3.6))
            keys.append(RoamPropKey(t: throwStart + 1.04, x: landing + direction * 6, y: resting, path: .arc, arc: 1.1))
            landing += direction * 6
        }
        stepDown()
        hold(.watch, 0.35, facing: landing >= x ? 1 : -1, style: .notice)
        let ready = throwStart + (followUp ? 1.1 : 1.04)
        let chaseDirection: Double = landing >= x ? 1 : -1
        move(to: landing - chaseDirection * 14, speed: MenuBarRoamer.Speed.run, atLeast: Swift.max(0, ready - t - 0.05))
        if t < ready { hold(.watch, ready - t) }
        rally(&keys, ball: landing, direction: chaseDirection, resting: resting, swipes: followUp ? 1 : Int(uniform(2...3.99)),
              yarn: false, finish: .carryHome)
        act(.happyBounce)
        props.append(RoamPropTrack(kind: .ball, keys: keys, scale: RoamToys.ballScale))
    }

    /// The side of the bed with free bar close by (where a treat or crumbs can land without
    /// Mochi covering an icon to eat them), or nil when both sides are busy.
    mutating func freeSideNearHome(within distance: ClosedRange<Double>) -> (direction: Double, spot: Double)? {
        var sides: [(Double, Double)] = []
        for direction in [-1.0, 1.0] {
            var range = distance
            if context.companionPresent, direction == zone.companionSide {
                // Not on top of Patch: past him.
                let beyond = abs(zone.companionX - zone.homeX) + 14
                range = Swift.max(distance.lowerBound, beyond)...Swift.max(distance.upperBound, beyond + 20)
            }
            if let spot = lingerTarget(from: zone.homeX, direction: direction, distance: range) { sides.append((direction, spot)) }
        }
        return sides.min { abs($0.1 - x) < abs($1.1 - x) }.map { (direction: $0.0, spot: $0.1) }
    }

    /// Treat: a cookie tossed out of the bed (where the user clicked) lands on free bar by the bed.
    /// Ears up, Mochi hurries over from wherever it is, has a good sniff, then munches it (crumbs
    /// flying), licks its lips and bounces happily.
    mutating func userTreat() {
        activity = .userTreat
        let home = zone.homeX
        // Where Mochi will sit and eat: free bar near the bed, else just in front of Mochi.
        var seat: Double
        if let free = freeSideNearHome(within: 18...46) {
            seat = free.spot
        } else {
            var direction: Double = abs(x - home) > 30 ? (home > x ? 1 : -1) : roomyDirection()
            if zone.room(from: x, direction: direction) < 50 { direction = -direction }
            seat = zone.clamp(x + direction * uniform(22...32))
        }
        // It lands just beyond the seat, as seen from Mochi.
        let side: Double = abs(seat - x) > 1 ? (seat > x ? 1 : -1) : (zone.room(from: seat, direction: 1) > zone.room(from: seat, direction: -1) ? 1 : -1)
        let landing = zone.clamp(seat + side * 9)
        let resting = RoamToys.treatRest
        var keys: [RoamPropKey] = []
        let throwStart = t
        let toss: Double = landing >= home ? 1 : -1
        keys.append(RoamPropKey(t: throwStart, x: home, y: 8, opacity: 0))
        keys.append(RoamPropKey(t: throwStart + 0.08, x: home + toss * 2, y: 10))
        keys.append(RoamPropKey(t: throwStart + 0.6, x: landing - toss * 1.5, y: resting, path: .arc, arc: 10))
        keys.append(RoamPropKey(t: throwStart + 0.8, x: landing, y: resting, path: .arc, arc: 2.2))
        stepDown()
        hold(.watch, 0.45, facing: landing >= x ? 1 : -1, style: .notice)
        let distance = abs(seat - x)
        move(to: seat, speed: distance > 60 ? MenuBarRoamer.Speed.run : MenuBarRoamer.Speed.trot, atLeast: Swift.max(0, throwStart + 0.8 - t))
        turn(to: side)
        act(.sniff, PetAnimation.sniff.defaultDuration * 0.8)
        // Picks it up: from here on it is in Mochi's paws.
        keys.append(RoamPropKey(t: t, x: landing, y: resting))
        keys.append(RoamPropKey(t: t + 0.12, x: x + side * 3, y: 7, opacity: 0, path: .linear))
        props.append(RoamPropTrack(kind: .treat, keys: keys, scale: RoamToys.treatScale))
        let munch = 2.6
        crumbs(from: x + side * 3.5, start: t + 0.35, every: 0.55, until: t + munch - 0.2, side: side)
        hold(.sit, munch, held: .treat, style: .munch)
        act(.blep)
        act(.happyBounce)
    }

    /// After a treat in the popover: a few crumbs fell out of the bed; Mochi snuffles them up.
    mutating func crumbHunt() {
        activity = .crumbHunt
        stepDown()
        let home = zone.homeX
        var direction = freeSideNearHome(within: 12...40)?.direction ?? roomyDirection()
        if zone.room(from: home, direction: direction) < 40 { direction = -direction }
        var spots: [Double] = []
        for index in 0..<3 {
            spots.append(zone.clamp(home + direction * (10 + Double(index) * uniform(9...14))))
        }
        // They tumble out of the bed first.
        for (index, spot) in spots.enumerated() {
            let born = t + Double(index) * 0.12
            props.append(RoamPropTrack(kind: .crumb, keys: [
                RoamPropKey(t: born, x: home, y: 5, opacity: 0),
                RoamPropKey(t: born + 0.05, x: home + direction, y: 6),
                RoamPropKey(t: born + 0.5, x: spot, y: RoamToys.crumbRest, path: .arc, arc: 4),
            ], scale: RoamToys.crumbScale, variant: index))
        }
        hold(.watch, 0.6, facing: direction, style: .notice)
        for (index, spot) in spots.enumerated() {
            move(to: spot - direction * 6, speed: MenuBarRoamer.Speed.walk)
            act(.sniff, 1.1)
            // Gone.
            let eaten = t
            if let track = props.firstIndex(where: { $0.kind == .crumb && $0.variant == index && $0.start >= eaten - 3 }) {
                props[track].keys.append(RoamPropKey(t: eaten, x: spot, y: RoamToys.crumbRest))
                props[track].keys.append(RoamPropKey(t: eaten + 0.15, x: spot, y: RoamToys.crumbRest + 1, opacity: 0))
            }
            hold(.idle, 0.25, style: .munch)
        }
        act(.blep)
        goHome(face: zone.companionSide)
    }

    /// Crumbs popping out of the mouth while munching; they land on the bar and fade.
    mutating func crumbs(from mouth: Double, start: TimeInterval, every: TimeInterval, until end: TimeInterval, side: Double) {
        var born = start
        var index = 0
        while born < end {
            let out = (index % 2 == 0 ? 1.0 : -0.6) * side * uniform(3.5...7)
            props.append(RoamPropTrack(kind: .crumb, keys: [
                RoamPropKey(t: born, x: mouth, y: 8.5, opacity: 0),
                RoamPropKey(t: born + 0.04, x: mouth + out * 0.1, y: 9),
                RoamPropKey(t: born + 0.45, x: mouth + out, y: RoamToys.crumbRest, path: .arc, arc: 2.5),
                RoamPropKey(t: born + 1.6, x: mouth + out, y: RoamToys.crumbRest),
                RoamPropKey(t: born + 2.1, x: mouth + out, y: RoamToys.crumbRest, opacity: 0),
            ], scale: RoamToys.crumbScale, variant: index % 3))
            born += every
            index += 1
        }
    }
}

/// Toy sizes and resting heights on the bar (scales are for `EffectRenderer.drawProp` at the
/// bar's pet scale; heights are the toy's centre above the baseline, so it sits on the bar).
public enum RoamToys {
    public static let ballScale = 1.8
    public static let ballRest = 3.3
    public static let yarnScale = 1.75
    public static let yarnRest = 3.4
    public static let butterflyScale = 1.5
    public static let leafScale = 2.2
    public static let leafRest = 2.0
    public static let treatScale = 2.0
    public static let treatRest = 2.8
    public static let crumbScale = 2.2
    public static let crumbRest = 0.9
}
