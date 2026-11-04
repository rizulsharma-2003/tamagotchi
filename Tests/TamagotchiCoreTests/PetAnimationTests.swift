import Foundation
import Testing
@testable import TamagotchiCore

@Suite("Pet animation")
struct PetAnimationTests {
    static let oneShots = PetAnimation.allCases.filter { !$0.isLoop && $0 != .scripted }
    /// Start times spread out enough to hit every variant (and many idle moments).
    static let starts: [Double] = (0..<120).map { 30 + Double($0) * 2.71 }

    static func length(_ animation: PetAnimation) -> Double {
        animation.isLoop || animation == .scripted ? 6 : animation.defaultDuration
    }

    /// Every (animation, variant) pair with `per` start times that pick that variant.
    static func runs(per: Int = 1) -> [(PetAnimation, Int, Double)] {
        PetAnimation.allCases.flatMap { animation -> [(PetAnimation, Int, Double)] in
            (0..<PetPoseEvaluator.variantCount(animation)).flatMap { variant -> [(PetAnimation, Int, Double)] in
                let matching = starts.filter { PetPoseEvaluator.variant(for: animation, startedAt: $0, seed: 7) == variant }
                return Array(matching.prefix(per)).map { (animation, variant, $0) }
            }
        }
    }

    static func pose(_ animation: PetAnimation, _ t: Double, start: Double, reduced: Bool = false,
                     intensity: AnimationIntensity = .normal, seed: UInt64 = 7, returnLoop: PetAnimation = .idle) -> PetPose {
        PetPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: start + t, reducedMotion: reduced, intensity: intensity,
                                                                          seed: seed, returnLoop: returnLoop))
    }

    static func loopPose(_ loop: PetAnimation, at time: Double, reduced: Bool = false, seed: UInt64 = 7) -> PetPose {
        PetPoseEvaluator.pose(loop, elapsed: 0, context: PoseContext(time: time, reducedMotion: reduced, seed: seed))
    }

    static func finite(_ pose: PetPose) -> Bool {
        let values = [pose.x, pose.y, pose.rotation, pose.scaleX, pose.scaleY, pose.tilt, pose.lean, pose.earLeft, pose.earRight,
                      pose.earPerk, pose.tailWag, pose.tailCurl, pose.tailLift, pose.lookX, pose.lookY, pose.eyeOpenness,
                      pose.eyeScale, pose.eyeSparkle, pose.crossEyed, pose.cheekLeft, pose.cheekRight, pose.breath, pose.step,
                      pose.stride, pose.kick, pose.pawToMouth, pose.holdFront, pose.leftArm, pose.rightArm, pose.blush, pose.shadow,
                      pose.headTurn, pose.earListen]
        guard values.allSatisfy(\.isFinite) else { return false }
        return pose.effects.allSatisfy { e in
            [e.x, e.y, e.scale, e.opacity, e.rotation, e.stretch, e.phase, e.x2, e.y2].allSatisfy(\.isFinite)
        }
    }

    @Test func everyAnimationAndVariantIsFiniteWithSaneScales() {
        for (animation, _, start) in Self.runs(per: 3) {
            for reduced in [false, true] {
                for intensity in [AnimationIntensity.calm, .lively] {
                    for t in stride(from: 0.0, through: Self.length(animation) + 0.4, by: 1.0 / 20) {
                        let pose = Self.pose(animation, t, start: start, reduced: reduced, intensity: intensity)
                        #expect(Self.finite(pose), "non-finite pose in \(animation) at \(t)")
                        #expect(pose.scaleX > 0.6 && pose.scaleX < 1.5 && pose.scaleY > 0.6 && pose.scaleY < 1.5, "scale out of range in \(animation) at \(t)")
                        #expect(pose.eyeScale >= 0.6 && pose.eyeScale <= 1.5)
                        #expect(pose.opacity >= 0 && pose.opacity <= 1)
                        #expect(pose.effects.count <= PetPoseEvaluator.maxEffects, "too many effects in \(animation) at \(t)")
                        #expect(pose.effects.allSatisfy { $0.opacity <= 1.0001 })
                    }
                }
            }
        }
    }

    @Test func oneShotsStartAndEndAtHomeUpright() {
        for animation in Self.oneShots {
            for start in Self.starts.prefix(24) {
                let d = animation.defaultDuration
                for t in [0.0, d, d + 0.25] {
                    let pose = Self.pose(animation, t, start: start)
                    let loop = Self.loopPose(.idle, at: start + t)
                    // At home and upright; any lift is the idle loop's own little hop.
                    #expect(abs(pose.x) < 0.005 && abs(pose.y - loop.y) < 0.005, "\(animation) not at home at \(t): \(pose.x), \(pose.y)")
                    #expect(abs(remainder(pose.rotation, 2 * .pi)) < 0.005, "\(animation) not upright at \(t): \(pose.rotation)")
                    #expect(abs(pose.lean - loop.lean) < 0.02, "\(animation) still leaning at \(t): \(pose.lean)")
                }
                for t in stride(from: 0.0, through: d, by: 1.0 / 30) {
                    let x = Self.pose(animation, t, start: start).x
                    // Travel stays within about a third of the path, and only forwards: the desktop
                    // window has almost no room behind Mochi's tail.
                    #expect(x <= 0.32 && x >= -0.02, "\(animation) travels out of bounds at \(t): \(x)")
                }
            }
        }
    }

    @Test func oneShotsHandOverExactlyToTheirReturnLoop() {
        for (animation, variant, _) in Self.runs() where Self.oneShots.contains(animation) {
            let matching = Self.starts.filter { PetPoseEvaluator.variant(for: animation, startedAt: $0, seed: 7) == variant }.prefix(20)
            for start in matching {
                for loop in [PetAnimation.idle, .watch, .waveGently, .sleep] {
                    let d = animation.defaultDuration
                    // Past the end the clip is exactly the loop it returns to…
                    for t in [d, d + 0.2] {
                        let pose = Self.pose(animation, t, start: start, returnLoop: loop)
                        #expect(pose == Self.loopPose(loop, at: start + t), "\(animation) does not hand over to \(loop) at \(t)")
                    }
                    // …and a frame before the end it is already all but there.
                    let late = Self.pose(animation, d - 1.0 / 60, start: start, returnLoop: loop)
                    let target = Self.loopPose(loop, at: start + d - 1.0 / 60)
                    let gaps = [late.leftArm - target.leftArm, late.rightArm - target.rightArm, late.earPerk - target.earPerk,
                                late.lookX - target.lookX, late.lookY - target.lookY, late.y - target.y, late.tilt - target.tilt,
                                late.tailWag - target.tailWag, late.scaleY - target.scaleY]
                    #expect(gaps.allSatisfy { abs($0) < 0.05 }, "\(animation) → \(loop) snaps at the end: \(gaps)")
                    #expect(late.effects.filter { $0.opacity > 0.05 }.count <= target.effects.count,
                            "\(animation) effects still showing at the end")
                    // The first frame eases in from the loop (unless the clip starts on a deliberate hit).
                    if !PetPoseEvaluator.startsOnHit(animation) {
                        let first = Self.pose(animation, 0, start: start, returnLoop: loop)
                        let before = Self.loopPose(loop, at: start)
                        let starts = [first.leftArm - before.leftArm, first.rightArm - before.rightArm, first.earPerk - before.earPerk,
                                      first.lookX - before.lookX, first.tailWag - before.tailWag]
                        #expect(starts.allSatisfy { abs($0) < 0.01 }, "\(animation) pops in from \(loop): \(starts)")
                    }
                }
            }
        }
    }

    @Test func reducedMotionHasNoTranslationRotationOrSquash() {
        for (animation, _, start) in Self.runs(per: 2) {
            var previous: PetPose?
            var lowest = 9.0, highest = -9.0
            for t in stride(from: 0.0, through: Self.length(animation) + 0.3, by: 1.0 / 30) {
                let pose = Self.pose(animation, t, start: start, reduced: true)
                #expect(pose.x == 0 && pose.y == 0 && pose.rotation == 0 && pose.lean == 0, "\(animation) moves with Reduced Motion at \(t)")
                #expect(pose.stride == 0 && pose.kick == 0 && pose.step == 0, "\(animation) steps with Reduced Motion at \(t)")
                lowest = min(lowest, pose.scaleY)
                highest = max(highest, pose.scaleY)
                if let previous {
                    // Only gentle breathing changes the body's shape, and paws move slowly.
                    #expect(abs(pose.scaleY - previous.scaleY) < 0.012 && abs(pose.scaleX - previous.scaleX) < 0.012,
                            "\(animation) squashes with Reduced Motion at \(t)")
                    #expect(abs(pose.leftArm - previous.leftArm) < 0.12 && abs(pose.rightArm - previous.rightArm) < 0.12,
                            "\(animation) snaps a paw with Reduced Motion at \(t)")
                }
                previous = pose
            }
            #expect(highest - lowest < 0.13, "\(animation) changes shape too much with Reduced Motion: \(highest - lowest)")
        }
    }

    @Test func variantsAreDeterministicAndVaried() {
        for animation in [PetAnimation.play, .treat, .petted] {
            var seen = Set<Int>()
            for start in Self.starts.prefix(60) {
                let variant = PetPoseEvaluator.variant(for: animation, startedAt: start, seed: 7)
                seen.insert(variant)
                // The variant never flips during a run, whatever the float error of time − elapsed.
                for t in stride(from: 0.0, through: animation.defaultDuration, by: 0.37) {
                    let context = PoseContext(time: start + t, seed: 7)
                    #expect(PetPoseEvaluator.pose(animation, elapsed: t, context: context)
                            == PetPoseEvaluator.pose(animation, elapsed: t, context: context, variant: variant),
                            "\(animation) switches story mid-run at \(t)")
                }
                #expect(Self.pose(animation, 1.234, start: start) == Self.pose(animation, 1.234, start: start))
            }
            #expect(seen.count >= (animation == .petted ? 2 : 3), "only \(seen.count) variants of \(animation)")
            #expect(PetPoseEvaluator.variantCount(animation) >= (animation == .petted ? 2 : 3))
        }
        // Different variants really are different stories.
        let ball = PetPoseEvaluator.pose(.play, elapsed: 2.4, context: PoseContext(time: 60), variant: 0)
        let butterfly = PetPoseEvaluator.pose(.play, elapsed: 2.4, context: PoseContext(time: 60), variant: 2)
        #expect(ball.effects.contains { $0.kind == .ball })
        #expect(butterfly.effects.contains { $0.kind == .butterfly })
        #expect(ball != butterfly)
    }

    @Test func secondaryMotionStaysBounded() {
        for (animation, variant, start) in Self.runs(per: 2) {
            for t in stride(from: 0.0, through: Self.length(animation), by: 1.0 / 24) {
                let context = PoseContext(time: start + t, seed: 7)
                let d = animation.defaultDuration
                let primary = PetPoseEvaluator.primary(animation, t: t, d: d, context: context, variant: variant, lite: false)
                let pose = PetPoseEvaluator.pose(animation, elapsed: t, context: context, variant: variant)
                guard t < d || animation.isLoop else { continue }
                #expect(abs(pose.earLeft) <= 1.2 && abs(pose.earRight) <= 1.2)
                #expect(abs(pose.earLeft - primary.earLeft) <= 1.0 && abs(pose.earRight - primary.earRight) <= 1.0,
                        "ear follow-through too strong in \(animation) at \(t)")
                #expect(abs(pose.lean - primary.lean) <= 0.25, "lean follow-through too strong in \(animation) at \(t)")
                #expect(abs(pose.tailWag) <= 2.5 && abs(pose.lean) <= 0.4)
                let squash = pose.scaleY / max(0.01, primary.scaleY)
                #expect(squash > 0.75 && squash < 1.2, "squash too strong in \(animation) at \(t): \(squash)")
            }
        }
    }

    @Test func secondaryMotionReactsToBigMoves() {
        // Landing from the excited jump puffs dust and flops the ears.
        let landing = PetPoseEvaluator.pose(.excitedJump, elapsed: 0.82, context: PoseContext(time: 50.82), variant: 0)
        #expect(landing.effects.contains { $0.kind == .dust })
        let takeoff = PetPoseEvaluator.pose(.excitedJump, elapsed: 0.3, context: PoseContext(time: 50.3), variant: 0)
        let calm = PetPoseEvaluator.primary(.excitedJump, t: 0.3, d: 1.4, context: PoseContext(time: 50.3), variant: 0, lite: false)
        #expect(abs(takeoff.earRight - calm.earRight) > 0.05, "ears ignore the take-off")
        // Nothing moves with Reduced Motion, so no follow-through either.
        let reduced = PetPoseEvaluator.pose(.excitedJump, elapsed: 0.82, context: PoseContext(time: 50.82, reducedMotion: true), variant: 0)
        #expect(!reduced.effects.contains { $0.kind == .dust })
    }

    @Test func landingDustAgesForwardsFromTheRealTouchdown() {
        for animation in [PetAnimation.excitedJump, .leapCatch, .happyBounce] {
            let d = animation.defaultDuration
            // The real touchdown, found finely.
            var apex = 0.0, apexY = -1.0
            for t in stride(from: 0.0, through: d * 0.8, by: 0.0005) {
                let y = PetPoseEvaluator.kinematics(animation, elapsed: t, duration: d, time: 50 + t, context: PoseContext(time: 50 + t), variant: 0).y
                if y > apexY { apexY = y; apex = t }
            }
            var touchdown = apex
            while touchdown < d,
                  PetPoseEvaluator.kinematics(animation, elapsed: touchdown, duration: d, time: 50 + touchdown,
                                              context: PoseContext(time: 50 + touchdown), variant: 0).y > PetSecondaryMotion.contact {
                touchdown += 0.0005
            }
            var previous: Double?
            for t in stride(from: touchdown + 0.002, to: min(d - 0.3, touchdown + 0.3), by: 1.0 / 60) {
                let pose = PetPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 50 + t), variant: 0)
                guard let dust = pose.effects.first(where: { $0.kind == .dust }) else { continue }
                let age = dust.phase * 0.38
                #expect(abs(age - (t - touchdown)) < 0.012, "\(animation) dust is \(age - (t - touchdown)) s off at \(t)")
                if let previous { #expect(dust.phase >= previous - 1e-9, "\(animation) dust steps backwards at \(t)") }
                previous = dust.phase
            }
            #expect(previous != nil, "\(animation) landing puffs no dust")
        }
    }

    @Test func motionIsContinuous() {
        for (animation, _, start) in Self.runs(per: 3) {
            var previous: PetPose?
            for t in stride(from: 0.0, through: Self.length(animation) + 0.2, by: 1.0 / 60) {
                let pose = Self.pose(animation, t, start: start)
                if let previous {
                    #expect(abs(pose.x - previous.x) < 0.04, "\(animation) x snaps at \(t)")
                    #expect(abs(pose.y - previous.y) < 0.09, "\(animation) y snaps at \(t)")
                    #expect(abs(remainder(pose.rotation - previous.rotation, 2 * .pi)) < 0.25, "\(animation) rotation snaps at \(t)")
                    #expect(abs(pose.lean - previous.lean) < 0.08, "\(animation) lean snaps at \(t)")
                    #expect(abs(pose.earPerk - previous.earPerk) < 0.25, "\(animation) ears snap at \(t)")
                    #expect(abs(pose.leftArm - previous.leftArm) < 0.25 && abs(pose.rightArm - previous.rightArm) < 0.25,
                            "\(animation) arms snap at \(t)")
                }
                previous = pose
            }
        }
    }

    @Test func scriptedInteractionsNeverStrobe() {
        for id in InteractionID.allCases {
            for variant in [0, 1] {
                let script = InteractionLibrary.script(id, variant: variant)
                let playback = InteractionPlayback(id: id, startedAt: 100, variant: variant, companionLoop: .idleAtDesk)
                var previous: PetPose?
                for t in stride(from: 0.0, through: script.duration, by: 1.0 / 60) {
                    let frame = InteractionLibrary.frame(playback, elapsed: t, petContext: PoseContext(time: 100 + t, seed: 7),
                                                         companionContext: PoseContext(time: 100 + t, seed: 8))
                    if let previous {
                        let step = abs(remainder(frame.pet.rotation - previous.rotation, 2 * .pi))
                        #expect(step < 0.35, "\(id) v\(variant) spins \(step) rad in one frame at \(t)")
                    }
                    previous = frame.pet
                }
            }
        }
    }

    @Test func propsStayPutInWorldSpace() {
        let k = PetPoseEvaluator.bodyWidthsPerPathUnit
        // Mochi pounces at the resting ball: it must not slide along with Mochi.
        var positions: [Double] = []
        for t in stride(from: 0.9, through: 1.78, by: 0.04) {
            let pose = PetPoseEvaluator.pose(.play, elapsed: t, context: PoseContext(time: 70 + t), variant: 0)
            if let ball = pose.effects.first(where: { $0.kind == .ball }) {
                #expect(ball.worldSpace)
                positions.append(ball.x + pose.x * k)
            }
        }
        #expect(positions.count > 10)
        #expect((positions.max() ?? 0) - (positions.min() ?? 0) < 0.02)
    }

    @Test func storiesStayInsideTheDesktopWindowAndThePopover() {
        // Desktop pet window: Mochi's home is 0.7 body widths from the left edge and the top is
        // 1.74 body heights above the floor; the popover has 2.55 body heights.
        let k = PetPoseEvaluator.bodyWidthsPerPathUnit
        let props: Set<EffectKind> = [.ball, .yarn, .butterfly, .bubble, .berry, .fish, .cupcake, .treat]
        for (animation, variant, start) in Self.runs(per: 2) where Self.oneShots.contains(animation) {
            for t in stride(from: 0.0, through: animation.defaultDuration, by: 1.0 / 30) {
                let pose = PetPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: start + t, seed: 7), variant: variant)
                for effect in pose.effects where props.contains(effect.kind) && effect.opacity > 0.2 {
                    let worldX = pose.x * k + effect.x
                    let top = pose.y + effect.y + 0.14 * effect.scale
                    #expect(worldX > -0.55, "\(animation) v\(variant) \(effect.kind) leaves the window on the left at \(t)")
                    #expect(top < 1.74, "\(animation) v\(variant) \(effect.kind) flies out of the desktop window at \(t): \(top)")
                }
            }
        }
    }

    @Test func caughtTreatsMeetTheMouth() {
        let k = PetPoseEvaluator.bodyWidthsPerPathUnit
        for (variant, catchAt, kind) in [(0, PetTreat.cookieCatch, EffectKind.treat), (2, PetTreat.berryCatch, .berry)] {
            for t in [catchAt - 1.0 / 30, catchAt - 1.0 / 60] {
                let pose = PetPoseEvaluator.pose(.treat, elapsed: t, context: PoseContext(time: 80 + t, seed: 7), variant: variant)
                guard let treat = pose.effects.first(where: { $0.kind == kind }) else {
                    Issue.record("no \(kind) at \(t)")
                    continue
                }
                let mouth = pose.mouthPoint
                // Within a few art units of the mouth, never up on the eyes.
                #expect(abs(treat.x + pose.x * k - (pose.x * k + mouth.x)) < 0.12 && abs(treat.y - mouth.y) < 0.12,
                        "\(kind) misses the mouth at \(t): treat (\(treat.x), \(treat.y)) mouth \(mouth)")
            }
        }
        // The cupcake is bitten, not eaten from afar: the mouth reaches it at every bite.
        for at in PetTreat.cupcakeBites {
            let pose = PetPoseEvaluator.pose(.treat, elapsed: at, context: PoseContext(time: 90 + at, seed: 7), variant: 3)
            let mouth = pose.x * k + pose.mouthPoint.x
            #expect(mouth > PetTreat.cupcakeX - 0.2, "the mouth is \(PetTreat.cupcakeX - mouth) body widths short of the cupcake at \(at)")
        }
    }

    @Test func idleIsAliveButCalm() {
        // Over two minutes of idle Mochi blinks, glances (with holds), twitches an ear and turns
        // the head, but never bounces around or darts its eyes nervously.
        for seed: UInt64 in [7, 11] {
            var blinks = 0, glances = 0
            var earTwitch = false, headTurns = false
            var wasOpen = true
            var lastLook = (0.0, 0.0)
            var lastGlance = -10.0
            for step in 0..<(120 * 30) {
                let time = 100 + Double(step) / 30
                let pose = PetPoseEvaluator.pose(.idle, elapsed: time - 100, context: PoseContext(time: time, seed: seed))
                if pose.eyeOpenness < 0.4, wasOpen { blinks += 1 }
                wasOpen = pose.eyeOpenness >= 0.4
                if abs(pose.lookX - lastLook.0) > 0.08 || abs(pose.lookY - lastLook.1) > 0.08 {
                    if time - lastGlance > 0.4 { glances += 1 }
                    lastGlance = time
                }
                lastLook = (pose.lookX, pose.lookY)
                if abs(pose.earLeft) > 0.15 || abs(pose.earRight) > 0.15 { earTwitch = true }
                if abs(pose.headTurn) > 0.2 { headTurns = true }
                #expect(pose.y < 0.08 && abs(pose.rotation) < 0.05)
            }
            #expect(blinks >= 16 && blinks <= 60, "\(blinks) blinks in two minutes")
            #expect(glances >= 16 && glances <= 44, "\(glances) glances in two minutes")
            #expect(earTwitch && headTurns)
        }
    }

    @Test func sleepIsDeepAndWatchIsAttentive() {
        func flicksPerMinute(_ loop: PetAnimation) -> Double {
            var peaks = 0
            var a = 0.0, b = 0.0, lastPeak = -10.0
            let minutes = 4.0
            for step in 0..<Int(minutes * 60 * 60) {
                let g = 200 + Double(step) / 60
                let pose = PetPoseEvaluator.pose(loop, elapsed: g - 200, context: PoseContext(time: g, seed: 7))
                let ear = max(abs(pose.earLeft), abs(pose.earRight))
                if b > 0.15, b >= a, b > ear, g - lastPeak > 0.3 { peaks += 1; lastPeak = g }
                a = b
                b = ear
            }
            return Double(peaks) / minutes
        }
        #expect(flicksPerMinute(.sleep) <= 4, "restless ears in sleep")
        #expect(flicksPerMinute(.curl) <= 4, "restless ears when curled up")
        #expect(flicksPerMinute(.watch) <= 12, "restless ears while watching")
        // Watching leans towards the screen without tipping over.
        let watching = Self.loopPose(.watch, at: 333)
        #expect(watching.rotation == 0 && watching.lean > 0)
    }

    @Test func sitIsAliveNotFrozen() {
        var open = 0, blinks = 0, bleps = 0, total = 0
        var wasOpen = true, wasBlep = false
        for step in 0..<(90 * 30) {
            let g = 400 + Double(step) / 30
            let pose = Self.loopPose(.sit, at: g)
            total += 1
            if pose.eyes == .open { open += 1 }
            if pose.eyes == .open, pose.eyeOpenness < 0.4, wasOpen { blinks += 1 }
            wasOpen = pose.eyes == .open && pose.eyeOpenness >= 0.4
            if pose.mouth == .blep, !wasBlep { bleps += 1 }
            wasBlep = pose.mouth == .blep
        }
        #expect(Double(open) / Double(total) > 0.6, "sit keeps its eyes closed")
        #expect(blinks >= 12, "sit blinks \(blinks) times in 90 s")
        #expect(bleps >= 2 && bleps <= 8, "\(bleps) bleps in 90 s")
    }

    @Test func walkBouncesEnoughToReadInTheMenuBar() {
        var lowest = 9.0, highest = -9.0, rock = 0.0, earLow = 9.0, earHigh = -9.0
        for step in 0..<120 {
            let pose = Self.loopPose(.walk, at: 50 + Double(step) / 120)
            lowest = min(lowest, pose.y)
            highest = max(highest, pose.y)
            rock = max(rock, abs(pose.rotation))
            earLow = min(earLow, pose.earPerk)
            earHigh = max(earHigh, pose.earPerk)
        }
        // About 1 pt (2 Retina pixels) of bounce and a visible rock at the bar's 0.235 scale.
        #expect(highest - lowest >= 0.07, "walk bob is only \(highest - lowest)")
        #expect(rock >= 0.07)
        #expect(earHigh - earLow >= 0.3)
    }

    @Test func playCareAndBlocksAvoidSymbolsReservedForRealEvents() {
        // Gold sparkles mean "turn complete", "?" means Claude is asking, "!" and orange mean
        // attention: Mochi's own play (and anything the scheduler plays ambiently) must never borrow them.
        let quiet: [PetAnimation] = [.play, .treat, .petted, .idle, .sleep, .curl, .watch, .waveGently, .sit, .walk, .carry, .run,
                                     .pounce, .bat, .tumble, .sniff, .stretch, .scratch, .shake, .leapCatch, .roll,
                                     .happyBounce, .excitedJump, .lookAround, .blep, .yawn, .dance, .greet, .wave, .nod, .wakeUp]
        let reserved: Set<EffectKind> = [.confetti, .question, .exclamation, .sweat, .clap]
        for (animation, _, start) in Self.runs(per: 2) where quiet.contains(animation) {
            for t in stride(from: 0.0, through: Self.length(animation), by: 1.0 / 20) {
                let pose = Self.pose(animation, t, start: start)
                for effect in pose.effects {
                    #expect(!reserved.contains(effect.kind), "\(animation) shows \(effect.kind) at \(t)")
                    if [.sparkle, .star, .burst].contains(effect.kind) {
                        #expect(effect.variant == 1, "\(animation) uses a gold \(effect.kind) at \(t)")
                    }
                }
                #expect(pose.brows != .worried)
            }
        }
    }

    @Test func mirroringTurnsEverythingAround() {
        for (animation, variant, start) in Self.runs() {
            let pose = PetPoseEvaluator.pose(animation, elapsed: 1.1, context: PoseContext(time: start + 1.1, seed: 7), variant: variant)
            let mirrored = pose.mirrored()
            #expect(mirrored.mirrored() == pose)
            #expect(mirrored.facing == -pose.facing && mirrored.lookX == -pose.lookX && mirrored.tilt == -pose.tilt)
            #expect(mirrored.leftArm == pose.rightArm && mirrored.cheekLeft == pose.cheekRight)
            // Own-frame channels are left for the renderer to mirror.
            #expect(mirrored.lean == pose.lean && mirrored.headTurn == pose.headTurn && mirrored.earLeft == pose.earLeft)
            // Every effect is in screen space, so mirroring moves it to the other side.
            #expect(pose.effects.allSatisfy { !$0.followsFacing }, "\(animation) uses a legacy facing-relative effect")
            for (a, b) in zip(pose.effects, mirrored.effects) {
                #expect(b.x == -a.x && b.x2 == -a.x2 && b.y == a.y)
            }
        }
    }

    @Test func silhouetteStaysOnTheFloor() {
        for (animation, _, start) in Self.runs(per: 2) {
            for t in stride(from: 0.0, through: Self.length(animation), by: 1.0 / 30) {
                let pose = Self.pose(animation, t, start: start)
                // Never more than 1.5 art units below the floor.
                let dip = Choreo.floorLift(pose.rotation, scaleX: pose.scaleX, scaleY: pose.scaleY)
                #expect(dip <= pose.y + 1.5 / 54 + 1e-9, "\(animation) sinks into the floor at \(t)")
            }
        }
    }

    @Test func tinyFitKeepsTheMenuBarClear() {
        for (animation, variant, start) in Self.runs(per: 2) {
            for t in stride(from: 0.0, through: Self.length(animation), by: 1.0 / 15) {
                let pose = PetPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: start + t, seed: 7), variant: variant)
                let fitted = PetTinyFit.fit(pose)
                #expect(fitted.y <= PetTinyFit.liftScale + 1e-9, "\(animation) leaps out of the bar at \(t)")
                #expect(fitted.effects.count <= PetTinyFit.maxEffects)
                for effect in fitted.effects where effect.kind != .tangle {
                    #expect(fitted.y + effect.y <= PetTinyFit.effectCeiling + 1e-9, "\(animation) \(effect.kind) pokes out of the bar at \(t)")
                }
                // Small hops and resting poses are left alone.
                if pose.y < 0.05 { #expect(abs(fitted.y - pose.y) < 0.002) }
            }
        }
        // A caught cookie still meets the mouth after the leap is compressed.
        let catching = PetPoseEvaluator.pose(.treat, elapsed: PetTreat.cookieCatch - 1.0 / 60,
                                             context: PoseContext(time: 80 + PetTreat.cookieCatch), variant: 0)
        let fitted = PetTinyFit.fit(catching)
        if let before = catching.effects.first(where: { $0.kind == .treat }), let after = fitted.effects.first(where: { $0.kind == .treat }) {
            #expect(abs(after.y - before.y) < 0.03, "the cookie leaves the mouth in the menu bar")
        }
    }

    @Test func poseEvaluationIsCheap() {
        let clock = ContinuousClock()
        var sink = 0.0
        let count = 3_000
        let elapsed = clock.measure {
            for index in 0..<count {
                let t = Double(index % 100) / 20
                let pose = PetPoseEvaluator.pose(.play, elapsed: t, context: PoseContext(time: 10 + t, seed: 3), variant: index % 4)
                sink += pose.y + Double(pose.effects.count)
            }
        }
        #expect(sink.isFinite)
        // Unoptimized debug build, with tests running in parallel; release is about 15× faster.
        #expect(elapsed < .milliseconds(Int64(count) * 150 / 1000), "\(count) play poses took \(elapsed)")
    }

    @Test func listensWhereItStands() {
        let start = ListeningPose.pose(elapsed: 0, listening: false, time: 3)
        #expect(start.earListen == 0)
        #expect(ListeningPose.pose(elapsed: ListeningPose.turnDuration, listening: false, time: 3.5).earListen == 1)
        for step in 0...12 {
            let elapsed = Double(step) * 0.1
            let pose = ListeningPose.pose(elapsed: elapsed, listening: elapsed > 0.8, time: 3 + elapsed)
            // On its spot, never spinning: it turns its ear, not its whole body.
            #expect(pose.x == 0 && pose.y == 0 && pose.facing == 1 && pose.scaleX > 0.9)
            #expect(Self.finite(pose))
        }
        let listening = ListeningPose.pose(elapsed: 5, listening: true, time: 9)
        #expect(listening.headTurn == 1 && listening.lean < 0 && listening.earListen == 1)
    }
}
