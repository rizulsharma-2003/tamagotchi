import SwiftUI
import TamagotchiCore

/// Wearables for both characters and desk decorations.
enum AccessoryRenderer {
    static let ink = Color(hex: 0x4A3B4F)

    // MARK: Pet (head top ≈ y -54, ears at ±14.5, eyes at ±10.5, -29.5)

    static func petWearable(_ accessory: Accessory, _ g: GraphicsContext) {
        switch accessory {
        case .partyHat: partyHat(g, base: CGPoint(x: 3, y: -50), height: 20, tilt: 0.18)
        case .beanie: beanie(g, center: CGPoint(x: 0, y: -46), width: 46)
        case .graduationCap: graduationCap(g, center: CGPoint(x: 0, y: -55), width: 34)
        case .detectiveHat: deerstalker(g, center: CGPoint(x: 0, y: -50), width: 38)
        case .santaHat: festiveHat(g, center: CGPoint(x: 0, y: -48), width: 40)
        case .flowerCrown: flowerCrown(g, center: CGPoint(x: 0, y: -50), width: 34)
        case .witchHat: witchHat(g, center: CGPoint(x: 0, y: -49), width: 44)
        case .roundGlasses: glasses(g, left: CGPoint(x: -10.5, y: -29.5), right: CGPoint(x: 10.5, y: -29.5), radius: 7)
        case .headphones: headphones(g, center: CGPoint(x: 0, y: -30), width: 56, top: -58)
        default: break
        }
    }

    static func petHatItem(_ item: HeldItem, _ g: GraphicsContext) {
        switch item {
        case .gradCap: graduationCap(g, center: CGPoint(x: 0, y: -55), width: 34)
        case .detectiveHat: deerstalker(g, center: CGPoint(x: 0, y: -50), width: 38)
        default: break
        }
    }

    static func petHoodie(_ g: GraphicsContext) {
        var lower = g
        lower.clip(to: PetRenderer.bodyPath())
        lower.fill(Path(CGRect(x: -40, y: -15, width: 80, height: 20)), Color(hex: 0x7C8CF2))
        var hem = Path()
        hem.move(to: CGPoint(x: -31, y: -15))
        hem.addLine(to: CGPoint(x: 31, y: -15))
        lower.stroke(hem, Color(hex: 0x5D6BD0), 1.4)
        lower.stroke(.roundedRect(CGRect(x: -9, y: -11, width: 18, height: 7), 3), Color(hex: 0x5D6BD0), 1.2)
        for side in [-1.0, 1.0] {
            var string = Path()
            string.move(to: CGPoint(x: CGFloat(side) * 5, y: -15))
            string.addLine(to: CGPoint(x: CGFloat(side) * 5.5, y: -9))
            g.stroke(string, Color.white.opacity(0.9), 1.2)
        }
    }

    static func petScarf(_ g: GraphicsContext) {
        var band = Path()
        band.move(to: CGPoint(x: -29, y: -16))
        band.addQuadCurve(to: CGPoint(x: 29, y: -16), control: CGPoint(x: 0, y: -9))
        band.addLine(to: CGPoint(x: 28, y: -10))
        band.addQuadCurve(to: CGPoint(x: -28, y: -10), control: CGPoint(x: 0, y: -3))
        band.closeSubpath()
        var clipped = g
        clipped.clip(to: PetRenderer.bodyPath())
        clipped.fill(band, Color(hex: 0xE85D75))
        var tail = Path.roundedRect(CGRect(x: 12, y: -11, width: 7, height: 13), 2)
        tail = tail.applying(CGAffineTransform(rotationAngle: -0.15))
        g.fill(tail, Color(hex: 0xD94A63))
        g.stroke(tail, Color(hex: 0xB93A52), 0.8)
    }

    // MARK: Companion (head 46×38 centered at (0, -58), top at -77, eyes at ±8, -60)

    static func companionWearable(_ accessory: Accessory, _ g: GraphicsContext) {
        switch accessory {
        case .partyHat: partyHat(g, base: CGPoint(x: 9, y: -76), height: 20, tilt: 0.25)
        case .beanie: beanie(g, center: CGPoint(x: 0, y: -70), width: 50)
        case .graduationCap: graduationCap(g, center: CGPoint(x: 0, y: -79), width: 40)
        case .detectiveHat: deerstalker(g, center: CGPoint(x: 0, y: -75), width: 44)
        case .santaHat: festiveHat(g, center: CGPoint(x: 0, y: -73), width: 46)
        case .flowerCrown: flowerCrown(g, center: CGPoint(x: 0, y: -77), width: 40)
        case .witchHat: witchHat(g, center: CGPoint(x: 0, y: -74), width: 50)
        case .roundGlasses: glasses(g, left: CGPoint(x: -8, y: -60), right: CGPoint(x: 8, y: -60), radius: 7.2)
        case .headphones: headphones(g, center: CGPoint(x: 0, y: -58), width: 58, top: -84)
        default: break
        }
    }

    static func companionHatItem(_ item: HeldItem, _ g: GraphicsContext) {
        switch item {
        case .detectiveHat: deerstalker(g, center: CGPoint(x: 0, y: -75), width: 44)
        case .gradCap: graduationCap(g, center: CGPoint(x: 0, y: -79), width: 40)
        default: break
        }
    }

    static func companionHood(_ g: GraphicsContext) {
        let hood = Path.roundedRect(CGRect(x: -27, y: -80, width: 54, height: 46), 18)
        g.fill(hood, Color(hex: 0x6B7BE0))
        g.stroke(hood, Color(hex: 0x5160C4), 1.4)
    }

    static func companionScarf(_ g: GraphicsContext) {
        let band = Path.roundedRect(CGRect(x: -17, y: -43, width: 34, height: 7), 3.5)
        g.fill(band, Color(hex: 0xE85D75))
        g.stroke(band, Color(hex: 0xB93A52), 0.9)
        let tail = Path.roundedRect(CGRect(x: 8, y: -39, width: 6.5, height: 13), 2)
        g.fill(tail, Color(hex: 0xD94A63))
    }

    // MARK: Shared shapes

    static func partyHat(_ g: GraphicsContext, base: CGPoint, height: CGFloat, tilt: Double) {
        var hat = g
        hat.translateBy(x: base.x, y: base.y)
        hat.rotate(by: .radians(tilt))
        var cone = Path()
        cone.move(to: CGPoint(x: -8, y: 0))
        cone.addLine(to: CGPoint(x: 0, y: -height))
        cone.addLine(to: CGPoint(x: 8, y: 0))
        cone.closeSubpath()
        hat.fill(cone, Color(hex: 0xFF8FB1))
        var stripes = hat
        stripes.clip(to: cone)
        for index in 0..<3 {
            let y = -CGFloat(index) * height / 3 - 3
            stripes.fill(Path(CGRect(x: -10, y: y - 1.8, width: 20, height: 2.4)), Color(hex: 0xFFE27A))
        }
        hat.stroke(cone, Color(hex: 0xD9668A), 1)
        hat.fill(.ellipse(CGPoint(x: 0, y: -height), 5.5, 5.5), Color(hex: 0x7FD6C2))
    }

    static func beanie(_ g: GraphicsContext, center: CGPoint, width: CGFloat) {
        let w = width / 2
        var dome = Path()
        dome.move(to: CGPoint(x: center.x - w, y: center.y))
        dome.addCurve(to: CGPoint(x: center.x + w, y: center.y), control1: CGPoint(x: center.x - w, y: center.y - w * 1.05),
                      control2: CGPoint(x: center.x + w, y: center.y - w * 1.05))
        dome.closeSubpath()
        g.fill(dome, Color(hex: 0x6FA8DC))
        for index in -2...2 {
            var rib = Path()
            rib.move(to: CGPoint(x: center.x + CGFloat(index) * w * 0.32, y: center.y - 1))
            rib.addLine(to: CGPoint(x: center.x + CGFloat(index) * w * 0.22, y: center.y - w * 0.65))
            g.stroke(rib, Color(hex: 0x5A8FC2), 1)
        }
        let band = Path.roundedRect(CGRect(x: center.x - w - 1, y: center.y - 4.5, width: width + 2, height: 7), 3.5)
        g.fill(band, Color(hex: 0x4F7FB4))
        g.fill(.ellipse(CGPoint(x: center.x, y: center.y - w * 0.82), 8, 8), Color(hex: 0xF4F1EA))
    }

    static func graduationCap(_ g: GraphicsContext, center: CGPoint, width: CGFloat) {
        let w = width / 2
        g.fill(.roundedRect(CGRect(x: center.x - w * 0.5, y: center.y, width: w, height: w * 0.42), 2), Color(hex: 0x2B2B36))
        var board = Path()
        board.move(to: CGPoint(x: center.x - w, y: center.y))
        board.addLine(to: CGPoint(x: center.x, y: center.y - w * 0.34))
        board.addLine(to: CGPoint(x: center.x + w, y: center.y))
        board.addLine(to: CGPoint(x: center.x, y: center.y + w * 0.34))
        board.closeSubpath()
        g.fill(board, Color(hex: 0x34343F))
        g.stroke(board, Color(hex: 0x1F1F27), 0.8)
        var tassel = Path()
        tassel.move(to: center)
        tassel.addLine(to: CGPoint(x: center.x + w * 0.72, y: center.y + 1))
        tassel.addLine(to: CGPoint(x: center.x + w * 0.74, y: center.y + w * 0.55))
        g.stroke(tassel, Color(hex: 0xF5C451), 1.3)
        g.fill(.ellipse(CGPoint(x: center.x + w * 0.74, y: center.y + w * 0.6), 3, 4), Color(hex: 0xF5C451))
        g.fill(.ellipse(center, 2.4, 2.4), Color(hex: 0xF5C451))
    }

    static func deerstalker(_ g: GraphicsContext, center: CGPoint, width: CGFloat) {
        let w = width / 2
        var brim = Path()
        brim.move(to: CGPoint(x: center.x - w, y: center.y + 1))
        brim.addQuadCurve(to: CGPoint(x: center.x + w, y: center.y + 1), control: CGPoint(x: center.x, y: center.y + 5))
        g.stroke(brim, Color(hex: 0x7D5130), 3.4)
        var dome = Path()
        dome.move(to: CGPoint(x: center.x - w * 0.78, y: center.y))
        dome.addCurve(to: CGPoint(x: center.x + w * 0.78, y: center.y), control1: CGPoint(x: center.x - w * 0.8, y: center.y - w * 0.95),
                      control2: CGPoint(x: center.x + w * 0.8, y: center.y - w * 0.95))
        dome.closeSubpath()
        g.fill(dome, Color(hex: 0xA67445))
        var checks = g
        checks.clip(to: dome)
        for index in -3...3 {
            checks.fill(Path(CGRect(x: center.x + CGFloat(index) * 5 - 0.6, y: center.y - w, width: 1.2, height: w)), Color(hex: 0x7D5130).opacity(0.6))
        }
        checks.fill(Path(CGRect(x: center.x - w, y: center.y - w * 0.45, width: width, height: 1.2)), Color(hex: 0x7D5130).opacity(0.6))
        g.stroke(dome, Color(hex: 0x6A4426), 1)
        g.fill(.ellipse(CGPoint(x: center.x, y: center.y - w * 0.72), 4, 3), Color(hex: 0x7D5130))
    }

    static func festiveHat(_ g: GraphicsContext, center: CGPoint, width: CGFloat) {
        let w = width / 2
        var hat = Path()
        hat.move(to: CGPoint(x: center.x - w * 0.85, y: center.y))
        hat.addQuadCurve(to: CGPoint(x: center.x + w * 1.1, y: center.y - w * 0.6), control: CGPoint(x: center.x - w * 0.2, y: center.y - w * 1.6))
        hat.addQuadCurve(to: CGPoint(x: center.x + w * 0.85, y: center.y), control: CGPoint(x: center.x + w * 0.5, y: center.y - w * 0.5))
        hat.closeSubpath()
        g.fill(hat, Color(hex: 0xE04B5A))
        g.fill(.roundedRect(CGRect(x: center.x - w, y: center.y - 4, width: width, height: 7), 3.5), Color.white)
        g.fill(.ellipse(CGPoint(x: center.x + w * 1.1, y: center.y - w * 0.6), 7, 7), Color.white)
    }

    /// A crooked purple witch hat with an orange band, for Halloween.
    static func witchHat(_ g: GraphicsContext, center: CGPoint, width: CGFloat) {
        let w = width / 2
        let purple = Color(hex: 0x5B3F8C)
        let purpleDark = Color(hex: 0x40296A)
        g.fill(.ellipse(CGPoint(x: center.x, y: center.y), width, w * 0.42), purpleDark)
        var cone = Path()
        cone.move(to: CGPoint(x: center.x - w * 0.55, y: center.y - 1))
        cone.addQuadCurve(to: CGPoint(x: center.x + w * 0.05, y: center.y - w * 1.5), control: CGPoint(x: center.x - w * 0.38, y: center.y - w * 0.9))
        cone.addQuadCurve(to: CGPoint(x: center.x + w * 0.62, y: center.y - w * 1.2), control: CGPoint(x: center.x + w * 0.38, y: center.y - w * 1.55))
        cone.addQuadCurve(to: CGPoint(x: center.x + w * 0.55, y: center.y - 1), control: CGPoint(x: center.x + w * 0.3, y: center.y - w * 0.7))
        cone.closeSubpath()
        g.fill(cone, purple)
        g.fill(.roundedRect(CGRect(x: center.x - w * 0.5, y: center.y - w * 0.36, width: w * 1.0, height: w * 0.22), 1.5), Color(hex: 0xFF9C3F))
        g.fill(.roundedRect(CGRect(x: center.x - w * 0.08, y: center.y - w * 0.38, width: w * 0.2, height: w * 0.26), 1), Color(hex: 0xFFD166))
    }

    static func flowerCrown(_ g: GraphicsContext, center: CGPoint, width: CGFloat) {
        let w = width / 2
        let colors = [Color(hex: 0xFF8FB1), Color(hex: 0xFFD166), Color(hex: 0xB9A7FF), Color(hex: 0xFF9F80), Color(hex: 0x7FD6C2)]
        for index in 0..<5 {
            let t = Double(index) / 4
            let x = center.x - w + CGFloat(t) * width
            let y = center.y + CGFloat(pow(t - 0.5, 2)) * 10 - 2
            g.fill(.ellipse(CGPoint(x: x + 3.5, y: y + 1), 4, 2.4), Color(hex: 0x6FB794))
            for petal in 0..<5 {
                let angle = Double(petal) * 2 * .pi / 5
                g.fill(.ellipse(CGPoint(x: x + CGFloat(cos(angle)) * 2.4, y: y + CGFloat(sin(angle)) * 2.4), 3, 3), colors[index])
            }
            g.fill(.ellipse(CGPoint(x: x, y: y), 2, 2), Color(hex: 0xFFF6D8))
        }
    }

    static func glasses(_ g: GraphicsContext, left: CGPoint, right: CGPoint, radius: CGFloat) {
        for center in [left, right] {
            let lens = Path.ellipse(center, radius * 2, radius * 2)
            g.fill(lens, Color.white.opacity(0.14))
            g.stroke(lens, Color(hex: 0x3B3B48), 1.6)
        }
        var bridge = Path()
        bridge.move(to: CGPoint(x: left.x + radius, y: left.y))
        bridge.addQuadCurve(to: CGPoint(x: right.x - radius, y: right.y), control: CGPoint(x: (left.x + right.x) / 2, y: left.y - 2.5))
        g.stroke(bridge, Color(hex: 0x3B3B48), 1.4)
    }

    static func headphones(_ g: GraphicsContext, center: CGPoint, width: CGFloat, top: CGFloat) {
        let w = width / 2
        var band = Path()
        band.move(to: CGPoint(x: center.x - w + 2, y: center.y - 2))
        band.addCurve(to: CGPoint(x: center.x + w - 2, y: center.y - 2), control1: CGPoint(x: center.x - w, y: top),
                      control2: CGPoint(x: center.x + w, y: top))
        g.stroke(band, Color(hex: 0x4A4A5A), 3.4)
        for side in [-1.0, 1.0] {
            let cup = Path.roundedRect(CGRect(x: center.x + CGFloat(side) * (w - 2) - 5, y: center.y - 8, width: 10, height: 15), 4.5)
            g.fill(cup, Color(hex: 0x5E5E70))
            g.fill(.roundedRect(CGRect(x: center.x + CGFloat(side) * (w - 2) - 2.5, y: center.y - 5, width: 5, height: 9), 2.5), Color(hex: 0xFF8FA3))
        }
    }

    // MARK: Desk decorations (desk top at y -22.5, desk spans x -60…62; the right corner is free)

    static func desk(_ accessory: Accessory, _ g: GraphicsContext) {
        let spot = CGPoint(x: 54, y: -22.5)
        switch accessory {
        case .plant:
            g.fill(.roundedRect(CGRect(x: spot.x - 4.5, y: spot.y - 9, width: 9, height: 9), 2), Color(hex: 0xD98E5F))
            for (angle, length) in [(-0.5, 11.0), (0.1, 13.0), (0.6, 10.0)] {
                var leaf = g
                leaf.translateBy(x: spot.x, y: spot.y - 9)
                leaf.rotate(by: .radians(angle))
                leaf.fill(.ellipse(CGPoint(x: 0, y: -length / 2), 5, length), Color(hex: 0x6FB794))
            }
        case .coffeeMug:
            ItemRenderer.draw(.coffee, in: g, at: CGPoint(x: spot.x, y: spot.y - 6), size: 13)
        case .rubberDuck:
            g.fill(.ellipse(CGPoint(x: spot.x, y: spot.y - 4), 12, 8), Color(hex: 0xFFD54A))
            g.fill(.ellipse(CGPoint(x: spot.x + 3, y: spot.y - 10), 7, 7), Color(hex: 0xFFD54A))
            g.fill(.ellipse(CGPoint(x: spot.x + 6.8, y: spot.y - 9.5), 3.6, 2), Color(hex: 0xFF9248))
            g.fill(.ellipse(CGPoint(x: spot.x + 4, y: spot.y - 11), 1.4, 1.4), Color(hex: 0x2C2234))
        case .pumpkin:
            for offset in [-3.0, 0.0, 3.0] {
                g.fill(.ellipse(CGPoint(x: spot.x + CGFloat(offset), y: spot.y - 5), 7, 10), Color(hex: offset == 0 ? 0xFF9C3F : 0xF28A2E))
            }
            g.fill(.roundedRect(CGRect(x: spot.x - 1, y: spot.y - 12.5, width: 2.4, height: 4), 1), Color(hex: 0x6B8E3A))
        case .trophy:
            ItemRenderer.draw(.trophy, in: g, at: CGPoint(x: spot.x, y: spot.y - 7), size: 14)
        case .lavaLamp:
            g.fill(.roundedRect(CGRect(x: spot.x - 3.5, y: spot.y - 18, width: 7, height: 15), 3.5), Color(hex: 0xB9A7FF).opacity(0.7))
            g.fill(.ellipse(CGPoint(x: spot.x, y: spot.y - 12), 4, 5), Color(hex: 0xFF8FB1))
            g.fill(.roundedRect(CGRect(x: spot.x - 4.5, y: spot.y - 4, width: 9, height: 4), 1.5), Color(hex: 0x5E5E70))
        default:
            break
        }
    }
}
