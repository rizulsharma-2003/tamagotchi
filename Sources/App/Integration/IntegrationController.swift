import Foundation
import Observation
import TamagotchiCore
import TamagotchiWire

/// Guided Claude Code connection: detection, consent, install, verification, removal.
@MainActor
@Observable
final class IntegrationController {
    let paths: BridgePaths
    let settingsFile: URL
    /// Extra environment baked into hook commands, so an isolated app instance
    /// (MACTAMAGOTCHI_HOME) receives the events from its own hooks.
    let hookEnvironment: [String: String]

    private(set) var installation: ClaudeInstallation?
    private(set) var searched = false
    private(set) var compatibility: HookCompatibility.Report?
    private(set) var inspection: ClaudeHookInstaller.Inspection?
    private(set) var busy = false
    private(set) var lastMessage: String?
    private(set) var lastError: String?
    private(set) var lastBackup: URL?
    private(set) var pingResult: String?

    @ObservationIgnored weak var world: CompanionWorld?

    init(paths: BridgePaths, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        if let override = environment["MACTAMAGOTCHI_CLAUDE_SETTINGS"], !override.isEmpty {
            settingsFile = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            settingsFile = ClaudeHookInstaller.defaultSettingsFile
        }
        if let home = environment[BridgePaths.homeEnvironmentKey], !home.isEmpty {
            hookEnvironment = [BridgePaths.homeEnvironmentKey: paths.home.path]
        } else {
            hookEnvironment = [:]
        }
    }

    var installer: ClaudeHookInstaller {
        ClaudeHookInstaller(settingsFile: settingsFile, backupDirectory: paths.backupsDirectory,
                            helperPath: paths.installedHelper.path, environment: hookEnvironment)
    }

    /// Events to install: what the installed Claude Code supports.
    var events: [ClaudeHookEvent] {
        compatibility?.supported ?? ClaudeHookEvent.allCases.filter(\.isCore)
    }

    var isInstalled: Bool { inspection?.status == .installed }

    var hasAnyInstall: Bool {
        guard let status = inspection?.status else { return false }
        if case .notInstalled = status { return false }
        if case .unreadable = status { return false }
        return true
    }

    /// The helper binary shipped with the app (inside the bundle, or next to the
    /// executable for development builds).
    var bundledHelper: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(HelperInfo.executableName)"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(HelperInfo.executableName),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Refresh

    func refresh() async {
        let (installation, report) = await Task.detached(priority: .utility) {
            let installation = ClaudeCodeLocator.locate()
            return (installation, HookCompatibility.detect(installation: installation))
        }.value
        self.installation = installation
        self.compatibility = report
        self.searched = true
        _ = updateHelper()
        inspect()
    }

    func inspect() {
        inspection = installer.inspect(events: events)
        publish()
    }

    private func publish() {
        guard let world else { return }
        let claude: ClaudeAvailability = installation.map { .found(version: $0.version) } ?? (searched ? .notFound : .unknown)
        guard let inspection else {
            world.updateIntegration(.unknown, claude: claude)
            return
        }
        if inspection.managedHooksOnly {
            world.updateIntegration(.blocked("Your organization only allows managed hooks"), claude: claude)
            return
        }
        if inspection.hooksDisabled {
            world.updateIntegration(.blocked("Hooks are disabled in Claude Code settings (disableAllHooks)"), claude: claude)
            return
        }
        switch inspection.status {
        case .notInstalled: world.updateIntegration(.notInstalled, claude: claude)
        case .installed: world.updateIntegration(.installed, claude: claude)
        case .needsUpdate(let missing, let outdated):
            world.updateIntegration(.needsUpdate((missing + outdated).joined(separator: ", ")), claude: claude)
        case .unreadable(let reason): world.updateIntegration(.error(reason), claude: claude)
        }
    }

    /// Copies the helper to a stable location so hooks keep working if the app moves.
    @discardableResult
    func updateHelper() -> Bool {
        guard let source = bundledHelper else { return FileManager.default.isExecutableFile(atPath: paths.installedHelper.path) }
        let target = paths.installedHelper
        guard let data = try? Data(contentsOf: source) else { return false }
        if let existing = try? Data(contentsOf: target), existing == data { return true }
        BridgePaths.ensurePrivateDirectory(paths.binDirectory)
        let temporary = paths.binDirectory.appendingPathComponent(".\(HelperInfo.executableName).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o755]) else { return false }
        removexattr(temporary.path, "com.apple.quarantine", 0)
        guard rename(temporary.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }

    // MARK: Actions

    func preview() -> String? {
        try? installer.preview(events: events)
    }

    func connect() async {
        busy = true
        defer { busy = false }
        lastError = nil
        lastMessage = nil
        guard updateHelper() else {
            lastError = "Could not install the hook helper into \(paths.binDirectory.path)."
            return
        }
        do {
            let result = try installer.install(events: events)
            lastBackup = result.backup
            if result.changed {
                lastMessage = "Connected. \(result.events.count) hook events were added"
                    + (result.backup.map { "; your previous settings are backed up at \($0.path)" } ?? "")
                    + ". New Claude Code sessions will report events (restart sessions that are already open)."
            } else {
                lastMessage = "Already connected — nothing needed to change."
            }
        } catch {
            lastError = String(describing: error)
        }
        inspect()
        await testConnection()
    }

    func disconnect() async {
        busy = true
        defer { busy = false }
        lastError = nil
        do {
            let result = try installer.uninstall()
            lastBackup = result.backup
            lastMessage = result.changed
                ? "Disconnected. Only MacTamagotchi's hook entries were removed" + (result.backup.map { "; backup at \($0.path)" } ?? "") + "."
                : "No MacTamagotchi hooks were installed."
        } catch {
            lastError = String(describing: error)
        }
        inspect()
    }

    /// Runs the installed helper's `ping` against the live bridge.
    func testConnection() async {
        let helper = paths.installedHelper
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            pingResult = "Hook helper not installed yet."
            return
        }
        let environment = hookEnvironment
        let output = await Task.detached(priority: .userInitiated) { () -> String in
            let process = Process()
            process.executableURL = helper
            process.arguments = ["ping"]
            var env = ProcessInfo.processInfo.environment
            env.merge(environment) { _, new in new }
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return "Could not run the helper: \(error.localizedDescription)" }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        pingResult = output
    }

    func clearMessages() {
        lastMessage = nil
        lastError = nil
    }
}
