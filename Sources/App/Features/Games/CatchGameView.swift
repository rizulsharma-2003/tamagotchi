import SwiftUI
import TamagotchiCore

/// The running game and its input, stepped once per frame by the canvas. Deliberately not
/// observable: it changes every frame and only the canvas reads it.
@MainActor
final class CatchSession {
    private(set) var game: CatchGame
    var left = false
    var right = false
    /// Pointer position while dragging, in field units.
    var dragX: Double?
    private var lastFrame: TimeInterval?
    /// When the speed last went up (game time), for the "Faster!" note.
    private(set) var fasterAt: Double?

    init(seed: UInt64) {
        game = CatchGame(seed: seed)
    }

    var input: CatchGame.Input {
        CatchGame.Input(direction: (right ? 1 : 0) - (left ? 1 : 0), targetX: dragX)
    }

    /// Steps the game to `time` (seconds, any monotonic base). The first call only sets the clock.
    func advance(to time: TimeInterval) -> [CatchGame.Event] {
        defer { lastFrame = time }
        guard let last = lastFrame, time > last else { return [] }
        let events = game.step(dt: time - last, input: input)
        if events.contains(where: { if case .faster = $0 { return true } else { return false } }) {
            fasterAt = game.time
        }
        return events
    }

    /// Development: drops a treat by hand.
    func debugDrop(_ kind: CatchGame.TreatKind, at x: Double) {
        game.drop(kind, at: x, y: 0.6)
    }

    /// Forget the last frame, e.g. after a pause, so no time jumps by.
    func resetClock() {
        lastFrame = nil
        left = false
        right = false
        dragX = nil
    }
}

/// What the overlays need to know; changes only at the start and end of a game.
@MainActor
@Observable
final class CatchModel {
    enum Phase: Equatable { case ready, playing, paused, over }

    var phase: Phase = .ready
    var lastScore = 0
    var lastCaught = 0
    var lastBestCombo = 0
    var newRecord = false
    @ObservationIgnored private(set) var session = CatchSession(seed: 1)

    func start() {
        session = CatchSession(seed: UInt64.random(in: 1...UInt64.max))
        phase = .playing
    }

    func pause() {
        guard phase == .playing else { return }
        session.resetClock()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        session.resetClock()
        phase = .playing
    }

    func finish(newRecord: Bool) {
        let game = session.game
        lastScore = game.score
        lastCaught = game.caught
        lastBestCombo = game.bestCombo
        self.newRecord = newRecord
        phase = .over
    }
}

struct CatchGameView: View {
    let environment: AppEnvironment
    let model: CatchModel
    let onEvents: ([CatchGame.Event]) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var windowVisible = false

    static let fieldSize = CGSize(width: 528, height: 372)

    var body: some View {
        let settings = environment.world.settings
        let records = settings.games
        VStack(spacing: 10) {
            ZStack {
                field
                overlay
            }
            .frame(width: Self.fieldSize.width, height: Self.fieldSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            HStack(spacing: 6) {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                Text("← → or A D to move · drag with the mouse · Space to pause")
                    .foregroundStyle(.secondary)
                Spacer()
                if records.catchGamesPlayed > 0 {
                    Text("Best \(records.catchHighScore) · \(records.catchGamesPlayed) \(records.catchGamesPlayed == 1 ? "game" : "games")")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .frame(width: Self.fieldSize.width)
        }
        .background(WindowVisibilityReader(visible: $windowVisible))
    }

    private var field: some View {
        let world = environment.world
        let settings = world.settings
        let palette = PetPalette(settings.petColor)
        let accessory = settings.petAccessory
        let reduced = world.reducedMotion
        let intensity = settings.animationIntensity
        let seed = world.seed
        let dark = colorScheme == .dark
        let model = self.model
        let playing = model.phase == .playing
        let showHUD = model.phase != .ready
        let best = settings.games.catchHighScore
        let interval = playing ? 1.0 / 60 : (reduced ? 1.0 / 12 : 1.0 / 30)
        return TimelineView(.animation(minimumInterval: interval, paused: !windowVisible)) { timeline in
            // The frame must depend on the tick's date, or SwiftUI skips redrawing the canvas.
            let frameDate = timeline.date
            Canvas(rendersAsynchronously: false) { g, size in
                let now = frameDate.timeIntervalSinceReferenceDate
                // Read at draw time: a restart swaps the session without changing the phase.
                let session = model.session
                if playing {
                    let events = session.advance(to: now)
                    if !events.isEmpty {
                        // Never change observable state while SwiftUI draws.
                        DispatchQueue.main.async { onEvents(events) }
                    }
                }
                let context = PoseContext(time: now, reducedMotion: reduced, intensity: intensity, seed: seed)
                CatchFieldRenderer.draw(session: session, in: g, size: size, dark: dark, time: now, context: context, palette: palette,
                                        accessory: accessory, best: best, showHUD: showHUD)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard model.phase == .playing else { return }
                    model.session.dragX = CatchFieldRenderer.fieldX(value.location.x, width: Self.fieldSize.width)
                }
                .onEnded { _ in model.session.dragX = nil }
        )
        .accessibilityLabel("Catch the Treats. Score \(model.session.game.score).")
    }

    @ViewBuilder
    private var overlay: some View {
        let petName = environment.world.settings.petName
        switch model.phase {
        case .playing:
            EmptyView()
        case .ready:
            GameCard {
                Text("Catch the Treats").font(.system(size: 22, weight: .heavy, design: .rounded))
                Text("Help \(petName) catch cookies, fish and berries. Golden cookies are a bonus. Three treats on the floor and the picnic is over.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.start() } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 90) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .help("Space")
            }
        case .paused:
            GameCard {
                Text("Paused").font(.system(size: 22, weight: .heavy, design: .rounded))
                Text("\(petName) is waiting patiently.").font(.system(size: 12)).foregroundStyle(.secondary)
                Button { model.resume() } label: { Label("Resume", systemImage: "play.fill").frame(minWidth: 90) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .help("Space")
            }
        case .over:
            GameCard {
                if model.newRecord {
                    Label("New high score!", systemImage: "crown.fill")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
                Text("\(model.lastScore)").font(.system(size: 44, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("\(model.lastCaught) caught · best combo \(model.lastBestCombo)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button { model.start() } label: { Label("Play Again", systemImage: "arrow.clockwise").frame(minWidth: 110) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .help("Space")
            }
        }
    }
}

/// A soft card floating over a game field.
struct GameCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) { content }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .frame(maxWidth: 330)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

/// Draws the picnic field, the treats, Mochi and the score.
@MainActor
enum CatchFieldRenderer {
    static let inset: CGFloat = 26
    static let top: CGFloat = 18
    static let grass: CGFloat = 40

    static func fieldX(_ x: CGFloat, width: CGFloat) -> Double {
        Double((x - inset) / (width - 2 * inset))
    }

    static func draw(session: CatchSession, in g: GraphicsContext, size: CGSize, dark: Bool, time: Double, context: PoseContext,
                     palette: PetPalette, accessory: Accessory?, best: Int, showHUD: Bool) {
        let game = session.game
        let floor = size.height - grass
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: inset + CGFloat(x) * (size.width - 2 * inset), y: floor - CGFloat(y) * (floor - top))
        }
        drawBackdrop(in: g, size: size, floor: floor, dark: dark, time: time)

        // Treats that landed rest on the grass for a moment, then fade.
        for splash in game.splashes where splash.points == 0 {
            let age = game.time - splash.at
            var faded = g
            faded.opacity = max(0, 1 - age / CatchGame.splashLife)
            let p = point(splash.x, 0)
            FeatureArt.drawTreat(splash.kind, in: faded, at: CGPoint(x: p.x, y: p.y - 6), size: 18, rotation: 1.4, time: time)
            var dust = g
            dust.translateBy(x: p.x, y: p.y)
            EffectRenderer.draw(Effect(.dust, x: 0, y: 0, scale: 1.2, phase: min(1, age / 0.5)), in: dust, unitX: 1, unitY: 1, dark: dark)
        }

        // Mochi.
        let pose = game.petPose(context: context)
        let petPoint = point(game.petX, 0)
        PetRenderer.draw(pose, in: g, at: CGPoint(x: petPoint.x, y: floor + 2), scale: 1.08, palette: palette, accessory: accessory, dark: dark)

        for treat in game.treats {
            let p = point(treat.x, treat.y)
            FeatureArt.drawTreat(treat.kind, in: g, at: p, size: treat.kind == .golden ? 22 : 21, rotation: treat.rotation, time: time)
        }

        // Catches: a pop and the points floating up.
        for splash in game.splashes where splash.points > 0 {
            let age = game.time - splash.at
            let p = point(splash.x, splash.y)
            var pop = g
            pop.translateBy(x: p.x, y: p.y)
            let kind: EffectKind = splash.kind == .golden ? .heartPop : .pop
            EffectRenderer.draw(Effect(kind, x: 0, y: 0, scale: 1.3, variant: splash.kind == .berry ? 0 : 2, phase: min(1, age / 0.5)),
                                in: pop, unitX: 1, unitY: 1, dark: dark)
            var label = g
            label.opacity = max(0, 1 - age / CatchGame.splashLife)
            FeatureArt.drawCenteredText("+\(splash.points)", in: label, at: CGPoint(x: p.x, y: p.y - 26 - CGFloat(age) * 34),
                                        size: splash.kind == .golden ? 20 : 16, color: splash.kind == .golden ? Color(hex: 0xF5A623) : Color(hex: 0xE2557A),
                                        outline: .white)
        }

        if showHUD { drawHUD(game, in: g, size: size, best: best, fasterAt: session.fasterAt) }
    }

    static func drawBackdrop(in g: GraphicsContext, size: CGSize, floor: CGFloat, dark: Bool, time: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let sky = dark ? [Color(hex: 0x2E2F63), Color(hex: 0x6A4E86)] : [Color(hex: 0xBFE4FF), Color(hex: 0xFFE7D1)]
        g.fill(Path(rect), with: .linearGradient(Gradient(colors: sky), startPoint: .zero, endPoint: CGPoint(x: 0, y: floor)))

        // Sun (or moon) with a soft glow.
        let sun = CGPoint(x: size.width - 74, y: 62)
        let glow = dark ? Color(hex: 0xFFF3C4) : Color(hex: 0xFFE08A)
        g.fill(.ellipse(sun, 120, 120), with: .radialGradient(Gradient(colors: [glow.opacity(0.55), glow.opacity(0)]),
                                                              center: sun, startRadius: 10, endRadius: 60))
        g.fill(.ellipse(sun, 38, 38), dark ? Color(hex: 0xFFF6DC) : Color(hex: 0xFFD45E))
        if dark {
            for index in 0..<14 {
                let x = CGFloat(Ease.hash(index, 11)) * size.width
                let y = CGFloat(Ease.hash(index, 23)) * floor * 0.55
                let twinkle = 0.45 + 0.4 * sin(time * 1.6 + Double(index))
                g.fill(.sparkle(CGPoint(x: x, y: y), radius: 2.6), Color.white.opacity(twinkle))
            }
        }

        // Drifting clouds.
        for index in 0..<3 {
            let speed = 6.0 + Double(index) * 3
            let span = Double(size.width) + 160
            let x = CGFloat((Double(index) * 210 + time * speed).truncatingRemainder(dividingBy: span)) - 80
            let y = CGFloat(48 + index * 38)
            cloud(in: g, at: CGPoint(x: x, y: y), scale: 0.8 + 0.2 * CGFloat(index % 2), color: Color.white.opacity(dark ? 0.16 : 0.85))
        }

        // Rolling hills behind the picnic.
        let hillsBack = dark ? Color(hex: 0x3C5B67) : Color(hex: 0xC8EBC0)
        let hillsFront = dark ? Color(hex: 0x2F4D50) : Color(hex: 0xA9DE9E)
        hill(in: g, size: size, base: floor, height: 92, phase: 0.2, color: hillsBack)
        hill(in: g, size: size, base: floor, height: 58, phase: 1.7, color: hillsFront)

        // Grass, with a picnic blanket to run on.
        let ground = CGRect(x: 0, y: floor - 4, width: size.width, height: size.height - floor + 4)
        g.fill(Path(ground), dark ? Color(hex: 0x3F6B4E) : Color(hex: 0x8ED17E))
        let blanket = CGRect(x: 10, y: floor + 6, width: size.width - 20, height: size.height - floor - 12)
        var cloth = g
        cloth.clip(to: .roundedRect(blanket, 7))
        cloth.fill(Path(blanket), dark ? Color(hex: 0xD9C9E8) : Color(hex: 0xFFF6F2))
        let check = dark ? Color(hex: 0xB07BC9).opacity(0.45) : Color(hex: 0xFF8FA3).opacity(0.45)
        var x = blanket.minX
        while x < blanket.maxX {
            cloth.fill(Path(CGRect(x: x, y: blanket.minY, width: 9, height: blanket.height)), check)
            x += 18
        }
        var y = blanket.minY
        while y < blanket.maxY {
            cloth.fill(Path(CGRect(x: blanket.minX, y: y, width: blanket.width, height: 6)), check)
            y += 12
        }
        g.stroke(.roundedRect(blanket, 7), dark ? Color(hex: 0x9C7AB5) : Color(hex: 0xF29BAE), 1.2)
        // Tufts along the edge of the grass.
        for index in 0..<26 {
            let tx = CGFloat(index) * size.width / 25 + CGFloat(Ease.hash(index, 5)) * 8
            var tuft = Path()
            tuft.move(to: CGPoint(x: tx - 3, y: floor - 2))
            tuft.addLine(to: CGPoint(x: tx - 1, y: floor - 8))
            tuft.move(to: CGPoint(x: tx + 1, y: floor - 2))
            tuft.addLine(to: CGPoint(x: tx + 3, y: floor - 9))
            g.stroke(tuft, dark ? Color(hex: 0x5C8E66) : Color(hex: 0x6DBA63), 1.6)
        }
    }

    static func cloud(in g: GraphicsContext, at p: CGPoint, scale s: CGFloat, color: Color) {
        var path = Path()
        for (dx, dy, r) in [(-22.0, 4.0, 15.0), (0.0, -6.0, 20.0), (22.0, 3.0, 15.0), (6.0, 8.0, 14.0)] {
            path.addEllipse(in: CGRect(x: p.x + CGFloat(dx - r) * s, y: p.y + CGFloat(dy - r) * s, width: CGFloat(2 * r) * s, height: CGFloat(2 * r) * s))
        }
        g.fill(path, color)
    }

    static func hill(in g: GraphicsContext, size: CGSize, base: CGFloat, height: CGFloat, phase: Double, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: base))
        let steps = 48
        for index in 0...steps {
            let u = Double(index) / Double(steps)
            let y = base - height * CGFloat(0.55 + 0.25 * sin(u * 5.2 + phase) + 0.2 * sin(u * 11.3 + phase * 2))
            path.addLine(to: CGPoint(x: CGFloat(u) * size.width, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: base))
        path.closeSubpath()
        g.fill(path, color)
    }

    static func drawHUD(_ game: CatchGame, in g: GraphicsContext, size: CGSize, best: Int, fasterAt: Double?) {
        let ink = Color(hex: 0x4A3B5C)
        // Score pill.
        let pill = Path.roundedRect(CGRect(x: 12, y: 12, width: 112, height: game.combo >= 2 ? 50 : 36), 12)
        g.fill(pill, Color.white.opacity(0.78))
        g.draw(Text("SCORE").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundColor(ink.opacity(0.6)),
               at: CGPoint(x: 24, y: 19), anchor: .topLeading)
        g.draw(Text("\(game.score)").font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(ink),
               at: CGPoint(x: 112, y: 30), anchor: .trailing)
        if game.combo >= 2 {
            let multiplier = CatchGame.multiplier(combo: game.combo)
            let text = multiplier > 1 ? "×\(multiplier) · \(game.combo) in a row" : "\(game.combo) in a row"
            g.draw(Text(text).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(Color(hex: 0xE2557A)),
                   at: CGPoint(x: 24, y: 47), anchor: .leading)
        }

        // Lives as hearts.
        let lives = CatchGame.maxMisses - game.misses
        let heartsPill = Path.roundedRect(CGRect(x: size.width - 92, y: 12, width: 80, height: 30), 12)
        g.fill(heartsPill, Color.white.opacity(0.78))
        for index in 0..<CatchGame.maxMisses {
            let center = CGPoint(x: size.width - 74 + CGFloat(index) * 22, y: 27)
            let heart = Path.heart(center, size: 15)
            if index < lives {
                g.fill(heart, Color(hex: 0xFF6F91))
                g.fill(.ellipse(CGPoint(x: center.x - 3, y: center.y - 3), 3.4, 2.4), Color.white.opacity(0.6))
            } else {
                g.stroke(heart, ink.opacity(0.28), 1.4)
            }
        }

        if best > 0 {
            g.draw(Text("Best \(best)").font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundColor(ink.opacity(0.55)), at: CGPoint(x: size.width - 52, y: 52), anchor: .center)
        }

        if let fasterAt, game.time - fasterAt < 1.4 {
            let age = game.time - fasterAt
            var note = g
            note.opacity = min(1, age / 0.15) * (1 - Ease.segment(age, 1.0, 1.4))
            let scale = 1 + 0.25 * (1 - Ease.outBack(Ease.segment(age, 0, 0.35)))
            note.translateBy(x: size.width / 2, y: 64)
            note.scaleBy(x: scale, y: scale)
            FeatureArt.drawCenteredText("Faster!", in: note, at: .zero, size: 24, color: Color(hex: 0xFF8A5C), outline: .white)
        }
    }
}
