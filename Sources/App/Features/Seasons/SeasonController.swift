import AppKit
import Observation
import SwiftUI
import TamagotchiCore

/// Holidays and seasons: decorations, costumes and treats for the days that matter.
@MainActor
final class SeasonController {
    private unowned let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }
    private var hourly: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastEvent: SeasonalEvent?
    private var lastSettings: SeasonalSettings?
    private var greeted: Set<String> = []
    /// A greeting toast waiting for the popover to open, so it's actually seen.
    private var pendingToast: (title: String, detail: String)?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var storeURL: URL { environment.paths.home.appendingPathComponent("seasons.json") }

    func start() {
        greeted = loadGreeted()
        lastSettings = world.settings.seasonal
        refresh(greet: false)
        // Let launch settle (onboarding, the companion arriving) before greeting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.refresh() }
        scheduleHourly()
        let refreshNow: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: refreshNow))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
                                                                          using: refreshNow))
        observeWorld()
        registerDebugHooks()
    }

    /// Re-reads the calendar: updates the treat style, refreshes the scene when the day's event changes
    /// and greets an event the first time it's seen.
    func refresh(greet: Bool = true) {
        let event = SeasonDecor.currentEvent(world: world)
        SeasonalTreats.style = SeasonalTreats.Style(event)
        if event != lastEvent {
            lastEvent = event
            SeasonState.shared.revision &+= 1
        }
        guard greet, let event else { return }
        let key = SeasonCalendar.occasionKey(event, on: Date())
        guard !greeted.contains(key) else { return }
        greeted.insert(key)
        saveGreeted()
        celebrate(event)
    }

    /// The once-per-occasion hello: a speech bubble, a happy hop and a note in the popover.
    func celebrate(_ event: SeasonalEvent) {
        let greeting = SeasonDecor.greeting(for: event, settings: world.settings, adopted: world.progress.firstMetAt)
        world.say(greeting.line)
        world.playPet(greeting.animation)
        world.playCompanion(.celebrate)
        // The note waits until the popover is open (and not covering the decorating tray).
        pendingToast = (greeting.title, greeting.detail)
        showPendingToast()
    }

    private func showPendingToast() {
        guard environment.ui.popoverVisible, !environment.roomEditor.isEditing, let toast = pendingToast else { return }
        pendingToast = nil
        world.showToast(title: toast.title, detail: toast.detail, seconds: 7)
    }

    // MARK: Timing and observation

    /// Wakes on every hour (and so at midnight), sleeping in between.
    private func scheduleHourly() {
        hourly?.invalidate()
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0, second: 2), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(3600)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleHourly()
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        hourly = timer
    }

    /// Seasonal settings (a birthday entered for today), the adoption date and the popover opening.
    private func observeWorld() {
        withObservationTracking {
            _ = world.settings.seasonal
            _ = world.progress.firstMetAt
            _ = environment.ui.popoverVisible
            _ = environment.roomEditor.isEditing
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.worldChanged()
                self?.observeWorld()
            }
        }
    }

    private func worldChanged() {
        let seasonal = world.settings.seasonal
        if seasonal != lastSettings {
            lastSettings = seasonal
            refresh()
        }
        showPendingToast()
    }

    /// Development aid: the Holidays and Room settings sections on their own, captured to
    /// `<home>/debug-season-settings.png` (the Fun tab is too long to capture whole).
    private func previewSettings() {
        let form = Form {
            RoomSettingsSection(environment: environment)
            SeasonalSettingsSection(environment: environment)
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 470)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470), styleMask: [.titled, .closable], backing: .buffered,
                              defer: false)
        window.title = "Seasons and Room (preview)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: form)
        window.center()
        window.orderFrontRegardless()
        environment.debug.capture(named: "season-settings", after: 1) { window }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { window.close() }
    }

    // MARK: Persistence

    private struct Store: Codable {
        var greeted: [String]
    }

    private func loadGreeted() -> Set<String> {
        guard let data = try? Data(contentsOf: storeURL), let store = try? JSONDecoder().decode(Store.self, from: data) else { return [] }
        return Set(store.greeted)
    }

    private func saveGreeted() {
        // Keep the file tiny: occasions from the last couple of years are plenty.
        let year = Calendar.current.component(.year, from: Date())
        let recent = greeted.filter { key in Int(key.split(separator: "-").last ?? "").map { $0 >= year - 1 } ?? false }
        guard let data = try? JSONEncoder().encode(Store(greeted: recent.sorted())) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Debug

    private func registerDebugHooks() {
        // "season:<event>" shows an event now, "season:off" none, "season:auto" the calendar again;
        // "season:greet" replays the greeting for whatever is showing.
        environment.debug.register("season") { [weak self] argument in
            guard let self else { return }
            switch argument {
            case "auto", "": SeasonState.shared.override = .calendar
            case "off": SeasonState.shared.override = .off
            case "greet":
                if let event = SeasonDecor.currentEvent(world: self.world) { self.celebrate(event) }
            case "settings":
                self.previewSettings()
            default:
                if let event = SeasonalEvent(rawValue: argument) { SeasonState.shared.override = .event(event) }
            }
            self.refresh()
        }
        environment.debug.registerState("season") { [weak self] in
            guard let self else { return [:] }
            let event = SeasonDecor.currentEvent(world: self.world)
            return ["event": event?.rawValue ?? "none", "override": "\(SeasonState.shared.override)",
                    "treat": "\(SeasonalTreats.style)", "greeted": self.greeted.sorted()]
        }
    }
}

struct SeasonalSettingsSection: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    var body: some View {
        let seasonal = store.settings.seasonal
        Section("Holidays") {
            Toggle("Celebrate holidays with decorations, costumes and treats", isOn: $store.settings.seasonal.enabled)
            Toggle("A little decoration beside the bed in the menu bar", isOn: $store.settings.seasonal.decorateMenuBar)
                .disabled(!seasonal.enabled)
            HStack {
                Text("Your birthday")
                Spacer()
                Picker("Month", selection: month) {
                    Text("Not set").tag(0)
                    ForEach(1...12, id: \.self) { Text(Self.monthNames[$0 - 1]).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Day", selection: day) {
                    ForEach(1...Self.daysIn(month: seasonal.birthdayMonth ?? 1), id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(seasonal.birthdayMonth == nil)
                if seasonal.birthdayMonth != nil {
                    Button("Clear") {
                        store.settings.seasonal.birthdayMonth = nil
                        store.settings.seasonal.birthdayDay = nil
                    }
                }
            }
            .disabled(!seasonal.enabled)
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var month: Binding<Int> {
        Binding {
            store.settings.seasonal.birthdayMonth ?? 0
        } set: { value in
            if value == 0 {
                store.settings.seasonal.birthdayMonth = nil
                store.settings.seasonal.birthdayDay = nil
            } else {
                store.settings.seasonal.birthdayMonth = value
                store.settings.seasonal.birthdayDay = min(store.settings.seasonal.birthdayDay ?? 1, Self.daysIn(month: value))
            }
        }
    }

    private var day: Binding<Int> {
        Binding { store.settings.seasonal.birthdayDay ?? 1 } set: { store.settings.seasonal.birthdayDay = $0 }
    }

    /// What's on now and what's next, e.g. "Halloween until 1 November. Next: Diwali from 5 November."
    private var statusLine: String {
        let settings = store.settings.seasonal
        guard settings.enabled else { return "Decorations are off." }
        let pet = store.settings.petName
        let adopted = environment.world.progress.firstMetAt
        let now = Date()
        let format = Date.FormatStyle().day().month(.wide)
        var parts: [String] = []
        if let event = SeasonCalendar.event(on: now, settings: settings, mochiBirthday: adopted) {
            let until = SeasonCalendar.lastDay(of: event, from: now, settings: settings, mochiBirthday: adopted)
            let name = SeasonDecor.title(event, petName: pet)
            if let until, !Calendar.current.isDate(until, inSameDayAs: now) {
                parts.append("\(name) until \(until.formatted(format)).")
            } else {
                parts.append("\(name) today!")
            }
        }
        if let next = SeasonCalendar.nextEvent(after: now, settings: settings, mochiBirthday: adopted) {
            parts.append("Next: \(SeasonDecor.title(next.event, petName: pet)) from \(next.starts.formatted(format)).")
        }
        if let adopted {
            parts.append("\(pet)'s birthday is \(adopted.formatted(format)), the day you met.")
        }
        return parts.isEmpty ? "Nothing to celebrate for a while." : parts.joined(separator: " ")
    }

    private static let monthNames = DateFormatter().monthSymbols ?? (1...12).map { "\($0)" }

    private static func daysIn(month: Int) -> Int {
        switch month {
        case 2: return 29
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}
