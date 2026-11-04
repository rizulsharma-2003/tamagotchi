import Foundation

/// Small, fast, seedable PRNG so ambient behaviour is reproducible in tests.
public struct SplitMix64: Sendable, Equatable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    public mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }
}

public enum AmbientActivity: String, Sendable {
    /// No Claude turn in progress.
    case idle
    /// A Claude turn is in progress (cosmetic interactions only, never claims about the work).
    case working
    /// Claude is waiting for the user: never distract from that.
    case waiting
}

public struct InteractionDefinition: Sendable {
    public enum Rarity: String, Sendable { case common, uncommon, rare }

    public var id: InteractionID
    public var weight: Double
    public var cooldown: TimeInterval
    public var dailyCap: Int
    public var rarity: Rarity
    public var activities: Set<AmbientActivity>
    /// Required time since the last real activity or user interaction.
    public var minimumIdle: TimeInterval

    public static let ambient: [InteractionDefinition] = [
        .init(id: .coffeeDelivery, weight: 3, cooldown: 25 * 60, dailyCap: 6, rarity: .common, activities: [.idle, .working], minimumIdle: 0),
        .init(id: .showCode, weight: 2.5, cooldown: 18 * 60, dailyCap: 6, rarity: .common, activities: [.working, .idle], minimumIdle: 0),
        .init(id: .ballDistraction, weight: 2, cooldown: 15 * 60, dailyCap: 6, rarity: .common, activities: [.idle, .working], minimumIdle: 30),
        .init(id: .rockPaperScissors, weight: 2, cooldown: 20 * 60, dailyCap: 5, rarity: .common, activities: [.idle], minimumIdle: 60),
        .init(id: .sleepWatch, weight: 1.4, cooldown: 50 * 60, dailyCap: 3, rarity: .uncommon, activities: [.idle], minimumIdle: 4 * 60),
        .init(id: .chairSteal, weight: 0.35, cooldown: 3 * 3600, dailyCap: 1, rarity: .rare, activities: [.idle], minimumIdle: 90),
        .init(id: .keyboardNap, weight: 0.35, cooldown: 3 * 3600, dailyCap: 1, rarity: .rare, activities: [.idle], minimumIdle: 3 * 60),
        .init(id: .mysteryOrb, weight: 0.3, cooldown: 4 * 3600, dailyCap: 1, rarity: .rare, activities: [.idle], minimumIdle: 60),
    ]
}

public struct SchedulerContext: Sendable {
    public var companionPresent: Bool
    public var activity: AmbientActivity
    /// Seconds since the last real Claude event or user interaction.
    public var idleSeconds: TimeInterval
    public var charactersBusy: Bool
    public var paused: Bool
    public var reducedMotion: Bool
    public var intensity: AnimationIntensity
    public var petAsleep: Bool

    public init(companionPresent: Bool, activity: AmbientActivity, idleSeconds: TimeInterval, charactersBusy: Bool = false,
                paused: Bool = false, reducedMotion: Bool = false, intensity: AnimationIntensity = .normal, petAsleep: Bool = false) {
        self.companionPresent = companionPresent
        self.activity = activity
        self.idleSeconds = idleSeconds
        self.charactersBusy = charactersBusy
        self.paused = paused
        self.reducedMotion = reducedMotion
        self.intensity = intensity
        self.petAsleep = petAsleep
    }
}

/// Decides when the characters do something on their own.
///
/// - A global gap between interactions (scaled by animation intensity) keeps them rare.
/// - Each interaction has its own cooldown and daily cap; the last two are never repeated.
/// - Real events push ambient behaviour back so it never competes with a reaction.
/// - Nothing ambient happens while Claude is waiting for the user, or when paused.
public struct InteractionScheduler: Sendable {
    public static let baseInteractionGap: TimeInterval = 150
    public static let baseSoloGap: TimeInterval = 40

    public private(set) var rng: SplitMix64
    public private(set) var nextInteractionAt: TimeInterval
    public private(set) var nextSoloAt: TimeInterval
    public private(set) var lastStarted: [InteractionID: TimeInterval] = [:]
    public private(set) var recent: [InteractionID] = []
    public private(set) var dailyCounts: [InteractionID: Int] = [:]
    public private(set) var countsDay = -1
    public let definitions: [InteractionDefinition]

    public init(seed: UInt64, now: TimeInterval, definitions: [InteractionDefinition] = InteractionDefinition.ambient) {
        self.rng = SplitMix64(seed: seed)
        self.definitions = definitions
        self.nextInteractionAt = now + 45
        self.nextSoloAt = now + 12
    }

    /// Pushes ambient behaviour back after a real event or user interaction.
    public mutating func postpone(now: TimeInterval, by seconds: TimeInterval = 30) {
        nextInteractionAt = max(nextInteractionAt, now + seconds)
        nextSoloAt = max(nextSoloAt, now + min(seconds, 20))
    }

    /// Records an interaction that was triggered by an event, so it counts towards gaps.
    public mutating func noteTriggered(_ id: InteractionID, now: TimeInterval) {
        lastStarted[id] = now
        remember(id)
        nextInteractionAt = max(nextInteractionAt, now + 60)
    }

    public func gap(_ base: TimeInterval, context: SchedulerContext) -> TimeInterval {
        base * context.intensity.gapMultiplier * (context.reducedMotion ? 1.5 : 1)
    }

    /// Returns an ambient interaction to start now, if one is due and eligible.
    public mutating func nextInteraction(now: TimeInterval, day: Int, context: SchedulerContext) -> (InteractionID, Int)? {
        guard !context.paused, context.activity != .waiting, context.companionPresent, !context.charactersBusy, !context.petAsleep else {
            return nil
        }
        guard now >= nextInteractionAt else { return nil }
        if day != countsDay {
            countsDay = day
            dailyCounts = [:]
        }
        let eligible = definitions.filter { definition in
            guard definition.activities.contains(context.activity) else { return false }
            guard context.idleSeconds >= definition.minimumIdle else { return false }
            if let last = lastStarted[definition.id], now - last < definition.cooldown { return false }
            if (dailyCounts[definition.id] ?? 0) >= definition.dailyCap { return false }
            if recent.suffix(2).contains(definition.id) { return false }
            return true
        }
        let jitter = rng.next(in: 0.7...1.3)
        nextInteractionAt = now + gap(InteractionScheduler.baseInteractionGap, context: context) * jitter
        guard let chosen = weightedPick(eligible) else { return nil }
        lastStarted[chosen.id] = now
        dailyCounts[chosen.id, default: 0] += 1
        remember(chosen.id)
        let variant = Int(rng.next() % 1_000)
        return (chosen.id, variant)
    }

    /// Returns a small solo behaviour for the pet, if one is due.
    public mutating func nextSolo(now: TimeInterval, context: SchedulerContext) -> PetAnimation? {
        guard !context.paused, !context.charactersBusy, !context.petAsleep, now >= nextSoloAt else { return nil }
        nextSoloAt = now + gap(InteractionScheduler.baseSoloGap, context: context) * rng.next(in: 0.7...1.6)
        var options: [(PetAnimation, Double)] = [
            (.lookAround, 4), (.blep, 1.2), (.sniff, 1.0), (.stretch, 0.8), (.scratch, 0.8), (.shake, 0.5),
        ]
        if context.activity == .idle {
            // Happy bounces only when nothing is going on: during a turn one could read as Claude's success.
            options += [(.happyBounce, 0.9), (.roll, 0.7), (.dance, 0.35), (.play, 0.9), (.tumble, 0.5), (.pounce, 0.5)]
            if context.idleSeconds > 180 { options.append((.yawn, 0.8)) }
        }
        if context.reducedMotion {
            // Expressions only: nothing that jumps, spins or travels.
            let moving: Set<PetAnimation> = [.roll, .dance, .play, .tumble, .pounce]
            options.removeAll { moving.contains($0.0) }
        }
        if context.activity == .waiting {
            // Only quiet glances while Claude waits for the user.
            options = [(.lookAround, 1)]
        }
        let total = options.reduce(0) { $0 + $1.1 }
        var roll = rng.nextUnit() * total
        for (animation, weight) in options {
            roll -= weight
            if roll <= 0 { return animation }
        }
        return options.last?.0
    }

    private mutating func weightedPick(_ candidates: [InteractionDefinition]) -> InteractionDefinition? {
        let total = candidates.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var roll = rng.nextUnit() * total
        for candidate in candidates {
            roll -= candidate.weight
            if roll <= 0 { return candidate }
        }
        return candidates.last
    }

    private mutating func remember(_ id: InteractionID) {
        recent.append(id)
        if recent.count > 4 { recent.removeFirst() }
    }
}
