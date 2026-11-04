import SwiftUI
import TamagotchiCore

/// How the den (the notch) looks on the bar right now: where the housing cuts Mochi off, and
/// whether Mochi naps inside (a few z's drift out of the edge, with a faint warm glow).
struct MenuBarDenLook {
    /// The open side of the housing's edge, in layout points: nothing is drawn outside it.
    var visible: CGRect
    var edgeX: CGFloat
    /// +1 when the housing lies to the right of the edge.
    var inward: CGFloat
    /// 0…1: Mochi is asleep in there (fades in as it settles).
    var napping: Double
}

/// The den's part of the menu-bar stage, drawn after Mochi in the same sprites.
enum MenuBarDen {
    static func look(_ snapshot: MenuBarSnapshot, layout: MenuBarLayout, time: TimeInterval) -> MenuBarDenLook? {
        guard !layout.isStage, let den = snapshot.roamer.zone?.den else { return nil }
        let edge = layout.local(den.edgeX)
        let far: CGFloat = 4_000
        let visible = den.inward < 0
            ? CGRect(x: edge, y: -far, width: far, height: 2 * far)
            : CGRect(x: edge - far, y: -far, width: far, height: 2 * far)
        let roam = snapshot.roamer.sample(at: time)
        var napping = 0.0
        if roam.activity == .denNap || roam.activity == .denPeek, roam.animation == .curl || roam.animation == .sleep,
           den.depth(of: roam.x) > 2 {
            napping = Ease.smooth(Ease.segment(roam.elapsed, 0.4, 1.8))
        }
        return MenuBarDenLook(visible: visible, edgeX: edge, inward: CGFloat(den.inward), napping: napping)
    }

    /// Where the z's and the glow may draw (layout points).
    static func decorationRect(_ look: MenuBarDenLook, layout: MenuBarLayout) -> CGRect? {
        guard look.napping > 0.01 else { return nil }
        let width: CGFloat = 26
        let x = look.inward < 0 ? look.edgeX : look.edgeX - width
        return CGRect(x: x, y: 0, width: width, height: layout.size.height)
    }

    static func draw(_ look: MenuBarDenLook, layout: MenuBarLayout, time: TimeInterval, dark: Bool, reduced: Bool, in g: GraphicsContext) {
        guard look.napping > 0.01 else { return }
        let out = -look.inward
        let mouth = CGPoint(x: look.edgeX, y: layout.baseline - layout.petHeight * 0.42)
        // A faint warm glow spilling out of the edge, breathing slowly.
        let breath = reduced ? 1 : 0.85 + 0.15 * sin(time * 1.3)
        let warm = Color(hex: 0xFFC37A)
        let radius: CGFloat = 10
        g.fill(.ellipse(mouth, radius * 2, radius * 1.6),
               with: .radialGradient(Gradient(colors: [warm.opacity((dark ? 0.32 : 0.24) * look.napping * breath), warm.opacity(0)]),
                                     center: mouth, startRadius: 0.5, endRadius: radius))
        // Tiny z's drifting out now and then.
        let ink = dark ? Color(hex: 0xEDE7F6) : Color(hex: 0x5E5070)
        for index in 0..<3 {
            let p = reduced ? Double(index) / 3 + 0.2 : Ease.fract(time / 3.4 + Double(index) / 3)
            let x = mouth.x + out * (2.5 + 9 * CGFloat(p))
            let y = max(3, mouth.y - 2 - 8 * CGFloat(p))
            var z = g
            z.opacity = (reduced ? 0.8 : sin(.pi * p)) * look.napping
            z.text("z", at: CGPoint(x: x, y: y), size: 3.6 + 2.2 * CGFloat(p), weight: .heavy, color: ink)
        }
    }

    /// Change detection for the den's part of a sprite.
    static func signature(_ look: MenuBarDenLook?, time: TimeInterval) -> [Int32] {
        guard let look else { return [0] }
        var s = PoseSignature()
        s.add(1)
        s.add(Double(look.edgeX), 0.25)
        s.add(look.napping, 0.05)
        if look.napping > 0.01 { s.add(time, 1.0 / 12) }
        return s.values
    }
}
