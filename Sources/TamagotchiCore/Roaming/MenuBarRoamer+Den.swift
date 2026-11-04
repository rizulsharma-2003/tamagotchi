import Foundation

// MARK: - The den (the notch)

extension RoamBuilder {
    /// The den, when naps may happen there: a notch right at the end of the strip, the setting on.
    var denForNaps: RoamDen? { context.notchDen && !context.reducedMotion ? zone.den : nil }

    /// Walks to `target` even past the end of the strip (into or out of the den), easing in and out.
    mutating func slip(to target: Double, speed: Double) {
        let distance = abs(target - x)
        guard distance > 0.5 else { return }
        let direction: Double = target > x ? 1 : -1
        turn(to: direction)
        let duration = distance / speed + 0.15
        append(RoamSegment(start: t, end: t + duration, fromX: x, toX: target, animation: .walk, facing: direction, motion: .cruise,
                           lift: lift, activity: activity, easeIn: 0.15, easeOut: 0.15))
        t += duration
        x = target
    }

    /// A nap in the den: to the end of the strip by the notch, a sniff, and in Mochi slips, out of
    /// sight (only a few z's drift out). Later a look outside, and out it comes with a stretch.
    mutating func napInDen(_ den: RoamDen, sleep: TimeInterval) {
        activity = .denNap
        let mouth = den.x(depth: -(RoamZone.footprint + 3))
        move(to: mouth, speed: Self.autoSpeed(abs(mouth - x)))
        turn(to: den.inward)
        act(.sniff)
        slip(to: den.x(depth: RoamDen.hideDepth), speed: MenuBarRoamer.Speed.walk * 0.8)
        hold(.curl, sleep)
        act(.wakeUp)
        turn(to: -den.inward)
        slip(to: den.x(depth: RoamDen.peekDepth), speed: MenuBarRoamer.Speed.walk * 0.6)
        hold(.watch, uniform(0.8...1.6), style: .notice)
        slip(to: den.x(depth: -(RoamZone.footprint + 3 + uniform(6...20))), speed: MenuBarRoamer.Speed.walk)
        act(.stretch)
    }

    /// Mochi is in the den (or peeking out of it) as the plan changes. A celebration bursts it out;
    /// Claude needing you (or a badge) brings it to the edge to peek; asleep it stays in. Returns
    /// false when it should simply come out and get on with the new mode.
    mutating func stayInDen(_ den: RoamDen, mode: RoamMode, state: MenuBarRoamer.EndState) -> Bool {
        lift = 0
        if context.celebrating {
            burstOut(of: den)
            open(mode, from: Start(lift: 0, sleeping: false))
            return true
        }
        if mode == .attending || (context.attentionBadge && mode.peeksFromDen) {
            peek(from: den, waking: state.sleeping)
            return true
        }
        if mode == .asleep {
            activity = .denNap
            if !state.sleeping {
                turn(to: den.inward)
                slip(to: den.x(depth: RoamDen.hideDepth), speed: MenuBarRoamer.Speed.walk * 0.8)
            }
            holdForever(.sleep)
            return true
        }
        return false
    }

    /// Claude needs you while Mochi naps in the den: it comes to the edge and peeks out, ears up,
    /// looking around and blinking, until you have answered.
    mutating func peek(from den: RoamDen, waking: Bool) {
        activity = .denPeek
        if waking { act(.wakeUp) }
        turn(to: -den.inward)
        slip(to: den.x(depth: RoamDen.peekDepth), speed: MenuBarRoamer.Speed.walk * 0.7)
        hold(.watch, 0.9, style: .notice)
        for _ in 0..<12 {
            hold(.watch, uniform(8...15))
            act(.lookAround)
        }
        holdForever(.watch)
    }

    /// A celebration while Mochi is in the den: out it bursts in one big hop, sparkles flying from
    /// the edge, onto the bar.
    mutating func burstOut(of den: RoamDen) {
        activity = .denBurst
        let landing = den.x(depth: -(RoamZone.footprint + 3 + uniform(16...30)))
        hold(.idle, 0.12, facing: -den.inward, style: .crouch)
        let start = t
        act(.excitedJump, travel: abs(landing - x))
        for index in 0..<5 {
            let born = start + 0.12 + Double(index) * 0.07
            let height = uniform(5...12)
            props.append(RoamPropTrack(kind: .sparkle, keys: [
                RoamPropKey(t: born, x: den.edgeX, y: height, opacity: 0),
                RoamPropKey(t: born + 0.08, x: den.x(depth: -2), y: height + 1),
                RoamPropKey(t: born + 0.9, x: den.x(depth: -uniform(10...34)), y: height + uniform(2...8), opacity: 0, path: .easeOut),
            ], scale: uniform(1.5...2.2), variant: index))
        }
        act(.happyBounce)
    }

    /// Out of the den, onto the bar.
    mutating func comeOutOfDen(_ den: RoamDen) {
        let previous = activity
        activity = .denNap
        turn(to: -den.inward)
        slip(to: den.x(depth: -(RoamZone.footprint + 3 + uniform(4...14))), speed: MenuBarRoamer.Speed.trot)
        activity = previous
    }
}

// MARK: - Desktop adventures

extension RoamBuilder {
    /// Off on a desktop adventure: a crouch and a hop down through the bottom of the bar, then
    /// nothing here until Mochi is back (at once when it was out of sight in the den already).
    mutating func goAway(from state: MenuBarRoamer.EndState) {
        let sheltered = zone.den?.shelters(x) ?? false
        if !state.hidden, !sheltered, !context.reducedMotion {
            leave(state)
            activity = .exploring
            hold(.idle, 0.2, style: .crouch)
            hold(.idle, 0.3, liftTo: -26, style: .drop)
        }
        activity = .exploring
        holdForever(.idle, hidden: true)
    }

    /// Back from an adventure at `landing`: out of sight it gets there, then pops up through the
    /// bottom of the bar and lands.
    mutating func reappear(at landing: Double) {
        let previous = activity
        activity = .returning
        append(RoamSegment(start: t, end: t + 0.05, fromX: x, toX: landing, animation: .idle, facing: facing, motion: .fade,
                           lift: lift, liftTo: -24, activity: activity, hidden: true))
        t += 0.05
        x = landing
        lift = -24
        if context.reducedMotion {
            hold(.idle, 0.3, liftTo: 0, hidden: true)
        } else {
            hold(.idle, 0.32, liftTo: 7, style: .launch)
            hold(.idle, 0.2, liftTo: 0, style: .drop)
            hold(.idle, 0.2, style: .land)
            hold(.idle, 0.3)
        }
        activity = previous
    }
}
