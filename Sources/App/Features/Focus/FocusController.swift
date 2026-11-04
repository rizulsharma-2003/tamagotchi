import AppKit
import SwiftUI
import TamagotchiCore

/// The focus buddy: a Pomodoro timer; Mochi naps while you focus and wakes you for breaks.
///
/// The phase machine is `FocusTimer` (pure, in Core); this controller ticks it once a second
/// while a session runs, publishes the phase to the world and turns transitions into
/// toasts, speech, animations, an optional chime and an optional banner.
@MainActor
final class FocusController {
    private unowned let environment: AppEnvironment
    private(set) var timer: FocusTimer
    /// Completed focus blocks, for the daily recap.
    let log: FocusLog
    private var ticker: Timer?
    /// Bumped on every transition so follow-up beats of an old one never play.
    private var beat = 0

    init(environment: AppEnvironment) {
        self.environment = environment
        let settings = environment.settingsStore.settings
        log = FocusLog(fileURL: environment.paths.home.appendingPathComponent("focus-log.json"), retentionDays: settings.historyRetentionDays)
        timer = FocusTimer(durations: FocusTimer.Durations(settings.focus))
    }

    private var settings: AppSettings { environment.settingsStore.settings }
    private var world: CompanionWorld { environment.world }

    func start() {
        log.retentionDays = settings.historyRetentionDays
        log.load()
        registerDebugHooks()
    }

    var isRunning: Bool { timer.isRunning }

    /// Starts a focus session, or stops the running one.
    func toggle() {
        if timer.isRunning { stop() } else { begin() }
    }

    func begin(durations: FocusTimer.Durations? = nil) {
        timer.durations = durations ?? FocusTimer.Durations(settings.focus)
        apply(timer.start(at: Date()))
        startTicker()
    }

    func stop() { apply(timer.stop(at: Date())) }

    func skip() { apply(timer.skip(at: Date())) }

    /// For the menu-bar item's menu.
    var menuTitle: String {
        guard let status = world.focus else { return "Start Focus" }
        return "Stop Focus (\(status.phase.title) \(FocusStatus.clock(status.remaining(at: Date()))) left)"
    }

    // MARK: Ticking

    private func startTicker() {
        guard ticker == nil else { return }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker.tolerance = 0.2
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func tick() {
        let transitions = timer.advance(to: Date())
        if transitions.isEmpty { publish() } else { apply(transitions) }
    }

    private func apply(_ transitions: [FocusTimer.Transition]) {
        let wasNapping = world.focus?.petNaps ?? false
        for case .focusCompleted(let block) in transitions {
            log.retentionDays = settings.historyRetentionDays
            log.append(block)
        }
        publish()
        if !timer.isRunning {
            ticker?.invalidate()
            ticker = nil
        }
        present(transitions, wasNapping: wasNapping)
    }

    /// The world sees the phase; Mochi's base loop sleeps through focus blocks when naps are on.
    private func publish() {
        world.updateFocus(timer.status(naps: settings.focus.napsDuringFocus))
    }

    // MARK: Presentation

    private func present(_ transitions: [FocusTimer.Transition], wasNapping: Bool) {
        beat += 1
        let petName = settings.petName
        if transitions.contains(.stopped) {
            world.say("Okay! Back to playing.", speaker: .pet, duration: 3.5)
            if wasNapping { world.playPet(.wakeUp) }
            return
        }
        if transitions.contains(.expired) {
            world.showToast(title: "Focus session ended", detail: "Your Mac was asleep when the block ended, so it wasn't counted.", seconds: 8)
            if wasNapping { world.playPet(.wakeUp) }
            return
        }
        if case .finished(let blocks) = transitions.last {
            let minutes = Int((Double(blocks) * timer.durations.focus / 60).rounded())
            world.showToast(title: "Focus set complete!", detail: "\(blocks) focus \(blocks == 1 ? "block" : "blocks") · \(minutes) minutes. Well done!", seconds: 8)
            world.say("We did it! Time for a proper rest.", speaker: .pet)
            world.playPet(.excitedJump)
            world.playCompanion(.celebrate)
            if settings.focus.chimeAtBreak { FeatureSound.play(.celebration, environment: environment) }
            return
        }
        guard case .started(let phase, let cycle) = transitions.last else { return }
        let cycles = timer.durations.cyclesBeforeLongBreak
        switch phase {
        case .focus where cycle == 1:
            let length = Self.length(timer.durations.focus)
            if settings.focus.napsDuringFocus {
                world.say("Focus time. I'll nap right here.", speaker: .pet)
                world.playPet(.yawn)
            } else {
                world.say("Focus time. I'll keep you company.", speaker: .pet)
                world.playPet(.nod)
            }
            world.playCompanion(.nod)
            world.showToast(title: "Focus · \(length)", detail: "\(petName) wakes you for a stretch break.")
        case .focus:
            world.say(settings.focus.napsDuringFocus ? "Back to it! Wake me at the break." : "Back to it! You've got this.", speaker: .pet)
            if settings.focus.napsDuringFocus { world.playPet(.yawn) }
            world.showToast(title: "Back to focus", detail: "Block \(cycle) of \(cycles).")
            if settings.focus.chimeAtBreak { FeatureSound.play(.greeting, environment: environment) }
        case .shortBreak, .longBreak:
            let length = Self.length(timer.running?.duration ?? 300)
            let long = phase == .longBreak
            world.showToast(title: long ? "Long break!" : "Stretch break!",
                            detail: long ? "\(cycle) focus blocks done · \(length) to recharge."
                                : "Focus block \(cycle) done · \(length) break.", seconds: 8)
            world.say(long ? "Long break! Get some water and look outside." : "Stretch break! Stand up and wiggle with me.", speaker: .pet)
            breakChoreography()
            world.playCompanion(.greet)
            if settings.focus.chimeAtBreak { FeatureSound.play(.success, environment: environment) }
            postBreakBanner(phase)
        }
    }

    /// Mochi wakes, stretches, then gets playful for the break.
    /// "5 minutes" (or seconds, for very short test durations).
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 1 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return "\(Int(seconds.rounded())) seconds"
    }

    private func breakChoreography() {
        world.playPet(.wakeUp)
        let current = beat
        later(1.3, ifStill: current) { $0.world.playPet(.stretch) }
        later(4.2, ifStill: current) { $0.world.playPet(.play) }
    }

    private func later(_ delay: TimeInterval, ifStill current: Int, _ action: @escaping @MainActor (FocusController) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.beat == current, self.timer.running?.phase.isBreak == true else { return }
                action(self)
            }
        }
    }

    /// A banner only for users who asked for one, and never in quiet mode/hours or while paused.
    private func postBreakBanner(_ phase: FocusStatus.Phase) {
        let settings = self.settings
        guard settings.focus.bannerAtBreak, !settings.pauseReactions, !NotificationPolicy.isQuiet(settings, at: Date()) else { return }
        environment.postBanner(FocusTimer.breakBanner(phase: phase, petName: settings.petName), category: .milestone, sessionID: nil)
    }

    // MARK: Development

    private func registerDebugHooks() {
        guard DebugHooks.isEnabled else { return }
        environment.debug.register("focus") { [weak self] argument in
            guard let self else { return }
            switch argument {
            case "start": self.begin()
            // Seconds instead of minutes, to watch a whole cycle quickly.
            case "fast": self.begin(durations: FocusTimer.Durations(focus: 12, shortBreak: 8, longBreak: 10, cyclesBeforeLongBreak: 2))
            case "skip": self.skip()
            case "stop": self.stop()
            case "settings": self.showSettingsPreview()
            default: break
            }
        }
        // The games controller is created lazily; make sure its development hooks exist too.
        _ = environment.games
        environment.debug.registerState("focus") { [weak self] in
            guard let self, let running = self.timer.running else { return ["running": false, "logged": self?.log.blocks.count ?? 0] }
            return ["running": true, "phase": running.phase.rawValue, "cycle": running.cycle,
                    "remaining": Int(running.endsAt.timeIntervalSinceNow.rounded()), "completed": self.timer.completedBlocks,
                    "logged": self.log.blocks.count, "petNaps": self.world.focus?.petNaps ?? false]
        }
    }

    private var settingsPreview: NSWindow?

    /// Development: the feature sections on their own, since the Fun tab scrolls.
    private func showSettingsPreview() {
        let view = Form {
            FocusSettingsSection(environment: environment)
            GamesSettingsSection(environment: environment)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
        let window = settingsPreview ?? FeatureWindow.make(title: "Feature Settings Preview", size: NSSize(width: 520, height: 760),
                                                            view: view, autosave: "MacTamagotchiFeaturePreview")
        settingsPreview = window
        FeatureWindow.present(window, environment: environment)
        environment.debug.capture(named: "feature-settings", after: 1.2) { [weak self] in self?.settingsPreview }
    }
}

struct FocusSettingsSection: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    var body: some View {
        let name = store.settings.petName
        Section("Focus buddy") {
            Stepper(value: $store.settings.focus.workMinutes, in: 5...120, step: 5) {
                LabeledContent("Focus block", value: "\(store.settings.focus.workMinutes) min")
            }
            Stepper(value: $store.settings.focus.breakMinutes, in: 1...30) {
                LabeledContent("Short break", value: "\(store.settings.focus.breakMinutes) min")
            }
            Stepper(value: $store.settings.focus.longBreakMinutes, in: 5...60, step: 5) {
                LabeledContent("Long break", value: "\(store.settings.focus.longBreakMinutes) min")
            }
            Stepper(value: $store.settings.focus.cyclesBeforeLongBreak, in: 2...8) {
                LabeledContent("Long break after", value: "\(store.settings.focus.cyclesBeforeLongBreak) blocks")
            }
            Toggle("\(name) naps while you focus", isOn: $store.settings.focus.napsDuringFocus)
            Toggle("Chime when a break starts", isOn: $store.settings.focus.chimeAtBreak)
                .disabled(!store.settings.soundEnabled)
            Toggle("Show a notification when a break starts", isOn: $store.settings.focus.bannerAtBreak)
            HStack {
                Text(store.settings.soundEnabled ? "Changes apply to the next focus session." : "Turn Sound on to hear the chime. Changes apply to the next session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(environment.world.focus == nil ? "Start Focus" : "Stop Focus") { environment.focus.toggle() }
            }
        }
    }
}

/// The running focus session in the popover (nothing when none runs).
struct FocusPopoverRow: View {
    let environment: AppEnvironment

    var body: some View {
        if let status = environment.world.focus {
            let cycles = environment.focus.timer.durations.cyclesBeforeLongBreak
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                FocusRowContent(status: status, cycles: cycles, now: timeline.date,
                                onSkip: { environment.focus.skip() }, onStop: { environment.focus.stop() })
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

private struct FocusRowContent: View {
    let status: FocusStatus
    let cycles: Int
    let now: Date
    let onSkip: () -> Void
    let onStop: () -> Void

    private var tint: Color {
        switch status.phase {
        case .focus: return .indigo
        case .shortBreak: return .teal
        case .longBreak: return .green
        }
    }

    private var symbol: String {
        switch status.phase {
        case .focus: return status.petNaps ? "moon.zzz.fill" : "timer"
        case .shortBreak: return "figure.cooldown"
        case .longBreak: return "cup.and.saucer.fill"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(status.phase.title) \(FocusStatus.clock(status.remaining(at: now))) left")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    HStack(spacing: 3) {
                        ForEach(1...max(1, cycles), id: \.self) { index in
                            Circle()
                                .fill(index < status.cycle || (index == status.cycle && status.phase.isBreak) ? tint : tint.opacity(0.2))
                                .frame(width: 5, height: 5)
                                .overlay(Circle().strokeBorder(tint, lineWidth: index == status.cycle && !status.phase.isBreak ? 1 : 0))
                        }
                    }
                    .help("Focus block \(status.cycle) of \(cycles)")
                }
                GeometryReader { geometry in
                    Capsule().fill(tint.opacity(0.15))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint).frame(width: max(3, geometry.size.width * status.progress(at: now)))
                        }
                }
                .frame(height: 3)
            }
            Button("Skip", action: onSkip)
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .help(status.phase == .focus ? "Start the break now (this block isn't counted)" : "End the break and focus again")
            Button(action: onStop) {
                Image(systemName: "stop.fill").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Stop the focus session")
            .accessibilityLabel("Stop focus")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }
}
