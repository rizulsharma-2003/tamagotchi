import Foundation

/// Allocation-free timing helpers for Mochi's choreography. Everything is a pure
/// function of time so poses can be sampled at any moment (and at several moments
/// per frame for secondary motion).
enum Choreo {
    /// Local 0…1 progress of `t` within [a, b].
    @inline(__always) static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { Ease.segment(t, a, b) }

    @inline(__always) static func smooth(_ x: Double) -> Double { Ease.smooth(x) }

    /// Smoothly moves from `from` to `to` while `t` crosses [a, b].
    @inline(__always) static func ramp(_ t: Double, _ a: Double, _ b: Double, _ from: Double, _ to: Double) -> Double {
        from + (to - from) * Ease.smooth(Ease.segment(t, a, b))
    }

    /// Ease-in (accelerating) ramp.
    @inline(__always) static func rampIn(_ t: Double, _ a: Double, _ b: Double, _ from: Double, _ to: Double) -> Double {
        let s = Ease.segment(t, a, b)
        return from + (to - from) * s * s
    }

    /// Ease-out (decelerating) ramp.
    @inline(__always) static func rampOut(_ t: Double, _ a: Double, _ b: Double, _ from: Double, _ to: Double) -> Double {
        let s = 1 - Ease.segment(t, a, b)
        return from + (to - from) * (1 - s * s)
    }

    /// Ramp with a springy overshoot at the end.
    @inline(__always) static func rampBack(_ t: Double, _ a: Double, _ b: Double, _ from: Double, _ to: Double, overshoot: Double = 1.70158) -> Double {
        from + (to - from) * Ease.outBack(Ease.segment(t, a, b), overshoot)
    }

    /// A quick "perk up" with a gentle overshoot (ears, a startled look): fast but never a snap.
    @inline(__always) static func perk(_ t: Double, _ a: Double, _ b: Double, _ from: Double, _ to: Double) -> Double {
        from + (to - from) * Ease.outBack(Ease.segment(t, a, b), 1.0)
    }

    /// 0 outside [a, b], 1 inside, with smooth fades of `fade` seconds at both ends.
    @inline(__always) static func window(_ t: Double, _ a: Double, _ b: Double, fade: Double) -> Double {
        guard t > a, t < b else { return 0 }
        let f = max(0.0001, min(fade, (b - a) / 2))
        return Ease.smooth(min((t - a) / f, (b - t) / f, 1))
    }

    /// Sine bump: 0 outside [a, b], 1 in the middle.
    @inline(__always) static func bump(_ t: Double, _ a: Double, _ b: Double) -> Double { Ease.bump(t, a, b) }

    /// Parabolic hop height (0 → 1 → 0) for a jump spanning [a, b].
    @inline(__always) static func hop(_ t: Double, _ a: Double, _ b: Double) -> Double {
        guard t > a, t < b else { return 0 }
        return Ease.hop((t - a) / (b - a))
    }

    /// A damped oscillation that starts at 1 when `age` = 0 (0 before).
    @inline(__always) static func ring(_ age: Double, frequency: Double, decay: Double) -> Double {
        guard age >= 0 else { return 0 }
        return exp(-decay * age) * cos(2 * .pi * frequency * age)
    }

    /// Smooth value noise in -1…1 (deterministic for a seed).
    static func noise(_ x: Double, _ seed: UInt64) -> Double {
        let i = floor(x)
        let f = x - i
        let n = Int(i)
        let a = Ease.hash(n, seed) * 2 - 1
        let b = Ease.hash(n &+ 1, seed) * 2 - 1
        return a + (b - a) * Ease.smooth(f)
    }

    /// Lift (body heights) that keeps Mochi's silhouette on the floor while rotated about
    /// the body centre: rotating a bean shape dips its lower edge into the ground.
    static func floorLift(_ rotation: Double, scaleX: Double = 1, scaleY: Double = 1) -> Double {
        let r = remainder(rotation, 2 * .pi)
        guard abs(r) > 0.02 else { return 0 }
        let s = sin(r), c = cos(r)
        // Silhouette points relative to the pivot (0, -27), y down, including feet and ears;
        // the body is scaled about the feet before it rotates.
        var lowest = -Double.infinity
        for (x, y) in floorProbe {
            let px = x * scaleX
            let py = (y - 27) * scaleY + 27
            lowest = max(lowest, px * s + py * c)
        }
        return max(0, lowest - 29.2) / 54
    }

    static let floorProbe: [(Double, Double)] = [
        (-19, 29.2), (-5, 29.2), (5, 29.2), (19, 29.2), (-27, 22), (27, 22), (-31, 8), (31, 8), (-31, -8), (31, -8),
        (-22, -24), (22, -24), (0, -27), (-16, -33), (16, -33),
    ]

    /// A 0…1 pulse train of `count` taps starting at `start`, `spacing` apart, each `width` long.
    @inline(__always) static func taps(_ t: Double, start: Double, spacing: Double, count: Int, width: Double) -> (index: Int, amount: Double) {
        guard t >= start else { return (-1, 0) }
        let k = Int((t - start) / spacing)
        guard k < count else { return (-1, 0) }
        let local = t - start - Double(k) * spacing
        return (k, Ease.bump(local, 0, width))
    }
}

/// A keyframe channel with per-segment easing. Tables are built once (static) so
/// evaluating a track never allocates.
struct Track: Sendable {
    enum Curve: Sendable { case linear, smooth, easeIn, easeOut, back, hold }

    private let times: [Double]
    private let values: [Double]
    private let curves: [Curve]

    /// `keys`: (time, value, curve used to arrive at this key).
    init(_ keys: [(Double, Double, Curve)]) {
        times = keys.map(\.0)
        values = keys.map(\.1)
        curves = keys.map(\.2)
    }

    func callAsFunction(_ t: Double) -> Double {
        guard let first = times.first else { return 0 }
        if t <= first { return values[0] }
        var index = 1
        while index < times.count, t > times[index] { index += 1 }
        guard index < times.count else { return values[values.count - 1] }
        let t0 = times[index - 1], t1 = times[index]
        let s = t1 > t0 ? (t - t0) / (t1 - t0) : 1
        let v0 = values[index - 1], v1 = values[index]
        let shaped: Double
        switch curves[index] {
        case .linear: shaped = s
        case .smooth: shaped = Ease.smooth(s)
        case .easeIn: shaped = s * s
        case .easeOut: shaped = 1 - (1 - s) * (1 - s)
        case .back: shaped = Ease.outBack(s, 1.6)
        case .hold: shaped = s < 1 ? 0 : 1
        }
        return v0 + (v1 - v0) * shaped
    }
}

// MARK: - Effects

extension PetPose {
    /// Body widths per path unit (pet home → companion home) in the popover scene; used to
    /// keep world-space props still while Mochi moves.
    static let worldScale = PetPoseEvaluator.bodyWidthsPerPathUnit

    mutating func add(_ effect: Effect) {
        if effects.isEmpty { effects.reserveCapacity(12) }
        if effects.count < PetPoseEvaluator.maxEffects { effects.append(effect) }
    }

    /// Where a point on Mochi (art units: origin at the feet, y negative upwards, the 60 × 54
    /// body) is drawn, in effect units (body widths / body heights from the lifted feet, y up),
    /// following squash, lean and rotation the way the renderer does; `face` points also turn
    /// with the head tilt. For props held in the paws or the mouth.
    func bodyPoint(_ ax: Double, _ ay: Double, face: Bool = false) -> (x: Double, y: Double) {
        var x = ax
        var y = ay
        if face, tilt != 0 {
            let c = cos(tilt), s = sin(tilt)
            let dy = y + 27
            (x, y) = (x * c - dy * s, x * s + dy * c - 27)
        }
        let side = facing >= 0 ? 1.0 : -1.0
        x *= scaleX
        y *= scaleY
        x -= lean * side * y
        let c = cos(rotation), s = sin(rotation)
        let dy = y + 27
        (x, y) = (x * c - dy * s, x * s + dy * c - 27)
        return (x / 60, -y / 54)
    }

    /// The mouth, in effect units (see `bodyPoint`).
    var mouthPoint: (x: Double, y: Double) {
        let side = facing >= 0 ? 1.0 : -1.0
        let shift = 1.6 * Ease.clamp(lookX, -1, 1) * (1 - crossEyed) + PetPose.faceShift * headTurn * side
        return bodyPoint(shift, -20, face: true)
    }

    /// Art units the face slides per unit of `headTurn` (the renderer uses the same).
    public static let faceShift = 2.4

    /// Adds a prop positioned in world space: `x` in body widths from Mochi's home, `y` in
    /// body heights above the floor. Call after the pose's own x/y are final. The effect is
    /// marked `worldSpace` so hosts with another path scale (and the tiny fit) can keep it still.
    mutating func addWorld(_ effect: Effect) {
        var e = effect
        e.x -= x * PetPose.worldScale
        e.y -= y
        e.worldSpace = true
        add(e)
    }
}

/// Reusable particle choreography for the pet. Each builder appends into a pose
/// (no intermediate arrays).
enum PetFX {
    static func zParticles(_ p: inout PetPose, g: Double, x: Double, y: Double, reduced: Bool, slow: Double = 1) {
        for index in 0..<3 {
            let f = Ease.fract(g / (3.2 * slow) + Double(index) / 3)
            if reduced {
                p.add(Effect(.z, x: x + 0.12 * Double(index), y: y + 0.2 * Double(index), scale: 0.6 + 0.2 * Double(index), opacity: 0.85))
            } else {
                let sway = 0.05 * sin(f * 2 * .pi + Double(index))
                p.add(Effect(.z, x: x + 0.22 * f + sway, y: y + 0.55 * f, scale: 0.5 + 0.55 * f,
                             opacity: sin(.pi * f) * 0.95, rotation: -0.25 + 0.35 * f))
            }
        }
    }

    /// `variant` 0 = gold (reserved for real-event reactions), 1 = pastel (play and care).
    static func sparkles(_ p: inout PetPose, t: Double, around center: (Double, Double), count: Int, spread: Double, seed: UInt64,
                         life: Double = 0.7, variant: Int = 0) {
        for index in 0..<count {
            let angle = Ease.hash(index, seed) * 2 * .pi
            let radius = spread * (0.7 + 0.3 * Ease.hash(index + 11, seed))
            let delay = Double(index) * 0.18
            let amount = Ease.bump(t - delay, 0, life)
            guard amount > 0.01 else { continue }
            p.add(Effect(.sparkle, x: center.0 + cos(angle) * radius, y: center.1 + sin(angle) * radius * 0.6 + 0.1,
                         scale: 0.45 + 0.6 * amount, opacity: amount, rotation: t * 2, variant: variant))
        }
    }

    /// Hearts that rise, sway and (optionally) burst into tiny hearts at the end.
    static func hearts(_ p: inout PetPose, t: Double, x: Double, y: Double, count: Int, spacing: Double = 0.35,
                       rise: Double = 0.5, reduced: Bool, pop: Bool = false, life: Double = 1.3) {
        for index in 0..<count {
            let local = t - Double(index) * spacing
            guard local > 0, local < life + (pop ? 0.3 : 0) else { continue }
            let side = index % 2 == 0 ? -1.0 : 1.0
            let baseX = x + side * 0.1 * Double((index + 1) / 2) + (index == 0 ? 0 : 0.02)
            if pop, local >= life {
                let age = (local - life) / 0.3
                p.add(Effect(.heartPop, x: baseX, y: y + (reduced ? 0.15 : rise), scale: 0.8, opacity: 1 - age, phase: age))
                continue
            }
            let f = local / life
            let sway = reduced ? 0 : 0.06 * sin(local * 6 + Double(index))
            p.add(Effect(.heart, x: baseX + sway, y: y + (reduced ? 0.15 : rise * Ease.outCubic(f)),
                         scale: 0.5 + 0.35 * Ease.outBack(min(1, f * 3)), opacity: pop ? min(1, f * 6) : sin(.pi * f),
                         rotation: reduced ? 0 : 0.18 * sin(local * 4 + Double(index))))
        }
    }

    static func notes(_ p: inout PetPose, t: Double, x: Double, y: Double, reduced: Bool) {
        for index in 0..<2 {
            let f = Ease.fract(t / 1.6 + Double(index) * 0.5)
            p.add(Effect(.note, x: x + (reduced ? 0 : 0.15 * sin(f * 6)) + 0.12 * Double(index), y: y + (reduced ? 0.1 : 0.45 * f),
                         scale: 0.7, opacity: sin(.pi * f), rotation: 0.2 * sin(f * 5), variant: index))
        }
    }

    /// Lavender "dizzy" stars circling the head (gold stars are reserved for real events).
    static func dizzyStars(_ p: inout PetPose, t: Double, amount: Double, y: Double = 1.08) {
        guard amount > 0.01 else { return }
        for index in 0..<3 {
            let angle = t * 6 + Double(index) * 2.09
            p.add(Effect(.star, x: 0.3 * cos(angle), y: y + 0.08 * sin(angle), scale: 0.42 + 0.06 * sin(angle), opacity: amount, variant: 1))
        }
    }

    static func confetti(_ p: inout PetPose, t: Double, originY: Double, count: Int, seed: UInt64, reduced: Bool) {
        guard t > 0, t < 1.9 else { return }
        for index in 0..<count {
            let angle = Ease.lerp(-2.4, -0.7, Ease.hash(index, seed)) * -1
            let speed = 0.6 + 0.5 * Ease.hash(index + 5, seed)
            let fall = t * t * 0.55
            let x = cos(angle) * speed * min(t, 0.9) * (Ease.hash(index + 9, seed) > 0.5 ? 1 : -1)
            let y = originY + sin(angle) * speed * min(t, 0.6) - fall
            let opacity = 1 - Ease.segment(t, 1.3, 1.9)
            if reduced {
                p.add(Effect(.confetti, x: cos(Double(index)) * 0.5, y: originY + 0.1 * Double(index % 3), scale: 0.6, opacity: opacity, variant: index % 4))
            } else {
                p.add(Effect(.confetti, x: x, y: y, scale: 0.6, opacity: opacity, rotation: t * 8 + Double(index), variant: index % 4))
            }
        }
    }

    /// A pair of dust puffs spreading from a point on the floor (world space).
    static func dustPuff(_ p: inout PetPose, age: Double, worldX: Double, strength: Double, life: Double = 0.38) {
        guard age >= 0, age < life, strength > 0.02 else { return }
        let f = age / life
        let spread = Ease.outCubic(f)
        let fade = pow(1 - f, 1.4) * (0.45 + 0.55 * strength)
        for index in 0..<2 {
            let side = index == 0 ? -1.0 : 1.0
            p.addWorld(Effect(.dust, x: worldX + side * (0.3 + 0.32 * spread * (0.6 + 0.4 * strength)), y: 0.03 + 0.06 * f,
                              scale: (0.5 + 0.6 * spread) * (0.65 + 0.5 * strength), opacity: fade, rotation: side * 0.2,
                              variant: side < 0 ? 0 : 1, phase: f))
        }
    }

    /// A small dust kick at the feet; `side` -1 = behind a right-facing Mochi (screen space,
    /// so `PetPose.mirrored()` puts it behind a left-facing one).
    static func dustKick(_ p: inout PetPose, age: Double, life: Double = 0.36, strength: Double = 0.6, side: Double = -1) {
        guard age >= 0, age < life else { return }
        let f = age / life
        p.add(Effect(.dust, x: side * (0.22 + 0.35 * Ease.outCubic(f)), y: 0.04 + 0.12 * f,
                     scale: (0.35 + 0.45 * Ease.outCubic(f)) * strength + 0.1, opacity: (1 - f) * 0.85,
                     rotation: 0, variant: side < 0 ? 0 : 1, phase: f))
    }

    /// Crumbs (or droplets) thrown from a point on ballistic arcs: they fly out, land on the
    /// floor, bounce once and fade (world space). `born` lists when each one leaves.
    static func ballistic(_ p: inout PetPose, kind: EffectKind, t: Double, born: Double, fromX: Double, fromY: Double,
                          side: Double, speed: Double, up: Double, seed: Int, scale: Double = 0.8, life: Double = 0.85,
                          spin: Double = 9) {
        let age = t - born
        guard age >= 0, age < life else { return }
        let gravity = 4.2
        // Flight until it meets the floor, then a small bounce and a rest.
        let land = (up + sqrt(up * up + 2 * gravity * max(0, fromY - 0.03))) / gravity
        var x: Double
        var y: Double
        if age < land {
            x = fromX + side * speed * age
            y = fromY + up * age - 0.5 * gravity * age * age
        } else {
            let after = age - land
            let bounceUp = 0.35 * (gravity * land - up)
            let bounce = max(0, bounceUp * after - 0.5 * gravity * after * after)
            x = fromX + side * (speed * land + 0.35 * speed * min(after, 2 * bounceUp / gravity))
            y = 0.03 + bounce
        }
        y = max(0.03, y)
        let fade = 1 - Choreo.seg(age, life - 0.25, life)
        p.addWorld(Effect(kind, x: x, y: y, scale: scale, opacity: fade, rotation: spin == 0 ? side * 0.6 : side * min(age, land) * spin,
                          variant: abs(seed) % 3))
    }

    /// A swipe streak along an arc (body space).
    static func streak(_ p: inout PetPose, x: Double, y: Double, angle: Double, length: Double, amount: Double, side: Int = 0) {
        guard amount > 0.02 else { return }
        p.add(Effect(.streak, x: x, y: y, scale: length, opacity: amount, rotation: angle, variant: side))
    }
}

/// A turn on the spot: the body squeezes thin, the tail sweeps to the middle and the eyes
/// lead; `facing` flips at the narrowest frame, so the change of side is hidden.
enum PetTurn {
    /// Squeeze amount 0…1 for a turn centred at `at` lasting `width` seconds.
    static func squeeze(_ t: Double, at: Double, width: Double = 0.2) -> Double {
        Choreo.bump(t, at - width / 2, at + width / 2)
    }

    static func apply(_ p: inout PetPose, t: Double, at: Double, width: Double = 0.2, motion m: Double) {
        let s = squeeze(t, at: at, width: width)
        guard s > 0 else { return }
        p.scaleX *= 1 - 0.2 * s * max(m, 0.5)
        p.scaleY *= 1 + 0.03 * s * m
        p.tailLift = Ease.lerp(p.tailLift, -0.55, s)
        p.tailCurl = Ease.lerp(p.tailCurl, 0.9, s)
        p.tailWag *= 1 - s
        p.lean *= 1 - s
        p.earPerk += 0.15 * s
    }
}
