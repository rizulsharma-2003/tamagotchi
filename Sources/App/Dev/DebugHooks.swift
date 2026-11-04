import AppKit
import TamagotchiCore

/// Development-only observability, enabled with MACTAMAGOTCHI_DEBUG_STATE=1.
///
/// - Writes `<home>/debug-state.json` once a second (sessions, animations, connection).
/// - Watches `<home>/debug-request`: "popover", "settings:<tab>", "activity", "desktop",
///   "close"; the app shows that UI and writes `<home>/debug-<name>.png` of its own window.
///   Also "interact:pet|play|treat" (as from the menu-bar item's menu), "roam:<activity>",
///   "menubar:<style>", "pause:on|off", "simulate:<scenario>", "interaction:<id>".
/// Nothing here runs unless the environment variable is set.
@MainActor
final class DebugHooks {
    private unowned let environment: AppEnvironment
    private var timer: Timer?
    /// Feature requests ("<prefix>:<argument>") and state, registered by the feature controllers.
    private var featureHandlers: [String: (String) -> Void] = [:]
    private var featureState: [String: () -> Any] = [:]

    /// Handles debug requests starting with `prefix` (the argument is everything after "prefix:").
    func register(_ prefix: String, _ handler: @escaping (String) -> Void) { featureHandlers[prefix] = handler }

    /// Adds `key` to debug-state.json.
    func registerState(_ key: String, _ provider: @escaping () -> Any) { featureState[key] = provider }

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MACTAMAGOTCHI_DEBUG_STATE"] == "1" }

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func start() {
        guard Self.isEnabled else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.writeState()
                self?.handleRequest()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func writeState() {
        let world = environment.world
        let status = world.menuBarStatus
        var state: [String: Any] = [
            "connection": [
                "title": world.connection.title,
                "level": "\(world.connection.level)",
                "integration": "\(world.connection.integration)",
                "claude": "\(world.connection.claude)",
                "bridgeListening": world.connection.bridgeListening,
                "bridgeError": world.connection.bridgeError ?? NSNull(),
                "accepted": world.connection.eventsAccepted,
                "rejected": world.connection.eventsRejected,
                "lastRejection": world.connection.lastRejection ?? NSNull(),
            ],
            "menuBar": ["mood": status.mood.rawValue, "companion": status.companionVisible, "working": status.companionWorking,
                        "badge": status.badge.map { "\($0)" } ?? NSNull()],
            "pet": ["animation": world.pet.current.animation.rawValue, "base": world.pet.base.rawValue, "asleep": world.petAsleep],
            "companion": ["present": world.companionPresent, "animation": world.companion.current.animation.rawValue, "base": world.companion.base.rawValue],
            "interaction": world.interaction?.id.rawValue ?? NSNull(),
            "caption": world.activeCaption?.text ?? NSNull(),
            "attention": world.attention.map { ["kind": $0.kind.rawValue, "level": "\($0.level)", "summary": $0.summary] } ?? NSNull(),
            "primarySession": world.primarySession?.id ?? NSNull(),
            "sessions": world.sessions.map { session -> [String: Any] in
                ["id": session.id, "project": session.displayName, "phase": session.phase.rawValue,
                 "status": session.statusLine(now: Date()), "turns": session.turnsCompleted, "simulated": session.isSimulated,
                 "failuresThisTurn": session.failuresThisTurn, "lateEvents": session.lateEvents,
                 "buildTest": session.lastBuildTest?.summary ?? NSNull()]
            },
            "timeline": world.timeline.suffix(14).map { "\($0.rawName) | \($0.summary) | \($0.delivery.rawValue)\($0.isSimulated ? " | sim" : "")" },
            "result": world.latestResult.map { card -> [String: Any] in
                ["project": card.projectName, "status": card.statusLine, "buildTest": card.buildTest?.summary ?? "none"]
            } ?? NSNull(),
            "missed": world.missed.map { ["delivered": $0.delivered, "dropped": $0.dropped] } ?? NSNull(),
            "diagnostics": ["duplicates": world.diagnostics.duplicatesIgnored, "unknown": world.diagnostics.unknownEvents,
                            "late": world.diagnostics.lateEvents],
            "desktopPet": ["enabled": world.settings.desktopPetEnabled, "visible": environment.ui.desktopPetVisible],
            "effects": ["sounds": environment.soundsPlayed, "banners": environment.bannersPosted],
            "roam": roamState(),
            "menuBarStage": environment.statusItem.diagnostics,
            "frames": FrameStats.shared.summary(),
            "popoverVisible": environment.ui.popoverVisible,
            "reducedMotion": world.reducedMotion,
            "quiet": NotificationPolicy.isQuiet(world.settings, at: Date()),
            "paused": world.settings.pauseReactions,
            "progress": ["level": world.progress.friendshipLevel, "points": world.progress.affectionPoints,
                         "unlocked": Array(world.progress.unlocked.keys).sorted()],
        ]
        for (key, provider) in featureState { state[key] = provider() }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: environment.paths.home.appendingPathComponent("debug-state.json"), options: .atomic)
    }

    private func roamState() -> [String: Any] {
        let world = environment.world
        let roamer = world.roamer
        guard roamer.isActive, let zone = roamer.zone else { return ["active": false] }
        let sample = roamer.sample(at: world.now)
        return [
            "active": true,
            "mode": roamer.mode.rawValue,
            "activity": sample.activity.rawValue,
            "animation": sample.animation.rawValue,
            "x": (sample.x * 10).rounded() / 10,
            "lift": (sample.lift * 10).rounded() / 10,
            "style": sample.style.rawValue,
            "speed": (sample.speed * 10).rounded() / 10,
            "userGame": roamer.userGameUntil.map { max(0, $0 - world.now) } ?? NSNull(),
            "occupied": zone.occupied.map { [$0.lowerBound, $0.upperBound] },
            "facing": sample.facing,
            "travelling": sample.isTravelling,
            "props": sample.props.map { $0.kind.rawValue },
            "zone": [zone.minX, zone.maxX, zone.homeX, zone.companionX],
            "pending": world.pendingInteractionID?.rawValue ?? NSNull(),
        ]
    }

    private func handleRequest() {
        let url = environment.paths.home.appendingPathComponent("debug-request")
        guard let request = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !request.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
        let parts = request.split(separator: ":").map(String.init)
        switch parts.first {
        case "popover":
            environment.statusItem.showPopover()
            capture(named: "popover", after: 1.2) { NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible } }
        case "settings":
            let tab = parts.count > 1 ? SettingsTab(rawValue: parts[1]) ?? .general : .general
            environment.windows.showSettings(tab: tab)
            capture(named: "settings-\(tab.rawValue)", after: 1.5) { NSApp.windows.first { $0.identifier == WindowManager.settingsIdentifier } }
        case "activity":
            environment.windows.showActivity()
            capture(named: "activity", after: 1.5) { NSApp.windows.first { $0.title == "Activity" } }
        case "welcome":
            environment.windows.showWelcome()
            capture(named: "welcome", after: 1.2) { NSApp.windows.first { $0.title == "Welcome to MacTamagotchi" } }
        case "desktop":
            capture(named: "desktop", after: 0.5) { NSApp.windows.first { $0 is DesktopPetPanel && $0.isVisible } }
        case "close":
            environment.statusItem.closePopover()
            // Only ordinary windows: the menu-bar overlay, bubbles, the desktop pet and demo stages are borderless.
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) && !(window is DesktopPetPanel) {
                window.close()
            }
        case "toggle-desktop":
            environment.toggleDesktopPet()
        case "simulate":
            if parts.count > 1, let scenario = EventSimulator.Scenario(rawValue: parts[1]) {
                environment.simulator.run(scenario)
            }
        case "roam":
            if parts.count > 1, let activity = RoamActivity(rawValue: parts[1]) {
                environment.world.forceRoamActivity(activity)
            }
        case "interact":
            switch parts.count > 1 ? parts[1] : "" {
            case "pet": environment.world.interact(.pet)
            case "play": environment.world.interact(.play)
            case "treat": environment.world.interact(.treat)
            default: break
            }
        case "pause":
            environment.world.settings.pauseReactions = parts.count > 1 && parts[1] == "on"
        case "menubar":
            if parts.count > 1, let style = MenuBarStyle(rawValue: parts[1]) {
                environment.world.settings.menuBarStyle = style
            }
        case "interaction":
            if parts.count > 1, let id = InteractionID(rawValue: parts[1]) {
                environment.world.startInteraction(id, priority: .critical, variant: parts.count > 2 ? Int(parts[2]) ?? 0 : 0)
            }
        default:
            featureHandlers[parts[0]]?(parts.dropFirst().joined(separator: ":"))
        }
    }

    func capture(named name: String, after delay: TimeInterval, window: @escaping () -> NSWindow?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = window(), let view = window.contentView?.superview ?? window.contentView else {
                    self?.note("capture \(name): window not found")
                    return
                }
                let bounds = view.bounds
                guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
                view.cacheDisplay(in: bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: self.environment.paths.home.appendingPathComponent("debug-\(name).png"))
                }
            }
        }
    }

    func note(_ text: String) {
        try? text.write(to: environment.paths.home.appendingPathComponent("debug-note.txt"), atomically: true, encoding: .utf8)
    }
}
