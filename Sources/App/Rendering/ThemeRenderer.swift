import SwiftUI
import TamagotchiCore

/// Lightweight procedural backdrops and desks for the tiny office.
enum ThemeRenderer {
    static func background(_ theme: OfficeTheme, in g: GraphicsContext, size: CGSize, ground: CGFloat, dark: Bool, time: Double, hour: Int) {
        let rect = CGRect(origin: .zero, size: size)
        switch theme {
        case .cozyDesk: cozy(g, rect, ground, dark, time, hour)
        case .cyberpunk: cyber(g, rect, ground, dark, time)
        case .spaceStation: space(g, rect, ground, dark, time)
        case .gardenOffice: garden(g, rect, ground, dark, time)
        }
    }

    // MARK: Cozy desk

    static func cozy(_ g: GraphicsContext, _ r: CGRect, _ ground: CGFloat, _ dark: Bool, _ time: Double, _ hour: Int) {
        g.fill(Path(r), with: .linearGradient(Gradient(colors: dark ? [Color(hex: 0x2E2523), Color(hex: 0x241D1B)] : [Color(hex: 0xFCF1E5), Color(hex: 0xF4DFCA)]),
                                              startPoint: .zero, endPoint: CGPoint(x: 0, y: r.height)))
        // Window with the real time of day.
        let window = CGRect(x: r.width * 0.07, y: r.height * 0.13, width: r.width * 0.2, height: r.height * 0.38)
        let night = hour < 7 || hour >= 19
        let sky = night ? [Color(hex: 0x27335F), Color(hex: 0x3D4C7D)] : [Color(hex: 0xBFE0FF), Color(hex: 0xEAF5FF)]
        let pane = Path.roundedRect(window, 6)
        g.fill(pane, with: .linearGradient(Gradient(colors: sky), startPoint: CGPoint(x: 0, y: window.minY), endPoint: CGPoint(x: 0, y: window.maxY)))
        var inside = g
        inside.clip(to: pane)
        if night {
            inside.fill(.ellipse(CGPoint(x: window.maxX - 12, y: window.minY + 12), 9, 9), Color(hex: 0xFFF1C9))
            inside.fill(.ellipse(CGPoint(x: window.maxX - 9, y: window.minY + 10), 8, 8), Color(hex: 0x27335F))
            for index in 0..<5 {
                let x = window.minX + CGFloat(Ease.hash(index, 3)) * window.width
                let y = window.minY + CGFloat(Ease.hash(index + 9, 3)) * window.height * 0.7
                inside.fill(.sparkle(CGPoint(x: x, y: y), radius: 1.6 + CGFloat(sin(time * 2 + Double(index))) * 0.4), Color.white.opacity(0.8))
            }
        } else {
            let drift = CGFloat(Ease.fract(time / 80)) * (window.width + 30) - 15
            for (dx, w) in [(0.0, 16.0), (8.0, 12.0), (-7.0, 11.0)] {
                inside.fill(.ellipse(CGPoint(x: window.minX + drift + CGFloat(dx), y: window.minY + window.height * 0.4), CGFloat(w), CGFloat(w) * 0.6),
                            Color.white.opacity(0.9))
            }
        }
        g.stroke(pane, dark ? Color(hex: 0x54453E) : Color(hex: 0xE4CDB3), 3)
        var mullion = Path()
        mullion.move(to: CGPoint(x: window.midX, y: window.minY))
        mullion.addLine(to: CGPoint(x: window.midX, y: window.maxY))
        g.stroke(mullion, dark ? Color(hex: 0x54453E) : Color(hex: 0xE4CDB3), 2)

        // A little framed heart.
        let frame = CGRect(x: r.width * 0.44, y: r.height * 0.16, width: 22, height: 18)
        g.fill(.roundedRect(frame, 2), dark ? Color(hex: 0x3B302C) : Color.white)
        g.stroke(.roundedRect(frame, 2), dark ? Color(hex: 0x6A574E) : Color(hex: 0xD9B994), 2)
        g.fill(.heart(CGPoint(x: frame.midX, y: frame.midY), size: 9), Color(hex: 0xFF8FA3))

        // Hanging lamp over the desk.
        let lampX = r.width * 0.8
        var cord = Path()
        cord.move(to: CGPoint(x: lampX, y: 0))
        cord.addLine(to: CGPoint(x: lampX, y: r.height * 0.18))
        g.stroke(cord, dark ? Color(hex: 0x6A574E) : Color(hex: 0xC7A98A), 1.2)
        let lampGlow = CGPoint(x: lampX, y: r.height * 0.3)
        g.fill(.ellipse(lampGlow, 110, 80), with: .radialGradient(Gradient(colors: [Color(hex: 0xFFD38A).opacity(dark ? 0.3 : 0.2), Color(hex: 0xFFD38A).opacity(0)]),
                                                                center: lampGlow, startRadius: 4, endRadius: 52))
        var shade = Path()
        shade.move(to: CGPoint(x: lampX - 11, y: r.height * 0.24))
        shade.addLine(to: CGPoint(x: lampX - 5, y: r.height * 0.17))
        shade.addLine(to: CGPoint(x: lampX + 5, y: r.height * 0.17))
        shade.addLine(to: CGPoint(x: lampX + 11, y: r.height * 0.24))
        shade.closeSubpath()
        g.fill(shade, Color(hex: 0xF0A36B))

        let floor = CGRect(x: 0, y: ground, width: r.width, height: r.height - ground)
        g.fill(Path(floor), dark ? Color(hex: 0x3B2F2A) : Color(hex: 0xE9CBA7))
        for index in 0..<6 {
            var plank = Path()
            let x = CGFloat(index) * r.width / 5 + 18
            plank.move(to: CGPoint(x: x, y: ground))
            plank.addLine(to: CGPoint(x: x - 10, y: r.height))
            g.stroke(plank, (dark ? Color.black : Color(hex: 0xC9A47F)).opacity(0.25), 1)
        }
        g.fill(Path(CGRect(x: 0, y: ground - 1, width: r.width, height: 2)), dark ? Color(hex: 0x4D3E37) : Color(hex: 0xDDBA93))
    }

    // MARK: Cyberpunk

    static func cyber(_ g: GraphicsContext, _ r: CGRect, _ ground: CGFloat, _ dark: Bool, _ time: Double) {
        g.fill(Path(r), with: .linearGradient(Gradient(colors: dark ? [Color(hex: 0x1A1338), Color(hex: 0x0D0A1F)] : [Color(hex: 0x2E2458), Color(hex: 0x181232)]),
                                              startPoint: .zero, endPoint: CGPoint(x: 0, y: ground)))
        for index in 0..<11 {
            let width = 18 + CGFloat(Ease.hash(index, 5)) * 22
            let height = r.height * (0.22 + CGFloat(Ease.hash(index + 30, 5)) * 0.4)
            let x = CGFloat(index) * r.width / 10 - 10
            let building = CGRect(x: x, y: ground - height, width: width, height: height)
            g.fill(Path(building), Color(hex: 0x261D4D))
            for window in 0..<6 {
                let lit = Ease.hash(index * 10 + window, UInt64(Int(time / 4))) > 0.55
                guard lit else { continue }
                let wx = building.minX + 4 + CGFloat(window % 2) * (width / 2)
                let wy = building.minY + 6 + CGFloat(window / 2) * 9
                g.fill(Path(CGRect(x: wx, y: wy, width: 3, height: 3)), Color(hex: window % 3 == 0 ? 0xFF6FD8 : 0x67E8F9).opacity(0.75))
            }
        }
        let neon = g
        let pulse = 0.75 + 0.25 * sin(time * 2.4)
        let heart = Path.heart(CGPoint(x: r.width * 0.46, y: r.height * 0.26), size: 20)
        neon.stroke(heart, Color(hex: 0xFF6FD8).opacity(0.25 * pulse), 6)
        neon.stroke(heart, Color(hex: 0xFF6FD8).opacity(pulse), 2)
        let sign = CGRect(x: r.width * 0.06, y: r.height * 0.12, width: 42, height: 14)
        neon.stroke(.roundedRect(sign, 4), Color(hex: 0x67E8F9).opacity(pulse), 1.6)
        for (index, color) in [0xFF6FD8, 0xFFD166, 0x67E8F9].enumerated() {
            let width: CGFloat = [9, 6, 11][index]
            neon.fill(.roundedRect(CGRect(x: sign.minX + 5 + CGFloat(index) * 12, y: sign.midY - 1.2, width: width, height: 2.4), 1.2),
                      Color(hex: UInt32(color)).opacity(pulse))
        }

        let floor = CGRect(x: 0, y: ground, width: r.width, height: r.height - ground)
        g.fill(Path(floor), Color(hex: 0x120D26))
        var grid = g
        grid.clip(to: Path(floor))
        let vanishing = CGPoint(x: r.width / 2, y: ground - 40)
        for index in -8...8 {
            var line = Path()
            line.move(to: CGPoint(x: vanishing.x + CGFloat(index) * 8, y: ground))
            line.addLine(to: CGPoint(x: vanishing.x + CGFloat(index) * 60, y: r.height))
            grid.stroke(line, Color(hex: 0xFF6FD8).opacity(0.35), 0.8)
        }
        for index in 0..<4 {
            let p = Ease.fract(Double(index) / 4 + time / 6)
            let y = ground + CGFloat(p * p) * (r.height - ground)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: r.width, y: y))
            grid.stroke(line, Color(hex: 0x67E8F9).opacity(0.3), 0.8)
        }
    }

    // MARK: Space station

    static func space(_ g: GraphicsContext, _ r: CGRect, _ ground: CGFloat, _ dark: Bool, _ time: Double) {
        let wall = dark ? [Color(hex: 0x1C2238), Color(hex: 0x141A2E)] : [Color(hex: 0xE9EDF5), Color(hex: 0xD6DCE8)]
        g.fill(Path(r), with: .linearGradient(Gradient(colors: wall), startPoint: .zero, endPoint: CGPoint(x: 0, y: ground)))
        for index in 0..<4 {
            let x = CGFloat(index) * r.width / 3.5
            g.fill(Path(CGRect(x: x, y: 0, width: 1.5, height: ground)), (dark ? Color.white : Color(hex: 0x9AA4BC)).opacity(0.12))
        }
        let center = CGPoint(x: r.width * 0.2, y: r.height * 0.36)
        let radius = min(r.height * 0.27, 40)
        let porthole = Path.ellipse(center, radius * 2, radius * 2)
        g.fill(porthole, Color(hex: 0x070B1D))
        var view = g
        view.clip(to: porthole)
        for index in 0..<16 {
            let x = center.x - radius + CGFloat(Ease.hash(index, 7)) * radius * 2
            let y = center.y - radius + CGFloat(Ease.hash(index + 50, 7)) * radius * 2
            let twinkle = 0.5 + 0.5 * sin(time * 1.5 + Double(index))
            view.fill(.ellipse(CGPoint(x: x, y: y), 1.6, 1.6), Color.white.opacity(0.4 + 0.5 * twinkle))
        }
        let planet = CGPoint(x: center.x + radius * 0.35, y: center.y + radius * 0.3)
        view.fill(.ellipse(planet, radius * 0.9, radius * 0.9), with: .linearGradient(Gradient(colors: [Color(hex: 0x9C8CFF), Color(hex: 0x5E4FC9)]),
                                                                                        startPoint: CGPoint(x: planet.x - 10, y: planet.y - 10), endPoint: planet))
        var ring = view
        ring.translateBy(x: planet.x, y: planet.y)
        ring.rotate(by: .degrees(-18))
        ring.stroke(.ellipse(.zero, radius * 1.5, radius * 0.4), Color(hex: 0xFFD166).opacity(0.8), 1.4)
        g.stroke(porthole, dark ? Color(hex: 0x495272) : Color(hex: 0xAAB3C8), 4)
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            g.fill(.ellipse(CGPoint(x: center.x + CGFloat(cos(angle)) * (radius + 0.5), y: center.y + CGFloat(sin(angle)) * (radius + 0.5)), 2.4, 2.4),
                   dark ? Color(hex: 0x7B85A6) : Color(hex: 0x8792AD))
        }
        let blink = sin(time * 3) > 0 ? 1.0 : 0.35
        g.fill(.ellipse(CGPoint(x: r.width * 0.5, y: r.height * 0.18), 5, 5), Color(hex: 0x7FE3CB).opacity(blink))
        g.fill(.ellipse(CGPoint(x: r.width * 0.53, y: r.height * 0.18), 5, 5), Color(hex: 0xFFB24A).opacity(1.35 - blink))

        let floor = CGRect(x: 0, y: ground, width: r.width, height: r.height - ground)
        g.fill(Path(floor), dark ? Color(hex: 0x2A3150) : Color(hex: 0xC3CADB))
        for index in 0..<8 {
            g.fill(Path(CGRect(x: CGFloat(index) * r.width / 7, y: ground, width: 1, height: r.height - ground)), Color.black.opacity(0.12))
        }
    }

    // MARK: Garden office

    static func garden(_ g: GraphicsContext, _ r: CGRect, _ ground: CGFloat, _ dark: Bool, _ time: Double) {
        let sky = dark ? [Color(hex: 0x1C2C24), Color(hex: 0x15211B)] : [Color(hex: 0xEAF7E4), Color(hex: 0xD4EECB)]
        g.fill(Path(r), with: .linearGradient(Gradient(colors: sky), startPoint: .zero, endPoint: CGPoint(x: 0, y: ground)))
        for index in 0..<7 {
            let x = CGFloat(index) * r.width / 6
            g.fill(.ellipse(CGPoint(x: x, y: ground - 6), 64, 44), (dark ? Color(hex: 0x2B4535) : Color(hex: 0xB5DFA6)).opacity(0.9))
        }
        // Vines from the top.
        for index in 0..<5 {
            let x = r.width * (0.1 + CGFloat(index) * 0.2)
            let length = r.height * (0.2 + CGFloat(Ease.hash(index, 9)) * 0.18)
            var vine = Path()
            vine.move(to: CGPoint(x: x, y: 0))
            vine.addQuadCurve(to: CGPoint(x: x + 6, y: length), control: CGPoint(x: x - 8, y: length / 2))
            g.stroke(vine, dark ? Color(hex: 0x3F6A4C) : Color(hex: 0x7CBF6A), 1.4)
            for leaf in 0..<3 {
                let t = CGFloat(leaf + 1) / 4
                var l = g
                l.translateBy(x: x - 2 + t * 6, y: length * t)
                l.rotate(by: .radians(leaf % 2 == 0 ? 0.7 : -0.7))
                l.fill(.ellipse(.zero, 5, 9), dark ? Color(hex: 0x4D8A5E) : Color(hex: 0x8ED07A))
            }
        }
        if dark {
            for index in 0..<6 {
                let phase = time * 0.6 + Double(index) * 1.7
                let x = r.width * CGFloat(Ease.hash(index, 4)) + CGFloat(sin(phase)) * 10
                let y = r.height * (0.25 + 0.4 * CGFloat(Ease.hash(index + 4, 4))) + CGFloat(cos(phase * 1.3)) * 6
                let point = CGPoint(x: x, y: y)
                let alpha = 0.5 + 0.4 * sin(phase * 3)
                g.fill(.ellipse(point, 10, 10), with: .radialGradient(Gradient(colors: [Color(hex: 0xE9FF9E).opacity(alpha), Color(hex: 0xE9FF9E).opacity(0)]),
                                                                    center: point, startRadius: 0.5, endRadius: 5))
            }
        }
        let floor = CGRect(x: 0, y: ground, width: r.width, height: r.height - ground)
        g.fill(Path(floor), dark ? Color(hex: 0x2E4A35) : Color(hex: 0xA6D893))
        for index in 0..<14 {
            let x = CGFloat(index) * r.width / 13 + 4
            var tuft = Path()
            tuft.move(to: CGPoint(x: x - 3, y: ground + 2))
            tuft.addLine(to: CGPoint(x: x, y: ground - 4))
            tuft.addLine(to: CGPoint(x: x + 3, y: ground + 2))
            g.stroke(tuft, dark ? Color(hex: 0x3F6A4C) : Color(hex: 0x7CBF6A), 1.2)
            if index % 4 == 1 {
                g.fill(.ellipse(CGPoint(x: x + 6, y: ground + 8), 4, 4), Color(hex: index % 8 == 1 ? 0xFF8FB1 : 0xFFD166))
            }
        }
    }

    // MARK: Desks (companion local units: desk top at y -21)

    static func deskFront(_ theme: OfficeTheme, in g: GraphicsContext, dark: Bool, accessory: Accessory?) {
        let top: Color
        let front: Color
        let edge: Color
        switch theme {
        case .cozyDesk:
            top = Color(hex: 0xDCA472); front = Color(hex: 0xBA8053); edge = Color(hex: 0x95633F)
        case .cyberpunk:
            top = Color(hex: 0x3A3460); front = Color(hex: 0x272246); edge = Color(hex: 0x67E8F9)
        case .spaceStation:
            top = Color(hex: 0xF4F6FA); front = Color(hex: 0xD9DEE8); edge = Color(hex: 0x9AA4BC)
        case .gardenOffice:
            top = Color(hex: 0xE8C796); front = Color(hex: 0xCFA770); edge = Color(hex: 0xA9824F)
        }
        // Wide enough for the mascot, its laptop and one decoration (see CompanionRenderer).
        g.fill(.ellipse(CGPoint(x: 1, y: 1.5), 126, 8), Color.black.opacity(dark ? 0.3 : 0.12))
        let frontRect = CGRect(x: -56, y: -18, width: 114, height: 18)
        g.fill(.roundedRect(frontRect, 3), front)
        g.stroke(.roundedRect(CGRect(x: 20, y: -14, width: 30, height: 10), 2), edge.opacity(0.6), 1)
        g.fill(.ellipse(CGPoint(x: 35, y: -9), 3, 3), edge)
        g.stroke(.roundedRect(CGRect(x: -50, y: -14, width: 30, height: 10), 2), edge.opacity(0.6), 1)
        g.fill(.ellipse(CGPoint(x: -35, y: -9), 3, 3), edge)
        let topRect = CGRect(x: -60, y: -22.5, width: 122, height: 5)
        g.fill(.roundedRect(topRect, 2.5), top)
        if theme == .cyberpunk {
            g.fill(Path(CGRect(x: -59, y: -19.2, width: 120, height: 3)), edge.opacity(0.25))
            g.fill(Path(CGRect(x: -59, y: -18.2, width: 120, height: 1)), edge)
        } else if theme == .spaceStation {
            g.fill(.ellipse(CGPoint(x: 0, y: -9), 4, 4), Color(hex: 0x7FE3CB))
        } else {
            g.stroke(.roundedRect(topRect, 2.5), edge.opacity(0.5), 0.8)
        }
        if let accessory, accessory.slot == .desk {
            AccessoryRenderer.desk(accessory, g)
        }
    }
}
