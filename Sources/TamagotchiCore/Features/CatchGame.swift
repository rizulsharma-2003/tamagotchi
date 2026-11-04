import Foundation

/// "Catch the Treats": treats fall from the top and Mochi runs along the floor to catch them.
///
/// A pure, deterministic simulation in a unit field (x 0…1 left to right, y 0 at the floor
/// … 1 at the top). The app steps it once per frame with the player's input; the same seed
/// and inputs always play out the same way. Three treats on the floor end the game (golden
/// bonus treats never count against you). It speeds up every `levelDuration` seconds.
public struct CatchGame: Sendable, Equatable {
    public enum TreatKind: String, Sendable, CaseIterable {
        case cookie, fish, berry
        /// A golden bonus cookie: worth more, and letting it go costs nothing.
        case golden

        public var points: Int { self == .golden ? 5 : 1 }
    }

    public struct Treat: Sendable, Equatable, Identifiable {
        public var id: Int
        public var kind: TreatKind
        public var x: Double
        public var y: Double
        /// Fall speed in field heights per second.
        public var speed: Double
        /// Spin in radians per second (drawing only).
        public var spin: Double
        public var age = 0.0

        public var rotation: Double { spin * age }
    }

    public enum Phase: Sendable, Equatable { case playing, over }

    /// What happened during a step, for sounds and reactions.
    public enum Event: Sendable, Equatable {
        case caught(TreatKind, points: Int, combo: Int)
        case missed(TreatKind)
        case faster(level: Int)
        case gameOver(score: Int)
    }

    /// A short-lived marker where a treat was caught or landed (pops and "+3" labels).
    public struct Splash: Sendable, Equatable {
        public var kind: TreatKind
        public var x: Double
        public var y: Double
        /// Points scored; 0 for a treat that landed on the floor.
        public var points: Int
        public var at: Double
    }

    /// Mochi's latest reaction, for the pose.
    public struct Reaction: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case munch, golden, oops }
        public var kind: Kind
        public var at: Double
    }

    public struct Input: Sendable, Equatable {
        /// -1 left, 0 still, 1 right (arrow keys / A-D).
        public var direction: Double
        /// Where the pointer is while dragging, in field units; wins over the keys.
        public var targetX: Double?

        public init(direction: Double = 0, targetX: Double? = nil) {
            self.direction = direction
            self.targetX = targetX
        }
    }

    // Tuning (field units and seconds).
    public static let maxMisses = 3
    /// Treats are caught between the floor and this height (Mochi's head).
    public static let catchHeight = 0.22
    /// Treats touch the floor at this height.
    public static let floorY = 0.04
    /// Half the width of Mochi's catch zone.
    public static let catchRadius = 0.085
    public static let petRange = 0.06...0.94
    /// Running speed with the keys, field widths per second.
    public static let runSpeed = 0.95
    /// Fastest speed while following the pointer.
    public static let dragSpeed = 1.9
    /// Seconds per speed level.
    public static let levelDuration = 20.0
    public static let maxLevel = 8
    public static let splashLife = 0.9

    public private(set) var phase: Phase = .playing
    /// Game time in seconds (only advances while playing).
    public private(set) var time = 0.0
    public private(set) var score = 0
    /// Catches in a row since the last treat on the floor.
    public private(set) var combo = 0
    public private(set) var bestCombo = 0
    public private(set) var caught = 0
    public private(set) var misses = 0
    public private(set) var level = 1
    public private(set) var petX = 0.5
    /// Field widths per second (positive = right).
    public private(set) var petVelocity = 0.0
    public private(set) var facing = 1.0
    public private(set) var treats: [Treat] = []
    public private(set) var splashes: [Splash] = []
    public private(set) var reaction: Reaction?
    /// Drop treats automatically (tests place them by hand instead).
    public var autoSpawn = true
    private var rng: SplitMix64
    private var nextSpawnAt = 0.8
    private var nextID = 1
    private var lastWasGolden = false

    public init(seed: UInt64) {
        rng = SplitMix64(seed: seed ^ 0x4341_5443_485F_4D45)
    }

    // MARK: Difficulty

    /// Combo multiplier: ×1 for the first five catches in a row, ×2 from the sixth, … up to ×4.
    public static func multiplier(combo: Int) -> Int { min(4, 1 + max(0, combo - 1) / 5) }

    /// Base fall speed (field heights per second) at a level.
    public static func fallSpeed(level: Int) -> Double { 0.27 * (1 + 0.14 * Double(level - 1)) }

    /// Mean seconds between treats at a level.
    public static func spawnInterval(level: Int) -> Double { 1.3 * pow(0.87, Double(level - 1)) }

    // MARK: Simulation

    /// Advances the game by `dt` seconds (at most 0.1 s per step). Returns what happened, in order.
    @discardableResult
    public mutating func step(dt rawDT: Double, input: Input) -> [Event] {
        guard phase == .playing, rawDT > 0 else { return [] }
        let dt = min(rawDT, 0.1)
        var events: [Event] = []
        time += dt

        let newLevel = min(Self.maxLevel, 1 + Int(time / Self.levelDuration))
        if newLevel > level {
            level = newLevel
            events.append(.faster(level: level))
        }

        movePet(dt: dt, input: input)

        if autoSpawn {
            while time >= nextSpawnAt {
                spawn()
                nextSpawnAt += Self.spawnInterval(level: level) * rng.next(in: 0.75...1.25)
            }
        }

        var remaining: [Treat] = []
        for var treat in treats {
            let oldY = treat.y
            treat.y -= treat.speed * dt
            treat.age += dt
            // Swept test, so a long step can't carry a treat through Mochi.
            let throughCatchZone = treat.y <= Self.catchHeight && oldY >= Self.floorY
            if throughCatchZone, abs(treat.x - petX) <= Self.catchRadius {
                combo += 1
                bestCombo = max(bestCombo, combo)
                caught += 1
                let points = treat.kind.points * Self.multiplier(combo: combo)
                score += points
                splashes.append(Splash(kind: treat.kind, x: treat.x, y: max(treat.y, Self.floorY + 0.1), points: points, at: time))
                reaction = Reaction(kind: treat.kind == .golden ? .golden : .munch, at: time)
                events.append(.caught(treat.kind, points: points, combo: combo))
            } else if treat.y <= Self.floorY {
                splashes.append(Splash(kind: treat.kind, x: treat.x, y: Self.floorY, points: 0, at: time))
                events.append(.missed(treat.kind))
                if treat.kind != .golden {
                    combo = 0
                    misses += 1
                    reaction = Reaction(kind: .oops, at: time)
                }
            } else {
                remaining.append(treat)
            }
        }
        treats = remaining
        splashes.removeAll { time - $0.at > Self.splashLife }

        if misses >= Self.maxMisses {
            phase = .over
            petVelocity = 0
            events.append(.gameOver(score: score))
        }
        return events
    }

    /// Drops a treat now. The spawner uses it; tests place treats by hand.
    public mutating func drop(_ kind: TreatKind, at x: Double, y: Double = 1.04, speed: Double? = nil) {
        let fall = speed ?? Self.fallSpeed(level: level) * (kind == .golden ? 1.15 : 1)
        treats.append(Treat(id: nextID, kind: kind, x: min(max(x, 0.04), 0.96), y: y, speed: fall, spin: 0))
        nextID += 1
    }

    private mutating func spawn() {
        let kind: TreatKind
        if !lastWasGolden, time > 6, rng.nextUnit() < 0.08 {
            kind = .golden
        } else {
            let pick = rng.nextUnit()
            kind = pick < 0.42 ? .cookie : (pick < 0.72 ? .fish : .berry)
        }
        lastWasGolden = kind == .golden
        // Keep a new treat out of the previous one's column, so two never stack exactly.
        var x = rng.next(in: 0.07...0.93)
        if let last = treats.last, abs(last.x - x) < 0.08 { x = x > 0.5 ? x - 0.16 : x + 0.16 }
        let fall = Self.fallSpeed(level: level) * rng.next(in: 0.88...1.12) * (kind == .golden ? 1.15 : 1)
        treats.append(Treat(id: nextID, kind: kind, x: x, y: 1.04, speed: fall, spin: rng.next(in: -3...3)))
        nextID += 1
    }

    private mutating func movePet(dt: Double, input: Input) {
        let desired: Double
        // Keys accelerate gently; the pointer is followed briskly without overshooting.
        let response: Double
        if let target = input.targetX {
            let clamped = min(max(target, Self.petRange.lowerBound), Self.petRange.upperBound)
            desired = min(max((clamped - petX) * 12, -Self.dragSpeed), Self.dragSpeed)
            response = 30
        } else {
            desired = max(-1, min(1, input.direction)) * Self.runSpeed
            response = 14
        }
        petVelocity += (desired - petVelocity) * min(1, dt * response)
        if desired == 0, abs(petVelocity) < 0.002 { petVelocity = 0 }
        petX += petVelocity * dt
        if !Self.petRange.contains(petX) {
            petX = min(max(petX, Self.petRange.lowerBound), Self.petRange.upperBound)
            petVelocity = 0
        }
        if abs(petVelocity) > 0.05 { facing = petVelocity > 0 ? 1 : -1 }
    }
}

// MARK: - Mochi's pose

extension CatchGame {
    /// Seconds each reaction shows on Mochi.
    static func reactionLength(_ kind: Reaction.Kind) -> Double {
        switch kind {
        case .munch: return 0.8
        case .golden: return 1.1
        case .oops: return 1.2
        }
    }

    /// Mochi in the game right now: walking or running with the movement (facing the way it
    /// goes), a happy hop and a munch for a catch, a little "oops" for a treat on the floor,
    /// and eyes on the lowest treat while standing still. `x` is left at 0: the host places Mochi.
    public func petPose(context: PoseContext) -> PetPose {
        let speed = abs(petVelocity)
        let loop: PetAnimation = phase == .over ? .sit : (speed > 0.45 ? .run : (speed > 0.06 ? .walk : .idle))
        var context = context
        context.returnLoop = loop
        var pose: PetPose
        if phase == .playing, let reaction, time - reaction.at < Self.reactionLength(reaction.kind) {
            let t = time - reaction.at
            switch reaction.kind {
            case .munch:
                pose = PetPoseEvaluator.pose(.happyBounce, elapsed: t, duration: Self.reactionLength(.munch), context: context)
                Self.munch(&pose, t: t)
            case .golden:
                pose = PetPoseEvaluator.pose(.excitedJump, elapsed: t, duration: Self.reactionLength(.golden), context: context)
                pose.eyeSparkle = max(pose.eyeSparkle, 0.8)
                if t > 0.5 { Self.munch(&pose, t: t - 0.5) }
            case .oops:
                pose = PetPoseEvaluator.pose(.concerned, elapsed: t, duration: Self.reactionLength(.oops), context: context)
            }
        } else {
            pose = PetPoseEvaluator.pose(loop, elapsed: 0, context: context)
            if phase == .over {
                pose.eyes = .happy
                pose.mouth = .smile
                pose.lookX = 0
            } else if loop == .idle, let next = treats.min(by: { $0.y < $1.y }) {
                // Watching the next treat come down (screen space, before turning around).
                pose.lookX = max(-1, min(1, (next.x - petX) * 4)) * facing
                pose.lookY = -0.25 - 0.45 * min(1, next.y)
                pose.earPerk = max(pose.earPerk, 0.4)
            }
        }
        pose.x = 0
        return facing < 0 ? pose.mirrored() : pose
    }

    /// Chewing: the mouth works and the cheeks puff for half a second.
    static func munch(_ pose: inout PetPose, t: Double) {
        guard t >= 0, t < 0.55 else { return }
        pose.mouth = Int(t / 0.09) % 2 == 0 ? .nom : .tiny
        let puff = 0.55 * Ease.bump(t, 0, 0.55)
        pose.cheekLeft = max(pose.cheekLeft, puff)
        pose.cheekRight = max(pose.cheekRight, puff)
        pose.eyes = .happy
        pose.blush = max(pose.blush, 0.7)
    }
}
