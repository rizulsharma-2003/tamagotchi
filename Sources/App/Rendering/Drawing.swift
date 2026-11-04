import SwiftUI
import TamagotchiCore

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
}

extension Path {
    static func ellipse(_ center: CGPoint, _ width: CGFloat, _ height: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height))
    }

    static func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> Path {
        Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }

    static func capsule(from a: CGPoint, to b: CGPoint, width: CGFloat) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// Four-pointed sparkle.
    static func sparkle(_ center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let inner = radius * 0.28
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4 - .pi / 2
            let r = index % 2 == 0 ? radius : inner
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    static func star(_ center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for index in 0..<10 {
            let angle = Double(index) * .pi / 5 - .pi / 2
            let r = index % 2 == 0 ? radius : radius * 0.45
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    static func heart(_ center: CGPoint, size: CGFloat) -> Path {
        let s = size / 2
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y + s * 0.9))
        path.addCurve(to: CGPoint(x: center.x - s, y: center.y - s * 0.2),
                      control1: CGPoint(x: center.x - s * 0.5, y: center.y + s * 0.5),
                      control2: CGPoint(x: center.x - s, y: center.y + s * 0.25))
        path.addArc(center: CGPoint(x: center.x - s * 0.5, y: center.y - s * 0.3), radius: s * 0.52,
                    startAngle: .degrees(170), endAngle: .degrees(-10), clockwise: false)
        path.addArc(center: CGPoint(x: center.x + s * 0.5, y: center.y - s * 0.3), radius: s * 0.52,
                    startAngle: .degrees(190), endAngle: .degrees(10), clockwise: false)
        path.addCurve(to: CGPoint(x: center.x, y: center.y + s * 0.9),
                      control1: CGPoint(x: center.x + s, y: center.y + s * 0.25),
                      control2: CGPoint(x: center.x + s * 0.5, y: center.y + s * 0.5))
        path.closeSubpath()
        return path
    }
}

extension GraphicsContext {
    func fill(_ path: Path, _ color: Color) {
        fill(path, with: .color(color))
    }

    func stroke(_ path: Path, _ color: Color, _ width: CGFloat, cap: CGLineCap = .round) {
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .round))
    }

    func text(_ string: String, at point: CGPoint, size: CGFloat, weight: Font.Weight = .bold, color: Color, design: Font.Design = .rounded) {
        draw(Text(string).font(.system(size: size, weight: weight, design: design)).foregroundColor(color), at: point, anchor: .center)
    }

    func symbol(_ name: String, in rect: CGRect, color: Color) {
        var image = resolve(Image(systemName: name))
        image.shading = .color(color)
        draw(image, in: rect)
    }
}

/// Colours for the pet's coat.
struct PetPalette {
    var body: Color
    var light: Color
    var outline: Color
    var innerEar: Color
    var blush: Color
    var eye: Color
    var eyeHighlight: Color
    var foot: Color

    init(_ color: PetColor) {
        switch color {
        case .cream:
            self.init(body: 0xFFE2C2, light: 0xFFF4E6, outline: 0xD99D6C, innerEar: 0xFFB9A6, blush: 0xFF9A9A, foot: 0xF4C9A0)
        case .peach:
            self.init(body: 0xFFC6AE, light: 0xFFE5D9, outline: 0xD98366, innerEar: 0xFF9F8C, blush: 0xFF7F86, foot: 0xF2A88E)
        case .mint:
            self.init(body: 0xBDEBD4, light: 0xE6FBF0, outline: 0x6FB794, innerEar: 0xFFC2B8, blush: 0xFF9DA0, foot: 0x9ED9BC)
        case .sky:
            self.init(body: 0xC2DEF8, light: 0xE9F3FE, outline: 0x6E9DD0, innerEar: 0xFFC4C7, blush: 0xFF9FB0, foot: 0xA3C6EC)
        case .lavender:
            self.init(body: 0xDCCFF6, light: 0xF1ECFD, outline: 0x9886CF, innerEar: 0xFFC0D6, blush: 0xFF9DC2, foot: 0xC4B3EC)
        case .cocoa:
            self.init(body: 0xC99B78, light: 0xE3C1A5, outline: 0x87593C, innerEar: 0xF0A994, blush: 0xF38C80, foot: 0xB08262)
        case .midnight:
            self.init(body: 0x4D5387, light: 0x7178B0, outline: 0x2A2E57, innerEar: 0xC98BC4, blush: 0xE086B3, foot: 0x3D4273,
                      eye: 0xFFF1D2, eyeHighlight: 0x2A2E57)
        }
    }

    private init(body: UInt32, light: UInt32, outline: UInt32, innerEar: UInt32, blush: UInt32, foot: UInt32,
                 eye: UInt32 = 0x2C2234, eyeHighlight: UInt32 = 0xFFFFFF) {
        self.body = Color(hex: body)
        self.light = Color(hex: light)
        self.outline = Color(hex: outline)
        self.innerEar = Color(hex: innerEar)
        self.blush = Color(hex: blush)
        self.eye = Color(hex: eye)
        self.eyeHighlight = Color(hex: eyeHighlight)
        self.foot = Color(hex: foot)
    }
}

/// Patch's fixed colours: warm clay with a dark glass visor.
enum CompanionPalette {
    static let head = Color(hex: 0xE8916A)
    static let headLight = Color(hex: 0xF6B994)
    static let outline = Color(hex: 0xA8552F)
    static let body = Color(hex: 0xD97F58)
    static let visor = Color(hex: 0x2A2232)
    static let visorEdge = Color(hex: 0x3D3247)
    static let eye = Color(hex: 0xFFE9C4)
    static let bolt = Color(hex: 0xC46C46)
    static let laptop = Color(hex: 0xB9B2C2)
    static let laptopDark = Color(hex: 0x8C849A)

    static func antenna(_ tint: AntennaTint) -> Color {
        switch tint {
        case .calm: return Color(hex: 0xFFD38A)
        case .working: return Color(hex: 0x7FE3CB)
        case .attention: return Color(hex: 0xFFB24A)
        case .alert: return Color(hex: 0xFF7B6E)
        case .off: return Color(hex: 0x8C8496)
        }
    }
}

enum ConfettiPalette {
    static let colors: [Color] = [Color(hex: 0xFF8FA3), Color(hex: 0x7FD6C2), Color(hex: 0xFFD166), Color(hex: 0x9C8CFF)]
}
