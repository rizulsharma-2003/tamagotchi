import AppKit
import Observation
import TamagotchiCore
import TamagotchiWire

/// Shared UI state that is not part of the world itself.
@MainActor
@Observable
final class UIState {
    var popoverVisible = false
    var desktopPetVisible = false
    var settingsTab: SettingsTab = .general
    /// Why the menu bar is not in the style the user chose right now (e.g. roaming falls back to the stage).
    var menuBarNote: String?
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, characters, claude, assistant, iphone, agent, notifications, desktop, fun, privacy, developer, about
    var id: String { rawValue }
}

/// Owns the long-lived objects and connects them.
@MainActor
final class AppEnvironment: WorldEffects {
    let paths: BridgePaths
    let settingsStore: SettingsStore
    let journal: EventJournal
    let achievements: AchievementEngine
    let world: CompanionWorld
    let provider: ClaudeHookEventProvider
    let simulator: EventSimulator
    let integration: IntegrationController
    let sound = SoundPlayer()
    let notifications = NotificationCoordinator()
    let ui = UIState()
    let hotKey = HotKey()
    private let reducedMotion = ReducedMotionObserver()
    private var tickTimer: Timer?

    lazy var windows = WindowManager(environment: self)
    lazy var statusItem = StatusItemController(environment: self)
    lazy var desktopPet = DesktopPetController(environment: self)
    lazy var debug = DebugHooks(environment: self)

    // Features
    lazy var adventure = AdventureController(environment: self)
    lazy var games = GamesController(environment: self)
    lazy var focus = FocusController(environment: self)
    lazy var recap = RecapController(environment: self)
    lazy var shareClip = ShareClipController(environment: self)
    lazy var roomEditor = RoomEditorController(environment: self)
    lazy var seasons = SeasonController(environment: self)
    lazy var speech = SpeechController(environment: self)
    lazy var growth = GrowthController(environment: self)
    lazy var widget = WidgetPublisher(environment: self)
    lazy var demoTour = DemoTour(environment: self)
    lazy var assistant = AssistantController(environment: self)
    lazy var phone = PhoneController(environment: self)
    lazy var agent = AgentController(environment: self)
    let macUsage = MacUsageMonitor()

    init(paths: BridgePaths) {
        self.paths = paths
        BridgePaths.ensurePrivateDirectory(paths.home)
        settingsStore = SettingsStore(fileURL: paths.settingsFile)
        let settings = settingsStore.settings
        journal = EventJournal(fileURL: paths.journalFile, retention: .init(days: settings.historyRetentionDays),
                               storeProjectPaths: settings.storeProjectPaths)
        achievements = AchievementEngine(fileURL: paths.progressFile)
        world = CompanionWorld(journal: journal, achievements: achievements, settingsStore: settingsStore)
        provider = ClaudeHookEventProvider(paths: paths)
        simulator = EventSimulator(world: world)
        integration = IntegrationController(paths: paths)
        integration.world = world
    }

    func start() {
        journal.load()
        world.effects = self
        world.restoreFromJournal()
        reducedMotion.start { [weak self] value in self?.world.setSystemReducedMotion(value) }
        macUsage.start { [weak self] activity in self?.world.updateSystem(activity) }

        provider.onBridgeState = { [weak self] state, stats in
            let error: String?
            if case .failed(let reason) = state { error = reason } else { error = nil }
            self?.world.updateBridge(listening: state.isListening, error: error, accepted: stats.accepted, rejected: stats.rejected,
                                     lastRejection: stats.lastRejection, refusedPeers: stats.refusedPeers)
        }
        provider.onSpoolDrained = { [weak self] delivered, dropped in
            self?.world.noteSpoolDrained(delivered: delivered, dropped: dropped)
        }
        provider.start { [weak self] wire, delivery in
            guard let self else { return }
            // Claude's words (summaries for the iPhone) stop here: the world never keeps them.
            if delivery == .live { self.phone.record(wire) }
            self.world.ingest(wire.withoutSummary, delivery: delivery)
        }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.world.tick() }
        }
        timer.tolerance = 0.08
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        statusItem.install()
        desktopPet.applySettings()
        startFeatures()
        hotKey.register { [weak self] in self?.toggleDesktopPet() }
        Task { await integration.refresh() }
        Task { await notifications.refreshAuthorization() }

        if settingsStore.settings.showOnboarding {
            windows.showWelcome()
        }
        debug.start()
    }

    private func startFeatures() {
        seasons.start()
        shareClip.start()
        roomEditor.start()
        speech.start()
        growth.start()
        widget.start()
        demoTour.start()
        focus.start()
        recap.start()
        adventure.start()
        assistant.start()
        phone.start()
        agent.start()
    }

    func shutdown() {
        tickTimer?.invalidate()
        assistant.shutdown()
        provider.stop()
        settingsStore.saveNow()
        simulator.stop()
    }

    func toggleDesktopPet() {
        settingsStore.settings.desktopPetEnabled.toggle()
        desktopPet.applySettings()
    }

    // MARK: WorldEffects

    /// Counts for diagnostics (sounds actually requested, banners actually posted).
    private(set) var soundsPlayed = 0
    private(set) var bannersPosted = 0

    func play(_ cue: SoundCue) {
        soundsPlayed += 1
        sound.volume = Float(settingsStore.settings.soundVolume)
        sound.play(cue)
    }

    func postBanner(_ content: BannerContent, category: NotificationCategory, sessionID: String?) {
        bannersPosted += 1
        notifications.post(content, category: category, sessionID: sessionID)
    }

    func worldDidReact(to event: CompanionEvent, session: SessionSnapshot?) {
        speech.react(to: event, session: session)
        assistant.worldDidReact(to: event, session: session)
    }

    func userDidInteract(_ kind: PetInteraction) {
        speech.interacted(kind)
        phone.userInteracted(kind)
    }
}
