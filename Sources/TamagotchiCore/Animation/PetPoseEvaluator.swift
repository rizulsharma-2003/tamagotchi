import Foundation

/// Keyframe interpolation with smoothstep between keys.
public enum Keys {
    public static func value(_ t: Double, _ keys: [(Double, Double)]) -> Double {
        guard let first = keys.first else { return 0 }
        if t <= first.0 { return first.1 }
        for index in 1..<keys.count {
            let (t1, v1) = keys[index]
            if t <= t1 {
                let (t0, v0) = keys[index - 1]
                return Ease.lerp(v0, v1, Ease.smooth(Ease.segment(t, t0, t1)))
            }
        }
        return keys[keys.count - 1].1
    }
}

/// Mochi's animation language: soft, squishy, bouncy and organic.
///
/// A pose is built in three layers, all pure functions of (animation, elapsed,
/// global time, seed, reduced motion, intensity):
/// 1. the living base (`PetLife`): breathing, blinks, saccades, ear twitches, tail;
/// 2. the primary choreography for the animation (and variant);
/// 3. secondary motion (`PetSecondaryMotion`): ears, tail and body follow-through,
///    squash/stretch, lean and landing dust, from re-sampling layer 2 in the recent past.
/// One-shots ease in from, and settle exactly onto, the loop they return to
/// (`PoseContext.returnLoop`), so the animator can switch clips without a pop.
public enum PetPoseEvaluator {
    /// Body widths per path unit (pet home → companion home) in the popover scene. World-space
    /// props (a ball on the floor) use it to stay put while Mochi moves.
    public static let bodyWidthsPerPathUnit = 2.25
    /// Upper bound on particles per pose.
    public static let maxEffects = 24
    /// A one-shot squeezed into a shorter slot plays at most this much faster; the rest of
    /// the clip is trimmed (the settle at the end still brings everything home).
    public static let maxSpeedUp = 1.35

    public static func pose(_ animation: PetAnimation, elapsed t: Double, duration: Double? = nil, context: PoseContext) -> PetPose {
        let startedAt = context.time - t
        return pose(animation, elapsed: t, duration: duration, context: context,
                    variant: variant(for: animation, startedAt: startedAt, seed: context.seed))
    }

    /// Evaluates a specific variant (used by dev tools and tests).
    public static func pose(_ animation: PetAnimation, elapsed t: Double, duration: Double? = nil, context: PoseContext, variant: Int) -> PetPose {
        let d = max(0.05, duration ?? animation.defaultDuration)
        let count = variantCount(animation)
        let v = ((variant % count) + count) % count
        let oneShot = isOneShot(animation)
        // Past its end a one-shot has handed over: it is exactly the loop it returns to.
        if oneShot, t >= d { return returnPose(context) }
        var p = primary(animation, t: t, d: d, context: context, variant: v, lite: false)
        if !context.reducedMotion {
            PetSecondaryMotion.apply(&p, animation: animation, t: t, duration: d, context: context, variant: v)
        }
        if oneShot { settle(&p, animation: animation, t: t, d: d, context: context) }
        finalize(&p, reduced: context.reducedMotion)
        return p
    }

    @inline(__always) static func isOneShot(_ animation: PetAnimation) -> Bool {
        !animation.isLoop && animation != .scripted
    }

    /// The loop a one-shot hands back to.
    public static func returnLoop(_ context: PoseContext) -> PetAnimation {
        context.returnLoop.isLoop ? context.returnLoop : .idle
    }

    /// The return loop's pose right now (loops depend only on global time).
    static func returnPose(_ context: PoseContext) -> PetPose {
        pose(returnLoop(context), elapsed: 0, duration: nil, context: context, variant: 0)
    }

    /// Clips that start on a deliberate hit frame rather than easing in.
    static func startsOnHit(_ animation: PetAnimation) -> Bool {
        switch animation {
        case .petted, .wakeUp, .offer, .highFive, .rpsShake: return true
        default: return false
        }
    }

    /// Continuity for one-shots. Over the first 0.15 s the gaze, head, ears, arms and tail
    /// ease in from the return loop (and its lift fades out). Over the last 0.3 s (less in
    /// short slots) every channel settles onto that loop: eye shapes swap behind a blink,
    /// the clip's effects fade and the loop's own effects fade in.
    static func settle(_ p: inout PetPose, animation: PetAnimation, t: Double, d: Double, context: PoseContext) {
        let start = startsOnHit(animation) ? 1 : Ease.smooth(Ease.segment(t, 0, 0.15))
        let window = min(0.3, 0.3 * d)
        let end = Ease.smooth(Ease.segment(t, d - window, d))
        guard start < 1 || end > 0 else { return }
        let ambient = returnPose(context)
        if start < 1 {
            let w = 1 - start
            p.y += ambient.y * w
            p.lean += ambient.lean * w
            blendExpression(&p, toward: ambient, amount: w)
        }
        guard end > 0 else { return }
        func blend(_ value: inout Double, _ target: Double) { value += (target - value) * end }
        blend(&p.x, ambient.x)
        blend(&p.y, ambient.y)
        p.rotation = Ease.lerp(remainder(p.rotation, 2 * .pi), ambient.rotation, end)
        blend(&p.scaleX, ambient.scaleX)
        blend(&p.scaleY, ambient.scaleY)
        blend(&p.lean, ambient.lean)
        blend(&p.step, ambient.step)
        blend(&p.stride, ambient.stride)
        blend(&p.kick, ambient.kick)
        blend(&p.pawToMouth, ambient.pawToMouth)
        blend(&p.holdFront, ambient.holdFront)
        blend(&p.crossEyed, ambient.crossEyed)
        blend(&p.shadow, ambient.shadow)
        blend(&p.breath, ambient.breath)
        blendExpression(&p, toward: ambient, amount: end)
        if end > 0.55 {
            p.mouth = ambient.mouth
            p.brows = ambient.brows
        }
        if end > 0.6 { p.facing = ambient.facing }
        // Eye shapes swap behind a quick blink.
        let swapBlink = p.eyes == ambient.eyes && p.eyes == .open ? 0 : Choreo.bump(t, d - 0.57 * window, d - 0.1 * window)
        if end > 0.7 { p.eyes = ambient.eyes }
        p.eyeOpenness = min(Ease.lerp(p.eyeOpenness, ambient.eyeOpenness, end), 1 - 0.95 * swapBlink)
        let fade = 1 - Ease.smooth(Ease.segment(t, d - min(0.25, window), d))
        if fade < 1 {
            for index in p.effects.indices { p.effects[index].opacity *= fade }
        }
        for var effect in ambient.effects {
            effect.opacity *= end
            p.add(effect)
        }
    }

    /// Gaze, head, ears, arms, tail and face channels moved `amount` of the way to `a`.
    static func blendExpression(_ p: inout PetPose, toward a: PetPose, amount w: Double) {
        func mix(_ value: inout Double, _ target: Double) { value += (target - value) * w }
        mix(&p.lookX, a.lookX)
        mix(&p.lookY, a.lookY)
        mix(&p.tilt, a.tilt)
        mix(&p.headTurn, a.headTurn)
        mix(&p.earPerk, a.earPerk)
        mix(&p.earLeft, a.earLeft)
        mix(&p.earRight, a.earRight)
        mix(&p.earListen, a.earListen)
        mix(&p.leftArm, a.leftArm)
        mix(&p.rightArm, a.rightArm)
        mix(&p.tailWag, a.tailWag)
        mix(&p.tailCurl, a.tailCurl)
        mix(&p.tailLift, a.tailLift)
        mix(&p.eyeScale, a.eyeScale)
        mix(&p.eyeSparkle, a.eyeSparkle)
        mix(&p.blush, a.blush)
        mix(&p.cheekLeft, a.cheekLeft)
        mix(&p.cheekRight, a.cheekRight)
        mix(&p.eyeOpenness, a.eyeOpenness)
    }

    // MARK: Variants

    /// How many distinct stories an animation has.
    public static func variantCount(_ animation: PetAnimation) -> Int {
        switch animation {
        case .play: return PetPlay.variants.count
        case .treat: return PetTreat.variants.count
        case .petted: return PetAffection.variants.count
        default: return 1
        }
    }

    public static func variantName(_ animation: PetAnimation, _ variant: Int) -> String {
        let count = variantCount(animation)
        let v = ((variant % count) + count) % count
        switch animation {
        case .play: return PetPlay.variants[v]
        case .treat: return PetTreat.variants[v]
        case .petted: return PetAffection.variants[v]
        default: return animation.title
        }
    }

    /// Deterministic variant for a run that started at `startedAt` (context.time − elapsed).
    public static func variant(for animation: PetAnimation, startedAt: TimeInterval, seed: UInt64) -> Int {
        let count = variantCount(animation)
        guard count > 1, startedAt.isFinite else { return 0 }
        // Quantize so the tiny float error of time − elapsed can never flip the choice mid-run.
        // Petting keeps one style for a whole petting session (repeated clicks restart it).
        let bucket = animation == .petted ? Int((startedAt / 12).rounded()) : Int((startedAt * 3.7).rounded())
        let salt = UInt64(truncatingIfNeeded: animation.rawValue.utf8.count &* 7_919)
        return min(count - 1, Int(Ease.hash(bucket, seed ^ 0x5EED_A11E ^ salt) * Double(count)))
    }

    // MARK: Layers

    /// The base + primary layers. `lite` skips effects and expression-only work; the
    /// kinematics (x, y, rotation) are identical either way.
    static func primary(_ animation: PetAnimation, t: Double, d: Double, context: PoseContext, variant: Int, lite: Bool) -> PetPose {
        var p = PetLife.base(context, lite: lite)
        switch animation {
        case .idle, .scripted: PetLife.idle(&p, context: context, lite: lite)
        case .sleep: PetLife.sleep(&p, context: context, lite: lite, curled: false)
        case .curl: PetLife.sleep(&p, context: context, lite: lite, curled: true)
        case .watch: PetLife.watch(&p, context: context, lite: lite)
        case .waveGently: PetLife.waveGently(&p, context: context, lite: lite)
        case .sit: PetLife.sit(&p, context: context, lite: lite)
        case .play: PetPlay.pose(&p, t: t, d: d, context: context, variant: variant, lite: lite)
        case .treat: PetTreat.pose(&p, t: t, d: d, context: context, variant: variant, lite: lite)
        case .petted: PetAffection.pose(&p, t: t, d: d, context: context, variant: variant, lite: lite)
        case .walk, .carry: walk(&p, context: context, lite: lite, carrying: animation == .carry)
        case .run: run(&p, context: context, lite: lite)
        default: oneShot(animation, &p, t: t, d: d, context: context, lite: lite)
        }
        return p
    }

    /// Primary kinematics at another moment (for secondary motion).
    static func kinematics(_ animation: PetAnimation, elapsed t: Double, duration d: Double, time: Double,
                           context: PoseContext, variant: Int) -> PetSecondaryMotion.Sample {
        if isOneShot(animation), t < 0 {
            return PetSecondaryMotion.Sample(x: 0, y: 0, rotation: 0)
        }
        var shifted = context
        shifted.time = time
        let p = primary(animation, t: t, d: d, context: shifted, variant: variant, lite: true)
        return PetSecondaryMotion.Sample(x: p.x, y: p.y, rotation: p.rotation)
    }

    static func finalize(_ p: inout PetPose, reduced: Bool) {
        p.rotation = remainder(p.rotation, 2 * .pi)
        if abs(p.rotation) < 1e-9 { p.rotation = 0 }
        if reduced {
            p.x = 0
            p.y = 0
            p.rotation = 0
            p.lean = 0
            p.stride = 0
            p.kick = 0
            p.step = 0
        }
        p.earLeft = Ease.clamp(p.earLeft, -1.2, 1.2)
        p.earRight = Ease.clamp(p.earRight, -1.2, 1.2)
        p.earPerk = Ease.clamp(p.earPerk, -1.6, 1.2)
        p.lean = Ease.clamp(p.lean, -0.4, 0.4)
        p.tailWag = Ease.clamp(p.tailWag, -2.5, 2.5)
        p.tailCurl = Ease.clamp(p.tailCurl, -1.2, 1.2)
        p.tailLift = Ease.clamp(p.tailLift, -1.2, 1.2)
        p.scaleX = Ease.clamp(p.scaleX, 0.62, 1.45)
        p.scaleY = Ease.clamp(p.scaleY, 0.62, 1.45)
        p.eyeScale = Ease.clamp(p.eyeScale, 0.6, 1.5)
        p.eyeSparkle = Ease.clamp(p.eyeSparkle)
        p.crossEyed = Ease.clamp(p.crossEyed)
        p.cheekLeft = Ease.clamp(p.cheekLeft)
        p.cheekRight = Ease.clamp(p.cheekRight)
        p.pawToMouth = Ease.clamp(p.pawToMouth)
        p.holdFront = Ease.clamp(p.holdFront)
        p.blush = Ease.clamp(p.blush)
        p.stride = Ease.clamp(p.stride, -1.2, 1.2)
        p.kick = Ease.clamp(p.kick, -1, 1)
        p.headTurn = Ease.clamp(p.headTurn, -1, 1)
        p.earListen = Ease.clamp(p.earListen)
        p.shadow = Ease.clamp(p.shadow, 0.25, 1)
    }

    /// Plays a one-shot authored for `natural` seconds inside a slot of `d` seconds:
    /// sped up (at most `maxSpeedUp`, then trimmed) when the slot is shorter, natural speed
    /// (then rest) when longer.
    @inline(__always) static func fit(_ t: Double, natural: Double, d: Double) -> Double {
        d < natural ? t * min(natural / max(d, 0.05), maxSpeedUp) : t
    }

    // MARK: Locomotion loops

    /// A bouncy "boing-waddle": two springy bounces per gait cycle, a squash on every
    /// footfall and a little stretch in the air, a side-to-side rock that peaks mid-step
    /// (never at contact, so the feet stay on the floor) and ears that bounce a beat late.
    static func walk(_ p: inout PetPose, context: PoseContext, lite: Bool, carrying: Bool) {
        let g = context.time
        let m = context.motion
        let cadence = 1.8
        let phase = 2 * .pi * g * cadence
        let s = sin(phase)
        let air = abs(s)
        let contact = Ease.clamp(1 - air / 0.42)
        let footfall = contact * contact
        p.y = 0.075 * air * m
        p.rotation = -0.085 * s * m
        p.scaleY *= 1 + (0.04 * air - 0.065 * footfall) * m
        p.scaleX *= 1 - (0.025 * air - 0.05 * footfall) * m
        p.lean = 0.05 * m
        p.step = s * (context.reducedMotion ? 0 : 1)
        p.stride = -cos(phase) * 0.85 * m
        p.tailWag = 0.8 * sin(phase - 0.9) * m
        p.tailCurl = 0.15
        p.tailLift = 0.3 + 0.15 * air * m
        guard !lite else { return }
        // Ears bounce an eighth of a step behind the body and sway with the rock.
        let lagged = cos(2 * phase - .pi / 4)
        p.earPerk = 0.3 - 0.24 * lagged * m
        p.earLeft += 0.1 * sin(phase - 1.0) * m
        p.earRight += 0.1 * sin(phase - 1.0) * m
        p.tilt = 0.03 * s * m
        p.headTurn = 0.3
        p.lookX = 0.6
        p.lookY = 0.05
        if carrying {
            p.leftArm = 0.55 + 0.04 * sin(phase * 2) * m
            p.rightArm = 0.55 + 0.04 * sin(phase * 2) * m
            p.mouth = .smile
        } else {
            p.leftArm = 0.08 + 0.3 * max(0, s) * m
            p.rightArm = 0.08 + 0.3 * max(0, -s) * m
            p.mouth = .cat
        }
    }

    static func run(_ p: inout PetPose, context: PoseContext, lite: Bool) {
        let g = context.time
        let m = context.motion
        let cadence = 2.4
        let cycle = g * cadence
        let phase = 2 * .pi * cycle
        // Two bounds per cycle: push off, fly, land.
        let half = Ease.fract(cycle * 2)
        let flight = Ease.hop(half)
        p.y = 0.09 * flight * m
        let contactSquash = Choreo.bump(half, 0.86, 1.0) + Choreo.bump(half, 0, 0.12)
        p.scaleY *= 1 + (0.07 * flight - 0.1 * contactSquash) * m
        p.scaleX *= 1 - (0.045 * flight - 0.08 * contactSquash) * m
        p.step = sin(phase) * (context.reducedMotion ? 0 : 1)
        p.stride = -cos(phase) * 1.15 * m
        p.lean = (0.17 + 0.03 * cos(phase * 2)) * m
        p.rotation = 0.025 * sin(phase) * m
        p.tailWag = 0.25 * sin(phase * 2) * m
        p.tailCurl = -0.9
        p.tailLift = 0.15
        guard !lite else { return }
        p.earPerk = -0.55
        p.earLeft -= 0.42 * m
        p.earRight -= 0.42 * m
        p.headTurn = 0.5
        p.lookX = 0.85
        p.lookY = 0.1
        p.mouth = .pant
        p.eyeScale = 0.96
        p.leftArm = 0.18 + 0.22 * max(0, -sin(phase)) * m
        p.rightArm = 0.18 + 0.22 * max(0, sin(phase)) * m
        p.blush = 0.5
        if !context.reducedMotion {
            // Dust kicked up behind on each footfall (screen space: behind a right-facing runner).
            let sinceContact = Ease.fract(cycle * 2 - 0.9) / (cadence * 2)
            PetFX.dustKick(&p, age: sinceContact, life: 0.34, strength: 0.8)
            let earlier = sinceContact + 1 / (cadence * 2)
            PetFX.dustKick(&p, age: earlier, life: 0.34, strength: 0.6)
            // Speed lines trailing behind.
            p.add(Effect(.streak, x: -0.52, y: 0.52 + 0.03 * sin(phase), scale: 0.85, opacity: 0.75, variant: 2))
        }
    }

    // MARK: One-shots and building blocks

    static func oneShot(_ animation: PetAnimation, _ p: inout PetPose, t raw: Double, d: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let g = context.time
        let reduced = context.reducedMotion
        switch animation {
        case .lookAround:
            lookAround(&p, t: fit(raw, natural: 2.6, d: d), context: context, lite: lite)

        case .happyBounce:
            let t = fit(raw, natural: 1.0, d: d)
            let crouch = Choreo.bump(t, 0, 0.12)
            p.y = (0.14 * Choreo.hop(t, 0.09, 0.46) + 0.07 * Choreo.hop(t, 0.52, 0.82)) * m
            p.scaleY -= 0.08 * crouch * m
            p.scaleX += 0.06 * crouch * m
            let air = Choreo.bump(t, 0.09, 0.46) + 0.6 * Choreo.bump(t, 0.52, 0.82)
            p.leftArm = 0.3 + 0.3 * air
            p.rightArm = 0.3 + 0.3 * air
            p.tailWag = 1.0 * sin(g * 13) * m
            p.tailLift = 0.5
            p.tailCurl = 0.4
            guard !lite else { break }
            p.eyes = .happy
            p.mouth = t < 0.5 ? .grin : .open
            p.blush = 0.75
            p.earPerk = 0.75
            p.lookX = 0.1
            // Pastel sparkles: gold ones are reserved for real Claude events (this one plays ambiently too).
            if !reduced {
                PetFX.sparkles(&p, t: t - 0.2, around: (0, 1.08), count: 2, spread: 0.55, seed: context.seed &+ 17, life: 0.6, variant: 1)
            }

        case .excitedJump:
            let t = fit(raw, natural: 1.4, d: d)
            let crouch = Choreo.bump(t, 0, 0.3)
            p.y = (0.48 * Choreo.hop(t, 0.24, 0.74) + 0.16 * Choreo.hop(t, 0.84, 1.16)) * m
            p.scaleY -= 0.15 * crouch * m
            p.scaleX += 0.12 * crouch * m
            let armsUp = Choreo.ramp(t, 0.18, 0.34, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 1.12, 1.4)))
            p.leftArm = armsUp
            p.rightArm = armsUp * (0.92 + 0.08 * sin(t * 26) * Choreo.window(t, 0.3, 0.7, fade: 0.1))
            p.shadow = 1 - 0.55 * p.y
            p.tailWag = 1.1 * sin(g * 14) * m
            p.tailLift = 0.8
            guard !lite else { break }
            p.eyes = t < 0.26 ? .wide : .happy
            p.eyeScale = 1 + 0.2 * crouch
            p.eyeSparkle = crouch
            p.mouth = t < 0.26 ? .o : .grin
            p.blush = 0.85
            p.earPerk = Choreo.perk(t, 0.18, 0.42, 0.2, 1)
            if t > 0.38, t < 1.35 {
                PetFX.sparkles(&p, t: t - 0.38, around: (0, 1.0), count: 4, spread: 0.66, seed: context.seed, variant: 1)
            }

        case .roll:
            let t = fit(raw, natural: 1.6, d: d)
            if reduced {
                guard !lite else { break }
                p.eyes = t < 1.05 ? .happy : .dizzy
                p.mouth = t < 1.05 ? .open : .wavy
                PetFX.dizzyStars(&p, t: 0, amount: Choreo.window(t, 1.0, 1.6, fade: 0.2))
                break
            }
            let squash = Choreo.bump(t, 0, 0.24)
            let progress = Choreo.seg(t, 0.2, 1.05)
            let balled = Choreo.window(t, 0.18, 1.08, fade: 0.14)
            p.scaleY -= (0.12 * squash + 0.08 * balled) * m
            p.scaleX += (0.1 * squash - 0.04 * balled) * m
            p.rotation = 2 * .pi * Ease.smooth(progress) * p.facing
            p.x = 0.16 * sin(.pi * progress) * m
            p.y = 0.03 * Ease.hop(progress) * m + Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY)
            p.holdFront = 0.8 * balled
            let wobble = Choreo.window(t, 1.03, 1.6, fade: 0.22)
            guard !lite else { break }
            p.eyes = t < 1.05 ? .happy : .dizzy
            p.mouth = t < 1.05 ? .open : .wavy
            p.earPerk = -0.8 * balled
            p.tilt = 0.12 * sin(t * 14) * wobble
            p.earLeft += 0.2 * sin(t * 14) * wobble
            p.earRight += 0.2 * sin(t * 14 + 1) * wobble
            PetFX.dizzyStars(&p, t: t, amount: wobble)

        case .dance:
            let beat = raw / 0.8
            let amount = Ease.envelope(raw, duration: d, fadeIn: 0.3, fadeOut: 0.45)
            let sway = sin(2 * .pi * beat * 0.5)
            p.x = 0.035 * (1 + sway) * 0.5 * m * amount
            p.y = 0.05 * abs(sin(2 * .pi * beat)) * m * amount
            p.lean = 0.07 * sway * m * amount
            p.rotation = 0.06 * sin(2 * .pi * beat) * m * amount
            // A little twirl on the third beat of each bar when there is room for it.
            let bar = floor(beat / 4)
            let twirlStart = bar * 4 * 0.8 + 2 * 0.8
            var twirlHop = 0.0
            if bar >= 0, twirlStart + 0.65 <= d - 0.3, !reduced {
                // A little jump carries the twirl, so it spins in the air rather than on its ears.
                p.rotation += 2 * .pi * Ease.smooth(Choreo.seg(raw, twirlStart, twirlStart + 0.65)) * p.facing
                twirlHop = 0.2 * Choreo.hop(raw, twirlStart - 0.04, twirlStart + 0.69) * m
            }
            p.y = max(p.y + twirlHop, Choreo.floorLift(p.rotation))
            p.step = sin(2 * .pi * beat) * amount
            p.leftArm = (0.5 + 0.45 * sin(2 * .pi * beat)) * amount
            p.rightArm = (0.5 - 0.45 * sin(2 * .pi * beat)) * amount
            p.tailWag = 1.0 * sin(2 * .pi * beat) * m
            p.tailLift = 0.5
            guard !lite else { break }
            p.eyes = .happy
            p.mouth = Int(beat * 2) % 2 == 0 ? .open : .grin
            p.blush = 0.7
            p.earPerk = 0.6
            p.tilt = 0.08 * sin(2 * .pi * beat) * max(m, 0.4) * amount
            PetFX.notes(&p, t: raw, x: 0.45, y: 1.0, reduced: reduced)

        case .confusedTilt:
            let t = fit(raw, natural: 1.8, d: d)
            let tilt = Ease.outBack(Choreo.seg(t, 0, 0.4), 2.2) * (1 - Choreo.smooth(Choreo.seg(t, 1.35, 1.75)))
            guard !lite else { break }
            p.tilt = 0.26 * tilt * max(m, 0.5) + 0.05 * sin((t - 1.35) * 20) * Choreo.window(t, 1.35, 1.75, fade: 0.1) * m
            p.brows = .confused
            p.mouth = t < 1.0 ? .o : .wavy
            p.lookX = 0.3
            p.lookY = -0.3
            p.earPerk = -0.1
            if !reduced {
                p.earRight -= 0.35 * tilt
                p.earLeft -= 0.1 * tilt
            }
            p.eyeOpenness = min(p.eyeOpenness, 1 - 0.95 * PetLife.blinkShape(t - 0.55))
            let pop = Ease.outBack(Choreo.seg(t, 0.15, 0.45))
            p.add(Effect(.question, x: 0.48, y: 1.22 + 0.05 * pop, scale: pop, opacity: 1 - Choreo.seg(t, 1.4, 1.8),
                         rotation: reduced ? 0 : 0.15 * sin(t * 5)))

        case .concerned:
            let amount = Ease.envelope(raw, duration: d, fadeIn: 0.3, fadeOut: 0.4)
            p.scaleY -= 0.04 * amount * max(m, 0.4)
            // A worried half-step back (tiny: the desktop window has little room behind the tail).
            p.x = -0.012 * amount * m
            p.lean = -0.04 * amount * m
            p.tailWag = 0.1 * sin(g * 3) * m
            p.tailLift = -0.7 * amount
            p.tailCurl = 0.7 * amount
            let fidget = sin(raw * 2 * .pi * 2.6) * amount * (reduced ? 0 : 1)
            p.leftArm = 0.18 * amount + 0.05 * fidget
            p.rightArm = 0.18 * amount - 0.05 * fidget
            guard !lite else { break }
            p.earPerk = -0.85 * amount
            p.brows = .worried
            p.eyes = .worried
            p.mouth = .wavy
            p.lookX = 0.55
            let drip = Choreo.seg(raw, 0.3, 1.6)
            p.add(Effect(.sweat, x: 0.4, y: 0.98 - 0.14 * drip * max(m, 0.2), scale: 0.9, opacity: Ease.bump(raw, 0.25, 2.2)))

        case .victory:
            let t = fit(raw, natural: 2.4, d: d)
            let squash = Choreo.bump(t, 0, 0.22)
            p.y = 0.36 * Choreo.hop(t, 0.2, 0.74) * m
            p.scaleY -= 0.13 * squash * m
            p.scaleX += 0.1 * squash * m
            // The spin needs the full clip; in a short script slot it would strobe.
            if !reduced, d >= 1.8 { p.rotation = 2 * .pi * Ease.smooth(Choreo.seg(t, 0.22, 0.86)) * p.facing }
            p.y = max(p.y, Choreo.floorLift(p.rotation))
            let pump = Choreo.bump(t, 0.85, 1.15) + Choreo.bump(t, 1.25, 1.55)
            let arms = Choreo.ramp(t, 0.16, 0.32, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 1.9, 2.35)))
            p.rightArm = arms * (0.9 + 0.1 * pump)
            p.leftArm = arms * (0.95 - 0.55 * Choreo.window(t, 0.7, 1.9, fade: 0.2))
            p.y += 0.03 * pump * m
            p.scaleY += 0.03 * Choreo.window(t, 0.75, 1.9, fade: 0.2) * m
            p.shadow = 1 - 0.5 * p.y
            p.tailWag = 1.2 * sin(g * 12) * m
            p.tailLift = 0.9
            guard !lite else { break }
            p.eyes = .happy
            p.mouth = .grin
            p.blush = 0.85
            p.earPerk = 1
            // Victory only plays for real successes, so it keeps the gold sparkles and confetti.
            PetFX.confetti(&p, t: t - 0.3, originY: 1.2, count: 8, seed: context.seed, reduced: reduced)
            PetFX.sparkles(&p, t: t, around: (0, 1.05), count: 2, spread: 0.6, seed: context.seed &+ 3)

        case .greet:
            let t = fit(raw, natural: 1.8, d: d)
            let crouch = Choreo.bump(t, 0, 0.12)
            p.y = 0.09 * Choreo.hop(t, 0.1, 0.38) * m
            p.scaleY -= 0.06 * crouch * m
            p.scaleX += 0.05 * crouch * m
            let raise = Choreo.rampBack(t, 0.22, 0.48, 0, 1, overshoot: 2) * (1 - Choreo.smooth(Choreo.seg(t, 1.45, 1.78)))
            let wave = sin((t - 0.45) * 2 * .pi * 2.4) * Choreo.window(t, 0.45, 1.5, fade: 0.15)
            p.rightArm = context.reducedMotion ? 0.85 * raise : 0.84 * raise + 0.14 * wave
            p.lean = (0.04 * raise + 0.02 * wave) * m
            p.tailWag = 0.9 * sin(g * 10) * m
            p.tailLift = 0.5
            guard !lite else { break }
            p.eyes = t < 0.45 ? .happy : .open
            p.eyeSparkle = 0.6 * Choreo.window(t, 0.45, 1.5, fade: 0.2)
            p.mouth = t < 1.2 ? .open : .smile
            p.earPerk = 0.75
            if !reduced { p.earRight += 0.12 * wave }
            p.lookX = 0
            p.headTurn = -0.2 * raise
            p.blush = 0.6

        case .wave:
            let t = fit(raw, natural: 1.8, d: d)
            let raise = Choreo.rampBack(t, 0.05, 0.35, 0, 1, overshoot: 2) * (1 - Choreo.smooth(Choreo.seg(t, 1.5, 1.8)))
            let wave = sin((t - 0.3) * 2 * .pi * 2.4) * Choreo.window(t, 0.3, 1.55, fade: 0.15)
            p.rightArm = context.reducedMotion ? 0.85 * raise : 0.84 * raise + 0.14 * wave
            p.lean = 0.02 * wave * m
            guard !lite else { break }
            p.mouth = .smile
            p.lookX = 0
            p.earPerk = 0.5
            if !reduced { p.earRight += 0.1 * wave }

        case .leanForward:
            let t = fit(raw, natural: 1.4, d: d)
            let lean = leanForwardTrack(t)
            p.lean = 0.16 * lean * m
            p.tailLift = 0.5 * lean
            guard !lite else { break }
            p.lookX = 0.8
            p.lookY = 0.1
            p.headTurn = 0.5 * lean
            p.earPerk = 0.7 * lean
            p.eyes = t > 0.2 && t < 1.15 ? .wide : .open
            p.eyeScale = 1 + 0.12 * lean
            p.mouth = .o

        case .nod:
            let t = fit(raw, natural: 0.8, d: d)
            p.y = (-0.025 * Choreo.bump(t, 0, 0.38) - 0.018 * Choreo.bump(t, 0.4, 0.76)) * m
            p.scaleY -= (0.025 * Choreo.bump(t, 0, 0.38) + 0.015 * Choreo.bump(t, 0.4, 0.76)) * m
            guard !lite else { break }
            p.lookY = 0.3 * (Choreo.bump(t, 0, 0.38) + 0.7 * Choreo.bump(t, 0.4, 0.76))
            p.tilt = 0.05 * Ease.bump(t, 0, 0.8) * max(m, 0.4)
            p.eyes = t > 0.08 && t < 0.62 ? .happy : .open
            p.mouth = .smile

        case .blep:
            let t = fit(raw, natural: 1.4, d: d)
            guard !lite else { break }
            // The tongue stays out for most of the clip; the head tips and an ear flicks.
            p.mouth = t > 0.1 && t < 1.2 ? .blep : .cat
            p.eyes = t > 0.15 && t < 1.15 ? .wink : .open
            p.tilt = 0.15 * Ease.bump(t, 0, 1.4) * max(m, 0.4)
            p.headTurn = -0.35 * Ease.bump(t, 0, 1.4)
            p.blush = 0.65
            p.earPerk = 0.3
            if !reduced {
                p.earLeft -= 0.3 * Choreo.bump(t, 0.1, 0.5)
                p.earRight += 0.5 * PetLife.flick(t - 0.75)
            }

        case .yawn:
            let t = fit(raw, natural: 1.8, d: d)
            let stretch = Choreo.window(t, 0.15, 1.42, fade: 0.35)
            let open = Choreo.ramp(t, 0.18, 0.58, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 1.18, 1.36)))
            let amount = reduced ? 0.25 : max(m, 0.3)
            p.leftArm = 0.7 * Ease.outBack(Choreo.seg(t, 0.2, 0.55)) * (1 - Choreo.smooth(Choreo.seg(t, 1.1, 1.45)))
            p.rightArm = p.leftArm
            p.scaleY += 0.08 * stretch * amount
            p.scaleX -= 0.04 * stretch * amount
            p.tailLift = 0.6 * stretch
            p.tailCurl = -0.4 * stretch
            guard !lite else { break }
            // Head back, the mouth opens wide over 0.4 s, snaps shut, then a sleepy lip-smack.
            p.tilt = -0.1 * open * max(m, 0.4)
            p.lookY = -0.3 * open
            switch t {
            case ..<0.18: p.mouth = .cat
            case ..<0.32: p.mouth = .o
            case ..<0.46: p.mouth = .open
            case ..<1.18: p.mouth = .yawn
            case ..<1.3: p.mouth = .o
            case ..<1.62: p.mouth = Int((t - 1.3) * 12) % 2 == 0 ? .nom : .lick
            default: p.mouth = .cat
            }
            p.eyes = t > 0.22 && t < 1.34 ? .closed : .sleepy
            p.earPerk = -0.2 - 0.5 * stretch
            if t > 1.18, t < 1.78 {
                p.add(Effect(.droplet, x: 0.26, y: 0.52 - 0.05 * Choreo.seg(t, 1.3, 1.78), scale: 0.3,
                             opacity: Choreo.window(t, 1.18, 1.78, fade: 0.15)))
            }

        case .wakeUp:
            let t = fit(raw, natural: 1.2, d: d)
            let stretch = Choreo.window(t, 0.3, 0.85, fade: 0.2)
            p.leftArm = 0.5 * stretch
            p.rightArm = 0.5 * stretch
            p.scaleY += 0.05 * stretch * (reduced ? 0.25 : max(m, 0.3))
            let shake = sin((t - 0.72) * 2 * .pi * 4) * Choreo.window(t, 0.72, 1.02, fade: 0.08)
            guard !lite else { break }
            p.eyes = t < 0.32 ? .sleepy : (t < 0.72 ? .closed : (t < 0.95 ? .wide : .open))
            p.eyeOpenness = t < 0.32 ? 0.5 + 0.5 * abs(sin(t * 9)) : p.eyeOpenness
            p.mouth = t > 0.32 && t < 0.7 ? .o : .cat
            p.tilt = 0.1 * shake * (reduced ? 0 : 1)
            p.earPerk = Choreo.ramp(t, 0, 0.5, -0.6, 0.2)
            if !reduced {
                p.earLeft += 0.3 * shake - 0.25 * Choreo.bump(t, 0.85, 1.05)
                p.earRight += 0.3 * shake + 0.25 * Choreo.bump(t, 0.95, 1.15)
            }
            p.earPerk += 0.5 * Choreo.seg(t, 0.85, 1.1)

        case .offer:
            let t = fit(raw, natural: 1.0, d: d)
            let reach = Choreo.rampBack(t, 0, 0.32, 0.2, 0.75)
            p.leftArm = reach
            p.rightArm = reach
            p.lean = 0.06 * Choreo.window(t, 0, 1.0, fade: 0.25) * m
            guard !lite else { break }
            p.eyes = .happy
            p.mouth = .smile
            p.blush = 0.6

        case .highFive:
            let t = fit(raw, natural: 0.7, d: d)
            p.rightArm = Choreo.rampBack(t, 0.04, 0.24, 0.3, 1.0, overshoot: 1.2)
            p.y = 0.07 * Choreo.hop(t, 0.06, 0.42) * m
            p.scaleY -= 0.05 * Choreo.bump(t, 0, 0.08) * m
            p.lean = 0.05 * Choreo.seg(t, 0.05, 0.25) * m
            guard !lite else { break }
            p.eyes = .happy
            p.mouth = .open
            p.earPerk = 0.85

        case .rpsShake:
            let t = raw
            let shakes = abs(sin(.pi * t / 0.5)) * Choreo.window(t, 0, d, fade: 0.12)
            p.rightArm = 0.35 + 0.3 * shakes
            p.y = 0.02 * shakes * m
            p.scaleY -= 0.03 * shakes * m
            guard !lite else { break }
            p.eyes = .wide
            p.mouth = .flat
            p.brows = .raised
            p.earPerk = 0.5

        case .pounce, .bat, .tumble, .sniff, .stretch, .scratch, .shake, .leapCatch:
            if reduced {
                calmBlock(animation, &p, t: raw, d: d, lite: lite)
                break
            }
            switch animation {
            case .pounce: pounce(&p, t: fit(raw, natural: 1.3, d: d), context: context, lite: lite)
            case .bat: bat(&p, t: fit(raw, natural: 0.6, d: d), context: context, lite: lite)
            case .tumble: tumble(&p, t: fit(raw, natural: 1.3, d: d), context: context, lite: lite)
            case .sniff: sniff(&p, t: fit(raw, natural: 1.8, d: d), context: context, lite: lite)
            case .stretch: stretch(&p, t: fit(raw, natural: 2.6, d: d), context: context, lite: lite)
            case .scratch: scratch(&p, t: fit(raw, natural: 2.0, d: d), context: context, lite: lite)
            case .shake: shake(&p, t: fit(raw, natural: 1.1, d: d), context: context, lite: lite)
            default: leapCatch(&p, t: fit(raw, natural: 1.1, d: d), context: context, lite: lite)
            }

        default:
            break
        }
        if reduced {
            switch animation {
            case .pounce, .bat, .tumble, .sniff, .stretch, .scratch, .shake, .leapCatch, .roll:
                break
            default:
                // Reduced Motion: gestures become small, slow paw lifts.
                p.leftArm *= 0.3
                p.rightArm *= 0.3
            }
        }
    }

    static let leanForwardTrack = Track([(0, 0, .linear), (0.3, 1, .back), (1.0, 1, .hold), (1.4, 0, .smooth)])

    // MARK: Look around

    /// Glances ahead (ears swivel, head turns), turns right round to look behind, turns
    /// back and peeks upward. The turns squeeze the body thin with the tail tucked, so the
    /// change of side reads as a turn and not a flip.
    static let lookAroundX = Track([(0, 0.15, .linear), (0.22, 0.9, .easeOut), (0.84, 0.9, .hold), (0.94, -0.9, .easeOut),
                                    (1.74, -0.9, .hold), (1.84, 0.5, .easeOut), (2.0, 0.1, .smooth), (2.6, 0.15, .smooth)])
    static let lookAroundY = Track([(0, 0, .linear), (1.3, 0, .hold), (1.42, 0.25, .easeOut), (1.7, 0.25, .hold),
                                    (1.86, 0, .smooth), (2.02, -0.65, .easeOut), (2.36, -0.65, .hold), (2.6, 0, .smooth)])

    static func lookAround(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let reduced = context.reducedMotion
        let ahead = Choreo.window(t, 0.1, 0.9, fade: 0.2)
        let behind = Choreo.window(t, 0.98, 1.8, fade: 0.2)
        let up = Choreo.window(t, 1.96, 2.5, fade: 0.16)
        if !reduced {
            if t >= 0.95, t < 1.85 { p.facing = -p.facing }
            PetTurn.apply(&p, t: t, at: 0.95, motion: m)
            PetTurn.apply(&p, t: t, at: 1.85, motion: m)
        }
        p.lean += 0.04 * (ahead + behind) * m
        guard !lite else { return }
        p.lookX = lookAroundX(t)
        p.lookY = lookAroundY(t)
        let curious = Choreo.window(t, 1.3, 1.72, fade: 0.1)
        if reduced {
            p.tilt = 0.06 * (ahead - behind)
        } else {
            p.headTurn = 0.85 * (ahead + behind)
            p.tilt = 0.15 * ahead - 0.15 * behind - 0.06 * up
            // The front ear swivels towards the view (own frame: the facing side), the other follows.
            p.earRight += 0.35 * (ahead + behind)
            p.earLeft += 0.15 * (ahead + behind)
            p.earLeft -= PetLife.flick(t - 1.32) * 1.5
        }
        p.earPerk = 0.3 + 0.25 * (ahead + behind) + 0.4 * curious + 0.55 * up
        p.eyes = curious > 0.3 || (up > 0.5 && t < 2.3) ? .wide : .open
        p.mouth = curious > 0.4 ? .o : .cat
        // Blinks as the gaze sweeps across at each turn.
        p.eyeOpenness = min(p.eyeOpenness, 1 - 0.95 * max(PetLife.blinkShape(t - 0.88), PetLife.blinkShape(t - 1.78)))
    }

    // MARK: Play building blocks

    /// Butt-wiggle, a leap that tips nose-down onto the prey, a pin, and a hop back.
    static func pounce(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let k = bodyWidthsPerPathUnit
        let crouch = Choreo.window(t, 0, 0.56, fade: 0.14)
        // The rear sways at 4 Hz (a lean, so the feet stay planted) and the tail tip twitches.
        let wiggle = sin((t - 0.12) * 2 * .pi * 4) * Choreo.window(t, 0.12, 0.52, fade: 0.1)
        p.scaleY -= 0.14 * crouch * m
        p.scaleX += 0.1 * crouch * m
        p.lean = (-0.05 * crouch + 0.06 * wiggle) * m
        let leap = Choreo.seg(t, 0.52, 0.88)
        let back = Choreo.seg(t, 1.0, 1.24)
        p.x = (0.16 * Ease.smooth(leap) - 0.16 * Ease.smooth(back)) * m
        // Nose up on take-off, nose down over the last part of the flight, level again after the pin.
        let noseDown = Choreo.ramp(t, 0.62, 0.86, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 0.94, 1.08)))
        p.rotation = (-0.08 * Choreo.bump(t, 0.5, 0.7) + 0.3 * noseDown) * p.facing * m
        let flight = 0.36 * Choreo.hop(t, 0.52, 0.88) * m + 0.05 * Choreo.hop(t, 1.0, 1.24) * m
        p.y = max(flight, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY))
        let reach = Choreo.window(t, 0.5, 0.95, fade: 0.08)
        let pin = Choreo.window(t, 0.86, 1.0, fade: 0.04)
        p.leftArm = max(0, 0.6 * reach - 0.2 * pin)
        p.rightArm = max(0, 0.66 * reach - 0.2 * pin)
        p.tailWag = (0.9 * sin((t - 0.12) * 2 * .pi * 4 + 1.2) * crouch + 0.4 * sin(t * 6)) * m
        p.tailLift = 0.6 * crouch
        guard !lite else { return }
        p.eyes = t < 0.95 ? .wide : .happy
        p.eyeScale = 1 + 0.2 * crouch
        p.lookX = 0.9
        p.lookY = 0.35 + 0.3 * noseDown
        p.headTurn = 0.5 * crouch
        p.earPerk = 0.85
        p.mouth = t < 0.5 ? .tiny : (t < 0.95 ? .open : .grin)
        p.blush = 0.55
        if t > 0.6, t < 0.9 {
            PetFX.streak(&p, x: -0.1, y: 0.4, angle: -0.35, length: 0.9, amount: Choreo.bump(t, 0.6, 0.9) * 0.8)
        }
        // Touchdown dust where the front paws land.
        PetFX.dustPuff(&p, age: t - 0.86, worldX: 0.16 * m * k + 0.4, strength: 0.6)
    }

    /// Wind up, swipe down through the target with a streak, a squash on the hit, recover.
    static func bat(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let hit = Choreo.bump(t, 0.2, 0.31)
        if t < 0.17 {
            p.rightArm = Choreo.rampOut(t, 0, 0.17, 0.1, 1.0)
        } else if t < 0.27 {
            p.rightArm = Choreo.ramp(t, 0.17, 0.27, 1.0, 0.0)
        } else {
            p.rightArm = Choreo.ramp(t, 0.3, 0.58, 0.0, 0.1) + 0.06 * Choreo.bump(t, 0.25, 0.42)
        }
        p.lean = (-0.05 * Choreo.bump(t, 0, 0.2) + 0.08 * Choreo.window(t, 0.17, 0.46, fade: 0.08)) * m
        p.scaleY -= (0.03 * Choreo.bump(t, 0.02, 0.18) + 0.07 * hit) * m
        p.scaleX += (0.02 * Choreo.bump(t, 0.02, 0.18) + 0.05 * hit) * m
        p.tailWag += 0.6 * Choreo.bump(t, 0.15, 0.45) * m
        guard !lite else { return }
        p.eyes = t < 0.3 ? .wide : .open
        p.eyeScale = 1.12 - 0.1 * hit
        p.lookX = 0.85
        p.lookY = 0.35
        p.headTurn = 0.6
        p.earPerk = 0.7 - 0.45 * hit
        p.mouth = t < 0.24 ? .tiny : (t < 0.45 ? .o : .smile)
        PetFX.streak(&p, x: 0.55, y: 0.5, angle: 1.1, length: 1.0, amount: Choreo.bump(t, 0.17, 0.36))
    }

    /// Curl into a ball and roll over forwards, then a dizzy recovery.
    static func tumble(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let squash = Choreo.bump(t, 0, 0.16)
        let roll = Choreo.seg(t, 0.12, 0.82)
        let balled = Choreo.window(t, 0.06, 0.9, fade: 0.18)
        p.scaleY -= (0.12 * squash + 0.1 * balled) * m
        p.scaleX += (0.1 * squash - 0.06 * balled) * m
        p.rotation = 2 * .pi * Ease.smooth(roll) * p.facing
        // A round arc: up and a little forward while going over, back down onto the feet.
        p.x = 0.06 * sin(.pi * roll) * m
        p.y = 0.07 * Ease.hop(roll) * m + Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY)
        let dizzy = Choreo.window(t, 0.8, 1.3, fade: 0.15)
        p.holdFront = 0.85 * balled
        p.tailCurl = 1.0 * balled
        p.tailLift = -0.4 * balled
        guard !lite else { return }
        p.eyes = t < 0.82 ? .closed : (t < 1.15 ? .dizzy : .happy)
        p.mouth = t < 0.82 ? .o : .wavy
        p.earPerk = -1.1 * balled
        p.earLeft -= 0.3 * balled
        p.earRight -= 0.3 * balled
        p.tilt = 0.12 * sin(t * 13) * dizzy
        p.earLeft += 0.25 * sin(t * 13) * dizzy
        p.earRight += 0.25 * sin(t * 13 + 1.2) * dizzy
        PetFX.dizzyStars(&p, t: t, amount: dizzy)
    }

    /// Nose down, quick sniffs that bob the head, then a satisfied look up.
    static func sniff(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let down = Choreo.window(t, 0, 1.45, fade: 0.3)
        let sniffTap = Choreo.taps(t, start: 0.35, spacing: 0.25, count: 4, width: 0.14)
        p.lean = (0.1 * down + 0.03 * sniffTap.amount) * m
        p.scaleY -= (0.06 * down + 0.035 * sniffTap.amount) * m
        p.scaleX += (0.04 * down + 0.015 * sniffTap.amount) * m
        p.tailLift = 0.55 * down
        p.tailWag = 0.5 * sin(t * 9) * down * m
        guard !lite else { return }
        p.lookX = 0.45
        p.lookY = 0.9 * down
        p.headTurn = 0.4 * down
        p.tilt = 0.04 * sniffTap.amount
        p.eyes = .open
        p.eyeOpenness = min(p.eyeOpenness, 1 - 0.35 * down)
        p.earPerk = 0.6 * down
        p.earRight += 0.12 * sniffTap.amount
        p.mouth = sniffTap.amount > 0.3 ? .tiny : .cat
        if t > 1.45 {
            p.eyes = t < 1.75 ? .happy : .open
            p.mouth = .smile
            p.earPerk = max(p.earPerk, 0.6 * Choreo.smooth(Choreo.seg(t, 1.42, 1.62)))
            p.earLeft -= PetLife.flick(t - 1.5) * 1.4
        }
        if sniffTap.index >= 0 {
            p.add(Effect(.sniff, x: 0.24, y: 0.3, scale: 0.95, opacity: sniffTap.amount, variant: sniffTap.index % 2,
                         phase: Choreo.seg(t - 0.35 - Double(sniffTap.index) * 0.25, 0, 0.14)))
        }
    }

    /// Play-bow with the tail up, then a big stretch and a yawn.
    static func stretch(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let bow = Choreo.window(t, 0, 1.25, fade: 0.38)
        let up = Choreo.window(t, 1.15, 2.3, fade: 0.32)
        let amount = max(m, 0.3)
        p.rotation = 0.22 * bow * p.facing * m
        p.y = Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY)
        p.scaleX += (0.1 * bow - 0.04 * up) * amount
        p.scaleY += (-0.08 * bow + 0.1 * up) * amount
        p.rightArm = 0.32 * bow + 0.78 * up
        p.leftArm = 0.18 * bow + 0.78 * up
        p.tailLift = 0.9 * bow + 0.4 * up
        p.tailCurl = -0.5 * bow
        p.tailWag = 0.5 * sin(t * 5) * bow * m
        guard !lite else { return }
        p.eyes = .closed
        p.tilt = -0.08 * up
        p.mouth = bow > 0.5 ? .o : (up > 0.3 ? .yawn : .cat)
        if t > 2.3 { p.mouth = Int(t * 12) % 2 == 0 ? .nom : .cat; p.eyes = .sleepy }
        p.earPerk = -0.5 * up + 0.2 * bow
        p.blush = 0.5
    }

    /// Hind foot scratching behind the ear, blissful face.
    static func scratch(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let lift = Choreo.window(t, 0.05, 1.7, fade: 0.25)
        let scratching = Choreo.window(t, 0.3, 1.55, fade: 0.1)
        let rub = sin((t - 0.3) * 2 * .pi * 4.5)
        p.kick = 0.9 * lift + 0.1 * rub * scratching
        p.lean = -0.06 * lift * m
        p.scaleY -= 0.04 * lift * m
        p.scaleX += 0.02 * lift * m
        // The whole body jiggles a little with each stroke.
        p.scaleY += 0.012 * rub * scratching * m
        guard !lite else { return }
        p.tilt = 0.2 * lift * p.facing * max(m, 0.4) + 0.04 * rub * scratching
        p.headTurn = -0.3 * lift
        p.eyes = scratching > 0.3 ? .happy : .closed
        p.mouth = scratching > 0.3 ? .blep : .smile
        p.blush = 0.5 + 0.3 * scratching
        p.earPerk = -0.2
        // The scratched (front) ear flaps with the foot.
        p.earRight += (0.45 * rub - 0.15) * scratching
        if scratching > 0.3 {
            p.add(Effect(.shakeLines, x: 0.52, y: 0.9, scale: 0.6, opacity: 0.75 * scratching * (0.55 + 0.45 * abs(rub)), variant: 1))
        }
        if t > 1.7 {
            p.eyes = .open
            p.tilt = 0.08 * sin((t - 1.7) * 18) * Choreo.window(t, 1.7, 2.0, fade: 0.06)
        }
    }

    /// A wet-dog shake with flapping ears, motion lines and droplets.
    static func shake(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let k = bodyWidthsPerPathUnit
        let brace = Choreo.bump(t, 0, 0.16)
        let amount = Choreo.window(t, 0.1, 0.86, fade: 0.18)
        let wobble = sin((t - 0.1) * 2 * .pi * 5)
        p.rotation = 0.2 * wobble * amount * m
        p.y = Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY)
        p.lean = 0.06 * wobble * amount * m
        p.scaleY -= (0.05 * brace + 0.03 * abs(wobble) * amount) * m
        p.scaleX += (0.04 * brace + 0.05 * amount) * m
        p.tailWag = 1.6 * sin((t - 0.1) * 2 * .pi * 5 + 1.2) * amount * m
        // All fluffed up afterwards.
        let fluff = Choreo.window(t, 0.85, 1.1, fade: 0.12)
        p.scaleX += 0.05 * fluff * m
        guard !lite else { return }
        p.eyes = amount > 0.2 ? .squint : (t > 0.86 ? .happy : .open)
        p.mouth = amount > 0.2 ? .wavy : .smile
        p.earLeft += 0.6 * sin((t - 0.1) * 2 * .pi * 5 - 0.8) * amount
        p.earRight += 0.6 * sin((t - 0.1) * 2 * .pi * 5 - 0.2) * amount
        if amount > 0.3 {
            p.add(Effect(.shakeLines, x: -0.62, y: 0.5, scale: 0.9, opacity: amount, variant: 0))
            p.add(Effect(.shakeLines, x: 0.62, y: 0.5, scale: 0.9, opacity: amount, variant: 1))
        }
        for index in 0..<6 {
            let born = 0.22 + Double(index) * 0.1
            let side = index % 2 == 0 ? -1.0 : 1.0
            PetFX.ballistic(&p, kind: .droplet, t: t, born: born, fromX: p.x * k + side * 0.42, fromY: 0.72, side: side,
                            speed: 0.9 + 0.5 * Ease.hash(index, context.seed), up: 0.9, seed: index, scale: 0.34, life: 0.5, spin: 0)
        }
    }

    /// Crouch, leap up and clap a catch at the top, land and hug it.
    static func leapCatch(_ p: inout PetPose, t: Double, context: PoseContext, lite: Bool) {
        let m = context.motion
        let crouch = Choreo.bump(t, 0, 0.26)
        p.y = 0.52 * Choreo.hop(t, 0.22, 0.78) * m
        p.scaleY -= 0.14 * crouch * m
        p.scaleX += 0.11 * crouch * m
        let reach = Choreo.ramp(t, 0.2, 0.4, 0.1, 1) * (1 - Choreo.smooth(Choreo.seg(t, 0.48, 0.6)))
        let hug = Choreo.window(t, 0.5, 1.1, fade: 0.12)
        p.leftArm = max(reach, 0.42 * hug)
        p.rightArm = max(reach, 0.42 * hug)
        p.shadow = 1 - 0.55 * p.y
        p.tailLift = 0.6
        p.tailWag = 0.8 * sin(t * 12) * m
        guard !lite else { return }
        p.eyes = t < 0.48 ? .wide : .happy
        p.eyeScale = 1 + 0.15 * crouch
        p.lookY = -0.6 * Choreo.window(t, 0.1, 0.55, fade: 0.1)
        p.tilt = -0.1 * Choreo.window(t, 0.1, 0.55, fade: 0.1)
        p.mouth = t < 0.48 ? .o : .grin
        p.earPerk = 1
        p.blush = 0.7
        if t > 0.46, t < 0.8 {
            let age = Choreo.seg(t, 0.46, 0.8)
            p.add(Effect(.burst, x: 0, y: 1.08, scale: 0.8, opacity: 1 - age, variant: 1, phase: age))
        }
    }

    /// Reduced Motion versions of the building blocks: no travel, rotation or squash, no
    /// snapping limbs; expressions, gaze and slow paw gestures only.
    static func calmBlock(_ animation: PetAnimation, _ p: inout PetPose, t raw: Double, d: Double, lite: Bool) {
        guard !lite else { return }
        let natural = animation.defaultDuration
        let t = fit(raw, natural: natural, d: d)
        let present = Choreo.window(t, 0, natural, fade: max(0.3, natural / 4))
        let early = t < natural * 0.5
        switch animation {
        case .pounce:
            p.eyes = early ? .wide : .happy
            p.eyeScale = 1 + 0.15 * present
            p.lookX = 0.8
            p.lookY = 0.4
            p.earPerk = 0.3 + 0.5 * present
            p.mouth = early ? .tiny : .smile
        case .bat:
            p.rightArm = 0.1 + 0.3 * present
            p.eyes = .wide
            p.lookX = 0.8
            p.lookY = 0.35
            p.earPerk = 0.6 * present
            p.mouth = early ? .tiny : .o
        case .tumble:
            p.eyes = t < natural * 0.6 ? .happy : .dizzy
            p.mouth = t < natural * 0.6 ? .open : .wavy
            PetFX.dizzyStars(&p, t: 0, amount: Choreo.window(t, natural * 0.6, natural, fade: 0.25))
        case .sniff:
            p.lookY = 0.8 * present
            p.lookX = 0.45
            p.eyeOpenness = min(p.eyeOpenness, 1 - 0.35 * present)
            p.earPerk = 0.5 * present
            p.mouth = .tiny
            p.add(Effect(.sniff, x: 0.24, y: 0.3, scale: 0.95, opacity: 0.8 * present, phase: 0.5))
        case .stretch:
            p.eyes = .closed
            p.mouth = Choreo.window(t, natural * 0.45, natural * 0.85, fade: 0.2) > 0.5 ? .yawn : .cat
            p.earPerk = -0.4 * present
        case .scratch:
            p.eyes = .happy
            p.mouth = .blep
            p.blush = 0.5 + 0.3 * present
            p.earPerk = -0.2 * present
        case .shake:
            p.eyes = Choreo.window(t, 0.15, natural * 0.8, fade: 0.1) > 0.5 ? .squint : .happy
            p.mouth = .wavy
        case .leapCatch:
            p.eyes = early ? .wide : .happy
            p.leftArm = 0.45 * present
            p.rightArm = 0.45 * present
            p.lookY = -0.6 * present
            p.mouth = early ? .o : .grin
        default:
            break
        }
    }

    // MARK: Legacy array builders (used by the companion; kept exactly as before)

    static func zParticles(_ g: Double, x: Double, y: Double, reduced: Bool) -> [Effect] {
        (0..<3).map { index in
            let p = Ease.fract(g / 3.2 + Double(index) / 3)
            if reduced {
                return Effect(.z, x: x + 0.12 * Double(index), y: y + 0.2 * Double(index), scale: 0.6 + 0.2 * Double(index), opacity: 0.85)
            }
            return Effect(.z, x: x + 0.22 * p, y: y + 0.55 * p, scale: 0.55 + 0.5 * p, opacity: sin(.pi * p), rotation: -0.2 + 0.3 * p)
        }
    }

    static func sparkles(_ t: Double, around center: (Double, Double), count: Int, spread: Double, seed: UInt64) -> [Effect] {
        (0..<count).map { index in
            let angle = Ease.hash(index, seed) * 2 * .pi
            let radius = spread * (0.7 + 0.3 * Ease.hash(index + 11, seed))
            let delay = Double(index) * 0.18
            let life = Ease.bump(t - delay, 0, 0.7)
            return Effect(.sparkle, x: center.0 + cos(angle) * radius, y: center.1 + sin(angle) * radius * 0.6 + 0.1,
                          scale: 0.5 + 0.6 * life, opacity: life, rotation: t * 2)
        }
    }

    static func hearts(_ t: Double, x: Double, y: Double, count: Int, reduced: Bool) -> [Effect] {
        (0..<count).compactMap { index in
            let local = t - Double(index) * 0.35
            guard local > 0, local < 1.3 else { return nil }
            let p = local / 1.3
            let sway = reduced ? 0 : 0.06 * sin(local * 7)
            return Effect(.heart, x: x + Double(index) * 0.12 - 0.12 + sway, y: y + (reduced ? 0.15 : 0.5 * p),
                          scale: 0.55 + 0.35 * Ease.outBack(min(1, p * 3)), opacity: sin(.pi * p))
        }
    }

    static func notes(_ t: Double, x: Double, y: Double, reduced: Bool) -> [Effect] {
        (0..<2).map { index in
            let p = Ease.fract(t / 1.6 + Double(index) * 0.5)
            return Effect(.note, x: x + (reduced ? 0 : 0.15 * sin(p * 6)) + 0.12 * Double(index), y: y + (reduced ? 0.1 : 0.45 * p),
                          scale: 0.7, opacity: sin(.pi * p), rotation: 0.2 * sin(p * 5), variant: index)
        }
    }

    static func confetti(_ t: Double, originY: Double, count: Int, seed: UInt64, reduced: Bool) -> [Effect] {
        guard t > 0, t < 1.9 else { return [] }
        return (0..<count).map { index in
            let angle = Ease.lerp(-2.4, -0.7, Ease.hash(index, seed)) * -1
            let speed = 0.6 + 0.5 * Ease.hash(index + 5, seed)
            let fall = t * t * 0.55
            let x = cos(angle) * speed * min(t, 0.9) * (Ease.hash(index + 9, seed) > 0.5 ? 1 : -1)
            let y = originY + sin(angle) * speed * min(t, 0.6) - fall
            let opacity = 1 - Ease.segment(t, 1.3, 1.9)
            if reduced {
                return Effect(.confetti, x: cos(Double(index)) * 0.5, y: originY + 0.1 * Double(index % 3), scale: 0.6, opacity: opacity, variant: index % 4)
            }
            return Effect(.confetti, x: x, y: y, scale: 0.6, opacity: opacity, rotation: t * 8 + Double(index), variant: index % 4)
        }
    }
}
