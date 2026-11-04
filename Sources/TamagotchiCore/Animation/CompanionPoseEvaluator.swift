import Foundation

/// Extra context for the companion that only real session state can provide.
public struct CompanionDetail: Sendable, Equatable {
    public var waitingFor: AttentionKind?
    public var subagents: Int

    public init(waitingFor: AttentionKind? = nil, subagents: Int = 0) {
        self.waitingFor = waitingFor
        self.subagents = subagents
    }
}

/// The companion's animation language: a sturdy little pixel creature that bobs, hops and
/// squashes, expressive through its eyes and stubby arms.
public enum CompanionPoseEvaluator {
    public static func pose(
        _ animation: CompanionAnimation,
        elapsed t: Double,
        duration: Double? = nil,
        context: PoseContext,
        detail: CompanionDetail = CompanionDetail()
    ) -> CompanionPose {
        var p = basePose(context)
        let m = context.motion
        let g = context.time
        let d = duration ?? animation.defaultDuration

        switch animation {
        case .absent:
            p.opacity = 0
            p.laptop.openness = 0

        case .idleAtDesk, .scripted:
            // Now and then a little bounce on the spot.
            let cycle = Ease.fract(g / 11.3 + Ease.hash(5, context.seed)) * 11.3
            p.y += 0.09 * Ease.hop(Ease.segment(cycle, 0, 0.36)) * m
            p.scaleY = 1 - 0.1 * Ease.bump(cycle, 0.3, 0.46) * m

        case .thinking:
            p.lookY = -0.45
            p.lookX = 0.3 + 0.12 * sin(g * 0.7)
            p.leftArm = 0.42
            p.reach = 0.2
            p.antennaTint = .working
            p.antennaGlow = 0.45 + 0.35 * (0.5 + 0.5 * sin(g * 4))
            p.rotation = 0.07 * sin(g * 1.4) * m
            p.effects = [thinkingDots(g, reduced: context.reducedMotion)]

        case .typing:
            p.reach = 1
            let tap = context.reducedMotion ? 0 : 1.0
            p.leftArm = 0.1 + 0.12 * max(0, sin(g * 17)) * tap
            p.rightArm = 0.1 + 0.12 * max(0, sin(g * 17 + .pi)) * tap
            p.eyes = .focused
            p.lookY = 0.35
            p.lookX = 0.15 * sin(g * 0.8)
            p.y += 0.008 * sin(g * 17) * m
            p.laptop.screen = .code
            p.laptop.scroll = g * 0.8
            p.antennaTint = .working
            p.antennaGlow = 0.7 + 0.1 * sin(g * 9)

        case .reading:
            // Holds the page out to the side so the face stays visible.
            p.held = .document
            p.leftArm = 0.58
            p.rightArm = 0.12
            p.reach = 0.4
            let line = Ease.fract(g / 1.8)
            p.lookX = -0.85 + 0.45 * Ease.smooth(min(1, line * 1.2))
            p.lookY = -0.12 + 0.05 * floor(Ease.fract(g / 7.2) * 4)
            p.laptop.screen = .docs
            p.antennaTint = .working
            p.antennaGlow = 0.6

        case .searching:
            p.held = .magnifier
            let sweep = sin(g * 1.6)
            p.rightArm = 0.6 + 0.15 * sweep
            p.lookX = 0.55 * sweep
            p.lookY = 0.1
            p.eyes = .wide
            p.rotation = 0.04 * sweep * m
            p.laptop.screen = .search
            p.laptop.scroll = g
            p.antennaTint = .working
            p.antennaGlow = 0.65

        case .runningCommand:
            p.reach = 0.55
            p.eyes = .focused
            p.lookY = 0.35
            p.laptop.screen = .terminal
            p.laptop.scroll = g * 1.2
            p.antennaTint = .working
            p.antennaGlow = 0.45 + 0.45 * Ease.fract(g * 1.2)
            p.rightArm = 0.12 + 0.12 * Ease.bump(Ease.fract(g / 2.4) * 2.4, 0, 0.3)

        case .browsing:
            p.reach = 0.6
            p.lookY = 0.3
            p.lookX = 0.35 * sin(g * 2.1)
            p.laptop.screen = .web
            p.laptop.scroll = g * 0.5
            p.antennaTint = .working
            p.antennaGlow = 0.6
            p.rightArm = 0.12 + 0.1 * Ease.bump(Ease.fract(g / 1.9) * 1.9, 0, 0.25)

        case .delegating:
            p.lookY = -0.35
            p.lookX = 0.4 * sin(g * 0.9)
            p.leftArm = 0.5 + 0.2 * sin(g * 3) * max(m, 0.2)
            p.eyes = .happy
            p.laptop.screen = .code
            p.laptop.scroll = g * 0.4
            p.antennaTint = .working
            p.antennaGlow = 0.7

        case .waiting:
            let cycle = Ease.fract(g / 3.6) * 3.6
            let wave = Ease.bump(cycle, 0, 1.2) * (context.reducedMotion ? 0 : 1)
            p.rightArm = 0.85 + 0.1 * sin(cycle * 14) * wave
            p.lookX = 0
            p.lookY = -0.12
            p.eyes = .normal
            p.reach = 0.1
            p.antennaTint = .attention
            p.antennaGlow = 0.3 + 0.6 * (0.5 + 0.5 * sin(g * 2.4))
            let bubble: EffectKind
            switch detail.waitingFor {
            case .permission?: bubble = .speechLock
            case .mcpDialog?, .backgroundAgent?: bubble = .speechQuestion
            default: bubble = .speechDots
            }
            p.effects = [Effect(bubble, x: -0.62, y: 1.32 + 0.02 * sin(g * 2) * m, scale: 1, opacity: 1)]

        case .detective:
            p.hat = .detectiveHat
            p.held = .magnifier
            let sweep = sin(g * 1.4)
            p.rightArm = 0.55 + 0.12 * sweep
            p.lookX = 0.5 * sweep
            p.eyes = .focused
            p.antennaTint = .attention
            p.antennaGlow = 0.6
            p.laptop.screen = .error
            p.laptop.scroll = g * 0.3
            let cycle = Ease.fract(g / 4.5) * 4.5
            if cycle < 1.4 {
                p.effects = [Effect(.question, x: 0.5, y: 1.35, scale: 0.8 * Ease.outBack(Ease.segment(cycle, 0, 0.3)), opacity: Ease.bump(cycle, 0, 1.4))]
            }

        case .rest:
            p.laptop.openness = 0.04
            p.laptop.screen = .off
            p.held = .coffee
            let sipCycle = Ease.fract(g / 6.5) * 6.5
            let sip = Ease.bump(sipCycle, 0, 1.6)
            p.rightArm = 0.42 + 0.3 * sip
            p.eyes = sip > 0.4 ? .happy : .normal
            p.eyeOpenness *= 0.85
            p.mouth = .smile
            p.rotation = -0.05 * m
            p.y = 0.02 * sin(2 * .pi * g / 4) * m
            p.antennaGlow = 0.25
            p.effects = [steam(g, x: 0.48, y: 0.78, reduced: context.reducedMotion)]

        case .sleep:
            p.laptop.openness = 0.04
            p.laptop.screen = .off
            p.visorBrightness = 0.35
            p.eyes = .sleepy
            p.antennaGlow = 0.06
            p.antennaBend = 0.35
            p.y = -0.03 + 0.008 * sin(2 * .pi * g / 4.6) * m
            p.reach = 0.1
            p.effects = PetPoseEvaluator.zParticles(g + 1.1, x: 0.38, y: 1.05, reduced: context.reducedMotion)

        case .offline:
            p.laptop.openness = 0.04
            p.laptop.screen = .off
            p.eyes = .off
            p.visorBrightness = 0.3
            p.antennaTint = .off
            p.antennaGlow = 0
            p.y = -0.02
            p.effects = [Effect(.plug, x: -0.6, y: 1.25, scale: 0.9, opacity: 0.9)]

        case .arrive:
            let drop = Ease.segment(t, 0, 0.8)
            p.y = (1 - Ease.outBack(drop, 1.2)) * 1.3 * m
            let land = Ease.bump(t, 0.62, 0.95) * m
            p.scaleY = 1 - 0.14 * land
            p.scaleX = 1 + 0.1 * land
            p.opacity = Ease.segment(t, 0, 0.35)
            p.laptop.openness = 0.04
            p.laptop.screen = .off
            p.eyes = t < 0.75 ? .wide : .happy
            p.shadow = Ease.segment(t, 0.2, 0.8)
            p.rightArm = 0.85 * Ease.bump(t, 1.0, d) + 0.1 * sin(t * 14) * Ease.bump(t, 1.0, d)
            p.effects = PetPoseEvaluator.sparkles(t - 0.75, around: (0, 0.6), count: 4, spread: 0.7, seed: context.seed)

        case .setup:
            p.laptop.openness = Ease.outBack(Ease.segment(t, 0.2, 0.9), 1.1)
            p.laptop.screen = t < 0.9 ? .off : .celebrate
            p.laptop.scroll = t
            let stretch = Ease.bump(t, 0.9, 1.7)
            p.leftArm = 0.95 * stretch
            p.rightArm = 0.95 * stretch
            p.reach = 0.6 * Ease.segment(t, 0, 0.4) * (1 - stretch)
            p.eyes = t < 1.0 ? .focused : .happy
            p.antennaGlow = 0.3 + 0.5 * Ease.segment(t, 0.6, 1.2)

        case .readTaskCard:
            p.held = .taskCard
            let lift = Ease.outBack(Ease.segment(t, 0, 0.3))
            p.leftArm = 0.58 * lift
            p.rightArm = 0.15
            p.lookX = Keys.value(t, [(0, 0), (0.35, -0.9), (0.75, -0.4), (0.85, -0.9), (1.25, -0.4), (1.5, -0.2)])
            p.lookY = -0.1
            p.y += -0.025 * Ease.bump(t, 1.55, d) * m
            p.eyes = t > 1.55 ? .happy : .normal
            p.antennaTint = .working
            p.antennaGlow = 0.6

        case .concerned:
            p.eyes = .worried
            p.mouth = .wavy
            p.antennaTint = .alert
            p.antennaGlow = 0.5 + 0.2 * sin(t * 6)
            p.held = .errorBoard
            p.leftArm = 0.6 * Ease.outBack(Ease.segment(t, 0, 0.35))
            p.lookX = -0.35
            p.lookY = 0.1
            p.rightArm = 0.88 * Ease.bump(t, 0.9, 2.3) + 0.05 * sin(t * 20) * Ease.bump(t, 1.0, 2.2) * max(m, 0.2)
            p.rotation = -0.05 * Ease.envelope(t, duration: d) * m
            p.laptop.screen = .error
            p.effects = [Effect(.exclamation, x: 0.42, y: 1.32, scale: Ease.outBack(Ease.segment(t, 0.05, 0.3)), opacity: Ease.bump(t, 0, 1.0))]

        case .celebrate:
            let jump = Ease.segment(t, 0.15, 0.75)
            p.y = 0.32 * Ease.hop(jump) * m
            let crouch = (Ease.bump(t, 0, 0.17) + Ease.bump(t, 0.72, 0.95)) * m
            let stretch = Ease.bump(t, 0.15, 0.45) * m
            p.scaleY = 1 - 0.15 * crouch + 0.08 * stretch
            p.scaleX = 1 + 0.1 * crouch - 0.05 * stretch
            // A happy wiggle in mid-air (a spin would flatten a front-facing pixel sprite to a line).
            p.rotation = 0.09 * sin(t * 24) * Ease.bump(t, 0.2, 0.7) * m * (context.intensity == .calm ? 0 : 1)
            let arms = Ease.segment(t, 0.1, 0.3) * (1 - Ease.segment(t, 1.9, 2.4))
            p.leftArm = arms
            p.rightArm = arms
            p.eyes = .star
            p.mouth = .grin
            p.antennaGlow = 1
            p.laptop.screen = .celebrate
            p.laptop.scroll = t
            p.shadow = 1 - 0.5 * p.y
            p.effects = PetPoseEvaluator.confetti(t - 0.3, originY: 1.3, count: 8, seed: context.seed, reduced: context.reducedMotion)

        case .trophy:
            p.held = .trophy
            p.rightArm = Ease.outBack(Ease.segment(t, 0, 0.4))
            p.leftArm = 0.4
            p.y = 0.18 * Ease.hop(Ease.segment(t, 0.1, 0.5)) * m
            p.scaleY = 1 - 0.12 * Ease.bump(t, 0.45, 0.65) * m
            p.eyes = .star
            p.mouth = .grin
            p.antennaGlow = 1
            p.laptop.screen = .celebrate
            p.laptop.scroll = t
            p.effects = PetPoseEvaluator.sparkles(t - 0.3, around: (0.45, 1.35), count: 4, spread: 0.35, seed: context.seed)

        case .packUp:
            p.laptop.openness = 1 - Ease.smooth(Ease.segment(t, 0.6, 1.4))
            p.laptop.screen = t < 0.6 ? .idle : .off
            p.reach = 0.8 * (1 - Ease.segment(t, 1.2, 1.6))
            p.eyes = t > 1.3 ? .happy : .normal
            p.mouth = .smile
            if t > 1.6 { p.held = .coffee; p.rightArm = 0.42 }

        case .depart:
            p.laptop.openness = 0.04
            p.laptop.screen = .off
            let wave = Ease.bump(t, 0, 0.7)
            p.rightArm = 0.9 * wave + 0.1 * sin(t * 16) * wave
            p.eyes = .happy
            p.y = 1.2 * Ease.smooth(Ease.segment(t, 0.6, d)) * m
            p.opacity = 1 - Ease.segment(t, 0.7, d)
            p.shadow = 1 - Ease.segment(t, 0.6, 1.0)

        case .greet:
            let wave = Ease.bump(t, 0, d)
            p.rightArm = 0.88 * min(1, wave * 1.5) + 0.1 * sin(t * 15) * wave * max(m, 0.2)
            p.eyes = .happy
            p.mouth = .smile
            p.lookX = -0.3
            p.y += 0.11 * Ease.hop(Ease.segment(t, 0, 0.4)) * m

        case .nod:
            p.y += (-0.03 * Ease.bump(t, 0, 0.45) - 0.02 * Ease.bump(t, 0.45, 0.9)) * m
            p.eyes = t > 0.1 && t < 0.7 ? .happy : .normal

        case .wakeUp:
            p.visorBrightness = Ease.lerp(0.35, 1, Ease.segment(t, 0, 0.6))
            p.eyes = t < 0.4 ? .sleepy : (t < 0.8 ? .wide : .normal)
            p.antennaBend = 0.35 * (1 - Ease.outBack(Ease.segment(t, 0.3, 0.8)))
            p.antennaGlow = Ease.lerp(0.06, 0.5, Ease.segment(t, 0.2, 0.8))

        case .stretch:
            let stretch = Ease.bump(t, 0.1, 1.7)
            p.leftArm = 0.95 * stretch
            p.rightArm = 0.95 * stretch
            p.rotation = 0.05 * sin(t * 3) * stretch * m
            p.eyes = .closed
            p.mouth = .o
            p.reach = 0

        case .sip:
            p.held = .coffee
            p.rightArm = Keys.value(t, [(0, 0.42), (0.35, 0.78), (1.5, 0.78), (1.85, 0.42)])
            p.eyes = t > 0.5 && t < 1.6 ? .happy : .normal
            p.mouth = .smile
            p.effects = [steam(g, x: 0.45, y: 1.0, reduced: context.reducedMotion)]

        case .dance:
            let beat = t / 0.8
            let amount = Ease.envelope(t, duration: d, fadeIn: 0.25, fadeOut: 0.35)
            p.rotation = 0.1 * sin(2 * .pi * beat) * m * amount
            p.y += 0.1 * abs(sin(2 * .pi * beat)) * m * amount
            p.scaleY = 1 - 0.08 * (1 - abs(sin(2 * .pi * beat))) * m * amount
            p.leftArm = (0.5 - 0.45 * sin(2 * .pi * beat)) * amount
            p.rightArm = (0.5 + 0.45 * sin(2 * .pi * beat)) * amount
            p.reach = 0
            p.eyes = .happy
            p.mouth = .grin
            p.antennaGlow = 0.6 + 0.4 * abs(sin(2 * .pi * beat))
            p.laptop.screen = .celebrate
            p.laptop.scroll = t
            p.effects = PetPoseEvaluator.notes(t + 0.4, x: 0.5, y: 1.15, reduced: context.reducedMotion)

        case .presentCode:
            p.held = .codeCard
            p.leftArm = 0.7 * Ease.outBack(Ease.segment(t, 0, 0.35))
            p.eyes = .happy
            p.mouth = .smile
            p.lookX = -0.5
            p.reach = 0

        case .highFive:
            p.leftArm = Keys.value(t, [(0, 0.3), (0.2, 1.0), (d, 1.0)])
            p.y += 0.16 * Ease.hop(Ease.segment(t, 0.05, 0.45)) * m
            p.scaleY = 1 - 0.12 * Ease.bump(t, 0.4, 0.6) * m
            p.eyes = .happy
            p.mouth = .grin
            p.reach = 0

        case .catchBall:
            let catchPose = Ease.bump(t, 0.1, 0.7)
            p.leftArm = 0.7 * catchPose
            p.rightArm = 0.7 * catchPose + 0.5 * Ease.bump(t, 0.7, 1.1)
            p.eyes = t < 0.35 ? .wide : .happy
            p.antennaBend = 0.25 * sin(t * 18) * Ease.bump(t, 0, 0.5) * m

        case .doubleTake:
            p.eyes = t > 0.25 && t < 1.0 ? .wide : .normal
            p.lookX = Keys.value(t, [(0, 0), (0.2, -0.75), (0.45, 0.2), (0.65, -0.8), (1.4, -0.6)])
            p.y += 0.13 * Ease.bump(t, 0.25, 0.45) * m
            p.effects = [Effect(.exclamation, x: 0.45, y: 1.32, scale: Ease.outBack(Ease.segment(t, 0.25, 0.45)), opacity: Ease.bump(t, 0.25, 1.2))]

        case .rpsShake:
            let shakes = abs(sin(.pi * t / 0.5))
            p.leftArm = 0.35 + 0.3 * shakes
            p.reach = 0
            p.eyes = .focused
            p.lookX = -0.5
            p.y += 0.015 * shakes * m

        case .pat:
            p.leftArm = 0.55 + 0.1 * sin(t * 10) * Ease.bump(t, 0.2, 1.4) * max(m, 0.3)
            p.eyes = .happy
            p.mouth = .smile
            p.lookX = -0.6
            p.lookY = 0.2
            p.effects = PetPoseEvaluator.hearts(t - 0.4, x: -0.5, y: 0.9, count: 1, reduced: context.reducedMotion)
        }
        return p
    }

    static func basePose(_ context: PoseContext) -> CompanionPose {
        var p = CompanionPose()
        let g = context.time
        let m = context.motion
        let phase = Ease.hash(2, context.seed) * 6.28
        p.y = 0.03 * sin(2 * .pi * g / 2.8 + phase) * m
        p.eyeOpenness = Ease.blink(g, seed: context.seed, period: 5.1)
        // Discrete glances: hold a direction, then move smoothly to the next.
        let period = 6.0
        let cycle = Int(floor(g / period))
        let local = g - Double(cycle) * period
        let from = (Ease.hash(cycle - 1, context.seed) - 0.5) * 0.8
        let to = (Ease.hash(cycle, context.seed) - 0.5) * 0.8
        p.lookX = Ease.lerp(from, to, Ease.smooth(Ease.segment(local, 0, 0.35)))
        p.antennaGlow = 0.35 + 0.08 * sin(g * 1.7)
        p.antennaBend = 0.06 * sin(g * 1.3) * m
        p.reach = 0.3
        p.laptop.scroll = g
        p.shadow = 1
        return p
    }

    static func thinkingDots(_ g: Double, reduced: Bool) -> Effect {
        Effect(.thinkingDots, x: 0.5, y: 1.35, scale: 1, opacity: 1, rotation: 0, variant: reduced ? 3 : Int(Ease.fract(g / 1.2) * 4))
    }

    static func steam(_ g: Double, x: Double, y: Double, reduced: Bool) -> Effect {
        Effect(.steam, x: x, y: y, scale: 1, opacity: 0.8, rotation: reduced ? 0 : g, variant: 0)
    }
}
