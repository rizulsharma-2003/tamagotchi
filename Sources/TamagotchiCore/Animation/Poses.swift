import Foundation

// MARK: - Shared pose vocabulary

public enum HeldItem: String, Codable, Sendable, CaseIterable {
    case coffee, ball, document, taskCard, magnifier, codeCard, trophy, gradCap
    case rock, paper, scissors, errorBoard, treat, detectiveHat
}

public enum EffectKind: String, Codable, Sendable, CaseIterable {
    case z, sparkle, heart, question, exclamation, sweat, note, star, confetti, steam
    case speechDots, speechLock, speechQuestion, plug, clap, thinkingDots
    case ball, treat, orb
    // Pet life, play and treat effects.
    /// Landing / footstep dust puff (`phase` 0…1 = age).
    case dust
    /// Swipe motion streak (`rotation` = direction, `scale` = length, `variant` = arc side).
    case streak
    /// Purr vibration lines beside the body (`variant` 0 = left, 1 = right, `phase` = jitter).
    case purr
    /// A cookie crumb (`variant` = shape).
    case crumb
    /// Yarn ball (`rotation` = spin, `stretch` = squash); the strand runs to (`x2`, `y2`) relative to the ball.
    case yarn
    /// Yarn strand wrapped around the body (`variant` = loops, `phase` = wobble).
    case tangle
    /// Butterfly (`phase` = wing beat, `variant` = colour).
    case butterfly
    /// Soap bubble (`phase` = wobble).
    case bubble
    /// Pop burst for bubbles, cheeks and catches (`phase` 0…1 = age, `variant` = colour).
    case pop
    /// Fish treat (`variant` 0…3 = bites taken, 3 = bones).
    case fish
    /// Strawberry.
    case berry
    /// Cupcake (`variant` 0 full, 1 licked, 2 one bite, 4 two bites, 3 only the wrapper left).
    case cupcake
    /// Little sniff puffs at the nose (`phase` = cycle).
    case sniff
    /// Sneeze burst (`phase` 0…1 = age).
    case sneeze
    /// Sleep nose bubble.
    case noseBubble
    /// Motion lines for a fast shake (`variant` 0 = left, 1 = right).
    case shakeLines
    /// Radial impact burst (`phase` 0…1 = age).
    case burst
    /// Water / drool droplet.
    case droplet
    /// Heart that bursts into tiny hearts (`phase` 0…1 = burst age).
    case heartPop
    /// Soft contact shadow under a prop on the floor.
    case shadow
    /// A dollop of pink frosting (e.g. stuck on Mochi's nose).
    case frosting
    /// "Noticed something!" lines above the head (pale; never the orange attention mark).
    case notice
}

/// A small particle or symbol drawn relative to a character (body units, origin
/// at the character's feet, y up).
public struct Effect: Equatable, Sendable {
    public var kind: EffectKind
    public var x: Double
    public var y: Double
    public var scale: Double
    public var opacity: Double
    public var rotation: Double
    public var variant: Int
    /// Squash (negative) or stretch (positive) of a prop, e.g. a ball hitting the floor.
    public var stretch: Double
    /// Free animation phase for props (wing beat, wobble, burst age).
    public var phase: Double
    /// Secondary anchor relative to (x, y), e.g. the far end of a yarn strand.
    public var x2: Double
    public var y2: Double
    /// Legacy: when true the renderer mirrors `x` with the character's facing. Mochi's own
    /// effects never set it any more: every effect is in screen space for the pose's facing,
    /// so turning a pose around with `PetPose.mirrored()` (or any mirror that negates effect
    /// `x`) keeps dust and speed lines behind the runner.
    public var followsFacing: Bool
    /// True for props placed in world space (`PetPose.addWorld`): a ball resting on the floor,
    /// a falling cookie. Their `x` was computed as `worldX − pose.x · PetPoseEvaluator.bodyWidthsPerPathUnit`,
    /// so a host that moves Mochi by `k′` body widths per unit of `pose.x` (instead of the popover's
    /// 2.25) keeps them still by adding `pose.x · (bodyWidthsPerPathUnit − k′)` to their `x`.
    public var worldSpace: Bool

    public init(_ kind: EffectKind, x: Double, y: Double, scale: Double = 1, opacity: Double = 1, rotation: Double = 0, variant: Int = 0,
                stretch: Double = 0, phase: Double = 0, x2: Double = 0, y2: Double = 0, followsFacing: Bool = false,
                worldSpace: Bool = false) {
        self.kind = kind
        self.x = x
        self.y = y
        self.scale = scale
        self.opacity = opacity
        self.rotation = rotation
        self.variant = variant
        self.stretch = stretch
        self.phase = phase
        self.x2 = x2
        self.y2 = y2
        self.followsFacing = followsFacing
        self.worldSpace = worldSpace
    }
}

public struct PoseContext: Sendable {
    /// Global monotonic time, for breathing and blinking that continue across animations.
    public var time: TimeInterval
    public var reducedMotion: Bool
    public var intensity: AnimationIntensity
    /// Per-character seed so blinks and glances never look synchronized.
    public var seed: UInt64
    /// The loop the character returns to when a one-shot ends (the animator's base: idle,
    /// watch, waveGently, sleep…). One-shots ease in from it and settle exactly onto it, so the
    /// hand-over never pops. Hosts that know the base loop should pass it; idle by default.
    public var returnLoop: PetAnimation

    public init(time: TimeInterval, reducedMotion: Bool = false, intensity: AnimationIntensity = .normal, seed: UInt64 = 1,
                returnLoop: PetAnimation = .idle) {
        self.time = time
        self.reducedMotion = reducedMotion
        self.intensity = intensity
        self.seed = seed
        self.returnLoop = returnLoop
    }

    /// Scale applied to translation, rotation and squash amplitudes.
    public var motion: Double {
        if reducedMotion { return 0 }
        switch intensity {
        case .calm: return 0.75
        case .normal: return 1
        case .lively: return 1.12
        }
    }
}

// MARK: - Pet

public enum PetEyes: String, Codable, Sendable {
    case open, closed, happy, wide, worried, dizzy, heart, wink, sleepy
    /// Squeezed shut > < (sneezing, a pop, a big effort).
    case squint
}

public enum Brows: String, Codable, Sendable {
    case none, worried, raised, confused
}

public enum PetMouth: String, Codable, Sendable {
    case cat, smile, open, o, flat, wavy, blep, nom, yawn
    /// Wide snapping bite with tiny fangs.
    case chomp
    /// Tongue swiping across the lips.
    case lick
    /// Big D-shaped happy grin.
    case grin
    /// Open mouth with the tongue out (running, excited).
    case pant
    /// A tiny pressed mouth (cheeks full, concentrating).
    case tiny
}

/// Mochi's pose. Channels are in screen space for the pose's `facing` unless noted as
/// "Mochi's own frame" (those the renderer mirrors itself). To turn a pose around, use
/// `mirrored()`: it is the only supported mirror (setting `facing` alone leaves the gaze,
/// tilt, arms, cheeks and effects pointing the old way).
public struct PetPose: Equatable, Sendable {
    /// Horizontal offset in scene-path units (0 = pet home, 1 = companion home; positive =
    /// towards the companion). The popover spans `PetPoseEvaluator.bodyWidthsPerPathUnit`
    /// body widths per unit; one-shots stay within about ±0.3 and start and end at 0.
    public var x = 0.0
    /// Lift off the ground in body heights.
    public var y = 0.0
    public var scaleX = 1.0
    public var scaleY = 1.0
    /// Whole-body rotation in radians (positive = clockwise).
    public var rotation = 0.0
    /// Head/face tilt in radians.
    public var tilt = 0.0
    /// 1 = facing the companion (right), -1 = facing left.
    public var facing = 1.0
    public var eyes = PetEyes.open
    public var eyeOpenness = 1.0
    public var lookX = 0.15
    public var lookY = 0.0
    public var brows = Brows.none
    public var mouth = PetMouth.cat
    public var blush = 0.35
    /// -1 drooped … 1 perked.
    public var earPerk = 0.0
    /// 0 = resting, 1 = raised straight up.
    public var leftArm = 0.0
    public var rightArm = 0.0
    public var tailWag = 0.0
    public var step = 0.0
    public var held: HeldItem?
    public var hat: HeldItem?
    public var effects: [Effect] = []
    public var shadow = 1.0
    public var opacity = 1.0

    // Secondary motion and finer expression (all default to the neutral pose).

    /// Extra rotation of each ear in radians (positive = clockwise on screen), from twitches and follow-through.
    public var earLeft = 0.0
    public var earRight = 0.0
    /// -1 straight out … 0 resting curl … 1 tightly curled.
    public var tailCurl = 0.0
    /// -1 lowered … 1 raised high.
    public var tailLift = 0.0
    /// Upper-body lean towards the facing direction (shear, fraction of body height; feet stay planted).
    public var lean = 0.0
    /// Breathing phase, -1 exhaled … 1 inhaled (belly rise).
    public var breath = 0.0
    /// Puffed cheeks, 0…1 per side.
    public var cheekLeft = 0.0
    public var cheekRight = 0.0
    /// 0…1 starry highlights in the eyes.
    public var eyeSparkle = 0.0
    /// Eye size multiplier (anticipation widens, effort narrows).
    public var eyeScale = 1.0
    /// 0…1 both eyes converge on the nose.
    public var crossEyed = 0.0
    /// -1…1 gait stride: the front foot moves forward (with `step` lifting the feet).
    public var stride = 0.0
    /// -1…1 lifts the left (negative) or right (positive) foot high, e.g. a scratch or a happy thump.
    public var kick = 0.0
    /// 0…1 brings the right paw up to the mouth (licking a paw).
    public var pawToMouth = 0.0
    /// 0…1 brings both paws together in front of the chest (holding a snack).
    public var holdFront = 0.0
    /// -1…1 head turn in Mochi's own frame (positive = towards the facing side): the face
    /// slides that way and the ears swivel, so a glance reads as the head turning.
    public var headTurn = 0.0
    /// 0…1 listening closely: the ear on the far side of a head turn comes forward, standing taller
    /// with its opening showing, while the near ear folds back.
    public var earListen = 0.0

    public init() {}

    /// The same pose facing the other way. Absolute channels (gaze, travel, rotation, head
    /// tilt, left/right parts and every effect position) are mirrored; channels stored in
    /// Mochi's own frame (lean, stride, kick, ears, tail, head turn) are mirrored by the
    /// renderer. This is the only supported way to make Mochi face left.
    public func mirrored() -> PetPose {
        var p = self
        p.facing = -facing
        p.lookX = -lookX
        p.x = -x
        p.rotation = -rotation
        p.tilt = -tilt
        p.leftArm = rightArm
        p.rightArm = leftArm
        p.cheekLeft = cheekRight
        p.cheekRight = cheekLeft
        p.effects = effects.map { effect in
            guard !effect.followsFacing else { return effect }
            var e = effect
            e.x = -e.x
            e.x2 = -e.x2
            e.rotation = -e.rotation
            return e
        }
        return p
    }
}

// MARK: - Companion

public enum VisorEyes: String, Codable, Sendable {
    case normal, happy, focused, worried, sleepy, wide, star, wink, off, heart, closed
}

public enum VisorMouth: String, Codable, Sendable {
    case none, smile, flat, o, grin, wavy
}

public enum AntennaTint: String, Codable, Sendable {
    case calm, working, attention, alert, off
}

public enum LaptopScreen: String, Codable, Sendable {
    case idle, code, terminal, web, search, docs, error, celebrate, off
}

public struct LaptopPose: Equatable, Sendable {
    public var visible = true
    /// 0 closed … 1 open.
    public var openness = 1.0
    public var screen = LaptopScreen.idle
    /// Animation phase for scrolling content.
    public var scroll = 0.0
}

public struct CompanionPose: Equatable, Sendable {
    public var x = 0.0
    public var y = 0.0
    public var scaleX = 1.0
    public var scaleY = 1.0
    public var rotation = 0.0
    public var facing = -1.0
    public var eyes = VisorEyes.normal
    public var eyeOpenness = 1.0
    public var lookX = 0.0
    public var lookY = 0.0
    public var mouth = VisorMouth.none
    public var visorBrightness = 1.0
    public var antennaGlow = 0.35
    public var antennaTint = AntennaTint.calm
    /// Antenna sway in radians.
    public var antennaBend = 0.0
    /// 0 = resting, 1 = raised up.
    public var leftArm = 0.0
    public var rightArm = 0.0
    /// 0 = arms at the side, 1 = reaching forward to the keyboard.
    public var reach = 0.0
    public var held: HeldItem?
    public var hat: HeldItem?
    public var laptop = LaptopPose()
    public var effects: [Effect] = []
    public var shadow = 1.0
    public var opacity = 1.0

    public init() {}
}

// MARK: - Easing

public enum Ease {
    @inlinable public static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }

    /// Local 0…1 progress of `t` within [start, end].
    @inlinable public static func segment(_ t: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return t >= end ? 1 : 0 }
        return clamp((t - start) / (end - start))
    }

    @inlinable public static func smooth(_ x: Double) -> Double {
        let c = clamp(x)
        return c * c * (3 - 2 * c)
    }

    @inlinable public static func outBack(_ x: Double, _ overshoot: Double = 1.70158) -> Double {
        let c = clamp(x) - 1
        return 1 + c * c * ((overshoot + 1) * c + overshoot)
    }

    @inlinable public static func outCubic(_ x: Double) -> Double {
        let c = 1 - clamp(x)
        return 1 - c * c * c
    }

    /// 0 → 1 → 0 parabola (a hop).
    @inlinable public static func hop(_ x: Double) -> Double {
        let c = clamp(x)
        return 4 * c * (1 - c)
    }

    /// Smooth bump: 0 outside [start, end], 1 in the middle.
    @inlinable public static func bump(_ t: Double, _ start: Double, _ end: Double) -> Double {
        guard t > start, t < end else { return 0 }
        return sin(.pi * (t - start) / (end - start))
    }

    /// Fades in over `fadeIn` and out over `fadeOut` within [0, duration].
    @inlinable public static func envelope(_ t: Double, duration: Double, fadeIn: Double = 0.2, fadeOut: Double = 0.3) -> Double {
        min(segment(t, 0, fadeIn), 1 - segment(t, duration - fadeOut, duration))
    }

    @inlinable public static func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }

    @inlinable public static func fract(_ x: Double) -> Double { x - floor(x) }

    /// Deterministic pseudo-random 0…1 from an integer and a seed.
    @inlinable public static func hash(_ n: Int, _ seed: UInt64) -> Double {
        var z = UInt64(bitPattern: Int64(n)) &+ seed &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Natural blinking: returns eye openness (0…1) for a global time.
    public static func blink(_ time: Double, seed: UInt64, period: Double = 4.2) -> Double {
        let cycle = Int(floor(time / period))
        let offset = hash(cycle, seed) * (period - 0.6)
        let local = time - Double(cycle) * period - offset
        let duration = 0.16
        var openness = 1.0
        if local >= 0, local < duration {
            openness = 1 - sin(.pi * local / duration) * 0.95
        }
        // Occasional double blink.
        if hash(cycle &+ 7_919, seed) > 0.82 {
            let second = local - 0.28
            if second >= 0, second < duration { openness = min(openness, 1 - sin(.pi * second / duration) * 0.95) }
        }
        return openness
    }
}
