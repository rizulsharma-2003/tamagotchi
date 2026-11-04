import SwiftUI
import TamagotchiCore

/// The Claude Code mascot in pixel art: an 18×12 terracotta body with two tall slit eyes,
/// stubby arms and four legs (24×15 art pixels with arms and legs). Jumps, bobs and squash
/// stay smooth; eyes, arms and legs change in whole pixels, like hand-drawn frames.
///
/// Local units are art pixels: origin between the feet, x right, y down.
enum PixelMascot {
    static let body = Color(hex: 0xCC7A5D)
    static let ink = Color(hex: 0x1D1719)
    static let halfWidth: CGFloat = 9
    static let bodyRows: CGFloat = 12
    static let legRows: CGFloat = 3
    /// Companion pose units (`CompanionPose.y`) in art pixels.
    static let pixelsPerUnit: CGFloat = 21.6

    struct Options {
        var accessory: Accessory?
        /// A laptop stands to the mascot's left: typing reaches for it and the eyes follow.
        var laptopOnLeft = false
        var reduced = false
        /// Horizontal speed in art pixels per second; the legs step while it moves.
        var speed: CGFloat = 0
        /// Snap bobbing to this many art pixels (half a pixel keeps a 1-pt sprite crisp on Retina).
        var snap: CGFloat?
        var showsSpark = true
        var shadow = true
        /// Art pixels free above the head (the menu bar is short): the spinner moves beside the
        /// head when it wouldn't fit above a hat.
        var headroom: CGFloat?
    }

    /// Where the body is this frame, in art pixels.
    private struct Frame {
        var lift: CGFloat
        var rise: CGFloat
        var leanTop: CGFloat
        var top: CGFloat { -(legRows + rise + bodyRows) }
        var bottom: CGFloat { -(legRows + rise) }

        func shift(_ y: CGFloat) -> CGFloat { (leanTop * -y / 15).rounded() }
    }

    // MARK: Drawing

    /// Draws the mascot with its feet centred on `feet` (context units), `pixel` context units per art pixel.
    static func draw(_ pose: CompanionPose, in context: GraphicsContext, feet: CGPoint, pixel: CGFloat, time: TimeInterval,
                     options: Options = Options()) {
        guard pose.opacity > 0.01 else { return }
        var g = context
        g.opacity = pose.opacity
        g.translateBy(x: feet.x, y: feet.y)
        g.scaleBy(x: pixel, y: pixel)

        let frame = frame(for: pose, options: options)
        let spin = abs(pose.rotation) > 0.6 ? CGFloat(cos(pose.rotation)) : 1
        let squashX = CGFloat(pose.scaleX) * spin
        let squashY = CGFloat(pose.scaleY)

        if options.shadow, pose.shadow > 0.05 {
            let fade = Double(1 - min(1, frame.lift / 22))
            g.fill(.ellipse(CGPoint(x: 0, y: 0.35), 21 * abs(squashX) + 1, 2.6), Color.black.opacity(0.16 * pose.shadow * fade))
        }

        var sprite = g
        sprite.translateBy(x: 0, y: -frame.lift)
        sprite.scaleBy(x: squashX, y: squashY)
        let flipped = squashX < 0

        // Body, arms and legs share one fill so their edges never seam.
        var shape = Path()
        for row in 0..<Int(bodyRows) {
            let y = frame.top + CGFloat(row)
            shape.addRect(CGRect(x: -halfWidth + frame.shift(y + 0.5), y: y, width: 2 * halfWidth, height: 1))
        }
        let arms = armRects(pose, options: options, time: time)
        for rect in arms.left + arms.right { shape.addRect(placed(rect, frame)) }
        for rect in legRects(frame, speed: options.speed, time: time, reduced: options.reduced) { shape.addRect(rect) }
        let hoodie = options.accessory == .hoodie
        sprite.fill(shape, body)

        if hoodie { drawHoodie(sprite, frame: frame, arms: arms.left + arms.right) }
        if options.accessory == .scarf { drawScarf(sprite, frame: frame) }
        drawFace(pose, sprite, frame: frame, options: options, flipped: flipped)
        drawHeadwear(pose, accessory: options.accessory, sprite, frame: frame)

        if options.showsSpark, let index = sparkFrame(pose, time: time, reduced: options.reduced) {
            var spark = g
            spark.translateBy(x: 0, y: -frame.lift)
            let hatLift: CGFloat = wearsHat(pose, accessory: options.accessory) ? 5 : 0
            var center = CGPoint(x: 7 + CGFloat(pose.antennaBend) * 4, y: frame.top - 5.5 - hatLift)
            if let headroom = options.headroom, 8 + hatLift > headroom {
                center = CGPoint(x: halfWidth + 5, y: frame.top + 1.5)
            }
            drawSpark(index, glow: pose.antennaGlow, tint: pose.antennaTint, at: center, in: spark)
        }

        if let held = pose.held {
            let left = held.heldInLeftHand
            let hand = left ? arms.leftHand : arms.rightHand
            var point = placed(CGRect(origin: hand, size: .zero), frame).origin
            point.x *= squashX
            point.y = point.y * squashY - frame.lift
            point.x += left ? -1 : 0.5
            point.y -= left ? 3.6 : 2.8
            var item = context
            item.opacity = pose.opacity
            item.translateBy(x: feet.x, y: feet.y)
            ItemRenderer.draw(held, in: item, at: CGPoint(x: point.x * pixel, y: point.y * pixel), size: (left ? 7.2 : 6.4) * pixel)
        }
    }

    /// The top of the head above the feet, in art pixels (for placing marks over it).
    static func headTop(_ pose: CompanionPose, options: Options = Options()) -> CGFloat {
        let frame = frame(for: pose, options: options)
        return -(frame.top - frame.lift)
    }

    private static func frame(for pose: CompanionPose, options: Options) -> Frame {
        let hover = CGFloat(pose.y) * pixelsPerUnit
        var bob = min(1, max(-1, hover))
        var lift = max(0, hover - 1)
        if let snap = options.snap, snap > 0 {
            bob = (bob / snap).rounded() * snap
            lift = (lift / snap).rounded() * snap
        }
        // Asleep or powered down it settles low, legs tucked under.
        let squat: CGFloat = (pose.eyes == .sleepy || pose.eyes == .off) ? 2 : 0
        let lean = abs(pose.rotation) <= 0.6 ? CGFloat(pose.rotation) * 15 : 0
        return Frame(lift: lift, rise: bob - squat, leanTop: options.reduced ? 0 : lean)
    }

    private static func placed(_ rect: CGRect, _ frame: Frame, shiftAt row: CGFloat? = nil) -> CGRect {
        let y = frame.top + rect.minY
        let shift = frame.shift(row.map { frame.top + $0 } ?? y + rect.height / 2)
        return CGRect(x: rect.minX + shift, y: y, width: rect.width, height: rect.height)
    }

    // MARK: Limbs

    /// Arm rectangles relative to the body top, and the hands' positions.
    private static func armRects(_ pose: CompanionPose, options: Options, time: TimeInterval)
        -> (left: [CGRect], right: [CGRect], leftHand: CGPoint, rightHand: CGPoint) {
        let reach = pose.reach >= 0.75
        func arm(side: CGFloat, raise: Double, tapValue: Double) -> ([CGRect], CGPoint) {
            var rects: [CGRect]
            var hand: CGPoint
            if raise >= 0.72 {
                let wave: CGFloat = raise >= 0.9 ? 1 : 0
                rects = [CGRect(x: 9, y: -1, width: 2, height: 3), CGRect(x: 9 + wave, y: -4, width: 2, height: 3)]
                hand = CGPoint(x: 10 + wave, y: -4)
            } else if raise >= 0.45 {
                rects = [CGRect(x: 9, y: 3, width: 3, height: 3), CGRect(x: 11, y: 1, width: 2, height: 2)]
                hand = CGPoint(x: 12, y: 1)
            } else if raise >= 0.2 {
                rects = [CGRect(x: 9, y: 4, width: 3, height: 4)]
                hand = CGPoint(x: 12, y: 5)
            } else if reach {
                let tap: CGFloat = tapValue - 0.1 > 0.05 ? 1 : 0
                let extra: CGFloat = options.laptopOnLeft && side < 0 ? 2 : 0
                rects = [CGRect(x: 9, y: 7 - tap, width: 2 + extra, height: 3)]
                hand = CGPoint(x: 11 + extra, y: 8.5 - tap)
            } else {
                rects = [CGRect(x: 9, y: 6, width: 3, height: 4)]
                hand = CGPoint(x: 12, y: 8)
            }
            if side < 0 {
                rects = rects.map { CGRect(x: -$0.maxX, y: $0.minY, width: $0.width, height: $0.height) }
                hand.x = -hand.x
            }
            return (rects, hand)
        }
        let left = arm(side: -1, raise: pose.leftArm, tapValue: pose.leftArm)
        let right = arm(side: 1, raise: pose.rightArm, tapValue: pose.rightArm)
        return (left.0, right.0, left.1, right.1)
    }

    /// Four legs; while moving, diagonal pairs take turns lifting.
    private static func legRects(_ frame: Frame, speed: CGFloat, time: TimeInterval, reduced: Bool) -> [CGRect] {
        let height = legRows + frame.rise
        guard height > 0.4 else { return [] }
        var lifted = -1
        var tapping = -1
        if !reduced, abs(speed) > 2 {
            lifted = Int(floor(time * 9)) % 2
        } else if !reduced {
            // Idle: every so often one foot taps twice.
            let cycle = Ease.fract(time / 6.7) * 6.7
            if cycle < 0.5, Int(floor(cycle / 0.125)) % 2 == 0 { tapping = 3 }
        }
        return [-8.0, -5.0, 3.0, 6.0].enumerated().map { index, x in
            let up: CGFloat = (index % 2 == lifted || index == tapping) ? 1 : 0
            return CGRect(x: CGFloat(x), y: frame.bottom - 0.25, width: 2, height: height + 0.25 - up)
        }
    }

    // MARK: Face

    private static func drawFace(_ pose: CompanionPose, _ g: GraphicsContext, frame: Frame, options: Options, flipped: Bool) {
        var lookX = Int((Ease.clamp(pose.lookX, -1, 1) * 1.5).rounded())
        let lookY = Int((Ease.clamp(pose.lookY, -1, 1) * 1.5).rounded())
        if options.laptopOnLeft, pose.reach >= 0.75, pose.leftArm < 0.45, pose.rightArm < 0.45 { lookX = -1 }
        if flipped { lookX = -lookX }
        for side in [-1, 1] {
            var kind = pose.eyes
            if kind == .wink { kind = side < 0 ? .normal : .happy }
            let inner = side < 0 ? 1 : -1
            let column = CGFloat(side < 0 ? -6 : 5) + CGFloat(lookX)
            let color: Color
            switch kind {
            case .star: color = Color(hex: 0xFFD166)
            case .heart: color = Color(hex: 0xFF6F91)
            case .off: color = Color(hex: 0x7B6A66)
            default: color = ink
            }
            // Each eye leans as one piece, so a lean never breaks it into a slash.
            var eye = Path()
            for (dx, dy) in eyeCells(kind, openness: pose.eyeOpenness, inner: inner) {
                let rect = CGRect(x: column + CGFloat(dx), y: 3 + CGFloat(lookY + dy), width: 1, height: 1)
                eye.addRect(placed(rect, frame, shiftAt: 4.5 + CGFloat(lookY)))
            }
            g.fill(eye, color)
        }
        if let cells = mouthCells(pose.mouth) {
            var mouth = Path()
            for (dx, dy) in cells {
                mouth.addRect(placed(CGRect(x: CGFloat(dx + lookX / 2), y: 8 + CGFloat(dy), width: 1, height: 1), frame, shiftAt: 9))
            }
            g.fill(mouth, ink)
        }
    }

    /// Eye pixels relative to the eye's top cell; `inner` points towards the middle of the face.
    static func eyeCells(_ kind: VisorEyes, openness: Double, inner: Int) -> [(Int, Int)] {
        let closedLine = [(0, 2), (inner, 2)]
        switch kind {
        case .normal, .wink:
            if openness > 0.62 { return [(0, 0), (0, 1), (0, 2)] }
            return openness > 0.28 ? [(0, 1), (0, 2)] : closedLine
        case .happy: return [(-1, 1), (0, 0), (1, 1)]
        case .focused: return [(0, 1), (inner, 1)]
        case .worried: return openness < 0.3 ? closedLine : [(inner, 0), (0, 1), (0, 2)]
        case .sleepy: return closedLine
        case .wide:
            if openness < 0.3 { return closedLine }
            return [(0, -1), (0, 0), (0, 1), (0, 2), (inner, -1), (inner, 0), (inner, 1), (inner, 2)]
        case .closed: return [(-1, 1), (0, 2), (1, 1)]
        case .star: return [(0, 0), (-1, 1), (0, 1), (1, 1), (0, 2)]
        case .heart: return [(-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1), (0, 2)]
        case .off: return [(0, 1)]
        }
    }

    /// The mascot has no mouth; big feelings borrow one for a moment.
    static func mouthCells(_ mouth: VisorMouth) -> [(Int, Int)]? {
        switch mouth {
        case .grin: return [(-2, 0), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1)]
        case .o: return [(-1, 0), (0, 0), (-1, 1), (0, 1)]
        case .wavy: return [(-3, 1), (-2, 0), (-1, 1), (0, 0), (1, 1), (2, 0)]
        case .none, .smile, .flat: return nil
        }
    }

    // MARK: The working spark

    /// Claude Code's spinner glyphs (· ✢ ✳ ✶ ✻ ✽) as 5×5 pixel frames.
    static let sparkFrames: [[(Int, Int)]] = {
        let dot = [(2, 2)]
        let small = [(2, 1), (1, 2), (2, 2), (3, 2), (2, 3)]
        let plus = [(2, 0), (2, 1), (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (2, 3), (2, 4)]
        let star = plus + [(1, 1), (3, 1), (1, 3), (3, 3)]
        let cross = [(0, 0), (4, 0), (1, 1), (3, 1), (2, 2), (1, 3), (3, 3), (0, 4), (4, 4)] + small
        let full = star + [(0, 0), (4, 0), (0, 4), (4, 4)]
        return [dot, small, plus, star, cross, full]
    }()

    /// Which spinner frame shows now: it spins while Claude works and holds steady while it waits.
    static func sparkFrame(_ pose: CompanionPose, time: TimeInterval, reduced: Bool) -> Int? {
        switch pose.antennaTint {
        case .working:
            guard pose.antennaGlow > 0.3 else { return nil }
            if reduced { return 3 }
            let step = Int(floor(time / 0.1)) % 10
            return step < 6 ? step : 10 - step
        case .attention, .alert:
            return 4
        case .calm, .off:
            return nil
        }
    }

    /// Claude orange while working, like the CLI's spinner; amber or red when it needs you.
    static func sparkColor(_ tint: AntennaTint) -> Color {
        tint == .working ? Color(hex: 0xE2805A) : CompanionPalette.antenna(tint)
    }

    static func drawSpark(_ index: Int, glow: Double, tint: AntennaTint, at center: CGPoint, in g: GraphicsContext) {
        let color = sparkColor(tint)
        let strength = Ease.clamp(glow)
        g.fill(.ellipse(center, 11, 11), with: .radialGradient(Gradient(colors: [color.opacity(0.32 * strength), color.opacity(0)]),
                                                               center: center, startRadius: 0.5, endRadius: 5.5))
        var cells = Path()
        for (x, y) in sparkFrames[min(max(index, 0), sparkFrames.count - 1)] {
            cells.addRect(CGRect(x: center.x - 2.5 + CGFloat(x), y: center.y - 2.5 + CGFloat(y), width: 1, height: 1))
        }
        g.fill(cells, color.opacity(0.45 + 0.55 * strength))
    }

    // MARK: Wearables

    private static func wearsHat(_ pose: CompanionPose, accessory: Accessory?) -> Bool {
        if pose.hat != nil { return true }
        switch accessory {
        case .partyHat?, .beanie?, .graduationCap?, .detectiveHat?, .santaHat?, .witchHat?, .flowerCrown?: return true
        default: return false
        }
    }

    private static func fill(_ g: GraphicsContext, _ frame: Frame, _ color: Color, _ rects: [(CGFloat, CGFloat, CGFloat, CGFloat)]) {
        var path = Path()
        for (x, y, w, h) in rects { path.addRect(placed(CGRect(x: x, y: y, width: w, height: h), frame)) }
        g.fill(path, color)
    }

    private static func drawHeadwear(_ pose: CompanionPose, accessory: Accessory?, _ g: GraphicsContext, frame: Frame) {
        var worn = accessory
        switch pose.hat {
        case .detectiveHat?: worn = .detectiveHat
        case .gradCap?: worn = .graduationCap
        default: break
        }
        switch worn {
        case .partyHat?:
            fill(g, frame, Color(hex: 0xFF8FA3), [(-1, -1, 6, 1), (0, -3, 4, 1), (1, -5, 2, 1)])
            fill(g, frame, Color(hex: 0x7FD6C2), [(0, -2, 4, 1), (1, -4, 2, 1)])
            fill(g, frame, Color(hex: 0xFFD166), [(1, -7, 2, 2)])
        case .beanie?:
            fill(g, frame, Color(hex: 0x3F7F9A), [(-9, -1, 18, 2)])
            fill(g, frame, Color(hex: 0x5BA3C0), [(-8, -2, 16, 1), (-6, -3, 12, 1), (-3, -4, 6, 1)])
            fill(g, frame, Color(hex: 0xF4EDE4), [(-1, -6, 2, 2)])
        case .graduationCap?:
            fill(g, frame, Color(hex: 0x2E2A3A), [(-6, -2, 12, 2), (-10, -3, 20, 1)])
            fill(g, frame, Color(hex: 0xFFD166), [(-1, -4, 2, 1), (9, -2, 1, 4)])
        case .detectiveHat?:
            fill(g, frame, Color(hex: 0x7A5A3E), [(-10, -1, 20, 1), (-8, -4, 16, 3)])
            fill(g, frame, Color(hex: 0x9C7A55), [(-6, -4, 2, 1), (-2, -4, 2, 1), (2, -4, 2, 1), (6, -4, 2, 1),
                                                   (-4, -3, 2, 1), (0, -3, 2, 1), (4, -3, 2, 1)])
        case .santaHat?:
            fill(g, frame, Color(hex: 0xE04B5A), [(-8, -2, 15, 1), (-6, -3, 12, 1), (-3, -4, 10, 1), (4, -5, 5, 1)])
            fill(g, frame, Color.white, [(-9, -1, 18, 2), (9, -6, 2, 2)])
        case .witchHat?:
            fill(g, frame, Color(hex: 0x40296A), [(-12, -1, 24, 1)])
            fill(g, frame, Color(hex: 0x5B3F8C), [(-5, -3, 10, 1), (-4, -4, 8, 1), (-3, -5, 6, 1), (-2, -6, 5, 1),
                                                   (0, -7, 3, 1), (2, -8, 2, 1), (3, -9, 2, 1)])
            fill(g, frame, Color(hex: 0xFF9C3F), [(-5, -2, 10, 1)])
            fill(g, frame, Color(hex: 0xFFD166), [(-1, -2, 2, 1)])
        case .flowerCrown?:
            fill(g, frame, Color(hex: 0x6FB794), [(-9, -1, 18, 1)])
            let colors = [Color(hex: 0xFF8FB1), Color(hex: 0xFFD166), Color(hex: 0xB9A7FF), Color(hex: 0xFF9F80), Color(hex: 0x7FD6C2)]
            for (index, x) in [-9.0, -5.0, -1.0, 3.0, 7.0].enumerated() {
                fill(g, frame, colors[index], [(CGFloat(x), -3, 2, 2)])
            }
        case .roundGlasses?:
            let frameColor = Color(hex: 0x3A3340)
            fill(g, frame, Color.white.opacity(0.18), [(-7, 3, 3, 4), (4, 3, 3, 4)])
            fill(g, frame, frameColor, [(-8, 2, 5, 1), (-8, 7, 5, 1), (-8, 3, 1, 4), (-4, 3, 1, 4),
                                        (3, 2, 5, 1), (3, 7, 5, 1), (3, 3, 1, 4), (7, 3, 1, 4), (-3, 3, 6, 1)])
        case .headphones?:
            let dark = Color(hex: 0x3A3340)
            fill(g, frame, dark, [(-10, -2, 20, 1), (-10, -1, 1, 3), (9, -1, 1, 3)])
            fill(g, frame, Color(hex: 0xFF8FA3), [(-11, 2, 3, 4), (8, 2, 3, 4)])
        default:
            break
        }
    }

    private static func drawHoodie(_ g: GraphicsContext, frame: Frame, arms: [CGRect]) {
        let blue = Color(hex: 0x7C8CF2)
        var cloth = Path()
        for row in 6..<Int(bodyRows) {
            let y = frame.top + CGFloat(row)
            cloth.addRect(CGRect(x: -halfWidth + frame.shift(y + 0.5), y: y, width: 2 * halfWidth, height: 1))
        }
        for rect in arms where rect.minY >= 5 { cloth.addRect(placed(rect, frame)) }
        g.fill(cloth, blue)
        fill(g, frame, Color(hex: 0x5E6BD0), [(-9, 6, 18, 1), (-4, 9, 8, 1), (-4, 10, 1, 1), (3, 10, 1, 1)])
    }

    private static func drawScarf(_ g: GraphicsContext, frame: Frame) {
        fill(g, frame, Color(hex: 0xE04B5A), [(-9, 6, 18, 2), (3, 8, 2, 3)])
        fill(g, frame, Color.white.opacity(0.85), [(-6, 6, 1, 2), (-2, 6, 1, 2), (2, 6, 1, 2), (6, 6, 1, 2), (3, 11, 2, 1)])
    }
}

extension HeldItem {
    /// Cards, boards and hand signs go in the left hand (towards the pet); the rest in the right.
    var heldInLeftHand: Bool {
        switch self {
        case .document, .taskCard, .codeCard, .errorBoard, .rock, .paper, .scissors: return true
        default: return false
        }
    }
}
