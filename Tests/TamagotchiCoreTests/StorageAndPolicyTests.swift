import Foundation
import Testing
@testable import TamagotchiCore
import TamagotchiWire

@Suite("Event journal")
@MainActor
struct JournalTests {
    @Test func refusesSimulatedEvents() {
        let directory = TestSupport.temporaryDirectory()
        let journal = EventJournal(fileURL: directory.appendingPathComponent("h.jsonl"), retention: .init(days: 7))
        var event = TestSupport.event("Stop")
        event.origin = .simulator
        #expect(journal.append(event) == false)
        #expect(journal.all.isEmpty)
    }

    @Test func ignoresDuplicatesAndPersists() {
        let directory = TestSupport.temporaryDirectory()
        let url = directory.appendingPathComponent("h.jsonl")
        let journal = EventJournal(fileURL: url, retention: .init(days: 7))
        let event = TestSupport.event("Stop")
        #expect(journal.append(event))
        #expect(journal.append(event) == false)
        let reloaded = EventJournal(fileURL: url, retention: .init(days: 7))
        reloaded.load()
        #expect(reloaded.all.map(\.id) == [event.id])
    }

    @Test func stripsFullPathsUnlessOptedIn() throws {
        let directory = TestSupport.temporaryDirectory()
        let url = directory.appendingPathComponent("h.jsonl")
        let journal = EventJournal(fileURL: url, retention: .init(days: 7))
        journal.append(TestSupport.event("Stop", project: "/Users/me/secret-client/app"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("/Users/me"))
        #expect(text.contains("\"displayName\":\"app\""))
    }

    @Test func enforcesRetentionByAgeAndCount() {
        let directory = TestSupport.temporaryDirectory()
        let url = directory.appendingPathComponent("h.jsonl")
        let journal = EventJournal(fileURL: url, retention: .init(days: 1, maxEvents: 5))
        let now = Date()
        journal.append(TestSupport.event("Stop", at: now.addingTimeInterval(-3 * 86_400)), now: now)
        for index in 0..<8 { journal.append(TestSupport.event("Stop", at: now.addingTimeInterval(Double(index))), now: now) }
        journal.enforceRetention(now: now)
        #expect(journal.all.count == 5)
        #expect(journal.all.allSatisfy { $0.timestamp >= now.addingTimeInterval(-86_400) })
        let reloaded = EventJournal(fileURL: url, retention: .init(days: 1, maxEvents: 5))
        reloaded.load(now: now)
        #expect(reloaded.all.count == 5)
    }

    @Test func zeroRetentionKeepsNothingOnDisk() {
        let directory = TestSupport.temporaryDirectory()
        let url = directory.appendingPathComponent("h.jsonl")
        let journal = EventJournal(fileURL: url, retention: .init(days: 0))
        journal.append(TestSupport.event("Stop"))
        journal.enforceRetention()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func ignoresCorruptLines() throws {
        let directory = TestSupport.temporaryDirectory()
        let url = directory.appendingPathComponent("h.jsonl")
        let journal = EventJournal(fileURL: url, retention: .init(days: 7))
        journal.append(TestSupport.event("Stop"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage\n{\"half\":\n".utf8))
        try handle.close()
        let reloaded = EventJournal(fileURL: url, retention: .init(days: 7))
        reloaded.load()
        #expect(reloaded.all.count == 1)
    }
}

@Suite("Settings")
@MainActor
struct SettingsTests {
    @Test func persistsAndReloads() async throws {
        let directory = TestSupport.temporaryDirectory()
        let url = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: url)
        store.settings.petName = "Biscuit"
        store.settings.quietHours = QuietHours(enabled: true, startMinute: 23 * 60, endMinute: 7 * 60)
        store.saveNow()
        let reloaded = SettingsStore(fileURL: url)
        #expect(reloaded.settings.petName == "Biscuit")
        #expect(reloaded.settings.quietHours.enabled)
    }

    @Test func tolerantDecodingKeepsGoodValues() {
        let data = Data("{\"petName\": \"Pip\", \"soundVolume\": \"loud\", \"futureSetting\": 1, \"theme\": \"spaceStation\"}".utf8)
        let settings = AppSettings.decodeTolerantly(data)
        #expect(settings.petName == "Pip")
        #expect(settings.theme == .spaceStation)
        #expect(settings.soundVolume == AppSettings().soundVolume)
    }

    @Test func garbageGivesDefaults() {
        #expect(AppSettings.decodeTolerantly(Data("nope".utf8)) == AppSettings())
    }
}

@Suite("Quiet hours and notification policy")
struct PolicyTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: hour, minute: minute))!
    }

    @Test func overnightWindowWraps() {
        let quiet = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(quiet.isActive(at: date(hour: 23), calendar: calendar))
        #expect(quiet.isActive(at: date(hour: 3), calendar: calendar))
        #expect(!quiet.isActive(at: date(hour: 7), calendar: calendar))
        #expect(!quiet.isActive(at: date(hour: 15), calendar: calendar))
        #expect(!QuietHours(enabled: false).isActive(at: date(hour: 23), calendar: calendar))
    }

    @Test func quietHoursSilenceSoundAndBannersButKeepAnimation() {
        var settings = AppSettings()
        settings.soundEnabled = true
        settings.quietHours = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        settings.setDelivery(CategoryDelivery(animate: true, badge: true, banner: true, sound: true), for: .needsAttention)
        let quiet = NotificationPolicy.decide(.needsAttention, settings: settings, context: NotificationContext(now: date(hour: 23)), calendar: calendar)
        #expect(quiet.animate && quiet.badge && !quiet.banner && !quiet.sound && quiet.quiet)
        let day = NotificationPolicy.decide(.needsAttention, settings: settings, context: NotificationContext(now: date(hour: 12)), calendar: calendar)
        #expect(day.banner && day.sound && !day.quiet)
    }

    @Test func soundNeedsTheMasterSwitch() {
        var settings = AppSettings()
        settings.setDelivery(CategoryDelivery(animate: true, sound: true), for: .turnCompleted)
        settings.soundEnabled = false
        #expect(!NotificationPolicy.decide(.turnCompleted, settings: settings, context: NotificationContext(now: date(hour: 12)), calendar: calendar).sound)
    }

    @Test func pauseStopsReactions() {
        var settings = AppSettings()
        settings.pauseReactions = true
        settings.soundEnabled = true
        let decision = NotificationPolicy.decide(.turnCompleted, settings: settings, context: NotificationContext(now: date(hour: 12)), calendar: calendar)
        #expect(!decision.animate && !decision.sound && !decision.banner)
    }

    @Test func simulatedAndLateEventsNeverReachNotificationCenter() {
        var settings = AppSettings()
        settings.setDelivery(CategoryDelivery(animate: true, badge: true, banner: true, sound: true), for: .turnCompleted)
        let simulated = NotificationPolicy.decide(.turnCompleted, settings: settings, context: NotificationContext(now: date(hour: 12), isSimulated: true), calendar: calendar)
        #expect(!simulated.banner)
        let late = NotificationPolicy.decide(.turnCompleted, settings: settings, context: NotificationContext(now: date(hour: 12), isLate: true), calendar: calendar)
        #expect(late == .none)
    }

    @Test func toolActivityNeverBanners() {
        var settings = AppSettings()
        settings.setDelivery(CategoryDelivery(animate: true, badge: true, banner: true, sound: true), for: .toolActivity)
        let decision = NotificationPolicy.decide(.toolActivity, settings: settings, context: NotificationContext(now: date(hour: 12)), calendar: calendar)
        #expect(!decision.banner && !decision.badge)
    }

    @Test func coalescerBatchesRepeats() {
        var coalescer = BannerCoalescer(window: 30)
        let t0 = Date()
        #expect(coalescer.register(key: "k", at: t0) == .show(suppressedSinceLast: 0))
        #expect(coalescer.register(key: "k", at: t0 + 5) == .suppress)
        #expect(coalescer.register(key: "k", at: t0 + 10) == .suppress)
        #expect(coalescer.register(key: "other", at: t0 + 10) == .show(suppressedSinceLast: 0))
        #expect(coalescer.register(key: "k", at: t0 + 40) == .show(suppressedSinceLast: 2))
    }
}

@Suite("Achievements and friendship")
@MainActor
struct AchievementTests {
    @Test func progressFromRealEventsOnly() {
        let engine = AchievementEngine(state: ProgressState())
        var registry = SessionRegistry()
        func record(_ event: CompanionEvent) -> [AchievementID] {
            let transition = registry.apply(event)
            return engine.record(event, transition: transition, session: transition.flatMap { registry[$0.sessionID] })
        }
        var simulated = TestSupport.event("SessionStart", session: "sim")
        simulated.origin = .simulator
        #expect(record(simulated).isEmpty)
        #expect(record(TestSupport.event("SessionStart")) == [.firstSession])
        #expect(record(TestSupport.event("Stop", delivery: .late)).isEmpty)
        #expect(record(TestSupport.event("Stop")) == [.firstTurn])
        #expect(record(TestSupport.event("Stop")).isEmpty)
    }

    @Test func greenBuildRequiresARealOutcome() {
        let engine = AchievementEngine(state: ProgressState())
        let plain = TestSupport.event("PostToolUse", tool: "Bash")
        #expect(engine.record(plain, transition: nil, session: nil).isEmpty)
        let piped = TestSupport.event("PostToolUse", tool: "Bash") { $0.commandKind = "test"; $0.commandReliable = false }
        #expect(engine.record(piped, transition: nil, session: nil).isEmpty)
        let real = TestSupport.event("PostToolUse", tool: "Bash") { $0.commandKind = "test"; $0.commandReliable = true }
        #expect(engine.record(real, transition: nil, session: nil) == [.firstGreenBuild])
    }

    @Test func globetrotterCountsDistinctProjects() {
        let engine = AchievementEngine(state: ProgressState())
        var registry = SessionRegistry()
        var unlocked: [AchievementID] = []
        for (index, project) in ["/a", "/b", "/b", "/c"].enumerated() {
            let event = TestSupport.event("SessionStart", session: "s\(index)", project: project)
            unlocked += engine.record(event, transition: registry.apply(event), session: nil)
        }
        #expect(unlocked.contains(.globetrotter))
        #expect(engine.state.projectKeys.count == 3)
    }

    @Test func affectionHasDailyCapsAndNeverDecreases() {
        let engine = AchievementEngine(state: ProgressState())
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<50 { engine.recordInteraction(.pet, at: day) }
        #expect(engine.state.affectionPoints == PetInteraction.pet.dailyCap)
        // A long absence does not reduce anything.
        let monthLater = day.addingTimeInterval(30 * 86_400)
        engine.recordInteraction(.play, at: monthLater)
        #expect(engine.state.affectionPoints == PetInteraction.pet.dailyCap + 2)
    }

    @Test func goodFriendsAfterSevenDistinctDays() {
        let engine = AchievementEngine(state: ProgressState())
        var unlocked: [AchievementID] = []
        for day in [0, 1, 1, 3, 8, 9, 20, 40] {
            unlocked += engine.recordInteraction(.pet, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400)).unlocked
        }
        #expect(unlocked.contains(.goodFriends))
    }

    @Test func accessoriesUnlockTransparently() {
        let october = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27))!
        let june = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        #expect(Accessory.pumpkin.isAvailable(unlocked: [], date: october))
        #expect(!Accessory.pumpkin.isAvailable(unlocked: [], date: june))
        #expect(!Accessory.headphones.isAvailable(unlocked: [], date: june))
        #expect(Accessory.headphones.isAvailable(unlocked: [.firstSession], date: june))
        #expect(Accessory.beanie.isAvailable(unlocked: [], date: june))
    }
}
