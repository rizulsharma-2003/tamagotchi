import SwiftUI
import TamagotchiCore

/// What the card needs besides the numbers: names, looks and how the characters move.
struct RecapLook {
    var petName: String
    var companionName: String
    var petColor: PetColor
    var petAccessory: Accessory?
    var companionAccessory: Accessory?
    var showCompanion: Bool
    var reducedMotion: Bool
    var intensity: AnimationIntensity
    var seed: UInt64
}

/// The shareable card (420×560): both characters presenting the day, the date, stat tiles
/// and a one-line summary. Always light, so a saved image looks the same everywhere.
struct RecapCard: View {
    static let size = CGSize(width: 420, height: 560)

    let recap: DailyRecap
    let look: RecapLook
    let now: Date
    /// Animate the characters (in the window); images use the still moment `time`.
    var animated = false
    var paused = false
    var time = 2.2

    private var title: String {
        let day = DailyRecap.dayName(recap.day, now: now)
        let names = look.showCompanion ? "\(look.petName) & \(look.companionName)" : look.petName
        if recap.isQuiet { return "A quiet \(day == "Today" || day == "Yesterday" ? "day" : day) with \(names)" }
        return "\(day) with \(names)"
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(height: 164)
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(RecapPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 8) {
                    Text(recap.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(RecapPalette.ink.opacity(0.6))
                    if recap.streak >= 1 { streakChip }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            // A full day of tiles fills the space; a quiet day's note sits in the middle of it.
            if recap.tiles.isEmpty { Spacer(minLength: 6) }
            content
                .padding(.horizontal, 18)
                .padding(.top, 14)
            Spacer(minLength: 6)
            Text(recap.summary(petName: look.petName, companionName: look.companionName))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(RecapPalette.ink.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 26)
            footer
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(RecapPalette.background(quiet: recap.isQuiet))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private var stage: some View {
        if animated {
            // Only the characters animate; the rest of the card stays still.
            TimelineView(.animation(minimumInterval: look.reducedMotion ? 1.0 / 8 : 1.0 / 30, paused: paused)) { timeline in
                RecapStage(recap: recap, look: look, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            RecapStage(recap: recap, look: look, time: time)
        }
    }

    private var streakChip: some View {
        let days = recap.streak == 1 ? "1 day" : "\(recap.streak) days"
        return Label(recap.streakIsLowerBound ? "At least \(days) in a row" : "\(days) in a row", systemImage: "flame.fill")
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hex: 0xE8663D))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(hex: 0xFFE3D3), in: Capsule())
            .help(recap.streakIsLowerBound ? "Your history doesn't go back further, so the streak may be longer." : "Days in a row with Claude Code activity")
    }

    @ViewBuilder
    private var content: some View {
        let tiles = recap.tiles
        if tiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(hex: 0x9C8CFF))
                Text(quietMessage)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(RecapPalette.ink.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            // Two per row; an odd last tile gets the whole row.
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { index in
                    HStack(spacing: 8) {
                        RecapTileView(tile: tiles[index])
                        if index + 1 < tiles.count { RecapTileView(tile: tiles[index + 1]) }
                    }
                }
            }
        }
    }

    private var quietMessage: String {
        if recap.coverage == .none { return "This day is older than the history kept on this Mac." }
        return "No Claude Code sessions \(DailyRecap.dayName(recap.day, now: now) == "Today" ? "yet today" : "this day").\nRest days count too."
    }

    @ViewBuilder
    private var footer: some View {
        let note: String = {
            switch recap.coverage {
            case .partial(let since):
                return "History starts at \(since.formatted(date: .omitted, time: .shortened)) this day · real events only"
            default:
                return "From real Claude Code events on this Mac"
            }
        }()
        HStack(spacing: 5) {
            Image(systemName: "pawprint.fill").font(.system(size: 8.5))
            Text(note).font(.system(size: 9.5, weight: .medium, design: .rounded))
        }
        .foregroundStyle(RecapPalette.ink.opacity(0.4))
    }
}

enum RecapPalette {
    static let ink = Color(hex: 0x41324F)

    static func background(quiet: Bool) -> LinearGradient {
        let colors = quiet
            ? [Color(hex: 0xE4E6FF), Color(hex: 0xF3E9FF), Color(hex: 0xFFF3EC)]
            : [Color(hex: 0xFFE6D6), Color(hex: 0xFFF2E8), Color(hex: 0xEDE6FF)]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

private struct RecapTileView: View {
    let tile: DailyRecap.Tile

    var body: some View {
        let content = Self.content(tile)
        HStack(spacing: 10) {
            Image(systemName: content.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(content.tint.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(content.value)
                    .font(.system(size: content.value.count > 7 ? 15 : 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(RecapPalette.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(content.label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(RecapPalette.ink.opacity(0.55))
                    .lineLimit(1)
                if let detail = content.detail {
                    Text(detail)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(content.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 60)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
    }

    struct Content {
        var symbol: String
        var tint: Color
        var value: String
        var label: String
        var detail: String?
    }

    static func content(_ tile: DailyRecap.Tile) -> Content {
        switch tile {
        case .turns(let count):
            return Content(symbol: "checkmark", tint: Color(hex: 0x4CB782), value: "\(count)", label: count == 1 ? "turn finished" : "turns finished")
        case .sessions(let count):
            return Content(symbol: "bubble.left.and.bubble.right.fill", tint: Color(hex: 0x7B7BEA), value: "\(count)",
                           label: count == 1 ? "session" : "sessions")
        case .toolCalls(let count, let top):
            return Content(symbol: "wrench.and.screwdriver.fill", tint: Color(hex: 0xF29A4A), value: "\(count)",
                           label: count == 1 ? "tool call" : "tool calls", detail: top?.recapTitle)
        case .buildsAndTests(let builds, let tests):
            var parts: [String] = []
            if builds > 0 { parts.append(builds == 1 ? "1 build" : "\(builds) builds") }
            if tests > 0 { parts.append(tests == 1 ? "1 test run" : "\(tests) test runs") }
            return Content(symbol: "checkmark.seal.fill", tint: Color(hex: 0x2FB3A0), value: "\(builds + tests)", label: "green builds & tests",
                           detail: parts.joined(separator: " · "))
        case .bouncedBack(let count):
            return Content(symbol: "arrow.uturn.up", tint: Color(hex: 0xF0718F), value: "\(count)",
                           label: count == 1 ? "error bounced back" : "errors bounced back", detail: "and finished anyway")
        case .focus(let minutes, let blocks):
            return Content(symbol: "moon.zzz.fill", tint: Color(hex: 0x9C7BEA), value: "\(minutes) min", label: "of focus",
                           detail: blocks == 1 ? "1 focus block" : "\(blocks) focus blocks")
        case .activeSpan(let from, let to):
            let span = to.timeIntervalSince(from)
            let hours = Int(span) / 3600
            let minutes = (Int(span) % 3600) / 60
            return Content(symbol: "clock.fill", tint: Color(hex: 0x5AA9E6),
                           value: "\(from.formatted(date: .omitted, time: .shortened))–\(to.formatted(date: .omitted, time: .shortened))",
                           label: "active", detail: hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min")
        case .milestones(let count):
            return Content(symbol: "flag.fill", tint: Color(hex: 0xE9B33F), value: "\(count)", label: count == 1 ? "milestone" : "milestones")
        }
    }
}

/// The characters presenting the day, with bunting and confetti.
struct RecapStage: View {
    let recap: DailyRecap
    let look: RecapLook
    let time: Double

    var body: some View {
        Canvas(rendersAsynchronously: false) { g, size in
            RecapStage.draw(recap: recap, look: look, time: time, in: g, size: size)
        }
    }

    static func draw(recap: DailyRecap, look: RecapLook, time: Double, in g: GraphicsContext, size: CGSize) {
        let quiet = recap.isQuiet
        let floor = size.height - 14
        // A soft glow behind the pair.
        let glowCenter = CGPoint(x: size.width / 2, y: floor - 30)
        g.fill(.ellipse(glowCenter, size.width * 0.95, 150), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0)]), center: glowCenter, startRadius: 10, endRadius: size.width * 0.45))
        g.fill(.ellipse(CGPoint(x: size.width / 2, y: floor + 2), size.width * 0.62, 18), Color(hex: 0xE9D6F5).opacity(0.7))

        if quiet {
            // Stars for a sleepy day.
            for index in 0..<9 {
                let p = CGPoint(x: 30 + CGFloat(Ease.hash(index, 4)) * (size.width - 60), y: 14 + CGFloat(Ease.hash(index, 8)) * 70)
                let twinkle = look.reducedMotion ? 0.8 : 0.55 + 0.35 * sin(time * 1.4 + Double(index))
                g.fill(.sparkle(p, radius: 4 + CGFloat(index % 3)), Color(hex: 0xB9A7FF).opacity(twinkle))
            }
        } else {
            bunting(in: g, width: size.width, time: time, reduced: look.reducedMotion)
            for index in 0..<16 {
                let x = 16 + CGFloat(Ease.hash(index, 21)) * (size.width - 32)
                let fall = look.reducedMotion ? 0 : (time * 12 + Double(index) * 9).truncatingRemainder(dividingBy: 40)
                let y = 34 + CGFloat(Ease.hash(index, 33)) * 90 + CGFloat(fall) * 0.25
                var piece = g
                piece.translateBy(x: x, y: y)
                piece.rotate(by: .radians(Double(index) + (look.reducedMotion ? 0 : time * 0.8)))
                piece.fill(.roundedRect(CGRect(x: -3, y: -1.6, width: 6, height: 3.2), 0.8),
                           ConfettiPalette.colors[index % ConfettiPalette.colors.count].opacity(0.85))
            }
        }

        let petContext = PoseContext(time: time, reducedMotion: look.reducedMotion, intensity: look.intensity, seed: look.seed)
        let companionContext = PoseContext(time: time, reducedMotion: look.reducedMotion, intensity: look.intensity, seed: look.seed &+ 0x5EED)
        let petX = look.showCompanion ? size.width * 0.33 : size.width * 0.5
        PetRenderer.draw(petPose(quiet: quiet, time: time, context: petContext), in: g, at: CGPoint(x: petX, y: floor), scale: 1.5,
                         palette: PetPalette(look.petColor), accessory: look.petAccessory, dark: false)
        if look.showCompanion {
            FeatureArt.drawCompanion(companionPose(recap: recap, context: companionContext), in: g,
                                     at: CGPoint(x: size.width * 0.69, y: floor + 4), scale: 1.18, accessory: look.companionAccessory, dark: false)
        }
    }

    /// Mochi raises a paw "ta-da" and does a little hop now and then; curled up asleep on a quiet day.
    static func petPose(quiet: Bool, time: Double, context: PoseContext) -> PetPose {
        if quiet { return PetPoseEvaluator.pose(.curl, elapsed: 0, context: context) }
        let cycle = time.truncatingRemainder(dividingBy: 4.0)
        if !context.reducedMotion, cycle < 1.0 {
            return PetPoseEvaluator.pose(.happyBounce, elapsed: cycle, duration: 1.0, context: context)
        }
        var pose = PetPoseEvaluator.pose(.idle, elapsed: 0, context: context)
        let raise = context.reducedMotion ? 1 : Ease.smooth(Ease.segment(cycle, 1.0, 1.35))
        pose.rightArm = 0.92 * raise
        pose.eyes = .happy
        pose.mouth = .grin
        pose.blush = 0.8
        pose.earPerk = 0.7
        pose.lookX = 0.35
        return pose
    }

    /// The companion holds up a trophy for a day with finished turns, waves otherwise, and rests on a quiet day.
    static func companionPose(recap: DailyRecap, context: PoseContext) -> CompanionPose {
        if recap.isQuiet { return CompanionPoseEvaluator.pose(.rest, elapsed: 0, context: context) }
        if recap.turnsFinished > 0 || recap.buildsPassed + recap.testsPassed > 0 {
            return CompanionPoseEvaluator.pose(.trophy, elapsed: 1.0, context: context)
        }
        var pose = CompanionPoseEvaluator.pose(.greet, elapsed: 0.8, context: context)
        pose.eyes = .happy
        return pose
    }

    static func bunting(in g: GraphicsContext, width: CGFloat, time: Double, reduced: Bool) {
        var string = Path()
        string.move(to: CGPoint(x: -10, y: 10))
        string.addQuadCurve(to: CGPoint(x: width + 10, y: 10), control: CGPoint(x: width / 2, y: 46))
        g.stroke(string, Color(hex: 0xC9B6DA), 1.2)
        let count = 11
        for index in 0..<count {
            let u = (Double(index) + 0.5) / Double(count)
            let x = -10 + CGFloat(u) * (width + 20)
            let y = CGFloat(10 + (1 - pow(2 * u - 1, 2)) * 18)
            let sway = reduced ? 0 : 0.08 * sin(time * 1.8 + Double(index))
            var flag = g
            flag.translateBy(x: x, y: y)
            flag.rotate(by: .radians(sway))
            var path = Path()
            path.move(to: CGPoint(x: -8, y: 0))
            path.addLine(to: CGPoint(x: 8, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 15))
            path.closeSubpath()
            flag.fill(path, ConfettiPalette.colors[index % ConfettiPalette.colors.count])
        }
    }
}
