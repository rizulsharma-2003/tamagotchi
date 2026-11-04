import SwiftUI
import TamagotchiCore

/// Small props the characters hold, drawn centered on a point in local units.
enum ItemRenderer {
    static let outline = Color(hex: 0x5B4A5E)

    static func draw(_ item: HeldItem, in ctx: GraphicsContext, at c: CGPoint, size: CGFloat) {
        let s = size / 16
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.scaleBy(x: s, y: s)
        switch item {
        case .coffee:
            let cup = Path.roundedRect(CGRect(x: -5.5, y: -5, width: 11, height: 11), 2.5)
            g.fill(cup, Color(hex: 0xFFFFFF))
            g.stroke(cup, outline, 1.1)
            g.fill(Path(CGRect(x: -5.5, y: -1, width: 11, height: 3)), Color(hex: 0xFF8FA3))
            var handle = Path()
            handle.addArc(center: CGPoint(x: 6, y: 0.5), radius: 3, startAngle: .degrees(-80), endAngle: .degrees(80), clockwise: false)
            g.stroke(handle, outline, 1.4)
            g.fill(.ellipse(CGPoint(x: 0, y: -5), 9, 2.4), Color(hex: 0x8A5A3C))
        case .ball:
            ball(g, radius: 6, spin: 0)
        case .document:
            let page = Path.roundedRect(CGRect(x: -6, y: -8, width: 12, height: 16), 1.5)
            g.fill(page, Color.white)
            g.stroke(page, outline, 1)
            for row in 0..<5 {
                g.fill(Path(CGRect(x: -4, y: -5.5 + CGFloat(row) * 2.6, width: row == 4 ? 4.5 : 8, height: 1.1)), Color(hex: 0x9C93AE))
            }
        case .taskCard:
            let card = Path.roundedRect(CGRect(x: -8, y: -6, width: 16, height: 12), 1.8)
            g.fill(card, Color(hex: 0xFFF6D8))
            g.stroke(card, outline, 1)
            for row in 0..<3 {
                let y = -3 + CGFloat(row) * 3.2
                g.stroke(.roundedRect(CGRect(x: -6, y: y - 1, width: 2, height: 2), 0.4), outline, 0.7)
                g.fill(Path(CGRect(x: -2.5, y: y - 0.5, width: 8, height: 1.1)), Color(hex: 0xB59E7A))
            }
        case .magnifier:
            var handle = Path()
            handle.move(to: CGPoint(x: 2.5, y: 2.5))
            handle.addLine(to: CGPoint(x: 7, y: 7))
            g.stroke(handle, Color(hex: 0x8A5A3C), 2.6)
            let lens = Path.ellipse(CGPoint(x: -1, y: -1), 10, 10)
            g.fill(lens, Color(hex: 0xBFE9FF).opacity(0.55))
            g.stroke(lens, Color(hex: 0x6D6D7E), 1.8)
            g.fill(.ellipse(CGPoint(x: -2.8, y: -2.8), 2.6, 1.6), Color.white.opacity(0.8))
        case .codeCard:
            let card = Path.roundedRect(CGRect(x: -9, y: -6.5, width: 18, height: 13), 2)
            g.fill(card, Color(hex: 0x2A2232))
            g.stroke(card, outline, 1)
            let colors = [Color(hex: 0x7FE3CB), Color(hex: 0xFFD166), Color(hex: 0xB9A7FF), Color(hex: 0xFF9FB2)]
            for row in 0..<4 {
                g.fill(.roundedRect(CGRect(x: -6.5 + CGFloat(row % 2) * 2, y: -4.2 + CGFloat(row) * 2.6, width: CGFloat(6 + (row * 5) % 7), height: 1.3), 0.6), colors[row])
            }
        case .trophy:
            var cup = Path()
            cup.move(to: CGPoint(x: -5.5, y: -7))
            cup.addLine(to: CGPoint(x: 5.5, y: -7))
            cup.addQuadCurve(to: CGPoint(x: 0, y: 2), control: CGPoint(x: 5.5, y: 2))
            cup.addQuadCurve(to: CGPoint(x: -5.5, y: -7), control: CGPoint(x: -5.5, y: 2))
            g.fill(cup, Color(hex: 0xFFCF4A))
            g.stroke(cup, Color(hex: 0xB8862B), 1)
            for side in [-1.0, 1.0] {
                var handle = Path()
                handle.addArc(center: CGPoint(x: CGFloat(side) * 5.5, y: -4.2), radius: 2.4,
                              startAngle: .degrees(side < 0 ? 90 : -90), endAngle: .degrees(side < 0 ? 270 : 90), clockwise: false)
                g.stroke(handle, Color(hex: 0xB8862B), 1.2)
            }
            g.fill(Path(CGRect(x: -1, y: 1.5, width: 2, height: 3)), Color(hex: 0xE0AE35))
            g.fill(.roundedRect(CGRect(x: -4, y: 4.2, width: 8, height: 2.6), 0.8), Color(hex: 0x8A5A3C))
            g.fill(.sparkle(CGPoint(x: -2, y: -4.5), radius: 1.8), Color.white.opacity(0.9))
        case .gradCap:
            AccessoryRenderer.graduationCap(g, center: CGPoint(x: 0, y: 0), width: 18)
        case .rock:
            let rock = Path.ellipse(.zero, 11, 9)
            g.fill(rock, Color(hex: 0xA59FAE))
            g.stroke(rock, outline, 1)
            g.fill(.ellipse(CGPoint(x: -2, y: -1.5), 3, 2), Color.white.opacity(0.35))
        case .paper:
            let sheet = Path.roundedRect(CGRect(x: -5.5, y: -7, width: 11, height: 14), 1)
            g.fill(sheet, Color.white)
            g.stroke(sheet, outline, 1)
            g.fill(Path(CGRect(x: -3.5, y: -3, width: 7, height: 1)), Color(hex: 0xC9C2D6))
            g.fill(Path(CGRect(x: -3.5, y: 0, width: 7, height: 1)), Color(hex: 0xC9C2D6))
        case .scissors:
            for side in [-1.0, 1.0] {
                g.stroke(.ellipse(CGPoint(x: CGFloat(side) * 3, y: 4), 4.6, 4.6), Color(hex: 0xFF6B6B), 1.6)
                var blade = Path()
                blade.move(to: CGPoint(x: CGFloat(side) * 2.2, y: 1.5))
                blade.addLine(to: CGPoint(x: CGFloat(-side) * 3.5, y: -7.5))
                g.stroke(blade, Color(hex: 0x8C849A), 1.8)
            }
        case .errorBoard:
            var leg = Path()
            leg.move(to: CGPoint(x: 0, y: 5))
            leg.addLine(to: CGPoint(x: 0, y: 9))
            g.stroke(leg, Color(hex: 0x8A5A3C), 1.6)
            let board = Path.roundedRect(CGRect(x: -8, y: -7, width: 16, height: 12), 1.8)
            g.fill(board, Color(hex: 0x3A3346))
            g.stroke(board, Color(hex: 0x8A5A3C), 1.4)
            g.text("!", at: CGPoint(x: -3, y: -1), size: 8, color: Color(hex: 0xFF8A7A))
            g.fill(Path(CGRect(x: 0, y: -3, width: 5.5, height: 1.2)), Color(hex: 0xFFC2B8))
            g.fill(Path(CGRect(x: 0, y: 0, width: 4, height: 1.2)), Color(hex: 0xFFC2B8))
        case .treat:
            ItemRenderer.cookie(g, size: 12)
        case .detectiveHat:
            AccessoryRenderer.deerstalker(g, center: CGPoint(x: 0, y: 2), width: 20)
        }
    }

    static func cookie(_ g: GraphicsContext, size: CGFloat, spin: Double = 0, seasonal: Bool = true) {
        // Holidays swap the cookie for a seasonal treat (candy, a laddoo, gingerbread, cake).
        if seasonal, SeasonalTreats.style != .cookie { return SeasonalTreats.draw(g, size: size, spin: spin) }
        let cookie = Path.ellipse(.zero, size, size)
        g.fill(cookie, with: .radialGradient(Gradient(colors: [Color(hex: 0xF2C27F), Color(hex: 0xDE9F58)]),
                                             center: CGPoint(x: -size * 0.15, y: -size * 0.18), startRadius: 0, endRadius: size * 0.6))
        g.stroke(cookie, Color(hex: 0xA8743B), max(0.9, size / 12))
        var chips = g
        chips.rotate(by: .radians(spin))
        for (x, y) in [(-2.2, -1.8), (2.4, -0.6), (-0.4, 2.6), (1.6, 3.2), (-3.2, 1.4), (0.6, -3.4)] {
            chips.fill(.ellipse(CGPoint(x: x * size / 12, y: y * size / 12), 1.8 * size / 12, 1.6 * size / 12), Color(hex: 0x6B3F22))
        }
    }

    /// A shiny red play ball with a white band; the band and stars turn with `spin`,
    /// the highlight stays put so it reads as a sphere.
    static func ball(_ g: GraphicsContext, radius r: CGFloat, spin: Double, tiny: Bool = false) {
        let circle = Path.ellipse(.zero, r * 2, r * 2)
        g.fill(circle, with: .radialGradient(Gradient(colors: [Color(hex: 0xFF8A80), Color(hex: 0xF0525A)]),
                                             center: CGPoint(x: -r * 0.35, y: -r * 0.4), startRadius: 0, endRadius: r * 1.3))
        var inner = g
        inner.clip(to: circle)
        inner.rotate(by: .radians(spin))
        var band = Path()
        band.move(to: CGPoint(x: -r * 1.2, y: -r * 0.28))
        band.addQuadCurve(to: CGPoint(x: r * 1.2, y: -r * 0.28), control: CGPoint(x: 0, y: r * 0.32))
        band.addLine(to: CGPoint(x: r * 1.2, y: r * 0.22))
        band.addQuadCurve(to: CGPoint(x: -r * 1.2, y: r * 0.22), control: CGPoint(x: 0, y: r * 0.82))
        band.closeSubpath()
        inner.fill(band, Color.white.opacity(0.95))
        inner.fill(.star(CGPoint(x: 0, y: -r * 0.62), radius: r * 0.28), Color(hex: 0xFFD166))
        g.fill(.ellipse(CGPoint(x: -r * 0.38, y: -r * 0.45), r * 0.55, r * 0.36), Color.white.opacity(0.65))
        g.stroke(circle, Color(hex: 0xB43B45), tiny ? 2 : max(0.9, r * 0.16))
    }

    /// A yarn ball with wound strands.
    static func yarn(_ g: GraphicsContext, radius r: CGFloat, spin: Double, tiny: Bool = false) {
        let circle = Path.ellipse(.zero, r * 2, r * 2)
        let base = Color(hex: 0xB79BFF)
        let dark = Color(hex: 0x8A6ADF)
        g.fill(circle, with: .radialGradient(Gradient(colors: [Color(hex: 0xD3C2FF), base]),
                                             center: CGPoint(x: -r * 0.3, y: -r * 0.35), startRadius: 0, endRadius: r * 1.2))
        var inner = g
        inner.clip(to: circle)
        inner.rotate(by: .radians(spin))
        for index in 0..<4 {
            var strand = Path()
            let offset = CGFloat(index) * r * 0.42 - r * 0.6
            strand.move(to: CGPoint(x: -r * 1.1, y: offset - r * 0.3))
            strand.addQuadCurve(to: CGPoint(x: r * 1.1, y: offset + r * 0.2), control: CGPoint(x: 0, y: offset + r * 0.55))
            inner.stroke(strand, dark.opacity(0.75), tiny ? 1.4 : max(0.7, r * 0.12))
        }
        var cross = Path()
        cross.move(to: CGPoint(x: -r * 0.5, y: -r * 1.1))
        cross.addQuadCurve(to: CGPoint(x: -r * 0.2, y: r * 1.1), control: CGPoint(x: r * 0.5, y: 0))
        inner.stroke(cross, dark.opacity(0.6), tiny ? 1.4 : max(0.7, r * 0.12))
        g.fill(.ellipse(CGPoint(x: -r * 0.35, y: -r * 0.45), r * 0.5, r * 0.32), Color.white.opacity(0.45))
        g.stroke(circle, Color(hex: 0x6E50C2), tiny ? 2 : max(0.9, r * 0.15))
    }

    /// A fish treat facing left. `bites` 0…2 nibbles from the head, 3 = only bones left.
    static func fish(_ g: GraphicsContext, bites: Int, tiny: Bool = false) {
        let line: CGFloat = tiny ? 2 : 1
        if bites >= 3 {
            let bone = Color(hex: 0xF4EEE6)
            let edge = Color(hex: 0xA8957E)
            var skeleton = Path()
            skeleton.move(to: CGPoint(x: -5, y: 0))
            skeleton.addLine(to: CGPoint(x: 6, y: 0))
            for index in 0..<3 {
                let x = CGFloat(index) * 3 - 2.5
                skeleton.move(to: CGPoint(x: x, y: -2.8))
                skeleton.addLine(to: CGPoint(x: x + 0.8, y: 2.8))
            }
            skeleton.addEllipse(in: CGRect(x: -9.6, y: -2.7, width: 5.2, height: 5.4))
            skeleton.move(to: CGPoint(x: 6, y: 0))
            skeleton.addLine(to: CGPoint(x: 9.5, y: -3))
            skeleton.addLine(to: CGPoint(x: 9.5, y: 3))
            skeleton.closeSubpath()
            g.stroke(skeleton, edge, tiny ? 3.4 : 2.6)
            g.stroke(skeleton, bone, tiny ? 1.8 : 1.3)
            return
        }
        var body = g
        if bites > 0 {
            var bitten = Path()
            for index in 0..<bites {
                let x = -9.5 + CGFloat(index) * 4.2
                bitten.addEllipse(in: CGRect(x: x - 4.2, y: -4.6, width: 6, height: 4.8))
                bitten.addEllipse(in: CGRect(x: x - 3.6, y: -1.2, width: 5.8, height: 5.2))
            }
            body.clip(to: bitten, options: .inverse)
        }
        var fishPath = Path()
        fishPath.move(to: CGPoint(x: -9, y: 0))
        fishPath.addQuadCurve(to: CGPoint(x: 5, y: -0.2), control: CGPoint(x: -2, y: -9))
        fishPath.addLine(to: CGPoint(x: 10, y: -4.5))
        fishPath.addQuadCurve(to: CGPoint(x: 10, y: 4.5), control: CGPoint(x: 8.2, y: 0))
        fishPath.addLine(to: CGPoint(x: 5, y: 0.2))
        fishPath.addQuadCurve(to: CGPoint(x: -9, y: 0), control: CGPoint(x: -2, y: 9))
        fishPath.closeSubpath()
        body.fill(fishPath, with: .linearGradient(Gradient(colors: [Color(hex: 0xFF9F6E), Color(hex: 0xFFC49A)]),
                                                  startPoint: CGPoint(x: 0, y: -5), endPoint: CGPoint(x: 0, y: 5)))
        for index in 0..<2 {
            var stripe = Path()
            let x = CGFloat(index) * 3.4 - 1.5
            stripe.move(to: CGPoint(x: x, y: -3.4))
            stripe.addQuadCurve(to: CGPoint(x: x, y: 3.4), control: CGPoint(x: x + 1.6, y: 0))
            body.stroke(stripe, Color(hex: 0xE5774A).opacity(0.8), 0.9)
        }
        body.fill(.ellipse(CGPoint(x: -5.4, y: -1.2), 2.2, 2.2), Color(hex: 0x3A2A33))
        body.fill(.ellipse(CGPoint(x: -5.7, y: -1.5), 0.8, 0.8), Color.white)
        body.stroke(fishPath, Color(hex: 0xC4663F), line)
    }

    /// A strawberry with seeds and a leafy crown.
    static func berry(_ g: GraphicsContext, size s: CGFloat, tiny: Bool = false) {
        var shape = Path()
        shape.move(to: CGPoint(x: 0, y: 6 * s))
        shape.addCurve(to: CGPoint(x: -6 * s, y: -2.5 * s), control1: CGPoint(x: -3 * s, y: 5 * s), control2: CGPoint(x: -6.5 * s, y: 1 * s))
        shape.addQuadCurve(to: CGPoint(x: 6 * s, y: -2.5 * s), control: CGPoint(x: 0, y: -7.5 * s))
        shape.addCurve(to: CGPoint(x: 0, y: 6 * s), control1: CGPoint(x: 6.5 * s, y: 1 * s), control2: CGPoint(x: 3 * s, y: 5 * s))
        shape.closeSubpath()
        g.fill(shape, with: .radialGradient(Gradient(colors: [Color(hex: 0xFF7A8A), Color(hex: 0xE83E58)]),
                                            center: CGPoint(x: -1.5 * s, y: -1 * s), startRadius: 0, endRadius: 7 * s))
        if !tiny {
            for (x, y) in [(-2.6, 0.0), (0.0, 1.6), (2.6, 0.0), (-1.3, 3.4), (1.3, 3.4), (-1.4, -1.8), (1.4, -1.8)] {
                g.fill(.ellipse(CGPoint(x: x * s, y: y * s), 0.9 * s, 1.2 * s), Color(hex: 0xFFE08A))
            }
        }
        g.stroke(shape, Color(hex: 0xB12C45), tiny ? 2 : 0.9)
        for index in 0..<3 {
            var leaf = g
            leaf.translateBy(x: 0, y: -4.2 * s)
            leaf.rotate(by: .radians(Double(index - 1) * 0.9))
            let path = Path.ellipse(CGPoint(x: 0, y: -1.8 * s), 2.4 * s, 4.2 * s)
            leaf.fill(path, Color(hex: 0x6CCB6A))
            leaf.stroke(path, Color(hex: 0x3F8E45), 0.7)
        }
    }

    /// A cupcake: `variant` 0 full, 1 frosting licked, 2 a bite taken, 4 two bites, 3 only the
    /// wrapper. Bites come out of the left side, where Mochi eats from.
    static func cupcake(_ g: GraphicsContext, size s: CGFloat, variant: Int = 0, tiny: Bool = false) {
        var wrapper = Path()
        wrapper.move(to: CGPoint(x: -6 * s, y: 0))
        wrapper.addLine(to: CGPoint(x: 6 * s, y: 0))
        wrapper.addLine(to: CGPoint(x: 4.4 * s, y: 7 * s))
        wrapper.addLine(to: CGPoint(x: -4.4 * s, y: 7 * s))
        wrapper.closeSubpath()
        if variant == 3 {
            // Just the crumpled wrapper.
            var crumpled = g
            crumpled.scaleBy(x: 1, y: 0.75)
            crumpled.translateBy(x: 0, y: 2.4 * s)
            crumpled.fill(wrapper, Color(hex: 0x8FD3FF))
            crumpled.stroke(wrapper, Color(hex: 0x4F8FB8), tiny ? 2 : 0.9)
            crumpled.fill(.ellipse(CGPoint(x: -1.5 * s, y: -0.4 * s), 2.4 * s, 1.6 * s), Color(hex: 0xC98A55))
            return
        }
        g.fill(wrapper, Color(hex: 0x8FD3FF))
        if !tiny {
            for index in 0..<4 {
                var stripe = Path()
                let x = CGFloat(index) * 3 - 4.5
                stripe.move(to: CGPoint(x: x * s, y: 0.4 * s))
                stripe.addLine(to: CGPoint(x: x * 0.78 * s, y: 6.6 * s))
                g.stroke(stripe, Color.white.opacity(0.7), 0.8)
            }
        }
        g.stroke(wrapper, Color(hex: 0x4F8FB8), tiny ? 2 : 0.9)
        var top = g
        if variant == 2 || variant == 4 {
            // Bites out of the top left (and a second, deeper one).
            var bite = Path()
            bite.addEllipse(in: CGRect(x: -9.5 * s, y: -9.5 * s, width: 9 * s, height: 8 * s))
            if variant == 4 { bite.addEllipse(in: CGRect(x: -6.5 * s, y: -7.5 * s, width: 9.5 * s, height: 8.5 * s)) }
            top.clip(to: bite, options: .inverse)
        }
        var frosting = Path()
        frosting.move(to: CGPoint(x: -7 * s, y: 0.5 * s))
        frosting.addQuadCurve(to: CGPoint(x: -3 * s, y: -4.5 * s), control: CGPoint(x: -7.5 * s, y: -4 * s))
        frosting.addQuadCurve(to: CGPoint(x: 3 * s, y: -4.5 * s), control: CGPoint(x: 0, y: -8 * s))
        frosting.addQuadCurve(to: CGPoint(x: 7 * s, y: 0.5 * s), control: CGPoint(x: 7.5 * s, y: -4 * s))
        frosting.closeSubpath()
        top.fill(frosting, Color(hex: 0xFFB3CF))
        top.stroke(frosting, Color(hex: 0xD9708F), tiny ? 2 : 0.9)
        if variant >= 1 {
            // A lick-shaped dent in the frosting.
            var lick = Path()
            lick.move(to: CGPoint(x: -3.6 * s, y: -3 * s))
            lick.addQuadCurve(to: CGPoint(x: 1.6 * s, y: -3.4 * s), control: CGPoint(x: -1 * s, y: -0.8 * s))
            top.stroke(lick, Color(hex: 0xE58AAA), tiny ? 1.8 : 1.1)
        } else {
            top.fill(.ellipse(CGPoint(x: 0, y: -6.6 * s), 3.6 * s, 3.6 * s), Color(hex: 0xE83E58))
        }
        top.fill(.ellipse(CGPoint(x: -2.5 * s, y: -2.8 * s), 2.6 * s, 1.4 * s), Color.white.opacity(0.6))
        if !tiny, variant < 2 || variant == 2 {
            for (x, y, c) in [(-4.0, -1.5, 0x7FD6C2), (2.6, -2.2, 0xFFD166), (4.4, -0.6, 0x9C8CFF), (-1.2, -4.6, 0x7FD6C2)] as [(Double, Double, UInt32)] {
                top.fill(.roundedRect(CGRect(x: x * s - 0.7, y: y * s - 0.35, width: 1.4, height: 0.7), 0.3), Color(hex: c))
            }
        }
    }

    static func crumb(_ g: GraphicsContext, variant: Int, size s: CGFloat) {
        var path = Path()
        switch variant % 3 {
        case 0:
            path.move(to: CGPoint(x: -1.6 * s, y: -1 * s))
            path.addLine(to: CGPoint(x: 1.4 * s, y: -1.5 * s))
            path.addLine(to: CGPoint(x: 1.7 * s, y: 1.1 * s))
            path.addLine(to: CGPoint(x: -1.1 * s, y: 1.5 * s))
        case 1:
            path.move(to: CGPoint(x: -1.3 * s, y: -1.4 * s))
            path.addLine(to: CGPoint(x: 1.6 * s, y: -0.4 * s))
            path.addLine(to: CGPoint(x: -0.4 * s, y: 1.6 * s))
        default:
            path.addEllipse(in: CGRect(x: -1.3 * s, y: -1.1 * s, width: 2.6 * s, height: 2.2 * s))
        }
        path.closeSubpath()
        g.fill(path, Color(hex: 0xE0A35E))
        g.stroke(path, Color(hex: 0xA8743B), 0.6)
    }
}

/// Particles, symbols and speech bubbles, positioned in body units around a character.
enum EffectRenderer {
    static func draw(_ effect: Effect, in ctx: GraphicsContext, unitX: CGFloat, unitY: CGFloat, dark: Bool, detail: RenderDetail = .standard) {
        guard effect.opacity > 0.01, effect.scale > 0.01 else { return }
        let tiny = detail == .tiny
        var g = ctx
        g.opacity = Ease.clamp(effect.opacity)
        g.translateBy(x: CGFloat(effect.x) * unitX, y: -CGFloat(effect.y) * unitY)
        // Props that roll spin their own pattern; everything else rotates as a whole.
        let spins: Bool
        switch effect.kind {
        case .ball, .yarn, .berry, .treat: spins = true
        default: spins = false
        }
        if !spins { g.rotate(by: .radians(effect.rotation)) }
        // Particles grow at menu-bar size so they still read; floor props stay true to size.
        let boost: CGFloat
        switch effect.kind {
        case .ball, .yarn, .fish, .berry, .cupcake, .treat, .shadow, .butterfly, .bubble: boost = tiny ? 1.15 : 1
        default: boost = tiny ? 1.5 : 1
        }
        g.scaleBy(x: CGFloat(effect.scale) * boost, y: CGFloat(effect.scale) * boost)
        let ink = dark ? Color(hex: 0xE9E3F2) : Color(hex: 0x6A5C7A)
        let stroke: CGFloat = tiny ? 2.2 : 1.4
        switch effect.kind {
        case .z:
            g.text("z", at: .zero, size: 13, weight: .heavy, color: ink.opacity(0.85))
        case .sparkle:
            // Variant 1 is the pastel play sparkle; gold (0) is kept for real-event reactions.
            let pastel = effect.variant == 1
            g.fill(.sparkle(.zero, radius: 6), pastel ? Color(hex: 0xFFB8D6) : Color(hex: 0xFFD166))
            if !tiny { g.fill(.sparkle(.zero, radius: 2.6), pastel ? Color.white : Color(hex: 0xFFF6D0)) }
        case .star:
            if effect.variant == 1 {
                // Lavender "dizzy" star.
                let star = Path.star(.zero, radius: 5)
                g.fill(star, Color(hex: 0xB9A7FF))
                g.stroke(star, ink.opacity(0.7), tiny ? 1.4 : 0.8)
            } else {
                g.fill(.star(.zero, radius: 5), Color(hex: 0xFFD166))
            }
        case .heart:
            g.fill(.heart(.zero, size: 10), Color(hex: 0xFF6F91))
            if !tiny { g.fill(.ellipse(CGPoint(x: -2, y: -1.8), 2.4, 1.6), Color.white.opacity(0.55)) }
        case .question:
            g.text("?", at: .zero, size: 16, weight: .heavy, color: Color(hex: 0x9C8CFF))
        case .exclamation:
            g.text("!", at: .zero, size: 16, weight: .heavy, color: Color(hex: 0xFF8A5C))
        case .sweat:
            var drop = Path()
            drop.move(to: CGPoint(x: 0, y: -5))
            drop.addQuadCurve(to: CGPoint(x: 0, y: 4), control: CGPoint(x: 5.5, y: 2.5))
            drop.addQuadCurve(to: CGPoint(x: 0, y: -5), control: CGPoint(x: -5.5, y: 2.5))
            g.fill(drop, Color(hex: 0x8FD3FF))
            g.fill(.ellipse(CGPoint(x: -1, y: 1), 1.6, 2.2), Color.white.opacity(0.8))
        case .note:
            g.text(effect.variant % 2 == 0 ? "♪" : "♫", at: .zero, size: 13, weight: .bold, color: Color(hex: 0x9C8CFF))
        case .confetti:
            let color = ConfettiPalette.colors[abs(effect.variant) % ConfettiPalette.colors.count]
            g.fill(.roundedRect(CGRect(x: -2.5, y: -1.4, width: 5, height: 2.8), 0.8), color)
        case .steam:
            for index in 0..<2 {
                var wisp = Path()
                let x = CGFloat(index) * 4 - 2
                let phase = CGFloat(effect.rotation) * 2 + CGFloat(index)
                wisp.move(to: CGPoint(x: x, y: 0))
                wisp.addCurve(to: CGPoint(x: x, y: -12), control1: CGPoint(x: x + 3 * sin(phase), y: -4), control2: CGPoint(x: x - 3 * sin(phase), y: -8))
                g.stroke(wisp, ink.opacity(0.35), 1.4)
            }
        case .speechDots, .speechLock, .speechQuestion, .plug:
            bubble(g, dark: dark) { inner in
                switch effect.kind {
                case .speechLock:
                    inner.symbol("lock.fill", in: CGRect(x: -4.5, y: -5, width: 9, height: 10), color: Color(hex: 0xE58A2E))
                case .speechQuestion:
                    inner.text("?", at: CGPoint(x: 0, y: -0.5), size: 11, weight: .heavy, color: Color(hex: 0x9C8CFF))
                case .plug:
                    inner.symbol("antenna.radiowaves.left.and.right.slash", in: CGRect(x: -6, y: -5, width: 12, height: 10), color: Color(hex: 0x8C849A))
                default:
                    for index in 0..<3 {
                        inner.fill(.ellipse(CGPoint(x: CGFloat(index - 1) * 4, y: 0), 2.6, 2.6), Color(hex: 0x6A5C7A))
                    }
                }
            }
        case .thinkingDots:
            for index in 0..<3 {
                let active = effect.variant == 3 || index < effect.variant
                g.fill(.ellipse(CGPoint(x: CGFloat(index) * 5.5 - 5.5, y: CGFloat(-index) * 2.5), 3.6, 3.6),
                       ink.opacity(active ? 0.8 : 0.25))
            }
        case .clap:
            for index in 0..<8 {
                let angle = Double(index) * .pi / 4
                var ray = Path()
                ray.move(to: CGPoint(x: cos(angle) * 6, y: sin(angle) * 6))
                ray.addLine(to: CGPoint(x: cos(angle) * 11, y: sin(angle) * 11))
                g.stroke(ray, Color(hex: 0xFFD166), 1.8)
            }
            g.fill(.sparkle(.zero, radius: 5), Color(hex: 0xFFF1B8))
        case .ball:
            squashed(g, effect) { ItemRenderer.ball($0, radius: 6.5, spin: effect.rotation, tiny: tiny) }
        case .treat:
            squashed(g, effect) { ItemRenderer.cookie($0, size: 11, spin: effect.rotation) }
        case .orb:
            orb(g, phase: effect.rotation)
        case .yarn:
            // The strand first, so the ball sits on top of it.
            strand(g, to: CGPoint(x: CGFloat(effect.x2) * unitX / CGFloat(effect.scale * Double(boost)),
                                  y: -CGFloat(effect.y2) * unitY / CGFloat(effect.scale * Double(boost))), tiny: tiny)
            squashed(g, effect) { ItemRenderer.yarn($0, radius: 7, spin: effect.rotation, tiny: tiny) }
        case .shadow:
            g.fill(.ellipse(.zero, 15, 4.2), Color.black.opacity(dark ? 0.3 : 0.14))
        case .dust:
            dust(g, phase: effect.phase, dark: dark, tiny: tiny, flip: effect.variant == 0)
        case .streak:
            streak(g, side: effect.variant, ink: ink, width: stroke, tiny: tiny)
        case .purr:
            purr(g, side: effect.variant, phase: effect.phase, ink: ink, width: stroke)
        case .crumb:
            ItemRenderer.crumb(g, variant: effect.variant, size: 1.8)
        case .tangle:
            break // drawn in body space by PetRenderer
        case .butterfly:
            butterfly(g, phase: effect.phase, variant: effect.variant, tiny: tiny)
        case .bubble:
            soapBubble(g, phase: effect.phase, tiny: tiny)
        case .pop:
            pop(g, phase: effect.phase, variant: effect.variant, width: stroke)
        case .fish:
            squashed(g, effect) { ItemRenderer.fish($0, bites: effect.variant, tiny: tiny) }
        case .berry:
            squashed(g, effect) { context in
                var rolled = context
                rolled.rotate(by: .radians(effect.rotation))
                ItemRenderer.berry(rolled, size: 1.05, tiny: tiny)
            }
        case .cupcake:
            // Squashes onto its base (7 units below its centre).
            var base = g
            base.translateBy(x: 0, y: 7)
            squashed(base, effect) { squash in
                var c = squash
                c.translateBy(x: 0, y: -7)
                ItemRenderer.cupcake(c, size: 1, variant: effect.variant, tiny: tiny)
            }
        case .frosting:
            var blob = Path()
            blob.move(to: CGPoint(x: -4, y: 1.6))
            blob.addQuadCurve(to: CGPoint(x: -1.6, y: -2.6), control: CGPoint(x: -4.4, y: -2))
            blob.addQuadCurve(to: CGPoint(x: 1.8, y: -2.4), control: CGPoint(x: 0, y: -4.4))
            blob.addQuadCurve(to: CGPoint(x: 4, y: 1.6), control: CGPoint(x: 4.6, y: -1.6))
            blob.closeSubpath()
            g.fill(blob, Color(hex: 0xFFB3CF))
            g.stroke(blob, Color(hex: 0xD9708F), tiny ? 1.6 : 0.8)
            g.fill(.ellipse(CGPoint(x: -1.2, y: -1.2), 1.8, 1.1), Color.white.opacity(0.75))
        case .sniff:
            sniffPuffs(g, phase: effect.phase, flip: effect.variant == 1, ink: ink, width: stroke, tiny: tiny)
        case .sneeze:
            sneeze(g, phase: effect.phase, dark: dark, width: stroke)
        case .noseBubble:
            let r: CGFloat = 7
            let circle = Path.ellipse(.zero, r * 2, r * 2)
            g.fill(circle, Color(hex: 0xBFE6FF).opacity(0.45))
            g.stroke(circle, Color(hex: 0x8FC9F0), tiny ? 1.8 : 0.9)
            g.fill(.ellipse(CGPoint(x: -2.6, y: -2.8), 3.2, 2.2), Color.white.opacity(0.85))
        case .shakeLines:
            shakeLines(g, side: effect.variant, ink: ink, width: stroke, tiny: tiny)
        case .burst:
            burst(g, phase: effect.phase, width: stroke, pale: effect.variant == 1)
        case .notice:
            // Three short strokes fanning out above the head.
            for index in 0..<3 {
                let angle = -Double.pi / 2 + Double(index - 1) * 0.55
                var line = Path()
                line.move(to: CGPoint(x: CGFloat(cos(angle)) * 4.5, y: CGFloat(sin(angle)) * 4.5))
                line.addLine(to: CGPoint(x: CGFloat(cos(angle)) * 10, y: CGFloat(sin(angle)) * 10))
                g.stroke(line, ink.opacity(0.75), stroke + 0.4)
            }
        case .droplet:
            var drop = Path()
            drop.move(to: CGPoint(x: 0, y: -4))
            drop.addQuadCurve(to: CGPoint(x: 0, y: 3.4), control: CGPoint(x: 4.4, y: 2))
            drop.addQuadCurve(to: CGPoint(x: 0, y: -4), control: CGPoint(x: -4.4, y: 2))
            g.fill(drop, Color(hex: 0x9FDBFF))
            g.stroke(drop, Color(hex: 0x5FB1E6), 0.6)
        case .heartPop:
            heartPop(g, phase: effect.phase)
        }
    }

    /// Applies a prop's squash (negative `stretch`) or stretch, keeping its volume.
    static func squashed(_ g: GraphicsContext, _ effect: Effect, draw: (GraphicsContext) -> Void) {
        var s = g
        let k = CGFloat(Ease.clamp(effect.stretch, -0.6, 0.6))
        s.scaleBy(x: 1 - 0.7 * k, y: 1 + k)
        draw(s)
    }

    static func strand(_ g: GraphicsContext, to end: CGPoint, tiny: Bool) {
        guard abs(end.x) + abs(end.y) > 1 else { return }
        var path = Path()
        let start = CGPoint(x: end.x > 0 ? 5 : -5, y: 3)
        path.move(to: start)
        let sag = max(4, abs(end.x) * 0.18)
        path.addCurve(to: end, control1: CGPoint(x: start.x + (end.x - start.x) * 0.3, y: max(start.y, end.y) + sag),
                      control2: CGPoint(x: start.x + (end.x - start.x) * 0.75, y: end.y + sag * 0.4))
        g.stroke(path, Color(hex: 0x6E50C2).opacity(0.5), tiny ? 2.6 : 2.0)
        g.stroke(path, Color(hex: 0xB79BFF), tiny ? 1.6 : 1.1)
    }

    /// Yarn loops around the body (body space: origin at the feet, units of the 60×54 body).
    static func tangle(_ effect: Effect, in body: GraphicsContext, style: PetRenderer.Style) {
        guard effect.opacity > 0.01 else { return }
        var g = body
        g.opacity = Ease.clamp(effect.opacity)
        g.translateBy(x: 0, y: -27)
        g.rotate(by: .radians(effect.rotation))
        g.scaleBy(x: CGFloat(effect.scale), y: CGFloat(effect.scale))
        g.translateBy(x: 0, y: 27)
        let wobble = CGFloat(sin(effect.phase * 5)) * 1.2
        // Bands wrap the lower body and stay clear of the face.
        let bands: [(CGFloat, CGFloat, Double)] = [(-7, 11, 0.1), (-12.5, 12, -0.2), (-18, 10, 0.24)]
        for index in 0..<min(3, max(0, effect.variant)) {
            let (y, h, tilt) = bands[index]
            var band = g
            band.translateBy(x: 0, y: y + wobble * CGFloat(index % 2 == 0 ? 1 : -1))
            band.rotate(by: .radians(tilt))
            var front = Path()
            front.addArc(center: .zero, radius: 1, startAngle: .degrees(8), endAngle: .degrees(172), clockwise: false)
            let arc = front.applying(CGAffineTransform(scaleX: 33, y: h / 2))
            band.stroke(arc, Color(hex: 0x6E50C2).opacity(0.55), style.tiny ? 4 : 3.0)
            band.stroke(arc, Color(hex: 0xB79BFF), style.tiny ? 2.4 : 1.8)
        }
        if effect.variant >= 2 {
            var dangle = Path()
            dangle.move(to: CGPoint(x: 24, y: -12))
            dangle.addCurve(to: CGPoint(x: 31, y: -1), control1: CGPoint(x: 32, y: -11), control2: CGPoint(x: 25, y: -5))
            g.stroke(dangle, Color(hex: 0xB79BFF), style.tiny ? 2.4 : 1.6)
        }
    }

    static func dust(_ g: GraphicsContext, phase: Double, dark: Bool, tiny: Bool, flip: Bool) {
        let fill = dark ? Color(hex: 0xCFC6DA).opacity(0.62) : Color(hex: 0xE9DCCB)
        let edge = dark ? Color(hex: 0xA79DB4).opacity(0.7) : Color(hex: 0xBFA88E)
        let s: CGFloat = flip ? -1 : 1
        let puffs: [(CGFloat, CGFloat, CGFloat)] = [(0, 0, 7.5), (s * 5.5, 1.2, 5.6), (-s * 4.8, 1.6, 4.6)]
        for (x, y, r) in puffs {
            let circle = Path.ellipse(CGPoint(x: x, y: y - CGFloat(phase) * 2), r, r * 0.86)
            g.fill(circle, fill)
            g.stroke(circle, edge, tiny ? 1.6 : 0.8)
        }
    }

    static func streak(_ g: GraphicsContext, side: Int, ink: Color, width: CGFloat, tiny: Bool = false) {
        if tiny {
            // One bold mark reads at menu-bar size; three thin ones blur into a smudge.
            if side == 2 {
                for index in 0..<2 {
                    var line = Path()
                    let y = CGFloat(index) * 7 - 3.5
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: index == 0 ? -14 : -9, y: y))
                    g.stroke(line, ink.opacity(0.75), 2.6)
                }
                return
            }
            let flip: CGFloat = side == 0 ? 1 : -1
            var arc = Path()
            arc.addArc(center: CGPoint(x: 0, y: flip * 7), radius: 12, startAngle: .degrees(flip > 0 ? -150 : 150),
                       endAngle: .degrees(flip > 0 ? -60 : 60), clockwise: flip < 0)
            g.stroke(arc, ink.opacity(0.85), 3.2)
            return
        }
        if side == 2 {
            // Straight speed lines (drawn behind a runner, pointing back).
            for index in 0..<3 {
                var line = Path()
                let y = CGFloat(index - 1) * 6
                let length: CGFloat = index == 1 ? 15 : 10
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: -length, y: y))
                g.stroke(line, ink.opacity(index == 1 ? 0.5 : 0.35), width)
            }
            return
        }
        let flip: CGFloat = side == 0 ? 1 : -1
        for index in 0..<3 {
            var arc = Path()
            let r = 9 + CGFloat(index) * 3.2
            arc.addArc(center: CGPoint(x: 0, y: flip * r * 0.6), radius: r, startAngle: .degrees(flip > 0 ? -150 : 150),
                       endAngle: .degrees(flip > 0 ? -60 : 60), clockwise: flip < 0)
            g.stroke(arc, ink.opacity(0.55 - 0.13 * Double(index)), width)
        }
    }

    static func purr(_ g: GraphicsContext, side: Int, phase: Double, ink: Color, width: CGFloat) {
        let s: CGFloat = side == 0 ? -1 : 1
        for index in 0..<3 {
            let jitter = CGFloat(sin(phase * 47 + Double(index) * 2.1)) * 0.9
            var arc = Path()
            let x = s * CGFloat(index) * 3.4
            arc.addArc(center: CGPoint(x: x - s * 6, y: jitter), radius: 6, startAngle: .degrees(s > 0 ? -38 : 142),
                       endAngle: .degrees(s > 0 ? 38 : 218), clockwise: false)
            g.stroke(arc, ink.opacity(0.6 - 0.15 * Double(index)), width)
        }
    }

    static func shakeLines(_ g: GraphicsContext, side: Int, ink: Color, width: CGFloat, tiny: Bool = false) {
        let s: CGFloat = side == 0 ? -1 : 1
        // Two longer, bolder arcs at menu-bar size.
        let count = tiny ? 2 : 3
        for index in 0..<count {
            var arc = Path()
            let y = tiny ? CGFloat(index) * 9 - 4.5 : CGFloat(index - 1) * 6.5
            let half: CGFloat = tiny ? 3.6 : 2.6
            arc.move(to: CGPoint(x: 0, y: y - half))
            arc.addQuadCurve(to: CGPoint(x: 0, y: y + half), control: CGPoint(x: s * (tiny ? 3.4 : 2.4), y: y))
            g.stroke(arc, ink.opacity(tiny ? 0.8 : 0.6), tiny ? 2.8 : width)
        }
    }

    static func sniffPuffs(_ g: GraphicsContext, phase: Double, flip: Bool, ink: Color, width: CGFloat, tiny: Bool = false) {
        let p = CGFloat(phase)
        let s: CGFloat = flip ? -1 : 1
        if tiny {
            // A single round puff at the nose.
            let puff = Path.ellipse(CGPoint(x: s * (5 + 4 * p), y: -1), 6 + 3 * p, 5 + 2.5 * p)
            g.stroke(puff, ink.opacity(0.8), 2.4)
            return
        }
        for index in 0..<2 {
            var arc = Path()
            let y = CGFloat(index) * 4.5 - 2
            arc.move(to: CGPoint(x: s * (2 + 4 * p), y: y))
            arc.addQuadCurve(to: CGPoint(x: s * (7 + 5 * p), y: y - 1), control: CGPoint(x: s * (4.5 + 4 * p), y: y - 3))
            g.stroke(arc, ink.opacity(0.55), width * 0.9)
        }
    }

    static func sneeze(_ g: GraphicsContext, phase: Double, dark: Bool, width: CGFloat) {
        let p = CGFloat(phase)
        let cloud = dark ? Color(hex: 0xEDE7F6).opacity(0.75) : Color.white
        let edge = dark ? Color(hex: 0xB9AFC7) : Color(hex: 0xC9BFD6)
        let puffs: [(CGFloat, CGFloat, CGFloat)] = [(4, 0, 7), (10, -3, 6), (11, 3.5, 5.5), (16, 0, 4.5)]
        for (x, y, r) in puffs {
            let c = Path.ellipse(CGPoint(x: x * (0.6 + 0.8 * p), y: y * (0.7 + 0.6 * p)), r * (0.6 + 0.7 * p), r * (0.6 + 0.7 * p))
            g.fill(c, cloud)
            g.stroke(c, edge, 0.8)
        }
        for index in 0..<4 {
            let angle = Double(index) * 0.5 - 0.75
            let r = 10 + 16 * p
            g.fill(.ellipse(CGPoint(x: CGFloat(cos(angle)) * r + 6, y: CGFloat(sin(angle)) * r), 2, 2), Color(hex: 0x9FDBFF))
        }
        var line = Path()
        line.move(to: CGPoint(x: 2, y: -9 - 4 * p))
        line.addLine(to: CGPoint(x: 6, y: -13 - 5 * p))
        line.move(to: CGPoint(x: 8, y: -7 - 4 * p))
        line.addLine(to: CGPoint(x: 13, y: -10 - 5 * p))
        g.stroke(line, edge, width)
    }

    static func burst(_ g: GraphicsContext, phase: Double, width: CGFloat, pale: Bool = false) {
        let p = CGFloat(phase)
        let ray = pale ? Color(hex: 0xFFD9B8) : Color(hex: 0xFFC94A)
        let core = pale ? Color.white : Color(hex: 0xFFF1B8)
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4 + 0.2
            let inner = 5 + 9 * p
            let outer = inner + 5 * (1 - p) + 1.5
            var line = Path()
            line.move(to: CGPoint(x: CGFloat(cos(angle)) * inner, y: CGFloat(sin(angle)) * inner))
            line.addLine(to: CGPoint(x: CGFloat(cos(angle)) * outer, y: CGFloat(sin(angle)) * outer))
            g.stroke(line, ray, width + 0.4)
        }
        g.fill(.sparkle(.zero, radius: 6 * (1 - p) + 1.5), core)
    }

    static func pop(_ g: GraphicsContext, phase: Double, variant: Int, width: CGFloat) {
        let p = CGFloat(phase)
        let colors = [Color(hex: 0xFF8FAB), Color(hex: 0x62BDF2), Color(hex: 0xFFC23D)]
        let color = colors[abs(variant) % colors.count]
        for index in 0..<7 {
            let angle = Double(index) * 2 * .pi / 7
            let r = 4 + 10 * p
            let point = CGPoint(x: CGFloat(cos(angle)) * r, y: CGFloat(sin(angle)) * r)
            if index % 2 == 0 {
                var dash = Path()
                dash.move(to: point)
                dash.addLine(to: CGPoint(x: point.x * 1.35, y: point.y * 1.35))
                g.stroke(dash, color, width)
            } else {
                g.fill(.ellipse(point, 2.6 * (1 - p) + 0.8, 2.6 * (1 - p) + 0.8), color)
            }
        }
        if p < 0.5 {
            g.stroke(.ellipse(.zero, 14 * (0.6 + p), 14 * (0.6 + p)), color.opacity(Double(1 - p * 2)), width * 0.8)
        }
        g.fill(.sparkle(.zero, radius: 5 * (1 - p)), Color.white.opacity(0.9))
    }

    static func heartPop(_ g: GraphicsContext, phase: Double) {
        let p = CGFloat(phase)
        for index in 0..<5 {
            let angle = Double(index) * 2 * .pi / 5 - .pi / 2
            let r = 3 + 11 * p
            g.fill(.heart(CGPoint(x: CGFloat(cos(angle)) * r, y: CGFloat(sin(angle)) * r), size: 4.5 * (1 - 0.5 * p)), Color(hex: 0xFF6F91))
        }
        g.fill(.sparkle(.zero, radius: 5 * (1 - p)), Color(hex: 0xFFD6E0))
    }

    static func butterfly(_ g: GraphicsContext, phase: Double, variant: Int, tiny: Bool) {
        let open = CGFloat(0.22 + 0.78 * abs(cos(phase)))
        let palettes: [(UInt32, UInt32, UInt32)] = [(0xFF9F80, 0xFFC36E, 0xC0566F), (0x8FD3FF, 0xB9A7FF, 0x4F74B8)]
        let (a, b, edgeHex) = palettes[abs(variant) % palettes.count]
        let edge = Color(hex: edgeHex)
        for index in 0..<2 {
            let side: CGFloat = index == 0 ? -1 : 1
            var wing = g
            wing.scaleBy(x: side * open, y: 1)
            let upper = Path.ellipse(CGPoint(x: 5.2, y: -3.2), 10, 9)
            let lower = Path.ellipse(CGPoint(x: 4, y: 3.6), 7, 6.4)
            wing.fill(upper, with: .linearGradient(Gradient(colors: [Color(hex: a), Color(hex: b)]),
                                                    startPoint: CGPoint(x: 0, y: -7), endPoint: CGPoint(x: 10, y: 2)))
            wing.fill(lower, Color(hex: b))
            wing.stroke(upper, edge, tiny ? 1.6 : 0.8)
            wing.stroke(lower, edge, tiny ? 1.6 : 0.8)
            if !tiny {
                wing.fill(.ellipse(CGPoint(x: 6.2, y: -3.6), 3.2, 3.2), Color.white.opacity(0.75))
                wing.fill(.ellipse(CGPoint(x: 4.4, y: 4), 1.8, 1.8), Color.white.opacity(0.6))
            }
        }
        g.fill(.capsule(from: CGPoint(x: 0, y: -5), to: CGPoint(x: 0, y: 6), width: tiny ? 3 : 2.4), Color(hex: 0x5B4A5E))
        for index in 0..<2 {
            let side: CGFloat = index == 0 ? -1 : 1
            var antenna = Path()
            antenna.move(to: CGPoint(x: 0, y: -5))
            antenna.addQuadCurve(to: CGPoint(x: side * 3.2, y: -10), control: CGPoint(x: side * 0.6, y: -9))
            g.stroke(antenna, Color(hex: 0x5B4A5E), tiny ? 1.4 : 0.8)
            g.fill(.ellipse(CGPoint(x: side * 3.2, y: -10), 1.6, 1.6), Color(hex: 0x5B4A5E))
        }
    }

    static func soapBubble(_ g: GraphicsContext, phase: Double, tiny: Bool) {
        let wobble = CGFloat(sin(phase * 5)) * 0.05
        var b = g
        b.scaleBy(x: 1 + wobble, y: 1 - wobble)
        let r: CGFloat = 8.5
        let circle = Path.ellipse(.zero, r * 2, r * 2)
        b.fill(circle, with: .radialGradient(Gradient(colors: [Color(hex: 0xEAF7FF).opacity(0.25), Color(hex: 0xA9DDFF).opacity(0.55)]),
                                             center: .zero, startRadius: r * 0.3, endRadius: r))
        b.stroke(circle, Color(hex: 0x6CC0F0), tiny ? 1.8 : 1.3)
        var sheen = Path()
        sheen.addArc(center: .zero, radius: r - 1.6, startAngle: .degrees(20), endAngle: .degrees(110), clockwise: false)
        b.stroke(sheen, Color(hex: 0xFFB8DD).opacity(0.75), tiny ? 1.6 : 1.0)
        var shine = Path()
        shine.addArc(center: .zero, radius: r - 2.4, startAngle: .degrees(200), endAngle: .degrees(250), clockwise: false)
        b.stroke(shine, Color.white.opacity(0.95), tiny ? 2 : 1.4)
        b.fill(.ellipse(CGPoint(x: -r * 0.42, y: -r * 0.5), 2.2, 2.2), Color.white.opacity(0.9))
    }

    static func bubble(_ g: GraphicsContext, dark: Bool, content: (GraphicsContext) -> Void) {
        var path = Path.roundedRect(CGRect(x: -10, y: -8, width: 20, height: 16), 7)
        path.move(to: CGPoint(x: 3, y: 7.5))
        path.addLine(to: CGPoint(x: 7, y: 12))
        path.addLine(to: CGPoint(x: 7.5, y: 6))
        g.fill(path.offsetBy(dx: 0, dy: 1), Color.black.opacity(0.12))
        g.fill(path, dark ? Color(hex: 0xF4EFFA) : Color.white)
        g.stroke(path, Color(hex: 0xC9BFD6), 0.8)
        content(g)
    }

    static func orb(_ g: GraphicsContext, phase: Double) {
        g.fill(.ellipse(.zero, 26, 26), with: .radialGradient(Gradient(colors: [Color(hex: 0xC6FF9E).opacity(0.6 + 0.2 * sin(phase * 5)), Color(hex: 0xC6FF9E).opacity(0)]),
                                                            center: .zero, startRadius: 2, endRadius: 13))
        g.fill(.ellipse(.zero, 8, 8), Color(hex: 0xF4FFD9))
        g.text("?", at: CGPoint(x: 0, y: -0.5), size: 6, weight: .heavy, color: Color(hex: 0x6FA84A).opacity(0.8))
    }

    /// Scene-level props in scene points. For butterflies and bubbles `rotation`
    /// is read as an animation phase (wing beat, wobble) rather than a spin.
    static func drawProp(_ prop: SceneProp, in ctx: GraphicsContext, at point: CGPoint, scale: CGFloat, dark: Bool) {
        guard prop.opacity > 0.01 else { return }
        var g = ctx
        g.opacity = Ease.clamp(prop.opacity)
        g.translateBy(x: point.x, y: point.y)
        g.scaleBy(x: scale * CGFloat(prop.scale), y: scale * CGFloat(prop.scale))
        switch prop.kind {
        case .ball:
            ItemRenderer.ball(g, radius: 6.5, spin: prop.rotation)
        case .orb:
            orb(g, phase: prop.rotation)
        case .clap:
            draw(Effect(.clap, x: 0, y: 0), in: g, unitX: 1, unitY: 1, dark: dark)
        case .confetti:
            g.rotate(by: .radians(prop.rotation))
            let color = ConfettiPalette.colors[abs(prop.variant) % ConfettiPalette.colors.count]
            g.fill(.roundedRect(CGRect(x: -3, y: -1.6, width: 6, height: 3.2), 0.8), color)
        case .sparkle:
            g.rotate(by: .radians(prop.rotation))
            g.fill(.sparkle(.zero, radius: 6), Color(hex: 0xFFD166))
            g.fill(.sparkle(.zero, radius: 2.6), Color(hex: 0xFFF6D0))
        case .butterfly:
            g.rotate(by: .radians(0.18 * sin(prop.rotation * 3)))
            butterfly(g, phase: prop.rotation * 12, variant: prop.variant, tiny: false)
        case .yarn:
            ItemRenderer.yarn(g, radius: 7, spin: prop.rotation)
        case .leaf:
            g.rotate(by: .radians(prop.rotation))
            leaf(g, variant: prop.variant)
        case .dust:
            dust(g, phase: 0, dark: dark, tiny: false, flip: prop.variant % 2 == 0)
        case .bubble:
            soapBubble(g, phase: prop.rotation, tiny: false)
        case .treat:
            ItemRenderer.cookie(g, size: 10, spin: prop.rotation)
        case .crumb:
            g.rotate(by: .radians(prop.rotation))
            ItemRenderer.crumb(g, variant: prop.variant, size: 1.3)
        }
    }

    static func leaf(_ g: GraphicsContext, variant: Int) {
        let colors: [(UInt32, UInt32)] = [(0x8ED07A, 0x4F9A45), (0xFFB463, 0xC9772E), (0xF2865E, 0xB9502E)]
        let (fill, edge) = colors[abs(variant) % colors.count]
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -6))
        path.addQuadCurve(to: CGPoint(x: 0, y: 6), control: CGPoint(x: 6, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: -6), control: CGPoint(x: -6, y: 0))
        path.closeSubpath()
        g.fill(path, Color(hex: fill))
        g.stroke(path, Color(hex: edge), 0.8)
        var vein = Path()
        vein.move(to: CGPoint(x: 0, y: -4.5))
        vein.addLine(to: CGPoint(x: 0, y: 7.5))
        g.stroke(vein, Color(hex: edge), 0.7)
    }
}
