import Foundation

/// Interrupt priority. A new one-shot may replace the current one only if its
/// priority is at least as high; lower-priority requests are dropped, never queued,
/// so stale reactions can never pile up and play late.
public enum AnimationPriority: Int, Comparable, Codable, Sendable {
    case base = 0
    case ambient = 1
    case interaction = 2
    case reaction = 3
    case user = 4
    case attention = 5
    case critical = 6

    public static func < (lhs: AnimationPriority, rhs: AnimationPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public protocol CharacterAnimationKind: Hashable, Sendable {
    /// Loops are base states (idle, working, sleeping…); everything else is a one-shot.
    var isLoop: Bool { get }
    var defaultDuration: TimeInterval { get }
    /// Minimum time before the same one-shot may start again.
    var cooldown: TimeInterval { get }
    static var scripted: Self { get }
}

/// Character A: the user's pet.
public enum PetAnimation: String, Codable, Sendable, CaseIterable, CharacterAnimationKind {
    // Loops
    case idle, sleep, watch, waveGently
    // One-shots
    case lookAround, happyBounce, excitedJump, roll, dance, confusedTilt, concerned, victory
    case greet, petted, play, leanForward, nod, blep, yawn, treat, wakeUp, wave
    // Building blocks used inside interaction scripts
    case walk, carry, offer, highFive, sit, rpsShake, curl
    // Locomotion and play building blocks (also used by roaming activities)
    case run, pounce, bat, tumble, sniff, stretch, scratch, shake, leapCatch
    /// Driven by an `InteractionScript`.
    case scripted

    public var isLoop: Bool {
        switch self {
        case .idle, .sleep, .watch, .waveGently, .walk, .carry, .sit, .curl, .run: return true
        default: return false
        }
    }

    public var defaultDuration: TimeInterval {
        switch self {
        case .lookAround: return 2.6
        case .happyBounce: return 1.0
        case .excitedJump: return 1.4
        case .roll: return 1.6
        case .dance: return 3.2
        case .confusedTilt: return 1.8
        case .concerned: return 2.4
        case .victory: return 2.4
        case .greet: return 1.8
        case .petted: return 3.2
        case .play: return 5.0
        case .leanForward: return 1.4
        case .nod: return 0.8
        case .blep: return 1.4
        case .yawn: return 1.8
        case .treat: return 4.4
        case .wakeUp: return 1.2
        case .wave: return 1.8
        case .offer: return 1.0
        case .highFive: return 0.7
        case .rpsShake: return 1.5
        case .pounce: return 1.3
        case .bat: return 0.6
        case .tumble: return 1.3
        case .sniff: return 1.8
        case .stretch: return 2.6
        case .scratch: return 2.0
        case .shake: return 1.1
        case .leapCatch: return 1.1
        default: return 1.0
        }
    }

    public var cooldown: TimeInterval {
        switch self {
        case .nod: return 12
        case .leanForward: return 6
        case .lookAround: return 20
        case .dance, .roll: return 60
        // Ambient play stories are special; the user's Play button ignores this.
        case .play: return 90
        case .blep: return 45
        case .yawn: return 60
        default: return 0
        }
    }

    public var title: String {
        switch self {
        case .waveGently: return "Gentle wave"
        case .lookAround: return "Look around"
        case .happyBounce: return "Happy bounce"
        case .excitedJump: return "Excited jump"
        case .confusedTilt: return "Confused tilt"
        case .leanForward: return "Lean forward"
        case .wakeUp: return "Wake up"
        case .highFive: return "High five"
        case .rpsShake: return "Rock-paper-scissors"
        case .leapCatch: return "Leap and catch"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// Character B: the AI coding companion.
public enum CompanionAnimation: String, Codable, Sendable, CaseIterable, CharacterAnimationKind {
    // Loops
    case absent, idleAtDesk, thinking, typing, reading, searching, runningCommand, browsing, delegating
    case waiting, detective, rest, sleep, offline
    // One-shots
    case arrive, setup, readTaskCard, concerned, celebrate, trophy, packUp, depart, greet, nod
    case wakeUp, stretch, sip, dance, presentCode, highFive, catchBall, doubleTake, pat, rpsShake
    case scripted

    public var isLoop: Bool {
        switch self {
        case .absent, .idleAtDesk, .thinking, .typing, .reading, .searching, .runningCommand, .browsing,
             .delegating, .waiting, .detective, .rest, .sleep, .offline:
            return true
        default:
            return false
        }
    }

    public var defaultDuration: TimeInterval {
        switch self {
        case .arrive: return 1.8
        case .setup: return 1.8
        case .readTaskCard: return 2.0
        case .concerned: return 2.6
        case .celebrate: return 2.4
        case .trophy: return 2.8
        case .packUp: return 2.0
        case .depart: return 1.4
        case .greet: return 1.6
        case .nod: return 0.9
        case .wakeUp: return 1.2
        case .stretch: return 2.0
        case .sip: return 2.0
        case .dance: return 3.2
        case .presentCode: return 2.4
        case .highFive: return 0.7
        case .catchBall: return 1.2
        case .doubleTake: return 1.4
        case .pat: return 1.6
        case .rpsShake: return 1.5
        default: return 1.0
        }
    }

    public var cooldown: TimeInterval {
        switch self {
        case .nod: return 10
        case .readTaskCard: return 3
        case .concerned: return 4
        default: return 0
        }
    }

    /// True for loops that show the workstation in use.
    public var isWorking: Bool {
        switch self {
        case .thinking, .typing, .reading, .searching, .runningCommand, .browsing, .delegating, .detective: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .idleAtDesk: return "Idle at desk"
        case .runningCommand: return "Watching a command"
        case .readTaskCard: return "Reading task card"
        case .packUp: return "Packing up"
        case .wakeUp: return "Waking up"
        case .presentCode: return "Showing code"
        case .highFive: return "High five"
        case .catchBall: return "Catching"
        case .doubleTake: return "Double take"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}
