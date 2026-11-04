import Foundation

// MARK: - Zone

/// The strip of menu bar Mochi may use, in global screen points (x grows to the right).
public struct RoamZone: Equatable, Sendable {
    public var minX: Double
    public var maxX: Double
    /// Mochi's bed, at the status item.
    public var homeX: Double
    /// Where mini Patch sits while it is around (beside the bed).
    public var companionX: Double
    /// Stretches of bar covered by other apps' status items. Mochi may run, leap and play
    /// across them, but rests, naps, sniffs and fidgets only where the bar is free (or in bed).
    public var occupied: [ClosedRange<Double>]
    /// The camera housing right at one end of the strip, when there is one: Mochi's den.
    public var den: RoamDen?

    /// Half of Mochi's footprint on the bar plus a hair of margin: a spot is free when this
    /// much bar on either side of Mochi's centre is clear.
    public static let footprint = 9.0

    public init(minX: Double, maxX: Double, homeX: Double, companionX: Double? = nil, occupied: [ClosedRange<Double>] = [],
                den: RoamDen? = nil) {
        let lo = Swift.min(minX, maxX)
        let hi = Swift.max(minX, maxX)
        self.minX = lo
        self.maxX = hi
        let home = Swift.min(hi, Swift.max(lo, homeX))
        self.homeX = home
        self.companionX = companionX ?? home - 26
        self.occupied = occupied.filter { $0.upperBound > lo && $0.lowerBound < hi }.sorted { $0.lowerBound < $1.lowerBound }
        self.den = den
    }

    public var width: Double { maxX - minX }
    public var midX: Double { (minX + maxX) / 2 }

    public func clamp(_ x: Double) -> Double { Swift.min(maxX, Swift.max(minX, x)) }

    /// +1 when the companion sits to the right of the bed, -1 when it sits to the left.
    public var companionSide: Double { companionX >= homeX ? 1 : -1 }

    /// Room to walk from `x` in a direction, in points.
    public func room(from x: Double, direction: Double) -> Double {
        direction >= 0 ? Swift.max(0, maxX - x) : Swift.max(0, x - minX)
    }

    /// Whether Mochi may stay a while at `x` without covering another app's status item.
    public func canLinger(at x: Double) -> Bool {
        guard x >= minX - 0.01, x <= maxX + 0.01 else { return false }
        if abs(x - homeX) < 1 { return true }
        return !occupied.contains { x + Self.footprint > $0.lowerBound + 0.001 && x - Self.footprint < $0.upperBound - 0.001 }
    }

    /// The ranges of centre positions where Mochi may linger, left to right. The bed always counts.
    public var lingerSpans: [ClosedRange<Double>] {
        var spans: [ClosedRange<Double>] = [minX...maxX]
        for block in occupied {
            let lo = block.lowerBound - Self.footprint
            let hi = block.upperBound + Self.footprint
            spans = spans.flatMap { span -> [ClosedRange<Double>] in
                if hi <= span.lowerBound || lo >= span.upperBound { return [span] }
                var parts: [ClosedRange<Double>] = []
                if lo > span.lowerBound { parts.append(span.lowerBound...lo) }
                if hi < span.upperBound { parts.append(hi...span.upperBound) }
                return parts
            }
        }
        if !spans.contains(where: { $0.contains(homeX) }) {
            spans.append(homeX...homeX)
            spans.sort { $0.lowerBound < $1.lowerBound }
        }
        return spans
    }

    /// The free spot closest to `x` (the bed when nothing else is free).
    public func nearestLinger(to x: Double) -> Double {
        var best = homeX
        for span in lingerSpans {
            let candidate = Swift.min(Swift.max(x, span.lowerBound), span.upperBound)
            if abs(candidate - x) < abs(best - x) { best = candidate }
        }
        return best
    }

    /// Free spots between `lo` and `hi` (clamped to the zone), as ranges of centre positions.
    public func lingerSpans(between lo: Double, and hi: Double) -> [ClosedRange<Double>] {
        let a = Swift.min(lo, hi)
        let b = Swift.max(lo, hi)
        return lingerSpans.compactMap { span in
            let l = Swift.max(span.lowerBound, a)
            let h = Swift.min(span.upperBound, b)
            return l <= h ? l...h : nil
        }
    }

    /// True when `x` is over another app's status item.
    public func isOccupied(_ x: Double) -> Bool { !canLinger(at: x) }

    /// Where Mochi may be: on the strip, or on its way into (or tucked inside) the den.
    public func holds(_ x: Double) -> Bool {
        if x >= minX, x <= maxX { return true }
        guard let den else { return false }
        let depth = den.depth(of: x)
        return depth >= den.depth(of: den.inward < 0 ? minX : maxX) - 0.001 && depth <= RoamDen.maxDepth
    }

    /// The same zone with everything moved by `dx` (the whole bar shifted).
    public func shifted(by dx: Double) -> RoamZone {
        RoamZone(minX: minX + dx, maxX: maxX + dx, homeX: homeX + dx, companionX: companionX + dx,
                 occupied: occupied.map { ($0.lowerBound + dx)...($0.upperBound + dx) },
                 den: den.map { RoamDen(edgeX: $0.edgeX + dx, inward: $0.inward) })
    }
}

// MARK: - Den

/// The camera housing (notch) at the end of Mochi's strip, used as a den: Mochi slips into it
/// to nap, peeks out of it when Claude needs you and bursts out of it to celebrate. The housing
/// has no pixels, so Mochi is simply cut off at its edge.
public struct RoamDen: Equatable, Sendable {
    /// x of the housing's edge on Mochi's side (screen points).
    public var edgeX: Double
    /// +1 when the housing lies to the right of the edge, -1 when it lies to the left.
    public var inward: Double

    /// How deep Mochi's centre goes to be out of sight, tail and all (points past the edge).
    public static let hideDepth = 20.0
    /// Peeking: the centre just outside the edge, so the face and ears show and the rest stays in.
    public static let peekDepth = -1.5
    /// Never deeper than this.
    public static let maxDepth = 30.0

    public init(edgeX: Double, inward: Double) {
        self.edgeX = edgeX
        self.inward = inward >= 0 ? 1 : -1
    }

    /// How far past the edge `x` is (negative on the bar).
    public func depth(of x: Double) -> Double { (x - edgeX) * inward }

    /// The x `depth` points past the edge.
    public func x(depth: Double) -> Double { edgeX + inward * depth }

    /// Inside the housing, or peeking out of its edge.
    public func shelters(_ x: Double) -> Bool { depth(of: x) >= Self.peekDepth - 0.5 }

    /// The part of `lo...hi` that can show (outside the housing); nil when all of it is inside.
    public func visibleSpan(_ lo: Double, _ hi: Double) -> ClosedRange<Double>? {
        let a = Swift.min(lo, hi)
        let b = Swift.max(lo, hi)
        let span = inward < 0 ? Swift.max(a, edgeX)...Swift.max(b, edgeX) : Swift.min(a, edgeX)...Swift.min(b, edgeX)
        return span.upperBound - span.lowerBound > 0.001 ? span : nil
    }
}

// MARK: - Context

/// Everything outside the roamer that decides what Mochi may do on the menu bar.
/// Evaluated by the world at its 4 Hz tick.
public struct RoamContext: Equatable, Sendable {
    /// Patch is at home (a Claude Code session is open or lingering).
    public var companionPresent = false
    /// What Claude is doing in the primary session.
    public var activity: AmbientActivity = .idle
    /// A real reaction or an interaction is playing: hold still where you are.
    public var reacting = false
    /// An interaction with Patch (or a hello) is waiting for Mochi to come home.
    public var summoned = false
    public var popoverOpen = false
    /// The world says the pet is asleep (long inactivity).
    public var asleep = false
    public var quietHours = false
    public var reducedMotion = false
    /// Reactions are paused: no ambient play either.
    public var paused = false
    public var intensity: AnimationIntensity = .normal
    /// Seconds since the last real Claude activity or user interaction.
    public var idleSeconds: TimeInterval = 0
    /// Some naps may happen in the notch (Settings › Fun).
    public var notchDen = false
    /// Patch shows an attention badge: Mochi peeks out of the den if it is in there.
    public var attentionBadge = false
    /// A celebration burst is on: Mochi bursts out of the den if it is in there.
    public var celebrating = false
    /// Mochi is out on a desktop adventure: nothing on the bar until it is back.
    public var away = false

    public init(companionPresent: Bool = false, activity: AmbientActivity = .idle, reacting: Bool = false, summoned: Bool = false,
                popoverOpen: Bool = false, asleep: Bool = false, quietHours: Bool = false, reducedMotion: Bool = false,
                paused: Bool = false, intensity: AnimationIntensity = .normal, idleSeconds: TimeInterval = 0, notchDen: Bool = false,
                attentionBadge: Bool = false, celebrating: Bool = false, away: Bool = false) {
        self.companionPresent = companionPresent
        self.activity = activity
        self.reacting = reacting
        self.summoned = summoned
        self.popoverOpen = popoverOpen
        self.asleep = asleep
        self.quietHours = quietHours
        self.reducedMotion = reducedMotion
        self.paused = paused
        self.intensity = intensity
        self.idleSeconds = idleSeconds
        self.notchDen = notchDen
        self.attentionBadge = attentionBadge
        self.celebrating = celebrating
        self.away = away
    }
}

/// The roamer's behaviour regime, derived from the context (highest rule first).
public enum RoamMode: String, Sendable {
    /// No zone: roaming is off (classic icon, hidden menu bar…).
    case inactive
    /// Out on a desktop adventure: the bed is empty.
    case away
    /// A real reaction or interaction plays where Mochi stands.
    case frozen
    /// Running home because an interaction with Patch is about to start.
    case summoned
    /// Reduced Motion: stays at home, expressions only.
    case reducedMotion
    /// Claude is waiting for the user: at home, facing the viewer.
    case attending
    /// The popover is open: stops and looks up.
    case lookingUp
    /// Long inactivity: sleeps in the bed at home.
    case asleep
    /// Reactions paused: rests at home.
    case paused
    /// Claude is working: sits beside Patch and watches, small moves only.
    case working
    /// Patch is around but Claude is idle: stays near home.
    case companion
    /// Nobody else around: the whole zone is Mochi's.
    case free

    public static func from(_ context: RoamContext) -> RoamMode {
        if context.away { return .away }
        if context.reacting { return .frozen }
        if context.summoned { return .summoned }
        if context.activity == .waiting { return .attending }
        if context.asleep { return .asleep }
        if context.popoverOpen { return .lookingUp }
        if context.paused { return .paused }
        if context.reducedMotion { return .reducedMotion }
        if context.activity == .working { return .working }
        if context.companionPresent { return .companion }
        return .free
    }

    /// Modes a game the user asked for (Play, Treat) does not give way to: they keep
    /// playing until the game ends. Everything else (a real reaction, the popover, a
    /// summons, Reduced Motion, pausing) interrupts it.
    var yieldsToUserGames: Bool {
        switch self {
        case .free, .companion, .working, .attending, .asleep: return true
        default: return false
        }
    }

    /// Modes in which Mochi, napping in the den, peeks out for an attention badge instead of coming out.
    var peeksFromDen: Bool { yieldsToUserGames }
}

/// Games the user starts from the menu bar (or that follow up a Play or Treat from the popover).
public enum RoamUserGame: String, Sendable, CaseIterable {
    /// A ball tossed out of the bed: chase, bat, pounce, catch, carry it home.
    case play
    /// A cookie tossed out of the bed: trot over, sniff, munch with crumbs, lick, bounce.
    case treat
    /// After Play in the popover: the ball rolls out of the bed once more.
    case playFollowUp
    /// After a Treat in the popover: Mochi hunts the crumbs around the bed.
    case treatFollowUp

    public var activity: RoamActivity {
        switch self {
        case .play: return .userPlay
        case .treat: return .userTreat
        case .playFollowUp: return .followUpPlay
        case .treatFollowUp: return .crumbHunt
        }
    }
}

// MARK: - Activities

public enum RoamActivity: String, Codable, Sendable, CaseIterable {
    case rest, wander, trotHome, zoomies, sniffAround, chaseButterfly, ballPlay, yarnPlay, leafPlay, fidget, nap, sleepAtHome
    case nearHome, watchCompanion, sitWithCompanion, attend, lookUp, hold, dashHome, settleHome, pausedRest
    case arrive, userPlay, userTreat, followUpPlay, crumbHunt
    case denNap, denPeek, denBurst, exploring, returning

    public var title: String {
        switch self {
        case .rest: return "Resting"
        case .wander: return "Wandering"
        case .trotHome: return "Trotting home"
        case .zoomies: return "Zoomies"
        case .sniffAround: return "Sniffing around"
        case .chaseButterfly: return "Chasing a butterfly"
        case .ballPlay: return "Playing ball"
        case .yarnPlay: return "Playing with yarn"
        case .leafPlay: return "Watching a leaf"
        case .fidget: return "Fidgeting"
        case .nap: return "Napping"
        case .sleepAtHome: return "Sleeping in bed"
        case .nearHome: return "Pottering near home"
        case .watchCompanion: return "Watching Patch work"
        case .sitWithCompanion: return "Sitting with Patch"
        case .attend: return "Waiting with you"
        case .lookUp: return "Looking up"
        case .hold: return "Holding still"
        case .dashHome: return "Dashing home"
        case .settleHome: return "Settling at home"
        case .pausedRest: return "Resting (paused)"
        case .arrive: return "Hopping in"
        case .userPlay: return "Playing with you"
        case .userTreat: return "Enjoying a treat"
        case .followUpPlay: return "One more throw"
        case .crumbHunt: return "Hunting crumbs"
        case .denNap: return "Napping in the notch"
        case .denPeek: return "Peeking out of the notch"
        case .denBurst: return "Bursting out of the notch"
        case .exploring: return "Exploring the desktop"
        case .returning: return "Back from an adventure"
        }
    }

    /// Bursts of play that use the whole zone.
    public var isPlay: Bool {
        switch self {
        case .zoomies, .chaseButterfly, .ballPlay, .yarnPlay, .leafPlay, .userPlay, .followUpPlay: return true
        default: return false
        }
    }

    /// Games the user asked for: the menu bar shows them instead of the world's own Play/Treat clip.
    public var isUserGame: Bool {
        switch self {
        case .userPlay, .userTreat, .followUpPlay, .crumbHunt: return true
        default: return false
        }
    }

    /// The menu bar shows the roamer's own pose even while the world plays a one-shot: games the
    /// user asked for, and the den (a reaction would otherwise play out of sight in the notch).
    public var overridesWorldPose: Bool {
        isUserGame || self == .denNap || self == .denPeek || self == .denBurst
    }
}

// MARK: - Plan

/// One continuous piece of Mochi's day on the menu bar. Segments are evaluated as
/// pure functions of time and each one starts where the previous one ended.
public struct RoamSegment: Equatable, Sendable {
    public enum Motion: String, Sendable {
        /// Standing still.
        case hold
        /// Walking or running: eases in, cruises, eases out (a trapezoid speed profile).
        case cruise
        /// Eased start and stop (leaps and shuffles inside one-shots).
        case smooth
        /// Starts at full speed and slows to a stop (a skid, or braking out of a run).
        case brake
        /// Reduced Motion: fades out, then in at the destination — no visible travel.
        case fade
    }

    /// Small body-language accents the renderer adds on top of the pose.
    public enum Style: String, Sendable {
        case plain
        /// Gathering for a sprint: squashed low.
        case crouch
        /// Pushing off: a quick stretch out of the crouch.
        case launch
        /// Sliding to a stop out of a run, leaning back.
        case skid
        /// Dropping in from the top of the bar.
        case drop
        /// Landing squash.
        case land
        /// Ears up, looking towards where it is about to go ("huh?").
        case notice
        /// Facing you, eyes open, ears up: Claude is waiting for you.
        case attentive
        /// Chewing a treat.
        case munch
    }

    public var start: TimeInterval
    public var end: TimeInterval
    public var fromX: Double
    public var toX: Double
    public var animation: PetAnimation
    /// +1 facing right, -1 facing left.
    public var facing: Double
    public var motion: Motion
    /// Height above the menu-bar baseline in points at the start (e.g. lying on the bed cushion)…
    public var lift: Double
    /// …and at the end (eased in between), so climbing into bed or dropping in never pops.
    public var liftTo: Double
    /// Something Mochi carries during this segment (a caught ball, a treat).
    public var held: HeldItem?
    public var activity: RoamActivity
    public var style: Style
    /// Distance walked before this segment (Mochi's odometer): gaits are locked to it, so feet never skate.
    public var odometer: Double
    /// Ease in and out of a cruise, in seconds.
    public var easeIn: Double
    public var easeOut: Double
    /// The curve the segment was planned with. A segment cut short keeps following it up to `end`.
    public var curveEnd: TimeInterval
    public var curveToX: Double
    /// Mochi is not on the bar at all (away on a desktop adventure).
    public var hidden: Bool

    public init(start: TimeInterval, end: TimeInterval, fromX: Double, toX: Double, animation: PetAnimation, facing: Double,
                motion: Motion, lift: Double = 0, liftTo: Double? = nil, held: HeldItem? = nil, activity: RoamActivity,
                style: Style = .plain, odometer: Double = 0, easeIn: Double = 0, easeOut: Double = 0, hidden: Bool = false) {
        self.start = start
        self.end = end
        self.fromX = fromX
        self.toX = toX
        self.animation = animation
        self.facing = facing >= 0 ? 1 : -1
        self.motion = motion
        self.lift = lift
        self.liftTo = liftTo ?? lift
        self.held = held
        self.activity = activity
        self.style = style
        self.odometer = odometer
        self.easeIn = easeIn
        self.easeOut = easeOut
        self.curveEnd = end
        self.curveToX = toX
        self.hidden = hidden
    }

    public var duration: TimeInterval { end - start }
    public var travels: Bool { motion != .hold && abs(toX - fromX) > 0.01 }

    public func progress(at t: TimeInterval) -> Double {
        guard end.isFinite else { return 0 }
        guard end > start else { return t >= end ? 1 : 0 }
        return Ease.clamp((t - start) / (end - start))
    }

    /// Fraction of the planned distance covered at `t`, following the planned curve.
    func curveFraction(at t: TimeInterval) -> Double {
        guard curveEnd.isFinite, curveEnd > start else { return t >= curveEnd ? 1 : 0 }
        let local = Swift.min(Swift.max(t, start), Swift.min(end, curveEnd)) - start
        let d = curveEnd - start
        switch motion {
        case .hold: return 0
        case .cruise: return Self.trapezoid(local, d, easeIn, easeOut)
        case .smooth: return Ease.smooth(local / d)
        case .brake:
            let p = Ease.clamp(local / d)
            return 1 - (1 - p) * (1 - p)
        case .fade: return local / d < 0.5 ? 0 : 1
        }
    }

    public func x(at t: TimeInterval) -> Double {
        guard motion != .hold else { return fromX }
        if t >= end { return toX }
        return Ease.lerp(fromX, curveToX, curveFraction(at: t))
    }

    public func lift(at t: TimeInterval) -> Double {
        guard abs(liftTo - lift) > 0.0001 else { return lift }
        return Ease.lerp(lift, liftTo, Ease.smooth(progress(at: t)))
    }

    public func opacity(at t: TimeInterval) -> Double {
        if hidden { return 0 }
        guard motion == .fade, curveEnd > start else { return 1 }
        let p = Ease.clamp((Swift.min(t, end) - start) / (curveEnd - start))
        return abs(1 - 2 * p)
    }

    /// Instantaneous speed in points per second.
    public func speed(at t: TimeInterval) -> Double {
        guard travels, curveEnd.isFinite, curveEnd > start, t >= start, t < end else { return 0 }
        let distance = abs(curveToX - fromX)
        let d = curveEnd - start
        let local = t - start
        switch motion {
        case .cruise: return distance * Self.trapezoidRate(local, d, easeIn, easeOut)
        case .smooth:
            let p = Ease.clamp(local / d)
            return distance / d * 6 * p * (1 - p)
        case .brake:
            let p = Ease.clamp(local / d)
            return distance / d * 2 * (1 - p)
        case .hold, .fade: return 0
        }
    }

    /// Distance covered within the segment at `t` (for the odometer).
    public func travelled(at t: TimeInterval) -> Double { abs(x(at: t) - fromX) }

    /// The top speed of the planned curve (points per second), whatever the moment.
    public var cruiseSpeed: Double {
        guard travels, curveEnd.isFinite, curveEnd > start else { return 0 }
        let distance = abs(curveToX - fromX)
        let d = curveEnd - start
        switch motion {
        case .cruise:
            var a = Swift.max(0, easeIn)
            var b = Swift.max(0, easeOut)
            if a + b > d {
                let k = d / (a + b)
                a *= k
                b *= k
            }
            return distance / Swift.max(0.001, d - (a + b) / 2)
        case .smooth: return distance / d * 1.5
        case .brake: return distance / d * 2
        case .hold, .fade: return 0
        }
    }

    /// Fraction of the distance covered after `t` seconds of a trapezoid profile lasting `d`
    /// seconds that ramps up over `a` and down over `b` (linear changes of speed).
    static func trapezoid(_ t: Double, _ d: Double, _ a0: Double, _ b0: Double) -> Double {
        guard d > 0 else { return 1 }
        var a = Swift.max(0, a0)
        var b = Swift.max(0, b0)
        if a + b > d {
            let k = d / (a + b)
            a *= k
            b *= k
        }
        let cruise = d - a - b
        let total = a / 2 + cruise + b / 2
        guard total > 0 else { return t >= d ? 1 : 0 }
        let tt = Swift.min(Swift.max(t, 0), d)
        let s: Double
        if tt < a {
            s = tt * tt / (2 * a)
        } else if tt <= a + cruise || b <= 0 {
            s = a / 2 + (tt - a)
        } else {
            let r = d - tt
            s = total - r * r / (2 * b)
        }
        return Ease.clamp(s / total)
    }

    /// d(trapezoid)/dt: the fraction of the distance covered per second at `t`.
    static func trapezoidRate(_ t: Double, _ d: Double, _ a0: Double, _ b0: Double) -> Double {
        guard d > 0 else { return 0 }
        var a = Swift.max(0, a0)
        var b = Swift.max(0, b0)
        if a + b > d {
            let k = d / (a + b)
            a *= k
            b *= k
        }
        let cruise = d - a - b
        let total = a / 2 + cruise + b / 2
        guard total > 0 else { return 0 }
        let tt = Swift.min(Swift.max(t, 0), d)
        if tt < a { return tt / a / total }
        if tt <= a + cruise || b <= 0 { return 1 / total }
        return (d - tt) / b / total
    }
}

// MARK: - Props

/// A keyframe of a prop's flight, in menu-bar points.
public struct RoamPropKey: Equatable, Sendable {
    public enum Path: String, Sendable {
        case linear
        /// Decelerating (a rolling ball).
        case easeOut
        case easeInOut
        /// Accelerating downwards (dropped from above).
        case drop
        /// A parabola `arc` points above the straight line.
        case arc
        /// Butterfly flight: eased with a bobbing wobble.
        case flutter
        /// A leaf: drifting down with a side-to-side sway of `arc` points.
        case drift
    }

    public var t: TimeInterval
    public var x: Double
    /// Height of the prop's centre above the baseline, in points.
    public var y: Double
    public var opacity: Double
    /// How the prop travels from the previous key to this one.
    public var path: Path
    public var arc: Double

    public init(t: TimeInterval, x: Double, y: Double, opacity: Double = 1, path: Path = .linear, arc: Double = 0) {
        self.t = t
        self.x = x
        self.y = y
        self.opacity = opacity
        self.path = path
        self.arc = arc
    }
}

public struct RoamPropSample: Equatable, Sendable {
    public var kind: SceneProp.Kind
    public var x: Double
    public var y: Double
    public var rotation: Double
    public var opacity: Double
    public var scale: Double
    public var variant: Int
}

public struct RoamPropTrack: Equatable, Sendable {
    public var kind: SceneProp.Kind
    public var keys: [RoamPropKey]
    public var scale: Double
    public var variant: Int

    public init(kind: SceneProp.Kind, keys: [RoamPropKey], scale: Double = 1, variant: Int = 0) {
        self.kind = kind
        self.keys = keys.sorted { $0.t < $1.t }
        self.scale = scale
        self.variant = variant
    }

    public var start: TimeInterval { keys.first?.t ?? 0 }
    public var end: TimeInterval { keys.last?.t ?? 0 }

    /// Rolling radius used for the spin of balls (points).
    public static let rollRadius = 3.2
    /// Butterfly wing-beat phase per second. `EffectRenderer.drawProp` reads a butterfly's
    /// `rotation` as a monotonic phase (flap = |cos(12·rotation)|): this gives ~9 beats a second.
    public static let flapRate = 2.35

    public func sample(at t: TimeInterval) -> RoamPropSample? {
        guard let first = keys.first, let last = keys.last, t >= first.t, t <= last.t else { return nil }
        var index = 1
        while index < keys.count - 1, keys[index].t < t { index += 1 }
        let a = keys[Swift.max(0, index - 1)]
        let b = keys[Swift.min(keys.count - 1, index)]
        let p = b.t > a.t ? Ease.clamp((t - a.t) / (b.t - a.t)) : 1
        var x: Double
        var y: Double
        switch b.path {
        case .linear:
            x = Ease.lerp(a.x, b.x, p)
            y = Ease.lerp(a.y, b.y, p)
        case .easeOut:
            let e = Ease.outCubic(p)
            x = Ease.lerp(a.x, b.x, e)
            y = Ease.lerp(a.y, b.y, e)
        case .easeInOut:
            let e = Ease.smooth(p)
            x = Ease.lerp(a.x, b.x, e)
            y = Ease.lerp(a.y, b.y, e)
        case .drop:
            x = Ease.lerp(a.x, b.x, p)
            y = Ease.lerp(a.y, b.y, p * p)
        case .arc:
            x = Ease.lerp(a.x, b.x, p)
            y = Ease.lerp(a.y, b.y, p) + b.arc * Ease.hop(p)
        case .flutter:
            // The wobble fades in and out with the leg, so every key is passed exactly.
            let e = Ease.smooth(p)
            let wobble = sin(.pi * p)
            x = Ease.lerp(a.x, b.x, e) + 1.6 * sin(t * 3.3) * wobble
            y = Ease.lerp(a.y, b.y, e) + 2.4 * sin(t * 6.1) * wobble
        case .drift:
            // Sways side to side on the way down, passing exactly through both keys.
            x = Ease.lerp(a.x, b.x, p) + b.arc * sin((t - a.t) * 2.6) * sin(.pi * p)
            y = Ease.lerp(a.y, b.y, p)
        }
        let opacity = Ease.lerp(a.opacity, b.opacity, p)
        let rotation: Double
        switch kind {
        case .ball, .yarn, .treat:
            // Rolling without slipping: the spin follows the distance travelled.
            rotation = x / RoamPropTrack.rollRadius
        case .butterfly:
            rotation = (t - first.t) * RoamPropTrack.flapRate
        case .leaf:
            rotation = 0.6 * sin(t * 2.6)
        case .crumb:
            rotation = (t - first.t) * 7
        default:
            rotation = 0
        }
        return RoamPropSample(kind: kind, x: x, y: y, rotation: rotation, opacity: opacity, scale: scale, variant: variant)
    }
}

// MARK: - Sample

/// Where Mochi is and what it is doing on the menu bar at one instant.
public struct RoamSample: Equatable, Sendable {
    public var x: Double
    /// Height above the baseline in points (bed cushion, dropping in).
    public var lift: Double
    public var facing: Double
    public var opacity: Double
    public var animation: PetAnimation
    /// Time into the segment.
    public var elapsed: TimeInterval
    /// The segment length for one-shots; nil for loops.
    public var duration: TimeInterval?
    public var activity: RoamActivity
    public var props: [RoamPropSample]
    /// Points per second.
    public var speed: Double
    public var held: HeldItem?
    public var segmentEnd: TimeInterval
    /// Total distance walked so far (gaits are locked to it).
    public var odometer: Double = 0
    public var style: RoamSegment.Style = .plain
    /// 0…1 through the current segment (finite segments only).
    public var progress: Double = 0
    /// The segment's length (also for loops; infinite for open-ended holds).
    public var segmentDuration: TimeInterval = .infinity

    public var isTravelling: Bool { speed > 0.5 }
    public var isOneShot: Bool { duration != nil }
}
