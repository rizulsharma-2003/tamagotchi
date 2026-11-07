import Foundation
@testable import TamagotchiCore

/// Pose fixtures: Mochi's and Patch's poses (`PetPoseEvaluator`, `CompanionPoseEvaluator`) and the interaction scripts'
/// whole frames (`InteractionLibrary.frame`) sampled over time in many contexts.
enum PoseFixtures {
    static let seed: UInt64 = 7
    /// Above 2^63, so the Dart port's unsigned handling is exercised.
    static let bigSeed: UInt64 = 0xDEAD_BEEF_CAFE_F00D

    static func context(time: Double, reduced: Bool = false, intensity: AnimationIntensity = .normal, seed: UInt64 = seed,
                        returnLoop: PetAnimation = .idle) -> PoseContext {
        PoseContext(time: time, reducedMotion: reduced, intensity: intensity, seed: seed, returnLoop: returnLoop)
    }

    /// One sampled run of a pet animation: `samples` are (elapsed, global time) pairs.
    static func petCase(_ animation: PetAnimation, variant: Int?, duration: Double? = nil, times: [Double], start: Double = 10,
                        reduced: Bool = false, intensity: AnimationIntensity = .normal, seed: UInt64 = seed,
                        returnLoop: PetAnimation = .idle, note: String) -> String {
        var o = FixtureObject()
        o.str("note", note)
        o.str("animation", animation.rawValue)
        if let variant { o.int("variant", variant) }
        o.optionalExact("duration", duration)
        o.raw("context", PoseJSON.context(context(time: start, reduced: reduced, intensity: intensity, seed: seed, returnLoop: returnLoop)))
        o.list("samples", times.map { t in
            let ctx = context(time: start + t, reduced: reduced, intensity: intensity, seed: seed, returnLoop: returnLoop)
            let pose = variant.map { PetPoseEvaluator.pose(animation, elapsed: t, duration: duration, context: ctx, variant: $0) }
                ?? PetPoseEvaluator.pose(animation, elapsed: t, duration: duration, context: ctx)
            var s = FixtureObject()
            s.exact("t", t)
            s.exact("time", start + t)
            if variant == nil { s.int("variant", PetPoseEvaluator.variant(for: animation, startedAt: start, seed: seed)) }
            s.raw("pose", PoseJSON.pet(pose))
            return s.json
        }, omitEmpty: false)
        return o.json
    }

    static func oneShotTimes(_ d: Double, fractions: [Double] = [0, 0.07, 0.2, 0.38, 0.55, 0.72, 0.9, 0.985]) -> [Double] {
        fractions.map { d * $0 } + [d + 0.1]
    }

    static let loopTimes = [0, 0.37, 1.1, 2.3, 3.9, 6.2]

    static func pet() -> String {
        var cases: [String] = []
        // Every animation and variant in the default context.
        for animation in PetAnimation.allCases {
            for variant in 0..<PetPoseEvaluator.variantCount(animation) {
                let times = animation.isLoop || animation == .scripted ? loopTimes : oneShotTimes(animation.defaultDuration)
                cases.append(petCase(animation, variant: variant, times: times, note: "default"))
            }
        }
        // Reduced Motion.
        for animation in PetAnimation.allCases {
            for variant in 0..<PetPoseEvaluator.variantCount(animation) {
                let d = animation.defaultDuration
                let times = animation.isLoop || animation == .scripted ? [0.5, 2.0] : [0.2 * d, 0.5 * d, 0.8 * d]
                cases.append(petCase(animation, variant: variant, times: times, reduced: true, note: "reduced motion"))
            }
        }
        // Calm and lively.
        let lively: [(PetAnimation, Int)] = [(.idle, 0), (.walk, 0), (.run, 0), (.happyBounce, 0), (.excitedJump, 0), (.dance, 0),
                                             (.victory, 0), (.play, 0), (.treat, 1), (.petted, 2), (.pounce, 0), (.shake, 0)]
        for intensity in [AnimationIntensity.calm, .lively] {
            for (animation, variant) in lively {
                let d = animation.defaultDuration
                let times = animation.isLoop ? [0.4, 1.9, 3.3] : [0.25 * d, 0.5 * d, 0.75 * d]
                cases.append(petCase(animation, variant: variant, times: times, intensity: intensity, note: "intensity \(intensity.rawValue)"))
            }
        }
        // One-shots easing in from, and settling onto, other loops.
        for loop in [PetAnimation.watch, .sleep, .waveGently, .sit] {
            for animation in [PetAnimation.greet, .nod, .happyBounce, .wakeUp, .yawn, .petted] {
                let d = animation.defaultDuration
                cases.append(petCase(animation, variant: 0, times: [0.04, 0.1, d - 0.25, d - 0.12, d - 0.03, d + 0.05], returnLoop: loop,
                                     note: "returns to \(loop.rawValue)"))
            }
        }
        // Squeezed into a shorter slot, and given a longer one.
        for animation in [PetAnimation.victory, .excitedJump, .greet, .happyBounce, .dance, .offer, .highFive, .wave, .play, .treat] {
            let d = animation.defaultDuration * 0.6
            cases.append(petCase(animation, variant: 0, duration: d, times: oneShotTimes(d, fractions: [0.1, 0.4, 0.7, 0.95]), note: "short slot"))
        }
        for animation in [PetAnimation.highFive, .offer, .happyBounce, .lookAround] {
            let d = animation.defaultDuration * 1.5
            cases.append(petCase(animation, variant: 0, duration: d, times: oneShotTimes(d, fractions: [0.2, 0.5, 0.8, 0.97]), note: "long slot"))
        }
        // A seed above 2^63 and a late global time.
        for (animation, variant) in [(PetAnimation.idle, 0), (.watch, 0), (.sleep, 0), (.sit, 0), (.waveGently, 0), (.curl, 0),
                                     (.play, 1), (.play, 2), (.play, 3), (.treat, 0), (.treat, 2), (.treat, 3), (.petted, 1)] {
            let times = animation.isLoop ? [0.3, 2.7, 5.1] : oneShotTimes(animation.defaultDuration, fractions: [0.15, 0.45, 0.8])
            cases.append(petCase(animation, variant: variant, times: times, start: 1234.5, seed: bigSeed, note: "big seed"))
        }
        // The variant picked from the start time and seed (no variant given).
        for animation in [PetAnimation.play, .treat, .petted] {
            for start in [100, 100.3, 113.7, 250.2, 987.65, 3021.4] {
                cases.append(petCase(animation, variant: nil, times: [1.0], start: start, seed: 9, note: "variant from the start time"))
            }
        }
        // A long idle and sleep, for the idle behaviours and dreams that only show up over minutes.
        cases.append(petCase(.idle, variant: 0, times: stride(from: 0.0, to: 240, by: 7.3).map { $0 }, note: "long idle"))
        cases.append(petCase(.sleep, variant: 0, times: stride(from: 0.0, to: 120, by: 5.9).map { $0 }, note: "long sleep"))
        cases.append(petCase(.watch, variant: 0, times: stride(from: 0.0, to: 90, by: 4.1).map { $0 }, note: "long watch"))

        var root = FixtureObject()
        root.str("about", "Mochi's poses from TamagotchiCore's PetPoseEvaluator (mochi_world's port must match): each case is an animation, "
                 + "a variant (or none: picked from the start time and seed), an optional slot duration and a context; each sample is the "
                 + "elapsed time t, the global time and the pose. Numbers have 12 significant digits; pose values equal to the defaults are left out. "
                 + "Seeds are unsigned 64-bit decimals. Regenerate with MOCHI_WRITE_WORLD_FIXTURES=1 swift test --filter WorldFixture.")
        root.list("cases", cases, omitEmpty: false, multiline: true)
        return root.json
    }

    static func companion() -> String {
        var cases: [String] = []
        func add(_ animation: CompanionAnimation, times: [Double], reduced: Bool = false, intensity: AnimationIntensity = .normal,
                 duration: Double? = nil, detail: CompanionDetail = CompanionDetail(waitingFor: .permission, subagents: 0), note: String) {
            let start = 20.0
            var o = FixtureObject()
            o.str("note", note)
            o.str("animation", animation.rawValue)
            o.optionalExact("duration", duration)
            o.raw("context", PoseJSON.context(context(time: start, reduced: reduced, intensity: intensity)))
            var d = FixtureObject()
            d.str("waitingFor", detail.waitingFor?.rawValue)
            d.int("subagents", detail.subagents, default: 0)
            o.object("detail", d)
            o.list("samples", times.map { t in
                let pose = CompanionPoseEvaluator.pose(animation, elapsed: t, duration: duration,
                                                       context: context(time: start + t, reduced: reduced, intensity: intensity), detail: detail)
                var s = FixtureObject()
                s.exact("t", t)
                s.exact("time", start + t)
                s.raw("pose", PoseJSON.companion(pose))
                return s.json
            }, omitEmpty: false)
            cases.append(o.json)
        }
        for animation in CompanionAnimation.allCases {
            let d = animation.defaultDuration
            let times = animation.isLoop || animation == .scripted ? [0, 0.6, 1.7, 3.3, 5.9, 12.4] : [0, 0.15, 0.4, 0.6, 0.85, 1.0].map { $0 * d }
            add(animation, times: times, note: "default")
            add(animation, times: animation.isLoop ? [0.8, 2.9] : [0.3 * d, 0.7 * d], reduced: true, note: "reduced motion")
        }
        for intensity in [AnimationIntensity.calm, .lively] {
            for animation in [CompanionAnimation.idleAtDesk, .thinking, .celebrate, .dance, .arrive, .depart] {
                let d = animation.defaultDuration
                add(animation, times: animation.isLoop ? [1.2, 4.4] : [0.35 * d, 0.65 * d], intensity: intensity, note: "intensity \(intensity.rawValue)")
            }
        }
        for waiting in [AttentionKind.input, .mcpDialog, .backgroundAgent] {
            add(.waiting, times: [0.5, 1.6], detail: CompanionDetail(waitingFor: waiting, subagents: 0), note: "waiting for \(waiting.rawValue)")
        }
        add(.waiting, times: [0.5], detail: CompanionDetail(), note: "waiting for nothing in particular")
        add(.highFive, times: [0.1, 0.5, 1.2], duration: 1.4, note: "longer slot")
        add(.celebrate, times: [0.3, 1.1, 2.0], duration: 2.3, note: "slot")

        var root = FixtureObject()
        root.str("about", "Patch's poses from TamagotchiCore's CompanionPoseEvaluator (mochi_world's port must match), in the format of poses-pet.json; "
                 + "detail is the CompanionDetail (what Claude waits for, subagents).")
        root.list("cases", cases, omitEmpty: false, multiline: true)
        return root.json
    }

    static func interactions() -> String {
        var cases: [String] = []
        func add(_ id: InteractionID, variant: Int, loop: CompanionAnimation = .idleAtDesk, reduced: Bool = false, intensity: AnimationIntensity = .normal,
                 samples: Int = 9, note: String) {
            let script = InteractionLibrary.script(id, variant: variant)
            let startedAt = 50.0
            let playback = InteractionPlayback(id: id, startedAt: startedAt, variant: variant, companionLoop: loop)
            let detail = CompanionDetail(waitingFor: nil, subagents: 1)
            var o = FixtureObject()
            o.str("note", note)
            o.str("interaction", id.rawValue)
            o.int("variant", variant)
            o.str("companionLoop", loop.rawValue)
            o.exact("duration", script.duration)
            o.bool("requiresCompanion", script.requiresCompanion)
            o.raw("petContext", PoseJSON.context(context(time: startedAt, reduced: reduced, intensity: intensity)))
            o.raw("companionContext", PoseJSON.context(context(time: startedAt, reduced: reduced, intensity: intensity, seed: seed &+ 0x5EED)))
            o.list("beats", script.pet.map { beat in
                var b = FixtureObject()
                b.num("start", beat.start)
                b.num("end", beat.end)
                b.str("animation", beat.animation.rawValue)
                return b.json
            } + script.companion.map { beat in
                var b = FixtureObject()
                b.str("character", "companion")
                b.num("start", beat.start)
                b.num("end", beat.end)
                b.str("animation", beat.animation.rawValue)
                return b.json
            })
            let times = (0..<samples).map { script.duration * Double($0) / Double(samples - 1) * 0.995 + 0.01 * Double($0 % 2) }
            o.list("frames", times.map { t in
                let frame = InteractionLibrary.frame(playback, elapsed: t,
                                                     petContext: context(time: startedAt + t, reduced: reduced, intensity: intensity),
                                                     companionContext: context(time: startedAt + t, reduced: reduced, intensity: intensity, seed: seed &+ 0x5EED),
                                                     detail: detail)
                var f = FixtureObject()
                f.exact("t", t)
                f.raw("pet", PoseJSON.pet(frame.pet))
                f.raw("companion", PoseJSON.companion(frame.companion))
                f.list("props", frame.props.map(PoseJSON.prop))
                return f.json
            }, omitEmpty: false)
            cases.append(o.json)
        }
        for id in InteractionID.allCases {
            add(id, variant: 0, note: "default")
        }
        for variant in [4, 8, 5] { add(.rockPaperScissors, variant: variant, samples: 5, note: "another hand") }
        add(.showCode, variant: 1, samples: 5, note: "delighted")
        add(.sleepWatch, variant: 1, note: "Patch naps")
        add(.coffeeDelivery, variant: 0, loop: .typing, samples: 5, note: "Patch was typing")
        add(.highFive, variant: 0, reduced: true, samples: 5, note: "reduced motion")
        add(.victoryDance, variant: 0, reduced: true, samples: 5, note: "reduced motion")
        add(.graduation, variant: 0, intensity: .lively, samples: 5, note: "lively")

        var root = FixtureObject()
        root.str("about", "Interaction scripts from TamagotchiCore's InteractionLibrary (mochi_world's port must match): the script's duration "
                 + "and beats, and whole frames (both poses and the scene props) at elapsed times t, for a playback started at 50 s with the "
                 + "given companion loop and CompanionDetail(subagents: 1).")
        root.list("cases", cases, omitEmpty: false, multiline: true)
        return root.json
    }
}
