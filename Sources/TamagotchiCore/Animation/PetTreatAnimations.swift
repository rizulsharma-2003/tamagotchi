import Foundation

/// Treat time (≈4.4 s): little stories of anticipation, a catch and a happy munch.
/// Treats live in world space until they are in Mochi's mouth; a treat that is caught
/// homes in on the real mouth point over its last frames and shrinks into it, so it never
/// slides across the face.
enum PetTreat {
    static let natural = 4.4
    static let variants = ["Cookie catch", "Fish nibbles", "Berry gulp", "Cupcake munch"]
    static let k = PetPoseEvaluator.bodyWidthsPerPathUnit
    static let calmKinds: [EffectKind] = [.treat, .fish, .berry, .cupcake]

    static func pose(_ p: inout PetPose, t raw: Double, d: Double, context: PoseContext, variant: Int, lite: Bool) {
        let t = PetPoseEvaluator.fit(raw, natural: natural, d: d)
        if context.reducedMotion {
            calm(&p, t: t, variant: variant, lite: lite)
            return
        }
        switch variant {
        case 0: cookie(&p, t: t, context: context, lite: lite)
        case 1: fish(&p, t: t, context: context, lite: lite)
        case 2: berry(&p, t: t, context: context, lite: lite)
        default: cupcake(&p, t: t, context: context, lite: lite)
        }
    }

    /// The mouth in world space (body widths from home, body heights above the floor).
    static func mouth(_ p: PetPose) -> (Double, Double) {
        let m = p.mouthPoint
        return (p.x * k + m.x, p.y + m.y)
    }

    /// Chewing: the cheeks fill one after the other (about 3.6 puffs a second), the mouth
    /// works between a munch and a pressed "mm", and the jaw bobs the whole body a little.
    @discardableResult
    static func chew(_ p: inout PetPose, t: Double, start: Double, end: Double, rate: Double = 1.8, lite: Bool) -> Double {
        let amount = Choreo.window(t, start, end, fade: 0.1)
        guard amount > 0 else { return 0 }
        let phase = 2 * .pi * rate * (t - start)
        let left = max(0, sin(phase)), right = max(0, -sin(phase))
        p.cheekLeft = max(p.cheekLeft, (0.2 + 0.55 * sqrt(left)) * amount)
        p.cheekRight = max(p.cheekRight, (0.2 + 0.55 * sqrt(right)) * amount)
        let jaw = abs(sin(phase))
        p.scaleY -= 0.03 * jaw * amount
        p.scaleX += 0.02 * jaw * amount
        if !lite {
            p.mouth = jaw > 0.55 ? .nom : .tiny
            p.earLeft -= 0.1 * sin(phase) * amount
            p.earRight += 0.1 * sin(phase) * amount
            p.tilt += 0.03 * sin(phase) * amount
        }
        return amount
    }

    /// Crumbs flicked out of the mouth on ballistic arcs: they land on the floor, bounce and fade.
    static func crumbs(_ p: inout PetPose, t: Double, start: Double, end: Double, every: Double, seed: UInt64, kind: Int = 0) {
        guard t > start else { return }
        let first = max(0, Int(floor((t - start - 0.9) / every)))
        let last = Int(floor((min(t, end) - start) / every))
        guard last >= first else { return }
        let (mx, my) = mouth(p)
        for index in first...last {
            let born = start + Double(index) * every
            let side = index % 2 == 0 ? 1.0 : -1.0
            PetFX.ballistic(&p, kind: .crumb, t: t, born: born, fromX: mx + side * 0.12, fromY: my, side: side,
                            speed: 0.45 + 0.3 * Ease.hash(index, seed), up: 0.5 + 0.4 * Ease.hash(index &+ 7, seed),
                            seed: index + kind, scale: 0.85, life: 0.9)
        }
    }

    /// A treat falling along `path` that is snapped up: over the last `home` seconds before
    /// `catchAt` it homes in on the mouth and shrinks into it.
    static func caught(_ p: PetPose, path: (x: Double, y: Double), t: Double, catchAt: Double, home: Double = 0.12)
        -> (x: Double, y: Double, scale: Double) {
        let (mx, my) = mouth(p)
        let w = Ease.smooth(Choreo.seg(t, catchAt - home, catchAt))
        return (Ease.lerp(path.x, mx + 0.05, w), Ease.lerp(path.y, my + 0.02, w), 1 - 0.3 * w)
    }

    // MARK: (a) Cookie catch

    static let cookieCatch = 1.15

    /// Falls in front of Mochi (to the right of the face), so the last stretch into the
    /// mouth comes from above and in front, across the cheek rather than the eyes.
    static func cookieFall(_ t: Double) -> (x: Double, y: Double, spin: Double) {
        let s = Choreo.seg(t, 0.38, cookieCatch)
        return (Ease.lerp(0.78, 0.5, s) + 0.03 * sin(t * 5), 1.48 - 0.7 * s * s, t * 7)
    }

    static func cookie(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        // Scoot under the falling cookie, crouch, leap and snap it out of the air.
        p.x = 0.1 * Choreo.smooth(Choreo.seg(t, 0.5, 0.82)) * (1 - Choreo.smooth(Choreo.seg(t, 3.55, 4.15)))
        p.step = 0.7 * sin(2 * .pi * 3.2 * (t - 0.5)) * Choreo.window(t, 0.5, 0.82, fade: 0.06)
            + 0.5 * sin(2 * .pi * 3 * (t - 3.55)) * Choreo.window(t, 3.55, 4.15, fade: 0.08)
        p.y = 0.36 * Choreo.hop(t, 0.95, 1.45) * m
        let crouch = Choreo.window(t, 0.7, 0.98, fade: 0.1)
        let wiggle = sin(2 * .pi * 4 * (t - 0.7)) * Choreo.window(t, 0.72, 0.96, fade: 0.06)
        let chinUp = Choreo.window(t, cookieCatch - 0.2, cookieCatch + 0.1, fade: 0.08)
        p.scaleY -= 0.15 * crouch * m
        p.scaleX += 0.11 * crouch * m
        p.scaleY += (0.06 * Choreo.bump(t, 0.95, 1.12) + 0.04 * chinUp) * m
        p.lean = (0.05 * wiggle - 0.03 * crouch) * m
        p.rotation = 0.06 * Choreo.bump(t, 0.95, 1.4) * m
        // Mouth full ("mmf!") through the landing, chewing, a gulp, then a happy wiggle.
        let mmf = Choreo.window(t, cookieCatch, 1.6, fade: 0.06)
        let gulp = Choreo.bump(t, 2.78, 2.92)
        let gulpStretch = Choreo.bump(t, 2.9, 3.08)
        p.scaleY += (-0.06 * gulp + 0.05 * gulpStretch) * m
        p.scaleX += (0.04 * gulp - 0.03 * gulpStretch) * m
        let happy = Choreo.window(t, 3.45, 4.4, fade: 0.25)
        let sway = sin(2 * .pi * 2.2 * (t - 3.45))
        p.lean += 0.06 * sway * happy * m
        p.y += 0.035 * abs(sway) * happy * m
        let reach = Choreo.window(t, 0.92, 1.3, fade: 0.08)
        p.leftArm = 0.5 * reach + 0.15 * Choreo.window(t, 1.4, 2.8, fade: 0.2) + 0.25 * happy * max(0, sway)
        p.rightArm = 0.5 * reach + 0.15 * Choreo.window(t, 1.4, 2.8, fade: 0.2) + 0.25 * happy * max(0, -sway)
        p.tailWag = (1.2 * sin(g * 13) * Choreo.window(t, 0.35, 1.0, fade: 0.1) + 0.8 * sin(g * 9) * happy) * m
        p.tailLift = 0.6 * Choreo.window(t, 0.3, 1.4, fade: 0.2) + 0.7 * happy
        p.tailCurl = 0.4 * happy
        p.cheekLeft = 0.5 * mmf
        p.cheekRight = 0.5 * mmf
        chew(&p, t: t, start: 1.6, end: 2.78, lite: lite)

        guard !lite else { return }
        // The head tips back to meet the cookie, the mouth opens wide.
        p.tilt -= 0.18 * chinUp
        let anticipation = Choreo.window(t, 0.3, 1.15, fade: 0.2)
        p.eyeSparkle = anticipation
        p.eyeScale = 1 + 0.22 * anticipation - 0.1 * gulp
        p.earPerk = Choreo.perk(t, 0.0, 0.32, 0.1, 1.0) - 0.2 * Choreo.window(t, 1.6, 2.78, fade: 0.1) + 0.2 * happy + 0.3 * gulpStretch
        switch t {
        case ..<0.3: p.eyes = .wide; p.mouth = .o
        case ..<(cookieCatch - 0.16): p.eyes = .wide; p.mouth = t < 0.65 ? .o : .tiny
        case ..<cookieCatch: p.eyes = .wide; p.mouth = .chomp
        case ..<1.6: p.eyes = .happy; p.mouth = .nom
        case ..<2.78: p.eyes = .happy
        case ..<3.0: p.eyes = .wide; p.mouth = .tiny
        case ..<3.45: p.eyes = .happy; p.mouth = Int((t - 3.0) * 6) % 2 == 0 ? .lick : .cat
        default: p.eyes = .happy; p.mouth = .smile
        }
        p.blush = 0.4 + 0.5 * Choreo.seg(t, 1.4, 2.2)
        let fall = cookieFall(t)
        if t < cookieCatch {
            PetPlay.look(&p, atWorld: fall.x, fall.y, strength: Choreo.seg(t, 0.05, 0.25), head: 0.7)
        } else {
            p.lookX = 0.05
            p.lookY = 0
        }
        // A twinkle in the air, the cookie tumbling down, then held in the teeth.
        if t < 0.55 {
            let twinkle = Choreo.bump(t, 0, 0.55)
            p.addWorld(Effect(.sparkle, x: 0.4, y: 1.5, scale: 0.6 + 0.8 * twinkle, opacity: twinkle, rotation: t * 4, variant: 1))
        }
        if t > 0.36, t < cookieCatch {
            let c = caught(p, path: (fall.x, fall.y), t: t, catchAt: cookieCatch, home: 0.16)
            p.addWorld(Effect(.treat, x: c.x, y: c.y, scale: 1.15 * c.scale, opacity: Choreo.seg(t, 0.36, 0.44), rotation: fall.spin))
        } else if t >= cookieCatch, t < 1.6 {
            let mp = p.mouthPoint
            let bite = Choreo.seg(t, 1.45, 1.6)
            p.add(Effect(.treat, x: mp.x + 0.06, y: mp.y + 0.01, scale: 0.8 * (1 - 0.5 * bite), opacity: 1 - bite,
                         rotation: cookieFall(cookieCatch).spin))
        }
        if t > cookieCatch, t < cookieCatch + 0.25 {
            let age = Choreo.seg(t, cookieCatch, cookieCatch + 0.25)
            let mp = p.mouthPoint
            p.add(Effect(.burst, x: mp.x + 0.04, y: mp.y + 0.04, scale: 0.65, opacity: 1 - age, variant: 1, phase: age))
        }
        crumbs(&p, t: t, start: 1.62, end: 2.7, every: 0.26, seed: context.seed)
        if t > 3.45 {
            PetFX.hearts(&p, t: t - 3.45, x: 0.15, y: 1.0, count: 3, spacing: 0.25, reduced: false, pop: true, life: 0.65)
        }
    }

    // MARK: (b) Fish nibbles

    static let fishBites: [Double] = [1.75, 2.15, 2.55]
    static let fishFloorX = 0.62

    static func fish(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        // Trot over, sniff, scoop the fish up, nibble it three times, purr, lick a paw.
        let approach = Choreo.smooth(Choreo.seg(t, 0.4, 0.72)) * (1 - Choreo.smooth(Choreo.seg(t, 1.3, 1.7)))
        p.x = 0.07 * approach
        let sniffing = Choreo.window(t, 0.5, 1.2, fade: 0.15)
        let tap = Choreo.taps(t, start: 0.62, spacing: 0.2, count: 3, width: 0.12)
        let scoop = Choreo.bump(t, 1.1, 1.4)
        p.lean = (0.1 * approach + 0.05 * scoop) * m
        p.scaleY -= (0.06 * sniffing + 0.03 * tap.amount * sniffing + 0.06 * scoop) * m
        p.scaleX += (0.04 * sniffing + 0.04 * scoop) * m
        p.step = 0.6 * sin(2 * .pi * 2.5 * t) * Choreo.window(t, 0.38, 0.74, fade: 0.08)
            + 0.6 * sin(2 * .pi * 2.5 * t) * Choreo.window(t, 1.32, 1.68, fade: 0.08)
        p.holdFront = Choreo.ramp(t, 1.2, 1.45, 0, 1) * (1 - Choreo.ramp(t, 2.85, 3.0, 0, 1))
        var nibble = 0.0
        for at in fishBites { nibble = max(nibble, Choreo.bump(t, at - 0.12, at + 0.1)) }
        p.scaleY -= 0.02 * nibble * m
        // A contented purr: a slow sway with purr lines (no body buzz).
        let purr = Choreo.window(t, 2.95, 3.5, fade: 0.12)
        p.lean += 0.03 * sin(2 * .pi * 1.6 * (t - 2.95)) * purr * m
        p.scaleY -= 0.02 * purr * m
        p.pawToMouth = Choreo.window(t, 3.45, 4.25, fade: 0.2)
        let lickBob = sin(2 * .pi * 3 * (t - 3.6)) * Choreo.window(t, 3.6, 4.1, fade: 0.1)
        p.pawToMouth -= 0.12 * max(0, lickBob)
        p.tailLift = 0.6 * Choreo.window(t, 0.4, 2.85, fade: 0.2) + 0.3 * purr
        p.tailWag = (0.5 * sin(t * 6) * sniffing + 0.9 * sin(g * 7) * Choreo.window(t, 1.5, 2.85, fade: 0.2) + 0.4 * sin(g * 4) * purr) * m
        p.tailCurl = 0.3 + 0.6 * purr
        var chewAmount = 0.0
        for at in fishBites {
            chewAmount = max(chewAmount, chew(&p, t: t, start: at + 0.08, end: at + 0.36, rate: 2.1, lite: lite))
        }

        guard !lite else { return }
        p.earPerk = Choreo.perk(t, 0.05, 0.36, 0.1, 0.9) - 0.2 * purr
        switch t {
        case ..<0.05: p.eyes = .open; p.mouth = .cat
        case ..<0.5: p.eyes = .wide; p.mouth = .o
        case ..<1.2: p.eyes = .open; p.mouth = tap.amount > 0.3 ? .tiny : .cat
        case ..<1.7: p.eyes = .wide; p.eyeSparkle = Choreo.window(t, 1.2, 1.7, fade: 0.1); p.mouth = .smile
        case ..<2.85:
            let biting = fishBites.contains { abs(t - ($0 - 0.03)) < 0.06 }
            if biting { p.eyes = .happy; p.mouth = .chomp } else if chewAmount < 0.05 { p.eyes = .happy; p.mouth = .cat } else { p.eyes = .happy }
        case ..<3.45: p.eyes = .happy; p.mouth = .cat
        case ..<4.2: p.eyes = .closed; p.mouth = lickBob > 0 ? .lick : .cat
        default: p.eyes = .happy; p.mouth = .smile
        }
        p.eyeOpenness = min(p.eyeOpenness, 1 - 0.3 * sniffing)
        p.blush = 0.4 + 0.45 * Choreo.seg(t, 1.8, 3.2)

        // Where the fish is: on the floor, then lifted into the paws, then dropped as bones.
        var bites = 0
        for at in fishBites where t > at { bites += 1 }
        let held = Choreo.ramp(t, 1.22, 1.45, 0, 1)
        let heldX = p.x * k + 0.03
        let heldY = p.y + 0.29 + 0.05 * nibble
        var fishX = Ease.lerp(fishFloorX, heldX, held)
        var fishY = Ease.lerp(0.1, heldY, held) + 0.12 * Choreo.bump(t, 1.22, 1.45)
        if t > 2.85 {
            let drop = Choreo.seg(t, 2.85, 3.1)
            fishX = heldX + 0.15 * drop
            fishY = heldY + (0.06 - heldY) * drop * drop
        }
        let appear = Ease.outBack(Choreo.seg(t, 0.02, 0.32), 2.4)
        let gone = Choreo.seg(t, 3.15, 3.5)
        if gone < 1 {
            if held < 0.5 || t > 3.0 {
                p.addWorld(Effect(.shadow, x: fishX, y: 0.01, scale: 1.3 * appear, opacity: (1 - gone) * 0.8))
            }
            p.addWorld(Effect(.fish, x: fishX, y: fishY, scale: appear * (1 - 0.15 * held), opacity: 1 - gone,
                              rotation: t > 2.85 ? 0.4 * Choreo.seg(t, 2.85, 3.1) : 0,
                              variant: bites, stretch: -0.08 * Choreo.bump(t, 0.25, 0.4)))
        }
        if t < 0.45 {
            let age = Choreo.seg(t, 0.02, 0.45)
            p.addWorld(Effect(.pop, x: fishFloorX, y: 0.25, scale: 1.0, opacity: 1 - age, variant: 0, phase: age))
        }
        if tap.index >= 0 {
            p.add(Effect(.sniff, x: 0.2, y: 0.33, scale: 0.85, opacity: tap.amount, variant: tap.index % 2,
                         phase: Choreo.seg(t - 0.62 - Double(tap.index) * 0.2, 0, 0.12)))
        }
        for (index, at) in fishBites.enumerated() {
            crumbs(&p, t: t, start: at, end: at + 0.12, every: 0.11, seed: context.seed &+ UInt64(index * 31), kind: 1)
        }
        if purr > 0.05 {
            p.add(Effect(.purr, x: -0.6, y: 0.45, scale: 0.9, opacity: purr, variant: 0, phase: t))
            p.add(Effect(.purr, x: 0.6, y: 0.45, scale: 0.9, opacity: purr, variant: 1, phase: t))
        }
        if t > 3.1 {
            PetFX.hearts(&p, t: t - 3.1, x: 0.2, y: 1.0, count: 2, spacing: 0.4, reduced: false)
        }
    }

    // MARK: (c) Berry gulp

    static let berryCatch = 1.74

    static func berryPath(_ t: Double) -> (x: Double, y: Double, spin: Double, squash: Double, opacity: Double) {
        let r = 0.12
        if t < 0.6 {
            let x = Ease.lerp(1.8, 0.62, Ease.outCubic(Choreo.seg(t, 0, 0.6)))
            return (x, r, (x - 1.8) * 8, 0, Choreo.seg(t, 0, 0.12))
        }
        if t < 1.0 {
            return (0.62, r, (0.62 - 1.8) * 8, -0.25 * Choreo.bump(t, 0.56, 0.78), 1)
        }
        // Flicked up high, it drops back down from above and in front of the face.
        let s = Choreo.seg(t, 1.0, berryCatch)
        return (Ease.lerp(0.62, 0.2, s) + 0.18 * Ease.hop(s), Ease.lerp(r, 0.75, s) + 0.72 * Ease.hop(s), (0.62 - 1.8) * 8 + 14 * s,
                0.12 * Choreo.bump(t, 1.0, 1.12), 1)
    }

    static func berry(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        let press = Choreo.window(t, 0.45, 0.98, fade: 0.1)
        let chinUp = Choreo.window(t, berryCatch - 0.3, berryCatch + 0.08, fade: 0.1)
        p.x = 0.04 * Choreo.smooth(Choreo.seg(t, 0.3, 0.5)) * (1 - Choreo.smooth(Choreo.seg(t, 3.2, 3.8)))
        p.lean = (0.05 * press - 0.04 * chinUp) * m
        p.step = 0.6 * sin(2 * .pi * 3 * (t - 0.3)) * Choreo.window(t, 0.3, 0.5, fade: 0.05)
            + 0.5 * sin(2 * .pi * 3 * (t - 3.2)) * Choreo.window(t, 3.2, 3.8, fade: 0.08)
        // The paw stops the berry, flicks it up.
        var right = 0.08
        if t > 0.4, t < 1.3 {
            if t < 0.6 {
                right = Choreo.rampOut(t, 0.4, 0.54, 0.08, 0.5)
                right = t > 0.54 ? Choreo.rampIn(t, 0.54, 0.6, 0.5, 0.12) : right
            } else if t < 0.92 {
                right = 0.12
            } else {
                right = Choreo.rampOut(t, 0.92, 1.04, 0.12, 0.75) * (1 - Choreo.smooth(Choreo.seg(t, 1.1, 1.3))) + 0.08 * Choreo.seg(t, 1.1, 1.3)
            }
        }
        p.rightArm = right
        // Hamster cheeks, a comic wobble, then pop!
        let full = Choreo.rampBack(t, berryCatch, berryCatch + 0.14, 0, 1, overshoot: 2.6) * (1 - Choreo.smooth(Choreo.seg(t, 2.6, 2.7)))
        let jiggle = 0.12 * sin(2 * .pi * 4 * (t - 2.2)) * Choreo.window(t, 2.2, 2.62, fade: 0.06)
        p.cheekLeft = Ease.clamp(full + jiggle)
        p.cheekRight = Ease.clamp(full - jiggle)
        p.scaleX += 0.06 * full * m
        p.scaleY -= 0.03 * full * m
        p.scaleY += 0.04 * chinUp * m
        let popDip = Choreo.bump(t, 2.6, 2.8)
        p.scaleY -= 0.06 * popDip * m
        p.scaleX += 0.05 * popDip * m
        let happy = Choreo.window(t, 2.85, 4.4, fade: 0.2)
        p.y = (0.1 * Choreo.hop(t, 3.0, 3.3) + 0.06 * Choreo.hop(t, 3.45, 3.7) + 0.03 * Choreo.hop(t, berryCatch, berryCatch + 0.2)) * m
        p.leftArm = 0.35 * Choreo.window(t, 2.95, 3.75, fade: 0.15)
        p.rightArm = max(p.rightArm, 0.35 * Choreo.window(t, 2.95, 3.75, fade: 0.15))
        p.tailWag = (0.9 * sin(g * 11) * happy + 0.6 * sin(g * 7) * full) * m
        p.tailLift = 0.5 + 0.4 * happy
        p.tailCurl = 0.5 * happy

        guard !lite else { return }
        p.tilt -= 0.18 * chinUp
        p.tilt += 0.06 * sin(2 * .pi * 4 * (t - 2.2)) * Choreo.window(t, 2.2, 2.62, fade: 0.06)
        p.earPerk = Choreo.perk(t, 0.05, 0.36, 0.1, 0.85) + 0.3 * full + 0.1 * happy
        p.eyeScale = 1 + 0.12 * Choreo.window(t, 0.05, berryCatch, fade: 0.2)
        p.eyeSparkle = 0.7 * Choreo.window(t, 1.0, berryCatch, fade: 0.15)
        switch t {
        case ..<0.05: p.eyes = .open; p.mouth = .cat
        case ..<0.45: p.eyes = .wide; p.mouth = .o
        case ..<0.95: p.eyes = .open; p.mouth = .grin; p.brows = .raised
        case ..<(berryCatch - 0.26): p.eyes = .wide; p.mouth = .smile
        case ..<berryCatch: p.eyes = .wide; p.mouth = .chomp
        case ..<1.92: p.eyes = .wide; p.mouth = .tiny
        case ..<2.6: p.eyes = .happy; p.mouth = .tiny
        case ..<2.8: p.eyes = .squint; p.mouth = .open
        default: p.eyes = .happy; p.mouth = .grin
        }
        p.blush = 0.4 + 0.55 * Choreo.seg(t, 2.65, 2.85)
        let path = berryPath(t)
        if t < berryCatch {
            PetPlay.look(&p, atWorld: path.x, path.y, strength: Choreo.seg(t, 0.05, 0.25), head: 0.6)
        } else if t < 2.6 {
            p.lookX = 0.4 * sin(2 * .pi * 0.9 * (t - 1.9)) * Choreo.seg(t, 1.9, 2.1)
            p.lookY = 0
        } else {
            p.lookX = 0.1
            p.lookY = 0
        }
        if t < berryCatch {
            let c = t > 1.0 ? caught(p, path: (path.x, path.y), t: t, catchAt: berryCatch) : (path.x, path.y, 1)
            PetPlay.addRolling(&p, .berry, x: c.0, y: c.1, radius: 0.12, spin: path.spin, squash: path.squash,
                               opacity: path.opacity, scale: c.2)
        }
        if t > berryCatch, t < berryCatch + 0.28 {
            let age = Choreo.seg(t, berryCatch, berryCatch + 0.28)
            let mp = p.mouthPoint
            p.add(Effect(.burst, x: mp.x + 0.03, y: mp.y + 0.03, scale: 0.6, opacity: 1 - age, variant: 1, phase: age))
        }
        if t > 2.6, t < 2.95 {
            let age = Choreo.seg(t, 2.6, 2.95)
            p.add(Effect(.pop, x: -0.38, y: 0.36, scale: 0.75, opacity: 1 - age, variant: 0, phase: age))
            p.add(Effect(.pop, x: 0.38, y: 0.36, scale: 0.75, opacity: 1 - age, variant: 0, phase: age))
        }
        if full > 0.5, t < 2.6 {
            p.add(Effect(.note, x: 0.46, y: 1.0 + 0.2 * Choreo.seg(t, 1.9, 2.6), scale: 0.6,
                         opacity: Choreo.window(t, 1.9, 2.6, fade: 0.15), rotation: 0.2 * sin(t * 6), variant: 1))
        }
        if t > 2.95 {
            PetFX.hearts(&p, t: t - 2.95, x: 0.2, y: 1.0, count: 3, spacing: 0.3, reduced: false, pop: true, life: 0.75)
        }
    }

    // MARK: (d) Cupcake munch

    static let cupcakeX = 0.62
    static let cupcakeBites: [Double] = [2.75, 3.03, 3.31]

    static func cupcake(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        // Tiptoe up to it, lick the frosting, get a dollop on the nose, wipe it, then lean
        // in for three real bites.
        let near = Choreo.smooth(Choreo.seg(t, 0.45, 1.0)) * (1 - Choreo.smooth(Choreo.seg(t, 3.62, 4.15)))
        p.x = 0.16 * near
        p.y = 0.06 * Choreo.hop(t, 0.22, 0.44) * m
        p.step = 0.7 * sin(2 * .pi * 3 * t) * Choreo.window(t, 0.45, 1.0, fade: 0.08)
            + 0.5 * sin(2 * .pi * 3 * t) * Choreo.window(t, 3.62, 4.15, fade: 0.08)
        let sniffing = Choreo.window(t, 0.95, 1.22, fade: 0.08)
        let lickIn = Choreo.window(t, 1.18, 1.48, fade: 0.1)
        var biteIn = 0.0
        var jab = 0.0
        for at in cupcakeBites {
            biteIn = max(biteIn, Choreo.window(t, at - 0.16, at + 0.1, fade: 0.08))
            jab = max(jab, Choreo.bump(t, at - 0.06, at + 0.05))
        }
        let leanIn = Choreo.window(t, cupcakeBites[0] - 0.22, cupcakeBites[2] + 0.14, fade: 0.1)
        p.lean = (0.08 * near + 0.12 * sniffing + 0.16 * lickIn + 0.22 * leanIn + 0.04 * jab
                  - 0.05 * Choreo.window(t, 1.5, 2.35, fade: 0.15)) * m
        p.scaleY -= (0.05 * sniffing + 0.06 * lickIn + 0.08 * leanIn + 0.03 * jab) * m
        p.scaleX += (0.03 * lickIn + 0.04 * leanIn) * m
        let happy = Choreo.window(t, 3.65, 4.4, fade: 0.2)
        let sway = sin(2 * .pi * 2.2 * (t - 3.65))
        p.lean += 0.05 * sway * happy * m
        // A paw wipes the frosting off the nose, then gets licked clean.
        p.pawToMouth = Choreo.window(t, 2.28, 2.62, fade: 0.1)
        p.tailLift = 0.7 * Choreo.window(t, 0.1, 3.6, fade: 0.2) + 0.5 * happy
        p.tailWag = (1.0 * sin(g * 11) * Choreo.window(t, 0.1, 1.1, fade: 0.1) + 0.8 * sin(g * 9) * happy) * m
        p.tailCurl = 0.4 * happy
        chew(&p, t: t, start: 3.38, end: 3.7, rate: 2, lite: lite)

        guard !lite else { return }
        let onNose = t > 1.38 && t < 2.42
        // Head dips towards the cupcake for the lick and the bites.
        p.tilt += 0.2 * max(lickIn, leanIn) + 0.05 * jab
        p.crossEyed = Choreo.ramp(t, 1.5, 1.7, 0, 1) * (1 - Choreo.ramp(t, 2.38, 2.48, 0, 1))
        p.earPerk = Choreo.perk(t, 0.02, 0.34, 0.1, 1.0) + 0.1 * happy - 0.2 * leanIn
        p.eyeSparkle = Choreo.window(t, 0.05, 1.05, fade: 0.15)
        p.eyeScale = 1 + 0.18 * Choreo.window(t, 0.05, 1.05, fade: 0.15) + 0.1 * Choreo.window(t, 1.5, 2.3, fade: 0.1)
        let lickAttempt = Choreo.bump(t, 1.8, 1.98) + Choreo.bump(t, 2.05, 2.23)
        var chomping = false
        for at in cupcakeBites where t > at - 0.12 && t < at + 0.02 { chomping = true }
        switch t {
        case ..<0.05: p.eyes = .open; p.mouth = .cat
        case ..<0.45: p.eyes = .wide; p.mouth = .o
        case ..<1.18: p.eyes = .wide; p.mouth = sniffing > 0.3 ? .tiny : .smile
        case ..<1.4: p.eyes = .happy; p.mouth = .lick
        case ..<1.5: p.eyes = .open; p.mouth = .cat
        case ..<2.28: p.eyes = .wide; p.mouth = lickAttempt > 0.3 ? .lick : .o
        case ..<2.62: p.eyes = .closed; p.mouth = t > 2.45 ? .lick : .cat
        case ..<3.38: p.eyes = .happy; p.mouth = chomping ? .chomp : .nom
        case ..<3.7: p.eyes = .happy
        default: p.eyes = .happy; p.mouth = .smile
        }
        p.tilt -= 0.08 * lickAttempt
        p.blush = 0.4 + 0.5 * Choreo.seg(t, 2.6, 3.4)
        if t < 1.5 || (t > 2.62 && t < 3.4) {
            PetPlay.look(&p, atWorld: cupcakeX, 0.28, strength: t < 1.5 ? Choreo.seg(t, 0.02, 0.2) : 1)
        } else if !(t > 1.5 && t < 2.42) {
            p.lookX = 0.1
            p.lookY = 0
        }

        var state = 0
        if t > 1.3 { state = 1 }
        if t > cupcakeBites[0] { state = 2 }
        if t > cupcakeBites[1] { state = 4 }
        if t > cupcakeBites[2] { state = 3 }
        let appear = Ease.outBack(Choreo.seg(t, 0.02, 0.32), 2.4)
        let gone = Choreo.seg(t, 3.5, 3.9)
        if gone < 1 {
            p.addWorld(Effect(.shadow, x: cupcakeX, y: 0.01, scale: 1.3 * appear, opacity: 1 - gone))
            p.addWorld(Effect(.cupcake, x: cupcakeX, y: 0.18, scale: appear * 1.35, opacity: 1 - gone, variant: state,
                              stretch: -0.1 * Choreo.bump(t, 1.22, 1.36) - 0.14 * jab))
        }
        if t < 0.45 {
            let age = Choreo.seg(t, 0.02, 0.45)
            p.addWorld(Effect(.pop, x: cupcakeX, y: 0.35, scale: 1.0, opacity: 1 - age, variant: 0, phase: age))
        }
        if onNose {
            let wobble = 0.03 * sin(t * 9)
            let nose = p.mouthPoint
            p.add(Effect(.frosting, x: nose.x + 0.02, y: nose.y + 0.07, scale: 0.95 * Ease.outBack(Choreo.seg(t, 1.38, 1.5), 2.6), rotation: wobble))
        }
        if sniffing > 0.05 {
            let nose = p.mouthPoint
            p.add(Effect(.sniff, x: nose.x + 0.16, y: nose.y + 0.02, scale: 0.85, opacity: sniffing, variant: Int(t * 8) % 2, phase: Ease.fract(t * 4)))
        }
        // Crumbs burst from where each bite lands.
        for (index, at) in cupcakeBites.enumerated() {
            for piece in 0..<2 {
                let side = piece == 0 ? -1.0 : 1.0
                PetFX.ballistic(&p, kind: .crumb, t: t, born: at + 0.02 * Double(piece), fromX: cupcakeX - 0.08, fromY: 0.32,
                                side: side, speed: 0.35 + 0.25 * Ease.hash(index * 2 + piece, context.seed &+ 41),
                                up: 0.7 + 0.3 * Ease.hash(index * 2 + piece + 9, context.seed &+ 41), seed: index + piece, scale: 0.85, life: 0.8)
            }
        }
        if t > 2.42, t < 2.62 {
            let age = Choreo.seg(t, 2.42, 2.62)
            p.add(Effect(.sparkle, x: 0.12, y: 0.48, scale: 0.5 + 0.3 * age, opacity: 1 - age, rotation: t * 3, variant: 1))
        }
        if t > 3.65 {
            PetFX.hearts(&p, t: t - 3.65, x: 0.15, y: 1.0, count: 3, spacing: 0.22, reduced: false, pop: true, life: 0.55)
        }
    }

    // MARK: Reduced motion

    /// Calm treats: the treat fades in, Mochi lights up, and each story keeps one beat of
    /// its own with expressions only (puffed "nom" cheeks, bones left behind, hamster
    /// cheeks with a blush, frosting on the nose).
    static func calm(_ p: inout PetPose, t: Double, variant: Int, lite: Bool) {
        guard !lite else { return }
        let present = Choreo.window(t, 0.15, 1.6, fade: 0.3)
        p.eyes = t < 1.5 ? .wide : .happy
        p.eyeSparkle = 0.8 * Choreo.window(t, 0.1, 1.5, fade: 0.2)
        p.earPerk = 0.6
        p.mouth = t < 1.5 ? .o : .smile
        p.blush = 0.4 + 0.45 * Choreo.seg(t, 1.5, 2.5)
        p.lookX = 0.4
        p.lookY = 0.2
        let kind = calmKinds[min(calmKinds.count - 1, max(0, variant))]
        switch variant {
        case 0:
            p.addWorld(Effect(kind, x: 0.7, y: 0.12, opacity: present))
            let munch = Choreo.window(t, 1.5, 3.0, fade: 0.25)
            p.cheekLeft = 0.7 * munch
            p.cheekRight = 0.7 * munch
            if munch > 0.3 { p.mouth = .nom }
        case 1:
            p.addWorld(Effect(kind, x: 0.7, y: 0.1, opacity: present))
            // Only the bones are left.
            p.addWorld(Effect(kind, x: 0.7, y: 0.1, opacity: Choreo.window(t, 1.5, 3.4, fade: 0.3), variant: 3))
            if t > 1.5, t < 3.0 { p.mouth = .nom }
        case 2:
            p.addWorld(Effect(kind, x: 0.7, y: 0.12, opacity: present))
            let full = Choreo.window(t, 1.5, 3.0, fade: 0.3)
            p.cheekLeft = 0.95 * full
            p.cheekRight = 0.95 * full
            p.blush = max(p.blush, 0.4 + 0.55 * full)
            if full > 0.3 { p.mouth = .tiny; p.eyes = .happy }
        default:
            p.addWorld(Effect(kind, x: 0.7, y: 0.14, opacity: present))
            let onNose = Choreo.window(t, 1.4, 2.8, fade: 0.3)
            p.add(Effect(.frosting, x: 0.05, y: 0.43, scale: 0.95, opacity: onNose))
            p.crossEyed = onNose
            if onNose > 0.3 { p.eyes = .wide; p.mouth = .lick; p.lookX = 0; p.lookY = 0.1 }
        }
        if t > 2.9 {
            PetFX.hearts(&p, t: t - 2.9, x: 0.2, y: 1.05, count: 2, spacing: 0.5, reduced: true)
        }
    }
}
