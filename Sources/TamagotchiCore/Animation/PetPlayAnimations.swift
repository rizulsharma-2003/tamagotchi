import Foundation

/// Mochi's play stories (≈5 s each). The variant is chosen from the start time, so
/// each press of Play can tell a different story. Props live in world space (body
/// widths from Mochi's home, body heights above the floor) and stay put while Mochi
/// moves around them. Every story starts and ends at home, upright; travel only goes
/// forwards (towards the companion), because the desktop window has almost no room
/// behind Mochi's tail, and airborne props stay below about 1.6 body heights.
enum PetPlay {
    static let natural = 5.0
    static let variants = ["Ball chase", "Yarn tangle", "Butterfly", "Bubbles"]
    static let k = PetPoseEvaluator.bodyWidthsPerPathUnit

    static func pose(_ p: inout PetPose, t raw: Double, d: Double, context: PoseContext, variant: Int, lite: Bool) {
        let t = PetPoseEvaluator.fit(raw, natural: natural, d: d)
        if context.reducedMotion {
            calm(&p, t: t, variant: variant, lite: lite)
            return
        }
        switch variant {
        case 0: ballChase(&p, t: t, context: context, lite: lite)
        case 1: yarn(&p, t: t, context: context, lite: lite)
        case 2: butterfly(&p, t: t, context: context, lite: lite)
        default: bubbles(&p, t: t, context: context, lite: lite)
        }
    }

    // MARK: Shared gestures

    /// Points the eyes at a world-space target; with `head` the head turns after them and
    /// the chin lifts for things overhead.
    static func look(_ p: inout PetPose, atWorld bx: Double, _ by: Double, strength: Double = 1, head: Double = 0) {
        let ex = p.x * k
        let ey = p.y + 0.55
        let lx = Ease.clamp((bx - ex) / 0.85, -1, 1)
        let ly = Ease.clamp(-(by - ey) / 0.9, -1, 1)
        p.lookX = Ease.lerp(p.lookX, lx, strength)
        p.lookY = Ease.lerp(p.lookY, ly, strength)
        guard head > 0 else { return }
        let side = p.facing >= 0 ? 1.0 : -1.0
        let w = head * strength
        p.headTurn = Ease.lerp(p.headTurn, 0.7 * lx * side, w)
        // Counter-clockwise (chin up) for a right-facing Mochi.
        p.tilt -= 0.17 * max(0, -ly) * w * side
        p.scaleY += 0.03 * max(0, -ly) * w
    }

    /// Arm value for a bat at `at`: wind up, swipe down through the target, recover.
    static func batArm(_ t: Double, at: Double, high: Double = 0.8, rest: Double = 0.08) -> Double? {
        let start = at - 0.15
        guard t > start, t < at + 0.32 else { return nil }
        if t < at - 0.04 { return Choreo.ramp(t, start, at - 0.04, rest, high) }
        if t < at + 0.06 { return Choreo.ramp(t, at - 0.04, at + 0.06, high, 0) }
        return Choreo.ramp(t, at + 0.06, at + 0.32, 0, rest) + 0.06 * Choreo.bump(t, at + 0.06, at + 0.2)
    }

    /// Arm value for a scoop at `at`: dip under the toy, flick up high, ease down.
    static func scoopArm(_ t: Double, at: Double, from rest: Double) -> Double? {
        guard t > at - 0.16, t < at + 0.42 else { return nil }
        if t < at - 0.07 { return Choreo.ramp(t, at - 0.16, at - 0.07, rest, 0) }
        if t < at + 0.05 { return Choreo.ramp(t, at - 0.07, at + 0.05, 0, 0.95) }
        if t < at + 0.1 { return 0.95 }
        return Choreo.ramp(t, at + 0.1, at + 0.42, 0.95, rest)
    }

    /// A ball (or other round prop) with a soft contact shadow on the floor.
    static func addRolling(_ p: inout PetPose, _ kind: EffectKind, x: Double, y: Double, radius: Double, spin: Double,
                           squash: Double, opacity: Double = 1, scale: Double = 1, x2: Double = 0, y2: Double = 0) {
        guard opacity > 0.01 else { return }
        let height = max(0, y - radius)
        p.addWorld(Effect(.shadow, x: x, y: 0.01, scale: scale * (1 - Ease.clamp(height / 2.2, 0, 0.6)),
                          opacity: opacity * (1 - Ease.clamp(height / 2.4, 0, 0.7))))
        p.addWorld(Effect(kind, x: x, y: y + radius * squash * 0.9, scale: scale, opacity: opacity, rotation: spin,
                          stretch: squash, x2: x2, y2: y2))
    }

    struct Prop {
        var x: Double
        var y: Double
        var spin: Double
        var squash: Double
        var opacity: Double
    }

    // MARK: (a) Ball chase

    static let ballRadius = 0.12
    /// Radians of spin per body width rolled.
    static let ballRoll = 60.0 / 6.5
    static let ballRestA = 1.0
    static let ballRestB = 1.36
    static let headerAt = 3.52
    static let header = (x: 0.62, y: 1.24)

    /// The ball: rolls in, is pinned, squirts out, is scooped up, bonks Mochi's head and rolls away.
    static func ball(_ t: Double) -> Prop {
        let r = ballRadius
        if t < 0.8 {
            let x = Ease.lerp(2.6, ballRestA, Ease.outCubic(Choreo.seg(t, 0, 0.8)))
            let y = r + 0.26 * Choreo.hop(t, 0, 0.32) + 0.11 * Choreo.hop(t, 0.32, 0.55) + 0.04 * Choreo.hop(t, 0.55, 0.7)
            let squash = -0.2 * (Choreo.bump(t, 0.29, 0.37) + 0.6 * Choreo.bump(t, 0.52, 0.58))
            return Prop(x: x, y: y, spin: (x - 2.6) * ballRoll, squash: squash, opacity: Choreo.seg(t, 0, 0.12))
        }
        let spinA = (ballRestA - 2.6) * ballRoll
        if t < 1.96 {
            let rock = 0.14 * sin((t - 0.8) * 7) * exp(-(t - 0.8) * 2.2)
            // Squashed flat under the landing paws.
            return Prop(x: ballRestA, y: r, spin: spinA + rock, squash: -0.38 * Choreo.bump(t, 1.8, 1.96), opacity: 1)
        }
        if t < 2.9 {
            // Squirts out from under the paws and rolls to a stop.
            let x = Ease.lerp(ballRestA, ballRestB, Ease.outCubic(Choreo.seg(t, 1.96, 2.6)))
            let y = r + 0.2 * Choreo.hop(t, 1.96, 2.2) + 0.06 * Choreo.hop(t, 2.2, 2.32)
            let squash = 0.2 * Choreo.bump(t, 1.96, 2.04) - 0.22 * Choreo.bump(t, 2.17, 2.24)
            return Prop(x: x, y: y, spin: spinA + (x - ballRestA) * ballRoll, squash: squash, opacity: 1)
        }
        let spinB = spinA + (ballRestB - ballRestA) * ballRoll
        if t < headerAt {
            // Scooped up, it arcs back over and drops onto Mochi's head.
            let s = Choreo.seg(t, 2.9, headerAt)
            return Prop(x: Ease.lerp(ballRestB, header.x, s), y: Ease.lerp(r, header.y, s) + 0.68 * Ease.hop(s), spin: spinB - 10 * s,
                        squash: 0.15 * Choreo.bump(t, 2.9, 3.0), opacity: 1)
        }
        if t < 4.1 {
            // Boing: off the head, up and away to the right.
            let s = Choreo.seg(t, headerAt, 4.1)
            return Prop(x: Ease.lerp(header.x, 2.2, s), y: Ease.lerp(header.y, r, s) + 0.45 * Ease.hop(s), spin: spinB - 10 - 12 * s,
                        squash: -0.3 * Choreo.bump(t, headerAt, headerAt + 0.08), opacity: 1)
        }
        let x = Ease.lerp(2.2, 3.0, Ease.outCubic(Choreo.seg(t, 4.1, 5.0)))
        let y = r + 0.16 * Choreo.hop(t, 4.12, 4.34) + 0.05 * Choreo.hop(t, 4.34, 4.46)
        return Prop(x: x, y: y, spin: spinB - 22 - (x - 2.2) * ballRoll, squash: -0.22 * Choreo.bump(t, 4.1, 4.16),
                    opacity: 1 - Choreo.seg(t, 4.4, 4.9))
    }

    static func ballChase(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        // Travel (path units, never behind home): pounce, two bounds after the ball, a little
        // shuffle back under it, then the header knocks Mochi back home in a backward roll.
        var x = 0.2 * Choreo.smooth(Choreo.seg(t, 1.4, 1.85))
        x += 0.05 * Choreo.smooth(Choreo.seg(t, 2.12, 2.42)) + 0.05 * Choreo.smooth(Choreo.seg(t, 2.44, 2.74))
        x -= 0.03 * Choreo.smooth(Choreo.seg(t, 3.2, 3.4))
        x = Ease.lerp(x, 0.03, Choreo.smooth(Choreo.seg(t, 3.64, 4.36)))
        p.x = Ease.lerp(x, 0, Choreo.smooth(Choreo.seg(t, 4.62, 4.96)))

        let bound1 = Choreo.hop(t, 2.12, 2.42)
        let bound2 = Choreo.hop(t, 2.44, 2.74)
        let roll = Choreo.seg(t, 3.64, 4.36)
        let crouch = Choreo.window(t, 0.8, 1.42, fade: 0.16)
        let headerCrouch = Choreo.bump(t, 3.26, 3.46)
        let balled = Choreo.window(t, 3.6, 4.4, fade: 0.17)
        let proud = Choreo.window(t, 4.6, 5.0, fade: 0.15)
        let bounding = Choreo.window(t, 2.1, 2.76, fade: 0.08)
        // The butt-wiggle sways the rear at 4 Hz (a lean, so the feet stay planted).
        let wiggle = sin(2 * .pi * 4 * (t - 0.86)) * Choreo.window(t, 0.86, 1.38, fade: 0.1)
        let noseDown = Choreo.ramp(t, 1.62, 1.84, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 1.9, 2.06)))

        p.scaleY -= (0.14 * crouch + 0.08 * headerCrouch + 0.1 * balled - 0.045 * proud) * m
        p.scaleX += (0.1 * crouch + 0.06 * headerCrouch - 0.06 * balled - 0.02 * proud) * m
        p.scaleY += 0.07 * Choreo.bump(t, 1.4, 1.6) * m
        p.rotation = (-0.1 * Choreo.bump(t, 1.38, 1.6) + 0.3 * noseDown + 0.05 * (bound1 + bound2)) * m
            - 2 * .pi * Ease.smooth(roll)
        let lift = (0.05 * Choreo.hop(t, 0.25, 0.42) + 0.46 * Choreo.hop(t, 1.4, 1.85) + 0.1 * (bound1 + bound2)
                    + 0.16 * Choreo.hop(t, 3.44, 3.74) + 0.1 * Ease.hop(roll)) * m
        // Ride on the floor while tipped or rolling rather than through it.
        p.y = max(lift, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY))
        p.lean = (-0.04 * crouch + 0.06 * wiggle + 0.1 * bounding - 0.03 * headerCrouch + 0.03 * proud) * m

        // Arms.
        let reach = Choreo.window(t, 1.36, 1.94, fade: 0.13)
        let pin = Choreo.window(t, 1.82, 2.1, fade: 0.09)
        var left = 0.22 * Choreo.bump(t, 0.25, 0.5) + 0.62 * reach - 0.15 * pin + 0.25 * (bound1 + bound2)
        var right = 0.22 * Choreo.bump(t, 0.25, 0.5) + 0.68 * reach - 0.15 * pin + 0.25 * (bound1 + bound2)
        if let scoop = scoopArm(t, at: 2.9, from: 0.12) { right = scoop }
        let headerArms = Choreo.window(t, 3.3, 3.8, fade: 0.1)
        left = max(left, 0.45 * headerArms)
        right = max(right, 0.45 * headerArms)
        p.leftArm = max(0, left) * (1 - balled) + 0.12 * proud
        p.rightArm = max(0, right) * (1 - balled) + 0.12 * proud
        p.holdFront = 0.85 * balled
        let stepPhase = 2 * .pi * 3.4 * (t - 2.12)
        p.step = sin(stepPhase) * bounding + 0.6 * sin(2 * .pi * 5 * (t - 3.2)) * Choreo.window(t, 3.2, 3.42, fade: 0.05)
        p.stride = -cos(stepPhase) * bounding

        // Tail.
        p.tailWag = (0.8 * sin(2 * .pi * 4 * (t - 0.86) + 1.4) * crouch + 0.9 * sin(g * 10) * proud) * m
            + p.tailWag * (1 - crouch) * (1 - proud)
        p.tailLift = 0.45 * crouch + 0.95 * proud + 0.3 * Choreo.window(t, 0.25, 0.8, fade: 0.1) - 0.5 * balled
        p.tailCurl = -0.8 * bounding + 0.3 * proud + 0.9 * balled

        guard !lite else { return }
        let ball = ball(t)
        let dizzy = Choreo.window(t, 4.3, 4.66, fade: 0.08)
        p.earPerk = Choreo.perk(t, 0.25, 0.55, 0.1, 1.0) - 0.15 * crouch - 0.6 * bounding - 1.0 * balled + 0.2 * proud
            + 0.3 * Choreo.window(t, 2.9, 3.4, fade: 0.1)
        p.earLeft -= 0.3 * bounding + 0.25 * balled
        p.earRight -= 0.3 * bounding + 0.25 * balled
        p.eyeScale = 1 + 0.25 * Choreo.window(t, 0.25, 2.1, fade: 0.25) + 0.15 * Choreo.window(t, 2.95, 3.45, fade: 0.1)
        p.eyeSparkle = 0.5 * crouch + 0.8 * proud
        switch t {
        case ..<0.25: p.eyes = .open; p.mouth = .cat
        case ..<0.8: p.eyes = .wide; p.mouth = .o
        case ..<1.4: p.eyes = .wide; p.mouth = .tiny
        case ..<1.85: p.eyes = .wide; p.mouth = .open
        case ..<2.1: p.eyes = .wide; p.mouth = .o
        case ..<2.76: p.eyes = .open; p.mouth = .pant
        case ..<2.98: p.eyes = .wide; p.mouth = .tiny
        case ..<3.44: p.eyes = .wide; p.mouth = .o
        case ..<3.56: p.eyes = .wide; p.mouth = .open
        case ..<3.66: p.eyes = .squint; p.mouth = .open
        case ..<4.34: p.eyes = .closed; p.mouth = .o
        case ..<4.62: p.eyes = .dizzy; p.mouth = .wavy
        default: p.eyes = .open; p.mouth = .smile
        }
        p.blush = 0.4 + 0.35 * Choreo.seg(t, 3.7, 4.2)
        if t < 3.6 {
            look(&p, atWorld: ball.x, ball.y, strength: Choreo.smooth(Choreo.seg(t, 0.25, 0.45)), head: 1 - bounding)
        } else if t < 4.62 {
            p.lookX = 0
            p.lookY = 0
            p.headTurn = 0
        } else {
            // Proud: chest out, chin up, tail high.
            p.lookX = 0.12
            p.lookY = -0.12
            p.headTurn = 0.2 * proud
            p.tilt -= 0.06 * proud
        }
        p.tilt += 0.1 * sin((t - 4.3) * 14) * dizzy

        // Props and particles.
        addRolling(&p, .ball, x: ball.x, y: ball.y, radius: ballRadius, spin: ball.spin, squash: ball.squash, opacity: ball.opacity)
        if t > 0.25, t < 0.85 {
            let pop = Ease.outBack(Choreo.seg(t, 0.25, 0.4), 2.4)
            p.add(Effect(.notice, x: 0.3, y: 1.12 + 0.04 * pop, scale: pop, opacity: 1 - Choreo.seg(t, 0.7, 0.85), rotation: 0.25))
        }
        if t > 1.44, t < 1.84 {
            PetFX.streak(&p, x: -0.42, y: 0.55, angle: 0.3, length: 0.9, amount: 0.75 * Choreo.bump(t, 1.44, 1.84))
        }
        PetFX.dustPuff(&p, age: t - 1.84, worldX: 0.2 * k + 0.38, strength: 0.7)
        if t > 2.84, t < 3.04 {
            PetFX.streak(&p, x: 0.52, y: 0.4, angle: -0.9, length: 0.85, amount: Choreo.bump(t, 2.84, 3.04), side: 1)
        }
        if t > headerAt - 0.02, t < headerAt + 0.3 {
            let age = Choreo.seg(t, headerAt - 0.02, headerAt + 0.3)
            p.add(Effect(.burst, x: 0.02, y: 1.1, scale: 0.85, opacity: 1 - age, variant: 1, phase: age))
        }
        PetFX.dizzyStars(&p, t: t, amount: 0.9 * dizzy, y: 1.08)
    }

    // MARK: (b) Yarn tangle

    static let yarnRadius = 0.13
    static let yarnRoll = 60.0 / 7
    /// Right, left, right: two bats and a boop that sends it rolling ahead.
    static let yarnBats: [Double] = [0.86, 1.36, 1.84]
    static let yarnStops: [Double] = [0.62, -0.22, 0.72, 0.95]
    static let yarnGrab = 2.4
    static let yarnRelease = 3.6
    static let yarnDrop = 0.42

    /// The yarn ball on the floor (nil while Mochi holds it).
    static func yarnBall(_ t: Double) -> Prop? {
        let r = yarnRadius
        if t < 0.72 {
            let x = Ease.lerp(2.4, yarnStops[0], Ease.outCubic(Choreo.seg(t, 0, 0.72)))
            return Prop(x: x, y: r, spin: (x - 2.4) * yarnRoll, squash: 0, opacity: Choreo.seg(t, 0, 0.12))
        }
        if t < yarnGrab {
            var x = yarnStops[0]
            var hop = 0.0
            var squash = 0.0
            for (index, at) in yarnBats.enumerated() {
                let s = Ease.outCubic(Choreo.seg(t, at + 0.04, at + (index == 2 ? 0.55 : 0.42)))
                if t > at + 0.04 { x = Ease.lerp(yarnStops[index], yarnStops[index + 1], s) }
                hop += 0.05 * Choreo.hop(t, at + 0.03, at + 0.2)
                squash -= 0.22 * Choreo.bump(t, at - 0.02, at + 0.06)
            }
            return Prop(x: x, y: r + hop, spin: (x - 2.4) * yarnRoll, squash: squash, opacity: 1)
        }
        if t < yarnRelease { return nil }
        // Dropped in front as Mochi sits up, then (once shaken free) it rolls away off-stage.
        let fall = Choreo.seg(t, yarnRelease, yarnRelease + 0.16)
        let away = Ease.smooth(Choreo.seg(t, 4.5, 5.0))
        let x = Ease.lerp(yarnDrop, 2.6, away)
        let y = r + 0.16 * (1 - fall * fall) + 0.04 * Choreo.hop(t, yarnRelease + 0.16, yarnRelease + 0.3)
        return Prop(x: x, y: y, spin: (x - 2.4) * yarnRoll, squash: -0.2 * Choreo.bump(t, yarnRelease + 0.12, yarnRelease + 0.2),
                    opacity: 1 - Choreo.seg(t, 4.7, 4.98))
    }

    static func yarn(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        let rally = Choreo.window(t, 0.72, 2.0, fade: 0.15)
        let onBack = Choreo.ramp(t, yarnGrab, 2.62, 0, 1) * (1 - Choreo.ramp(t, 3.42, 3.72, 0, 1))
        let kicking = Choreo.window(t, 2.62, 3.42, fade: 0.1)
        let tangled = Choreo.window(t, 3.66, 4.05, fade: 0.1)
        let shaking = Choreo.window(t, 4.0, 4.5, fade: 0.1)
        let content = Choreo.window(t, 4.72, 5.0, fade: 0.12)

        // Shuffle after the yarn, pounce on it, slide back as he flops over, sit up near home.
        var x = 0.04 * Choreo.smooth(Choreo.seg(t, 1.0, 1.9))
        x = Ease.lerp(x, 0.22, Choreo.smooth(Choreo.seg(t, 2.05, 2.4)))
        x = Ease.lerp(x, 0.1, Choreo.smooth(Choreo.seg(t, 2.4, 2.66)))
        x = Ease.lerp(x, 0.04, Choreo.smooth(Choreo.seg(t, 3.42, 3.72)))
        p.x = Ease.lerp(x, 0, Choreo.smooth(Choreo.seg(t, 4.55, 4.95)))

        var lean = 0.0
        var left = 0.06
        var right = 0.06
        for (index, at) in yarnBats.enumerated() {
            let rightPaw = index % 2 == 0
            let reachSide = rightPaw ? 1.0 : -1.0
            lean += reachSide * (0.06 * Choreo.bump(t, at - 0.16, at) - 0.04 * Choreo.bump(t, at, at + 0.28))
            if let value = batArm(t, at: at, high: 0.75, rest: 0.06) {
                if rightPaw { right = value } else { left = value }
            }
        }
        // Rolling on the back: rocking, bunny-kicking the yarn hugged to the chest.
        let rock = 0.08 * sin(2 * .pi * 2 * (t - 2.62)) * kicking
        let shake = sin(2 * .pi * 5 * (t - 4.0)) * shaking
        p.rotation = (-1.25 * onBack + rock) * max(m, 0.5) + 0.18 * shake * m - 0.1 * Choreo.bump(t, 2.05, 2.25) * m
        p.scaleY -= (0.04 * rally + 0.1 * kicking + 0.03 * abs(shake) + 0.03 * content) * m
        p.scaleX += (0.03 * rally + 0.06 * kicking + 0.05 * shaking) * m
        let lift = 0.2 * Choreo.hop(t, 2.05, 2.4) * m + 0.03 * Choreo.hop(t, 0.3, 0.48) * m
        p.y = max(lift, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY))
        p.lean = (lean + 0.05 * shake + 0.08 * Choreo.window(t, 1.98, 2.4, fade: 0.1)) * m * (1 - onBack)
        p.holdFront = Choreo.ramp(t, yarnGrab - 0.05, yarnGrab + 0.12, 0, 1) * (1 - Choreo.ramp(t, yarnRelease - 0.1, yarnRelease, 0, 1))
        p.leftArm = left + 0.15 * tangled + 0.5 * Choreo.window(t, 2.0, 2.42, fade: 0.08)
        p.rightArm = right + 0.15 * tangled + 0.5 * Choreo.window(t, 2.0, 2.42, fade: 0.08)
        let bunny = sin(2 * .pi * 3.2 * (t - 2.62))
        p.kick = 0.55 * bunny * kicking
        p.step = 0.5 * sin(2 * .pi * 2.2 * t) * rally + 0.7 * sin(2 * .pi * 3.2 * (t - 2.62) + 1.4) * kicking
        p.stride = 0.5 * cos(2 * .pi * 3.2 * (t - 2.62)) * kicking
        p.tailWag = (0.9 * sin(2 * .pi * 2.2 * t) * rally + 1.4 * sin(2 * .pi * 5 * (t - 4.0) + 1) * shaking
                     + 0.8 * sin(g * 9) * kicking) * m
        p.tailLift = 0.5 * rally - 0.3 * tangled + 0.4 * content
        p.tailCurl = 0.5 * tangled + 0.6 * content

        guard !lite else { return }
        p.earPerk = Choreo.perk(t, 0.3, 0.6, 0.1, 0.85) - 0.5 * tangled - 0.7 * onBack + 0.1 * content
        if shaking > 0 {
            p.earLeft += 0.55 * sin(2 * .pi * 5 * (t - 4.0) - 0.8) * shaking
            p.earRight += 0.55 * sin(2 * .pi * 5 * (t - 4.0) - 0.2) * shaking
        }
        p.eyeScale = 1 + 0.15 * rally + 0.2 * tangled
        switch t {
        case ..<0.3: p.eyes = .open; p.mouth = .cat
        case ..<0.72: p.eyes = .wide; p.mouth = .o
        case ..<2.0:
            let batting = yarnBats.contains { abs(t - $0) < 0.07 }
            p.eyes = .wide
            p.mouth = batting ? .tiny : .grin
        case ..<2.42: p.eyes = .wide; p.mouth = .open
        case ..<3.42: p.eyes = .happy; p.mouth = Int((t - 2.42) * 4) % 2 == 0 ? .grin : .open
        case ..<3.68: p.eyes = .open; p.mouth = .o
        case ..<4.02: p.eyes = .wide; p.mouth = .wavy; p.brows = .confused
        case ..<4.5: p.eyes = .squint; p.mouth = .wavy
        case ..<4.72: p.eyes = .open; p.mouth = .smile
        default: p.eyes = .happy; p.mouth = .cat
        }
        p.blush = 0.45 + 0.3 * kicking + 0.2 * content
        let ball = yarnBall(t)
        if let ball, t < 2.42 {
            look(&p, atWorld: ball.x, ball.y, strength: Choreo.seg(t, 0.25, 0.45), head: 0.8)
        } else if t < 3.42 {
            p.lookX = 0.25
            p.lookY = 0.35
        } else if t < 4.0 {
            // Looks down at the loops round the tummy.
            p.lookX = 0.05 * sin(t * 9)
            p.lookY = 0.75
        } else if t < 4.5 {
            p.lookX = 0
            p.lookY = 0
        } else if let ball {
            look(&p, atWorld: ball.x, ball.y, strength: Choreo.window(t, 4.5, 4.9, fade: 0.12), head: 0.6)
        }
        p.tilt += 0.06 * p.lookX * rally - 0.08 * tangled * sin(t * 4)

        // The yarn: on the floor, hugged to the chest, dropped, rolling away.
        let anchor = p.bodyPoint(18, -15)
        let caught = Choreo.ramp(t, yarnBats[0], yarnBats[0] + 0.2, 0, 1) * (1 - Choreo.ramp(t, 4.05, 4.25, 0, 1))
        if let ball {
            let pet = p.x * k
            let anchorX = Ease.lerp(ball.x + 0.5, pet + anchor.x, caught)
            let anchorY = Ease.lerp(ball.y - 0.1, p.y + anchor.y, caught)
            addRolling(&p, .yarn, x: ball.x, y: ball.y, radius: yarnRadius, spin: ball.spin, squash: ball.squash,
                       opacity: ball.opacity, x2: anchorX - ball.x, y2: anchorY - ball.y)
        } else {
            // Held between the paws (body space, follows the roll): it wobbles with the kicks.
            let chest = p.bodyPoint(0, -17)
            let grab = Choreo.smooth(Choreo.seg(t, yarnGrab, yarnGrab + 0.12))
            let floorX = yarnStops[3] - p.x * k, floorY = yarnRadius - p.y
            let hx = Ease.lerp(floorX, chest.x, grab) + 0.02 * bunny * kicking
            let hy = Ease.lerp(floorY, chest.y, grab) + 0.02 * cos(2 * .pi * 3.2 * (t - 2.62)) * kicking
            p.add(Effect(.yarn, x: hx, y: hy, rotation: (yarnStops[3] - 2.4) * yarnRoll + 3 * (t - yarnGrab)))
            // Its floor shadow fades as it leaves the floor.
            if grab < 1 { p.addWorld(Effect(.shadow, x: yarnStops[3], y: 0.01, opacity: 1 - grab)) }
        }
        // Loops wind round Mochi while he rolls, then fly off in the shake.
        var loops = 0
        for at in [2.72, 2.98, 3.24] where t > at { loops += 1 }
        if loops > 0, t < 4.4 {
            let lastBand = [2.72, 2.98, 3.24][loops - 1]
            let flyOff = Choreo.seg(t, 4.08, 4.4)
            let fadeIn = Choreo.seg(t, lastBand, lastBand + 0.08)
            p.add(Effect(.tangle, x: 0, y: 0.5, scale: 1 + 0.6 * flyOff, opacity: (1 - flyOff) * (0.35 + 0.65 * fadeIn),
                         rotation: 0.3 * sin(t * 3) * flyOff, variant: loops, phase: t))
        }
        PetFX.dizzyStars(&p, t: t, amount: Choreo.window(t, 3.72, 4.0, fade: 0.08), y: 1.12)
        for (index, at) in yarnBats.enumerated() where t > at - 0.05 && t < at + 0.16 {
            let rightPaw = index % 2 == 0
            PetFX.streak(&p, x: rightPaw ? 0.42 : -0.42, y: 0.32, angle: rightPaw ? -1.3 : 1.3 + .pi, length: 0.75,
                         amount: Choreo.bump(t, at - 0.05, at + 0.16), side: rightPaw ? 0 : 1)
        }
        if shaking > 0.3 {
            p.add(Effect(.shakeLines, x: -0.62, y: 0.5, scale: 0.9, opacity: shaking, variant: 0))
            p.add(Effect(.shakeLines, x: 0.62, y: 0.5, scale: 0.9, opacity: shaking, variant: 1))
        }
    }

    // MARK: (c) Butterfly

    static func butterflyPath(_ t: Double, noseX: Double, noseY: Double) -> (x: Double, y: Double, flap: Double, opacity: Double, tilt: Double) {
        let flutterX = 0.07 * sin(2 * .pi * 1.3 * t)
        let flutterY = 0.06 * sin(2 * .pi * 1.9 * t + 0.5)
        let beat = t * 2 * .pi * 3.5
        if t < 1.3 {
            let s = Ease.smooth(Choreo.seg(t, 0, 0.95))
            return (Ease.lerp(2.0, 0.62, s) + flutterX, Ease.lerp(1.42, 1.24, s) + flutterY, beat, Choreo.seg(t, 0, 0.2), -0.2)
        }
        if t < 1.6 {
            // Dodges the first clap: up and back.
            let s = Ease.smooth(Choreo.seg(t, 1.3, 1.52))
            return (Ease.lerp(0.62 + flutterX, 0.08, s), Ease.lerp(1.24 + flutterY, 1.44, s), beat, 1, 0.3 * Choreo.bump(t, 1.3, 1.52))
        }
        if t < 2.18 {
            // Drifts ahead, leading Mochi on.
            let s = Ease.smooth(Choreo.seg(t, 1.6, 2.1))
            return (Ease.lerp(0.08, 0.58, s) + flutterX * s, Ease.lerp(1.44, 1.38, s) + flutterY * s, beat, 1, -0.15 * Choreo.bump(t, 1.6, 2.1))
        }
        if t < 2.8 {
            // Dodges the second clap, then hovers.
            let s = Ease.smooth(Choreo.seg(t, 2.18, 2.4))
            let hover = Choreo.seg(t, 2.4, 2.8)
            return (Ease.lerp(0.58 + flutterX, -0.05, s) + flutterX * hover, Ease.lerp(1.38 + flutterY, 1.46, s) + flutterY * hover, beat, 1,
                    0.3 * Choreo.bump(t, 2.18, 2.4))
        }
        if t < 3.3 {
            // Spirals down onto Mochi's nose and folds its wings.
            let s = Ease.smooth(Choreo.seg(t, 2.8, 3.3))
            let spiral = 0.18 * sin(2 * .pi * 1.6 * (t - 2.8)) * (1 - s)
            let settle = 1 - Choreo.seg(t, 3.05, 3.3)
            return (Ease.lerp(-0.05 + flutterX, noseX, s) + spiral, Ease.lerp(1.46 + flutterY, noseY, s), beat * settle + 1.2 * (1 - settle), 1, 0)
        }
        if t < 3.95 {
            // Resting on the nose, wings slowly opening and closing.
            return (noseX, noseY, 1.2 + 1.1 * sin(2 * .pi * 1.4 * (t - 3.3)), 1, 0)
        }
        // Blown off by the sneeze, it flutters away up and to the right.
        let lift = Ease.outCubic(Choreo.seg(t, 3.95, 4.75))
        return (Ease.lerp(noseX, 1.75, lift) + 0.08 * sin(2 * .pi * 2.2 * t) * lift, Ease.lerp(noseY, 1.45, lift) + 0.05 * sin(2 * .pi * 3 * t) * lift,
                t * 2 * .pi * 4.2, 1 - Choreo.seg(t, 4.4, 4.85), -0.3 * Choreo.bump(t, 3.95, 4.4))
    }

    static let claps: [Double] = [1.33, 2.2]

    static func butterfly(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        // A hop and a clap, a skip after it, another hop and clap, then it lands on his nose.
        let hop1 = Choreo.hop(t, 1.12, 1.55)
        let skip = Choreo.hop(t, 1.62, 1.92)
        let hop2 = Choreo.hop(t, 1.98, 2.42)
        let back = Choreo.smooth(Choreo.seg(t, 4.35, 4.95))
        p.x = 0.12 * Choreo.smooth(Choreo.seg(t, 1.62, 1.92)) * (1 - back)
        p.y = (0.38 * hop1 + 0.07 * skip + 0.42 * hop2 + 0.03 * Choreo.hop(t, 4.45, 4.62) + 0.03 * Choreo.hop(t, 4.66, 4.83)) * m
        let crouch1 = Choreo.bump(t, 0.98, 1.14)
        let crouch2 = Choreo.bump(t, 1.86, 2.0)
        let inhale = Choreo.window(t, 3.55, 3.9, fade: 0.25)
        let sneeze = Choreo.bump(t, 3.87, 4.12)
        let deflated = Choreo.window(t, 2.42, 2.85, fade: 0.12)
        p.scaleY -= (0.11 * crouch1 + 0.12 * crouch2 - 0.06 * inhale + 0.16 * sneeze + 0.04 * deflated) * m
        p.scaleX += (0.08 * crouch1 + 0.09 * crouch2 - 0.03 * inhale + 0.12 * sneeze) * m
        p.lean = (0.03 * Choreo.window(t, 0.2, 1.0, fade: 0.3) + 0.06 * Choreo.window(t, 1.58, 1.96, fade: 0.1)
                  - 0.04 * deflated - 0.04 * inhale + 0.12 * sneeze - 0.03 * Choreo.window(t, 4.35, 4.95, fade: 0.15)) * m
        p.rotation = (0.05 * Choreo.bump(t, 1.12, 1.55) - 0.06 * Choreo.bump(t, 1.98, 2.42)) * m
        let reach1 = Choreo.window(t, 1.08, 1.6, fade: 0.1)
        let reach2 = Choreo.window(t, 1.94, 2.46, fade: 0.1)
        let reach = max(reach1, reach2)
        let clap = Choreo.bump(t, 1.27, 1.39) + Choreo.bump(t, 2.14, 2.26)
        p.leftArm = 0.95 * reach * (1 - 0.18 * clap)
        p.rightArm = 0.95 * reach * (1 - 0.18 * clap)
        // Waving goodbye while backing home.
        let bye = Choreo.window(t, 4.4, 5.0, fade: 0.14)
        let byeWave = sin(2 * .pi * 2.6 * (t - 4.5)) * Choreo.window(t, 4.5, 4.92, fade: 0.08)
        p.rightArm = max(p.rightArm, 0.82 * bye + 0.12 * byeWave)
        p.step = 0.6 * sin(2 * .pi * 3 * (t - 4.4)) * Choreo.window(t, 4.4, 4.95, fade: 0.08)
        p.tailWag = (0.7 * sin(2 * .pi * 1.5 * t) * Choreo.window(t, 0, 2.8, fade: 0.3) + 0.5 * sin(g * 9) * bye) * m
        p.tailLift = 0.5 * Choreo.window(t, 0.2, 2.6, fade: 0.3) + 0.4 * bye - 0.3 * deflated
        p.tailCurl = 0.3

        guard !lite else { return }
        let nose = p.mouthPoint
        let noseX = p.x * k + nose.x + 0.02
        let noseY = p.y + nose.y + 0.06
        let fly = butterflyPath(t, noseX: noseX, noseY: noseY)
        let landed = Choreo.ramp(t, 2.95, 3.3, 0, 1) * (1 - Choreo.ramp(t, 3.95, 4.15, 0, 1))
        let still = Choreo.window(t, 2.95, 3.9, fade: 0.2)
        p.earPerk = 0.9 * Choreo.window(t, 0.15, 2.42, fade: 0.2) + 1.0 * still - 0.5 * deflated
        if sneeze > 0.05 {
            p.earLeft -= 0.45 * sneeze
            p.earRight += 0.45 * sneeze
        }
        if t > 3.4, t < 3.7 { p.earRight += PetLife.flick(t - 3.42) }
        p.crossEyed = Choreo.ramp(t, 2.95, 3.25, 0, 1) * (1 - Choreo.ramp(t, 3.86, 3.92, 0, 1))
        p.eyeScale = 1 + 0.15 * Choreo.window(t, 0.2, 2.42, fade: 0.2) - 0.25 * inhale
        switch t {
        case ..<0.2: p.eyes = .open; p.mouth = .cat
        case ..<1.08: p.eyes = .wide; p.mouth = t < 0.6 ? .o : .smile
        case ..<1.55: p.eyes = .wide; p.mouth = .open
        case ..<1.98: p.eyes = .open; p.mouth = .grin
        case ..<2.42: p.eyes = .wide; p.mouth = .open
        case ..<2.85: p.eyes = .open; p.mouth = .wavy
        case ..<3.5: p.eyes = .wide; p.mouth = Int(t * 8) % 2 == 0 && t > 3.3 ? .cat : .tiny
        case ..<3.88: p.eyes = t > 3.75 ? .squint : .open; p.mouth = .o
        case ..<4.12: p.eyes = .squint; p.mouth = .chomp
        case ..<4.3: p.eyes = .squint; p.mouth = .wavy
        case ..<4.42: p.eyes = .open; p.mouth = .wavy
        default: p.eyes = .happy; p.mouth = .smile
        }
        if t < 2.95 || t > 4.3 {
            look(&p, atWorld: fly.x, fly.y, strength: Choreo.seg(t, 0.15, 0.35) * (t > 4.75 ? 1 - Choreo.seg(t, 4.75, 5.0) : 1), head: 0.9)
        } else {
            p.lookX = 0.02 + 0.03 * sin(t * 13) * still
            p.lookY = 0.1
            p.headTurn = 0
        }
        p.tilt += -0.09 * inhale + 0.05 * sin((t - 4.3) * 24) * Choreo.window(t, 4.3, 4.6, fade: 0.06)
        p.blush = 0.45 + 0.3 * still

        if fly.opacity > 0.01 {
            p.addWorld(Effect(.butterfly, x: fly.x, y: fly.y, scale: 0.95 - 0.33 * landed, opacity: fly.opacity, rotation: fly.tilt, variant: 0, phase: fly.flap))
        }
        for at in claps where t > at && t < at + 0.3 {
            let age = (t - at) / 0.3
            p.add(Effect(.burst, x: 0.04, y: 1.3, scale: 0.65, opacity: 1 - age, variant: 1, phase: age))
        }
        if t > 3.88, t < 4.4 {
            let age = Choreo.seg(t, 3.88, 4.4)
            p.add(Effect(.sneeze, x: nose.x + 0.14, y: nose.y + 0.03, scale: 0.9, opacity: 1 - age * age, phase: age))
        }
        if t > 3.5, t < 3.88 {
            // The tickle builds at the nose.
            p.add(Effect(.sniff, x: nose.x + 0.14, y: nose.y + 0.03, scale: 0.75, opacity: Choreo.window(t, 3.5, 3.88, fade: 0.08),
                         variant: Int(t * 7) % 2, phase: Ease.fract(t * 3.5)))
        }
    }

    // MARK: (d) Bubbles

    struct Bubble {
        var x: Double
        var top: Double
        var low: Double
        var appear: Double
        var popAt: Double
        var size: Double
    }

    /// A bat-pop, a clap-pop at the top of a hop, a nose boop, and one big bubble that
    /// swallows Mochi's head.
    static let bubbleSet: [Bubble] = [
        Bubble(x: 0.66, top: 1.45, low: 0.72, appear: 0.0, popAt: 0.98, size: 1),
        Bubble(x: 0.44, top: 1.48, low: 1.24, appear: 0.25, popAt: 1.5, size: 0.9),
        Bubble(x: 0.9, top: 1.45, low: 0.5, appear: 0.9, popAt: 2.3, size: 0.8),
        Bubble(x: 0.65, top: 1.45, low: 0.62, appear: 1.9, popAt: 3.66, size: 1),
    ]
    static let engulfAt = 3.2

    static func bubblePosition(_ index: Int, _ t: Double, nose: (Double, Double), head: (Double, Double)) -> (x: Double, y: Double, opacity: Double, scale: Double) {
        let b = bubbleSet[index]
        let life = Choreo.seg(t, b.appear, b.popAt)
        let fade = Choreo.seg(t, b.appear, b.appear + 0.3)
        var x = b.x + 0.07 * sin(2 * .pi * 0.9 * t + Double(index))
        var y = Ease.lerp(b.top, b.low, Ease.outCubic(life)) + 0.04 * sin(2 * .pi * 1.3 * t + Double(index) * 2)
        var scale = b.size
        if index == 2 {
            // Drifts down onto the nose for a boop.
            let land = Ease.smooth(Choreo.seg(t, 1.7, 2.3))
            x = Ease.lerp(x, nose.0 + 0.06, land)
            y = Ease.lerp(y, nose.1 + 0.04, land)
        }
        if index == 3 {
            // The big one: swells as it sinks, then settles over the head.
            scale = 1 + 2.4 * Ease.smooth(Choreo.seg(t, 2.3, engulfAt))
            let land = Ease.smooth(Choreo.seg(t, 2.6, engulfAt))
            x = Ease.lerp(x, head.0, land)
            y = Ease.lerp(y, head.1, land)
        }
        return (x, y, fade, scale)
    }

    static func bubbles(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        let k = PetPlay.k
        let hop = Choreo.hop(t, 1.2, 1.62)
        let inside = Choreo.window(t, engulfAt - 0.1, 3.68, fade: 0.15)
        let shaking = Choreo.window(t, 3.72, 4.3, fade: 0.1)
        let fluffed = Choreo.window(t, 4.28, 5.0, fade: 0.15)
        let wobble = sin(2 * .pi * 5 * (t - 3.72)) * shaking
        p.x = 0.1 * Choreo.smooth(Choreo.seg(t, 1.15, 1.55)) * (1 - Choreo.smooth(Choreo.seg(t, 4.4, 4.95)))
        p.rotation = (0.04 * Choreo.bump(t, 0.75, 1.15) - 0.05 * Choreo.bump(t, 1.2, 1.62)) * m + 0.18 * wobble * m
        let crouch = Choreo.bump(t, 1.04, 1.22)
        let boop = Choreo.bump(t, 2.2, 2.4)
        let squish = Choreo.bump(t, 3.1, 3.3)
        p.scaleY -= (0.1 * crouch + 0.05 * boop + 0.06 * squish + 0.03 * abs(wobble)) * m
        p.scaleX += (0.08 * crouch + 0.04 * squish + 0.05 * shaking + 0.06 * fluffed) * m
        let lift = (0.34 * hop + 0.03 * Choreo.hop(t, 4.5, 4.66) + 0.03 * Choreo.hop(t, 4.7, 4.86)) * m
        p.y = max(lift, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY))
        p.lean = (0.05 * Choreo.window(t, 0.6, 1.1, fade: 0.15) + 0.08 * boop + 0.05 * wobble) * m
        var right = 0.08
        if let bat = batArm(t, at: 0.98, high: 0.95, rest: 0.08) { right = bat }
        let clapUp = Choreo.window(t, 1.16, 1.66, fade: 0.1)
        let clap = Choreo.bump(t, 1.44, 1.56)
        p.rightArm = max(right, 0.95 * clapUp * (1 - 0.18 * clap))
        p.leftArm = max(0.08, 0.95 * clapUp * (1 - 0.18 * clap)) + 0.25 * inside
        p.rightArm += 0.25 * inside
        p.step = 0.6 * sin(2 * .pi * 3 * (t - 4.4)) * Choreo.window(t, 4.4, 4.95, fade: 0.08)
        p.tailWag = (0.6 * sin(2 * .pi * 1.6 * t) * (1 - inside) + 1.4 * sin(2 * .pi * 5 * (t - 3.72) + 1.2) * shaking
                     + 0.6 * sin(g * 9) * fluffed) * m
        p.tailLift = 0.4 + 0.3 * fluffed - 0.4 * inside
        p.tailCurl = 0.5 * inside

        guard !lite else { return }
        let nosePoint = p.mouthPoint
        let nose = (p.x * k + nosePoint.x, p.y + nosePoint.y)
        let headPoint = p.bodyPoint(0, -30)
        let head = (p.x * k + headPoint.x, p.y + headPoint.y)
        p.crossEyed = 0.8 * Choreo.window(t, 2.12, 2.38, fade: 0.06)
        p.earPerk = 0.75 - 0.9 * inside - 0.2 * shaking + 0.2 * Choreo.window(t, 2.5, 3.1, fade: 0.15)
        p.eyeScale = 1 + 0.15 * Choreo.window(t, 0.1, 2.4, fade: 0.2) + 0.3 * Choreo.window(t, 2.6, 3.66, fade: 0.15)
        p.cheekLeft = 0.6 * inside
        p.cheekRight = 0.6 * inside
        if shaking > 0 {
            p.earLeft += 0.6 * sin(2 * .pi * 5 * (t - 3.72) - 0.8) * shaking
            p.earRight += 0.6 * sin(2 * .pi * 5 * (t - 3.72) - 0.2) * shaking
        }
        switch t {
        case ..<0.15: p.eyes = .open; p.mouth = .cat
        case ..<0.9: p.eyes = .wide; p.mouth = .o
        case ..<1.05: p.eyes = .squint; p.mouth = .grin
        case ..<1.44: p.eyes = .wide; p.mouth = .open
        case ..<1.62: p.eyes = .squint; p.mouth = .grin
        case ..<2.24: p.eyes = .wide; p.mouth = .smile
        case ..<2.4: p.eyes = .squint; p.mouth = .tiny
        case ..<2.6: p.eyes = .happy; p.mouth = .smile
        case ..<3.66: p.eyes = .wide; p.mouth = t < engulfAt ? .o : .tiny
        case ..<3.74: p.eyes = .squint; p.mouth = .o
        case ..<4.3: p.eyes = .squint; p.mouth = .wavy
        default: p.eyes = .happy; p.mouth = t < 4.6 ? .grin : .smile
        }
        p.blush = 0.45 + 0.35 * Choreo.seg(t, 3.7, 4.3)

        // Look at the next bubble that is still floating.
        var target: (Double, Double)?
        for index in 0..<bubbleSet.count where t < bubbleSet[index].popAt && t > bubbleSet[index].appear {
            let b = bubblePosition(index, t, nose: nose, head: head)
            target = (b.x, b.y)
            break
        }
        if let target, t < 3.05 {
            look(&p, atWorld: target.0, target.1, strength: Choreo.seg(t, 0.1, 0.3), head: 0.8)
        } else if t < 3.7 {
            p.lookX = 0.03
            p.lookY = -0.2
        }

        for index in 0..<bubbleSet.count {
            let b = bubbleSet[index]
            if t > b.appear, t < b.popAt {
                let pos = bubblePosition(index, t, nose: nose, head: head)
                let wob = index == 3 ? t * 5 : t * 3 + Double(index)
                p.addWorld(Effect(.bubble, x: pos.x, y: pos.y, scale: pos.scale, opacity: pos.opacity * (index == 3 ? 0.9 : 1), phase: wob))
            } else if t >= b.popAt, t < b.popAt + 0.35 {
                let pos = bubblePosition(index, b.popAt - 0.001, nose: nose, head: head)
                let age = (t - b.popAt) / 0.35
                p.addWorld(Effect(.pop, x: pos.x, y: pos.y, scale: index == 3 ? 1.8 : 0.9, opacity: 1 - age, variant: 1, phase: age))
            }
        }
        let bat = Choreo.bump(t, 0.92, 1.1)
        if bat > 0.02 { PetFX.streak(&p, x: 0.45, y: 0.8, angle: -1.1, length: 0.7, amount: bat) }
        // Soaked by the big pop: a shake with flying droplets.
        for index in 0..<6 {
            let side = index % 2 == 0 ? -1.0 : 1.0
            PetFX.ballistic(&p, kind: .droplet, t: t, born: 3.66 + Double(index) * 0.09, fromX: p.x * k + side * 0.4,
                            fromY: 0.7 + 0.1 * Double(index % 3), side: side, speed: 0.8 + 0.4 * Ease.hash(index, context.seed),
                            up: 0.8, seed: index, scale: 0.34, life: 0.5, spin: 0)
        }
        if shaking > 0.3 {
            p.add(Effect(.shakeLines, x: -0.62, y: 0.5, scale: 0.9, opacity: shaking, variant: 0))
            p.add(Effect(.shakeLines, x: 0.62, y: 0.5, scale: 0.9, opacity: shaking, variant: 1))
        }
    }

    // MARK: Reduced motion

    /// Calm play: Mochi stays home, the toy fades in and out, and each story keeps its own
    /// little beat with expressions only (a notice, a tangle, a cross-eyed sneeze, a bubble on the nose).
    static func calm(_ p: inout PetPose, t: Double, variant: Int, lite: Bool) {
        guard !lite else { return }
        let present = Choreo.window(t, 0.2, 4.6, fade: 0.4)
        p.earPerk = 0.2 + 0.7 * present
        p.eyes = t < 1.2 ? .wide : .happy
        p.eyeSparkle = 0.6 * Choreo.window(t, 0.3, 1.4, fade: 0.2)
        p.mouth = t < 1.2 ? .o : (t < 4.4 ? .grin : .smile)
        p.blush = 0.4 + 0.35 * Choreo.seg(t, 1.0, 1.6)
        p.lookX = 0.7
        p.lookY = 0.3
        p.rightArm = 0.3 * Choreo.window(t, 1.4, 3.6, fade: 0.5)
        switch variant {
        case 0:
            p.addWorld(Effect(.shadow, x: 0.85, y: 0.01, scale: 1, opacity: present))
            p.addWorld(Effect(.ball, x: 0.85, y: ballRadius, opacity: present))
            p.add(Effect(.notice, x: 0.3, y: 1.14, opacity: Choreo.window(t, 0.3, 1.1, fade: 0.25), rotation: 0.25))
        case 1:
            p.addWorld(Effect(.shadow, x: 0.85, y: 0.01, scale: 1, opacity: present))
            p.addWorld(Effect(.yarn, x: 0.85, y: yarnRadius, opacity: present, x2: -0.7, y2: 0.2))
            // Wound up in the strand for a moment, puzzled, then free.
            let wound = Choreo.window(t, 1.6, 3.4, fade: 0.4)
            p.add(Effect(.tangle, x: 0, y: 0.5, opacity: wound, variant: 2))
            if wound > 0.5 { p.eyes = .wide; p.mouth = .wavy; p.brows = .confused; p.lookY = 0.7; p.lookX = 0 }
        case 2:
            // The butterfly visits, then rests on the nose: cross-eyed, a squinting sneeze, gone.
            let away = Choreo.window(t, 0.2, 1.9, fade: 0.35)
            let onNose = Choreo.window(t, 1.9, 3.9, fade: 0.35)
            p.lookY = -0.4 * away
            p.addWorld(Effect(.butterfly, x: 0.75, y: 1.45, scale: 0.9, opacity: away, phase: 1.4))
            p.addWorld(Effect(.butterfly, x: 0.16, y: 0.48, scale: 0.62, opacity: onNose, phase: 1.2))
            p.crossEyed = onNose
            if onNose > 0.2 { p.lookX = 0; p.lookY = 0.1; p.mouth = .tiny; p.eyes = .wide }
            if t > 3.45, t < 3.95 { p.eyes = .squint; p.mouth = .chomp; p.crossEyed = 0 }
        default:
            // A bubble drifts by, then one rests on the nose and fades with a blink.
            p.lookY = -0.3
            p.addWorld(Effect(.bubble, x: 0.7, y: 1.3, opacity: Choreo.window(t, 0.2, 2.2, fade: 0.4), phase: 0))
            let onNose = Choreo.window(t, 2.2, 3.8, fade: 0.4)
            p.addWorld(Effect(.bubble, x: 0.2, y: 0.46, scale: 0.6, opacity: onNose, phase: 1))
            p.crossEyed = 0.8 * onNose
            if onNose > 0.3 { p.lookX = 0; p.lookY = 0.1; p.eyes = .wide }
            p.eyeOpenness = min(p.eyeOpenness, 1 - 0.95 * PetLife.blinkShape(t - 3.75))
        }
        if t > 4.0 {
            PetFX.hearts(&p, t: t - 4.0, x: 0.25, y: 1.05, count: 1, spacing: 0.8, reduced: true)
        }
    }
}
