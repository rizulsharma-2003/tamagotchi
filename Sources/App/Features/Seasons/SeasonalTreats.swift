import SwiftUI
import TamagotchiCore

/// The treat Mochi gets depends on the season: candy at Halloween, a laddoo at Diwali,
/// gingerbread at Christmas, cake on birthdays. Drawn in place of the cookie, centered on the origin.
enum SeasonalTreats {
    enum Style: Equatable {
        case cookie, candy, laddoo, gingerbread, cakeSlice, heartCookie

        init(_ event: SeasonalEvent?) {
            switch event {
            case .halloween?: self = .candy
            case .diwali?: self = .laddoo
            case .christmas?: self = .gingerbread
            case .userBirthday?, .mochiBirthday?: self = .cakeSlice
            case .valentines?: self = .heartCookie
            case .newYear?, nil: self = .cookie
            }
        }
    }

    /// Kept up to date by the season controller (main thread); read while drawing.
    nonisolated(unsafe) static var style: Style = .cookie

    static func draw(_ g: GraphicsContext, size: CGFloat, spin: Double) {
        draw(style, in: g, size: size, spin: spin)
    }

    static func draw(_ style: Style, in g: GraphicsContext, size: CGFloat, spin: Double) {
        let k = size / 12
        var t = g
        t.scaleBy(x: k, y: k)
        switch style {
        case .cookie: ItemRenderer.cookie(g, size: size, spin: spin, seasonal: false)
        case .candy: candy(t, spin: spin)
        case .laddoo: laddoo(t, spin: spin)
        case .gingerbread: gingerbread(t, spin: spin)
        case .cakeSlice: cakeSlice(t)
        case .heartCookie: heartCookie(t, spin: spin)
        }
    }

    /// A wrapped sweet: a striped orange-and-purple candy with twisted ends. Rolls with `spin`.
    static func candy(_ g: GraphicsContext, spin: Double) {
        var c = g
        c.rotate(by: .radians(spin * 0.6))
        let wrapper = Color(hex: 0xFF9C3F)
        let edge = Color(hex: 0xB9531A)
        for side in [-1.0, 1.0] {
            var twist = Path()
            twist.move(to: CGPoint(x: side * 3.6, y: 0))
            twist.addLine(to: CGPoint(x: side * 7.2, y: -3.2))
            twist.addQuadCurve(to: CGPoint(x: side * 7.2, y: 3.2), control: CGPoint(x: side * 6.2, y: 0))
            twist.closeSubpath()
            c.fill(twist, Color(hex: 0x9A6BE0))
            c.stroke(twist, Color(hex: 0x5E3E9C), 0.7)
        }
        let body = Path.ellipse(.zero, 9, 7.4)
        c.fill(body, wrapper)
        var stripes = c
        stripes.clip(to: body)
        for x in [-3.0, 0.4, 3.8] {
            stripes.fill(Path(CGRect(x: x - 0.8, y: -4, width: 1.6, height: 8)).applying(CGAffineTransform(a: 1, b: 0, c: -0.45, d: 1, tx: 0, ty: 0)),
                         Color(hex: 0x9A6BE0))
        }
        c.stroke(body, edge, 0.8)
        c.fill(.ellipse(CGPoint(x: -1.6, y: -1.8), 3, 1.6), Color.white.opacity(0.6))
    }

    /// A round, golden laddoo with a grainy texture and a fleck of pistachio.
    static func laddoo(_ g: GraphicsContext, spin: Double) {
        let ball = Path.ellipse(.zero, 11, 11)
        g.fill(ball, with: .radialGradient(Gradient(colors: [Color(hex: 0xFFC65C), Color(hex: 0xE8901F)]),
                                           center: CGPoint(x: -1.8, y: -2), startRadius: 0, endRadius: 7.5))
        var grains = g
        grains.clip(to: ball)
        grains.rotate(by: .radians(spin))
        for index in 0..<14 {
            let angle = Double(index) * 2.4
            let r = 1.3 + Double(index % 4) * 1.05
            grains.fill(.ellipse(CGPoint(x: cos(angle) * r, y: sin(angle) * r), 1.1, 0.9),
                        index % 3 == 0 ? Color(hex: 0xFFE3A3) : Color(hex: 0xC97416).opacity(0.7))
        }
        grains.fill(.ellipse(CGPoint(x: 1.6, y: -2.6), 1.8, 1.2), Color(hex: 0x8CC152))
        g.stroke(ball, Color(hex: 0xB86B12), 0.8)
        g.fill(.ellipse(CGPoint(x: -2, y: -2.6), 2.6, 1.6), Color.white.opacity(0.5))
    }

    /// A little gingerbread person with icing trim and buttons.
    static func gingerbread(_ g: GraphicsContext, spin: Double) {
        var c = g
        c.rotate(by: .radians(sin(spin) * 0.35))
        let limbs: [(CGPoint, CGPoint)] = [(CGPoint(x: -2.4, y: -1.4), CGPoint(x: -5.8, y: 0.8)), (CGPoint(x: 2.4, y: -1.4), CGPoint(x: 5.8, y: 0.8)),
                                           (CGPoint(x: -1.7, y: 3), CGPoint(x: -2.8, y: 6.2)), (CGPoint(x: 1.7, y: 3), CGPoint(x: 2.8, y: 6.2))]
        let head = Path.ellipse(CGPoint(x: 0, y: -4.2), 6, 6)
        let torso = Path.roundedRect(CGRect(x: -3.4, y: -2.6, width: 6.8, height: 6.6), 2.4)
        // Outline first, then each part filled on its own so overlaps stay solid.
        let edge = Color(hex: 0x8A4F22)
        for (a, b) in limbs { c.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, edge, 4.4) }
        c.stroke(head, edge, 1.4)
        c.stroke(torso, edge, 1.4)
        let dough = Color(hex: 0xC27A3E)
        for (a, b) in limbs { c.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, dough, 3) }
        c.fill(head, dough)
        c.fill(torso, dough)
        for (a, b) in limbs {
            let tip = CGPoint(x: a.x + (b.x - a.x) * 0.8, y: a.y + (b.y - a.y) * 0.8)
            let dx = (b.y - a.y) * 0.18, dy = -(b.x - a.x) * 0.18
            c.stroke(Path { $0.move(to: CGPoint(x: tip.x - dx, y: tip.y - dy)); $0.addLine(to: CGPoint(x: tip.x + dx, y: tip.y + dy)) },
                     Color.white.opacity(0.9), 0.5)
        }
        c.fill(.ellipse(CGPoint(x: -1.1, y: -4.6), 0.9, 0.9), Color(hex: 0x3B2416))
        c.fill(.ellipse(CGPoint(x: 1.1, y: -4.6), 0.9, 0.9), Color(hex: 0x3B2416))
        var smile = Path()
        smile.move(to: CGPoint(x: -1.1, y: -3))
        smile.addQuadCurve(to: CGPoint(x: 1.1, y: -3), control: CGPoint(x: 0, y: -2.1))
        c.stroke(smile, Color.white, 0.6)
        c.fill(.ellipse(CGPoint(x: 0, y: -0.6), 1.2, 1.2), Color(hex: 0xFF6B6B))
        c.fill(.ellipse(CGPoint(x: 0, y: 1.8), 1.2, 1.2), Color(hex: 0x7FD6C2))
    }

    /// A wedge of birthday cake with a strawberry on top. Cake doesn't roll, so `spin` is ignored.
    static func cakeSlice(_ g: GraphicsContext) {
        var wedge = Path()
        wedge.move(to: CGPoint(x: -6.5, y: 4.5))
        wedge.addLine(to: CGPoint(x: 6.5, y: 4.5))
        wedge.addLine(to: CGPoint(x: 6.5, y: -2.5))
        wedge.addLine(to: CGPoint(x: -6.5, y: 0.5))
        wedge.closeSubpath()
        g.fill(wedge, Color(hex: 0xFFE7B8))
        var layer = g
        layer.clip(to: wedge)
        layer.fill(Path(CGRect(x: -7, y: 1.4, width: 14, height: 1.3)), Color(hex: 0xFF8FB1))
        layer.fill(Path(CGRect(x: -7, y: -1.6, width: 14, height: 1.1)).applying(CGAffineTransform(a: 1, b: -0.2, c: 0, d: 1, tx: 0, ty: 0)),
                   Color(hex: 0xFF8FB1))
        g.stroke(wedge, Color(hex: 0xC99A5B), 0.8)
        var icing = Path()
        icing.move(to: CGPoint(x: -6.8, y: 0.6))
        icing.addLine(to: CGPoint(x: 6.8, y: -2.6))
        icing.addLine(to: CGPoint(x: 6.8, y: -4.2))
        icing.addLine(to: CGPoint(x: -6.8, y: -0.9))
        icing.closeSubpath()
        g.fill(icing, Color(hex: 0xFFF4F7))
        g.stroke(icing, Color(hex: 0xF2B5C8), 0.6)
        g.fill(.heart(CGPoint(x: 3.4, y: -5.6), size: 4.4), Color(hex: 0xF0525A))
        g.fill(Path(CGRect(x: 3.1, y: -8.2, width: 0.7, height: 1.2)), Color(hex: 0x6B8E3A))
    }

    /// A heart-shaped sugar cookie with pink icing.
    static func heartCookie(_ g: GraphicsContext, spin: Double) {
        var c = g
        c.rotate(by: .radians(sin(spin) * 0.3))
        let cookie = Path.heart(CGPoint(x: 0, y: 0.4), size: 13)
        c.fill(cookie, Color(hex: 0xE9B36F))
        c.stroke(cookie, Color(hex: 0xB07B3C), 0.8)
        c.fill(.heart(CGPoint(x: 0, y: 0.2), size: 9.6), Color(hex: 0xFF8FB1))
        for (x, y) in [(-2.2, -1.2), (1.8, -0.4), (0.0, 1.6), (-0.6, -2.4)] {
            c.fill(.ellipse(CGPoint(x: x, y: y), 0.9, 0.9), Color.white.opacity(0.9))
        }
    }
}
