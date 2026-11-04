import AppKit
import TamagotchiCore

/// Draws the menu-bar icon: Mochi's silhouette with cut-out expressions, plus a
/// mini Patch head while a Claude Code session is active. Template image, so it
/// adapts to light/dark menu bars and the selection highlight automatically.
enum MenuBarGlyph {
    struct Frame: Equatable {
        /// 0…1 cycling phase for subtle loops.
        var phase: Double
        var blink: Bool
        /// Celebration hop height in points.
        var bounce: CGFloat
    }

    static let height: CGFloat = 18

    static func width(companion: Bool) -> CGFloat { companion ? 31 : 19 }

    static func image(for status: MenuBarStatus, frame: Frame) -> NSImage {
        let size = NSSize(width: width(companion: status.companionVisible), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(status, frame: frame, in: cg)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description(for: status)
        return image
    }

    static func description(for status: MenuBarStatus) -> String {
        switch status.mood {
        case .content: return status.companionVisible ? "MacTamagotchi — Claude Code session open" : "MacTamagotchi"
        case .sleeping: return "MacTamagotchi — napping"
        case .watching: return "MacTamagotchi — Claude is working"
        case .waiting: return "MacTamagotchi — Claude is waiting for you"
        case .concerned: return "MacTamagotchi — a tool reported an error"
        case .celebrating: return "MacTamagotchi — turn complete"
        case .offline: return "MacTamagotchi — event bridge unavailable"
        case .paused: return "MacTamagotchi — reactions paused"
        }
    }

    static func draw(_ status: MenuBarStatus, frame: Frame, in cg: CGContext) {
        cg.setFillColor(NSColor.black.cgColor)
        cg.setStrokeColor(NSColor.black.cgColor)
        let lift = frame.bounce
        cg.saveGState()
        cg.translateBy(x: 0, y: lift)
        drawPet(status, frame: frame, in: cg)
        cg.restoreGState()
        if status.companionVisible {
            drawCompanion(status, frame: frame, in: cg)
        }
        if status.mood == .celebrating {
            for (x, y, r) in [(1.6, 14.5 - Double(lift) * 0.3, 1.8), (17.2, 15.2, 1.5)] {
                sparkle(in: cg, center: CGPoint(x: x, y: y), radius: CGFloat(r) * (0.7 + 0.3 * CGFloat(frame.phase)))
            }
        }
    }

    static func drawPet(_ status: MenuBarStatus, frame: Frame, in cg: CGContext) {
        // Body: a soft dome.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 1.6, y: 3))
        body.addCurve(to: CGPoint(x: 9, y: 13.6), control1: CGPoint(x: 1.2, y: 10.2), control2: CGPoint(x: 4.6, y: 13.6))
        body.addCurve(to: CGPoint(x: 16.4, y: 3), control1: CGPoint(x: 13.4, y: 13.6), control2: CGPoint(x: 16.8, y: 10.2))
        body.addCurve(to: CGPoint(x: 9, y: 1), control1: CGPoint(x: 16.3, y: 1.4), control2: CGPoint(x: 12.6, y: 1))
        body.addCurve(to: CGPoint(x: 1.6, y: 3), control1: CGPoint(x: 5.4, y: 1), control2: CGPoint(x: 1.7, y: 1.4))
        body.closeSubpath()
        cg.addPath(body)
        cg.fillPath()
        // Ears.
        let droop: CGFloat = status.mood == .concerned || status.mood == .sleeping ? 1.2 : 0
        for side: CGFloat in [-1, 1] {
            let ear = CGMutablePath()
            let baseX = 9 + side * 3.6
            ear.move(to: CGPoint(x: baseX - 2.3, y: 11.6))
            ear.addLine(to: CGPoint(x: baseX + side * (0.9 + droop), y: 16.6 - droop))
            ear.addLine(to: CGPoint(x: baseX + 2.3, y: 11.6))
            ear.closeSubpath()
            cg.addPath(ear)
            cg.fillPath()
        }

        // Cut out the face.
        cg.setBlendMode(.clear)
        let left = CGPoint(x: 6.3, y: 7)
        let right = CGPoint(x: 11.7, y: 7)
        let closedEyes = frame.blink || status.mood == .sleeping || status.mood == .paused
        switch status.mood {
        case .celebrating:
            for eye in [left, right] { arc(in: cg, center: eye, up: true) }
            let mouth = CGMutablePath()
            mouth.addEllipse(in: CGRect(x: 7.9, y: 3.2, width: 2.2, height: 1.7))
            cg.addPath(mouth)
            cg.fillPath()
        case .offline:
            for eye in [left, right] { cg.fill(CGRect(x: eye.x - 1.3, y: eye.y - 0.4, width: 2.6, height: 0.9)) }
        case .concerned:
            for eye in [left, right] { cg.fillEllipse(in: CGRect(x: eye.x - 0.95, y: eye.y - 1.4, width: 1.9, height: 2.5)) }
            for (eye, side) in [(left, CGFloat(-1)), (right, CGFloat(1))] {
                cg.setLineWidth(0.9)
                cg.move(to: CGPoint(x: eye.x + side * 1.5, y: eye.y + 2.1))
                cg.addLine(to: CGPoint(x: eye.x - side * 1.0, y: eye.y + 2.9))
                cg.strokePath()
            }
        case .waiting:
            for eye in [left, right] { cg.fillEllipse(in: CGRect(x: eye.x - 1.3, y: eye.y - 1.7, width: 2.6, height: 3.5)) }
        default:
            if closedEyes {
                for eye in [left, right] { arc(in: cg, center: eye, up: false) }
            } else {
                let lookX: CGFloat = status.mood == .watching ? 0.7 : 0
                for eye in [left, right] {
                    cg.fillEllipse(in: CGRect(x: eye.x - 1.1 + lookX, y: eye.y - 1.5, width: 2.2, height: 3.1))
                }
            }
        }
        cg.setBlendMode(.normal)

        if status.mood == .sleeping {
            let z = CGMutablePath()
            z.move(to: CGPoint(x: 14.6, y: 17))
            z.addLine(to: CGPoint(x: 17.6, y: 17))
            z.addLine(to: CGPoint(x: 14.6, y: 14.2))
            z.addLine(to: CGPoint(x: 17.6, y: 14.2))
            cg.setLineWidth(1)
            cg.addPath(z)
            cg.strokePath()
        }
        if status.mood == .paused {
            cg.fill(CGRect(x: 14.8, y: 13.6, width: 1.1, height: 3.6))
            cg.fill(CGRect(x: 16.8, y: 13.6, width: 1.1, height: 3.6))
        }
    }

    static func drawCompanion(_ status: MenuBarStatus, frame: Frame, in cg: CGContext) {
        let head = CGRect(x: 19.6, y: 2.2, width: 10.6, height: 8.8)
        cg.addPath(CGPath(roundedRect: head, cornerWidth: 3, cornerHeight: 3, transform: nil))
        cg.fillPath()
        // Antenna and bulb; the bulb gently blinks while Claude is working.
        cg.setLineWidth(1)
        cg.move(to: CGPoint(x: head.midX, y: head.maxY))
        cg.addLine(to: CGPoint(x: head.midX, y: head.maxY + 2.6))
        cg.strokePath()
        let bulb = CGRect(x: head.midX - 1.45, y: head.maxY + 2.2, width: 2.9, height: 2.9)
        let lit = !status.companionWorking || frame.phase < 0.5
        if lit {
            cg.fillEllipse(in: bulb)
        } else {
            cg.setLineWidth(0.8)
            cg.strokeEllipse(in: bulb.insetBy(dx: 0.4, dy: 0.4))
        }
        // Visor cut-out with eyes.
        cg.setBlendMode(.clear)
        let visor = head.insetBy(dx: 1.7, dy: 1.9)
        cg.addPath(CGPath(roundedRect: visor, cornerWidth: 2, cornerHeight: 2, transform: nil))
        cg.fillPath()
        cg.setBlendMode(.normal)
        let eyeY = visor.midY
        if status.mood == .offline {
            cg.fill(CGRect(x: visor.minX + 1.4, y: eyeY - 0.35, width: 1.8, height: 0.7))
            cg.fill(CGRect(x: visor.maxX - 3.2, y: eyeY - 0.35, width: 1.8, height: 0.7))
        } else if status.companionWorking {
            cg.fill(CGRect(x: visor.minX + 1.2, y: eyeY - 0.5, width: 2.2, height: 1))
            cg.fill(CGRect(x: visor.maxX - 3.4, y: eyeY - 0.5, width: 2.2, height: 1))
        } else {
            cg.fill(CGRect(x: visor.minX + 1.6, y: eyeY - 1.1, width: 1.3, height: 2.2))
            cg.fill(CGRect(x: visor.maxX - 2.9, y: eyeY - 1.1, width: 1.3, height: 2.2))
        }
    }

    static func arc(in cg: CGContext, center: CGPoint, up: Bool) {
        cg.setLineWidth(1.15)
        cg.setLineCap(.round)
        cg.move(to: CGPoint(x: center.x - 1.4, y: center.y + (up ? -0.5 : 0.6)))
        cg.addQuadCurve(to: CGPoint(x: center.x + 1.4, y: center.y + (up ? -0.5 : 0.6)),
                        control: CGPoint(x: center.x, y: center.y + (up ? 2.0 : -1.6)))
        cg.strokePath()
    }

    static func sparkle(in cg: CGContext, center: CGPoint, radius: CGFloat) {
        let path = CGMutablePath()
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            let r = index % 2 == 0 ? radius : radius * 0.3
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        cg.addPath(path)
        cg.fillPath()
    }
}
