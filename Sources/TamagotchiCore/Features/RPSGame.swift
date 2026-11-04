import Foundation

/// One round of rock-paper-scissors: you play Mochi and (when it joins) the companion
/// at the same time. Each pairing with you is a separate duel.
public struct RPSRound: Sendable, Equatable {
    public var player: RPSChoice
    public var pet: RPSChoice
    public var companion: RPSChoice?

    public init(player: RPSChoice, pet: RPSChoice, companion: RPSChoice?) {
        self.player = player
        self.pet = pet
        self.companion = companion
    }

    /// Your result against Mochi: 1 won, -1 lost, 0 draw.
    public var vsPet: Int { player.outcome(against: pet) }

    /// Your result against the companion, if it played.
    public var vsCompanion: Int? { companion.map { player.outcome(against: $0) } }

    /// Your duels in order (Mochi first).
    public var duels: [Int] { [vsPet] + (vsCompanion.map { [$0] } ?? []) }

    /// Won at least one duel and lost none.
    public var isWin: Bool { duels.contains(1) && !duels.contains(-1) }

    /// Lost at least one duel and won none.
    public var isLoss: Bool { duels.contains(-1) && !duels.contains(1) }
}

/// Running totals of one side's duels.
public struct RPSTally: Sendable, Equatable {
    public var wins = 0
    public var losses = 0
    public var draws = 0

    public init() {}

    public mutating func record(_ outcome: Int) {
        switch outcome {
        case 1: wins += 1
        case -1: losses += 1
        default: draws += 1
        }
    }

    public var played: Int { wins + losses + draws }
}

/// A sitting of rock-paper-scissors. The characters choose with a seeded generator, so a
/// match is reproducible; they never peek at your choice.
public struct RPSMatch: Sendable, Equatable {
    public let withCompanion: Bool
    public private(set) var vsPet = RPSTally()
    public private(set) var vsCompanion = RPSTally()
    public private(set) var rounds: [RPSRound] = []
    /// Rounds won in a row (see `RPSRound.isWin`).
    public private(set) var streak = 0
    private var rng: SplitMix64

    public init(seed: UInt64, withCompanion: Bool) {
        self.withCompanion = withCompanion
        rng = SplitMix64(seed: seed ^ 0x5250_535F_4D41_5443)
    }

    /// The characters' picks for the next round, decided before they know yours.
    public mutating func nextPicks() -> (pet: RPSChoice, companion: RPSChoice?) {
        let pet = RPSChoice(rawValue: Int(rng.next() % 3))!
        let companion = RPSChoice(rawValue: Int(rng.next() % 3))!
        return (pet, withCompanion ? companion : nil)
    }

    /// Plays a round against fresh picks.
    @discardableResult
    public mutating func play(_ choice: RPSChoice) -> RPSRound {
        let picks = nextPicks()
        return play(RPSRound(player: choice, pet: picks.pet, companion: picks.companion))
    }

    /// Scores a round whose picks are already known.
    @discardableResult
    public mutating func play(_ round: RPSRound) -> RPSRound {
        vsPet.record(round.vsPet)
        if let outcome = round.vsCompanion { vsCompanion.record(outcome) }
        rounds.append(round)
        if rounds.count > 50 { rounds.removeFirst(rounds.count - 50) }
        streak = round.isWin ? streak + 1 : 0
        return round
    }
}

extension RPSChoice {
    public var title: String {
        switch self {
        case .rock: return "Rock"
        case .paper: return "Paper"
        case .scissors: return "Scissors"
        }
    }

    public var emoji: String {
        switch self {
        case .rock: return "✊"
        case .paper: return "✋"
        case .scissors: return "✌️"
        }
    }

    /// Keyboard shortcuts: R/P/S or 1/2/3.
    public init?(key: String) {
        switch key.lowercased() {
        case "r", "1": self = .rock
        case "p", "2": self = .paper
        case "s", "3": self = .scissors
        default: return nil
        }
    }
}
