import SwiftUI
import TamagotchiCore

/// The fun features: explore, games, focus, recap, clips and decorating.
struct FunRow: View {
    let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }

    var body: some View {
        VStack(spacing: 6) {
            FocusPopoverRow(environment: environment)
            HStack(spacing: 5) {
                if world.settings.assistant.enabled {
                    FunButton(title: "Ask", symbol: "wand.and.stars") { environment.assistant.showPanel() }
                        .help("Ask \(world.settings.petName) to do something on your Mac")
                }
                if world.adventureActive {
                    FunButton(title: "Home", symbol: "house", highlighted: true) { environment.adventure.endAdventure() }
                        .help("Call \(world.settings.petName) back to the menu bar")
                } else {
                    FunButton(title: "Explore", symbol: "figure.walk") { environment.adventure.beginAdventure() }
                        .help("\(world.settings.petName) leaves the menu bar to explore your desktop")
                }
                FunButton(title: "Games", symbol: "gamecontroller") { environment.games.show() }
                FunButton(title: world.focus == nil ? "Focus" : "Stop", symbol: "timer") { environment.focus.toggle() }
                    .help("A focus timer: \(world.settings.petName) naps while you work and wakes you for breaks")
                FunButton(title: "Recap", symbol: "calendar") { environment.recap.show() }
                FunButton(title: "Clip", symbol: "film") { environment.shareClip.captureClip() }
                    .help("Save a 5-second GIF of the scene")
                FunButton(title: "Decorate", symbol: "sofa", highlighted: environment.roomEditor.isEditing) {
                    environment.roomEditor.toggleEditing()
                }
            }
        }
    }
}

private struct FunButton: View {
    let title: String
    let symbol: String
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipButtonStyle(highlighted: highlighted))
        .accessibilityLabel(title)
    }
}
