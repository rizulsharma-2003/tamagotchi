import Foundation

/// Being petted (≈3.2 s), three different moods: melting under the hand with a purr,
/// flopping over for a belly rub with paws kneading the air, or pushing the chin up into
/// a scratch with sleepy eyes and a thumping foot. Each ends with its own satisfied blep
/// and returns to an upright rest.
enum PetAffection {
    static let natural = 3.2
    static let variants = ["Melt and purr", "Roll over", "Chin scratch"]

    static func pose(_ p: inout PetPose, t raw: Double, d: Double, context: PoseContext, variant: Int, lite: Bool) {
        let t = PetPoseEvaluator.fit(raw, natural: natural, d: d)
        if context.reducedMotion {
            calm(&p, t: t, variant: variant, lite: lite)
            return
        }
        switch variant {
        case 0: melt(&p, t: t, context: context, lite: lite)
        case 1: rollOver(&p, t: t, context: context, lite: lite)
        default: chinScratch(&p, t: t, context: context, lite: lite)
        }
    }

    static func purrLines(_ p: inout PetPose, t: Double, amount: Double) {
        guard amount > 0.05 else { return }
        p.add(Effect(.purr, x: -0.6, y: 0.45, scale: 0.9, opacity: amount, variant: 0, phase: t))
        p.add(Effect(.purr, x: 0.6, y: 0.45, scale: 0.9, opacity: amount, variant: 1, phase: t))
    }

    // MARK: (a) Melt and purr

    static func melt(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let press = Choreo.window(t, 0, 2.45, fade: 0.25)
        let strokes = Choreo.window(t, 0.3, 2.4, fade: 0.3)
        let stroke = sin(2 * .pi * 0.95 * (t - 0.3))
        let purr = Choreo.window(t, 0.35, 2.4, fade: 0.25)
        p.lean = 0.08 * stroke * strokes * m
        p.scaleY -= (0.1 * press + 0.035 * abs(stroke) * strokes) * m
        p.scaleX += (0.08 * press + 0.025 * abs(stroke) * strokes) * m
        let bounceBack = Choreo.bump(t, 2.45, 2.75)
        p.scaleY += 0.06 * bounceBack * m
        p.scaleX -= 0.04 * bounceBack * m
        p.tailWag = 0.5 * sin(2 * .pi * 0.95 * t) * m
        p.tailCurl = 0.9
        p.tailLift = 0.2
        p.leftArm = 0.06 + 0.06 * strokes
        p.rightArm = 0.06 + 0.06 * strokes
        guard !lite else { return }
        // Ears flatten under the hand, then perk back up one after the other.
        let leftUp = Choreo.rampBack(t, 2.4, 2.62, 0, 1, overshoot: 2.4)
        let rightUp = Choreo.rampBack(t, 2.52, 2.74, 0, 1, overshoot: 2.4)
        p.earPerk = Ease.lerp(-1.3, 0.3, Choreo.seg(t, 2.4, 2.75)) * Choreo.seg(t, 0, 0.2) + (1 - Choreo.seg(t, 0, 0.2)) * p.earPerk
        p.earLeft += -0.25 * press + 0.18 * (1 - leftUp) * Choreo.seg(t, 2.35, 2.5) - 0.15 * leftUp + 0.15 * Choreo.seg(t, 2.62, 2.9)
        p.earRight += 0.25 * press - 0.18 * (1 - rightUp) * Choreo.seg(t, 2.47, 2.6) + 0.15 * rightUp - 0.15 * Choreo.seg(t, 2.74, 3.0)
        p.eyes = t < 2.5 ? .happy : (t < 2.82 ? .open : .happy)
        if t >= 2.5, t < 2.82 { p.eyeOpenness = 1 }
        p.eyeSparkle = Choreo.window(t, 2.5, 2.85, fade: 0.08)
        p.mouth = t < 0.9 ? .cat : (t < 2.45 ? .smile : (t < 2.8 ? .o : .blep))
        p.blush = 0.45 + 0.5 * Choreo.seg(t, 0.1, 0.8)
        p.lookX = 0
        p.lookY = 0
        p.headTurn = 0
        p.tilt = 0.06 * stroke * strokes
        purrLines(&p, t: t, amount: purr)
        PetFX.hearts(&p, t: t - 0.4, x: 0.18, y: 1.05, count: 3, spacing: 0.55, reduced: false, pop: true, life: 0.85)
    }

    // MARK: (b) Roll over

    static func rollOver(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        // A quick squash and a flop straight onto the back, belly up, paws kneading the air.
        let flopSquash = Choreo.bump(t, 0, 0.16)
        let over = Choreo.ramp(t, 0.12, 0.5, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 2.2, 2.58)))
        let belly = Choreo.window(t, 0.42, 2.3, fade: 0.12)
        let rock = 0.08 * sin(2 * .pi * 2 * (t - 0.5)) * belly
        p.rotation = (-1.3 * over + rock) * max(m, 0.5)
        // On its back the body's own x axis points up: squash that way, flat against the floor.
        p.scaleY -= 0.08 * flopSquash * m
        p.scaleX += 0.06 * flopSquash * m - 0.1 * belly * m
        p.scaleY += 0.05 * belly * m
        p.y = max(0.08 * Choreo.hop(t, 2.42, 2.72) * m, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY))
        let knead = sin(2 * .pi * 3 * (t - 0.5))
        p.leftArm = (0.75 + 0.15 * knead) * belly
        p.rightArm = (0.75 - 0.15 * knead) * belly
        // Hind paws paddle happily.
        p.step = sin(2 * .pi * 2.6 * t) * belly
        p.stride = cos(2 * .pi * 2.6 * t) * 0.6 * belly
        p.tailWag = (0.5 * sin(t * 6) + 1.0 * sin(g * 11) * belly) * m
        p.tailCurl = 0.6
        guard !lite else { return }
        p.earPerk = -0.7 * belly + 0.3 * Choreo.seg(t, 2.55, 2.9)
        p.earLeft += 0.15 * sin(2 * .pi * 2 * (t - 0.5)) * belly
        p.earRight -= 0.15 * sin(2 * .pi * 2 * (t - 0.5) + 0.6) * belly
        // Open, adoring eyes up at the hand (no purr: this one is a wriggly giggle).
        switch t {
        case ..<0.42: p.eyes = .wide; p.mouth = .o
        case ..<2.3: p.eyes = .open; p.mouth = Int((t - 0.42) * 3) % 3 == 2 ? .open : .grin
        case ..<2.7: p.eyes = .open; p.mouth = .open
        default: p.eyes = .wink; p.mouth = .blep
        }
        p.eyeSparkle = 0.9 * belly
        p.eyeScale = 1 + 0.12 * belly
        p.blush = 0.5 + 0.45 * Choreo.seg(t, 0.1, 0.9)
        p.lookX = -0.15
        p.lookY = -0.55 * belly
        p.headTurn = -0.2 * belly
        PetFX.hearts(&p, t: t - 0.7, x: 0.0, y: 0.95, count: 3, spacing: 0.4, reduced: false, pop: true, life: 0.8)
    }

    // MARK: (c) Chin scratch with a happy foot thump

    static let thumpRate = 4.0

    static func chinScratch(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        // The chin pushes up into the hand: a long stretch, head tipped back, sleepy eyes.
        let up = Choreo.window(t, 0, 2.45, fade: 0.28)
        let thumping = Choreo.window(t, 0.45, 2.25, fade: 0.15)
        let thumpPhase = 2 * .pi * thumpRate * (t - 0.45)
        let thump = max(0, sin(thumpPhase)) * thumping
        p.kick = -0.42 * thump
        p.scaleY += (0.06 * up - 0.02 * max(0, -sin(thumpPhase)) * thumping) * m
        p.scaleX -= 0.03 * up * m
        p.lean = -0.04 * up * m
        // Paws knead slowly in contentment.
        let knead = sin(2 * .pi * 1.4 * (t - 0.3))
        p.leftArm = (0.18 + 0.1 * knead) * up
        p.rightArm = (0.18 - 0.1 * knead) * up
        p.tailWag = 0.9 * sin(thumpPhase) * thumping * m
        p.tailCurl = 0.7
        p.tailLift = 0.3
        guard !lite else { return }
        p.lookY = -0.5 * up
        p.lookX = 0
        p.headTurn = 0
        p.tilt = -0.2 * up + 0.04 * sin(2 * .pi * 0.8 * t) * up
        p.earPerk = Ease.lerp(0.2, -0.6, Choreo.seg(t, 0.3, 1.2)) * (1 - Choreo.seg(t, 2.3, 2.6)) + 0.6 * Choreo.seg(t, 2.3, 2.6)
        p.earLeft -= 0.14 * thump
        // Eyes blissfully shut (soft lid arcs, not melt's happy ^^), a look up, a slow blink.
        switch t {
        case ..<0.3: p.eyes = .happy
        case ..<2.35: p.eyes = .closed
        case ..<2.7: p.eyes = .open
        default: p.eyes = .closed
        }
        if t >= 2.35, t < 2.7 { p.eyeOpenness = 1 }
        p.eyeOpenness = min(p.eyeOpenness, 1 - 0.95 * PetLife.slowBlinkShape(t - 2.72))
        p.mouth = t < 0.5 ? .smile : (t < 2.3 ? .smile : (t < 2.7 ? .o : .blep))
        p.blush = 0.5 + 0.45 * Choreo.seg(t, 0.2, 0.9)
        purrLines(&p, t: t, amount: 0.7 * Choreo.window(t, 0.6, 2.2, fade: 0.2))
        // A little dust puff from every thump, fading out completely before the next one.
        if thumping > 0.1 {
            let cycle = (t - 0.45) * thumpRate
            let since = Ease.fract(cycle - 0.5) / thumpRate
            let life = 0.9 / thumpRate
            if since < life {
                p.add(Effect(.dust, x: -0.32, y: 0.03, scale: 0.35 + 0.6 * since / life, opacity: (1 - since / life) * 0.7 * thumping,
                             variant: 0, phase: since / life))
            }
        }
        if t > 0.7 {
            PetFX.hearts(&p, t: t - 0.7, x: 0.15, y: 1.08, count: 2, spacing: 0.7, reduced: false, pop: true, life: 0.9)
        }
    }

    // MARK: Reduced motion

    static func calm(_ p: inout PetPose, t: Double, variant: Int, lite: Bool) {
        guard !lite else { return }
        p.blush = 0.45 + 0.5 * Choreo.seg(t, 0.1, 0.8)
        p.lookX = 0
        switch variant {
        case 0:
            p.eyes = t < 2.6 ? .happy : .open
            p.mouth = t < 2.7 ? .smile : .blep
            p.earPerk = Ease.lerp(-1.0, 0.3, Choreo.seg(t, 2.4, 2.8))
            purrLines(&p, t: 0, amount: Choreo.window(t, 0.3, 2.5, fade: 0.3))
        case 1:
            p.eyes = t < 2.6 ? .open : .wink
            p.eyeSparkle = 0.8 * Choreo.window(t, 0.3, 2.4, fade: 0.3)
            p.mouth = t < 2.7 ? .grin : .blep
            p.lookY = -0.4
            p.earPerk = -0.3
        default:
            p.eyes = t < 2.6 ? .closed : .open
            p.mouth = t < 2.7 ? .smile : .blep
            p.lookY = -0.4
            p.earPerk = Ease.lerp(-0.5, 0.3, Choreo.seg(t, 2.4, 2.8))
        }
        p.tailCurl = 0.9
        PetFX.hearts(&p, t: t - 0.4, x: 0.2, y: 1.05, count: 2, spacing: 0.9, reduced: true)
    }
}
