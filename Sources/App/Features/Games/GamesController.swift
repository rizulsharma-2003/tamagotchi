import AppKit
import SwiftUI
import TamagotchiCore

enum GameTab: String, CaseIterable, Identifiable {
    case catchTreats, rps
    var id: String { rawValue }
}

/// Mini-games: Catch the Treats and rock-paper-scissors with Mochi and the companion.
///
/// Keys are read only from the Games window itself (a local monitor that ignores every
/// event for other windows); nothing is observed anywhere else.
@MainActor
final class GamesController {
    private unowned let environment: AppEnvironment
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    let model = GamesModel()
    let catchModel = CatchModel()
    private(set) lazy var rpsModel = RPSModel(withCompanion: companionPlays)

    init(environment: AppEnvironment) {
        self.environment = environment
        registerDebugHooks()
    }

    private var companionPlays: Bool { environment.settingsStore.settings.companionVisibility != .never }

    func show() {
        show(tab: nil)
    }

    func show(tab: GameTab?) {
        if let tab { model.tab = tab }
        if !rpsModel.busy, rpsModel.match.withCompanion != companionPlays { rpsModel.reset(withCompanion: companionPlays) }
        let window = self.window ?? makeWindow()
        self.window = window
        installKeyMonitor()
        FeatureWindow.present(window, environment: environment)
    }

    private func makeWindow() -> NSWindow {
        let view = GamesView(environment: environment, controller: self)
        let window = FeatureWindow.make(title: "Games", size: NSSize(width: 572, height: 512), view: view, autosave: "MacTamagotchiGames")
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchModel.pause() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.catchModel.pause()
                self?.removeKeyMonitor()
            }
        })
        return window
    }

    // MARK: Keys (this window only)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let down = event.type == .keyDown
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers ?? ""
            let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                guard let self, plain, windowNumber == self.window?.windowNumber else { return false }
                return self.handleKey(keyCode: keyCode, characters: characters, down: down)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was used by a game.
    private func handleKey(keyCode: UInt16, characters: String, down: Bool) -> Bool {
        switch model.tab {
        case .catchTreats:
            let session = catchModel.session
            switch keyCode {
            case 123, 0: // ← or A
                if catchModel.phase == .playing { session.left = down }
                return true
            case 124, 2: // → or D
                if catchModel.phase == .playing { session.right = down }
                return true
            case 49: // Space
                if down { toggleCatch() }
                return true
            case 53: // Escape
                if down { catchModel.pause() }
                return catchModel.phase != .ready
            default:
                return false
            }
        case .rps:
            guard let choice = RPSChoice(key: characters) else { return false }
            if down { pick(choice) }
            return true
        }
    }

    private func toggleCatch() {
        switch catchModel.phase {
        case .ready, .over: catchModel.start()
        case .playing: catchModel.pause()
        case .paused: catchModel.resume()
        }
    }

    // MARK: Catch the Treats

    func handle(_ events: [CatchGame.Event]) {
        for event in events {
            switch event {
            case .caught(let kind, _, _):
                FeatureSound.play(kind == .golden ? .success : .pop, environment: environment)
            case .missed, .faster:
                break
            case .gameOver:
                finishCatch()
            }
        }
    }

    private func finishCatch() {
        guard catchModel.phase == .playing else { return }
        let game = catchModel.session.game
        let newRecord = environment.settingsStore.settings.games.recordCatch(score: game.score, bestCombo: game.bestCombo) && game.score > 0
        catchModel.finish(newRecord: newRecord)
        let petName = environment.world.settings.petName
        if newRecord {
            FeatureSound.play(.celebration, environment: environment)
            environment.world.playPet(.excitedJump)
            environment.world.showToast(title: "New high score: \(game.score)!", detail: "\(petName) caught \(game.caught) treats. Yum!")
        } else {
            FeatureSound.play(.sleep, environment: environment)
        }
    }

    // MARK: Rock, paper, scissors

    func pick(_ choice: RPSChoice) {
        let now = Date().timeIntervalSinceReferenceDate
        guard rpsModel.play(choice, at: now) != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + RPSModel.shake) { [weak self] in
            MainActor.assumeIsolated { self?.revealRound() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + RPSModel.roundLength) { [weak self] in
            MainActor.assumeIsolated { self?.rpsModel.finish() }
        }
    }

    private func revealRound() {
        guard let round = rpsModel.round else { return }
        withAnimation(.easeOut(duration: 0.2)) { rpsModel.reveal() }
        let streak = rpsModel.match.streak
        let newBest = environment.settingsStore.settings.games.recordRPS(round, streak: streak) && streak >= 3
        if newBest {
            FeatureSound.play(.celebration, environment: environment)
            environment.world.playPet(.excitedJump)
            environment.world.showToast(title: "New best streak: \(streak)!", detail: "Rock, paper, scissors champion.")
        } else if round.isWin {
            FeatureSound.play(.success, environment: environment)
        } else if round.isLoss {
            FeatureSound.play(.investigate, environment: environment)
        } else {
            FeatureSound.play(.pop, environment: environment)
        }
    }

    // MARK: Development

    private func registerDebugHooks() {
        guard DebugHooks.isEnabled else { return }
        environment.debug.register("games") { [weak self] argument in
            guard let self else { return }
            let parts = argument.split(separator: ":").map(String.init)
            switch parts.first ?? "" {
            case "appearance":
                // Check both looks without changing the system setting.
                NSApp.appearance = parts.count > 1 ? NSAppearance(named: parts[1] == "light" ? .aqua : .darkAqua) : nil
            case "rps":
                self.show(tab: .rps)
                if parts.count > 1, let choice = RPSChoice(key: parts[1]) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { self.pick(choice) } }
                    self.capture("games-rps", after: 0.8 + RPSModel.shake + 1.1)
                } else {
                    self.capture("games-rps", after: 1.2)
                }
            case "play":
                // A self-playing demo: chases the lowest treat for a few seconds.
                self.show(tab: .catchTreats)
                self.catchModel.start()
                self.autopilot(until: Date().addingTimeInterval(Double(parts.count > 1 ? parts[1] : "") ?? 6))
                for (index, delay) in [3.9, 4.5, 5.1, 5.7].enumerated() { self.capture("games-catch-play-\(index)", after: delay) }
            case "over":
                self.show(tab: .catchTreats)
                self.catchModel.start()
                for x in [0.05, 0.95, 0.9] { self.catchModel.session.debugDrop(.cookie, at: x) }
                self.capture("games-catch-over", after: 4.5)
            default:
                self.show(tab: .catchTreats)
                self.capture("games-catch", after: 1.2)
            }
        }
        environment.debug.registerState("games") { [weak self] in
            guard let self else { return [:] }
            let game = self.catchModel.session.game
            return ["tab": self.model.tab.rawValue, "catch": ["phase": "\(self.catchModel.phase)", "score": game.score, "caught": game.caught,
                                                               "misses": game.misses, "level": game.level, "petX": game.petX],
                    "rps": ["busy": self.rpsModel.busy, "rounds": self.rpsModel.match.rounds.count, "streak": self.rpsModel.match.streak],
                    "records": ["catchHigh": self.environment.settingsStore.settings.games.catchHighScore,
                                "rpsWins": self.environment.settingsStore.settings.games.rpsWins]]
        }
    }

    private func autopilot(until end: Date) {
        guard Date() < end, catchModel.phase == .playing else {
            catchModel.session.dragX = nil
            return
        }
        let game = catchModel.session.game
        catchModel.session.dragX = game.treats.min { $0.y < $1.y }?.x
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.autopilot(until: end) }
        }
    }

    private func capture(_ name: String, after delay: TimeInterval) {
        environment.debug.capture(named: name, after: delay) { [weak self] in self?.window }
    }
}

/// Which game is showing.
@MainActor
@Observable
final class GamesModel {
    var tab: GameTab = .catchTreats
}

struct GamesView: View {
    let environment: AppEnvironment
    let controller: GamesController

    var body: some View {
        @Bindable var model = controller.model
        VStack(spacing: 14) {
            Picker("Game", selection: $model.tab) {
                Text("Catch the Treats").tag(GameTab.catchTreats)
                Text("Rock, Paper, Scissors").tag(GameTab.rps)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            switch model.tab {
            case .catchTreats:
                CatchGameView(environment: environment, model: controller.catchModel) { controller.handle($0) }
            case .rps:
                RPSGameView(environment: environment, model: controller.rpsModel) { controller.pick($0) }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.horizontal, 22)
        .frame(width: 572, height: 512)
        .onChange(of: model.tab) { _, tab in
            if tab != .catchTreats { controller.catchModel.pause() }
        }
    }
}

struct GamesSettingsSection: View {
    let environment: AppEnvironment
    @State private var confirmReset = false

    var body: some View {
        let records = environment.world.settings.games
        Section("Games") {
            LabeledContent("Catch the Treats") {
                Text(records.catchGamesPlayed == 0 ? "Not played yet"
                     : "Best \(records.catchHighScore) · best combo \(records.catchBestCombo) · \(records.catchGamesPlayed) played")
                    .monospacedDigit()
            }
            LabeledContent("Rock, paper, scissors") {
                Text(records.rpsWins + records.rpsLosses + records.rpsDraws == 0 ? "Not played yet"
                     : "\(records.rpsWins) won · \(records.rpsLosses) lost · \(records.rpsDraws) drawn")
                    .monospacedDigit()
            }
            HStack {
                Button("Play…") { environment.games.show() }
                Spacer()
                Button("Reset Records…") { confirmReset = true }
                    .disabled(records == GameRecords())
            }
        }
        .confirmationDialog("Reset all game records?", isPresented: $confirmReset) {
            Button("Reset Records", role: .destructive) { environment.settingsStore.settings.games = GameRecords() }
        } message: {
            Text("High scores and win counts start over. This can't be undone.")
        }
    }
}
