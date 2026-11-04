import Foundation
@testable import TamagotchiCore
import TamagotchiWire

enum TestSupport {
    static func temporaryDirectory(_ name: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactamagotchi-tests", isDirectory: true)
            .appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A hook-shaped wire event, as the helper would produce it.
    static func wire(
        _ event: String,
        session: String? = "s1",
        project: String = "/Users/test/InsideEdge",
        tool: String? = nil,
        toolUseId: String? = nil,
        at date: Date = Date(),
        id: String? = nil,
        origin: WireOrigin = .hook,
        configure: (inout WireEvent) -> Void = { _ in }
    ) -> WireEvent {
        var wire = WireEvent(id: id ?? UUID().uuidString.lowercased(), ts: date.timeIntervalSince1970, origin: origin, event: event, session: session)
        wire.project = ProjectIdentity.displayName(forPath: project)
        wire.projectKey = ProjectIdentity.key(forPath: project)
        wire.projectPath = project
        if let tool {
            wire.tool = tool
            wire.toolCategory = ToolCategoryClassifier.category(forTool: tool)
            wire.toolUseId = toolUseId ?? "toolu_\(UUID().uuidString.prefix(8))"
        }
        configure(&wire)
        return wire
    }

    static func event(_ event: String, session: String? = "s1", project: String = "/Users/test/InsideEdge", tool: String? = nil,
                      toolUseId: String? = nil, at date: Date = Date(), delivery: EventDelivery = .live,
                      configure: (inout WireEvent) -> Void = { _ in }) -> CompanionEvent {
        EventNormalizer.normalize(wire(event, session: session, project: project, tool: tool, toolUseId: toolUseId, at: date, configure: configure),
                                  receivedAt: date, delivery: delivery)
    }
}

/// A controllable clock for world scenarios.
@MainActor
final class TestClock {
    var date: Date
    var uptime: TimeInterval

    init(date: Date = Date(timeIntervalSince1970: 1_800_000_000), uptime: TimeInterval = 1_000) {
        self.date = date
        self.uptime = uptime
    }

    func advance(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
        uptime += seconds
    }
}

@MainActor
final class RecordingEffects: WorldEffects {
    var sounds: [SoundCue] = []
    var banners: [(BannerContent, NotificationCategory)] = []

    func play(_ sound: SoundCue) { sounds.append(sound) }

    func postBanner(_ content: BannerContent, category: NotificationCategory, sessionID: String?) {
        banners.append((content, category))
    }
}

@MainActor
struct WorldHarness {
    let clock: TestClock
    let world: CompanionWorld
    let journal: EventJournal
    let effects: RecordingEffects
    let directory: URL

    init(settings: AppSettings = AppSettings(), name: String = #function) {
        directory = TestSupport.temporaryDirectory(name)
        clock = TestClock()
        journal = EventJournal(fileURL: directory.appendingPathComponent("history.jsonl"), retention: .init(days: 7))
        let achievements = AchievementEngine(fileURL: directory.appendingPathComponent("progress.json"))
        let store = SettingsStore(fileURL: nil, initial: settings)
        let clock = self.clock
        world = CompanionWorld(journal: journal, achievements: achievements, settingsStore: store, seed: 42,
                               clock: { clock.date }, uptime: { clock.uptime })
        effects = RecordingEffects()
        world.effects = effects
    }

    /// Sends an event "now" and lets a little time pass.
    func send(_ event: String, session: String = "s1", project: String = "/Users/test/InsideEdge", tool: String? = nil,
              toolUseId: String? = nil, after: TimeInterval = 0.5, configure: (inout WireEvent) -> Void = { _ in }) {
        clock.advance(after)
        world.ingest(TestSupport.wire(event, session: session, project: project, tool: tool, toolUseId: toolUseId, at: clock.date, configure: configure))
        world.tick()
    }

    func run(for seconds: TimeInterval, step: TimeInterval = 0.25) {
        var elapsed = 0.0
        while elapsed < seconds {
            clock.advance(step)
            world.tick()
            elapsed += step
        }
    }
}
