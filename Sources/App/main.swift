import AppKit
import TamagotchiWire

let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// Development tools.
if let directory = argument(after: "--render-snapshots") {
    MainActor.assumeIsolated { SnapshotRenderer.render(to: URL(fileURLWithPath: directory)) }
    exit(0)
}
if let directory = argument(after: "--render-strips") {
    MainActor.assumeIsolated { AnimationStrips.render(to: URL(fileURLWithPath: directory)) }
    exit(0)
}
if let directory = argument(after: "--render-menubar") {
    MainActor.assumeIsolated { MenuBarStageSnapshots.render(to: URL(fileURLWithPath: directory)) }
    exit(0)
}
if let directory = argument(after: "--render-live-activity") {
    MainActor.assumeIsolated { LiveActivityArt.render(to: URL(fileURLWithPath: directory)) }
    exit(0)
}
if let directory = argument(after: "--render-listening") {
    MainActor.assumeIsolated { ListeningStrip.render(to: URL(fileURLWithPath: directory)) }
    exit(0)
}
if let directory = argument(after: "--render-iconset") {
    MainActor.assumeIsolated { IconRenderer.renderIconset(to: URL(fileURLWithPath: directory)) }
    exit(0)
}

// `--home <dir>` runs an isolated instance with its own data, socket and hooks.
if let home = argument(after: "--home") {
    setenv(BridgePaths.homeEnvironmentKey, (home as NSString).expandingTildeInPath, 1)
}

if let command = argument(after: "--integration") {
    exit(MainActor.assumeIsolated { HeadlessCommands.run(command) })
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
