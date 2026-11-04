import SwiftUI
import TamagotchiCore

/// Procedural furniture in the scene's style. Each piece draws in its own units (1 unit = 1 pt at
/// scale 1) around its anchor: floor pieces stand on (0, 0), wall pieces and rugs are centred on it.
enum FurnitureArt {
    static func draw(_ id: String, in g: GraphicsContext, dark: Bool, time: Double) {
        switch id {
        case "rug": rug(g, dark: dark)
        case "cushion": cushion(g, dark: dark)
        case "plant": plant(g, dark: dark, time: time)
        case "poster": poster(g, dark: dark)
        case "lamp": lamp(g, dark: dark)
        case "bookshelf": bookshelf(g, dark: dark)
        case "beanbag": beanbag(g, dark: dark)
        case "catTree": catTree(g, dark: dark, time: time)
        case "clock": clock(g, dark: dark)
        case "photo": photo(g, dark: dark)
        case "fishBowl": fishBowl(g, dark: dark, time: time)
        case "toyBox": toyBox(g, dark: dark)
        default: break
        }
    }

    static func shadow(_ g: GraphicsContext, width: CGFloat, dark: Bool) {
        g.fill(.ellipse(CGPoint(x: 0, y: 0.4), width, max(3, width * 0.13)), Color.black.opacity(dark ? 0.32 : 0.13))
    }

    static func rug(_ g: GraphicsContext, dark: Bool) {
        var fringe = Path()
        for index in 0..<7 {
            let y = -4.2 + CGFloat(index) * 1.4
            for side in [-1.0, 1.0] as [CGFloat] {
                fringe.move(to: CGPoint(x: side * 44.6, y: y))
                fringe.addLine(to: CGPoint(x: side * 48.6, y: y + 0.2))
            }
        }
        g.stroke(fringe, Color(hex: 0xF3D9B1), 0.8)
        g.fill(.ellipse(.zero, 92, 15), Color(hex: 0xD9776B))
        g.fill(.ellipse(.zero, 84, 12.2), Color(hex: 0xF3D9B1))
        g.fill(.ellipse(.zero, 76, 10), Color(hex: 0xE38C6E))
        g.stroke(.ellipse(.zero, 60, 7.2), with: .color(Color(hex: 0xF7E3C4)), style: StrokeStyle(lineWidth: 0.9, dash: [2.4, 1.6]))
        var diamonds = Path()
        for x in [-18.0, 0, 18] as [CGFloat] {
            diamonds.move(to: CGPoint(x: x - 4, y: 0))
            diamonds.addLine(to: CGPoint(x: x, y: -1.9))
            diamonds.addLine(to: CGPoint(x: x + 4, y: 0))
            diamonds.addLine(to: CGPoint(x: x, y: 1.9))
            diamonds.closeSubpath()
        }
        g.fill(diamonds, Color(hex: 0x5FB3A8))
        if dark { g.fill(.ellipse(.zero, 92, 15), Color.black.opacity(0.18)) }
    }

    /// A plump, tufted floor pillow.
    static func cushion(_ g: GraphicsContext, dark: Bool) {
        shadow(g, width: 30, dark: dark)
        var pillow = Path()
        pillow.move(to: CGPoint(x: -14, y: -1))
        pillow.addQuadCurve(to: CGPoint(x: -13, y: -12.5), control: CGPoint(x: -16.5, y: -7))
        pillow.addQuadCurve(to: CGPoint(x: 13, y: -12.5), control: CGPoint(x: 0, y: -15.5))
        pillow.addQuadCurve(to: CGPoint(x: 14, y: -1), control: CGPoint(x: 16.5, y: -7))
        pillow.addQuadCurve(to: CGPoint(x: -14, y: -1), control: CGPoint(x: 0, y: 1.5))
        pillow.closeSubpath()
        g.fill(pillow, Color(hex: 0xE8A0A8))
        g.fill(.ellipse(CGPoint(x: -4, y: -10.5), 14, 3.6), Color.white.opacity(0.3))
        var creases = Path()
        for (from, to) in [(CGPoint(x: -6.5, y: -9.5), CGPoint(x: -1.2, y: -7)), (CGPoint(x: 6.5, y: -9.5), CGPoint(x: 1.2, y: -7)),
                           (CGPoint(x: -6.5, y: -3.5), CGPoint(x: -1.2, y: -6)), (CGPoint(x: 6.5, y: -3.5), CGPoint(x: 1.2, y: -6))] {
            creases.move(to: from)
            creases.addLine(to: to)
        }
        g.stroke(creases, Color(hex: 0xC97B86).opacity(0.8), 0.7)
        g.fill(.ellipse(CGPoint(x: 0, y: -6.5), 2.6, 2.2), Color(hex: 0xB8606E))
        for corner in [CGPoint(x: -13.6, y: -12.4), CGPoint(x: 13.6, y: -12.4)] {
            g.fill(.ellipse(corner, 2.4, 2.4), Color(hex: 0xF2C14E))
        }
        g.stroke(pillow, Color(hex: 0xC97B86), 0.8)
    }

    static func plant(_ g: GraphicsContext, dark: Bool, time: Double) {
        shadow(g, width: 24, dark: dark)
        var foliage = g
        foliage.translateBy(x: 0, y: -17)
        foliage.rotate(by: .radians(sin(time * 0.7) * 0.025))
        let leaves: [(Double, CGFloat, CGFloat, UInt32)] = [(-1.15, 19, 8, 0x3E8E5A), (1.1, 19, 8, 0x3E8E5A), (-0.62, 25, 9, 0x4FA36B),
                                                            (0.6, 24, 9, 0x4FA36B), (-0.18, 30, 9.5, 0x5DB477), (0.22, 28, 9, 0x3E8E5A)]
        for (angle, length, width, color) in leaves {
            var leaf = foliage
            leaf.rotate(by: .radians(angle))
            let shape = Path.ellipse(CGPoint(x: 0, y: -length / 2 - 2), width, length)
            leaf.fill(shape, Color(hex: color))
            leaf.stroke(Path { $0.move(to: CGPoint(x: 0, y: -2)); $0.addLine(to: CGPoint(x: 0, y: -length + 1)) }, Color(hex: 0x2F6E45).opacity(0.8), 0.7)
        }
        var pot = Path()
        pot.move(to: CGPoint(x: -9, y: -15))
        pot.addLine(to: CGPoint(x: 9, y: -15))
        pot.addLine(to: CGPoint(x: 6.5, y: 0))
        pot.addLine(to: CGPoint(x: -6.5, y: 0))
        pot.closeSubpath()
        g.fill(pot, Color(hex: 0xD9774A))
        g.fill(.roundedRect(CGRect(x: -10, y: -18, width: 20, height: 4.5), 1.5), Color(hex: 0xE98B5D))
        g.fill(Path(CGRect(x: -6.5, y: -9, width: 13, height: 1.2)), Color(hex: 0xC4643A))
    }

    static func poster(_ g: GraphicsContext, dark: Bool) {
        g.fill(.roundedRect(CGRect(x: -14, y: -18, width: 30, height: 38), 1.5), Color.black.opacity(dark ? 0.3 : 0.1))
        g.fill(.roundedRect(CGRect(x: -15, y: -19, width: 30, height: 38), 1.5), Color(hex: 0xFFFBF4))
        let art = CGRect(x: -12.5, y: -16.5, width: 25, height: 27)
        g.fill(Path(art), with: .linearGradient(Gradient(colors: [Color(hex: 0xFFC59E), Color(hex: 0xFF8FA3), Color(hex: 0x9C7AE0)]),
                                                startPoint: CGPoint(x: 0, y: art.minY), endPoint: CGPoint(x: 0, y: art.maxY)))
        var inside = g
        inside.clip(to: Path(art))
        inside.fill(.ellipse(CGPoint(x: 0, y: -1), 13, 13), Color(hex: 0xFFE08A))
        var far = Path()
        far.move(to: CGPoint(x: -14, y: art.maxY))
        far.addLine(to: CGPoint(x: -5, y: 1))
        far.addLine(to: CGPoint(x: 3, y: art.maxY))
        inside.fill(far, Color(hex: 0x7B66B0))
        var near = Path()
        near.move(to: CGPoint(x: -4, y: art.maxY))
        near.addLine(to: CGPoint(x: 6, y: 3))
        near.addLine(to: CGPoint(x: 15, y: art.maxY))
        inside.fill(near, Color(hex: 0x5B4A8C))
        g.fill(.roundedRect(CGRect(x: -8, y: 12.8, width: 16, height: 1.6), 0.8), Color(hex: 0x9C8FA8))
        g.fill(.roundedRect(CGRect(x: -5, y: 15.4, width: 10, height: 1.2), 0.6), Color(hex: 0xC9C0D4))
        for side in [-1.0, 1.0] as [CGFloat] {
            var tape = g
            tape.translateBy(x: side * 13, y: -18.5)
            tape.rotate(by: .radians(Double(side) * 0.6))
            tape.fill(Path(CGRect(x: -4, y: -1.6, width: 8, height: 3.2)), Color(hex: 0xFFF3C4).opacity(0.75))
        }
    }

    static func lamp(_ g: GraphicsContext, dark: Bool) {
        let light = CGPoint(x: 0, y: -60)
        g.fill(.ellipse(light, 84, 84), with: .radialGradient(Gradient(colors: [Color(hex: 0xFFD38A).opacity(dark ? 0.42 : 0.24), Color(hex: 0xFFD38A).opacity(0)]),
                                                            center: light, startRadius: 2, endRadius: 42))
        shadow(g, width: 20, dark: dark)
        g.fill(.ellipse(CGPoint(x: 0, y: -1.6), 16, 4), Color(hex: 0x5B4A5E))
        g.fill(.roundedRect(CGRect(x: -1.1, y: -68, width: 2.2, height: 67), 1.1), Color(hex: 0x6B5A70))
        var shade = Path()
        shade.move(to: CGPoint(x: -6, y: -84))
        shade.addLine(to: CGPoint(x: 6, y: -84))
        shade.addLine(to: CGPoint(x: 11.5, y: -66))
        shade.addLine(to: CGPoint(x: -11.5, y: -66))
        shade.closeSubpath()
        g.fill(.ellipse(CGPoint(x: 0, y: -66), 21, 4), Color(hex: 0xFFE9B8))
        g.fill(shade, Color(hex: 0xF6C98E))
        var stripes = g
        stripes.clip(to: shade)
        for x in stride(from: -12.0, through: 12, by: 4) {
            stripes.fill(Path(CGRect(x: x, y: -85, width: 1.6, height: 20)).applying(CGAffineTransform(a: 1, b: 0, c: -CGFloat(x) / 40, d: 1, tx: 0, ty: 0)),
                         Color(hex: 0xEDB06C))
        }
        g.stroke(shade, Color(hex: 0xD99A55), 0.8)
    }

    static func bookshelf(_ g: GraphicsContext, dark: Bool) {
        shadow(g, width: 42, dark: dark)
        let frame = Path.roundedRect(CGRect(x: -20, y: -64, width: 40, height: 64), 2)
        g.fill(frame, Color(hex: 0xB97F4E))
        g.fill(Path(CGRect(x: -17, y: -61, width: 34, height: 58)), Color(hex: 0x7A4F2E))
        let colors: [UInt32] = [0xE76F51, 0x2A9D8F, 0xE9C46A, 0x8AB17D, 0x6D597A, 0xF4A261, 0x457B9D, 0xF1E3D3]
        for (row, base) in [-42.0, -22, -3].enumerated() {
            var x: CGFloat = -16
            var index = row * 3
            while x < 14 {
                let width = CGFloat(3 + (index * 7) % 3)
                let height = CGFloat(12 + (index * 5) % 6)
                if row == 1, index == 5 {
                    // A small trinket instead of a book.
                    g.fill(.ellipse(CGPoint(x: x + 3, y: CGFloat(base) - 3.5), 6, 6), Color(hex: 0xFF8FA3))
                    x += 7
                } else {
                    let book = CGRect(x: x, y: CGFloat(base) - height, width: width, height: height)
                    g.fill(Path(book), Color(hex: colors[index % colors.count]))
                    g.fill(Path(CGRect(x: book.minX, y: book.minY + 2.5, width: width, height: 1)), Color.white.opacity(0.35))
                    x += width + 0.6
                }
                index += 1
            }
            g.fill(Path(CGRect(x: -17, y: CGFloat(base), width: 34, height: 2.4)), Color(hex: 0xC98F5C))
        }
        g.stroke(frame, Color(hex: 0x8C5A34), 1)
        // A tiny plant on top.
        g.fill(.roundedRect(CGRect(x: 6, y: -70, width: 7, height: 6), 1.2), Color(hex: 0xD9774A))
        for angle in [-0.6, 0, 0.6] {
            var leaf = g
            leaf.translateBy(x: 9.5, y: -70)
            leaf.rotate(by: .radians(angle))
            leaf.fill(.ellipse(CGPoint(x: 0, y: -3.5), 3.2, 7), Color(hex: 0x4FA36B))
        }
    }

    static func beanbag(_ g: GraphicsContext, dark: Bool) {
        shadow(g, width: 40, dark: dark)
        var bag = Path()
        bag.move(to: CGPoint(x: -19, y: -1))
        bag.addCurve(to: CGPoint(x: -10, y: -22), control1: CGPoint(x: -23, y: -10), control2: CGPoint(x: -18, y: -20))
        bag.addCurve(to: CGPoint(x: 12, y: -24), control1: CGPoint(x: -3, y: -25), control2: CGPoint(x: 4, y: -27))
        bag.addCurve(to: CGPoint(x: 19, y: -3), control1: CGPoint(x: 20, y: -21), control2: CGPoint(x: 23, y: -9))
        bag.addCurve(to: CGPoint(x: -19, y: -1), control1: CGPoint(x: 10, y: 1.5), control2: CGPoint(x: -8, y: 1.5))
        bag.closeSubpath()
        g.fill(bag, Color(hex: 0x7FBFC8))
        var dent = Path()
        dent.move(to: CGPoint(x: -9, y: -12))
        dent.addQuadCurve(to: CGPoint(x: 10, y: -13), control: CGPoint(x: 1, y: -6))
        g.stroke(dent, Color(hex: 0x5E9EA8), 1.2)
        g.fill(.ellipse(CGPoint(x: -8, y: -18), 9, 4), Color.white.opacity(0.35))
        g.stroke(bag, Color(hex: 0x4F8C96), 0.9)
    }

    static func catTree(_ g: GraphicsContext, dark: Bool, time: Double) {
        shadow(g, width: 42, dark: dark)
        func post(_ x: CGFloat, from top: CGFloat, to bottom: CGFloat) {
            let rect = CGRect(x: x - 3, y: top, width: 6, height: bottom - top)
            g.fill(Path(rect), Color(hex: 0xD8BF8F))
            var rope = g
            rope.clip(to: Path(rect))
            var lines = Path()
            for y in stride(from: top, through: bottom + 6, by: 2.2) {
                lines.move(to: CGPoint(x: x - 4, y: y))
                lines.addLine(to: CGPoint(x: x + 4, y: y - 2))
            }
            rope.stroke(lines, Color(hex: 0xB89A66), 0.7)
        }
        post(-9, from: -44, to: -5)
        post(8, from: -80, to: -5)
        let carpet = Color(hex: 0xB9A7D9)
        let edge = Color(hex: 0x8F7CB8)
        g.fill(.roundedRect(CGRect(x: -20, y: -6, width: 40, height: 6), 2), carpet)
        g.stroke(.roundedRect(CGRect(x: -20, y: -6, width: 40, height: 6), 2), edge, 0.8)
        // Middle platform with a dangling pom-pom.
        g.fill(.roundedRect(CGRect(x: -19, y: -48, width: 25, height: 5), 2), carpet)
        g.stroke(.roundedRect(CGRect(x: -19, y: -48, width: 25, height: 5), 2), edge, 0.8)
        let swing = CGFloat(sin(time * 1.6)) * 3
        let ball = CGPoint(x: -15 + swing, y: -30)
        g.stroke(Path { $0.move(to: CGPoint(x: -15, y: -43)); $0.addLine(to: ball) }, Color(hex: 0x8C7A9E), 0.7)
        g.fill(.ellipse(ball, 5.5, 5.5), Color(hex: 0xFF8FB1))
        g.fill(.ellipse(CGPoint(x: ball.x - 1, y: ball.y - 1), 1.8, 1.8), Color.white.opacity(0.6))
        // Top platform with a round bed.
        g.fill(.roundedRect(CGRect(x: -4, y: -84, width: 24, height: 5), 2), carpet)
        g.stroke(.roundedRect(CGRect(x: -4, y: -84, width: 24, height: 5), 2), edge, 0.8)
        g.fill(.roundedRect(CGRect(x: -1, y: -89, width: 18, height: 6), 3), Color(hex: 0xF4B3C2))
        g.fill(.ellipse(CGPoint(x: 8, y: -88), 13, 2.6), Color(hex: 0xFFDCE5))
    }

    /// A cat-eared wall clock showing the real time.
    static func clock(_ g: GraphicsContext, dark: Bool) {
        for side in [-1.0, 1.0] as [CGFloat] {
            var ear = Path()
            ear.move(to: CGPoint(x: side * 9.5, y: -6))
            ear.addLine(to: CGPoint(x: side * 9, y: -14))
            ear.addLine(to: CGPoint(x: side * 3, y: -10))
            ear.closeSubpath()
            g.fill(ear, Color(hex: 0xC77D4E))
            g.fill(.ellipse(CGPoint(x: side * 7.6, y: -10.4), 2.4, 3), Color(hex: 0xFFB9A6))
        }
        g.fill(.ellipse(CGPoint(x: 0.6, y: 0.8), 24, 24), Color.black.opacity(dark ? 0.3 : 0.1))
        g.fill(.ellipse(.zero, 24, 24), Color(hex: 0xC77D4E))
        g.fill(.ellipse(.zero, 19.5, 19.5), Color(hex: 0xFFF8EE))
        var ticks = Path()
        for index in 0..<12 {
            let angle = Double(index) / 12 * 2 * .pi
            let inner: CGFloat = index % 3 == 0 ? 6.6 : 7.6
            ticks.move(to: CGPoint(x: CGFloat(sin(angle)) * inner, y: -CGFloat(cos(angle)) * inner))
            ticks.addLine(to: CGPoint(x: CGFloat(sin(angle)) * 8.8, y: -CGFloat(cos(angle)) * 8.8))
        }
        g.stroke(ticks, Color(hex: 0x8C7A9E), 0.8)
        let local = Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())
        let seconds = local.truncatingRemainder(dividingBy: 43_200)
        let hourAngle = seconds / 43_200 * 2 * .pi
        let minuteAngle = seconds.truncatingRemainder(dividingBy: 3600) / 3600 * 2 * .pi
        g.stroke(Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: sin(hourAngle) * 4.6, y: -cos(hourAngle) * 4.6)) }, Color(hex: 0x4A3B57), 1.4)
        g.stroke(Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: sin(minuteAngle) * 7, y: -cos(minuteAngle) * 7)) }, Color(hex: 0x4A3B57), 0.9)
        g.fill(.ellipse(.zero, 2, 2), Color(hex: 0xFF8FA3))
    }

    /// A framed photo of the two friends.
    static func photo(_ g: GraphicsContext, dark: Bool) {
        g.fill(.roundedRect(CGRect(x: -16, y: -12.5, width: 34, height: 27), 2), Color.black.opacity(dark ? 0.3 : 0.1))
        g.fill(.roundedRect(CGRect(x: -17, y: -13.5, width: 34, height: 27), 2), Color(hex: 0xC98F5C))
        g.fill(Path(CGRect(x: -14.5, y: -11, width: 29, height: 22)), Color(hex: 0xFFFBF4))
        let picture = CGRect(x: -12.5, y: -9, width: 25, height: 18)
        var inside = g
        inside.clip(to: Path(picture))
        inside.fill(Path(picture), with: .linearGradient(Gradient(colors: [Color(hex: 0xBFE0FF), Color(hex: 0xFDE7F0)]),
                                                         startPoint: CGPoint(x: 0, y: picture.minY), endPoint: CGPoint(x: 0, y: picture.maxY)))
        inside.fill(Path(CGRect(x: picture.minX, y: 5, width: picture.width, height: 4)), Color(hex: 0xA6D893))
        var pet = Photo.pet
        pet.x = 0
        PetRenderer.draw(pet, in: inside, at: CGPoint(x: -5, y: 7.5), scale: 0.2, palette: PetPalette(SeasonRenderContext.petColor),
                         accessory: nil, dark: false)
        Photo.companion(inside, feet: CGPoint(x: 5.8, y: 8.2), pixel: 0.52)
        inside.fill(.heart(CGPoint(x: 0.5, y: -5.5), size: 4), Color(hex: 0xFF6F91))
        var glare = Path()
        glare.move(to: CGPoint(x: 2, y: picture.minY))
        glare.addLine(to: CGPoint(x: 8, y: picture.minY))
        glare.addLine(to: CGPoint(x: -2, y: picture.maxY))
        glare.addLine(to: CGPoint(x: -8, y: picture.maxY))
        glare.closeSubpath()
        inside.fill(glare, Color.white.opacity(0.18))
        g.stroke(.roundedRect(CGRect(x: -17, y: -13.5, width: 34, height: 27), 2), Color(hex: 0x9C6A3E), 0.8)
    }

    /// The two friends in the photo.
    enum Photo {
        /// Mochi smiling at the camera.
        static let pet: PetPose = {
            var pose = PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: 0.4))
            pose.eyeOpenness = 1
            pose.lookX = 0.35
            pose.blush = 0.7
            pose.mouth = .smile
            return pose
        }()

        /// The companion as the Claude Code pixel mascot, waving: a terracotta 18 × 12 body, slit eyes,
        /// stubby arms and four legs. Drawn here rather than by its renderer so the photo stays a
        /// still picture that fits its frame.
        static func companion(_ g: GraphicsContext, feet: CGPoint, pixel: CGFloat) {
            var p = g
            p.translateBy(x: feet.x, y: feet.y)
            p.scaleBy(x: pixel, y: pixel)
            var shape = Path()
            shape.addRect(CGRect(x: -9, y: -15, width: 18, height: 12))
            shape.addRect(CGRect(x: -12, y: -10, width: 3, height: 2))
            shape.addRect(CGRect(x: 9, y: -14, width: 2, height: 2))
            shape.addRect(CGRect(x: 10, y: -17, width: 2, height: 3))
            for x in [-7.0, -4, 2, 5] as [CGFloat] {
                shape.addRect(CGRect(x: x, y: -3, width: 2, height: 3))
            }
            p.fill(shape, Color(hex: 0xCC7A5D))
            p.fill(Path(CGRect(x: -5, y: -12, width: 2, height: 3)), Color(hex: 0x1D1719))
            p.fill(Path(CGRect(x: 3, y: -12, width: 2, height: 3)), Color(hex: 0x1D1719))
        }
    }

    static func fishBowl(_ g: GraphicsContext, dark: Bool, time: Double) {
        shadow(g, width: 22, dark: dark)
        // A little side table.
        for x in [-8.0, 8.0] as [CGFloat] {
            g.fill(.roundedRect(CGRect(x: x - 1, y: -14, width: 2, height: 14), 1), Color(hex: 0x9C6A3E))
        }
        g.fill(.roundedRect(CGRect(x: -12, y: -16, width: 24, height: 3.2), 1.5), Color(hex: 0xC98F5C))
        // The bowl.
        let center = CGPoint(x: 0, y: -27)
        let bowl = Path.ellipse(center, 23, 21)
        var water = g
        water.clip(to: bowl)
        water.fill(Path(CGRect(x: -12, y: center.y - 5, width: 24, height: 20)), Color(hex: 0x8ED3EE).opacity(0.75))
        water.stroke(Path { $0.move(to: CGPoint(x: -10, y: -21)); $0.addQuadCurve(to: CGPoint(x: -7, y: -30), control: CGPoint(x: -11, y: -26)) },
                     Color(hex: 0x4FA36B), 1.2)
        water.stroke(Path { $0.move(to: CGPoint(x: 8, y: -20)); $0.addQuadCurve(to: CGPoint(x: 6, y: -27), control: CGPoint(x: 9.5, y: -24)) },
                     Color(hex: 0x5DB477), 1)
        // The goldfish swims to and fro.
        let swim = sin(time * 0.8)
        let facing: CGFloat = cos(time * 0.8) >= 0 ? 1 : -1
        let fish = CGPoint(x: CGFloat(swim) * 5, y: center.y + 2 + CGFloat(sin(time * 1.7)) * 1.2)
        var tail = Path()
        tail.move(to: CGPoint(x: fish.x - facing * 2.4, y: fish.y))
        tail.addLine(to: CGPoint(x: fish.x - facing * 5.6, y: fish.y - 2.2))
        tail.addLine(to: CGPoint(x: fish.x - facing * 5.6, y: fish.y + 2.2))
        tail.closeSubpath()
        water.fill(tail, Color(hex: 0xFF7A2E))
        water.fill(.ellipse(fish, 7, 4.4), Color(hex: 0xFF9A3D))
        water.fill(.ellipse(CGPoint(x: fish.x + facing * 1.8, y: fish.y - 0.5), 1.1, 1.1), Color(hex: 0x2C2234))
        for index in 0..<2 {
            let p = Ease.fract(time / 2.4 + Double(index) * 0.5)
            water.stroke(.ellipse(CGPoint(x: fish.x + facing * 3 + CGFloat(index) * 1.5, y: fish.y - 2 - CGFloat(p) * 8), 1.4, 1.4),
                         Color.white.opacity(0.8 * (1 - p)), 0.5)
        }
        g.stroke(bowl, Color(hex: 0xA9DDF0).opacity(0.9), 0.9)
        g.stroke(.ellipse(CGPoint(x: 0, y: center.y - 9.6), 13, 2.6), Color(hex: 0xA9DDF0), 0.8)
        g.fill(.ellipse(CGPoint(x: -5, y: center.y - 3), 3, 6), Color.white.opacity(0.4))
    }

    static func toyBox(_ g: GraphicsContext, dark: Bool) {
        shadow(g, width: 32, dark: dark)
        // The open lid leans back; toys peek out over the front.
        var lid = Path()
        lid.move(to: CGPoint(x: -15.5, y: -17))
        lid.addLine(to: CGPoint(x: -13, y: -27))
        lid.addLine(to: CGPoint(x: 13, y: -27))
        lid.addLine(to: CGPoint(x: 15.5, y: -17))
        lid.closeSubpath()
        g.fill(lid, Color(hex: 0xB97F4E))
        g.stroke(lid, Color(hex: 0x9C6A3E), 0.8)
        ItemRenderer.yarn(translated(g, 6, -19), radius: 4.6, spin: 0.4)
        ItemRenderer.ball(translated(g, -6, -19.5), radius: 4.8, spin: 0.2)
        let body = Path.roundedRect(CGRect(x: -15, y: -17, width: 30, height: 17), 2)
        g.fill(body, Color(hex: 0xD9A066))
        g.fill(Path(CGRect(x: -15, y: -12, width: 30, height: 2)), Color(hex: 0xB97F4E))
        g.fill(Path(CGRect(x: -15, y: -5, width: 30, height: 2)), Color(hex: 0xB97F4E))
        g.fill(.heart(CGPoint(x: 0, y: -8.2), size: 6), Color(hex: 0xFF8FA3))
        g.stroke(body, Color(hex: 0x9C6A3E), 0.9)
        g.fill(.ellipse(CGPoint(x: 0, y: -17.4), 31, 2.6), Color(hex: 0xB97F4E))
    }

    static func translated(_ g: GraphicsContext, _ x: CGFloat, _ y: CGFloat) -> GraphicsContext {
        var copy = g
        copy.translateBy(x: x, y: y)
        return copy
    }
}
