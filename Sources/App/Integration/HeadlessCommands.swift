import AppKit
import TamagotchiCore
import TamagotchiWire

/// `MacTamagotchi --integration status|connect|disconnect|preview`
///
/// Runs the same installer as the Settings window, without UI — for scripted
/// setups and end-to-end tests. Honors MACTAMAGOTCHI_HOME and
/// MACTAMAGOTCHI_CLAUDE_SETTINGS so it can operate on copies.
@MainActor
enum HeadlessCommands {
    static func run(_ command: String) -> Int32 {
        let paths = BridgePaths.resolve()
        let controller = IntegrationController(paths: paths)
        var exitCode: Int32 = 0
        var finished = false
        Task {
            await controller.refresh()
            print("Claude Code: \(controller.installation.map { "\($0.version ?? "?") at \($0.executable.path)" } ?? "not found")")
            if let report = controller.compatibility {
                print("Events (\(report.method)): \(report.supported.map(\.rawValue).joined(separator: ", "))")
                if !report.unsupported.isEmpty { print("Not available: \(report.unsupported.map(\.rawValue).joined(separator: ", "))") }
            }
            print("Settings file: \(controller.settingsFile.path)")
            switch command {
            case "status":
                break
            case "preview":
                print(controller.preview() ?? "(could not compute changes)")
            case "connect":
                await controller.connect()
            case "disconnect":
                await controller.disconnect()
            default:
                print("usage: MacTamagotchi --integration status|preview|connect|disconnect")
                exitCode = 64
            }
            if let message = controller.lastMessage { print(message) }
            if let error = controller.lastError {
                print("Error: \(error)")
                exitCode = 1
            }
            if let inspection = controller.inspection {
                print("Status: \(inspection.status)")
                print("Installed events: \(inspection.installedEvents.joined(separator: ", "))")
                print("Other hooks preserved: \(inspection.otherHookCount)")
            }
            if let ping = controller.pingResult { print("Ping: \(ping)") }
            finished = true
        }
        while !finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return exitCode
    }
}
