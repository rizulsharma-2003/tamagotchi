import Foundation

/// Mochi's "alive" layer: breathing with a belly rise, natural blinks (single,
/// double, slow), eye saccades with holds, single-ear twitches, tail swishes,
/// weight shifts and small idle behaviours. Everything is derived from global
/// time and the per-character seed, so it is deterministic, continues across
/// animations and never synchronizes between characters.
enum PetLife {
    private static let blinkSalt: UInt64 = 0xB11C_0001
    private static let gazeSalt: UInt64 = 0x6A2E_0002
    private static let earSalt: UInt64 = 0xEA25_0003
    private static let tailSalt: UInt64 = 0x7A11_0004
    private static let eventSalt: UInt64 = 0xE7E7_0005
    private static let dreamSalt: UInt64 = 0xD2EA_0006

    // MARK: Breathing

    /// -1 exhaled … 1 inhaled: a quicker inhale, a longer exhale and a short rest.
    static func breath(_ g: Double, period: Double, phase: Double) -> Double {
        let f = Ease.fract(g / period + phase)
        if f < 0.4 { return -1 + 2 * Ease.smooth(f / 0.4) }
        if f < 0.9 { return 1 - 2 * Ease.smooth((f - 0.4) / 0.5) }
        return -1
    }

    // MARK: Blinking

    /// Eye openness 0…1 with an irregular natural rhythm.
    /// `slowChance` raises the share of slow, trusting blinks (watching, content).
    static func blink(_ g: Double, seed: UInt64, slot: Double = 3.4, slowChance: Double = 0.12) -> Double {
        let s = seed ^ blinkSalt
        let n = Int(floor(g / slot))
        guard Ease.hash(n, s) > 0.1 else { return 1 }
        let start = Double(n) * slot + Ease.hash(n &+ 101, s) * (slot - 1.0)
        let local = g - start
        guard local >= 0, local < 0.9 else { return 1 }
        let kind = Ease.hash(n &+ 211, s)
        let closed: Double
        if kind < 1 - slowChance - 0.16 {
            closed = blinkShape(local)
        } else if kind < 1 - slowChance {
            closed = max(blinkShape(local), blinkShape(local - 0.24))
        } else {
            closed = slowBlinkShape(local)
        }
        return 1 - 0.97 * closed
    }

    /// Quick lid close (0.06 s), tiny hold, slightly slower open.
    static func blinkShape(_ l: Double) -> Double {
        guard l > 0, l < 0.19 else { return 0 }
        if l < 0.06 { return Ease.smooth(l / 0.06) }
        if l < 0.09 { return 1 }
        return 1 - Ease.smooth((l - 0.09) / 0.1)
    }

    /// The slow "I trust you" blink: lids drift down, rest, and lift lazily.
    static func slowBlinkShape(_ l: Double) -> Double {
        guard l > 0, l < 0.78 else { return 0 }
        if l < 0.16 { return Ease.smooth(l / 0.16) }
        if l < 0.4 { return 1 }
        return 1 - Ease.smooth((l - 0.4) / 0.38)
    }

    // MARK: Gaze

    struct Gaze {
        var x: Double
        var y: Double
        /// Slow head-follow of the gaze, -1…1.
        var head: Double
    }

    /// Saccades: the eyes jump quickly to a new point, hold (about `slot` ± 50 %), and jump
    /// again; the head follows lazily. Rests look straight at the user.
    static func gaze(_ g: Double, seed: UInt64, slot: Double = 3.8, center: (Double, Double) = (0.04, 0.0),
                     range: (Double, Double) = (0.7, 0.3), restChance: Double = 0.35) -> Gaze {
        let s = seed ^ gazeSalt
        let n = Int(floor(g / slot))
        func target(_ k: Int) -> (Double, Double) {
            if Ease.hash(k &* 3, s) < restChance { return center }
            return (center.0 + range.0 * (2 * Ease.hash(k &* 3 &+ 1, s) - 1),
                    center.1 + range.1 * (2 * Ease.hash(k &* 3 &+ 2, s) - 1))
        }
        func saccadeTime(_ k: Int) -> Double { (Double(k) + 0.25 + 0.5 * Ease.hash(k &+ 77, s)) * slot }
        let t0 = target(n - 2), t1 = target(n - 1), t2 = target(n)
        let eyeBlend = Ease.smooth((g - saccadeTime(n)) / 0.075)
        let x = Ease.lerp(t1.0, t2.0, eyeBlend)
        let y = Ease.lerp(t1.1, t2.1, eyeBlend)
        let prevHead = Ease.smooth((g - saccadeTime(n - 1)) / 0.5)
        let headFrom = Ease.lerp(t0.0, t1.0, prevHead)
        let head = Ease.lerp(headFrom, t2.0, Ease.smooth((g - saccadeTime(n)) / 0.5))
        // A whisper of drift during holds keeps the eyes from looking painted on.
        let drift = 0.025 * Choreo.noise(g * 0.9, s &+ 9)
        return Gaze(x: x + drift, y: y + 0.6 * drift, head: head)
    }

    // MARK: Ears and tail

    /// Occasional single-ear flicks, as outward angles (radians) per ear.
    static func earTwitch(_ g: Double, seed: UInt64, slot: Double = 3.1, chance: Double = 0.42, strength: Double = 1) -> (left: Double, right: Double) {
        let s = seed ^ earSalt
        let n = Int(floor(g / slot))
        guard Ease.hash(n, s) < chance else { return (0, 0) }
        let start = Double(n) * slot + Ease.hash(n &+ 5, s) * (slot - 0.75)
        let l = g - start
        guard l >= 0, l < 0.75 else { return (0, 0) }
        var amount = flick(l)
        if Ease.hash(n &+ 9, s) > 0.62 { amount += 0.8 * flick(l - 0.22) }
        amount *= strength
        return Ease.hash(n &+ 3, s) > 0.5 ? (0, amount) : (amount, 0)
    }

    /// A quick outward flick that springs back with a little overshoot.
    static func flick(_ l: Double) -> Double {
        guard l > 0, l < 0.45 else { return 0 }
        if l < 0.05 { return 0.4 * Ease.smooth(l / 0.05) }
        let r = l - 0.05
        return 0.4 * exp(-r * 13) * cos(r * 2 * .pi * 4.2)
    }

    /// A lazy tail sway with an occasional flick of the tip.
    static func tail(_ g: Double, seed: UInt64, energy: Double = 1) -> (wag: Double, curl: Double) {
        let s = seed ^ tailSalt
        let phase = Ease.hash(1, s) * 6.28
        let lazy = 0.36 * sin(2 * .pi * g / 3.1 + phase) * (0.65 + 0.35 * Choreo.noise(g / 3.7, s)) * energy
        var flickAmount = 0.0
        let slot = 4.3
        let n = Int(floor(g / slot))
        if Ease.hash(n, s &+ 1) < 0.38 {
            let start = Double(n) * slot + Ease.hash(n &+ 2, s) * (slot - 0.9)
            let l = g - start
            if l > 0, l < 0.9 { flickAmount = exp(-l * 4.5) * sin(l * 2 * .pi * 2.6) }
        }
        return (lazy + 0.7 * flickAmount * energy, 0.25 * abs(flickAmount))
    }

    // MARK: Base layer shared by every animation

    /// Breathing, blinks, gaze, ear twitches and tail swish. One-shots build on top of this.
    static func base(_ context: PoseContext, lite: Bool) -> PetPose {
        var p = PetPose()
        let g = context.time
        let phase = Ease.hash(1, context.seed)
        let b = breath(g, period: 3.6, phase: phase)
        let amount = context.reducedMotion ? 0.5 : 1
        p.breath = b
        p.scaleY = 1 + 0.02 * b * amount
        p.scaleX = 1 - 0.012 * b * amount
        p.tailWag = 0.35 * sin(g * 2.2) * context.motion
        guard !lite else { return p }
        p.eyeOpenness = blink(g, seed: context.seed)
        let gaze = gaze(g, seed: context.seed)
        p.lookX = gaze.x
        p.lookY = gaze.y
        p.earPerk = 0.08 * sin(g / 3 + phase * 6.28)
        // The head turns lazily after the eyes (screen space equals Mochi's own frame here: facing right).
        p.headTurn = 0.55 * (gaze.head - 0.04) * (context.reducedMotion ? 0.5 : 1)
        if !context.reducedMotion {
            p.tilt = 0.04 * (gaze.head - 0.04)
            let twitch = earTwitch(g, seed: context.seed, chance: 0.3)
            p.earLeft = -twitch.left
            p.earRight = twitch.right
            let tail = tail(g, seed: context.seed)
            p.tailWag = tail.wag
            p.tailCurl = tail.curl
        }
        return p
    }

    // MARK: Idle

    enum IdleEvent: Int {
        case none, weightShift, headTilt, earPerk, tailFlick, smile, blep, lick, pawLift, hop, stretchUp
        /// One ear swivels towards an imagined sound and the head turns to it.
        case listen
        /// The tail slowly curls up tight (or loosens), then relaxes.
        case tailCurl
    }

    /// The idle behaviour scheduled for this moment: at most one at a time, calm spacing.
    static func idleEvent(_ g: Double, seed: UInt64) -> (event: IdleEvent, local: Double, side: Double) {
        let s = seed ^ eventSalt
        let slot = 3.2
        let n = Int(floor(g / slot))
        let r = Ease.hash(n, s)
        let table: [(IdleEvent, Double)] = PetLife.idleTable
        var acc = 0.0
        var chosen = IdleEvent.none
        for (event, weight) in table {
            acc += weight
            if r < acc { chosen = event; break }
        }
        guard chosen != .none else { return (.none, 0, 1) }
        let duration = idleDuration(chosen)
        let start = Double(n) * slot + Ease.hash(n &+ 13, s) * (slot - duration - 0.05)
        let local = g - start
        guard local >= 0, local <= duration else { return (.none, 0, 1) }
        return (chosen, local, Ease.hash(n &+ 29, s) > 0.5 ? 1 : -1)
    }

    static let idleTable: [(IdleEvent, Double)] = [
        (.none, 0.2), (.weightShift, 0.11), (.headTilt, 0.09), (.listen, 0.12), (.earPerk, 0.06), (.tailFlick, 0.08),
        (.tailCurl, 0.06), (.smile, 0.07), (.blep, 0.04), (.lick, 0.05), (.pawLift, 0.06), (.hop, 0.03), (.stretchUp, 0.03),
    ]

    static func idleDuration(_ event: IdleEvent) -> Double {
        switch event {
        case .none: return 0
        case .weightShift: return 2.3
        case .headTilt: return 1.9
        case .earPerk: return 1.5
        case .tailFlick: return 0.9
        case .smile: return 1.7
        case .blep: return 1.2
        case .lick: return 0.75
        case .pawLift: return 1.4
        case .hop: return 0.8
        case .stretchUp: return 1.7
        case .listen: return 2.0
        case .tailCurl: return 2.6
        }
    }

    static func idle(_ p: inout PetPose, context: PoseContext, lite: Bool) {
        let g = context.time
        let m = context.motion
        let reduced = context.reducedMotion
        let (event, l, side) = idleEvent(g, seed: context.seed)
        switch event {
        case .none:
            break
        case .weightShift:
            let shift = Choreo.window(l, 0, 2.3, fade: 0.6)
            p.lean += side * 0.035 * shift * m
            // The unweighted foot shuffles as the weight moves.
            p.step += side * 0.55 * Choreo.bump(l, 0.05, 0.32) * (reduced ? 0 : 1) - side * 0.45 * Choreo.bump(l, 1.75, 2.0) * (reduced ? 0 : 1)
            if !lite { p.lookX += 0.15 * side * shift }
        case .headTilt:
            guard !lite else { break }
            let tilt = Choreo.window(l, 0, 1.9, fade: 0.38)
            p.tilt += side * 0.1 * tilt * (reduced ? 0.4 : 1)
            p.earPerk += 0.2 * tilt
            if side > 0 { p.earRight += 0.18 * tilt } else { p.earLeft -= 0.18 * tilt }
            p.lookY -= 0.12 * tilt
        case .earPerk:
            guard !lite else { break }
            let perk = Choreo.window(l, 0, 1.5, fade: 0.2)
            p.earPerk += 0.55 * perk
            p.lookX = Ease.lerp(p.lookX, 0.75 * side, perk)
            p.lookY = Ease.lerp(p.lookY, -0.1, perk)
            p.eyeScale += 0.06 * perk
        case .tailFlick:
            guard !lite, !reduced else { break }
            p.tailWag += 1.0 * exp(-l * 3.5) * sin(l * 2 * .pi * 3)
            p.tailCurl += 0.5 * Choreo.bump(l, 0, 0.9)
            p.tailLift += 0.4 * Choreo.bump(l, 0, 0.9)
        case .smile:
            guard !lite else { break }
            if l > 0.1, l < 1.6 { p.mouth = .smile }
            p.blush += 0.15 * Choreo.window(l, 0, 1.7, fade: 0.3)
        case .blep:
            guard !lite else { break }
            if l > 0.12, l < 1.05 { p.mouth = .blep }
        case .lick:
            guard !lite else { break }
            if l > 0.1, l < 0.42 { p.mouth = .lick } else if l >= 0.42, l < 0.6 { p.mouth = .nom }
        case .pawLift:
            let lift = Choreo.window(l, 0, 1.4, fade: 0.32)
            let knead = 0.07 * sin((l - 0.32) * 2 * .pi * 2.4) * Choreo.window(l, 0.32, 1.08, fade: 0.1)
            let value = 0.3 * lift + knead
            if side > 0 { p.rightArm = max(p.rightArm, value) } else { p.leftArm = max(p.leftArm, value) }
            if !lite { p.lookY += 0.28 * lift; p.lookX = Ease.lerp(p.lookX, 0.3 * side, lift) }
        case .hop:
            let crouch = Choreo.bump(l, 0, 0.16)
            p.scaleY -= 0.05 * crouch * m
            p.scaleX += 0.04 * crouch * m
            p.y += 0.05 * Choreo.hop(l, 0.14, 0.44) * m
            if !lite, l > 0.12, l < 0.62 { p.eyes = .happy; p.mouth = .smile }
        case .listen:
            // The ear on that side snaps round like a little radar dish, the head follows, both relax.
            let ear = Choreo.window(l, 0, 1.9, fade: 0.1) * (1 - 0.25 * Choreo.window(l, 0.9, 1.3, fade: 0.15))
            let head = Choreo.window(l, 0.12, 1.95, fade: 0.4)
            if !reduced {
                if side > 0 { p.earRight += 0.5 * ear } else { p.earLeft -= 0.5 * ear }
            }
            guard !lite else { break }
            p.headTurn += 0.55 * side * head
            p.lookX = Ease.lerp(p.lookX, 0.8 * side, head)
            p.lookY = Ease.lerp(p.lookY, -0.05, head)
            p.earPerk += 0.25 * ear
            p.eyeScale += 0.05 * head
            p.tilt += 0.05 * side * head * (reduced ? 0.4 : 1)
        case .tailCurl:
            guard !reduced else { break }
            let curl = Choreo.window(l, 0, 2.6, fade: 0.7)
            p.tailCurl += (side > 0 ? 0.8 : -0.6) * curl
            p.tailLift += 0.45 * curl
        case .stretchUp:
            let stretch = Choreo.window(l, 0, 1.7, fade: 0.45)
            p.leftArm = max(p.leftArm, 0.5 * stretch)
            p.rightArm = max(p.rightArm, 0.5 * stretch)
            p.scaleY += 0.045 * stretch * (reduced ? 0.25 : 1)
            p.scaleX -= 0.025 * stretch * (reduced ? 0.25 : 1)
            if !lite {
                if l > 0.25, l < 1.4 { p.eyes = .closed; p.mouth = .o }
                p.earPerk -= 0.3 * stretch
            }
        }
    }

    // MARK: Watching the companion

    static func watch(_ p: inout PetPose, context: PoseContext, lite: Bool) {
        let g = context.time
        let m = context.motion
        let s = context.seed ^ eventSalt
        // Occasional lean forward: something interesting on the screen.
        let leanSlot = 6.3
        let ln = Int(floor(g / leanSlot))
        var interest = 0.0
        if Ease.hash(ln, s &+ 41) < 0.4 {
            let start = Double(ln) * leanSlot + Ease.hash(ln &+ 1, s &+ 41) * (leanSlot - 2.6)
            interest = Choreo.window(g - start, 0, 2.6, fade: 0.5)
        }
        // Leaning towards the screen (a shear, so the feet stay planted and the pose stays upright).
        p.lean += (0.03 + 0.06 * interest) * m
        guard !lite else { return }
        // Only watch's own ear twitches (below), not the idle base's: an attentive, not restless, listener.
        p.earLeft = 0
        p.earRight = 0
        let gaze = gaze(g, seed: context.seed, slot: 1.6, center: (0.72, 0.12), range: (0.14, 0.1), restChance: 0.45)
        p.lookX = gaze.x
        p.lookY = gaze.y
        p.eyeOpenness = blink(g, seed: context.seed, slot: 3.8, slowChance: 0.3)
        p.earPerk = 0.45 + 0.25 * interest
        p.eyeScale += 0.08 * interest
        if interest > 0.5 { p.mouth = .o }
        // Curious head tilts.
        let tiltSlot = 4.6
        let tn = Int(floor(g / tiltSlot))
        if Ease.hash(tn, s &+ 43) < 0.38 {
            let start = Double(tn) * tiltSlot + Ease.hash(tn &+ 1, s &+ 43) * (tiltSlot - 1.8)
            let side = Ease.hash(tn &+ 2, s &+ 43) > 0.5 ? 1.0 : -1.0
            let tilt = Choreo.window(g - start, 0, 1.8, fade: 0.35)
            p.tilt = side * 0.09 * tilt * (context.reducedMotion ? 0.4 : 1)
            if side > 0 { p.earRight += 0.12 * tilt } else { p.earLeft -= 0.12 * tilt }
        } else {
            p.tilt = 0.03 * sin(g * 0.8) * max(m, 0.3)
        }
        p.headTurn = 0.45 + 0.2 * interest
        if !context.reducedMotion {
            // Ears swivel towards little sounds from the desk (about eight a minute).
            let twitch = earTwitch(g, seed: context.seed &+ 3, slot: 3.2, chance: 0.36)
            p.earLeft -= twitch.left
            p.earRight += twitch.right * 1.2
            let tail = tail(g, seed: context.seed, energy: 0.8)
            p.tailWag = tail.wag
            p.tailCurl = tail.curl + 0.2
            p.tailLift = 0.2
        }
    }

    // MARK: Gentle wave

    static func waveGently(_ p: inout PetPose, context: PoseContext, lite: Bool) {
        let g = context.time
        let m = context.motion
        let cycle = Ease.fract(g / 4.4) * 4.4
        let reduced = context.reducedMotion
        let anticipation = Choreo.bump(cycle, 0, 0.32)
        let raise = Choreo.rampBack(cycle, 0.22, 0.6, 0, 1, overshoot: 2.2) * (1 - Choreo.smooth(Choreo.seg(cycle, 1.95, 2.45)))
        let waving = Choreo.window(cycle, 0.55, 2.0, fade: 0.25)
        let wave = sin((cycle - 0.55) * 2 * .pi * 2.2) * waving
        if reduced {
            p.rightArm = 0.75 * Choreo.window(cycle, 0.1, 2.4, fade: 0.4)
        } else {
            p.rightArm = 0.1 - 0.08 * anticipation + 0.72 * raise + 0.14 * wave
        }
        p.lean += (0.025 * wave - 0.015 * anticipation) * m
        guard !lite else { return }
        p.lookX = 0.05 + 0.08 * sin(g * 0.7)
        p.lookY = -0.05
        p.mouth = raise > 0.6 ? .open : .smile
        p.eyes = raise > 0.6 && waving > 0.6 && Int(cycle * 2) % 3 == 0 ? .happy : .open
        p.blush += 0.15 * raise
        p.earPerk = 0.35 + 0.2 * raise
        if !reduced {
            p.earRight += 0.1 * wave
            p.earLeft += 0.06 * wave
            p.tilt = -0.04 * wave
            p.tailWag = 0.6 * sin(g * 5) * (0.4 + 0.6 * raise)
        }
    }

    // MARK: Sleep

    static func sleep(_ p: inout PetPose, context: PoseContext, lite: Bool, curled: Bool) {
        let g = context.time
        let m = context.motion
        let reduced = context.reducedMotion
        let s = context.seed ^ dreamSalt
        let period = curled ? 5.2 : 4.8
        let b = breath(g, period: period, phase: Ease.hash(2, context.seed))
        p.breath = b
        // A deep sigh now and then.
        let sighSlot = 11.0
        let sn = Int(floor(g / sighSlot))
        var sigh = 0.0
        if Ease.hash(sn, s) < 0.5 {
            let start = Double(sn) * sighSlot + Ease.hash(sn &+ 1, s) * (sighSlot - 2.2)
            sigh = Choreo.bump(g - start, 0, 2.2)
        }
        let depth = reduced ? 0.6 : 1
        if curled {
            p.scaleY = 0.82 + (0.022 * b + 0.015 * sigh) * depth
            p.scaleX = 1.12 - (0.012 * b + 0.008 * sigh) * depth
        } else {
            p.scaleY = 1 + (0.038 * b + 0.02 * sigh) * depth
            p.scaleX = 1 - (0.022 * b + 0.012 * sigh) * depth
        }
        p.y = 0
        p.rotation = 0
        p.tailWag = 0.12 * sin(g * 0.9) * m
        p.tailCurl = curled ? 1 : 0.75
        p.tailLift = curled ? 0.1 : -0.35
        guard !lite else { return }
        p.eyes = .closed
        p.eyeOpenness = 1
        p.mouth = .cat
        p.earPerk = curled ? -0.9 : -0.6
        p.headTurn = 0
        p.tilt = 0
        // Deep sleep: no idle ear twitches, only the odd dream flick (about two a minute).
        p.earLeft = 0
        p.earRight = 0
        p.blush = 0.5 + 0.08 * (b + 1) / 2
        p.lookX = 0
        p.lookY = 0
        // Dreams: a paw twitch, an ear flick, a little chew or a smile.
        let dreamSlot = 5.3
        let dn = Int(floor(g / dreamSlot))
        if Ease.hash(dn, s &+ 7) < 0.5 {
            let start = Double(dn) * dreamSlot + Ease.hash(dn &+ 1, s &+ 7) * (dreamSlot - 1.6)
            let l = g - start
            let kind = Ease.hash(dn &+ 2, s &+ 7)
            if l >= 0, l < 1.6 {
                if kind < 0.25, !reduced {
                    let twitch = Choreo.bump(l, 0, 0.12) + 0.7 * Choreo.bump(l, 0.22, 0.34)
                    p.rightArm = max(p.rightArm, 0.16 * twitch)
                } else if kind < 0.55, !reduced {
                    let flickAmount = flick(l)
                    if Ease.hash(dn &+ 3, s) > 0.5 { p.earRight += flickAmount } else { p.earLeft -= flickAmount }
                } else if kind < 0.8 {
                    if l < 1.0 { p.mouth = Int(l * 7) % 2 == 0 ? .nom : .cat }
                } else {
                    if l < 1.5 { p.mouth = .smile }
                    p.blush += 0.15 * Choreo.bump(l, 0, 1.6)
                }
            }
        }
        PetFX.zParticles(&p, g: g, x: curled ? 0.36 : 0.42, y: curled ? 0.72 : 0.95, reduced: reduced, slow: curled ? 1.15 : 1)
        // A nose bubble that swells as Mochi breathes out (some of the time), popping now and then.
        if !curled {
            let cyclePosition = g / period + Ease.hash(2, context.seed)
            let cycle = Int(floor(cyclePosition))
            let local = cyclePosition - floor(cyclePosition)
            if Ease.hash(cycle / 3, s &+ 21) < 0.55 {
                let swell = (1 - b) / 2
                let pops = cycle % 3 == 2
                if pops, local > 0.9 {
                    let age = (local - 0.9) / 0.1
                    p.add(Effect(.pop, x: 0.16, y: 0.4, scale: 0.6, opacity: 1 - age, variant: 1, phase: age))
                } else if (cycle - 1) % 3 == 2, local < 0.4 {
                    // Re-forms after the next breath in.
                } else {
                    p.add(Effect(.noseBubble, x: 0.08 + 0.08 * swell, y: 0.4, scale: 0.2 + 0.8 * swell * swell, opacity: 0.85))
                }
            }
        }
    }

    // MARK: Sit

    /// Sitting contentedly (the menu bar rests here for long stretches): open eyes with the
    /// usual blinks and glances, now and then a long contented squint or a blep, deeper
    /// breathing, and the tail wrapped round the feet with its tip flicking.
    static func sit(_ p: inout PetPose, context: PoseContext, lite: Bool) {
        let g = context.time
        let m = context.motion
        let reduced = context.reducedMotion
        let s = context.seed ^ eventSalt
        let b = breath(g, period: 3.4, phase: Ease.hash(1, context.seed))
        p.breath = b
        let depth = reduced ? 0.5 : 1
        p.scaleY = 0.9 + 0.02 * b * depth
        p.scaleX = 1.07 - 0.011 * b * depth
        p.tailCurl = 0.95
        p.tailLift = -0.3
        p.tailWag = 0.12 * sin(g * 1.1) * m
        if !reduced {
            let slot = 5.5
            let n = Int(floor(g / slot))
            if Ease.hash(n, s &+ 51) < 0.5 {
                let l = g - (Double(n) * slot + Ease.hash(n &+ 1, s &+ 51) * (slot - 1.1))
                if l > 0, l < 1.1 {
                    p.tailWag += 0.75 * exp(-l * 3.8) * sin(l * 2 * .pi * 2.2)
                    p.tailCurl -= 0.35 * Choreo.bump(l, 0, 1.1)
                    p.tailLift += 0.25 * Choreo.bump(l, 0, 1.1)
                }
            }
        }
        guard !lite else { return }
        p.earPerk = 0.35 + 0.05 * sin(g / 2.7)
        p.blush = 0.55
        p.lookY += 0.04
        // A long contented squint (eyes swap behind a blink at each end).
        let squintSlot = 9.0
        let sn = Int(floor(g / squintSlot))
        if Ease.hash(sn, s &+ 61) < 0.55 {
            let length = 1.5 + Ease.hash(sn &+ 2, s &+ 61)
            let from = Double(sn) * squintSlot + Ease.hash(sn &+ 1, s &+ 61) * (squintSlot - length - 0.3)
            let l = g - from
            if l > 0, l < length { p.eyes = .happy; p.blush += 0.15 }
            let swap = max(blinkShape(l + 0.08), blinkShape(l - length + 0.08))
            p.eyeOpenness = min(p.eyeOpenness, 1 - 0.95 * swap)
        }
        // A blep every 15–25 s.
        let blepSlot = 20.0
        let bn = Int(floor(g / blepSlot))
        let blepAt = Double(bn) * blepSlot + 2.5 + Ease.hash(bn, s &+ 71) * (blepSlot - 5)
        let bl = g - blepAt
        if bl > 0.12, bl < 1.0 {
            p.mouth = .blep
            p.tilt += 0.05 * Choreo.window(bl, 0, 1.0, fade: 0.12) * (reduced ? 0.4 : 1)
        }
    }
}

extension PetPoseEvaluator {
    /// Dev tools: the idle behaviour playing at `time` (its name, and seconds into it).
    public static func idleBehaviour(at time: Double, seed: UInt64) -> (name: String, local: Double) {
        let event = PetLife.idleEvent(time, seed: seed)
        return ("\(event.event)", event.local)
    }
}
