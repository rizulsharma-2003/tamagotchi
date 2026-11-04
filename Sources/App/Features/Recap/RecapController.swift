import AppKit
import SwiftUI
import TamagotchiCore
import UniformTypeIdentifiers

/// The daily recap card: today's real activity, presented by Mochi and the companion.
///
/// Numbers come only from the event journal (real, non-simulated events) and the focus log.
/// Once a day, from the recap hour (18:00), a day with real activity is announced with a
/// toast and a speech line, plus a banner for users who turned recap banners on.
@MainActor
final class RecapController {
    private unowned let environment: AppEnvironment
    private var window: NSWindow?
    private var checkTimer: Timer?
    /// With history off, events only exist from this launch on.
    private var launchedAt = Date()
    let model = RecapModel()

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func start() {
        launchedAt = Date()
        registerDebugHooks()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkEvening() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { self?.checkEvening() }
        }
    }

    func show() {
        show(day: Date())
    }

    func show(day: Date) {
        model.day = Calendar.current.startOfDay(for: day)
        model.refresh += 1
        let window = self.window ?? FeatureWindow.make(title: "Today's Recap", size: NSSize(width: 470, height: 660),
                                                       view: RecapWindowView(environment: environment, controller: self),
                                                       autosave: "MacTamagotchiRecap")
        self.window = window
        FeatureWindow.present(window, environment: environment)
    }

    // MARK: Data

    func recap(for day: Date, now: Date = Date()) -> DailyRecap {
        DailyRecap.compute(day: day, events: environment.journal.all, focus: environment.focus.log.blocks, historyStart: historyStart(now: now))
    }

    /// From when on the journal is complete: retention, the size cap, the oldest day it holds,
    /// and (with history off) this launch. Anything earlier is unknown, not "nothing happened".
    func historyStart(now: Date = Date()) -> Date {
        let journal = environment.journal
        let events = journal.all
        // Late (spooled) events are appended after newer ones, so look for the oldest.
        let oldest = events.lazy.map(\.timestamp).min()
        var start = Calendar.current.startOfDay(for: oldest ?? now)
        if journal.retention.maxAge > 0, journal.retention.maxEvents > 0 {
            start = max(start, now.addingTimeInterval(-journal.retention.maxAge))
            if events.count >= journal.retention.maxEvents, let oldest { start = max(start, oldest) }
        } else {
            start = max(start, launchedAt)
        }
        return start
    }

    var look: RecapLook {
        let settings = environment.settingsStore.settings
        return RecapLook(petName: settings.petName, companionName: settings.companionName, petColor: settings.petColor,
                         petAccessory: settings.petAccessory, companionAccessory: settings.companionAccessory,
                         showCompanion: settings.companionVisibility != .never, reducedMotion: environment.world.reducedMotion,
                         intensity: settings.animationIntensity, seed: environment.world.seed)
    }

    // MARK: Evening announcement

    private func checkEvening(now: Date = Date()) {
        let recapSettings = environment.settingsStore.settings.recap
        // Cheap checks first; the recap itself is only computed when the time has come.
        guard recapSettings.isAnnouncementDue(at: now, hasActivity: true) else { return }
        let today = recap(for: now, now: now)
        guard recapSettings.isAnnouncementDue(at: now, hasActivity: today.hasActivity) else { return }
        environment.settingsStore.settings.recap.lastAnnouncedDay = DailyRecap.dayKey(now)
        announce(today)
    }

    private func announce(_ recap: DailyRecap) {
        let settings = environment.settingsStore.settings
        let world = environment.world
        let names = settings.companionVisibility == .never ? settings.petName : "\(settings.petName) & \(settings.companionName)"
        world.showToast(title: "Your day with Claude is ready", detail: "\(names) made you a recap card. Open Recap in the panel.", seconds: 10)
        world.say("Your day with Claude is ready! Want to see?", speaker: .pet, duration: 6)
        world.playPet(.greet)
        world.playCompanion(.greet)
        if settings.recap.banner, !settings.pauseReactions, !NotificationPolicy.isQuiet(settings, at: Date()) {
            environment.postBanner(recap.readyBanner(petName: settings.petName, companionName: settings.companionName),
                                   category: .milestone, sessionID: nil)
        }
    }

    // MARK: Export

    /// The card as a 2× bitmap, characters at a settled moment.
    func renderImage(for recap: DailyRecap) -> NSBitmapImageRep? {
        let card = RecapCard(recap: recap, look: look, now: Date())
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        renderer.isOpaque = false
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    func copyImage(for recap: DailyRecap) -> Bool {
        guard let bitmap = renderImage(for: recap), let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = bitmap.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        return pasteboard.writeObjects([item])
    }

    func saveImage(for recap: DailyRecap) {
        guard let window, let bitmap = renderImage(for: recap), let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Recap \(DailyRecap.dayKey(recap.day)).png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url, options: .atomic)
        }
    }

    // MARK: Development

    private func registerDebugHooks() {
        guard DebugHooks.isEnabled else { return }
        environment.debug.register("recap") { [weak self] argument in
            guard let self else { return }
            switch argument {
            case "announce":
                self.announce(self.recap(for: Date()))
            case "export":
                // Writes the exported image next to the debug state.
                if let bitmap = self.renderImage(for: self.recap(for: Date())), let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: self.environment.paths.home.appendingPathComponent("debug-recap-export.png"))
                }
            case let argument where argument.hasPrefix("days:"):
                // "days:-3": the card for three days ago.
                let offset = Int(argument.dropFirst(5)) ?? 0
                self.show(day: Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date())
                self.environment.debug.capture(named: "recap-days\(offset)", after: 1.5) { [weak self] in self?.window }
            default:
                self.show()
                self.environment.debug.capture(named: "recap", after: 1.5) { [weak self] in self?.window }
            }
        }
        environment.debug.registerState("recap") { [weak self] in
            guard let self else { return [:] }
            let today = self.recap(for: Date())
            return ["sessions": today.sessions, "turns": today.turnsFinished, "tools": today.toolCalls, "streak": today.streak,
                    "streakAtLeast": today.streakIsLowerBound, "focusMinutes": today.focusMinutes, "quiet": today.isQuiet,
                    "lastAnnounced": self.environment.settingsStore.settings.recap.lastAnnouncedDay ?? NSNull()]
        }
    }
}

/// The day shown in the recap window.
@MainActor
@Observable
final class RecapModel {
    var day = Calendar.current.startOfDay(for: Date())
    /// Bumped to recompute when the window is shown again.
    var refresh = 0
}

struct RecapWindowView: View {
    let environment: AppEnvironment
    let controller: RecapController
    @State private var windowVisible = false
    @State private var copied = false

    var body: some View {
        let model = controller.model
        let now = Date()
        // Recompute when shown again or when new events arrive while the window is open.
        let _ = (model.refresh, environment.world.timeline.count)
        let recap = controller.recap(for: model.day, now: now)
        let look = controller.look
        let earliest = Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(max(1, environment.settingsStore.settings.historyRetentionDays)) * 86_400))
        let isToday = Calendar.current.isDate(model.day, inSameDayAs: now)
        VStack(spacing: 14) {
            RecapCard(recap: recap, look: look, now: now, animated: true, paused: !windowVisible)
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
            HStack(spacing: 10) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.day <= earliest)
                    .help("Previous day")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isToday)
                    .help("Next day")
                Spacer()
                Button {
                    copied = controller.copyImage(for: recap)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Image", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button { controller.saveImage(for: recap) } label: {
                    Label("Save Image…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .frame(width: RecapCard.size.width)
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 470, height: 660)
        .background(WindowVisibilityReader(visible: $windowVisible))
    }

    private func step(_ days: Int) {
        let model = controller.model
        model.day = Calendar.current.date(byAdding: .day, value: days, to: model.day) ?? model.day
    }
}

/// Settings for the evening recap (shown under the focus buddy in Settings › Fun).
struct RecapSettingsSection: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    var body: some View {
        Section("Daily recap") {
            Toggle("Tell me when my day's recap is ready", isOn: $store.settings.recap.announce)
            Picker("From", selection: $store.settings.recap.hour) {
                ForEach(12..<24) { hour in
                    Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())?
                        .formatted(date: .omitted, time: .shortened) ?? "\(hour):00").tag(hour)
                }
            }
            .disabled(!store.settings.recap.announce)
            Toggle("Also show a notification", isOn: $store.settings.recap.banner)
                .disabled(!store.settings.recap.announce)
            HStack {
                Text("Once a day, only after real Claude Code activity. Cards use your history only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Recap…") { environment.recap.show() }
            }
        }
    }
}
