import Foundation

/// Follow-through for Mochi's soft parts. Ears, tail and the jelly-like body react
/// to the primary motion as damped springs. The layer stays a pure function of
/// time: the primary pose is re-sampled over the last 0.4 s and each spring's
/// displacement is the convolution of the recent velocity with that spring's
/// impulse response (u(t) = −∫ v(t−τ) h′(τ) dτ). It also finds the most recent
/// landing in that window for squash and dust.
enum PetSecondaryMotion {
    static let step = 1.0 / 30
    /// 12 samples at 1/30 s: the look-back window is 0.4 s.
    static let samples = 12
    /// Height under which Mochi counts as touching the floor (body heights).
    static let contact = 0.004

    /// h′(τ) of an underdamped spring, sampled at the window's midpoints and tapered
    /// so truncating the window never pops.
    static func kernel(frequency: Double, damping: Double) -> [Double] {
        let omega = 2 * .pi * frequency
        let damped = omega * sqrt(1 - damping * damping)
        let span = Double(samples) * step
        return (0..<samples).map { k in
            let tau = (Double(k) + 0.5) * step
            let response = exp(-damping * omega * tau) * (cos(damped * tau) - damping * omega / damped * sin(damped * tau))
            return response * 0.5 * (1 + cos(.pi * tau / span))
        }
    }

    static let earKernel = kernel(frequency: 3.4, damping: 0.27)
    static let tailKernel = kernel(frequency: 2.3, damping: 0.22)
    static let bodyKernel = kernel(frequency: 5.0, damping: 0.4)

    struct Sample {
        var x: Double
        var y: Double
        var rotation: Double
    }

    /// Whether landings should puff dust and squash the body (loops with their own
    /// footfalls handle that themselves).
    static func detectsLandings(_ animation: PetAnimation) -> Bool {
        switch animation {
        case .walk, .carry, .run, .sleep, .curl, .sit: return false
        default: return true
        }
    }

    static func apply(_ p: inout PetPose, animation: PetAnimation, t: Double, duration d: Double, context: PoseContext, variant: Int) {
        let k = PetPoseEvaluator.bodyWidthsPerPathUnit
        var prev = Sample(x: p.x, y: p.y, rotation: p.rotation)
        var earY = 0.0, earX = 0.0, earR = 0.0
        var tailY = 0.0, tailX = 0.0, tailR = 0.0
        var bodyY = 0.0, bodyX = 0.0
        var vy = 0.0, vx = 0.0
        var landingAge = -1.0
        var landingX = 0.0
        var landingSpeed = 0.0
        var landingIndex = -1
        let detect = detectsLandings(animation)
        for index in 1...samples {
            let dt = Double(index) * step
            let cur = PetPoseEvaluator.kinematics(animation, elapsed: t - dt, duration: d, time: context.time - dt, context: context, variant: variant)
            let dy = prev.y - cur.y
            let dx = (prev.x - cur.x) * k
            let dr = remainder(prev.rotation - cur.rotation, 2 * .pi)
            let we = earKernel[index - 1], wt = tailKernel[index - 1], wb = bodyKernel[index - 1]
            earY -= dy * we; earX -= dx * we; earR -= dr * we
            tailY -= dy * wt; tailX -= dx * wt; tailR -= dr * wt
            bodyY -= dy * wb; bodyX -= dx * wb
            if index == 1 {
                vy = dy / step
                vx = dx / step
            }
            if detect {
                if landingIndex == index - 1, index > 1 {
                    // Speed just before touching down.
                    landingSpeed = max(landingSpeed, -dy / step)
                }
                if landingIndex < 0, prev.y <= contact, cur.y > contact {
                    // Touchdown lies between `cur` (dt ago, still in the air) and the newer
                    // `prev` (dt − step ago, on the floor). A hop often flattens onto the floor
                    // between samples, so refine by bisection rather than interpolating (which
                    // would make the dust's age stutter by up to half a step).
                    var lo = dt - step, hi = dt
                    for _ in 0..<4 {
                        let mid = (lo + hi) / 2
                        let y = PetPoseEvaluator.kinematics(animation, elapsed: t - mid, duration: d, time: context.time - mid,
                                                            context: context, variant: variant).y
                        if y > contact { hi = mid } else { lo = mid }
                    }
                    landingAge = max(0, (lo + hi) / 2)
                    landingX = prev.x
                    landingIndex = index
                    landingSpeed = (cur.y - prev.y) / step
                }
            }
            prev = cur
        }

        let m = max(0.5, context.motion)
        // Ears: flop outward when the body is yanked up or stops on landing, swing
        // against horizontal moves and lag behind rotation.
        let flop = Ease.clamp(-earY * 2.6, -0.4, 0.85) * m
        let swing = Ease.clamp(earX * 1.6 + earR * 0.9, -0.75, 0.75) * m
        // Ear fields are stored in Mochi's own frame (the renderer mirrors them when
        // facing left), so a world-space swing is multiplied by facing.
        p.earLeft += -flop + swing * p.facing
        p.earRight += flop + swing * p.facing
        // A little extra droop while moving fast.
        p.earPerk -= Ease.clamp(abs(vx) * 0.12, 0, 0.25)

        // Tail: lags behind vertical moves and rotation, streams out with speed.
        p.tailWag += Ease.clamp(tailY * 2.4 + tailR * 1.3 * p.facing, -0.9, 0.9) * m
        p.tailCurl += Ease.clamp(-abs(vx) * 0.22 + tailX * p.facing * 0.6, -0.8, 0.4)
        p.tailLift += Ease.clamp(-tailY * 1.4, -0.5, 0.5)

        // Body: jelly follow-through plus stretch along fast vertical motion.
        let jiggle = Ease.clamp(bodyY * 2.2, -0.15, 0.1)
        let stretch = Ease.clamp(abs(vy) * 0.03, 0, 0.09)
        let sy = 1 + (jiggle + stretch) * m
        p.scaleY *= sy
        p.scaleX *= 1 - 0.8 * (sy - 1)

        // Lean into horizontal motion, with follow-through when stopping.
        p.lean += (Ease.clamp(vx * 0.055, -0.13, 0.13) + Ease.clamp(bodyX * 1.1, -0.1, 0.1)) * p.facing * m

        if landingIndex > 0, landingSpeed > 0.9 {
            let strength = Ease.clamp((landingSpeed - 0.9) / 2.4)
            // Extra impact squash right at touchdown.
            let impact = Choreo.ring(landingAge, frequency: 3.2, decay: 11) * Ease.clamp(1 - landingAge / 0.3)
            p.scaleY *= 1 - 0.07 * strength * max(0, impact) * m
            p.scaleX *= 1 + 0.06 * strength * max(0, impact) * m
            PetFX.dustPuff(&p, age: landingAge, worldX: landingX * k, strength: strength)
        }
        // Squash and stretch change the silhouette: keep a tipped body on the floor.
        if abs(p.rotation) > 0.02 {
            p.y = max(p.y, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY))
        }
    }
}
