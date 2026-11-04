// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTamagotchi",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "MacTamagotchi", targets: ["MacTamagotchi"]),
        .executable(name: "mactamagotchi-hook", targets: ["mactamagotchi-hook"]),
        .library(name: "TamagotchiCore", targets: ["TamagotchiCore"]),
        .library(name: "TamagotchiWire", targets: ["TamagotchiWire"]),
    ],
    targets: [
        // Wire format, payload sanitizer, socket client and spool shared by the
        // hook helper and the app. Foundation-only so the helper stays tiny.
        .target(name: "TamagotchiWire"),

        // The command Claude Code hooks invoke. Reads the hook payload from stdin,
        // keeps only a minimal sanitized subset, forwards it over the local socket
        // (or spools it when the app is not running) and always exits 0 silently.
        .executableTarget(
            name: "mactamagotchi-hook",
            dependencies: ["TamagotchiWire"],
            path: "Sources/HookHelper"
        ),

        // Everything testable without UI: event model, validation, sessions,
        // animation state machines, interaction scheduling, hook installer, journal,
        // settings, notification policy and achievements.
        .target(
            name: "TamagotchiCore",
            dependencies: ["TamagotchiWire"]
        ),

        // The menu-bar app (AppKit + SwiftUI).
        .executableTarget(
            name: "MacTamagotchi",
            dependencies: ["TamagotchiCore"],
            path: "Sources/App"
        ),

        .testTarget(
            name: "TamagotchiCoreTests",
            dependencies: ["TamagotchiCore", "TamagotchiWire"]
        ),
    ]
)
