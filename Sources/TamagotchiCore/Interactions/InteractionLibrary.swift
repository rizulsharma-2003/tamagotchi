import Foundation

public enum InteractionID: String, Codable, Sendable, CaseIterable, Identifiable {
    // Ambient (scheduled)
    case coffeeDelivery, showCode, ballDistraction, rockPaperScissors, sleepWatch
    case chairSteal, keyboardNap, mysteryOrb
    // Triggered by real events or by the user
    case welcome, highFive, victoryDance, trophyCelebration, caseClosed, detectiveHat, graduation, syncDance

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .coffeeDelivery: return "Coffee delivery"
        case .showCode: return "Show and tell"
        case .ballDistraction: return "Ball distraction"
        case .rockPaperScissors: return "Rock, paper, scissors"
        case .sleepWatch: return "Keeping watch"
        case .chairSteal: return "Chair thief"
        case .keyboardNap: return "Keyboard nap"
        case .mysteryOrb: return "The mysterious glow"
        case .welcome: return "Welcome"
        case .highFive: return "High five"
        case .victoryDance: return "Victory dance"
        case .trophyCelebration: return "Tiny trophy"
        case .caseClosed: return "Case closed"
        case .detectiveHat: return "Detective mode"
        case .graduation: return "Graduation"
        case .syncDance: return "Synchronized dance"
        }
    }
}

/// A prop that belongs to the scene rather than to one character.
public struct SceneProp: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case ball, orb, clap, confetti, sparkle
        case butterfly, yarn, leaf, dust, bubble, treat, crumb
    }

    public var kind: Kind
    /// 0 = the pet's home position, 1 = the companion's.
    public var x: Double
    /// Height above the floor in pet body heights.
    public var y: Double
    public var scale: Double
    public var opacity: Double
    public var rotation: Double
    public var variant: Int

    public init(_ kind: Kind, x: Double, y: Double, scale: Double = 1, opacity: Double = 1, rotation: Double = 0, variant: Int = 0) {
        self.kind = kind
        self.x = x
        self.y = y
        self.scale = scale
        self.opacity = opacity
        self.rotation = rotation
        self.variant = variant
    }
}

/// A running interaction.
public struct InteractionPlayback: Equatable, Sendable {
    public var id: InteractionID
    public var startedAt: TimeInterval
    public var variant: Int
    /// What the companion was doing when it started; `.scripted` beats return to it.
    public var companionLoop: CompanionAnimation
    public var petToken: Int?
    public var companionToken: Int?
    /// Project label when the interaction celebrates a specific session.
    public var sessionLabel: String?

    public init(id: InteractionID, startedAt: TimeInterval, variant: Int, companionLoop: CompanionAnimation, sessionLabel: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.variant = variant
        self.companionLoop = companionLoop
        self.sessionLabel = sessionLabel
    }

    public var duration: TimeInterval { InteractionLibrary.script(id, variant: variant).duration }

    public func isFinished(at now: TimeInterval) -> Bool { now - startedAt >= duration }
}

public struct InteractionScript: Sendable {
    public struct PetBeat: Sendable {
        public var start: Double
        public var end: Double
        public var animation: PetAnimation
        public var from: Double
        public var to: Double
        public var held: HeldItem?
        public var hat: HeldItem?
        public var facing: Double
        /// Height above the floor (e.g. sitting on the desk), in body heights.
        public var lift: (Double, Double)
    }

    public struct CompanionBeat: Sendable {
        public var start: Double
        public var end: Double
        /// `.scripted` means "whatever the companion was doing when the interaction began".
        public var animation: CompanionAnimation
        public var from: Double
        public var to: Double
        public var held: HeldItem?
    }

    public var id: InteractionID
    public var duration: Double
    public var pet: [PetBeat]
    public var companion: [CompanionBeat]
    public var requiresCompanion: Bool
}

public struct InteractionFrame: Sendable {
    public var pet: PetPose
    public var companion: CompanionPose
    public var props: [SceneProp]
}

public enum RPSChoice: Int, Sendable, CaseIterable {
    case rock, paper, scissors

    public var item: HeldItem {
        switch self {
        case .rock: return .rock
        case .paper: return .paper
        case .scissors: return .scissors
        }
    }

    /// 1 if self beats other, -1 if it loses, 0 for a tie.
    public func outcome(against other: RPSChoice) -> Int {
        if self == other { return 0 }
        switch (self, other) {
        case (.rock, .scissors), (.paper, .rock), (.scissors, .paper): return 1
        default: return -1
        }
    }
}

public enum InteractionLibrary {
    /// Where the pet stands to interact with the companion (fraction of the path).
    public static let meet = 0.6

    private static func pet(_ start: Double, _ end: Double, _ animation: PetAnimation, at x: Double = 0, to: Double? = nil,
                            held: HeldItem? = nil, hat: HeldItem? = nil, facing: Double = 1, lift: (Double, Double) = (0, 0)) -> InteractionScript.PetBeat {
        InteractionScript.PetBeat(start: start, end: end, animation: animation, from: x, to: to ?? x, held: held, hat: hat, facing: facing, lift: lift)
    }

    private static func comp(_ start: Double, _ end: Double, _ animation: CompanionAnimation, at x: Double = 0, to: Double? = nil,
                             held: HeldItem? = nil) -> InteractionScript.CompanionBeat {
        InteractionScript.CompanionBeat(start: start, end: end, animation: animation, from: x, to: to ?? x, held: held)
    }

    public static func rpsChoices(variant: Int) -> (pet: RPSChoice, companion: RPSChoice) {
        let v = abs(variant)
        return (RPSChoice(rawValue: v % 3)!, RPSChoice(rawValue: (v / 3) % 3)!)
    }

    public static func script(_ id: InteractionID, variant: Int = 0) -> InteractionScript {
        let m = meet
        switch id {
        case .coffeeDelivery:
            return InteractionScript(id: id, duration: 8.0, pet: [
                pet(0, 0.6, .idle, held: .coffee),
                pet(0.6, 2.6, .carry, at: 0, to: m, held: .coffee),
                pet(2.6, 3.6, .offer, at: m, held: .coffee),
                pet(3.6, 5.0, .happyBounce, at: m),
                pet(5.0, 7.4, .walk, at: m, to: 0, facing: -1),
                pet(7.4, 8.0, .idle),
            ], companion: [
                comp(0, 2.6, .scripted),
                comp(2.6, 3.6, .greet),
                comp(3.6, 6.2, .sip, held: .coffee),
                comp(6.2, 8.0, .scripted),
            ], requiresCompanion: true)

        case .showCode:
            let delighted = variant % 2 == 1
            return InteractionScript(id: id, duration: 6.6, pet: [
                pet(0, 0.8, .watch),
                pet(0.8, 2.2, .walk, at: 0, to: 0.5),
                pet(2.2, 4.0, delighted ? .excitedJump : .confusedTilt, at: 0.5),
                pet(4.0, 6.0, .walk, at: 0.5, to: 0, facing: -1),
                pet(6.0, 6.6, .idle),
            ], companion: [
                comp(0, 0.8, .scripted),
                comp(0.8, 4.2, .presentCode),
                comp(4.2, 6.6, .scripted),
            ], requiresCompanion: true)

        case .ballDistraction:
            return InteractionScript(id: id, duration: 6.4, pet: [
                pet(0, 0.8, .blep, held: .ball),
                pet(0.8, 1.2, .offer, held: .ball),
                pet(1.2, 1.5, .offer),
                pet(1.5, 4.3, .watch),
                pet(4.3, 5.3, .happyBounce, held: .ball),
                pet(5.3, 6.4, .idle),
            ], companion: [
                comp(0, 2.0, .scripted),
                comp(2.0, 3.4, .catchBall),
                comp(3.4, 6.4, .scripted),
            ], requiresCompanion: true)

        case .rockPaperScissors:
            let choices = rpsChoices(variant: variant)
            let outcome = choices.pet.outcome(against: choices.companion)
            return InteractionScript(id: id, duration: 5.8, pet: [
                pet(0, 0.4, .idle),
                pet(0.4, 1.9, .rpsShake),
                pet(1.9, 3.4, .watch, held: choices.pet.item),
                pet(3.4, 4.8, outcome > 0 ? .happyBounce : (outcome < 0 ? .concerned : .blep), held: choices.pet.item),
                pet(4.8, 5.8, .idle),
            ], companion: [
                comp(0, 0.4, .idleAtDesk),
                comp(0.4, 1.9, .rpsShake),
                comp(1.9, 3.4, .idleAtDesk, held: choices.companion.item),
                comp(3.4, 4.8, outcome < 0 ? .nod : (outcome > 0 ? .doubleTake : .greet), held: choices.companion.item),
                comp(4.8, 5.8, .scripted),
            ], requiresCompanion: true)

        case .sleepWatch:
            if variant % 2 == 0 {
                return InteractionScript(id: id, duration: 24, pet: [
                    pet(0, 1.8, .yawn),
                    pet(1.8, 22, .sleep),
                    pet(22, 23.2, .wakeUp),
                    pet(23.2, 24, .idle),
                ], companion: [
                    comp(0, 24, .rest),
                ], requiresCompanion: true)
            }
            return InteractionScript(id: id, duration: 24, pet: [
                pet(0, 24, .watch),
            ], companion: [
                comp(0, 2, .stretch),
                comp(2, 22, .sleep),
                comp(22, 23.2, .wakeUp),
                comp(23.2, 24, .idleAtDesk),
            ], requiresCompanion: true)

        case .chairSteal:
            return InteractionScript(id: id, duration: 7.6, pet: [
                pet(0, 1.6, .watch),
                pet(1.6, 3.0, .walk, at: 0, to: 1.0),
                pet(3.0, 5.6, .sit, at: 1.0, lift: (0.18, 0.18)),
                pet(5.6, 7.0, .walk, at: 1.0, to: 0, facing: -1),
                pet(7.0, 7.6, .idle),
            ], companion: [
                comp(0, 1.2, .stretch),
                comp(1.2, 2.2, .idleAtDesk, at: 0, to: 0.45),
                comp(2.2, 4.2, .sip, at: 0.45, held: .coffee),
                comp(4.2, 5.0, .idleAtDesk, at: 0.45, held: .coffee),
                comp(5.0, 6.4, .doubleTake, at: 0.45, held: .coffee),
                comp(6.4, 7.6, .idleAtDesk, at: 0.45, to: 0, held: .coffee),
            ], requiresCompanion: true)

        case .keyboardNap:
            return InteractionScript(id: id, duration: 14, pet: [
                pet(0, 2.0, .walk, at: 0, to: 0.8),
                pet(2.0, 2.6, .happyBounce, at: 0.8, lift: (0, 0.42)),
                pet(2.6, 11, .curl, at: 0.8, lift: (0.42, 0.42)),
                pet(11, 12.2, .wakeUp, at: 0.8, lift: (0.42, 0.42)),
                pet(12.2, 12.8, .happyBounce, at: 0.8, lift: (0.42, 0)),
                pet(12.8, 14, .walk, at: 0.8, to: 0, facing: -1),
            ], companion: [
                comp(0, 2.6, .scripted),
                comp(2.6, 4.0, .doubleTake),
                comp(4.0, 5.6, .pat),
                comp(5.6, 11.6, .rest),
                comp(11.6, 14, .scripted),
            ], requiresCompanion: true)

        case .mysteryOrb:
            return InteractionScript(id: id, duration: 8, pet: [
                pet(0, 1.0, .watch),
                pet(1.0, 3.6, .lookAround),
                pet(3.6, 5.4, .confusedTilt),
                pet(5.4, 6.6, .watch),
                pet(6.6, 7.6, .happyBounce),
                pet(7.6, 8, .idle),
            ], companion: [
                comp(0, 1.4, .scripted),
                comp(1.4, 5.4, .searching),
                comp(5.4, 6.6, .doubleTake),
                comp(6.6, 8, .greet),
            ], requiresCompanion: true)

        case .welcome:
            return InteractionScript(id: id, duration: 3.6, pet: [
                pet(0, 0.6, .watch),
                pet(0.6, 2.4, .greet),
                pet(2.4, 3.4, .happyBounce),
                pet(3.4, 3.6, .watch),
            ], companion: [
                comp(0, 1.8, .arrive),
                comp(1.8, 3.6, .setup),
            ], requiresCompanion: true)

        case .highFive:
            return InteractionScript(id: id, duration: 4.0, pet: [
                pet(0, 1.0, .walk, at: 0, to: m),
                pet(1.0, 1.7, .highFive, at: m),
                pet(1.7, 2.7, .happyBounce, at: m),
                pet(2.7, 3.6, .walk, at: m, to: 0, facing: -1),
                pet(3.6, 4.0, .idle),
            ], companion: [
                comp(0, 1.0, .greet),
                comp(1.0, 1.7, .highFive),
                comp(1.7, 4.0, .celebrate),
            ], requiresCompanion: true)

        case .victoryDance:
            return InteractionScript(id: id, duration: 5.6, pet: [
                pet(0, 1.0, .walk, at: 0, to: 0.4),
                pet(1.0, 4.2, .dance, at: 0.4),
                pet(4.2, 5.2, .walk, at: 0.4, to: 0, facing: -1),
                pet(5.2, 5.6, .idle),
            ], companion: [
                comp(0, 1.0, .greet),
                comp(1.0, 4.2, .dance),
                comp(4.2, 5.6, .idleAtDesk),
            ], requiresCompanion: true)

        case .trophyCelebration:
            return InteractionScript(id: id, duration: 4.2, pet: [
                pet(0, 0.3, .watch),
                pet(0.3, 1.7, .excitedJump),
                pet(1.7, 2.7, .happyBounce),
                pet(2.7, 4.2, .idle),
            ], companion: [
                comp(0, 2.8, .trophy),
                comp(2.8, 4.2, .idleAtDesk),
            ], requiresCompanion: true)

        case .caseClosed:
            return InteractionScript(id: id, duration: 4.8, pet: [
                pet(0, 1.2, .walk, at: 0, to: m),
                pet(1.2, 2.0, .watch, at: m),
                pet(2.0, 2.7, .highFive, at: m),
                pet(2.7, 3.7, .happyBounce, at: m),
                pet(3.7, 4.6, .walk, at: m, to: 0, facing: -1),
                pet(4.6, 4.8, .idle),
            ], companion: [
                comp(0, 1.2, .detective),
                comp(1.2, 2.0, .greet, held: .detectiveHat),
                comp(2.0, 2.7, .highFive),
                comp(2.7, 4.8, .celebrate),
            ], requiresCompanion: true)

        case .detectiveHat:
            return InteractionScript(id: id, duration: 2.8, pet: [
                pet(0, 1.8, .confusedTilt),
                pet(1.8, 2.8, .watch),
            ], companion: [
                comp(0, 2.8, .detective),
            ], requiresCompanion: true)

        case .graduation:
            return InteractionScript(id: id, duration: 5.4, pet: [
                pet(0, 1.0, .walk, at: 0, to: m),
                pet(1.0, 2.4, .watch, at: m),
                pet(2.4, 4.4, .victory, at: m, hat: .gradCap),
                pet(4.4, 5.4, .walk, at: m, to: 0, hat: .gradCap, facing: -1),
            ], companion: [
                comp(0, 1.0, .greet),
                comp(1.0, 2.4, .presentCode, held: .gradCap),
                comp(2.4, 5.4, .celebrate),
            ], requiresCompanion: true)

        case .syncDance:
            return InteractionScript(id: id, duration: 6.4, pet: [
                pet(0, 0.4, .watch),
                pet(0.4, 3.6, .dance),
                pet(3.6, 5.2, .roll),
                pet(5.2, 6.4, .victory),
            ], companion: [
                comp(0, 0.4, .greet),
                comp(0.4, 3.6, .dance),
                comp(3.6, 6.0, .celebrate),
                comp(6.0, 6.4, .idleAtDesk),
            ], requiresCompanion: true)
        }
    }

    /// Evaluates both characters and scene props at `elapsed` seconds into the interaction.
    public static func frame(
        _ playback: InteractionPlayback,
        elapsed: Double,
        petContext: PoseContext,
        companionContext: PoseContext,
        detail: CompanionDetail = CompanionDetail()
    ) -> InteractionFrame {
        let script = script(playback.id, variant: playback.variant)
        let t = min(max(0, elapsed), script.duration)
        let motion = petContext.motion > 0 ? 1.0 : 0.0

        let petBeat = script.pet.last { $0.start <= t } ?? script.pet[0]
        let petLocal = t - petBeat.start
        var petPose = PetPoseEvaluator.pose(petBeat.animation, elapsed: petLocal, duration: petBeat.end - petBeat.start, context: petContext)
        let petProgress = Ease.smooth(Ease.segment(t, petBeat.start, petBeat.end))
        // Walking is translation; with Reduced Motion the pet interacts from home.
        petPose.x += Ease.lerp(petBeat.from, petBeat.to, petProgress) * motion
        petPose.y += Ease.lerp(petBeat.lift.0, petBeat.lift.1, petProgress) * motion
        petPose.facing = petBeat.facing
        if petBeat.facing < 0 { petPose.lookX = -abs(petPose.lookX) }
        if let held = petBeat.held { petPose.held = held }
        if let hat = petBeat.hat { petPose.hat = hat }

        let compBeat = script.companion.last { $0.start <= t } ?? script.companion[0]
        let compAnimation = compBeat.animation == .scripted ? playback.companionLoop : compBeat.animation
        let compLocal = t - compBeat.start
        var compPose = CompanionPoseEvaluator.pose(compAnimation, elapsed: compLocal, duration: compBeat.end - compBeat.start,
                                                   context: companionContext, detail: detail)
        let compProgress = Ease.smooth(Ease.segment(t, compBeat.start, compBeat.end))
        compPose.x += Ease.lerp(compBeat.from, compBeat.to, compProgress) * motion
        if let held = compBeat.held { compPose.held = held }

        return InteractionFrame(pet: petPose, companion: compPose, props: props(playback.id, t: t, variant: playback.variant, reduced: motion == 0))
    }

    static func props(_ id: InteractionID, t: Double, variant: Int, reduced: Bool) -> [SceneProp] {
        switch id {
        case .ballDistraction:
            if t >= 1.2, t < 2.1 {
                let p = Ease.segment(t, 1.2, 2.1)
                return [SceneProp(.ball, x: Ease.lerp(0.12, 0.9, p), y: 0.55 + 0.75 * Ease.hop(p), rotation: t * 8)]
            }
            if t >= 2.1, t < 3.4 {
                return [SceneProp(.ball, x: 0.9, y: 1.05 + 0.04 * sin(t * 10), rotation: t * 2)]
            }
            if t >= 3.4, t < 4.3 {
                let p = Ease.segment(t, 3.4, 4.3)
                return [SceneProp(.ball, x: Ease.lerp(0.9, 0.12, p), y: Ease.lerp(1.05, 0.55, p) + 0.6 * Ease.hop(p), rotation: -t * 8)]
            }
            return []
        case .highFive, .caseClosed:
            let clapAt = id == .highFive ? 1.15 : 2.15
            let life = Ease.bump(t, clapAt, clapAt + 0.6)
            guard life > 0 else { return [] }
            return [SceneProp(.clap, x: 0.83, y: 1.35, scale: 0.6 + 0.6 * life, opacity: life)]
        case .victoryDance, .syncDance, .graduation:
            let bursts = id == .graduation ? [2.4] : [1.0, 2.6]
            return bursts.flatMap { start -> [SceneProp] in
                let local = t - start
                guard local > 0, local < 2.2 else { return [] }
                return (0..<10).map { index in
                    let seed = UInt64(index &* 31 &+ Int(start * 10))
                    let x = 0.15 + 0.7 * Ease.hash(index, seed)
                    let fallSpeed = 0.5 + 0.4 * Ease.hash(index + 3, seed)
                    let y = reduced ? 1.6 + 0.2 * Ease.hash(index + 7, seed) : 2.2 - local * fallSpeed
                    return SceneProp(.confetti, x: x + (reduced ? 0 : 0.04 * sin(local * 5 + Double(index))), y: y,
                                     scale: 0.8, opacity: 1 - Ease.segment(local, 1.6, 2.2), rotation: local * 6 + Double(index), variant: index % 4)
                }
            }
        case .trophyCelebration:
            return (0..<4).map { index in
                let local = t - 0.4 - Double(index) * 0.35
                let life = Ease.bump(local, 0, 0.8)
                return SceneProp(.sparkle, x: 0.75 + 0.12 * Double(index % 2) * (index > 1 ? -1 : 1), y: 1.55 + 0.15 * Double(index % 3),
                                 scale: 0.5 + 0.5 * life, opacity: life, rotation: t * 2)
            }
        case .mysteryOrb:
            let x: Double
            let y: Double
            var opacity = 1.0
            if t < 2.5 {
                let p = Ease.smooth(Ease.segment(t, 0, 2.5))
                x = Ease.lerp(-0.25, 0.5, p)
                y = 1.6 + 0.15 * sin(t * 3)
                opacity = Ease.segment(t, 0, 0.6)
            } else if t < 5.5 {
                let local = t - 2.5
                x = 0.5 + 0.15 * sin(local * 2.2)
                y = 1.55 + 0.12 * cos(local * 2.2)
            } else {
                let p = Ease.smooth(Ease.segment(t, 5.5, 6.6))
                x = 0.5 + 0.4 * p
                y = 1.55 + 1.6 * p
                opacity = 1 - p
            }
            return [SceneProp(.orb, x: x, y: y, scale: 1, opacity: opacity, rotation: t)]
        default:
            return []
        }
    }
}
