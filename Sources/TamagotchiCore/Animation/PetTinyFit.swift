import Foundation

/// Fits a pose to the menu bar, where Mochi is about 12–16 pt tall in a 22–24 pt bar.
///
/// - Big leaps are compressed (y′ = c·tanh(y/c)), so a 0.5 body-height pounce peaks at
///   about a quarter of a body height and the ears stay under the bar top; the lost
///   height becomes a little extra stretch so the jump still reads.
/// - World-space props in the air move down with the body (a caught cookie still meets
///   the mouth); props on the floor stay on the floor.
/// - Effects high above the head are eased down towards the ear line.
/// - Only a few bold effects are kept: props first, then symbols, then one cue of each
///   kind of motion mark (a streak, a pair of shake arcs, a sniff puff, a dust puff).
///
/// Pure, so the menu-bar geometry is testable; `PetRenderer` applies it for `.tiny`.
public enum PetTinyFit {
    /// Lift compression scale (body heights).
    public static let liftScale = 0.26
    /// Effects whose top is above this height (body heights above the feet) are eased down…
    public static let effectKnee = 0.95
    /// …so that none goes higher than this.
    public static let effectCeiling = 1.38
    /// At most this many effects are drawn.
    public static let maxEffects = 5

    public static func lift(_ y: Double) -> Double {
        y <= 0 ? y : liftScale * tanh(y / liftScale)
    }

    /// Eases an absolute height (body heights above the feet) under the ceiling.
    public static func height(_ h: Double) -> Double {
        guard h > effectKnee else { return h }
        let span = effectCeiling - effectKnee
        return effectKnee + span * tanh((h - effectKnee) / span)
    }

    /// Draw priority at menu-bar size (nil = not drawn) and how many of a kind to keep.
    public static func rank(_ kind: EffectKind) -> (rank: Int, cap: Int)? {
        switch kind {
        case .ball, .yarn, .butterfly, .bubble, .treat, .fish, .berry, .cupcake, .frosting, .orb, .tangle:
            return (0, 4)
        case .heart, .heartPop, .z, .note, .star, .sparkle, .noseBubble, .notice, .sneeze, .burst, .pop,
             .question, .exclamation, .sweat, .confetti, .clap:
            return (1, 3)
        case .streak, .sniff, .dust:
            return (2, 1)
        case .shakeLines, .crumb, .droplet:
            return (2, 2)
        case .purr, .steam, .shadow, .speechDots, .speechLock, .speechQuestion, .plug, .thinkingDots:
            return nil
        }
    }

    public static func fit(_ pose: PetPose) -> PetPose {
        var p = pose
        let y0 = pose.y
        let y1 = lift(y0)
        p.y = y1
        let lost = y0 - y1
        if lost > 0 {
            let stretch = min(0.04, 0.12 * lost)
            p.scaleY *= 1 + stretch
            p.scaleX *= 1 - 0.6 * stretch
        }
        p.effects = select(pose.effects)
        for index in p.effects.indices {
            var e = p.effects[index]
            if e.kind == .tangle { continue }
            let world = y0 + e.y
            if e.worldSpace {
                // Floor props keep their place on the floor; airborne ones come down with the body.
                let airborne = Ease.smooth(Ease.segment(world, 0.15, 0.45))
                e.y = Ease.lerp(world - y1, e.y, airborne)
            }
            e.y = height(y1 + e.y) - y1
            p.effects[index] = e
        }
        return p
    }

    /// Stable selection by rank: at most `maxEffects`, each kind capped, faint ones dropped.
    static func select(_ effects: [Effect]) -> [Effect] {
        guard !effects.isEmpty else { return effects }
        var chosen: [Int] = []
        chosen.reserveCapacity(maxEffects)
        for pass in 0...2 {
            for (index, effect) in effects.enumerated() where chosen.count < maxEffects {
                guard effect.opacity > 0.12, let (rank, cap) = rank(effect.kind), rank == pass else { continue }
                var count = 0
                for other in chosen where effects[other].kind == effect.kind { count += 1 }
                if count < cap { chosen.append(index) }
            }
        }
        chosen.sort()
        return chosen.map { effects[$0] }
    }
}
