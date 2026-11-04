// swift-tools-version: 6.0
import PackageDescription

// Exports poses from the Swift animation code (TamagotchiCore) as JSON, so the Flutter
// port of the renderers can be checked against the Swift snapshots and the gallery can
// play the animations before the pose evaluators themselves are ported.
//
//   cd flutter/tools/pose_export && swift run pose_export ../..
let package = Package(
    name: "pose_export",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "MacTamagotchi", path: "../../..")],
    targets: [
        .executableTarget(
            name: "pose_export",
            dependencies: [
                .product(name: "TamagotchiCore", package: "MacTamagotchi"),
                .product(name: "TamagotchiWire", package: "MacTamagotchi"),
            ],
            path: "Sources"
        ),
    ]
)
