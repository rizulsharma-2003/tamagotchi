import SwiftUI
import TamagotchiCore

/// Draws the companion's workstation: the Claude Code mascot (``PixelMascot``) standing on
/// the desk beside a small laptop whose screen shows what kind of work the *event* indicates.
/// Local units: origin on the floor below the workstation, y up is negative.
enum CompanionRenderer {
    static let unit: CGFloat = 54
    /// One art pixel of the mascot, in local units.
    static let pixel: CGFloat = 2.5
    static let deskTop: CGFloat = -22.5
    /// The mascot's spot on the desk, and the laptop's (towards the pet).
    static let homeX: CGFloat = 14
    static let laptopX: CGFloat = -36

    /// `origin` is the workstation (desk and laptop stay there); `offsetX` moves only the
    /// mascot, in points, e.g. when it steps away from the desk. Without a workstation the
    /// mascot stands on the floor at `origin` with nothing around it.
    static func draw(
        _ pose: CompanionPose,
        in context: GraphicsContext,
        at origin: CGPoint,
        offsetX: CGFloat = 0,
        scale: CGFloat,
        accessory: Accessory?,
        dark: Bool,
        time: TimeInterval? = nil,
        speed: CGFloat = 0,
        reduced: Bool = false,
        workstation: Bool = true,
        deskFront: (GraphicsContext) -> Void
    ) {
        let time = time ?? ProcessInfo.processInfo.systemUptime
        var base = context
        base.translateBy(x: origin.x, y: origin.y)
        base.scaleBy(x: scale, y: scale)

        let x = (workstation ? homeX : 0) + offsetX / scale
        let floor = workstation ? support(at: x) : 0
        if workstation {
            deskFront(base)
            drawLaptop(pose, base, time: time)
        }
        var options = PixelMascot.Options()
        options.accessory = accessory
        options.laptopOnLeft = workstation
        options.reduced = reduced
        options.speed = speed / (pixel * scale)
        PixelMascot.draw(pose, in: base, feet: CGPoint(x: x, y: -floor), pixel: pixel, time: time, options: options)

        if pose.opacity > 0.01, !pose.effects.isEmpty {
            var effects = base
            effects.opacity = pose.opacity
            // Marks are authored around the floor below the desk; follow the mascot down when it hops off.
            effects.translateBy(x: x, y: -CGFloat(pose.y) * unit + (workstation ? -deskTop - floor : -deskTop))
            for effect in pose.effects {
                EffectRenderer.draw(effect, in: effects, unitX: 60, unitY: unit, dark: dark)
            }
        }
    }

    /// How high the mascot's feet are above the floor at local x: on the desk at home, hopping
    /// down past its right end (the only way it leaves) and back up on the way home.
    static func support(at x: CGFloat) -> CGFloat {
        let top = -deskTop
        let edge: CGFloat = 50
        let landing: CGFloat = 64
        if x <= edge { return top }
        if x >= landing { return 0 }
        let u = Double((x - edge) / (landing - edge))
        return top * CGFloat(1 - u * u) + 6 * CGFloat(Ease.hop(u))
    }

    // MARK: Laptop

    static func drawLaptop(_ pose: CompanionPose, _ ctx: GraphicsContext, time: TimeInterval) {
        guard pose.laptop.visible else { return }
        let open = CGFloat(Ease.clamp(pose.laptop.openness))
        let cx = laptopX
        let top = deskTop
        var deck = Path()
        deck.move(to: CGPoint(x: cx - 15, y: top - 3))
        deck.addLine(to: CGPoint(x: cx + 15, y: top - 3))
        deck.addLine(to: CGPoint(x: cx + 17.5, y: top))
        deck.addLine(to: CGPoint(x: cx - 17.5, y: top))
        deck.closeSubpath()
        ctx.fill(deck, CompanionPalette.laptop)
        ctx.stroke(deck, CompanionPalette.laptopDark, 0.8)
        ctx.fill(Path(CGRect(x: cx - 11, y: top - 2.1, width: 22, height: 1)), CompanionPalette.laptopDark.opacity(0.55))
        guard open > 0.08 else {
            let lid = Path.roundedRect(CGRect(x: cx - 15, y: top - 4.6, width: 30, height: 1.8), 0.9)
            ctx.fill(lid, Color(hex: 0x3A3542))
            return
        }
        let height = 20 * open
        let lid = CGRect(x: cx - 14, y: top - 3 - height, width: 28, height: height)
        ctx.fill(.roundedRect(lid, 2), Color(hex: 0x2B2733))
        let display = lid.insetBy(dx: 1.6, dy: 1.6)
        guard display.height > 2 else { return }
        drawScreen(pose, in: ctx, rect: display, time: time)
    }

    static func drawScreen(_ pose: CompanionPose, in ctx: GraphicsContext, rect: CGRect, time: TimeInterval) {
        let screen = pose.laptop.screen
        let shape = Path.roundedRect(rect, 1)
        guard screen != .off else {
            ctx.fill(shape, Color(hex: 0x15131A))
            return
        }
        ctx.fill(shape, Color(hex: 0x1B1824))
        var content = ctx
        content.clip(to: shape)
        let scroll = CGFloat(pose.laptop.scroll)
        let tint: Color
        switch screen {
        case .error: tint = Color(hex: 0xFF8A7A)
        case .celebrate: tint = Color(hex: 0xFFD166)
        default: tint = Color(hex: 0x7FE3CB)
        }
        switch screen {
        case .code, .error:
            let colors = screen == .error
                ? [Color(hex: 0xFF8A7A), Color(hex: 0xFFC2B8), Color(hex: 0xFF8A7A)]
                : [Color(hex: 0x7FE3CB), Color(hex: 0xFFD166), Color(hex: 0xB9A7FF), Color(hex: 0xFF9FB2)]
            for row in 0..<6 {
                let y = rect.minY + 2 + CGFloat(row) * 2.8 - (scroll * 5).truncatingRemainder(dividingBy: 2.8)
                let indent = CGFloat((row * 7) % 3) * 2.4
                let width = CGFloat(6 + (row * 13) % 11)
                content.fill(.roundedRect(CGRect(x: rect.minX + 2 + indent, y: y, width: width, height: 1.3), 0.6), colors[row % colors.count].opacity(0.9))
            }
            if screen == .error {
                warning(in: content, center: CGPoint(x: rect.maxX - 4.5, y: rect.minY + 4.5), size: 6, color: tint)
            }
        case .terminal:
            for row in 0..<4 {
                let y = rect.minY + 2.5 + CGFloat(row) * 3.2
                prompt(in: content, at: CGPoint(x: rect.minX + 3, y: y + 0.6), size: 2.4, color: tint)
                let width = CGFloat(5 + ((row + Int(scroll * 2)) * 11) % 12)
                content.fill(.roundedRect(CGRect(x: rect.minX + 5.5, y: y, width: width, height: 1.3), 0.6), tint.opacity(0.8))
            }
        case .web:
            let center = CGPoint(x: rect.midX, y: rect.midY)
            content.stroke(.ellipse(center, 11, 11), tint, 0.8)
            content.stroke(.ellipse(center, 4 + 2.5 * sin(scroll), 11), tint.opacity(0.8), 0.7)
            var equator = Path()
            equator.move(to: CGPoint(x: center.x - 5.5, y: center.y))
            equator.addLine(to: CGPoint(x: center.x + 5.5, y: center.y))
            content.stroke(equator, tint.opacity(0.8), 0.7)
        case .search:
            let lens = CGPoint(x: rect.minX + 5.5 + 2.5 * sin(scroll * 2), y: rect.minY + 6)
            content.stroke(.ellipse(lens, 5, 5), tint, 1)
            var handle = Path()
            handle.move(to: CGPoint(x: lens.x + 1.8, y: lens.y + 1.8))
            handle.addLine(to: CGPoint(x: lens.x + 4, y: lens.y + 4))
            content.stroke(handle, tint, 1.2)
            for row in 0..<3 {
                content.fill(.roundedRect(CGRect(x: rect.minX + 12, y: rect.minY + 3.5 + CGFloat(row) * 3.6, width: 10, height: 1.4), 0.7),
                             tint.opacity(row == 1 ? 1 : 0.5))
            }
        case .docs:
            let page = CGRect(x: rect.midX - 5, y: rect.minY + 1.5, width: 10, height: rect.height - 3)
            content.fill(.roundedRect(page, 1), Color.white.opacity(0.85))
            for row in 0..<4 {
                content.fill(Path(CGRect(x: page.minX + 1.5, y: page.minY + 2 + CGFloat(row) * 2.6, width: CGFloat(7 - row % 2 * 2), height: 0.9)),
                             Color(hex: 0x5D5470))
            }
        case .celebrate:
            for index in 0..<4 {
                let angle = Double(index) * 1.6 + Double(scroll) * 2
                content.fill(.sparkle(CGPoint(x: rect.midX + CGFloat(cos(angle)) * 7, y: rect.midY + CGFloat(sin(angle)) * 4), radius: 2.6), tint)
            }
        case .idle:
            // Claude Code's prompt, waiting; amber with a question while Claude waits for you.
            let waiting = pose.antennaTint == .attention
            let color = waiting ? CompanionPalette.antenna(.attention) : Color(hex: 0xF2E6D8)
            prompt(in: content, at: CGPoint(x: rect.minX + 3.2, y: rect.minY + 3.4), size: 2.8, color: color.opacity(0.85))
            if waiting {
                question(in: content, center: CGPoint(x: rect.midX + 1, y: rect.midY + 0.5), size: 7, color: color)
            }
            if Int(floor(time / 0.6)) % 2 == 0 {
                content.fill(Path(CGRect(x: rect.minX + 5.6, y: rect.minY + 2, width: 2, height: 2.8)), color.opacity(0.8))
            }
        case .off:
            break
        }
        ctx.fill(shape, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0)]),
                                              startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
    }

    // Screen glyphs as paths: text and symbols would be laid out again on every frame.

    /// Claude Code's `>` prompt.
    static func prompt(in ctx: GraphicsContext, at center: CGPoint, size: CGFloat, color: Color) {
        var chevron = Path()
        chevron.move(to: CGPoint(x: center.x - size * 0.35, y: center.y - size * 0.5))
        chevron.addLine(to: CGPoint(x: center.x + size * 0.35, y: center.y))
        chevron.addLine(to: CGPoint(x: center.x - size * 0.35, y: center.y + size * 0.5))
        ctx.stroke(chevron, with: .color(color), style: StrokeStyle(lineWidth: max(0.7, size * 0.28), lineCap: .round, lineJoin: .round))
    }

    static func question(in ctx: GraphicsContext, center: CGPoint, size: CGFloat, color: Color) {
        var hook = Path()
        hook.addArc(center: CGPoint(x: center.x, y: center.y - size * 0.18), radius: size * 0.22, startAngle: .degrees(200), endAngle: .degrees(70),
                    clockwise: false)
        hook.addLine(to: CGPoint(x: center.x, y: center.y + size * 0.16))
        ctx.stroke(hook, with: .color(color), style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round, lineJoin: .round))
        ctx.fill(.ellipse(CGPoint(x: center.x, y: center.y + size * 0.4), size * 0.15, size * 0.15), color)
    }

    static func warning(in ctx: GraphicsContext, center: CGPoint, size: CGFloat, color: Color) {
        var triangle = Path()
        triangle.move(to: CGPoint(x: center.x, y: center.y - size * 0.5))
        triangle.addLine(to: CGPoint(x: center.x + size * 0.55, y: center.y + size * 0.45))
        triangle.addLine(to: CGPoint(x: center.x - size * 0.55, y: center.y + size * 0.45))
        triangle.closeSubpath()
        ctx.fill(triangle, color)
        ctx.fill(Path(CGRect(x: center.x - size * 0.06, y: center.y - size * 0.18, width: size * 0.12, height: size * 0.36)), Color(hex: 0x1B1824))
        ctx.fill(Path(CGRect(x: center.x - size * 0.06, y: center.y + size * 0.24, width: size * 0.12, height: size * 0.1)), Color(hex: 0x1B1824))
    }
}
