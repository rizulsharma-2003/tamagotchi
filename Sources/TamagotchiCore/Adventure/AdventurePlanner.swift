import CoreGraphics
import Foundation

// MARK: - Segments

/// One continuous piece of a desktop adventure, a pure function of time like the menu bar's
/// `RoamSegment`. Each one starts where (and when) the previous one ended.
public struct AdventureSegment: Equatable, Sendable {
    public enum Move: String, Sendable {
        /// In place: standing, sitting, sniffing, landing.
        case hold
        /// Along a window top or the floor (eased in and out).
        case walk
        /// A jump in an arc `arc` points above the straight line.
        case hop
        /// Dropping, faster and faster.
        case fall
        /// Up a screen edge.
        case climb
    }

    public enum Phase: Int, Sendable, Comparable {
        /// Dropping in from the menu bar (or out of your hand).
        case arriving
        /// Along window tops, hopping between them.
        case exploring
        /// Down to the floor.
        case descending
        /// A sit on the Dock.
        case dock
        /// Over to a screen edge.
        case toEdge
        /// Up the screen edge.
        case climbing
        /// The hop back up into the menu bar.
        case returning

        public static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }

        public var title: String {
            switch self {
            case .arriving: return "arriving"
            case .exploring: return "exploring"
            case .descending: return "descending"
            case .dock: return "dock"
            case .toEdge: return "toEdge"
            case .climbing: return "climbing"
            case .returning: return "returning"
            }
        }
    }

    public var start: TimeInterval
    public var end: TimeInterval
    public var from: AdventurePoint
    public var to: AdventurePoint
    public var move: Move
    public var animation: PetAnimation
    /// +1 facing right, -1 facing left (climbing: towards the edge).
    public var facing: Double
    /// How high a hop rises above the straight line between its ends.
    public var arc: Double
    /// Body rotation in radians (clockwise on screen) at the start and at the end: a lean into the edge while climbing.
    public var turn: Double
    public var turnTo: Double
    public var phase: Phase
    public var style: RoamSegment.Style
    /// Distance travelled before this segment (gaits are locked to it).
    public var odometer: Double
    /// Something Mochi says as the segment starts.
    public var line: String?

    public var duration: TimeInterval { end - start }

    public func progress(at t: TimeInterval) -> Double {
        guard end > start else { return t >= end ? 1 : 0 }
        return Ease.clamp((t - start) / (end - start))
    }

    /// Ease in and out of walks and climbs, in seconds.
    static let ease = 0.15

    public func point(at t: TimeInterval) -> AdventurePoint {
        let p = progress(at: t)
        switch move {
        case .hold:
            return from
        case .walk, .climb:
            let f = RoamSegment.trapezoid(Swift.min(Swift.max(t, start), end) - start, duration, Self.ease, Self.ease)
            return AdventurePoint(x: Ease.lerp(from.x, to.x, f), y: Ease.lerp(from.y, to.y, f))
        case .hop:
            return AdventurePoint(x: Ease.lerp(from.x, to.x, p), y: Ease.lerp(from.y, to.y, p) + arc * Ease.hop(p))
        case .fall:
            return AdventurePoint(x: Ease.lerp(from.x, to.x, p), y: from.y + (to.y - from.y) * p * p)
        }
    }

    public func rotation(at t: TimeInterval) -> Double {
        guard abs(turnTo - turn) > 0.0001 else { return turn }
        return Ease.lerp(turn, turnTo, Ease.smooth(Ease.segment(progress(at: t), 0, move == .hop ? 0.6 : 1)))
    }

    /// The segment cut short at `t`: from where it started to where Mochi is then.
    func cut(at t: TimeInterval) -> AdventureSegment {
        var copy = self
        copy.to = point(at: t)
        copy.turnTo = rotation(at: t)
        copy.end = Swift.max(start, t)
        return copy
    }
}

/// Where Mochi is and what it does at one instant of an adventure.
public struct AdventureSample: Equatable, Sendable {
    public var point: AdventurePoint
    public var facing: Double
    /// Body rotation in radians, clockwise on screen.
    public var rotation: Double
    public var animation: PetAnimation
    /// Time into the segment.
    public var elapsed: TimeInterval
    /// The segment length for one-shots; nil for loops.
    public var duration: TimeInterval?
    public var move: AdventureSegment.Move
    public var phase: AdventureSegment.Phase
    public var style: RoamSegment.Style
    /// 0…1 through the segment.
    public var progress: Double
    /// Points per second.
    public var speed: Double
    /// Distance travelled so far (gaits are locked to it).
    public var odometer: Double
    /// The plan has run out: Mochi is back in the menu bar.
    public var finished: Bool

    public var isAirborne: Bool { move == .hop || move == .fall }
}

// MARK: - Plan

/// A whole adventure, from the drop out of the menu bar to the hop back up into it.
public struct AdventurePlan: Equatable, Sendable {
    public internal(set) var segments: [AdventureSegment]
    /// Where on the menu bar (screen x) the last hop lands.
    public internal(set) var homeX: Double
    /// The stretch of menu bar Mochi may come back to.
    public internal(set) var bar: ClosedRange<Double>
    /// The screen edge Mochi climbs: +1 right, -1 left.
    public internal(set) var wall: Double
    /// Exploring window tops stops then; the way home takes the rest.
    public internal(set) var exploreUntil: TimeInterval
    public internal(set) var seed: UInt64

    public var start: TimeInterval { segments.first?.start ?? 0 }
    public var end: TimeInterval { segments.last?.end ?? 0 }

    public func segment(at t: TimeInterval) -> AdventureSegment? {
        guard let first = segments.first else { return nil }
        guard t >= first.start else { return first }
        return segments.last { $0.start <= t }
    }

    public func sample(at t: TimeInterval) -> AdventureSample {
        guard let segment = segment(at: t) else {
            return AdventureSample(point: AdventurePoint(x: homeX, y: 0), facing: 1, rotation: 0, animation: .idle, elapsed: 0, duration: nil,
                                   move: .hold, phase: .returning, style: .plain, progress: 1, speed: 0, odometer: 0, finished: true)
        }
        let time = Swift.min(Swift.max(t, segment.start), segment.end)
        let point = segment.point(at: time)
        let travelled = segment.move == .hold ? 0 : point.distance(to: segment.from)
        var speed = 0.0
        if segment.move != .hold, t < segment.end {
            let next = segment.point(at: Swift.min(segment.end, time + 0.01))
            speed = point.distance(to: next) / Swift.max(0.0001, Swift.min(segment.end, time + 0.01) - time)
        }
        let ended = t >= segment.end
        let loops = segment.animation.isLoop
        return AdventureSample(point: point, facing: segment.facing, rotation: segment.rotation(at: time),
                               animation: ended && !loops ? .idle : segment.animation, elapsed: time - segment.start,
                               duration: loops ? nil : segment.duration, move: ended ? .hold : segment.move, phase: segment.phase,
                               style: ended ? .plain : segment.style, progress: segment.progress(at: time), speed: speed,
                               odometer: segment.odometer + travelled, finished: t >= end)
    }
}

// MARK: - Planner

/// Plans Mochi's desktop adventures: a drop out of the menu bar onto whatever is below, a stroll
/// along window tops hopping from one to the next, down to the Dock for a sit, over to the screen
/// edge nearest home, up it, and one hop back up into the menu bar. Deterministic per seed;
/// sampled purely by time; re-routed from where Mochi is when windows move.
public enum AdventurePlanner {
    /// Mochi's size and speeds at adventure scale (points, points per second).
    public struct Metrics: Equatable, Sendable {
        public var halfWidth: Double
        public var height: Double
        public var walk: Double
        public var run: Double
        public var climb: Double

        public init(halfWidth: Double = 26, height: Double = 47) {
            self.halfWidth = halfWidth
            self.height = height
            walk = halfWidth * 2.6
            run = halfWidth * 6.5
            climb = halfWidth * 4.5
        }
    }

    /// Hops reach at most this high, and this far across a gap.
    static let maxRise = 230.0
    static let maxGap = 300.0
    /// Falls accelerate like this (points per second², cartoon gravity).
    static let gravity = 2_400.0
    /// Climbing, Mochi leans this far into the screen edge (radians).
    public static let climbLean = 0.14

    /// - Parameters:
    ///   - start: where Mochi's feet are as it drops in (above the visible area when it comes out of the menu bar).
    ///   - bar: the stretch of menu bar it may come back to (its roaming zone).
    ///   - length: how long the adventure should take, roughly (seconds).
    ///   - facing: which way Mochi faces as it drops in.
    public static func plan(from start: AdventurePoint, at t: TimeInterval, terrain: AdventureTerrain, bar: ClosedRange<Double>, seed: UInt64,
                            metrics: Metrics = Metrics(), length: ClosedRange<Double> = 40...75, facing: Double = 1) -> AdventurePlan {
        var rng = SplitMix64(seed: seed ^ 0x4144_5645_4E54_5552)
        let wall: Double = (bar.lowerBound + bar.upperBound) / 2 >= Double(terrain.bounds.midX) ? 1 : -1
        let total = rng.next(in: length)
        var builder = Builder(t: t, at: start, terrain: terrain, metrics: metrics, rng: rng)
        builder.facing = facing >= 0 ? 1 : -1
        builder.arrive(from: start)
        let exploreUntil = t + Swift.max(4, total - builder.estimateWayHome(wall: wall))
        builder.explore(until: exploreUntil)
        builder.goHome(wall: wall, bar: bar, strollUntil: exploreUntil)
        return AdventurePlan(segments: builder.segments, homeX: builder.homeX, bar: bar, wall: wall, exploreUntil: exploreUntil, seed: seed)
    }

    /// The windows changed. When that takes the ground from under Mochi (or from where it is about
    /// to land), it falls from where it is and carries on from wherever it ends up; when it only
    /// spoils the way ahead, the rest is re-routed from the current spot. Nil when the plan still holds.
    public static func adapt(_ plan: AdventurePlan, at t: TimeInterval, to terrain: AdventureTerrain,
                             metrics: Metrics = Metrics()) -> AdventurePlan? {
        guard t < plan.end, let current = plan.segment(at: t), current.phase <= .descending else { return nil }
        let tolerance = metrics.halfWidth * 0.3
        let sample = plan.sample(at: t)
        func holds(_ point: AdventurePoint) -> Bool { terrain.supports(point, tolerance: tolerance) }
        // Only where Mochi stands counts (a hop's mid-air waypoints never do).
        let standing = plan.segments.filter { $0.end > t && $0.phase <= .descending && ($0.move == .hold || $0.move == .walk) }
        let grounded = !sample.isAirborne && current.move != .climb
        let groundGone = grounded && !holds(sample.point)
        let landingGone = sample.isAirborne && !(standing.first { $0.start >= t }.map { holds($0.from) } ?? true)
        let aheadGone = standing.contains { $0.start > t && (!holds($0.from) || !holds($0.to)) }
        guard groundGone || landingGone || aheadGone else { return nil }

        var kept = plan.segments.filter { $0.end <= t }
        var resumeAt = t
        var from = sample.point
        if !groundGone, !landingGone, t < current.end {
            // Only the way ahead changed: finish what Mochi is doing first (a hop never stops mid-air).
            kept.append(current)
            resumeAt = current.end
            from = current.to
        } else if current.start < t {
            kept.append(current.cut(at: t))
        }
        let mixed = plan.seed ^ UInt64(bitPattern: Int64((resumeAt * 1_000).rounded()))
        var builder = Builder(t: resumeAt, at: from, terrain: terrain, metrics: metrics, rng: SplitMix64(seed: mixed))
        builder.facing = sample.facing
        builder.odometer = sample.odometer
        builder.phase = current.phase
        if !holds(from) { builder.dropToSurface() }
        if builder.phase <= .exploring { builder.explore(until: Swift.max(plan.exploreUntil, resumeAt + 2)) }
        builder.goHome(wall: plan.wall, bar: plan.bar, strollUntil: plan.exploreUntil)
        var adapted = plan
        adapted.segments = kept + builder.segments
        adapted.homeX = builder.homeX
        return adapted
    }

    /// Called home early (Claude needs you, Patch arrived, adventures were turned off): one big
    /// leap from wherever Mochi is straight back up into the menu bar.
    public static func hurryHome(_ plan: AdventurePlan, at t: TimeInterval, terrain: AdventureTerrain,
                                 metrics: Metrics = Metrics()) -> AdventurePlan {
        let sample = plan.sample(at: t)
        guard !sample.finished, sample.phase != .returning || !sample.isAirborne else { return plan }
        var kept = plan.segments.filter { $0.end <= t }
        if let current = plan.segment(at: t), current.start < t, t < current.end { kept.append(current.cut(at: t)) }
        var builder = Builder(t: t, at: sample.point, terrain: terrain, metrics: metrics,
                              rng: SplitMix64(seed: plan.seed ^ UInt64(bitPattern: Int64((t * 1_000).rounded()))))
        builder.facing = sample.facing
        builder.angle = sample.rotation
        builder.odometer = sample.odometer
        builder.phase = .returning
        let home = Swift.min(plan.bar.upperBound, Swift.max(plan.bar.lowerBound, sample.point.x))
        if !sample.isAirborne { builder.hold(.idle, 0.15, style: .crouch) }
        builder.leapHome(to: home)
        var hurried = plan
        hurried.segments = kept + builder.segments
        hurried.homeX = home
        return hurried
    }

    /// A moment in place where Mochi stands (a happy bounce when you pet it); everything after waits
    /// for it. Nil while it is in the air, crouching for a jump, on a wall or on its way home.
    public static func interject(_ animation: PetAnimation, into plan: AdventurePlan, at t: TimeInterval) -> AdventurePlan? {
        guard let index = plan.segments.lastIndex(where: { $0.start <= t }), t < plan.segments[index].end else { return nil }
        let current = plan.segments[index]
        guard current.move == .hold || current.move == .walk, current.phase < .climbing, abs(current.turn) < 0.01,
              current.style == .plain else { return nil }
        let point = current.point(at: t)
        let duration = animation.defaultDuration
        let odometer = current.odometer + (current.move == .hold ? 0 : point.distance(to: current.from))
        var segments = Array(plan.segments[..<index])
        if t > current.start { segments.append(current.cut(at: t)) }
        segments.append(AdventureSegment(start: t, end: t + duration, from: point, to: point, move: .hold, animation: animation,
                                         facing: current.facing, arc: 0, turn: 0, turnTo: 0, phase: current.phase, style: .plain,
                                         odometer: odometer, line: nil))
        // Then the rest of what it was doing, from here.
        var rest = current
        rest.start = t + duration
        rest.end = current.end + duration
        rest.from = point
        rest.odometer = odometer
        rest.line = nil
        segments.append(rest)
        for var later in plan.segments[(index + 1)...] {
            later.start += duration
            later.end += duration
            segments.append(later)
        }
        var result = plan
        result.segments = segments
        if result.exploreUntil > t { result.exploreUntil += duration }
        return result
    }

    // MARK: Builder

    struct Builder {
        var t: TimeInterval
        var at: AdventurePoint
        var facing = 1.0
        /// Current body rotation (on a wall).
        var angle = 0.0
        var odometer = 0.0
        var phase = AdventureSegment.Phase.arriving
        let terrain: AdventureTerrain
        let metrics: Metrics
        var rng: SplitMix64
        var segments: [AdventureSegment] = []
        var homeX = 0.0
        var visited: [Int] = []
        var lines = 0
        var strolled = false

        init(t: TimeInterval, at: AdventurePoint, terrain: AdventureTerrain, metrics: Metrics, rng: SplitMix64) {
            self.t = t
            self.at = at
            self.terrain = terrain
            self.metrics = metrics
            self.rng = rng
            homeX = at.x
        }

        var bounds: CGRect { terrain.bounds }
        var lowX: Double { Double(bounds.minX) + metrics.halfWidth }
        var highX: Double { Double(bounds.maxX) - metrics.halfWidth }

        mutating func uniform(_ range: ClosedRange<Double>) -> Double { rng.next(in: range) }
        mutating func chance(_ p: Double) -> Bool { rng.nextUnit() < p }

        /// A line now and then (never more than three an adventure).
        mutating func say(_ text: String, chance p: Double = 1) -> String? {
            guard lines < 3, chance(p) else { return nil }
            lines += 1
            return text
        }

        // MARK: Primitives

        mutating func append(_ move: AdventureSegment.Move, to target: AdventurePoint, duration: TimeInterval, animation: PetAnimation,
                             arc: Double = 0, turnTo: Double? = nil, style: RoamSegment.Style = .plain, line: String? = nil) {
            let end = turnTo ?? angle
            segments.append(AdventureSegment(start: t, end: t + duration, from: at, to: target, move: move, animation: animation, facing: facing,
                                             arc: arc, turn: angle, turnTo: end, phase: phase, style: style, odometer: odometer, line: line))
            if move != .hold { odometer += at.distance(to: target) }
            t += duration
            at = target
            angle = end
        }

        mutating func hold(_ animation: PetAnimation, _ duration: TimeInterval, style: RoamSegment.Style = .plain, line: String? = nil) {
            guard duration > 0.01 else { return }
            append(.hold, to: at, duration: duration, animation: animation, style: style, line: line)
        }

        mutating func act(_ animation: PetAnimation) { hold(animation, animation.defaultDuration) }

        /// Turns to face `direction` (a beat to swap sides).
        mutating func face(_ direction: Double) {
            let wanted: Double = direction >= 0 ? 1 : -1
            guard wanted != facing else { return }
            facing = wanted
            hold(.idle, 0.1)
        }

        mutating func walk(to x: Double, run: Bool = false) {
            let goal = Swift.min(highX, Swift.max(lowX, x))
            let distance = abs(goal - at.x)
            guard distance > 0.5 else { return }
            face(goal > at.x ? 1 : -1)
            let speed = run ? metrics.run : metrics.walk
            append(.walk, to: AdventurePoint(x: goal, y: at.y), duration: distance / speed + AdventureSegment.ease,
                   animation: run ? .run : .walk)
        }

        mutating func land() { hold(.idle, 0.24, style: .land) }

        /// A jump onto `target`; one well below becomes a little hop off and a drop.
        mutating func hop(to target: AdventurePoint, line: String? = nil) {
            if abs(target.x - at.x) > 2 { face(target.x > at.x ? 1 : -1) }
            hold(.idle, 0.16, style: .crouch)
            let rise = target.y - at.y
            if rise < -70 {
                let off = AdventurePoint(x: at.x + (target.x - at.x) * 0.3, y: at.y)
                append(.hop, to: off, duration: 0.3, animation: .idle, arc: 14, style: .drop, line: line)
                fall(to: target)
                return
            }
            let arc = rise > 0 ? rise / 2 + 24 : 18
            let duration = Swift.min(1.0, Swift.max(0.42, 0.36 + abs(target.x - at.x) / 900 + arc / 500))
            append(.hop, to: target, duration: duration, animation: .idle, arc: arc, style: .drop, line: line)
            land()
        }

        mutating func fall(to target: AdventurePoint, line: String? = nil) {
            let height = Swift.max(1, at.y - target.y)
            append(.fall, to: target, duration: Swift.max(0.22, (2 * height / gravity).squareRoot()), animation: .idle, style: .drop, line: line)
            land()
        }

        /// Down onto whatever is right below.
        mutating func dropToSurface() {
            let below = terrain.surface(below: AdventurePoint(x: at.x, y: at.y - 0.5))
            if at.y - below.y > 0.5 { fall(to: AdventurePoint(x: at.x, y: below.y)) }
        }

        // MARK: Itinerary

        /// Out of the menu bar (or a hand): down onto the first thing below.
        mutating func arrive(from start: AdventurePoint) {
            phase = .arriving
            at = AdventurePoint(x: Swift.min(highX, Swift.max(lowX, start.x)), y: Swift.max(terrain.floorY, start.y))
            let below = terrain.surface(below: at)
            fall(to: AdventurePoint(x: at.x, y: below.y), line: say("Wheee!", chance: 0.7))
        }

        /// Roughly how long the way home takes from here: down, the Dock, the edge, the climb, the hop.
        func estimateWayHome(wall: Double) -> TimeInterval {
            let dockX = terrain.dock.map { ($0.lowerBound + $0.upperBound) / 2 } ?? Double(bounds.midX)
            let wallX = wall > 0 ? highX : lowX
            let down = at.y > terrain.floorY + 1 ? 3.5 : 0
            let toDock = abs(dockX - at.x) / metrics.walk
            let sit = 7.5
            let toWall = abs(wallX - dockX) / metrics.run + 0.5
            let climb = (Double(bounds.maxY) - terrain.floorY) / metrics.climb + 1.2
            return down + toDock + sit + toWall + climb + 1.0
        }

        /// Along window tops and from one to the next, until `deadline`.
        mutating func explore(until deadline: TimeInterval) {
            phase = .exploring
            var hops = 0
            var lingers = 0
            while t < deadline, hops < 8 {
                let current = terrain.ledge(at: at, tolerance: 2)
                if let current {
                    if !visited.contains(current.window) { visited.append(current.window) }
                    beat(on: current)
                }
                guard t < deadline else { break }
                guard let next = pickLedge(from: current) else {
                    // Nowhere to hop to from here: a little longer up here, then down.
                    if current != nil, lingers < 2 {
                        lingers += 1
                        continue
                    }
                    break
                }
                travel(from: current, to: next, first: hops == 0)
                hops += 1
            }
            // Nothing within reach to climb on: a stroll along the floor with the time left.
            if at.y <= terrain.floorY + 0.5 { stroll(until: deadline) }
        }

        /// A few steps and sniffs along the floor (once an adventure).
        mutating func stroll(until deadline: TimeInterval) {
            guard !strolled else { return }
            strolled = true
            var beats = 0
            while t < deadline - 3, beats < 3 {
                beats += 1
                walk(to: at.x + (chance(0.5) ? 1 : -1) * uniform(80...260))
                act(chance(0.6) ? .sniff : .lookAround)
            }
        }

        /// A moment on a window top: a sniff, a look around, a sit or a few steps.
        mutating func beat(on ledge: AdventureLedge) {
            let roll = rng.nextUnit()
            if roll < 0.28 {
                act(.sniff)
            } else if roll < 0.48 {
                act(.lookAround)
            } else if roll < 0.62 {
                hold(.sit, uniform(1.4...2.6))
            } else {
                let direction: Double = chance(0.5) ? 1 : -1
                walk(to: ledge.clamp(at.x + direction * uniform(50...200), margin: metrics.halfWidth * 0.7))
                if chance(0.4) { act(.sniff) }
            }
        }

        /// The next window top within a hop, preferring new ones and the way up.
        mutating func pickLedge(from current: AdventureLedge?) -> AdventureLedge? {
            var options: [(AdventureLedge, Double)] = []
            for ledge in terrain.ledges where ledge != current {
                let rise = ledge.y - at.y
                guard rise <= maxRise, rise > -700 else { continue }
                let lo = current?.minX ?? at.x
                let hi = current?.maxX ?? at.x
                let gap = Swift.max(0, Swift.max(ledge.minX - hi, lo - ledge.maxX))
                guard gap <= maxGap else { continue }
                var weight = 1.0
                if visited.contains(ledge.window) { weight *= 0.12 }
                if rise > 20 { weight *= 1.6 }
                if ledge.width > 220 { weight *= 1.2 }
                options.append((ledge, weight))
            }
            guard !options.isEmpty else { return nil }
            let total = options.reduce(0) { $0 + $1.1 }
            var roll = rng.nextUnit() * total
            for (ledge, weight) in options {
                roll -= weight
                if roll <= 0 { return ledge }
            }
            return options.last?.0
        }

        /// Along the current ledge to the best take-off spot, then a hop onto `target`.
        mutating func travel(from current: AdventureLedge?, to target: AdventureLedge, first: Bool) {
            let margin = metrics.halfWidth * 0.6
            var takeoff = at.x
            if let current {
                let lo = current.minX + margin
                let hi = current.maxX - margin
                let targetLo = target.minX + margin
                let targetHi = target.maxX - margin
                if lo > hi {
                    takeoff = current.midX
                } else if targetHi < lo {
                    takeoff = lo
                } else if targetLo > hi {
                    takeoff = hi
                } else {
                    takeoff = Swift.min(Swift.min(hi, targetHi), Swift.max(Swift.max(lo, targetLo), at.x))
                }
                walk(to: takeoff)
            }
            let direction: Double = target.midX >= at.x ? 1 : -1
            let landing = target.clamp(at.x + direction * uniform(18...70), margin: margin)
            let up = target.y > at.y + 20
            hop(to: AdventurePoint(x: landing, y: target.y), line: up ? say(first ? "Hup!" : "Up we go!", chance: 0.35) : nil)
        }

        /// Down to the floor: off the nearer end of each window top (one with room to drop past it).
        mutating func descend() {
            phase = .descending
            var guardrail = 0
            while at.y > terrain.floorY + 0.5, guardrail < 8 {
                guardrail += 1
                guard let ledge = terrain.ledge(at: at, tolerance: 2) else {
                    dropToSurface()
                    continue
                }
                var side: Double = ledge.maxX - at.x < at.x - ledge.minX ? 1 : -1
                if side > 0, ledge.maxX >= highX - 1 { side = -1 } else if side < 0, ledge.minX <= lowX + 1 { side = 1 }
                let edge = side > 0 ? ledge.maxX - 6 : ledge.minX + 6
                walk(to: edge)
                let out = Swift.min(highX, Swift.max(lowX, edge + side * (metrics.halfWidth + 14)))
                let below = terrain.surface(below: AdventurePoint(x: out, y: at.y - 1))
                hop(to: AdventurePoint(x: out, y: below.y))
            }
        }

        /// The rest of the way: down (strolling the floor if there is time left until `strollUntil`),
        /// a sit on the Dock, over to the edge, up it and back into the menu bar.
        mutating func goHome(wall: Double, bar: ClosedRange<Double>, strollUntil: TimeInterval) {
            if phase <= .descending {
                descend()
                stroll(until: strollUntil)
            }
            if phase <= .dock { visitDock() }
            if phase <= .toEdge {
                phase = .toEdge
                let foot = wall > 0 ? highX - 2 : lowX + 2
                walk(to: foot, run: abs(foot - at.x) > 160)
            }
            if phase <= .climbing { climb(wall: wall) }
            phase = .returning
            hold(.idle, 0.25, style: .crouch)
            leapHome(to: wall > 0 ? bar.upperBound : bar.lowerBound, line: say("Home time!", chance: 0.4))
        }

        mutating func visitDock() {
            phase = .dock
            let span = terrain.dock ?? (Double(bounds.minX) + Double(bounds.width) * 0.3)...(Double(bounds.maxX) - Double(bounds.width) * 0.3)
            let lo = Swift.max(lowX, span.lowerBound + metrics.halfWidth)
            let hi = Swift.min(highX, span.upperBound - metrics.halfWidth)
            let spot = lo < hi ? Swift.min(hi, Swift.max(lo, at.x + uniform(-120...120))) : (span.lowerBound + span.upperBound) / 2
            walk(to: spot, run: abs(spot - at.x) > 260)
            hold(.idle, 0.3)
            hold(.sit, uniform(3.5...6), line: say("Comfy!", chance: 0.35))
            act(chance(0.5) ? .lookAround : .yawn)
            hold(.sit, uniform(0.8...1.6))
        }

        /// Onto the screen edge with a little spring, and up it paw over paw, upright and leaning into
        /// it, to just under the menu bar.
        mutating func climb(wall: Double) {
            phase = .climbing
            face(wall)
            let side: Double = wall >= 0 ? 1 : -1
            // The front of the body against the edge.
            let x = (side > 0 ? Double(bounds.maxX) : Double(bounds.minX)) - side * metrics.halfWidth * 0.8
            if abs(at.x - x) > 1 {
                hold(.idle, 0.18, style: .crouch)
                append(.hop, to: AdventurePoint(x: x, y: at.y + 22), duration: 0.34, animation: .idle, arc: 10,
                       turnTo: side * AdventurePlanner.climbLean, style: .launch)
            }
            let top = Double(bounds.maxY) - metrics.height - 6
            if top > at.y + 1 {
                append(.climb, to: AdventurePoint(x: x, y: top), duration: (top - at.y) / metrics.climb + 2 * AdventureSegment.ease,
                       animation: .walk)
            }
            hold(.idle, 0.35, style: .notice)
        }

        /// The last hop: up into the menu bar at `x`, out of sight behind it.
        mutating func leapHome(to x: Double, line: String? = nil) {
            phase = .returning
            homeX = x
            let target = AdventurePoint(x: x, y: Double(bounds.maxY) + metrics.height + 12)
            let rise = target.y - at.y
            let duration = Swift.min(1.1, 0.45 + rise / 1_600 + abs(x - at.x) / 2_400)
            if abs(x - at.x) > 2 { facing = x > at.x ? 1 : -1 }
            append(.hop, to: target, duration: duration, animation: .idle, arc: Swift.max(24, rise * 0.25), turnTo: 0, style: .launch, line: line)
        }
    }
}
