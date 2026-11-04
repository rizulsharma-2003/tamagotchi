import AppKit
import SwiftUI
import TamagotchiCore

@MainActor
final class WindowManager {
    private unowned let environment: AppEnvironment
    private var settingsWindow: NSWindow?
    private var activityWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { environment.ui.settingsTab = tab }
        environment.statusItem.closePopover()
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        present(window)
    }

    func showActivity() {
        environment.statusItem.closePopover()
        let window = activityWindow ?? makeWindow(
            title: "Activity",
            size: NSSize(width: 820, height: 560),
            view: ActivityView(environment: environment),
            autosave: "MacTamagotchiActivity"
        )
        activityWindow = window
        present(window)
    }

    func showWelcome() {
        let window = welcomeWindow ?? makeWindow(
            title: "Welcome to MacTamagotchi",
            size: NSSize(width: 520, height: 560),
            view: WelcomeView(environment: environment),
            autosave: nil
        )
        window.styleMask.remove(.resizable)
        welcomeWindow = window
        present(window)
    }

    func closeWelcome() {
        welcomeWindow?.close()
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    static let settingsIdentifier = NSUserInterfaceItemIdentifier("MacTamagotchiSettings")

    /// System Settings' window: the sidebar runs the full height under the traffic lights, and the pane's
    /// name is the title in a unified toolbar.
    private func makeSettingsWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(environment: environment))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.identifier = Self.settingsIdentifier
        window.title = "MacTamagotchi Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // SwiftUI's toolbar (status pill, search) sits in a transparent title bar beside the traffic lights,
        // over the window's backdrop.
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        // The pane's glow runs up under the title bar, as on iOS; content scrolling beneath it softens away.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.setContentSize(NSSize(width: 900, height: 660))
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MacTamagotchiSettingsV3")
        if window.frame.origin == .zero { window.center() }
        return window
    }

    private func makeWindow<V: View>(title: String, size: NSSize, view: V, autosave: String?) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.setContentSize(size)
        window.minSize = NSSize(width: min(size.width, 560), height: 420)
        window.isReleasedWhenClosed = false
        if let autosave {
            window.setFrameAutosaveName(autosave)
        }
        if window.frame.origin == .zero { window.center() }
        return window
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let environment: AppEnvironment
    @State private var preview = PreviewWorld()

    var body: some View {
        VStack(spacing: 18) {
            SceneView(world: preview.world, style: .popover, visible: true)
                .frame(width: 440, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            VStack(spacing: 6) {
                Text("Meet \(environment.world.settings.petName) & \(environment.world.settings.companionName)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("A tiny friendship that lives in your menu bar.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Feature(symbol: "pawprint.fill", color: .orange, title: "\(environment.world.settings.petName) is yours",
                        text: "Pet, play and share treats any time — no Claude Code needed. It never gets sick or sad when the app is closed.")
                Feature(symbol: "sparkles", color: .teal, title: "\(environment.world.settings.companionName) joins your Claude Code sessions",
                        text: "Real hook events make Patch read, search, type, wait for you and celebrate finished turns.")
                Feature(symbol: "lock.shield.fill", color: .indigo, title: "Private by design",
                        text: "Events stay on this Mac. Prompts, code, tool input and command output are never stored or sent anywhere.")
            }
            .frame(maxWidth: 420)
            Spacer(minLength: 0)
            HStack {
                Button("Maybe Later") { finish() }
                Spacer()
                Button("Connect Claude Code…") {
                    finish()
                    environment.windows.showSettings(tab: .claude)
                }
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 420)
        }
        .padding(28)
        .frame(width: 520, height: 560)
    }

    private func finish() {
        environment.settingsStore.settings.showOnboarding = false
        environment.windows.closeWelcome()
    }

    private struct Feature: View {
        let symbol: String
        let color: Color
        let title: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(color)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// An in-memory world used only for previews; it never sees real events.
@MainActor
final class PreviewWorld {
    let world: CompanionWorld

    init(theme: OfficeTheme = .cozyDesk) {
        var settings = AppSettings()
        settings.companionVisibility = .always
        settings.theme = theme
        settings.historyRetentionDays = 0
        let journal = EventJournal(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview.jsonl"), retention: .init(days: 0))
        world = CompanionWorld(journal: journal, achievements: AchievementEngine(state: ProgressState()),
                               settingsStore: SettingsStore(fileURL: nil, initial: settings))
    }
}
