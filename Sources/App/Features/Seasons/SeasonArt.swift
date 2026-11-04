#if canImport(AppKit)
import AppKit
private typealias PlatformFont = NSFont
#else
import UIKit
private typealias PlatformFont = UIFont
#endif
import CoreText
import SwiftUI
import TamagotchiCore

/// Procedural holiday decorations: the room (behind the characters), the sky in front of them and a
/// tiny accent beside the menu-bar bed. Glows are radial gradients, never blur filters, and particle
/// counts stay small so the popover keeps its frame rate.
enum SeasonArt {
    static func room(_ event: SeasonalEvent, in g: GraphicsContext, layout: SceneLayout, dark: Bool, time: Double, theme: OfficeTheme,
                     reduced: Bool) {
        let scene = Scene(layout: layout, dark: dark || theme == .cyberpunk, theme: theme, time: reduced ? 0.6 : time, reduced: reduced)
        switch event {
        case .halloween: halloween(g, scene)
        case .diwali: diwali(g, scene)
        case .christmas: christmas(g, scene)
        case .newYear: newYear(g, scene)
        case .valentines: valentines(g, scene)
        case .userBirthday, .mochiBirthday: birthday(g, scene)
        }
    }

    static func foreground(_ event: SeasonalEvent, in g: GraphicsContext, layout: SceneLayout, dark: Bool, time: Double) {
        let scene = Scene(layout: layout, dark: dark || SeasonRenderContext.theme == .cyberpunk, theme: SeasonRenderContext.theme, time: time,
                          reduced: false)
        switch event {
        case .christmas: snowfall(g, scene)
        case .newYear: fireworks(g, scene)
        case .diwali: floatingLights(g, scene)
        case .userBirthday, .mochiBirthday: confettiFall(g, scene)
        case .halloween, .valentines: break
        }
    }

    /// Geometry and mood of the room being decorated.
    struct Scene {
        var layout: SceneLayout
        /// A dark wall (dark mode, or the always-dark cyberpunk city).
        var dark: Bool
        var theme: OfficeTheme
        var time: Double
        var reduced: Bool

        var w: CGFloat { layout.size.width }
        var h: CGFloat { layout.size.height }
        var s: CGFloat { layout.scale }
        var ground: CGFloat { layout.ground }

        /// The window or porthole of the theme, if it has one (matches ThemeRenderer).
        var window: Path? {
            switch theme {
            case .cozyDesk:
                return .roundedRect(CGRect(x: w * 0.07, y: h * 0.13, width: w * 0.2, height: h * 0.38), 6)
            case .spaceStation:
                let radius = min(h * 0.27, 40)
                return .ellipse(CGPoint(x: w * 0.2, y: h * 0.36), radius * 2, radius * 2)
            case .cyberpunk, .gardenOffice:
                return nil
            }
        }

        /// Where the faces usually are, so particles in front fade out around them.
        var faces: [(center: CGPoint, radius: CGFloat)] {
            [(CGPoint(x: layout.petHome, y: ground - 32 * s), 40 * s),
             (CGPoint(x: layout.companionHome, y: ground - 62 * s), 38 * s)]
        }

        /// 0 over a face, 1 well away from it.
        func faceClearance(_ p: CGPoint) -> Double {
            var value = 1.0
            for face in faces {
                let distance = hypot(p.x - face.center.x, p.y - face.center.y)
                value = min(value, Ease.smooth(Double((distance - face.radius) / (16 * s))))
            }
            return value
        }
    }

    // MARK: - Shared pieces

    /// A point on a garland hanging from `a` to `b` that sags by `sag` in the middle.
    static func swagPoint(_ a: CGPoint, _ b: CGPoint, sag: CGFloat, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + sag * 4 * t * (1 - t))
    }

    static func swagPath(_ a: CGPoint, _ b: CGPoint, sag: CGFloat) -> Path {
        var path = Path()
        path.move(to: a)
        path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + sag * 2))
        return path
    }

    static func glow(_ g: GraphicsContext, at p: CGPoint, radius: CGFloat, color: Color, opacity: Double) {
        guard opacity > 0.01 else { return }
        g.fill(.ellipse(p, radius * 2, radius * 2), with: .radialGradient(Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
                                                                        center: p, startRadius: 0, endRadius: radius))
    }

    /// Candle flicker, 0.75…1.05, different per `phase`.
    static func flicker(_ t: Double, _ phase: Double) -> Double {
        0.88 + 0.08 * sin(t * 9.3 + phase) + 0.05 * sin(t * 14.7 + phase * 2.3) + 0.04 * sin(t * 23.1 + phase * 0.7)
    }

    /// A pennant flag hanging from `top`, with an optional letter.
    static func pennant(_ g: GraphicsContext, top: CGPoint, width: CGFloat, height: CGFloat, color: Color, letter: String? = nil,
                        sway: Double = 0) {
        var flag = g
        flag.translateBy(x: top.x, y: top.y)
        flag.rotate(by: .radians(sway))
        var path = Path()
        path.move(to: CGPoint(x: -width / 2, y: 0))
        path.addLine(to: CGPoint(x: width / 2, y: 0))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        flag.fill(path, color)
        flag.fill(Path(CGRect(x: -width / 2, y: 0, width: width, height: height * 0.12)), Color.black.opacity(0.08))
        if let letter, let character = letter.first {
            let size = width * 0.62
            flag.fill(BuntingGlyphs.path(character).applying(CGAffineTransform(a: size, b: 0, c: 0, d: size, tx: 0, ty: height * 0.36)), .white)
        }
    }

    /// Letters for the bunting as vector paths, built once from SF Rounded Heavy and reused every
    /// frame: filling a path is several times cheaper than laying out text for each frame.
    enum BuntingGlyphs {
        /// Only touched while drawing on the main thread.
        nonisolated(unsafe) private static var cache: [Character: Path] = [:]

        /// The glyph for `character` at a font size of 1, centred on the origin (y down).
        static func path(_ character: Character) -> Path {
            if let cached = cache[character] { return cached }
            let base = PlatformFont.systemFont(ofSize: 100, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { PlatformFont(descriptor: $0, size: 100) } ?? base
            var units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            var path = Path()
            if CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyphs, units.count),
               let outline = CTFontCreatePathForGlyph(font as CTFont, glyphs[0], nil) {
                let bounds = outline.boundingBoxOfPath
                path = Path(outline).applying(CGAffineTransform(a: 0.01, b: 0, c: 0, d: -0.01, tx: -bounds.midX * 0.01, ty: bounds.midY * 0.01))
            }
            cache[character] = path
            return path
        }
    }

    // MARK: - Halloween

    static func halloween(_ g: GraphicsContext, _ sc: Scene) {
        let (w, h, s, ground, t) = (sc.w, sc.h, sc.s, sc.ground, sc.time)
        // Dusk purple from the ceiling, pumpkin warmth along the floor.
        g.fill(Path(CGRect(origin: .zero, size: sc.layout.size)), with: .linearGradient(Gradient(stops: [
            .init(color: Color(hex: 0x4B2A7B).opacity(sc.dark ? 0.24 : 0.13), location: 0),
            .init(color: Color(hex: 0x4B2A7B).opacity(0), location: 0.55),
            .init(color: Color(hex: 0xFF8A2A).opacity(0), location: 0.72),
            .init(color: Color(hex: 0xFF8A2A).opacity(sc.dark ? 0.16 : 0.1), location: 1),
        ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        bats(g, sc)
        cobweb(g, corner: CGPoint(x: w, y: 0), length: 40 * s, dark: sc.dark, time: t, reduced: sc.reduced)
        pumpkinLights(g, sc)

        // Jack-o'-lanterns in the corners and a bowl of candy between the friends.
        let floor = ground + 5 * s
        jackOLantern(g, foot: CGPoint(x: w * 0.052, y: floor), width: 27 * s, time: t, phase: 0, dark: sc.dark)
        jackOLantern(g, foot: CGPoint(x: w * 0.118, y: floor + 3 * s), width: 17 * s, time: t, phase: 2.1, dark: sc.dark, face: 1)
        jackOLantern(g, foot: CGPoint(x: w * 0.93, y: floor + 1 * s), width: 23 * s, time: t, phase: 4.2, dark: sc.dark, face: 2)
        candyBowl(g, foot: CGPoint(x: w * 0.465, y: floor + 3 * s), width: 29 * s, dark: sc.dark)
        ghost(g, center: CGPoint(x: w * 0.915, y: h * 0.47), size: 17 * s, time: t, reduced: sc.reduced, dark: sc.dark)
    }

    /// A small, friendly ghost bobbing on the wall, with rosy cheeks.
    static func ghost(_ g: GraphicsContext, center: CGPoint, size: CGFloat, time: Double, reduced: Bool, dark: Bool) {
        let bob = reduced ? 0 : CGFloat(sin(time * 1.3)) * size * 0.12
        var gh = g
        gh.translateBy(x: center.x, y: center.y + bob)
        gh.rotate(by: .radians(reduced ? 0 : sin(time * 0.9) * 0.06))
        let k = size / 20
        gh.scaleBy(x: k, y: k)
        glow(gh, at: .zero, radius: 18, color: Color(hex: 0xD9CCFF), opacity: dark ? 0.35 : 0.2)
        var body = Path()
        body.move(to: CGPoint(x: -9, y: 9))
        body.addLine(to: CGPoint(x: -9, y: -1))
        body.addCurve(to: CGPoint(x: 9, y: -1), control1: CGPoint(x: -9, y: -13.5), control2: CGPoint(x: 9, y: -13.5))
        body.addLine(to: CGPoint(x: 9, y: 9))
        let wave = reduced ? 0 : CGFloat(sin(time * 4)) * 0.8
        for index in 0..<3 {
            let x0 = 9 - CGFloat(index) * 6
            body.addQuadCurve(to: CGPoint(x: x0 - 3, y: 8 + wave), control: CGPoint(x: x0 - 1.5, y: 11.5 + wave))
            body.addQuadCurve(to: CGPoint(x: x0 - 6, y: 9), control: CGPoint(x: x0 - 4.5, y: 5.5))
        }
        body.closeSubpath()
        gh.fill(body, Color.white.opacity(0.94))
        gh.stroke(body, Color(hex: 0xB9AED0).opacity(dark ? 0.5 : 0.9), 0.9)
        gh.fill(.ellipse(CGPoint(x: -3.2, y: -2.5), 2.4, 3.2), Color(hex: 0x2C2234))
        gh.fill(.ellipse(CGPoint(x: 3.2, y: -2.5), 2.4, 3.2), Color(hex: 0x2C2234))
        gh.fill(.ellipse(CGPoint(x: -2.8, y: -3.3), 0.9, 0.9), Color.white)
        gh.fill(.ellipse(CGPoint(x: 3.6, y: -3.3), 0.9, 0.9), Color.white)
        gh.fill(.ellipse(CGPoint(x: 0, y: 1.6), 2.4, 2), Color(hex: 0x2C2234))
        gh.fill(.ellipse(CGPoint(x: -5.6, y: 0.6), 3, 1.8), Color(hex: 0xFF9FB2).opacity(0.7))
        gh.fill(.ellipse(CGPoint(x: 5.6, y: 0.6), 3, 1.8), Color(hex: 0xFF9FB2).opacity(0.7))
    }

    /// A string of little pumpkin lights along the top, warm and slowly breathing.
    static func pumpkinLights(_ g: GraphicsContext, _ sc: Scene) {
        let (w, s, t) = (sc.w, sc.s, sc.time)
        let anchors = [CGPoint(x: -6, y: 3 * s), CGPoint(x: w * 0.45, y: 5 * s), CGPoint(x: w * 0.87, y: 2 * s)]
        let wire = sc.dark ? Color(hex: 0x120C18) : Color(hex: 0x3A2E45)
        var index = 0
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            let sag = 13 * s
            g.stroke(swagPath(a, b, sag: sag), wire.opacity(0.75), 0.9)
            for step in 1...6 {
                let p = swagPoint(a, b, sag: sag, CGFloat(step) / 7)
                let pulse = 0.75 + 0.25 * sin(t * 1.6 + Double(index) * 1.3)
                let bulb = CGPoint(x: p.x, y: p.y + 4.5 * s)
                g.stroke(Path { $0.move(to: p); $0.addLine(to: bulb) }, wire.opacity(0.75), 0.7)
                if index % 3 == 1 {
                    glow(g, at: bulb, radius: 8 * s, color: Color(hex: 0xB98CFF), opacity: (sc.dark ? 0.5 : 0.3) * pulse)
                    g.fill(.ellipse(bulb, 4.4 * s, 5 * s), Color(hex: 0xB98CFF))
                    g.fill(.ellipse(CGPoint(x: bulb.x - 0.8 * s, y: bulb.y - 1 * s), 1.6 * s, 1.6 * s), Color.white.opacity(0.7))
                } else {
                    glow(g, at: bulb, radius: 9 * s, color: Color(hex: 0xFFAA45), opacity: (sc.dark ? 0.55 : 0.32) * pulse)
                    miniPumpkin(g, center: bulb, width: 7.4 * s, lit: pulse)
                }
                index += 1
            }
        }
        // A sleepy bat hangs from the wire when nothing flies.
        if sc.reduced {
            hangingBat(g, from: swagPoint(anchors[1], anchors[2], sag: 13 * s, 0.5), span: 15 * s, dark: sc.dark)
            hangingBat(g, from: swagPoint(anchors[0], anchors[1], sag: 13 * s, 0.36), span: 12 * s, dark: sc.dark)
        }
    }

    static func miniPumpkin(_ g: GraphicsContext, center c: CGPoint, width wd: CGFloat, lit: Double = 1) {
        let h = wd * 0.8
        for (dx, lw, color) in [(-0.22, 0.6, 0xE8771F), (0.22, 0.6, 0xE8771F), (0.0, 0.62, 0xFF9C3F)] as [(CGFloat, CGFloat, UInt32)] {
            g.fill(.ellipse(CGPoint(x: c.x + dx * wd, y: c.y), lw * wd, h), Color(hex: color))
        }
        g.fill(.ellipse(CGPoint(x: c.x, y: c.y + h * 0.05), wd * 0.3, h * 0.45), Color(hex: 0xFFE07A).opacity(0.35 + 0.35 * lit))
        g.fill(.roundedRect(CGRect(x: c.x - wd * 0.07, y: c.y - h * 0.68, width: wd * 0.16, height: h * 0.3), wd * 0.05), Color(hex: 0x5E7F33))
    }

    /// A carved pumpkin with a candle inside: the face glows and flickers, light spills around it.
    static func jackOLantern(_ g: GraphicsContext, foot: CGPoint, width wd: CGFloat, time: Double, phase: Double, dark: Bool, face: Int = 0) {
        let h = wd * 0.76
        let c = CGPoint(x: foot.x, y: foot.y - h / 2)
        let f = flicker(time, phase)
        glow(g, at: CGPoint(x: c.x, y: c.y - h * 0.15), radius: wd * (1.45 + 0.1 * CGFloat(f)), color: Color(hex: 0xFFB347),
             opacity: (dark ? 0.5 : 0.32) * f)
        g.fill(.ellipse(CGPoint(x: foot.x, y: foot.y - 0.5), wd * 1.05, wd * 0.18), Color.black.opacity(dark ? 0.32 : 0.15))
        let lobes: [(CGFloat, CGFloat, UInt32)] = [(-0.27, 0.5, 0xE06F1C), (0.27, 0.5, 0xE06F1C), (-0.13, 0.56, 0xF5862A),
                                                   (0.13, 0.56, 0xF5862A), (0, 0.52, 0xFF9C3F)]
        for (dx, lw, color) in lobes {
            let lobe = Path.ellipse(CGPoint(x: c.x + dx * wd, y: c.y), lw * wd, h)
            g.fill(lobe, Color(hex: color))
            g.stroke(lobe, Color(hex: 0xB0501A).opacity(0.5), max(0.6, wd / 34))
        }
        g.fill(.ellipse(CGPoint(x: c.x - wd * 0.2, y: c.y - h * 0.26), wd * 0.16, h * 0.14), Color.white.opacity(0.28))
        var stem = Path()
        stem.move(to: CGPoint(x: c.x - wd * 0.05, y: c.y - h * 0.44))
        stem.addQuadCurve(to: CGPoint(x: c.x + wd * 0.1, y: c.y - h * 0.68), control: CGPoint(x: c.x - wd * 0.04, y: c.y - h * 0.62))
        g.stroke(stem, Color(hex: 0x5E7F33), max(1.6, wd * 0.11), cap: .round)
        var curl = Path()
        curl.move(to: CGPoint(x: c.x + wd * 0.04, y: c.y - h * 0.5))
        curl.addQuadCurve(to: CGPoint(x: c.x + wd * 0.24, y: c.y - h * 0.56), control: CGPoint(x: c.x + wd * 0.18, y: c.y - h * 0.38))
        g.stroke(curl, Color(hex: 0x7FA34A), max(0.6, wd * 0.03))

        // The carved face, lit from inside.
        let light = Color(hex: 0xFFE38A).opacity(0.72 + 0.28 * f)
        let deep = Color(hex: 0xC4560E)
        var carved = Path()
        let eyeY = c.y - h * 0.1
        for side in [-1.0, 1.0] as [CGFloat] {
            let ex = c.x + side * wd * 0.17
            if face == 1 {
                carved.addEllipse(in: CGRect(x: ex - wd * 0.06, y: eyeY - wd * 0.07, width: wd * 0.12, height: wd * 0.13))
            } else {
                carved.move(to: CGPoint(x: ex - wd * 0.08, y: eyeY + wd * 0.05))
                carved.addLine(to: CGPoint(x: ex + wd * 0.08, y: eyeY + wd * 0.05))
                carved.addLine(to: CGPoint(x: ex + (face == 2 ? side * 0.05 : 0) * wd, y: eyeY - wd * 0.08))
                carved.closeSubpath()
            }
        }
        carved.move(to: CGPoint(x: c.x - wd * 0.035, y: c.y + h * 0.05))
        carved.addLine(to: CGPoint(x: c.x + wd * 0.035, y: c.y + h * 0.05))
        carved.addLine(to: CGPoint(x: c.x, y: c.y - h * 0.03))
        carved.closeSubpath()
        let mouthY = c.y + h * 0.15
        carved.move(to: CGPoint(x: c.x - wd * 0.26, y: mouthY - h * 0.04))
        carved.addQuadCurve(to: CGPoint(x: c.x + wd * 0.26, y: mouthY - h * 0.04), control: CGPoint(x: c.x, y: mouthY + h * 0.32))
        if face == 1 {
            carved.closeSubpath()
        } else {
            // Two square teeth along the top of the grin.
            carved.addLine(to: CGPoint(x: c.x + wd * 0.14, y: mouthY + h * 0.0))
            carved.addLine(to: CGPoint(x: c.x + wd * 0.14, y: mouthY + h * 0.07))
            carved.addLine(to: CGPoint(x: c.x + wd * 0.05, y: mouthY + h * 0.07))
            carved.addLine(to: CGPoint(x: c.x + wd * 0.05, y: mouthY + h * 0.02))
            carved.addLine(to: CGPoint(x: c.x - wd * 0.07, y: mouthY + h * 0.02))
            carved.addLine(to: CGPoint(x: c.x - wd * 0.07, y: mouthY + h * 0.08))
            carved.addLine(to: CGPoint(x: c.x - wd * 0.16, y: mouthY + h * 0.08))
            carved.addLine(to: CGPoint(x: c.x - wd * 0.16, y: mouthY + h * 0.0))
            carved.closeSubpath()
        }
        g.fill(carved, light)
        g.stroke(carved, deep.opacity(0.8), max(0.5, wd / 40))
    }

    static func candyBowl(_ g: GraphicsContext, foot: CGPoint, width wd: CGFloat, dark: Bool) {
        let rimY = foot.y - wd * 0.42
        g.fill(.ellipse(CGPoint(x: foot.x, y: foot.y), wd * 0.9, wd * 0.14), Color.black.opacity(dark ? 0.3 : 0.13))
        // The heap of sweets behind the rim.
        let sweets: [(CGFloat, CGFloat, UInt32, Bool)] = [(-0.27, -0.03, 0xFF8FA3, false), (0.26, -0.03, 0x7FD6C2, false), (-0.05, -0.2, 0xFFD166, true),
                                                         (0.12, -0.14, 0xB98CFF, false), (-0.17, -0.13, 0xFF9C3F, true), (0.02, -0.04, 0xFF6B6B, false),
                                                         (0.2, -0.24, 0xFF9C3F, true)]
        for (dx, dy, color, corn) in sweets {
            let p = CGPoint(x: foot.x + dx * wd, y: rimY + dy * wd)
            if corn {
                candyCorn(g, center: p, size: wd * 0.24)
            } else {
                for side in [-1.0, 1.0] as [CGFloat] {
                    var twist = Path()
                    twist.move(to: CGPoint(x: p.x + side * wd * 0.07, y: p.y))
                    twist.addLine(to: CGPoint(x: p.x + side * wd * 0.15, y: p.y - wd * 0.05))
                    twist.addLine(to: CGPoint(x: p.x + side * wd * 0.15, y: p.y + wd * 0.05))
                    twist.closeSubpath()
                    g.fill(twist, Color(hex: color).opacity(0.85))
                }
                g.fill(.ellipse(p, wd * 0.17, wd * 0.14), Color(hex: color))
                g.fill(.ellipse(CGPoint(x: p.x - wd * 0.03, y: p.y - wd * 0.025), wd * 0.06, wd * 0.04), Color.white.opacity(0.6))
            }
        }
        var bowl = Path()
        bowl.move(to: CGPoint(x: foot.x - wd / 2, y: rimY))
        bowl.addQuadCurve(to: CGPoint(x: foot.x + wd / 2, y: rimY), control: CGPoint(x: foot.x, y: foot.y + wd * 0.3))
        bowl.closeSubpath()
        g.fill(bowl, Color(hex: 0x5E3E9C))
        var band = g
        band.clip(to: bowl)
        band.fill(Path(CGRect(x: foot.x - wd / 2, y: rimY + wd * 0.1, width: wd, height: wd * 0.07)), Color(hex: 0xFF9C3F))
        band.fill(.ellipse(CGPoint(x: foot.x - wd * 0.2, y: rimY + wd * 0.06), wd * 0.12, wd * 0.05), Color.white.opacity(0.25))
        g.fill(.ellipse(CGPoint(x: foot.x, y: rimY), wd, wd * 0.12), Color(hex: 0x7B55C4))
        g.fill(.roundedRect(CGRect(x: foot.x - wd * 0.16, y: foot.y - wd * 0.07, width: wd * 0.32, height: wd * 0.08), wd * 0.03), Color(hex: 0x4A2F80))
    }

    static func candyCorn(_ g: GraphicsContext, center p: CGPoint, size: CGFloat) {
        var corn = Path()
        corn.move(to: CGPoint(x: p.x - size * 0.42, y: p.y + size * 0.4))
        corn.addQuadCurve(to: CGPoint(x: p.x + size * 0.42, y: p.y + size * 0.4), control: CGPoint(x: p.x, y: p.y + size * 0.55))
        corn.addLine(to: CGPoint(x: p.x, y: p.y - size * 0.5))
        corn.closeSubpath()
        var bands = g
        bands.clip(to: corn)
        bands.fill(Path(CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)), Color(hex: 0xFFF6E5))
        bands.fill(Path(CGRect(x: p.x - size, y: p.y - size * 0.18, width: size * 2, height: size * 2)), Color(hex: 0xFF9C3F))
        bands.fill(Path(CGRect(x: p.x - size, y: p.y + size * 0.18, width: size * 2, height: size * 2)), Color(hex: 0xFFD166))
    }

    /// A few bats flutter across the top-left (past the window), every dozen seconds.
    static func bats(_ g: GraphicsContext, _ sc: Scene) {
        guard !sc.reduced else { return }
        let cycle = 12.0
        let local = Ease.fract(sc.time / cycle) * cycle
        let ink = sc.dark ? Color(hex: 0x0E0914) : Color(hex: 0x2B2236)
        for index in 0..<3 {
            let p = (local - Double(index) * 0.55) / 4.6
            guard p > 0, p < 1 else { continue }
            let x = -14 + CGFloat(p) * (sc.w * 0.62)
            let y = sc.h * (0.2 + 0.07 * CGFloat(index)) + CGFloat(sin(p * .pi * 3 + Double(index))) * 7 * sc.s - CGFloat(p) * 10 * sc.s
            let flap = CGFloat(sin(sc.time * 15 + Double(index) * 1.7))
            bat(g, at: CGPoint(x: x, y: y), span: (index == 1 ? 15 : 12) * sc.s, flap: flap, color: ink)
        }
    }

    /// A little bat with yellow eyes; `flap` -1…1 moves the wings.
    static func bat(_ g: GraphicsContext, at c: CGPoint, span: CGFloat, flap: CGFloat, color: Color) {
        var b = g
        b.translateBy(x: c.x, y: c.y)
        b.scaleBy(x: span / 20, y: span / 20)
        var wings = Path()
        for side in [-1.0, 1.0] as [CGFloat] {
            wings.move(to: CGPoint(x: 0, y: -1))
            wings.addQuadCurve(to: CGPoint(x: side * 10, y: -2 - 5 * flap), control: CGPoint(x: side * 5, y: -6 - 3 * flap))
            wings.addQuadCurve(to: CGPoint(x: side * 6.6, y: 1 - 2.4 * flap), control: CGPoint(x: side * 9.4, y: 1 - 3.5 * flap))
            wings.addQuadCurve(to: CGPoint(x: side * 3.4, y: 1.6 - 1.2 * flap), control: CGPoint(x: side * 5.6, y: -0.2 - 1.4 * flap))
            wings.addQuadCurve(to: CGPoint(x: 0, y: 2), control: CGPoint(x: side * 1.8, y: 0.4))
            wings.closeSubpath()
        }
        b.fill(wings, color)
        b.fill(.ellipse(CGPoint(x: 0, y: 0.6), 4.6, 6), color)
        var ears = Path()
        ears.move(to: CGPoint(x: -2.1, y: -1.8))
        ears.addLine(to: CGPoint(x: -1.5, y: -4.4))
        ears.addLine(to: CGPoint(x: -0.4, y: -2.3))
        ears.move(to: CGPoint(x: 2.1, y: -1.8))
        ears.addLine(to: CGPoint(x: 1.5, y: -4.4))
        ears.addLine(to: CGPoint(x: 0.4, y: -2.3))
        b.fill(ears, color)
        b.fill(.ellipse(CGPoint(x: -0.9, y: -0.4), 1.2, 1.2), Color(hex: 0xFFD166))
        b.fill(.ellipse(CGPoint(x: 0.9, y: -0.4), 1.2, 1.2), Color(hex: 0xFFD166))
    }

    /// A bat asleep upside down, wings folded.
    static func hangingBat(_ g: GraphicsContext, from point: CGPoint, span: CGFloat, dark: Bool) {
        var b = g
        b.translateBy(x: point.x, y: point.y + span * 0.32)
        b.rotate(by: .degrees(180))
        bat(b, at: .zero, span: span, flap: -0.9, color: dark ? Color(hex: 0x0E0914) : Color(hex: 0x2B2236))
    }

    /// A corner cobweb with a small spider bobbing on its thread.
    static func cobweb(_ g: GraphicsContext, corner: CGPoint, length: CGFloat, dark: Bool, time: Double, reduced: Bool) {
        let ink = dark ? Color.white.opacity(0.32) : Color(hex: 0x6E6280).opacity(0.45)
        let angles: [Double] = [0, 0.4, 0.8, 1.17, 1.5707]
        let directions = angles.map { CGPoint(x: -cos($0), y: sin($0)) }
        var web = Path()
        for (index, d) in directions.enumerated() {
            let reach = length * (index == 0 || index == directions.count - 1 ? 0.95 : 1)
            web.move(to: corner)
            web.addLine(to: CGPoint(x: corner.x + d.x * reach, y: corner.y + d.y * reach))
        }
        for ring in [0.3, 0.55, 0.8] as [CGFloat] {
            for (a, b) in zip(directions, directions.dropFirst()) {
                let p1 = CGPoint(x: corner.x + a.x * length * ring, y: corner.y + a.y * length * ring)
                let p2 = CGPoint(x: corner.x + b.x * length * ring, y: corner.y + b.y * length * ring)
                let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                web.move(to: p1)
                web.addQuadCurve(to: p2, control: CGPoint(x: corner.x + (mid.x - corner.x) * 0.82, y: corner.y + (mid.y - corner.y) * 0.82))
            }
        }
        g.stroke(web, ink, 0.7)
        // The spider.
        let anchor = CGPoint(x: corner.x - length * 0.42, y: corner.y + length * 0.42)
        let drop = length * 0.5 + (reduced ? 0 : CGFloat(sin(time * 0.9)) * length * 0.12)
        let spider = CGPoint(x: anchor.x, y: anchor.y + drop)
        g.stroke(Path { $0.move(to: anchor); $0.addLine(to: spider) }, ink, 0.6)
        let k = length / 40
        var legs = Path()
        for index in 0..<4 {
            let y = spider.y - 1.2 * k + CGFloat(index) * 1.1 * k
            for side in [-1.0, 1.0] as [CGFloat] {
                legs.move(to: CGPoint(x: spider.x + side * 1.2 * k, y: y))
                legs.addQuadCurve(to: CGPoint(x: spider.x + side * 4.4 * k, y: y + 1.6 * k),
                                  control: CGPoint(x: spider.x + side * 3.4 * k, y: y - 1.8 * k))
            }
        }
        let body = dark ? Color(hex: 0x0E0914) : Color(hex: 0x2B2236)
        g.stroke(legs, body, 0.7 * k)
        g.fill(.ellipse(CGPoint(x: spider.x, y: spider.y + 0.8 * k), 4.4 * k, 5 * k), body)
        g.fill(.ellipse(CGPoint(x: spider.x, y: spider.y - 1.8 * k), 3 * k, 2.6 * k), body)
        g.fill(.ellipse(CGPoint(x: spider.x - 0.7 * k, y: spider.y - 1.9 * k), 1.1 * k, 1.1 * k), Color.white)
        g.fill(.ellipse(CGPoint(x: spider.x + 0.7 * k, y: spider.y - 1.9 * k), 1.1 * k, 1.1 * k), Color.white)
    }

    // MARK: - Diwali

    static let marigoldOrange = Color(hex: 0xF77F00)
    static let marigoldYellow = Color(hex: 0xFCBF49)

    static func diwali(_ g: GraphicsContext, _ sc: Scene) {
        let (w, h, s, ground, t) = (sc.w, sc.h, sc.s, sc.ground, sc.time)
        // A warm festive evening: deep indigo up high, golden lamp light along the floor.
        g.fill(Path(CGRect(origin: .zero, size: sc.layout.size)), with: .linearGradient(Gradient(stops: [
            .init(color: Color(hex: 0x3B1F6B).opacity(sc.dark ? 0.2 : 0.08), location: 0),
            .init(color: Color(hex: 0x3B1F6B).opacity(0), location: 0.45),
            .init(color: Color(hex: 0xFFB347).opacity(0), location: 0.62),
            .init(color: Color(hex: 0xFFB347).opacity(sc.dark ? 0.2 : 0.13), location: 1),
        ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        fairyLights(g, sc)
        marigoldToran(g, sc)

        // Rangoli on the floor between the friends, with a diya at its heart.
        let rangoliCenter = CGPoint(x: w * 0.465, y: ground + 10 * s)
        rangoli(g, center: rangoliCenter, radius: 31 * s)
        diya(g, foot: CGPoint(x: rangoliCenter.x, y: rangoliCenter.y + 1.5 * s), width: 12 * s, time: t, phase: 0.4, dark: sc.dark)

        // Rows of diyas in the corners.
        let floor = ground + 7 * s
        for (index, x) in [0.035, 0.085, 0.89, 0.94, 0.985].enumerated() {
            diya(g, foot: CGPoint(x: w * x, y: floor + CGFloat(index % 2) * 3 * s), width: 12.5 * s, time: t, phase: Double(index) * 1.9, dark: sc.dark)
        }
    }

    /// Marigold garlands across the top, with strands hanging between the swags.
    static func marigoldToran(_ g: GraphicsContext, _ sc: Scene) {
        let (w, s) = (sc.w, sc.s)
        var orange = Path()
        var yellow = Path()
        var hearts = Path()
        var leaves: [(CGPoint, Double)] = []
        let r = 3.3 * s
        func flower(_ p: CGPoint, _ index: Int) {
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            if index % 2 == 0 { orange.addEllipse(in: rect) } else { yellow.addEllipse(in: rect) }
            hearts.addEllipse(in: CGRect(x: p.x - r * 0.32, y: p.y - r * 0.32, width: r * 0.64, height: r * 0.64))
        }
        let joints = [CGPoint(x: -4, y: -1), CGPoint(x: w / 3, y: -1), CGPoint(x: w * 2 / 3, y: -1), CGPoint(x: w + 4, y: -1)]
        var index = 0
        for (a, b) in zip(joints, joints.dropFirst()) {
            let count = 17
            for step in 0...count {
                flower(swagPoint(a, b, sag: 10 * s, CGFloat(step) / CGFloat(count)), index)
                index += 1
            }
        }
        // Hanging strands at the inner joints, each ending in a mango leaf.
        for joint in joints.dropFirst().dropLast() {
            for step in 1...4 {
                flower(CGPoint(x: joint.x, y: joint.y + CGFloat(step) * r * 1.75 + r), step)
            }
            leaves.append((CGPoint(x: joint.x, y: joint.y + r * 9.6), 0))
            leaves.append((CGPoint(x: joint.x - r * 1.6, y: joint.y + r * 1.4), 0.9))
            leaves.append((CGPoint(x: joint.x + r * 1.6, y: joint.y + r * 1.4), -0.9))
        }
        for (p, angle) in leaves {
            var leaf = g
            leaf.translateBy(x: p.x, y: p.y)
            leaf.rotate(by: .radians(angle))
            leaf.fill(.ellipse(CGPoint(x: 0, y: r * 0.9), r * 1.1, r * 2.6), Color(hex: 0x3E8E41))
            leaf.stroke(Path { $0.move(to: CGPoint(x: 0, y: -r * 0.3)); $0.addLine(to: CGPoint(x: 0, y: r * 2)) }, Color(hex: 0x2C6B2F), 0.5)
        }
        g.fill(orange, marigoldOrange)
        g.fill(yellow, marigoldYellow)
        // Ruffled petals: a darker ring and a bright centre.
        g.stroke(orange, Color(hex: 0xC85A00).opacity(0.7), 0.6)
        g.stroke(yellow, Color(hex: 0xE0962A).opacity(0.7), 0.6)
        g.fill(hearts, Color(hex: 0xA34700).opacity(0.75))
    }

    /// Twinkling fairy lights in warm colours, swagged below the garland.
    static func fairyLights(_ g: GraphicsContext, _ sc: Scene) {
        let (w, s, t) = (sc.w, sc.s, sc.time)
        let colors: [UInt32] = [0xFFD166, 0xFF8FA3, 0x7FE3CB, 0xFFB347, 0xB9A7FF]
        let anchors = (0...4).map { CGPoint(x: w * CGFloat($0) / 4, y: 15 * s) }
        let wire = sc.dark ? Color(hex: 0x8A7A5A).opacity(0.5) : Color(hex: 0x6E5A3A).opacity(0.45)
        var index = 0
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            g.stroke(swagPath(a, b, sag: 11 * s), wire, 0.7)
            for step in 1...8 {
                let p = swagPoint(a, b, sag: 11 * s, CGFloat(step) / 9)
                let twinkle = sc.reduced ? 0.85 : 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2.3 + Double(index) * 1.7))
                let color = Color(hex: colors[index % colors.count])
                glow(g, at: CGPoint(x: p.x, y: p.y + 2 * s), radius: 6 * s, color: color, opacity: (sc.dark ? 0.6 : 0.4) * twinkle)
                g.fill(.ellipse(CGPoint(x: p.x, y: p.y + 1.8 * s), 2.4 * s, 3.2 * s), color.opacity(0.55 + 0.45 * twinkle))
                index += 1
            }
        }
    }

    /// A clay oil lamp with a flickering flame.
    static func diya(_ g: GraphicsContext, foot: CGPoint, width wd: CGFloat, time: Double, phase: Double, dark: Bool, lit: Bool = true) {
        let f = flicker(time, phase)
        let tip = CGPoint(x: foot.x + wd * 0.38, y: foot.y - wd * 0.42)
        if lit {
            glow(g, at: CGPoint(x: tip.x, y: tip.y - wd * 0.35), radius: wd * (1.7 + 0.12 * CGFloat(f)), color: Color(hex: 0xFFC14D),
                 opacity: (dark ? 0.6 : 0.38) * f)
            g.fill(.ellipse(CGPoint(x: foot.x, y: foot.y), wd * 1.0, wd * 0.18), Color.black.opacity(dark ? 0.3 : 0.14))
        }
        // Bowl: rounded underneath, pinched into a spout on the right.
        var bowl = Path()
        bowl.move(to: CGPoint(x: foot.x - wd * 0.5, y: foot.y - wd * 0.36))
        bowl.addQuadCurve(to: CGPoint(x: foot.x + wd * 0.1, y: foot.y), control: CGPoint(x: foot.x - wd * 0.45, y: foot.y + wd * 0.02))
        bowl.addQuadCurve(to: CGPoint(x: tip.x, y: tip.y), control: CGPoint(x: foot.x + wd * 0.42, y: foot.y - wd * 0.08))
        bowl.addQuadCurve(to: CGPoint(x: foot.x - wd * 0.5, y: foot.y - wd * 0.36), control: CGPoint(x: foot.x, y: foot.y - wd * 0.28))
        bowl.closeSubpath()
        g.fill(bowl, Color(hex: 0xC2512B))
        g.stroke(bowl, Color(hex: 0x8C3518), max(0.5, wd / 22))
        g.fill(.ellipse(CGPoint(x: foot.x - wd * 0.08, y: foot.y - wd * 0.32), wd * 0.72, wd * 0.14), Color(hex: 0x5A2A12))
        g.stroke(.ellipse(CGPoint(x: foot.x - wd * 0.08, y: foot.y - wd * 0.32), wd * 0.72, wd * 0.14), Color(hex: 0xE58A4E), max(0.5, wd / 24))
        for (index, dx) in [-0.28, -0.08, 0.12].enumerated() {
            g.fill(.ellipse(CGPoint(x: foot.x + wd * dx, y: foot.y - wd * 0.14), wd * 0.08, wd * 0.08),
                   index == 1 ? Color.white.opacity(0.9) : Color(hex: 0xFFD166))
        }
        // Flame.
        let height = wd * 0.62 * CGFloat(0.85 + 0.2 * f)
        let sway = CGFloat(sin(time * 3.1 + phase)) * wd * 0.04
        var flame = Path()
        flame.move(to: CGPoint(x: tip.x, y: tip.y + wd * 0.02))
        flame.addQuadCurve(to: CGPoint(x: tip.x + sway, y: tip.y - height), control: CGPoint(x: tip.x - wd * 0.2, y: tip.y - height * 0.35))
        flame.addQuadCurve(to: CGPoint(x: tip.x, y: tip.y + wd * 0.02), control: CGPoint(x: tip.x + wd * 0.2, y: tip.y - height * 0.35))
        g.fill(flame, Color(hex: 0xFF9A1F))
        var core = Path()
        core.move(to: CGPoint(x: tip.x, y: tip.y))
        core.addQuadCurve(to: CGPoint(x: tip.x + sway * 0.6, y: tip.y - height * 0.6), control: CGPoint(x: tip.x - wd * 0.1, y: tip.y - height * 0.22))
        core.addQuadCurve(to: CGPoint(x: tip.x, y: tip.y), control: CGPoint(x: tip.x + wd * 0.1, y: tip.y - height * 0.22))
        g.fill(core, Color(hex: 0xFFF3B0))
    }

    /// A colourful rangoli seen on the floor (squashed into perspective).
    static func rangoli(_ g: GraphicsContext, center: CGPoint, radius R: CGFloat) {
        var r = g
        r.translateBy(x: center.x, y: center.y)
        r.scaleBy(x: 1, y: 0.3)
        func petals(_ count: Int, from inner: CGFloat, to outer: CGFloat, width: CGFloat, offset: Double, every: Int = 1, phase: Int = 0) -> Path {
            var path = Path()
            for index in 0..<count where (index + phase) % every == 0 {
                let angle = Double(index) / Double(count) * 2 * .pi + offset
                let (c, s) = (CGFloat(cos(angle)), CGFloat(sin(angle)))
                let a = CGPoint(x: c * inner, y: s * inner)
                let b = CGPoint(x: c * outer, y: s * outer)
                let mid = (inner + outer) / 2
                path.move(to: a)
                path.addQuadCurve(to: b, control: CGPoint(x: c * mid - s * width, y: s * mid + c * width))
                path.addQuadCurve(to: a, control: CGPoint(x: c * mid + s * width, y: s * mid - c * width))
            }
            return path
        }
        var outline = Path()
        for index in 0..<36 {
            let angle = Double(index) / 36 * 2 * .pi
            outline.addEllipse(in: CGRect(x: CGFloat(cos(angle)) * R * 1.06 - R * 0.03, y: CGFloat(sin(angle)) * R * 1.06 - R * 0.03,
                                          width: R * 0.06, height: R * 0.06))
        }
        r.fill(outline, Color.white.opacity(0.85))
        r.fill(petals(12, from: R * 0.6, to: R, width: R * 0.17, offset: 0, every: 2), Color(hex: 0xD7266B))
        r.fill(petals(12, from: R * 0.6, to: R, width: R * 0.17, offset: 0, every: 2, phase: 1), Color(hex: 0xFF8C1A))
        var dots = Path()
        for index in 0..<24 {
            let angle = Double(index) / 24 * 2 * .pi
            dots.addEllipse(in: CGRect(x: CGFloat(cos(angle)) * R * 0.56 - R * 0.035, y: CGFloat(sin(angle)) * R * 0.56 - R * 0.035,
                                       width: R * 0.07, height: R * 0.07))
        }
        r.fill(.ellipse(.zero, R * 1.1, R * 1.1), Color(hex: 0x2EC4B6))
        r.fill(dots, Color.white)
        r.fill(petals(8, from: R * 0.16, to: R * 0.5, width: R * 0.13, offset: .pi / 8), Color(hex: 0xFFC93C))
        r.fill(.ellipse(.zero, R * 0.34, R * 0.34), Color(hex: 0x6A3FB5))
        r.fill(.ellipse(.zero, R * 0.14, R * 0.14), Color(hex: 0xFFE7A3))
    }

    /// Glowing motes drifting up through the room, away from the faces.
    static func floatingLights(_ g: GraphicsContext, _ sc: Scene) {
        for index in 0..<8 {
            let period = 9 + Ease.hash(index, 21) * 5
            let p = Ease.fract(sc.time / period + Ease.hash(index, 22))
            let x = sc.w * CGFloat(Ease.hash(index, 23)) + CGFloat(sin(sc.time * 0.7 + Double(index))) * 8 * sc.s
            let y = sc.ground - CGFloat(p) * (sc.ground + 10)
            let point = CGPoint(x: x, y: y)
            let alpha = Ease.bump(p, 0, 1) * sc.faceClearance(point) * 0.9
            guard alpha > 0.02 else { continue }
            glow(g, at: point, radius: 6 * sc.s, color: Color(hex: 0xFFC94D), opacity: alpha * 0.55)
            g.fill(.ellipse(point, 2.2 * sc.s, 2.2 * sc.s), Color(hex: 0xFFF1C2).opacity(alpha))
        }
        // A couple of marigold petals tumbling down.
        for index in 0..<3 {
            let period = 11 + Ease.hash(index, 31) * 4
            let p = Ease.fract(sc.time / period + Ease.hash(index, 32))
            let point = CGPoint(x: sc.w * CGFloat(Ease.hash(index, 33)) + CGFloat(sin(sc.time * 1.1 + Double(index) * 2)) * 12 * sc.s,
                                y: -6 + CGFloat(p) * (sc.h + 12))
            let alpha = Ease.bump(p, 0, 1) * sc.faceClearance(point)
            guard alpha > 0.02 else { continue }
            var petal = g
            petal.translateBy(x: point.x, y: point.y)
            petal.rotate(by: .radians(sc.time * 1.7 + Double(index)))
            petal.fill(.ellipse(.zero, 3.6 * sc.s, 2 * sc.s), (index % 2 == 0 ? marigoldOrange : marigoldYellow).opacity(alpha))
        }
    }

    // MARK: - Christmas

    static func christmas(_ g: GraphicsContext, _ sc: Scene) {
        let (w, s, ground, t) = (sc.w, sc.s, sc.ground, sc.time)
        // Snow outside the window, or a wreath around the porthole in space.
        if let window = sc.window {
            if sc.theme == .spaceStation {
                wreath(g, sc)
            } else {
                var outside = g
                outside.clip(to: window)
                let bounds = window.boundingRect
                snowflakes(outside, in: bounds, count: 14, time: t, reduced: sc.reduced, size: 1.8 * s, color: Color.white.opacity(0.95))
                var drift = Path()
                drift.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
                drift.addCurve(to: CGPoint(x: bounds.maxX, y: bounds.maxY - 3 * s), control1: CGPoint(x: bounds.minX + bounds.width * 0.3, y: bounds.maxY - 12 * s),
                               control2: CGPoint(x: bounds.minX + bounds.width * 0.6, y: bounds.maxY - 2 * s))
                drift.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
                drift.closeSubpath()
                outside.fill(drift, Color.white.opacity(0.92))
            }
        } else {
            // No window: a gentle snowfall over the backdrop.
            snowflakes(g, in: CGRect(x: 0, y: 0, width: w, height: ground), count: 16, time: t * 0.8, reduced: sc.reduced, size: 1.5 * s,
                       color: Color.white.opacity(0.55))
        }
        evergreenGarland(g, sc)
        stocking(g, top: CGPoint(x: w * 0.415, y: sc.h * 0.34), size: 21 * s, color: Color(hex: 0xD94B4B), swing: sc.reduced ? 0 : sin(t * 0.8) * 0.04)
        stocking(g, top: CGPoint(x: w * 0.478, y: sc.h * 0.36), size: 19 * s, color: Color(hex: 0x3C9A5F), swing: sc.reduced ? 0 : sin(t * 0.8 + 1) * 0.04)
        presents(g, foot: CGPoint(x: w * 0.85, y: ground + 6 * s), s: s, dark: sc.dark)
        tree(g, foot: CGPoint(x: w * 0.94, y: ground + 4 * s), height: 70 * s, time: t, reduced: sc.reduced, dark: sc.dark)
    }

    static func snowflakes(_ g: GraphicsContext, in rect: CGRect, count: Int, time: Double, reduced: Bool, size: CGFloat, color: Color) {
        var flakes = Path()
        for index in 0..<count {
            let speed = 0.08 + Ease.hash(index, 41) * 0.06
            let p = reduced ? Ease.hash(index, 42) : Ease.fract(time * speed + Ease.hash(index, 42))
            let x = rect.minX + CGFloat(Ease.hash(index, 43)) * rect.width + CGFloat(sin(time * 0.9 + Double(index))) * 3
            let y = rect.minY - 3 + CGFloat(p) * (rect.height + 6)
            let r = size * CGFloat(0.7 + Ease.hash(index, 44) * 0.6)
            flakes.addEllipse(in: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r))
        }
        g.fill(flakes, color)
    }

    static func wreath(_ g: GraphicsContext, _ sc: Scene) {
        let radius = min(sc.h * 0.27, 40) + 5
        let center = CGPoint(x: sc.w * 0.2, y: sc.h * 0.36)
        var needles = Path()
        var berries = Path()
        for index in 0..<30 {
            let angle = Double(index) / 30 * 2 * .pi
            let p = CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
            needles.addEllipse(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
            if index % 5 == 2 { berries.addEllipse(in: CGRect(x: p.x + 1, y: p.y - 1, width: 3.4, height: 3.4)) }
        }
        g.fill(needles, Color(hex: 0x2F7D4F))
        g.stroke(needles, Color(hex: 0x3C9A5F), 1)
        g.fill(berries, Color(hex: 0xE23D3D))
        bow(g, center: CGPoint(x: center.x, y: center.y + radius + 2), size: 9)
    }

    static func bow(_ g: GraphicsContext, center c: CGPoint, size: CGFloat) {
        let red = Color(hex: 0xE23D3D)
        for side in [-1.0, 1.0] as [CGFloat] {
            var loop = Path()
            loop.move(to: c)
            loop.addQuadCurve(to: CGPoint(x: c.x + side * size, y: c.y - size * 0.1), control: CGPoint(x: c.x + side * size * 0.6, y: c.y - size * 0.75))
            loop.addQuadCurve(to: c, control: CGPoint(x: c.x + side * size * 0.6, y: c.y + size * 0.5))
            g.fill(loop, red)
            var tail = Path()
            tail.move(to: c)
            tail.addLine(to: CGPoint(x: c.x + side * size * 0.45, y: c.y + size * 0.95))
            g.stroke(tail, red, size * 0.22)
        }
        g.fill(.ellipse(c, size * 0.4, size * 0.4), Color(hex: 0xB82A2A))
    }

    /// Pine swags along the top with red bows and gold baubles.
    static func evergreenGarland(_ g: GraphicsContext, _ sc: Scene) {
        let (w, s) = (sc.w, sc.s)
        let anchors = (0...3).map { CGPoint(x: w * CGFloat($0) / 3, y: 0) }
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            let swag = swagPath(a, b, sag: 11 * s)
            g.stroke(swag, Color(hex: 0x2F7D4F), 7 * s)
            g.stroke(swag, with: .color(Color(hex: 0x3C9A5F)), style: StrokeStyle(lineWidth: 5 * s, lineCap: .round, dash: [1.4 * s, 2.2 * s]))
            for step in [0.25, 0.5, 0.75] as [CGFloat] {
                let p = swagPoint(a, b, sag: 11 * s, step)
                g.fill(.ellipse(CGPoint(x: p.x, y: p.y + 4.5 * s), 4.6 * s, 4.6 * s), Color(hex: step == 0.5 ? 0xFFD166 : 0xE23D3D))
                g.fill(.ellipse(CGPoint(x: p.x - 0.8 * s, y: p.y + 3.7 * s), 1.4 * s, 1.4 * s), Color.white.opacity(0.7))
            }
        }
        for anchor in anchors.dropFirst().dropLast() {
            bow(g, center: CGPoint(x: anchor.x, y: 3 * s), size: 6 * s)
        }
    }

    static func stocking(_ g: GraphicsContext, top: CGPoint, size: CGFloat, color: Color, swing: Double) {
        var st = g
        st.translateBy(x: top.x, y: top.y)
        st.rotate(by: .radians(swing))
        let k = size / 20
        st.stroke(Path { $0.move(to: CGPoint(x: 0, y: -4 * k)); $0.addLine(to: CGPoint(x: 0, y: 1 * k)) }, Color(hex: 0x9C7B4E), 0.8)
        st.fill(.ellipse(CGPoint(x: 0, y: -4.4 * k), 2.2 * k, 2.2 * k), Color(hex: 0xC9A15B))
        var sock = Path()
        sock.move(to: CGPoint(x: -4.5 * k, y: 2 * k))
        sock.addLine(to: CGPoint(x: -4.5 * k, y: 13 * k))
        sock.addQuadCurve(to: CGPoint(x: 1 * k, y: 19 * k), control: CGPoint(x: -4.5 * k, y: 19 * k))
        sock.addLine(to: CGPoint(x: 6 * k, y: 19 * k))
        sock.addQuadCurve(to: CGPoint(x: 6.5 * k, y: 13.5 * k), control: CGPoint(x: 9.5 * k, y: 17 * k))
        sock.addLine(to: CGPoint(x: 4.5 * k, y: 12 * k))
        sock.addLine(to: CGPoint(x: 4.5 * k, y: 2 * k))
        sock.closeSubpath()
        st.fill(sock, color)
        st.fill(.ellipse(CGPoint(x: 5.6 * k, y: 16.6 * k), 5 * k, 4.6 * k), Color.white.opacity(0.85))
        st.fill(.roundedRect(CGRect(x: -5.5 * k, y: 0, width: 11 * k, height: 4.6 * k), 2 * k), Color.white)
        st.fill(.star(CGPoint(x: 0, y: 8.5 * k), radius: 2.4 * k), Color(hex: 0xFFD166))
    }

    static func presents(_ g: GraphicsContext, foot: CGPoint, s: CGFloat, dark: Bool) {
        g.fill(.ellipse(CGPoint(x: foot.x, y: foot.y), 30 * s, 4 * s), Color.black.opacity(dark ? 0.3 : 0.12))
        for (dx, wd, ht, box, ribbon) in [(-7.0, 13.0, 10.0, 0xE23D3D, 0xFFD166), (6.0, 10.0, 8.0, 0x6FC3DF, 0xFFFFFF)] as [(CGFloat, CGFloat, CGFloat, UInt32, UInt32)] {
            let rect = CGRect(x: foot.x + dx * s - wd * s / 2, y: foot.y - ht * s, width: wd * s, height: ht * s)
            g.fill(.roundedRect(rect, 1.2 * s), Color(hex: box))
            g.fill(Path(CGRect(x: rect.midX - 1 * s, y: rect.minY, width: 2 * s, height: rect.height)), Color(hex: ribbon))
            g.fill(Path(CGRect(x: rect.minX, y: rect.midY - 0.9 * s, width: rect.width, height: 1.8 * s)), Color(hex: ribbon))
            for side in [-1.0, 1.0] as [CGFloat] {
                g.fill(.ellipse(CGPoint(x: rect.midX + side * 1.8 * s, y: rect.minY - 1 * s), 3.4 * s, 2.4 * s), Color(hex: ribbon))
            }
        }
    }

    /// A little decorated tree: blinking lights, baubles and a glowing star.
    static func tree(_ g: GraphicsContext, foot: CGPoint, height: CGFloat, time: Double, reduced: Bool, dark: Bool) {
        let k = height / 70
        g.fill(.ellipse(CGPoint(x: foot.x, y: foot.y), 40 * k, 5 * k), Color.black.opacity(dark ? 0.3 : 0.13))
        g.fill(.roundedRect(CGRect(x: foot.x - 3 * k, y: foot.y - 10 * k, width: 6 * k, height: 8 * k), 1 * k), Color(hex: 0x8A5A3C))
        g.fill(.roundedRect(CGRect(x: foot.x - 7 * k, y: foot.y - 6 * k, width: 14 * k, height: 7 * k), 2 * k), Color(hex: 0xC94A3F))
        let tiers: [(base: CGFloat, top: CGFloat, half: CGFloat)] = [(-8, -34, 19), (-26, -50, 15), (-42, -64, 10.5)]
        var lights: [CGPoint] = []
        for (index, tier) in tiers.enumerated() {
            var shape = Path()
            shape.move(to: CGPoint(x: foot.x - tier.half * k, y: foot.y + tier.base * k))
            shape.addQuadCurve(to: CGPoint(x: foot.x + tier.half * k, y: foot.y + tier.base * k), control: CGPoint(x: foot.x, y: foot.y + (tier.base + 4) * k))
            shape.addLine(to: CGPoint(x: foot.x, y: foot.y + tier.top * k))
            shape.closeSubpath()
            g.fill(shape, Color(hex: index % 2 == 0 ? 0x2F7D4F : 0x34885A))
            var shade = g
            shade.clip(to: shape)
            shade.fill(Path(CGRect(x: foot.x, y: foot.y + tier.top * k, width: tier.half * k, height: (tier.base - tier.top + 4) * k)),
                       Color.black.opacity(0.12))
            // A garland of lights across the tier.
            for step in 0..<4 {
                let t = (CGFloat(step) + 0.5) / 4
                lights.append(CGPoint(x: foot.x - tier.half * k * 0.82 + t * tier.half * k * 1.64,
                                      y: foot.y + (tier.base - 2.5 - 3 * sin(t * .pi)) * k))
            }
        }
        let bulbColors: [UInt32] = [0xFFD166, 0xFF6B6B, 0x7FD6F2, 0x9CE37D]
        let beat = Int(time / 0.7)
        for (index, p) in lights.enumerated() {
            let on = reduced || (index + beat) % 3 != 0
            let color = Color(hex: bulbColors[index % bulbColors.count])
            if on { glow(g, at: p, radius: 5 * k, color: color, opacity: dark ? 0.75 : 0.5) }
            g.fill(.ellipse(p, 3 * k, 3 * k), on ? color : color.opacity(0.35))
        }
        for (dx, dy, color) in [(-9.0, -14.0, 0xE23D3D), (8.0, -20.0, 0xFFD166), (-5.0, -37.0, 0x7FD6F2), (6.0, -44.0, 0xE23D3D)] as [(CGFloat, CGFloat, UInt32)] {
            let p = CGPoint(x: foot.x + dx * k, y: foot.y + dy * k)
            g.fill(.ellipse(p, 4.2 * k, 4.2 * k), Color(hex: color))
            g.fill(.ellipse(CGPoint(x: p.x - 0.7 * k, y: p.y - 0.7 * k), 1.3 * k, 1.3 * k), Color.white.opacity(0.7))
        }
        let star = CGPoint(x: foot.x, y: foot.y - 66 * k)
        let pulse = reduced ? 1 : 0.8 + 0.2 * sin(time * 2)
        glow(g, at: star, radius: 12 * k, color: Color(hex: 0xFFE38A), opacity: (dark ? 0.7 : 0.5) * pulse)
        g.fill(.star(star, radius: 5.5 * k), Color(hex: 0xFFD166))
        g.stroke(.star(star, radius: 5.5 * k), Color(hex: 0xE0A82E), 0.6)
    }

    /// Gentle snow in front of everything, thinning out around the faces.
    static func snowfall(_ g: GraphicsContext, _ sc: Scene) {
        let shade = sc.dark ? Color.white : Color(hex: 0xFFFFFF)
        for index in 0..<26 {
            let speed = 0.06 + Ease.hash(index, 51) * 0.05
            let p = Ease.fract(sc.time * speed + Ease.hash(index, 52))
            let x = sc.w * CGFloat(Ease.hash(index, 53)) + CGFloat(sin(sc.time * 0.8 + Double(index) * 1.3)) * 6 * sc.s
            let y = -4 + CGFloat(p) * (sc.h + 8)
            let point = CGPoint(x: x, y: y)
            let alpha = sc.faceClearance(point) * (0.6 + 0.35 * Ease.hash(index, 54))
            guard alpha > 0.02 else { continue }
            let r = (1.4 + CGFloat(Ease.hash(index, 55)) * 1.4) * sc.s
            if !sc.dark { g.fill(.ellipse(CGPoint(x: x + 0.3, y: y + 0.4), r * 1.25, r * 1.25), Color(hex: 0x9DB2CC).opacity(alpha * 0.35)) }
            g.fill(.ellipse(point, r, r), shade.opacity(alpha))
        }
    }

    // MARK: - New Year

    static let partyColors: [UInt32] = [0xFFD166, 0xFF8FB1, 0x7FD6C2, 0xB9A7FF, 0x8FC7FF]

    static func newYear(_ g: GraphicsContext, _ sc: Scene) {
        let (w, s, ground, t) = (sc.w, sc.s, sc.ground, sc.time)
        // Curly streamers hanging from the ceiling.
        for (index, x) in [0.03, 0.15, 0.27, 0.72, 0.84, 0.97].enumerated() {
            let length = (24 + CGFloat(Ease.hash(index, 61)) * 22) * s
            let color = Color(hex: partyColors[index % partyColors.count])
            var ribbon = Path()
            let x0 = w * x
            ribbon.move(to: CGPoint(x: x0, y: 0))
            for step in 1...16 {
                let y = CGFloat(step) / 16 * length
                let wave = sin(Double(y / s) * 0.42 + (sc.reduced ? 0 : t * 1.4) + Double(index)) * Double(3 * s)
                ribbon.addLine(to: CGPoint(x: x0 + CGFloat(wave), y: y))
            }
            g.stroke(ribbon, color, 2.2 * s)
        }
        // "2027" bunting in the middle, plain flags either side.
        let digits = Array(String(SeasonRenderContext.newYear)).map(String.init)
        let a = CGPoint(x: w * 0.33, y: 2 * s)
        let b = CGPoint(x: w * 0.67, y: 2 * s)
        g.stroke(swagPath(a, b, sag: 7 * s), Color(hex: 0x8C7A9E).opacity(0.7), 0.8)
        let count = digits.count + 2
        for index in 0..<count {
            let tt = (CGFloat(index) + 0.5) / CGFloat(count)
            let p = swagPoint(a, b, sag: 7 * s, tt)
            let isDigit = index > 0 && index <= digits.count
            let color = Color(hex: [0x3B3B98, 0xFF8FB1, 0xFFB000, 0x2EAA9A, 0x7A5CD6, 0xE85D75][index % 6])
            let sway = sc.reduced ? 0 : sin(t * 1.3 + Double(index)) * 0.05
            pennant(g, top: p, width: (isDigit ? 15 : 11) * s, height: (isDigit ? 19 : 13) * s, color: color,
                    letter: isDigit ? digits[index - 1] : nil, sway: sway)
        }
        // Confetti on the floor.
        var bits: [Path] = Array(repeating: Path(), count: partyColors.count)
        for index in 0..<26 {
            let x = w * CGFloat(Ease.hash(index, 63))
            let y = ground + 3 * s + CGFloat(Ease.hash(index, 64)) * (sc.h - ground - 6 * s)
            bits[index % bits.count].addRoundedRect(in: CGRect(x: x, y: y, width: 3 * s, height: 1.6 * s), cornerSize: CGSize(width: 0.6, height: 0.6))
        }
        for (index, path) in bits.enumerated() { g.fill(path, Color(hex: partyColors[index]).opacity(0.9)) }
        // Sparklers in a jar in the corner.
        sparklerJar(g, foot: CGPoint(x: w * 0.06, y: ground + 6 * s), s: s, time: t, reduced: sc.reduced, dark: sc.dark)
    }

    static func sparklerJar(_ g: GraphicsContext, foot: CGPoint, s: CGFloat, time: Double, reduced: Bool, dark: Bool) {
        for (index, angle) in [-0.35, 0.0, 0.3].enumerated() {
            let tip = CGPoint(x: foot.x + CGFloat(sin(angle)) * 22 * s, y: foot.y - 10 * s - CGFloat(cos(angle)) * 18 * s)
            g.stroke(Path { $0.move(to: CGPoint(x: foot.x, y: foot.y - 8 * s)); $0.addLine(to: tip) }, Color(hex: 0x9AA0AE), 1 * s)
            let f = reduced ? 1 : flicker(time * 1.6, Double(index) * 2)
            glow(g, at: tip, radius: 9 * s, color: Color(hex: 0xFFE38A), opacity: (dark ? 0.8 : 0.55) * f)
            let tick = reduced ? 1 : UInt64(max(0, Int(time * 12)) & 0xFFFF)
            for ray in 0..<8 {
                let a = Double(ray) / 8 * 2 * .pi + (reduced ? 0 : time * 3 + Double(index))
                let length = (3 + 2 * CGFloat(Ease.hash(ray + index * 8, tick))) * s
                g.stroke(Path { $0.move(to: tip); $0.addLine(to: CGPoint(x: tip.x + CGFloat(cos(a)) * length, y: tip.y + CGFloat(sin(a)) * length)) },
                         Color(hex: 0xFFF1B8), 0.6 * s)
            }
        }
        let jar = CGRect(x: foot.x - 6 * s, y: foot.y - 11 * s, width: 12 * s, height: 11 * s)
        g.fill(.roundedRect(jar, 2.5 * s), Color(hex: 0xBFE4F2).opacity(0.75))
        g.stroke(.roundedRect(jar, 2.5 * s), Color(hex: 0x7FA9BC), 0.8)
        g.fill(.roundedRect(CGRect(x: jar.minX + 1 * s, y: jar.minY - 1.5 * s, width: jar.width - 2 * s, height: 2.2 * s), 1), Color(hex: 0xE0A82E))
    }

    /// Fireworks bursting high up, in the corners and over the middle, never over the faces.
    static func fireworks(_ g: GraphicsContext, _ sc: Scene) {
        let slots: [ClosedRange<Double>] = [0.05...0.22, 0.38...0.6, 0.84...0.96]
        for slot in 0..<3 {
            let period = 3.4
            let shifted = sc.time + Double(slot) * 1.15
            let cycle = Int(floor(shifted / period))
            let local = shifted - Double(cycle) * period
            let seed = UInt64(truncatingIfNeeded: cycle &* 7 &+ slot &* 131)
            let range = slots[slot]
            let center = CGPoint(x: sc.w * CGFloat(Ease.lerp(range.lowerBound, range.upperBound, Ease.hash(slot, seed))),
                                 y: sc.h * CGFloat(0.1 + 0.14 * Ease.hash(slot + 9, seed)))
            let color = Color(hex: partyColors[Int(Ease.hash(slot + 3, seed) * Double(partyColors.count)) % partyColors.count])
            if local < 0.5 {
                // The rocket climbing to the burst.
                let p = local / 0.5
                let y = center.y + CGFloat(1 - p) * 26 * sc.s
                g.fill(.ellipse(CGPoint(x: center.x, y: y), 2 * sc.s, 3 * sc.s), color.opacity(0.9))
                g.stroke(Path { $0.move(to: CGPoint(x: center.x, y: y + 2 * sc.s)); $0.addLine(to: CGPoint(x: center.x, y: y + 9 * sc.s)) },
                         color.opacity(0.35), 1 * sc.s)
                continue
            }
            let p = Ease.segment(local, 0.5, 2.6)
            guard p < 1 else { continue }
            let radius = CGFloat(Ease.outCubic(p)) * 19 * sc.s
            let alpha = 1 - p * p
            glow(g, at: center, radius: 14 * sc.s, color: color, opacity: 0.4 * (1 - p))
            var sparks = Path()
            for index in 0..<14 {
                let angle = Double(index) / 14 * 2 * .pi + Ease.hash(slot, seed) * 3
                let droop = CGFloat(p * p) * 6 * sc.s
                let tip = CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius + droop)
                let tail = CGPoint(x: center.x + CGFloat(cos(angle)) * radius * 0.7, y: center.y + CGFloat(sin(angle)) * radius * 0.7 + droop * 0.6)
                sparks.move(to: tail)
                sparks.addLine(to: tip)
            }
            g.stroke(sparks, color.opacity(alpha), 1.3 * sc.s)
        }
    }

    // MARK: - Valentine's

    static func valentines(_ g: GraphicsContext, _ sc: Scene) {
        let (w, s, t) = (sc.w, sc.s, sc.time)
        // Floating hearts drifting up behind the friends.
        if !sc.reduced {
            for index in 0..<7 {
                let period = 10 + Ease.hash(index, 71) * 6
                let p = Ease.fract(t / period + Ease.hash(index, 72))
                let point = CGPoint(x: w * CGFloat(Ease.hash(index, 73)) + CGFloat(sin(t * 0.9 + Double(index))) * 7 * s,
                                    y: sc.ground - CGFloat(p) * sc.ground * 0.95)
                let size = (7 + CGFloat(Ease.hash(index, 74)) * 6) * s
                let alpha = Ease.bump(p, 0, 1) * (sc.dark ? 0.9 : 0.7)
                if sc.dark { glow(g, at: point, radius: size, color: Color(hex: 0xFF8FB1), opacity: alpha * 0.35) }
                g.fill(.heart(point, size: size), Color(hex: index % 2 == 0 ? 0xFF9FBF : 0xFF7A9C).opacity(alpha))
            }
        }
        // A garland of hearts across the top.
        let anchors = [CGPoint(x: -4, y: 2 * s), CGPoint(x: w / 2, y: 4 * s), CGPoint(x: w + 4, y: 2 * s)]
        var index = 0
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            g.stroke(swagPath(a, b, sag: 12 * s), Color(hex: 0xD9A0B4), 0.9)
            for step in 1...7 {
                let p = swagPoint(a, b, sag: 12 * s, CGFloat(step) / 8)
                let swing = sc.reduced ? 0 : CGFloat(sin(t * 1.2 + Double(index))) * 1.2 * s
                let heart = CGPoint(x: p.x + swing, y: p.y + 7 * s)
                g.stroke(Path { $0.move(to: p); $0.addLine(to: CGPoint(x: heart.x, y: heart.y - 3 * s)) }, Color(hex: 0xD9A0B4), 0.6)
                g.fill(.heart(heart, size: (index % 3 == 1 ? 7 : 9) * s), Color(hex: [0xFF6F91, 0xFFC2D4, 0xF0525A][index % 3]))
                index += 1
            }
        }
    }

    // MARK: - Birthdays

    static func birthday(_ g: GraphicsContext, _ sc: Scene) {
        let (w, s, ground, t) = (sc.w, sc.s, sc.ground, sc.time)
        // "HAPPY BIRTHDAY" bunting.
        let letters = Array("HAPPY BIRTHDAY").map(String.init)
        let a = CGPoint(x: w * 0.14, y: 2 * s)
        let b = CGPoint(x: w * 0.86, y: 2 * s)
        g.stroke(swagPath(a, b, sag: 12 * s), Color(hex: 0x8C7A9E).opacity(0.7), 0.8)
        for (index, letter) in letters.enumerated() where letter != " " {
            let p = swagPoint(a, b, sag: 12 * s, (CGFloat(index) + 0.5) / CGFloat(letters.count))
            let sway = sc.reduced ? 0 : sin(t * 1.3 + Double(index) * 0.8) * 0.05
            pennant(g, top: p, width: 14 * s, height: 17 * s, color: Color(hex: [0xFF8FB1, 0x7FC8F8, 0xFFC94D, 0x9AD99A, 0xB9A7FF][index % 5]),
                    letter: letter, sway: sway)
        }
        // Balloon bunches tied in the corners.
        balloons(g, tie: CGPoint(x: w * 0.06, y: ground + 4 * s), offsets: [(0, -78), (12, -66), (-9, -58)], colors: [0xFF8FB1, 0x7FC8F8, 0xFFC94D],
                 s: s, time: t, reduced: sc.reduced)
        balloons(g, tie: CGPoint(x: w * 0.965, y: ground + 4 * s), offsets: [(2, -74), (-11, -62)], colors: [0xB9A7FF, 0x9AD99A], s: s, time: t + 2,
                 reduced: sc.reduced)
        cake(g, foot: CGPoint(x: w * 0.465, y: ground + 7 * s), s: s, candles: SeasonRenderContext.candles, time: t, dark: sc.dark)
    }

    static func balloons(_ g: GraphicsContext, tie: CGPoint, offsets: [(CGFloat, CGFloat)], colors: [UInt32], s: CGFloat, time: Double, reduced: Bool) {
        for (index, offset) in offsets.enumerated() {
            let bob = reduced ? 0 : CGFloat(sin(time * 1.1 + Double(index) * 1.9)) * 2.5 * s
            let center = CGPoint(x: tie.x + offset.0 * s + bob * 0.4, y: tie.y + offset.1 * s + bob)
            let knot = CGPoint(x: center.x, y: center.y + 11 * s)
            var string = Path()
            string.move(to: knot)
            string.addQuadCurve(to: tie, control: CGPoint(x: (knot.x + tie.x) / 2 + 5 * s, y: (knot.y + tie.y) / 2))
            g.stroke(string, Color(hex: 0x9C8FA8).opacity(0.8), 0.7)
            let color = Color(hex: colors[index % colors.count])
            g.fill(.ellipse(center, 17 * s, 21 * s), color)
            g.fill(Path { p in
                p.move(to: CGPoint(x: knot.x - 2 * s, y: knot.y + 1.5 * s))
                p.addLine(to: CGPoint(x: knot.x + 2 * s, y: knot.y + 1.5 * s))
                p.addLine(to: CGPoint(x: knot.x, y: knot.y - 1 * s))
                p.closeSubpath()
            }, color)
            g.fill(.ellipse(CGPoint(x: center.x - 4 * s, y: center.y - 5 * s), 4.5 * s, 6 * s), Color.white.opacity(0.45))
        }
    }

    static func cake(_ g: GraphicsContext, foot: CGPoint, s: CGFloat, candles: Int, time: Double, dark: Bool) {
        g.fill(.ellipse(CGPoint(x: foot.x, y: foot.y), 40 * s, 6 * s), Color.black.opacity(dark ? 0.3 : 0.12))
        g.fill(.ellipse(CGPoint(x: foot.x, y: foot.y - 1 * s), 38 * s, 6 * s), Color(hex: 0xF4F1F8))
        let bottom = CGRect(x: foot.x - 15 * s, y: foot.y - 14 * s, width: 30 * s, height: 12 * s)
        let top = CGRect(x: foot.x - 10 * s, y: bottom.minY - 9 * s, width: 20 * s, height: 9 * s)
        for (rect, body, icing) in [(bottom, 0xFFB3C7, 0xFFF4F7), (top, 0xFFE7B8, 0xFF8FB1)] as [(CGRect, UInt32, UInt32)] {
            g.fill(.roundedRect(rect, 2.5 * s), Color(hex: body))
            var drips = Path()
            drips.move(to: CGPoint(x: rect.minX, y: rect.minY))
            let count = Int(rect.width / (5 * s))
            for step in 0...count {
                let x = rect.minX + CGFloat(step) / CGFloat(max(1, count)) * rect.width
                drips.addLine(to: CGPoint(x: x, y: rect.minY + (step % 2 == 0 ? 4.2 : 2.2) * s))
            }
            drips.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            drips.closeSubpath()
            g.fill(.roundedRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2.6 * s), 1.3 * s), Color(hex: icing))
            g.fill(drips, Color(hex: icing))
        }
        for (index, x) in [-11.0, -5.0, 2.0, 8.0, 12.0].enumerated() {
            g.fill(.roundedRect(CGRect(x: foot.x + x * s, y: bottom.midY + 1 * s, width: 2 * s, height: 1 * s), 0.5),
                   Color(hex: partyColors[index % partyColors.count]))
        }
        let count = max(1, min(5, candles))
        for index in 0..<count {
            let x = top.minX + (CGFloat(index) + 0.5) / CGFloat(count) * top.width
            let candle = CGRect(x: x - 1 * s, y: top.minY - 7 * s, width: 2 * s, height: 7 * s)
            g.fill(.roundedRect(candle, 0.6 * s), Color(hex: partyColors[(index + 1) % partyColors.count]))
            let f = flicker(time, Double(index) * 1.7)
            let flameTip = CGPoint(x: x + CGFloat(sin(time * 3 + Double(index))) * 0.4 * s, y: candle.minY - 5 * s * CGFloat(0.85 + 0.2 * f))
            glow(g, at: CGPoint(x: x, y: candle.minY - 2.5 * s), radius: 7 * s, color: Color(hex: 0xFFC14D), opacity: (dark ? 0.6 : 0.4) * f)
            var flame = Path()
            flame.move(to: CGPoint(x: x, y: candle.minY))
            flame.addQuadCurve(to: flameTip, control: CGPoint(x: x - 2 * s, y: candle.minY - 2 * s))
            flame.addQuadCurve(to: CGPoint(x: x, y: candle.minY), control: CGPoint(x: x + 2 * s, y: candle.minY - 2 * s))
            g.fill(flame, Color(hex: 0xFFB13B))
            g.fill(.ellipse(CGPoint(x: x, y: candle.minY - 1.6 * s), 1.2 * s, 2 * s), Color(hex: 0xFFF3B0))
        }
    }

    /// Slow confetti drifting down in front, thinning around the faces.
    static func confettiFall(_ g: GraphicsContext, _ sc: Scene) {
        for index in 0..<12 {
            let speed = 0.05 + Ease.hash(index, 81) * 0.04
            let p = Ease.fract(sc.time * speed + Ease.hash(index, 82))
            let point = CGPoint(x: sc.w * CGFloat(Ease.hash(index, 83)) + CGFloat(sin(sc.time + Double(index))) * 8 * sc.s, y: -4 + CGFloat(p) * (sc.h + 8))
            let alpha = sc.faceClearance(point) * 0.9
            guard alpha > 0.02 else { continue }
            var bit = g
            bit.translateBy(x: point.x, y: point.y)
            bit.rotate(by: .radians(sc.time * 2.4 + Double(index)))
            bit.scaleBy(x: CGFloat(cos(sc.time * 3 + Double(index))), y: 1)
            bit.fill(.roundedRect(CGRect(x: -2 * sc.s, y: -1 * sc.s, width: 4 * sc.s, height: 2 * sc.s), 0.5),
                     Color(hex: partyColors[index % partyColors.count]).opacity(alpha))
        }
    }

    // MARK: - Menu bar

    /// A tiny, static decoration standing on the menu bar beside the bed (≈ 8 pt tall at scale 1).
    static func menuBarAccent(_ event: SeasonalEvent, in g: GraphicsContext, at foot: CGPoint, scale: CGFloat, dark: Bool) {
        var a = g
        a.translateBy(x: foot.x, y: foot.y)
        a.scaleBy(x: scale, y: scale)
        switch event {
        case .halloween:
            miniPumpkin(a, center: CGPoint(x: 0, y: -3.2), width: 8.2)
            a.fill(.ellipse(CGPoint(x: -1.4, y: -3.6), 1.2, 1.2), Color(hex: 0x6B2E0A))
            a.fill(.ellipse(CGPoint(x: 1.4, y: -3.6), 1.2, 1.2), Color(hex: 0x6B2E0A))
        case .diwali:
            glow(a, at: CGPoint(x: 3.2, y: -5.5), radius: 4, color: Color(hex: 0xFFC14D), opacity: dark ? 0.55 : 0.4)
            diya(a, foot: CGPoint(x: 0, y: 0), width: 8.5, time: 0, phase: 0, dark: dark, lit: false)
        case .christmas:
            tree(a, foot: CGPoint(x: 0, y: 0), height: 9.5, time: 0, reduced: true, dark: dark)
        case .newYear:
            var cone = a
            cone.rotate(by: .degrees(-25))
            var popper = Path()
            popper.move(to: CGPoint(x: -1.3, y: 0))
            popper.addLine(to: CGPoint(x: 1.3, y: 0))
            popper.addLine(to: CGPoint(x: 2.4, y: -6.5))
            popper.addLine(to: CGPoint(x: -2.4, y: -6.5))
            popper.closeSubpath()
            cone.fill(popper, Color(hex: 0xFF8FB1))
            cone.fill(Path(CGRect(x: -2, y: -4.2, width: 4, height: 1.2)), Color(hex: 0xFFD166))
            for (index, (x, y)) in [(-3.5, -9.0), (0.5, -10.5), (4.0, -8.5), (5.5, -5.5)].enumerated() {
                a.fill(.roundedRect(CGRect(x: x, y: y, width: 1.8, height: 1.1), 0.3), Color(hex: partyColors[index % partyColors.count]))
            }
        case .userBirthday, .mochiBirthday:
            var string = Path()
            string.move(to: CGPoint(x: 0, y: 0))
            string.addQuadCurve(to: CGPoint(x: 0, y: -4.5), control: CGPoint(x: 1.4, y: -2.4))
            a.stroke(string, Color(hex: 0x9C8FA8), 0.5)
            a.fill(.ellipse(CGPoint(x: 0, y: -7.6), 5.4, 6.4), Color(hex: 0xFF8FB1))
            a.fill(.ellipse(CGPoint(x: -1.1, y: -8.8), 1.4, 1.9), Color.white.opacity(0.55))
        case .valentines:
            a.fill(.heart(CGPoint(x: 0, y: -3.6), size: 7), Color(hex: 0xFF6F91))
            a.fill(.ellipse(CGPoint(x: -1.4, y: -4.6), 1.6, 1.1), Color.white.opacity(0.5))
        }
    }
}
