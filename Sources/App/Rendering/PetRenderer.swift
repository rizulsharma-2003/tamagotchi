import SwiftUI
import TamagotchiCore

/// How much detail to draw. `.tiny` is for menu-bar scale (about 12–16 pt tall):
/// the pose is fitted to the bar (`PetTinyFit`), outlines are thicker, eyes bigger with
/// one bright highlight, the blush stronger, ear and head movements amplified and the
/// tail longer and carried higher, so blinks, ear flicks, glances and tail swishes read.
enum RenderDetail {
    case standard
    case tiny
}

/// Draws Mochi: a soft, round, bean-shaped creature with short ears, a curly tail
/// and big expressive eyes. Local units: origin at the feet, body 60×54, y up is negative.
enum PetRenderer {
    static let bodyWidth: CGFloat = 60
    static let bodyHeight: CGFloat = 54
    /// Mochi's life stage, set from the friendship by GrowthController; written on the main thread only.
    nonisolated(unsafe) static var stage = LifeStage.grownUp

    /// Size, eye and ear proportions per life stage: kittens are small with big eyes.
    static func proportions(_ stage: LifeStage) -> (size: CGFloat, eyes: CGFloat, ears: CGFloat) {
        switch stage {
        case .kitten: return (0.8, 1.2, 0.86)
        case .young: return (0.9, 1.08, 0.94)
        case .grownUp: return (1, 1, 1)
        }
    }

    /// Line weights and sizes for a detail level.
    struct Style {
        var tiny: Bool
        var outline: CGFloat
        var part: CGFloat
        var ink: CGFloat
        var eyeBoost: CGFloat
        var outlineColor: Color
        var ears: CGFloat = 1
        var stage = LifeStage.grownUp

        init(_ detail: RenderDetail, palette: PetPalette, dark: Bool) {
            tiny = detail == .tiny
            outline = tiny ? 3.6 : 1.7
            part = tiny ? 3.0 : 1.4
            ink = tiny ? 3.0 : 1.7
            eyeBoost = tiny ? 1.24 : 1
            outlineColor = palette.outline
        }
    }

    static func draw(
        _ input: PetPose,
        in context: GraphicsContext,
        at origin: CGPoint,
        scale: CGFloat,
        palette: PetPalette,
        accessory: Accessory?,
        dark: Bool,
        detail: RenderDetail = .standard
    ) {
        guard input.opacity > 0.01 else { return }
        var style = Style(detail, palette: palette, dark: dark)
        let growth = proportions(stage)
        style.eyeBoost *= growth.eyes
        style.ears = growth.ears
        style.stage = stage
        let pose = style.tiny ? PetTinyFit.fit(input) : input
        var base = context
        base.opacity = pose.opacity
        base.translateBy(x: origin.x, y: origin.y)
        base.scaleBy(x: scale * growth.size, y: scale * growth.size)

        // Ground shadow (does not lift with the body; shrinks as Mochi rises). None in the
        // menu bar, where it would read as a smudge on the bar.
        if !style.tiny {
            let lift = CGFloat(max(0, pose.y))
            let shadowWidth = 50 * CGFloat(max(0.3, pose.shadow)) * CGFloat(pose.scaleX) * max(0.45, 1 - 0.45 * lift)
            base.fill(.ellipse(CGPoint(x: 0, y: 1.5), shadowWidth, 7 * max(0.6, 1 - 0.3 * lift)),
                      Color.black.opacity((dark ? 0.32 : 0.13) * Double(max(0.4, 1 - 0.5 * lift))))
        }

        let facing: CGFloat = pose.facing >= 0 ? 1 : -1
        var body = base
        body.translateBy(x: 0, y: -CGFloat(pose.y) * bodyHeight)
        body.translateBy(x: 0, y: -27)
        body.rotate(by: .radians(pose.rotation))
        body.translateBy(x: 0, y: 27)
        let lean = CGFloat(pose.lean) * facing
        if abs(lean) > 0.0001 {
            // Shear about the feet: the head leads, the feet stay planted.
            body.concatenate(CGAffineTransform(a: 1, b: 0, c: -lean, d: 1, tx: 0, ty: 0))
        }
        body.scaleBy(x: CGFloat(pose.scaleX), y: CGFloat(pose.scaleY))

        // The head tilt turns the face and the ears together.
        var face = body
        face.translateBy(x: 0, y: -27)
        face.rotate(by: .radians(pose.tilt))
        face.translateBy(x: 0, y: 27)

        drawTail(pose, body, palette, style)
        drawEars(pose, face, palette, style)
        drawFeet(pose, body, palette, style, front: false)
        drawBody(pose, body, palette, style)
        drawFeet(pose, body, palette, style, front: true)
        drawStageMark(face, body, palette, style)
        if accessory == .hoodie { AccessoryRenderer.petHoodie(body) }
        if accessory == .scarf { AccessoryRenderer.petScarf(body) }

        drawFace(pose, face, palette, style)

        if let accessory, accessory != .hoodie, accessory != .scarf, accessory.slot == .wearable {
            AccessoryRenderer.petWearable(accessory, face)
        }
        if let hat = pose.hat {
            AccessoryRenderer.petHatItem(hat, face)
        }

        drawArms(pose, body, palette, style)
        // Puffed cheeks bulge over the shoulders.
        drawCheeks(pose, face, palette, style)
        if let held = pose.held {
            let lift = CGFloat((pose.leftArm + pose.rightArm) / 2)
            switch held {
            case .rock, .paper, .scissors:
                // Shown in the front paw (the right one when facing right).
                let raised = CGFloat(facing > 0 ? pose.rightArm : pose.leftArm)
                ItemRenderer.draw(held, in: body, at: CGPoint(x: 31 * facing, y: -38 - 10 * raised), size: 15)
            default:
                ItemRenderer.draw(held, in: body, at: CGPoint(x: 4 * facing, y: -16 - 16 * lift), size: 15)
            }
        }

        // Yarn wrapped around the body moves with it.
        for effect in pose.effects where effect.kind == .tangle {
            EffectRenderer.tangle(effect, in: body, style: style)
        }

        // Effects live in un-squashed space around the lifted body (at menu-bar size the fit
        // has already picked a few bold ones and eased them under the bar top).
        var effects = base
        effects.translateBy(x: 0, y: -CGFloat(pose.y) * bodyHeight)
        for effect in pose.effects where effect.kind != .tangle {
            var e = effect
            // Legacy effects in Mochi's own frame.
            if e.followsFacing, facing < 0 {
                e.x = -e.x
                if e.kind == .streak { e.rotation = .pi - e.rotation }
            }
            EffectRenderer.draw(e, in: effects, unitX: bodyWidth, unitY: bodyHeight, dark: dark, detail: detail)
        }
    }

    /// Horizontal slide of the face (art units, screen space) for a head turn; at menu-bar
    /// size glances also nudge the face so they read as the head turning.
    static func faceShift(_ pose: PetPose, _ style: Style) -> CGFloat {
        let facing = pose.facing >= 0 ? 1.0 : -1.0
        let turn = Ease.clamp(pose.headTurn, -1, 1) * facing * PetPose.faceShift
        return CGFloat(style.tiny ? 1.25 * turn + 1.3 * Ease.clamp(pose.lookX, -1, 1) : turn)
    }

    // MARK: Parts

    static func bodyPath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -30, y: -7))
        path.addCurve(to: CGPoint(x: 0, y: -54), control1: CGPoint(x: -31.5, y: -37), control2: CGPoint(x: -18, y: -54))
        path.addCurve(to: CGPoint(x: 30, y: -7), control1: CGPoint(x: 18, y: -54), control2: CGPoint(x: 31.5, y: -37))
        path.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: 29.5, y: -1.2), control2: CGPoint(x: 17, y: 0))
        path.addCurve(to: CGPoint(x: -30, y: -7), control1: CGPoint(x: -17, y: 0), control2: CGPoint(x: -29.5, y: -1.2))
        path.closeSubpath()
        return path
    }

    static func drawBody(_ pose: PetPose, _ ctx: GraphicsContext, _ palette: PetPalette, _ style: Style) {
        let path = bodyPath()
        ctx.fill(path, with: .linearGradient(Gradient(colors: [palette.light, palette.body, palette.body]),
                                             startPoint: CGPoint(x: -8, y: -54), endPoint: CGPoint(x: 6, y: 0)))
        // Soft belly glow that rises and widens as Mochi breathes in.
        let breath = CGFloat(pose.breath)
        ctx.fill(.ellipse(CGPoint(x: 0, y: -15 - 1.3 * breath), 34 + 2.2 * breath, 20 + 1.6 * breath),
                 palette.light.opacity(style.tiny ? 0.35 : 0.45 + 0.05 * Double(breath)))
        if !style.tiny {
            var highlight = ctx
            highlight.translateBy(x: -13, y: -42)
            highlight.rotate(by: .degrees(-28))
            highlight.fill(.ellipse(.zero, 13, 6.5), Color.white.opacity(0.5))
            highlight.fill(.ellipse(CGPoint(x: 9, y: 3.5), 3, 2), Color.white.opacity(0.35))
        }
        ctx.stroke(path, style.outlineColor, style.outline)
    }

    /// A kitten's tuft of fur on top; a grown-up's little bell collar.
    static func drawStageMark(_ face: GraphicsContext, _ body: GraphicsContext, _ palette: PetPalette, _ style: Style) {
        switch style.stage {
        case .kitten:
            var tuft = Path()
            tuft.move(to: CGPoint(x: -3.5, y: -52.5))
            tuft.addQuadCurve(to: CGPoint(x: -1.5, y: -59), control: CGPoint(x: -4.5, y: -57))
            tuft.move(to: CGPoint(x: 0, y: -53.5))
            tuft.addQuadCurve(to: CGPoint(x: 1.6, y: -61), control: CGPoint(x: -1.2, y: -58.5))
            tuft.move(to: CGPoint(x: 3.2, y: -52.8))
            tuft.addQuadCurve(to: CGPoint(x: 5.2, y: -58), control: CGPoint(x: 2.8, y: -56.8))
            face.stroke(tuft, with: .color(style.outlineColor), style: StrokeStyle(lineWidth: style.tiny ? 2.6 : 1.5, lineCap: .round))
        case .young:
            break
        case .grownUp:
            guard !style.tiny else { return }
            var ribbon = Path()
            ribbon.move(to: CGPoint(x: -21, y: -14.5))
            ribbon.addQuadCurve(to: CGPoint(x: 21, y: -14.5), control: CGPoint(x: 0, y: -8.5))
            body.stroke(ribbon, with: .color(Color(hex: 0xE0566B)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            let bell = CGPoint(x: 0, y: -9.2)
            body.fill(.ellipse(bell, 6.4, 6.4), Color(hex: 0xF2C14E))
            body.stroke(.ellipse(bell, 6.4, 6.4), Color(hex: 0xC8932B), 0.9)
            body.fill(Path(CGRect(x: -1.6, y: bell.y + 0.6, width: 3.2, height: 0.9)), Color(hex: 0x8A6420))
            body.fill(.ellipse(CGPoint(x: bell.x - 1.1, y: bell.y - 1.2), 1.6, 1.2), Color.white.opacity(0.7))
        }
    }

    /// Per-ear extra rotation in screen space, mirrored with facing.
    static func earRotation(_ pose: PetPose, side: Double) -> Double {
        if pose.facing >= 0 { return side < 0 ? pose.earLeft : pose.earRight }
        return side < 0 ? -pose.earRight : -pose.earLeft
    }

    static func drawEars(_ pose: PetPose, _ ctx: GraphicsContext, _ palette: PetPalette, _ style: Style) {
        // A head turn slides the ears with the face and swivels them that way.
        let facing = pose.facing >= 0 ? 1.0 : -1.0
        let turn = Ease.clamp(pose.headTurn, -1, 1) * facing + (style.tiny ? 0.3 * Ease.clamp(pose.lookX, -1, 1) : 0)
        let listen = Ease.clamp(pose.earListen)
        for index in 0..<2 {
            let side = index == 0 ? -1.0 : 1.0
            let s = CGFloat(side)
            // Listening closely: the ear on the far side of the turn comes forward, the near one folds back.
            let offered = side == -facing ? listen : 0
            let folded = side == facing ? listen : 0
            let grow = CGFloat(offered)
            var ear = ctx
            ear.translateBy(x: s * (14.5 + 2.5 * grow) + CGFloat(turn) * 1.5, y: -47 - 1.5 * grow)
            let twitch = earRotation(pose, side: side)
            // Flicks are amplified at menu-bar size, where a 0.3 rad flick is under a pixel.
            let resting = Ease.lerp((0.3 - 0.36 * pose.earPerk) * side + 0.2 * turn, 0.2 * side, offered)
            let tilt = resting + twitch * (style.tiny ? 1.8 : 1) + 0.5 * folded * side
            ear.rotate(by: .radians(tilt))
            // Floppy tips bend outward when the ear swings out.
            let outward = Ease.clamp(tilt * side - 0.3, -0.6, 1.2)
            let bend = CGFloat(max(0, outward)) * 3.2 * s
            // A flicked ear folds a little at the tip, so the silhouette's notch changes too.
            let fold = (style.tiny ? 0.25 : 0.08) * Ease.clamp(abs(twitch) / 0.45)
            let height: CGFloat = 12 * style.ears * CGFloat(1 + 0.08 * Ease.clamp(pose.earPerk - 0.4, 0, 1) - 0.06 * Ease.clamp(-pose.earPerk - 0.8, 0, 1) - fold)
                * (1 + 0.32 * grow) * (1 - 0.2 * CGFloat(folded))
            // The offered ear also opens wider, so more of its inside shows.
            let half = 7 + 1.8 * grow
            var outer = Path()
            outer.move(to: CGPoint(x: -half, y: 3))
            outer.addQuadCurve(to: CGPoint(x: -1.2 + bend, y: -height + abs(bend) * 0.35), control: CGPoint(x: -half + 0.5 + bend * 0.4, y: -height * 0.66))
            outer.addQuadCurve(to: CGPoint(x: 1.2 + bend, y: -height + abs(bend) * 0.35), control: CGPoint(x: bend, y: -height - 1.5))
            outer.addQuadCurve(to: CGPoint(x: half, y: 3), control: CGPoint(x: half - 0.5 + bend * 0.4, y: -height * 0.66))
            outer.closeSubpath()
            ear.fill(outer, palette.body)
            ear.stroke(outer, style.outlineColor, style.tiny ? 2.8 : 1.6)
            var inner = Path()
            let innerHeight = height * (style.tiny ? 0.62 : 0.71 + 0.07 * grow)
            let innerHalf = 3.6 + 1.9 * grow
            inner.move(to: CGPoint(x: -innerHalf, y: 1))
            inner.addQuadCurve(to: CGPoint(x: bend * 0.6, y: -innerHeight), control: CGPoint(x: -innerHalf + 0.4 + bend * 0.3, y: -innerHeight * 0.7))
            inner.addQuadCurve(to: CGPoint(x: innerHalf, y: 1), control: CGPoint(x: innerHalf - 0.4 + bend * 0.3, y: -innerHeight * 0.7))
            inner.closeSubpath()
            ear.fill(inner, palette.innerEar.opacity(style.tiny ? 1 : 0.85 + 0.15 * Double(grow)))
        }
    }

    /// A short tail that sweeps outward and ends in a fluffy curl. `tailLift` raises it,
    /// `tailCurl` winds it tighter, `tailWag` swings it (positive = tip up and in).
    static func drawTail(_ pose: PetPose, _ ctx: GraphicsContext, _ palette: PetPalette, _ style: Style) {
        let side: CGFloat = pose.facing >= 0 ? -1 : 1
        var tail = ctx
        tail.translateBy(x: side * (style.tiny ? 26.5 : 25.5), y: -6)
        // In the menu bar the tail is longer, carried up and out with a softer curl, so it stands
        // clear of the body (it is drawn behind it) and its swishes show against the bar.
        let start: Double
        let curl: Double
        if style.tiny {
            let raw = 0.05 + 0.55 * Ease.clamp(pose.tailLift + 1.0, -1, 1.6) + 0.4 * Ease.clamp(pose.tailWag, -2.5, 2.5)
            start = Ease.clamp(raw, -0.3, 0.85)
            // Never curl back over the body (where the tail would vanish behind it).
            curl = min(0.9 + 0.7 * Ease.clamp(pose.tailCurl, -1.2, 1.2), (1.75 - start) / 1.1)
        } else {
            start = 0.05 + 0.55 * Ease.clamp(pose.tailLift, -1, 1) + 0.33 * Ease.clamp(pose.tailWag, -2.5, 2.5)
            curl = 2.0 + 1.15 * Ease.clamp(pose.tailCurl, -1.2, 1.2)
        }
        let length = style.tiny ? 28.0 : 21.0
        func point(_ a: Double, _ r: Double, from p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + side * CGFloat(cos(a) * r), y: p.y - CGFloat(sin(a) * r))
        }
        let p1 = point(start, length * 0.45, from: .zero)
        let p2 = point(start + curl * 0.55, length * 0.33, from: p1)
        let tip = point(start + curl * 1.1, length * 0.28, from: p2)
        var path = Path()
        path.move(to: .zero)
        path.addCurve(to: tip, control1: p1, control2: p2)
        tail.stroke(path, style.outlineColor, style.tiny ? 10.5 : 6.4)
        tail.stroke(path, palette.body, style.tiny ? 6.2 : 3.8)
        let tipSize: CGFloat = style.tiny ? 8.6 : 5.2
        let tipBall = Path.ellipse(tip, tipSize, tipSize)
        tail.fill(tipBall, palette.light)
        tail.stroke(tipBall, style.outlineColor, style.tiny ? 2.4 : 1.3)
    }

    static func drawFeet(_ pose: PetPose, _ ctx: GraphicsContext, _ palette: PetPalette, _ style: Style, front: Bool) {
        let facing: CGFloat = pose.facing >= 0 ? 1 : -1
        let kick = CGFloat(Ease.clamp(pose.kick, -1, 1))
        for index in 0..<2 {
            let side: CGFloat = index == 0 ? -1 : 1
            // The front foot is the one on the facing side; `kick` > 0 lifts it high.
            let isFront = side == facing
            let kicked = (kick > 0 && isFront) || (kick < 0 && !isFront)
            let kickAmount = kicked ? abs(kick) : 0
            // Raised feet are drawn in front of the body so they read.
            guard (kickAmount > 0.15) == front else { continue }
            // Gait: the swinging foot tucks up, the planted foot presses down and peeks out.
            let step = pose.step * Double(side)
            let lift = CGFloat(max(0, step)) * (style.tiny ? 3.6 : 2.6)
            let plant = CGFloat(max(0, -step)) * (style.tiny ? 1.8 : 2.2)
            let strideOffset = CGFloat(pose.stride) * 5.4 * (isFront ? 1 : -1) * facing
            let kickLift = 34 * pow(kickAmount, 1.5)
            let center = CGPoint(x: side * (12 + 9 * kickAmount) + strideOffset, y: -1.6 - lift + plant - kickLift)
            if kickAmount > 0.5 {
                let hip = CGPoint(x: side * 13, y: -8)
                ctx.fill(.capsule(from: hip, to: center, width: style.tiny ? 13.5 : 10.5), style.outlineColor)
                ctx.fill(.capsule(from: hip, to: center, width: style.tiny ? 8 : 7.6), palette.foot)
            }
            var foot = ctx
            foot.translateBy(x: center.x, y: center.y)
            if kickAmount > 0.15 {
                // A raised foot turns its sole towards us.
                foot.rotate(by: .radians(Double(side) * -0.5 * Double(min(1, kickAmount * 1.5))))
            }
            let shape = Path.ellipse(.zero, style.tiny ? 15 : 14, kickAmount > 0.15 ? 9 : (style.tiny ? 8.5 : 7.5))
            foot.fill(shape, palette.foot)
            foot.stroke(shape, style.outlineColor, style.part)
            if kickAmount > 0.15, !style.tiny {
                // Toe beans.
                foot.fill(.ellipse(CGPoint(x: 0, y: 1.2), 5.2, 3.4), palette.innerEar.opacity(0.95))
                for toe in 0..<3 {
                    foot.fill(.ellipse(CGPoint(x: CGFloat(toe - 1) * 3.4, y: -2.2), 2.2, 2.2), palette.innerEar.opacity(0.95))
                }
            }
        }
    }

    static func drawArms(_ pose: PetPose, _ ctx: GraphicsContext, _ palette: PetPalette, _ style: Style) {
        // The paw that goes to the mouth is the front one (screen right when facing right).
        let facingSign: CGFloat = pose.facing >= 0 ? 1 : -1
        let pawIndex = facingSign > 0 ? 1 : 0
        let shift = faceShift(pose, style)
        for index in 0..<2 {
            let side: CGFloat = index == 0 ? -1 : 1
            let value = index == 0 ? pose.leftArm : pose.rightArm
            let angle = Ease.lerp(0.32, 2.75, Ease.clamp(value))
            let shoulder = CGPoint(x: side * 24.5, y: -21)
            let direction = CGPoint(x: CGFloat(sin(angle)) * side, y: CGFloat(cos(angle)))
            let length: CGFloat = 7.5 + 2 * CGFloat(Ease.clamp(value))
            var hand = CGPoint(x: shoulder.x + direction.x * length, y: shoulder.y + direction.y * length)
            let toMouth = index == pawIndex ? CGFloat(Ease.clamp(pose.pawToMouth)) : 0
            if toMouth > 0 {
                let mouth = CGPoint(x: 7.5 * facingSign + shift, y: -19.5)
                hand = CGPoint(x: hand.x + (mouth.x - hand.x) * toMouth, y: hand.y + (mouth.y - hand.y) * toMouth)
            }
            let hold = CGFloat(Ease.clamp(pose.holdFront)) * (1 - toMouth)
            if hold > 0 {
                let chest = CGPoint(x: side * 6, y: -15.5)
                hand = CGPoint(x: hand.x + (chest.x - hand.x) * hold, y: hand.y + (chest.y - hand.y) * hold)
            }
            ctx.fill(.capsule(from: shoulder, to: hand, width: style.tiny ? 11.5 : 10.2), style.outlineColor)
            ctx.fill(.capsule(from: shoulder, to: hand, width: style.tiny ? 6.4 : 7.4), palette.body)
            if hold > 0.3 {
                let paw = Path.ellipse(hand, 8.6, 8)
                ctx.fill(paw, palette.body)
                ctx.stroke(paw, style.outlineColor, style.part)
            } else if toMouth > 0.3 {
                let paw = Path.ellipse(hand, 9.5, 8.5)
                ctx.fill(paw, palette.body)
                ctx.stroke(paw, style.outlineColor, style.part)
                if !style.tiny { ctx.fill(.ellipse(CGPoint(x: hand.x, y: hand.y + 0.8), 4.2, 2.8), palette.innerEar.opacity(0.85)) }
            } else if !style.tiny, value > 0.25 {
                // A soft paw tip so raised arms read as paws.
                ctx.fill(.ellipse(CGPoint(x: hand.x - direction.x * 0.6, y: hand.y - direction.y * 0.6), 4.2, 4.2), palette.light.opacity(0.7))
            }
        }
    }

    /// Puffed cheeks: round bulges at the sides of the mouth that stick out past the
    /// face outline, with their own blush.
    static func drawCheeks(_ pose: PetPose, _ ctx: GraphicsContext, _ palette: PetPalette, _ style: Style) {
        let shift = faceShift(pose, style) * 0.8
        for index in 0..<2 {
            let amount = CGFloat(index == 0 ? pose.cheekLeft : pose.cheekRight)
            guard amount > 0.04 else { continue }
            let side: CGFloat = index == 0 ? -1 : 1
            // Past 0.7 the cheeks balloon into comic hamster cheeks.
            let hamster = CGFloat(Ease.clamp((Double(amount) - 0.7) / 0.3))
            let radius = 3.5 + 6 * amount + 4.5 * hamster
            let center = CGPoint(x: side * (16.5 + 6.5 * amount + 2.8 * hamster) + shift, y: -19.5 + 0.5 * amount - 0.8 * hamster)
            let cheek = Path.ellipse(center, radius * 2, radius * 1.85)
            ctx.fill(cheek, with: .linearGradient(Gradient(colors: [palette.light, palette.body]),
                                                  startPoint: CGPoint(x: center.x, y: center.y - radius), endPoint: CGPoint(x: center.x, y: center.y + radius)))
            // Outline only on the outer side, so the bulge melts into the face.
            var rim = Path()
            rim.addArc(center: center, radius: radius, startAngle: .degrees(side > 0 ? -80 : 100), endAngle: .degrees(side > 0 ? 95 : 275), clockwise: false)
            ctx.stroke(rim.applying(CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(scaleX: 1, y: 0.925))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))),
                       style.outlineColor.opacity(Double(min(1, amount * 2.5))), style.part)
            ctx.fill(.ellipse(CGPoint(x: center.x - side * radius * 0.15, y: center.y + radius * 0.15), radius * 1.15, radius * 0.7),
                     palette.blush.opacity(Double(min(0.9, 0.35 + 0.6 * pose.blush))))
            if !style.tiny {
                ctx.fill(.ellipse(CGPoint(x: center.x + side * radius * 0.2, y: center.y - radius * 0.45), radius * 0.55, radius * 0.35),
                         Color.white.opacity(0.55))
            }
        }
    }

    static func drawFace(_ pose: PetPose, _ ctx: GraphicsContext, _ palette: PetPalette, _ style: Style) {
        // Glances travel further at menu-bar size so they still read; a head turn slides the face.
        let lookX = CGFloat(Ease.clamp(pose.lookX, -1, 1)) * (style.tiny ? 4.6 : 3.2)
        let lookY = CGFloat(Ease.clamp(pose.lookY, -1, 1)) * (style.tiny ? 3.0 : 2.4)
        let shift = faceShift(pose, style)
        let blush = CGFloat(Ease.clamp(pose.blush))
        if blush > 0.02 {
            let boost: CGFloat = style.tiny ? 1.25 : 1
            for index in 0..<2 {
                let side: CGFloat = index == 0 ? -1 : 1
                let puff = CGFloat(index == 0 ? pose.cheekLeft : pose.cheekRight)
                let center = CGPoint(x: side * (18 + 3 * puff) + lookX * 0.4 + shift * 0.8, y: -20.5 + puff)
                ctx.fill(.ellipse(center, 8.5 * boost, 4.6 * boost), palette.blush.opacity(Double(min(1, 0.75 * blush * boost))))
                if blush > 0.92, !style.tiny {
                    // Anime blush hatching for big moments.
                    for line in 0..<3 {
                        var hatch = Path()
                        let x = center.x - 2.6 + CGFloat(line) * 2.6
                        hatch.move(to: CGPoint(x: x + 1, y: center.y - 1.4))
                        hatch.addLine(to: CGPoint(x: x - 0.6, y: center.y + 1.4))
                        ctx.stroke(hatch, palette.blush.opacity(0.95), 0.9)
                    }
                }
            }
        }
        let cross = CGFloat(Ease.clamp(pose.crossEyed))
        for index in 0..<2 {
            let side: CGFloat = index == 0 ? -1 : 1
            let center = CGPoint(x: side * 10.5 + lookX * (1 - cross) - side * 2.6 * cross + shift,
                                 y: -29.5 + lookY * (1 - cross) + 1.6 * cross)
            var kind = pose.eyes
            if kind == .wink { kind = index == 0 ? .open : .happy }
            drawEye(kind, side: side, at: center, pose: pose, in: ctx, palette: palette, style: style)
            drawBrow(pose.brows, side: Double(side), eye: center, in: ctx, palette: palette, style: style)
        }
        drawMouth(pose.mouth, at: CGPoint(x: lookX * 0.5 * (1 - cross) + shift * 0.95, y: -20 + lookY * 0.4), in: ctx, palette: palette, style: style)
    }

    static func drawEye(_ kind: PetEyes, side: CGFloat, at center: CGPoint, pose: PetPose, in ctx: GraphicsContext, palette: PetPalette, style: Style) {
        let eye = palette.eye
        let openness = pose.eyeOpenness
        let size = CGFloat(Ease.clamp(pose.eyeScale, 0.6, 1.5)) * style.eyeBoost
        let line = style.tiny ? 2.8 : 2.2
        switch kind {
        case .open, .wink, .worried, .wide:
            let wide = kind == .wide
            let width: CGFloat = (wide ? 9 : (kind == .worried ? 7.2 : 7.8)) * size
            let height: CGFloat = (wide ? 12 : (kind == .worried ? 9.6 : 10.6)) * size * CGFloat(max(0.06, openness))
            if openness < 0.22 {
                var lid = Path()
                lid.move(to: CGPoint(x: center.x - 3.8 * size, y: center.y + 0.5))
                lid.addQuadCurve(to: CGPoint(x: center.x + 3.8 * size, y: center.y + 0.5), control: CGPoint(x: center.x, y: center.y + 1.8))
                ctx.stroke(lid, eye, line)
                return
            }
            ctx.fill(.ellipse(center, width, height), eye)
            let sparkle = CGFloat(Ease.clamp(pose.eyeSparkle))
            if style.tiny {
                let r = (wide ? 3.6 : 3.2) * size
                ctx.fill(.ellipse(CGPoint(x: center.x - 1.4 * size, y: center.y - height * 0.2), r, r), palette.eyeHighlight)
                return
            }
            let highlight = (wide ? 2.4 : 2.0) * size
            if sparkle > 0.05 {
                ctx.fill(.sparkle(CGPoint(x: center.x - 1.4 * size, y: center.y - height * 0.2), radius: (2.2 + 2.2 * sparkle) * size),
                         palette.eyeHighlight)
                ctx.fill(.sparkle(CGPoint(x: center.x + 1.8 * size, y: center.y + height * 0.22), radius: (1.2 + 0.9 * sparkle) * size),
                         palette.eyeHighlight.opacity(0.85))
                ctx.fill(.ellipse(CGPoint(x: center.x + 1.9 * size, y: center.y - height * 0.3), 1.2 * size, 1.2 * size),
                         palette.eyeHighlight.opacity(0.8 * Double(sparkle)))
            } else {
                ctx.fill(.ellipse(CGPoint(x: center.x - 1.5 * size, y: center.y - height * 0.24), highlight * 2, highlight * 2),
                         palette.eyeHighlight.opacity(0.95))
                ctx.fill(.ellipse(CGPoint(x: center.x + 1.6 * size, y: center.y + height * 0.22), 1.8 * size, 1.8 * size),
                         palette.eyeHighlight.opacity(0.75))
            }
        case .closed:
            var arc = Path()
            arc.move(to: CGPoint(x: center.x - 4.2 * size, y: center.y))
            arc.addQuadCurve(to: CGPoint(x: center.x + 4.2 * size, y: center.y), control: CGPoint(x: center.x, y: center.y + 3.6 * size))
            ctx.stroke(arc, eye, line)
        case .happy:
            var arc = Path()
            arc.move(to: CGPoint(x: center.x - 4.2 * size, y: center.y + 1.8))
            arc.addQuadCurve(to: CGPoint(x: center.x + 4.2 * size, y: center.y + 1.8), control: CGPoint(x: center.x, y: center.y - 4.6 * size))
            ctx.stroke(arc, eye, style.tiny ? 3 : 2.4)
        case .squint:
            // > <
            var mark = Path()
            let inward = -side
            mark.move(to: CGPoint(x: center.x - inward * 3.6 * size, y: center.y - 3.4 * size))
            mark.addLine(to: CGPoint(x: center.x + inward * 3.2 * size, y: center.y))
            mark.addLine(to: CGPoint(x: center.x - inward * 3.6 * size, y: center.y + 3.4 * size))
            ctx.stroke(mark, eye, style.tiny ? 2.8 : 2.2)
        case .sleepy:
            // Heavy, drowsy lids that droop towards the outer corners (an inward droop
            // would read as a glare), over the lower part of the eye.
            let outer = CGPoint(x: center.x + side * 4.4 * size, y: center.y + 1.5 * size)
            let inner = CGPoint(x: center.x - side * 4.2 * size, y: center.y - 0.2 * size)
            var lid = Path()
            lid.move(to: outer)
            lid.addQuadCurve(to: inner, control: CGPoint(x: center.x + side * 0.6 * size, y: center.y - 0.6 * size))
            var lower = ctx
            var below = lid
            below.addLine(to: CGPoint(x: inner.x, y: center.y + 8 * size))
            below.addLine(to: CGPoint(x: outer.x, y: center.y + 8 * size))
            below.closeSubpath()
            lower.clip(to: below)
            lower.fill(.ellipse(CGPoint(x: center.x, y: center.y + 1.2), 7.0 * size, 8.4 * size), eye)
            if !style.tiny {
                lower.fill(.ellipse(CGPoint(x: center.x - 1.2 * size, y: center.y + 2.4 * size), 1.8 * size, 1.4 * size), palette.eyeHighlight.opacity(0.8))
            }
            ctx.stroke(lid, eye, style.tiny ? 2.6 : 1.9)
        case .dizzy:
            var spiral = Path()
            spiral.addArc(center: center, radius: 4, startAngle: .degrees(0), endAngle: .degrees(300), clockwise: false)
            spiral.addArc(center: CGPoint(x: center.x + 0.6, y: center.y), radius: 2, startAngle: .degrees(300), endAngle: .degrees(20), clockwise: false)
            ctx.stroke(spiral, eye, style.tiny ? 2.4 : 1.6)
        case .heart:
            ctx.fill(.heart(center, size: 10 * size), Color(hex: 0xFF5A7A))
        }
    }

    static func drawBrow(_ brows: Brows, side: Double, eye: CGPoint, in ctx: GraphicsContext, palette: PetPalette, style: Style) {
        guard brows != .none else { return }
        let s = CGFloat(side)
        var path = Path()
        switch brows {
        case .none:
            return
        case .worried:
            path.move(to: CGPoint(x: eye.x + s * 4.5, y: eye.y - 7.2))
            path.addLine(to: CGPoint(x: eye.x - s * 3.5, y: eye.y - 9.8))
        case .raised:
            path.move(to: CGPoint(x: eye.x - 3.8, y: eye.y - 8.6))
            path.addQuadCurve(to: CGPoint(x: eye.x + 3.8, y: eye.y - 8.6), control: CGPoint(x: eye.x, y: eye.y - 11.4))
        case .confused:
            if side < 0 {
                path.move(to: CGPoint(x: eye.x - 3.8, y: eye.y - 9.4))
                path.addQuadCurve(to: CGPoint(x: eye.x + 3.8, y: eye.y - 9.4), control: CGPoint(x: eye.x, y: eye.y - 12.4))
            } else {
                path.move(to: CGPoint(x: eye.x - 3.6, y: eye.y - 7.6))
                path.addLine(to: CGPoint(x: eye.x + 3.6, y: eye.y - 7.0))
            }
        }
        ctx.stroke(path, palette.eye.opacity(0.85), style.tiny ? 2.4 : 1.6)
    }

    static func catMouth(_ c: CGPoint, width: CGFloat = 4.2) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: c.x - width, y: c.y - 0.8))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - 0.2), control: CGPoint(x: c.x - width * 0.52, y: c.y + 2.6))
        path.addQuadCurve(to: CGPoint(x: c.x + width, y: c.y - 0.8), control: CGPoint(x: c.x + width * 0.52, y: c.y + 2.6))
        return path
    }

    static func drawMouth(_ mouth: PetMouth, at c: CGPoint, in ctx: GraphicsContext, palette: PetPalette, style: Style) {
        let ink = palette.eye
        let mouthColor = Color(hex: 0x7A2E3B)
        let tongue = Color(hex: 0xFF8C9B)
        let line = style.ink
        switch mouth {
        case .cat, .nom:
            ctx.stroke(catMouth(c), ink, mouth == .nom ? line + 0.5 : line)
            if mouth == .nom, !style.tiny {
                ctx.fill(.ellipse(CGPoint(x: c.x - 9, y: c.y - 1), 5, 4), palette.light.opacity(0.9))
                ctx.fill(.ellipse(CGPoint(x: c.x + 9, y: c.y - 1), 5, 4), palette.light.opacity(0.9))
            }
        case .smile:
            var path = Path()
            path.move(to: CGPoint(x: c.x - 4.2, y: c.y - 1))
            path.addQuadCurve(to: CGPoint(x: c.x + 4.2, y: c.y - 1), control: CGPoint(x: c.x, y: c.y + 3.8))
            ctx.stroke(path, ink, line + 0.1)
        case .open, .pant:
            var path = Path()
            path.move(to: CGPoint(x: c.x - 4.8, y: c.y - 1.6))
            path.addQuadCurve(to: CGPoint(x: c.x + 4.8, y: c.y - 1.6), control: CGPoint(x: c.x, y: c.y - 2.4))
            path.addQuadCurve(to: CGPoint(x: c.x - 4.8, y: c.y - 1.6), control: CGPoint(x: c.x, y: c.y + 8.6))
            ctx.fill(path, mouthColor)
            if mouth == .pant {
                let lick = Path.roundedRect(CGRect(x: c.x - 2.2, y: c.y + 0.6, width: 4.8, height: 6.4), 2.4)
                ctx.fill(lick, tongue)
                ctx.stroke(lick, mouthColor.opacity(0.6), 0.6)
            } else {
                ctx.fill(.ellipse(CGPoint(x: c.x, y: c.y + 2.2), 5, 2.8), tongue)
            }
        case .chomp:
            var path = Path()
            path.move(to: CGPoint(x: c.x - 5.6, y: c.y - 2.2))
            path.addQuadCurve(to: CGPoint(x: c.x + 5.6, y: c.y - 2.2), control: CGPoint(x: c.x, y: c.y - 3.4))
            path.addQuadCurve(to: CGPoint(x: c.x - 5.6, y: c.y - 2.2), control: CGPoint(x: c.x, y: c.y + 11))
            ctx.fill(path, mouthColor)
            ctx.fill(.ellipse(CGPoint(x: c.x, y: c.y + 3.6), 5.6, 3), tongue)
            for index in 0..<2 {
                let side: CGFloat = index == 0 ? -1 : 1
                var fang = Path()
                fang.move(to: CGPoint(x: c.x + side * 3.6, y: c.y - 2.4))
                fang.addLine(to: CGPoint(x: c.x + side * 1.8, y: c.y - 2.4))
                fang.addLine(to: CGPoint(x: c.x + side * 2.8, y: c.y + 0.4))
                fang.closeSubpath()
                ctx.fill(fang, Color.white)
            }
        case .grin:
            var path = Path()
            path.move(to: CGPoint(x: c.x - 5.4, y: c.y - 1.8))
            path.addLine(to: CGPoint(x: c.x + 5.4, y: c.y - 1.8))
            path.addQuadCurve(to: CGPoint(x: c.x - 5.4, y: c.y - 1.8), control: CGPoint(x: c.x, y: c.y + 9.4))
            path.closeSubpath()
            ctx.fill(path, mouthColor)
            var clipped = ctx
            clipped.clip(to: path)
            clipped.fill(.ellipse(CGPoint(x: c.x, y: c.y + 4.4), 7, 4.6), tongue)
            ctx.stroke(path, mouthColor, 0.8)
        case .lick:
            ctx.stroke(catMouth(c), ink, line)
            var lickPath = Path()
            lickPath.move(to: CGPoint(x: c.x + 0.8, y: c.y + 0.2))
            lickPath.addQuadCurve(to: CGPoint(x: c.x + 5.4, y: c.y - 2.8), control: CGPoint(x: c.x + 5.6, y: c.y + 2.8))
            lickPath.addQuadCurve(to: CGPoint(x: c.x + 0.8, y: c.y + 0.2), control: CGPoint(x: c.x + 2.0, y: c.y - 2.4))
            ctx.fill(lickPath, tongue)
            ctx.stroke(lickPath, mouthColor.opacity(0.5), 0.6)
        case .tiny:
            var path = Path()
            path.move(to: CGPoint(x: c.x - 1.8, y: c.y))
            path.addQuadCurve(to: CGPoint(x: c.x + 1.8, y: c.y), control: CGPoint(x: c.x, y: c.y + 1.2))
            ctx.stroke(path, ink, line)
        case .o:
            ctx.fill(.ellipse(CGPoint(x: c.x, y: c.y + 0.5), 3.6, 4.2), mouthColor)
        case .flat:
            var path = Path()
            path.move(to: CGPoint(x: c.x - 3, y: c.y))
            path.addLine(to: CGPoint(x: c.x + 3, y: c.y))
            ctx.stroke(path, ink, line)
        case .wavy:
            var path = Path()
            path.move(to: CGPoint(x: c.x - 4.5, y: c.y + 0.5))
            path.addQuadCurve(to: CGPoint(x: c.x - 1.5, y: c.y + 0.5), control: CGPoint(x: c.x - 3, y: c.y - 1.6))
            path.addQuadCurve(to: CGPoint(x: c.x + 1.5, y: c.y + 0.5), control: CGPoint(x: c.x, y: c.y + 2.6))
            path.addQuadCurve(to: CGPoint(x: c.x + 4.5, y: c.y + 0.5), control: CGPoint(x: c.x + 3, y: c.y - 1.6))
            ctx.stroke(path, ink, line - 0.1)
        case .blep:
            // A bigger tongue in the menu bar, so the blep reads at 12 pt.
            let k: CGFloat = style.tiny ? 1.5 : 1
            ctx.fill(.ellipse(CGPoint(x: c.x + 1.4, y: c.y + 2.6 * k), 4.2 * k, 5.2 * k), tongue)
            ctx.stroke(catMouth(c), ink, line)
        case .yawn:
            let open = Path.ellipse(CGPoint(x: c.x, y: c.y + 2.6), 9.4, 11.6)
            ctx.fill(open, mouthColor)
            var inside = ctx
            inside.clip(to: open)
            inside.fill(.ellipse(CGPoint(x: c.x, y: c.y + 7.6), 7.6, 5.4), tongue)
            ctx.stroke(open, mouthColor, 0.8)
        }
    }
}
