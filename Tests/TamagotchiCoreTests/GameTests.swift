import Foundation
import Testing
@testable import TamagotchiCore

@Suite("Catch the Treats")
struct CatchGameTests {
    /// A game with no automatic treats, so each test places its own.
    func quietGame(seed: UInt64 = 7) -> CatchGame {
        var game = CatchGame(seed: seed)
        game.autoSpawn = false
        return game
    }

    /// Steps until `condition` holds (or a limit), collecting events.
    @discardableResult
    func run(_ game: inout CatchGame, input: CatchGame.Input = .init(), seconds: Double, dt: Double = 1.0 / 60,
             until condition: (CatchGame) -> Bool = { _ in false }) -> [CatchGame.Event] {
        var events: [CatchGame.Event] = []
        var elapsed = 0.0
        while elapsed < seconds, !condition(game) {
            events += game.step(dt: dt, input: input)
            elapsed += dt
        }
        return events
    }

    @Test func catchingScoresAndCountsTheCombo() {
        var game = quietGame()
        game.drop(.cookie, at: 0.5, y: 0.6)
        let events = run(&game, seconds: 5) { $0.caught == 1 }
        #expect(events == [.caught(.cookie, points: 1, combo: 1)])
        #expect(game.score == 1)
        #expect(game.combo == 1)
        #expect(game.treats.isEmpty)
        #expect(game.splashes.first?.points == 1)
        #expect(game.reaction?.kind == .munch)
    }

    @Test func comboMultiplierGrowsEveryFiveCatches() {
        #expect(CatchGame.multiplier(combo: 1) == 1)
        #expect(CatchGame.multiplier(combo: 5) == 1)
        #expect(CatchGame.multiplier(combo: 6) == 2)
        #expect(CatchGame.multiplier(combo: 11) == 3)
        #expect(CatchGame.multiplier(combo: 40) == 4)
        var game = quietGame()
        for _ in 0..<6 {
            game.drop(.fish, at: 0.5, y: 0.5)
            run(&game, seconds: 5) { $0.treats.isEmpty }
        }
        #expect(game.combo == 6)
        #expect(game.score == 5 + 2)
        #expect(game.bestCombo == 6)
    }

    @Test func goldenTreatsAreABonusAndFreeToMiss() {
        var game = quietGame()
        game.drop(.golden, at: 0.5, y: 0.5)
        run(&game, seconds: 5) { $0.treats.isEmpty }
        #expect(game.score == 5)
        #expect(game.reaction?.kind == .golden)
        game.drop(.golden, at: 0.95, y: 0.5)
        let events = run(&game, seconds: 5) { $0.treats.isEmpty }
        #expect(events == [.missed(.golden)])
        #expect(game.misses == 0)
        #expect(game.combo == 1)
    }

    @Test func aTreatOnTheFloorResetsTheCombo() {
        var game = quietGame()
        game.drop(.berry, at: 0.5, y: 0.5)
        run(&game, seconds: 5) { $0.treats.isEmpty }
        game.drop(.berry, at: 0.95, y: 0.5)
        let events = run(&game, seconds: 5) { $0.treats.isEmpty }
        #expect(events == [.missed(.berry)])
        #expect(game.combo == 0)
        #expect(game.misses == 1)
        #expect(game.reaction?.kind == .oops)
        #expect(game.score == 1)
    }

    @Test func threeMissesEndTheGameOnce() {
        var game = quietGame()
        for x in [0.05, 0.95, 0.9] { game.drop(.cookie, at: x, y: 0.3) }
        let events = run(&game, seconds: 5) { $0.phase == .over }
        #expect(events.filter { if case .missed = $0 { return true } else { return false } }.count == 3)
        #expect(events.last == .gameOver(score: 0))
        #expect(game.phase == .over)
        let frozen = game
        let after = game.step(dt: 0.1, input: .init(direction: 1))
        #expect(after.isEmpty)
        #expect(game == frozen)
    }

    @Test func aLongStepCannotCarryATreatThroughMochi() {
        var game = quietGame()
        game.drop(.cookie, at: 0.5, y: 0.3, speed: 2.5)
        let events = game.step(dt: 0.1, input: .init())
        #expect(events == [.caught(.cookie, points: 1, combo: 1)])
    }

    @Test func speedRampsUpOverTime() {
        #expect(CatchGame.fallSpeed(level: 5) > CatchGame.fallSpeed(level: 1) * 1.5)
        #expect(CatchGame.spawnInterval(level: 8) < CatchGame.spawnInterval(level: 1) * 0.5)
        var game = quietGame()
        let events = run(&game, seconds: 70, dt: 0.1)
        let levels = events.compactMap { event -> Int? in
            if case .faster(let level) = event { return level }
            return nil
        }
        #expect(levels == [2, 3, 4])
        #expect(game.level == 4)
        game.drop(.cookie, at: 0.2)
        #expect(game.treats.last!.speed == CatchGame.fallSpeed(level: 4))
    }

    @Test func theSameSeedAndInputsPlayTheSameGame() {
        func play(seed: UInt64) -> CatchGame {
            var game = CatchGame(seed: seed)
            for _ in 0..<(60 * 40) {
                // A simple player: chase the lowest treat.
                let target = game.treats.min { $0.y < $1.y }?.x
                game.step(dt: 1.0 / 60, input: .init(targetX: target))
            }
            return game
        }
        let a = play(seed: 99)
        let b = play(seed: 99)
        #expect(a == b)
        #expect(a.caught > 10)
        let c = play(seed: 100)
        #expect(a.treats.map(\.x) != c.treats.map(\.x) || a.score != c.score)
    }

    @Test func mochiFollowsKeysAndThePointerWithinTheField() {
        var game = quietGame()
        run(&game, input: .init(direction: 1), seconds: 0.4)
        #expect(game.petX > 0.6)
        #expect(game.facing == 1)
        run(&game, input: .init(direction: -1), seconds: 3)
        #expect(game.petX == CatchGame.petRange.lowerBound)
        #expect(game.facing == -1)
        run(&game, input: .init(targetX: 0.3), seconds: 2)
        #expect(abs(game.petX - 0.3) < 0.01)
        run(&game, input: .init(targetX: 2), seconds: 2)
        #expect(game.petX <= CatchGame.petRange.upperBound)
    }

    @Test func mochiFacesTheWayItRunsAndMunchesOnACatch() {
        var game = quietGame()
        run(&game, input: .init(direction: -1), seconds: 0.3)
        let context = PoseContext(time: 10)
        #expect(game.petPose(context: context).facing == -1)
        run(&game, input: .init(direction: 1), seconds: 0.5)
        #expect(game.petPose(context: context).facing == 1)
        game.drop(.cookie, at: game.petX, y: 0.3)
        run(&game, seconds: 1) { $0.caught == 1 }
        let pose = game.petPose(context: context)
        #expect(pose.cheekLeft > 0 || pose.mouth == .nom || pose.mouth == .tiny)
        #expect(pose.x == 0)
    }
}

@Suite("Rock, paper, scissors")
struct RPSGameTests {
    @Test func everyPairingIsSymmetric() {
        for a in RPSChoice.allCases {
            for b in RPSChoice.allCases {
                #expect(a.outcome(against: b) == -b.outcome(against: a))
            }
        }
        #expect(RPSChoice.rock.outcome(against: .scissors) == 1)
        #expect(RPSChoice.paper.outcome(against: .scissors) == -1)
    }

    @Test func youPlayEachCharacterSeparately() {
        let mixed = RPSRound(player: .rock, pet: .scissors, companion: .paper)
        #expect(mixed.vsPet == 1)
        #expect(mixed.vsCompanion == -1)
        #expect(mixed.duels == [1, -1])
        #expect(!mixed.isWin && !mixed.isLoss)
        let sweep = RPSRound(player: .paper, pet: .rock, companion: .paper)
        #expect(sweep.isWin)
        let solo = RPSRound(player: .scissors, pet: .rock, companion: nil)
        #expect(solo.duels == [-1])
        #expect(solo.isLoss)
    }

    @Test func aMatchKeepsScoreAndStreaks() {
        var match = RPSMatch(seed: 1, withCompanion: true)
        match.play(RPSRound(player: .rock, pet: .scissors, companion: .rock))
        match.play(RPSRound(player: .paper, pet: .rock, companion: .rock))
        #expect(match.streak == 2)
        #expect(match.vsPet == RPSTally(wins: 2))
        #expect(match.vsCompanion.wins == 1 && match.vsCompanion.draws == 1)
        match.play(RPSRound(player: .paper, pet: .scissors, companion: .rock))
        #expect(match.streak == 0)
        #expect(match.rounds.count == 3)
    }

    @Test func picksAreSeededAndRespectTheLineUp() {
        var a = RPSMatch(seed: 5, withCompanion: true)
        var b = RPSMatch(seed: 5, withCompanion: true)
        let picksA = (0..<20).map { _ in a.nextPicks() }
        let picksB = (0..<20).map { _ in b.nextPicks() }
        #expect(picksA.map(\.pet) == picksB.map(\.pet))
        #expect(picksA.map(\.companion) == picksB.map(\.companion))
        #expect(Set(picksA.map(\.pet)).count == 3)
        var solo = RPSMatch(seed: 5, withCompanion: false)
        let round = solo.play(.rock)
        #expect(round.companion == nil)
    }

    @Test func recordsCountEveryDuelAndTheBestStreak() {
        var records = GameRecords()
        #expect(records.recordRPS(RPSRound(player: .rock, pet: .scissors, companion: .paper), streak: 0) == false)
        #expect(records.rpsWins == 1 && records.rpsLosses == 1 && records.rpsDraws == 0)
        #expect(records.recordRPS(RPSRound(player: .rock, pet: .rock, companion: nil), streak: 0) == false)
        #expect(records.rpsDraws == 1)
        let newStreak = records.recordRPS(RPSRound(player: .rock, pet: .scissors, companion: nil), streak: 3)
        #expect(newStreak)
        #expect(records.rpsBestStreak == 3)
        let highScore = records.recordCatch(score: 12, bestCombo: 4)
        let notHigher = records.recordCatch(score: 8, bestCombo: 9)
        #expect(highScore && !notHigher)
        #expect(records.catchHighScore == 12 && records.catchGamesPlayed == 2 && records.catchBestCombo == 9)
    }

    @Test func keysMapToChoices() {
        #expect(RPSChoice(key: "R") == .rock)
        #expect(RPSChoice(key: "2") == .paper)
        #expect(RPSChoice(key: "s") == .scissors)
        #expect(RPSChoice(key: "x") == nil)
    }

    @Test func olderSettingsKeepTheirRecords() {
        let data = Data(#"{"games": {"catchHighScore": 31, "rpsWins": 4}, "focus": {"workMinutes": 50}}"#.utf8)
        let settings = AppSettings.decodeTolerantly(data)
        #expect(settings.games.catchHighScore == 31)
        #expect(settings.games.rpsWins == 4)
        #expect(settings.games.rpsBestStreak == 0)
        #expect(settings.focus.workMinutes == 50)
        #expect(settings.focus.breakMinutes == 5)
        #expect(settings.recap == RecapSettings())
    }
}

extension RPSTally {
    init(wins: Int = 0, losses: Int = 0, draws: Int = 0) {
        self.init()
        self.wins = wins
        self.losses = losses
        self.draws = draws
    }
}
