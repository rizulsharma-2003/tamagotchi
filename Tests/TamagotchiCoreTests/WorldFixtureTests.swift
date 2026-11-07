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
}
