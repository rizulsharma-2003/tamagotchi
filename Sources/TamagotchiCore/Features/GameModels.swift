import Foundation

/// Local mini-game records.
public struct GameRecords: Codable, Sendable, Equatable {
    public var catchHighScore = 0
    public var catchGamesPlayed = 0
    public var catchBestCombo = 0
    public var rpsWins = 0
    public var rpsLosses = 0
    public var rpsDraws = 0
    /// Most rounds in a row won (at least one duel won, none lost).
    public var rpsBestStreak = 0
    public init() {}

    /// Missing keys keep their defaults, so adding a record never resets the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catchHighScore = try c.decodeIfPresent(Int.self, forKey: .catchHighScore) ?? 0
        catchGamesPlayed = try c.decodeIfPresent(Int.self, forKey: .catchGamesPlayed) ?? 0
        catchBestCombo = try c.decodeIfPresent(Int.self, forKey: .catchBestCombo) ?? 0
        rpsWins = try c.decodeIfPresent(Int.self, forKey: .rpsWins) ?? 0
        rpsLosses = try c.decodeIfPresent(Int.self, forKey: .rpsLosses) ?? 0
        rpsDraws = try c.decodeIfPresent(Int.self, forKey: .rpsDraws) ?? 0
        rpsBestStreak = try c.decodeIfPresent(Int.self, forKey: .rpsBestStreak) ?? 0
    }

    /// Records a finished game of Catch the Treats. Returns true for a new high score.
    @discardableResult
    public mutating func recordCatch(score: Int, bestCombo combo: Int) -> Bool {
        catchGamesPlayed += 1
        catchBestCombo = max(catchBestCombo, combo)
        guard score > catchHighScore else { return false }
        catchHighScore = score
        return true
    }

    /// Adds one rock-paper-scissors round: you against each opponent is one duel.
    /// Returns true when `streak` (rounds won in a row) beats the best streak.
    @discardableResult
    public mutating func recordRPS(_ round: RPSRound, streak: Int) -> Bool {
        for outcome in round.duels {
            switch outcome {
            case 1: rpsWins += 1
            case -1: rpsLosses += 1
            default: rpsDraws += 1
            }
        }
        guard streak > rpsBestStreak else { return false }
        rpsBestStreak = streak
        return true
    }
}
