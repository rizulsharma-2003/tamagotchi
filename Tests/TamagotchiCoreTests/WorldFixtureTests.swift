import Foundation
import Testing
@testable import TamagotchiCore

/// The golden fixtures in `link-spec/world` (see `WorldFixtures`): each test regenerates one from the Swift engine and
/// requires the committed file to match it exactly.
@Suite("World fixtures")
@MainActor
struct WorldFixtureTests {
    @Test("link-spec/world/poses-pet.json: Mochi's poses")
    func petPoses() throws { try WorldFixtures.check("poses-pet.json", PoseFixtures.pet()) }

    @Test("link-spec/world/poses-companion.json: Patch's poses")
    func companionPoses() throws { try WorldFixtures.check("poses-companion.json", PoseFixtures.companion()) }

    @Test("link-spec/world/interactions.json: the interaction scripts' frames")
    func interactionFrames() throws { try WorldFixtures.check("interactions.json", PoseFixtures.interactions()) }

    @Test("link-spec/world/scheduler.json: ambient picks, cooldowns, daily caps and no repeats")
    func scheduler() throws { try WorldFixtures.check("scheduler.json", LogicFixtures.scheduler()) }

    @Test("link-spec/world/progress.json: friendship, achievements and growing up")
    func progress() throws { try WorldFixtures.check("progress.json", LogicFixtures.progress()) }

    @Test("link-spec/world/celebrations.json: celebrations from real Claude events (G2)")
    func celebrations() throws { try WorldFixtures.check("celebrations.json", LogicFixtures.celebrations()) }

    @Test("link-spec/world/world.json: whole CompanionWorld timelines")
    func worldTimelines() throws { try WorldFixtures.check("world.json", WorldTimelineFixtures.world()) }

    @Test("link-spec/world/speech.json: lines, picks, pacing and clean-up (W11)")
    func speech() throws { try WorldFixtures.check("speech.json", FeatureFixtures.speech()) }

    @Test("link-spec/world/games.json: Catch the Treats and rock-paper-scissors (W14)")
    func games() throws { try WorldFixtures.check("games.json", FeatureFixtures.games()) }

    @Test("link-spec/world/focus.json: the focus timer and log (W15)")
    func focus() throws { try WorldFixtures.check("focus.json", FeatureFixtures.focus()) }

    @Test("link-spec/world/recap.json: the daily recap (W16)")
    func recap() throws { try WorldFixtures.check("recap.json", FeatureFixtures.recap()) }

    @Test("link-spec/world/room.json: furniture, unlocks and placement (W18)")
    func room() throws { try WorldFixtures.check("room.json", FeatureFixtures.room()) }

    @Test("link-spec/world/seasons.json: holidays by date (W20)")
    func seasons() throws { try WorldFixtures.check("seasons.json", FeatureFixtures.seasons()) }
}
