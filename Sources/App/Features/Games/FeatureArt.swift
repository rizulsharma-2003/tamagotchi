import AppKit
import SwiftUI
import TamagotchiCore

/// Windows for the fun features (games, recap), following `WindowManager`'s conventions.
@MainActor
enum FeatureWindow {
    static func make<V: View>(title: String, size: NSSize, view: V, autosave: String) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(autosave)
        if window.frame.origin == .zero { window.center() }
        return window
    }

    /// LSUIElement app: activate so the window comes to the front with focus. Debug runs
    /// (automated captures) bring it forward without taking the keyboard from other apps.
    static func present(_ window: NSWindow, environment: AppEnvironment) {
        environment.statusItem.closePopover()
        if DebugHooks.isEnabled {
            window.orderFrontRegardless()
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Small drawing helpers shared by the games and the recap card. Characters are always
/// drawn through `PetRenderer.draw` and `CompanionRenderer.draw`.
enum FeatureArt {
    /// The companion standing on its own: no laptop or desk.
    static func standalone(_ pose: CompanionPose) -> CompanionPose {
        var pose = pose
        pose.laptop.visible = false
        pose.laptop.openness = 0
        pose.laptop.screen = .off
        pose.reach = 0
        return pose
    }

    static func drawCompanion(_ pose: CompanionPose, in g: GraphicsContext, at point: CGPoint, scale: CGFloat,
                              accessory: Accessory?, dark: Bool) {
        CompanionRenderer.draw(standalone(pose), in: g, at: point, scale: scale, accessory: accessory, dark: dark,
                               workstation: false) { _ in }
    }

    /// A treat from the game, centred on `point` (about `size` points across).
    static func drawTreat(_ kind: CatchGame.TreatKind, in g: GraphicsContext, at point: CGPoint, size: CGFloat, rotation: Double,
                          time: Double) {
        var t = g
        t.translateBy(x: point.x, y: point.y)
        switch kind {
        case .cookie:
            ItemRenderer.cookie(t, size: size, spin: rotation)
        case .fish:
            t.rotate(by: .radians(0.35 * sin(rotation)))
            t.scaleBy(x: size / 20, y: size / 20)
            ItemRenderer.fish(t, bites: 0)
        case .berry:
            t.rotate(by: .radians(0.4 * sin(rotation * 0.7)))
            ItemRenderer.berry(t, size: size / 13)
        case .golden:
            // A warm glow and two twinkles around a golden cookie.
            let pulse = 0.85 + 0.15 * sin(time * 6)
            t.fill(.ellipse(.zero, size * 2.3 * pulse, size * 2.3 * pulse),
                   with: .radialGradient(Gradient(colors: [Color(hex: 0xFFE27A).opacity(0.75), Color(hex: 0xFFE27A).opacity(0)]),
                                         center: .zero, startRadius: size * 0.2, endRadius: size * 1.15 * pulse))
            let cookie = Path.ellipse(.zero, size * 1.05, size * 1.05)
            t.fill(cookie, with: .radialGradient(Gradient(colors: [Color(hex: 0xFFF1A8), Color(hex: 0xF5B83D)]),
                                                 center: CGPoint(x: -size * 0.15, y: -size * 0.18), startRadius: 0, endRadius: size * 0.6))
            t.stroke(cookie, Color(hex: 0xC98A1E), max(1, size / 11))
            t.fill(.star(.zero, radius: size * 0.28), Color.white.opacity(0.9))
            for index in 0..<2 {
                let angle = time * 2.2 + Double(index) * .pi
                let p = CGPoint(x: CGFloat(cos(angle)) * size * 0.85, y: CGFloat(sin(angle)) * size * 0.85)
                t.fill(.sparkle(p, radius: size * 0.22 * CGFloat(0.6 + 0.4 * abs(sin(time * 4 + Double(index))))), Color.white)
            }
        }
    }

    static func drawCenteredText(_ text: String, in g: GraphicsContext, at point: CGPoint, size: CGFloat, weight: Font.Weight = .heavy,
                                 color: Color, outline: Color? = nil) {
        if let outline {
            for (dx, dy) in [(-1.2, 0.0), (1.2, 0.0), (0.0, -1.2), (0.0, 1.2)] {
                g.text(text, at: CGPoint(x: point.x + dx, y: point.y + dy), size: size, weight: weight, color: outline)
            }
        }
        g.text(text, at: point, size: size, weight: weight, color: color)
    }
}

/// Sounds for the games: only with sound on and outside quiet mode/hours.
@MainActor
enum FeatureSound {
    static func play(_ cue: SoundCue, environment: AppEnvironment) {
        let settings = environment.settingsStore.settings
        guard settings.soundEnabled, !NotificationPolicy.isQuiet(settings, at: Date()) else { return }
        environment.play(cue)
    }
}
