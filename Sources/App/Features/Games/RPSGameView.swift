import SwiftUI
import TamagotchiCore

/// A sitting of rock-paper-scissors: the match, the round on stage and its timing.
@MainActor
@Observable
final class RPSModel {
    /// Shake, reveal, react: the round's beats in seconds.
    nonisolated static let shake = 1.5
    nonisolated static let hold = 0.45
    nonisolated static let roundLength = 3.6

    private(set) var match: RPSMatch
    private(set) var round: RPSRound?
    /// Reference-date seconds when the current round began.
    private(set) var startedAt: TimeInterval?
    /// The round has been revealed (the result line and scores show).
    private(set) var revealed = false
    private(set) var busy = false

    init(withCompanion: Bool) {
        match = RPSMatch(seed: UInt64.random(in: 1...UInt64.max), withCompanion: withCompanion)
    }

    /// Starts a round; the characters' picks are fixed before the shake. Returns false while one runs.
    func play(_ choice: RPSChoice, at time: TimeInterval) -> RPSRound? {
        guard !busy else { return nil }
        let picks = match.nextPicks()
        let round = RPSRound(player: choice, pet: picks.pet, companion: picks.companion)
        self.round = round
        startedAt = time
        revealed = false
        busy = true
        return round
    }

    /// Scores the round at the reveal.
    func reveal() {
        guard let round, !revealed else { return }
        match.play(round)
        revealed = true
    }

    func finish() { busy = false }

    func reset(withCompanion: Bool) {
        guard !busy else { return }
        match = RPSMatch(seed: UInt64.random(in: 1...UInt64.max), withCompanion: withCompanion)
        round = nil
        startedAt = nil
        revealed = false
    }
}

struct RPSGameView: View {
    let environment: AppEnvironment
    let model: RPSModel
    let onPick: (RPSChoice) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var windowVisible = false

    static let stageSize = CGSize(width: 528, height: 250)

    var body: some View {
        let settings = environment.world.settings
        VStack(spacing: 12) {
            stage
                .frame(width: Self.stageSize.width, height: Self.stageSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            resultLine(settings)
            HStack(spacing: 10) {
                ForEach(RPSChoice.allCases, id: \.rawValue) { choice in
                    Button { onPick(choice) } label: {
                        VStack(spacing: 2) {
                            Text(choice.emoji).font(.system(size: 26))
                            Text(choice.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(keyHint(choice)).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ChipButtonStyle(highlighted: model.round?.player == choice && model.busy))
                    .disabled(model.busy)
                    .accessibilityLabel(choice.title)
                }
            }
            .frame(width: 400)
            scoreboard(settings)
        }
        .background(WindowVisibilityReader(visible: $windowVisible))
    }

    private func keyHint(_ choice: RPSChoice) -> String {
        switch choice {
        case .rock: return "R or 1"
        case .paper: return "P or 2"
        case .scissors: return "S or 3"
        }
    }

    private var stage: some View {
        let world = environment.world
        let settings = world.settings
        let palette = PetPalette(settings.petColor)
        let petAccessory = settings.petAccessory
        let companionAccessory = settings.companionAccessory
        let reduced = world.reducedMotion
        let intensity = settings.animationIntensity
        let seed = world.seed
        let dark = colorScheme == .dark
        let round = model.round
        let startedAt = model.startedAt
        let withCompanion = model.match.withCompanion
        let interval = model.busy ? 1.0 / 60 : (reduced ? 1.0 / 12 : 1.0 / 24)
        return TimelineView(.animation(minimumInterval: interval, paused: !windowVisible)) { timeline in
            let frameDate = timeline.date
            Canvas(rendersAsynchronously: false) { g, size in
                let now = frameDate.timeIntervalSinceReferenceDate
                let elapsed = startedAt.map { now - $0 }
                let petContext = PoseContext(time: now, reducedMotion: reduced, intensity: intensity, seed: seed)
                let companionContext = PoseContext(time: now, reducedMotion: reduced, intensity: intensity, seed: seed &+ 0x5EED)
                RPSStageRenderer.draw(in: g, size: size, dark: dark, time: now, round: round, elapsed: elapsed, withCompanion: withCompanion,
                                      petPose: RPSStageRenderer.petPose(round: round, elapsed: elapsed, context: petContext),
                                      companionPose: RPSStageRenderer.companionPose(round: round, elapsed: elapsed, context: companionContext),
                                      palette: palette, petAccessory: petAccessory, companionAccessory: companionAccessory)
            }
        }
        .accessibilityLabel(accessibilityText(settings))
    }

    @ViewBuilder
    private func resultLine(_ settings: AppSettings) -> some View {
        if let round = model.round, model.revealed {
            let text = RPSText.result(round, petName: settings.petName, companionName: settings.companionName)
            VStack(spacing: 1) {
                Text(text.headline).font(.system(size: 17, weight: .heavy, design: .rounded))
                Text(text.detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(height: 40)
            .transition(.opacity)
        } else {
            Text(model.busy ? "Rock… paper… scissors…" : "Pick one: you play \(settings.petName)\(model.match.withCompanion ? " and \(settings.companionName)" : "") at once.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(height: 40)
        }
    }

    private func scoreboard(_ settings: AppSettings) -> some View {
        let records = settings.games
        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                TallyChip(title: "vs \(settings.petName)", tally: model.match.vsPet, tint: .orange)
                if model.match.withCompanion {
                    TallyChip(title: "vs \(settings.companionName)", tally: model.match.vsCompanion, tint: .teal)
                }
                if model.match.streak >= 2 {
                    Label("\(model.match.streak) in a row", systemImage: "flame.fill")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
            }
            Text("All time: \(records.rpsWins) won · \(records.rpsLosses) lost · \(records.rpsDraws) drawn"
                 + (records.rpsBestStreak > 1 ? " · best streak \(records.rpsBestStreak)" : ""))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func accessibilityText(_ settings: AppSettings) -> String {
        guard let round = model.round, model.revealed else { return "Rock, paper, scissors with \(settings.petName)." }
        let text = RPSText.result(round, petName: settings.petName, companionName: settings.companionName)
        return "\(text.headline) \(text.detail)"
    }
}

private struct TallyChip: View {
    let title: String
    let tally: RPSTally
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
            Text("\(tally.wins)–\(tally.losses)–\(tally.draws)")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .help("Won – lost – drawn this sitting")
    }
}

/// What a round means, in words.
enum RPSText {
    static func result(_ round: RPSRound, petName: String, companionName: String) -> (headline: String, detail: String) {
        func duel(_ outcome: Int, _ name: String) -> String {
            switch outcome {
            case 1: return "you beat \(name)"
            case -1: return "\(name) wins"
            default: return "a draw with \(name)"
            }
        }
        var parts = [duel(round.vsPet, petName)]
        if let outcome = round.vsCompanion { parts.append(duel(outcome, companionName)) }
        let detail = parts.joined(separator: " · ")
        let headline: String
        if round.isWin {
            headline = round.duels.allSatisfy { $0 == 1 } ? "Clean sweep!" : "You win!"
        } else if round.isLoss {
            headline = round.duels.allSatisfy { $0 == -1 } ? "They got you!" : "Not this time!"
        } else if round.duels.allSatisfy({ $0 == 0 }) {
            headline = "Great minds think alike!"
        } else {
            headline = "Split decision!"
        }
        return (headline, detail.prefix(1).uppercased() + detail.dropFirst())
    }
}

/// The stage: Mochi on the left, the companion on the right, your hand in the middle
/// (just Mochi and you when the companion is set never to show).
enum RPSStageRenderer {
    static let companionX: CGFloat = 0.75

    static func petX(_ withCompanion: Bool) -> CGFloat { withCompanion ? 0.25 : 0.34 }
    static func handX(_ withCompanion: Bool) -> CGFloat { withCompanion ? 0.5 : 0.68 }

    static func petPose(round: RPSRound?, elapsed: Double?, context: PoseContext) -> PetPose {
        guard let round, let t = elapsed else {
            var pose = PetPoseEvaluator.pose(.idle, elapsed: 0, context: context)
            pose.lookX = 0.5
            return pose
        }
        if t < RPSModel.shake {
            return PetPoseEvaluator.pose(.rpsShake, elapsed: t, duration: RPSModel.shake, context: context)
        }
        let r = t - RPSModel.shake
        var pose: PetPose
        if r < RPSModel.hold {
            pose = PetPoseEvaluator.pose(.idle, elapsed: 0, context: context)
            pose.eyes = .wide
            pose.earPerk = 0.6
        } else {
            // From Mochi's side: it won when you lost to it.
            let outcome = -round.vsPet
            let animation: PetAnimation = outcome > 0 ? .excitedJump : (outcome < 0 ? .concerned : .blep)
            let length: Double = outcome < 0 ? 1.9 : animation.defaultDuration
            pose = PetPoseEvaluator.pose(animation, elapsed: r - RPSModel.hold, duration: length, context: context)
        }
        pose.held = round.pet.item
        pose.rightArm = max(pose.rightArm, 0.45)
        return pose
    }

    static func companionPose(round: RPSRound?, elapsed: Double?, context: PoseContext) -> CompanionPose {
        guard let round, let companion = round.companion, let t = elapsed else {
            return CompanionPoseEvaluator.pose(.idleAtDesk, elapsed: 0, context: context)
        }
        if t < RPSModel.shake {
            return CompanionPoseEvaluator.pose(.rpsShake, elapsed: t, duration: RPSModel.shake, context: context)
        }
        let r = t - RPSModel.shake
        var pose: CompanionPose
        if r < RPSModel.hold {
            pose = CompanionPoseEvaluator.pose(.idleAtDesk, elapsed: 0, context: context)
            pose.eyes = .wide
        } else {
            let outcome = -(round.vsCompanion ?? 0)
            let animation: CompanionAnimation = outcome > 0 ? .celebrate : (outcome < 0 ? .doubleTake : .nod)
            let local = r - RPSModel.hold
            pose = local < animation.defaultDuration
                ? CompanionPoseEvaluator.pose(animation, elapsed: local, context: context)
                : CompanionPoseEvaluator.pose(.idleAtDesk, elapsed: 0, context: context)
            if outcome > 0, local >= animation.defaultDuration { pose.eyes = .happy }
        }
        pose.held = companion.item
        pose.leftArm = max(pose.leftArm, 0.5)
        return pose
    }

    static func draw(in g: GraphicsContext, size: CGSize, dark: Bool, time: Double, round: RPSRound?, elapsed: Double?, withCompanion: Bool,
                     petPose: PetPose, companionPose: CompanionPose, palette: PetPalette, petAccessory: Accessory?, companionAccessory: Accessory?) {
        let rect = CGRect(origin: .zero, size: size)
        let colors = dark ? [Color(hex: 0x33305C), Color(hex: 0x52406E)] : [Color(hex: 0xFFF1E4), Color(hex: 0xEDE4FF)]
        g.fill(Path(rect), with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        // Soft spotlights for the two players.
        let floor = size.height - 30
        let petX = petX(withCompanion)
        for (x, tint) in [(petX, Color(hex: 0xFFC9A8)), (companionX, Color(hex: 0xB8E8DA))] where x == petX || withCompanion {
            let center = CGPoint(x: size.width * x, y: floor)
            g.fill(.ellipse(center, 170, 44), with: .radialGradient(Gradient(colors: [tint.opacity(dark ? 0.35 : 0.7), tint.opacity(0)]),
                                                                    center: center, startRadius: 4, endRadius: 85))
        }
        // Confetti dots in the background.
        for index in 0..<18 {
            let x = CGFloat(Ease.hash(index, 3)) * size.width
            let y = CGFloat(Ease.hash(index, 9)) * (floor - 40) + 10
            let color = ConfettiPalette.colors[index % ConfettiPalette.colors.count]
            g.fill(.ellipse(CGPoint(x: x, y: y), 5, 5), color.opacity(dark ? 0.35 : 0.45))
        }

        PetRenderer.draw(petPose, in: g, at: CGPoint(x: size.width * petX, y: floor), scale: 1.55, palette: palette, accessory: petAccessory, dark: dark)
        if withCompanion {
            FeatureArt.drawCompanion(companionPose, in: g, at: CGPoint(x: size.width * companionX, y: floor + 6), scale: 1.32,
                                     accessory: companionAccessory, dark: dark)
        }
        drawPlayerHand(in: g, size: size, centerX: size.width * handX(withCompanion), round: round, elapsed: elapsed, dark: dark, time: time)
        drawChant(in: g, size: size, elapsed: elapsed)
        if let round, let elapsed, elapsed >= RPSModel.shake + 0.15 {
            let age = elapsed - RPSModel.shake - 0.15
            badge(for: -round.vsPet, in: g, at: CGPoint(x: size.width * petX, y: 26), age: age)
            if let outcome = round.vsCompanion { badge(for: -outcome, in: g, at: CGPoint(x: size.width * companionX, y: 26), age: age) }
        }
    }

    /// Your hand: a fist that bobs with the chant, then your pick.
    static func drawPlayerHand(in g: GraphicsContext, size: CGSize, centerX: CGFloat, round: RPSRound?, elapsed: Double?, dark: Bool,
                               time: Double) {
        let base = CGPoint(x: centerX, y: size.height - 74)
        var emoji = "✊"
        var bob: CGFloat = 0
        var pop: CGFloat = 1
        var label = "You"
        if let round, let t = elapsed {
            if t < RPSModel.shake {
                bob = -CGFloat(abs(sin(.pi * t / 0.5))) * 12
            } else {
                emoji = round.player.emoji
                pop = CGFloat(1 + 0.3 * (1 - Ease.outBack(Ease.segment(t - RPSModel.shake, 0, 0.3))))
                label = round.player.title
            }
        } else {
            bob = CGFloat(sin(time * 2)) * 2
        }
        let center = CGPoint(x: base.x, y: base.y + bob)
        g.fill(.ellipse(CGPoint(x: base.x, y: size.height - 30), 54, 12), Color.black.opacity(dark ? 0.25 : 0.08))
        let disc = Path.ellipse(center, 66 * pop, 66 * pop)
        g.fill(disc, dark ? Color(hex: 0x4A4472) : Color.white)
        g.stroke(disc, dark ? Color(hex: 0x8C7FC0) : Color(hex: 0xE5DAF5), 2)
        var hand = g
        hand.translateBy(x: center.x, y: center.y)
        hand.scaleBy(x: pop, y: pop)
        hand.draw(Text(emoji).font(.system(size: 32)), at: .zero, anchor: .center)
        g.text(label, at: CGPoint(x: base.x, y: size.height - 18), size: 11, weight: .bold, color: dark ? .white.opacity(0.8) : Color(hex: 0x6A5C7A))
    }

    static func drawChant(in g: GraphicsContext, size: CGSize, elapsed: Double?) {
        guard let t = elapsed, t < RPSModel.shake + 0.6 else { return }
        let words = ["Rock…", "Paper…", "Scissors…", "Shoot!"]
        let index = min(3, Int(t / 0.5))
        let local = t - Double(index) * 0.5
        var text = g
        let scale = 1 + 0.35 * (1 - Ease.outBack(Ease.segment(local, 0, 0.2)))
        text.opacity = index == 3 ? 1 - Ease.segment(local, 0.4, 0.6) : 1
        text.translateBy(x: size.width / 2, y: 40)
        text.scaleBy(x: scale, y: scale)
        FeatureArt.drawCenteredText(words[index], in: text, at: .zero, size: index == 3 ? 26 : 20,
                                    color: index == 3 ? Color(hex: 0xFF6F91) : Color(hex: 0x7A68C9), outline: .white)
    }

    /// "Won!" above a character that beat you, "Lost" when you beat it, "Draw" otherwise.
    static func badge(for outcome: Int, in g: GraphicsContext, at point: CGPoint, age: Double) {
        let text = outcome > 0 ? "Won!" : (outcome < 0 ? "Lost" : "Draw")
        let tint = outcome > 0 ? Color(hex: 0xFF8A5C) : (outcome < 0 ? Color(hex: 0x8C84A8) : Color(hex: 0x62BDF2))
        var b = g
        let scale = Ease.outBack(Ease.segment(age, 0, 0.25))
        b.translateBy(x: point.x, y: point.y)
        b.scaleBy(x: scale, y: scale)
        let pill = Path.roundedRect(CGRect(x: -30, y: -12, width: 60, height: 24), 12)
        b.fill(pill, tint)
        b.text(text, at: .zero, size: 12.5, weight: .heavy, color: .white)
    }
}
