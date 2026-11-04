import CoreGraphics
import Foundation
import Testing
@testable import TamagotchiCore

/// The notch as Mochi's den: only on notched bars with the setting on, naps out of sight past the
/// housing's edge, a peek when Claude needs you, a burst out to celebrate, and never a teleport.
@Suite("Notch den")
struct NotchDenTests {
    static let den = RoamDen(edgeX: 824.5, inward: -1)
    static let zone = RoamZone(minX: 836.5, maxX: 1_278, homeX: 962, companionX: 938, occupied: [978...1_470], den: den)
    static let plainZone = RoamZone(minX: 836.5, maxX: 1_278, homeX: 962, companionX: 938, occupied: [978...1_470])
    static let maxStep = MenuBarRoamer.Speed.dash / 30 * 1.1 + 0.01

    @discardableResult
    static func simulate(seed: UInt64 = 7, seconds: Double, zone: RoamZone = zone, start: Double = 1_000,
                         context: (Double) -> RoamContext = { _ in RoamContext(notchDen: true) },
                         prepare: (inout MenuBarRoamer, Double) -> Void = { _, _ in },
                         visit: (Double, RoamSample, MenuBarRoamer) -> Void) -> MenuBarRoamer {
        var roamer = MenuBarRoamer(seed: seed)
        roamer.setZone(zone, now: start, context: context(0))
        prepare(&roamer, start)
        var t = start
        var nextTick = start
        while t < start + seconds {
            if t >= nextTick {
                roamer.update(now: t, context: context(t - start))
                nextTick += 0.25
            }
            visit(t - start, roamer.sample(at: t), roamer)
            t += 1.0 / 30
        }
        return roamer
    }

    /// Starts a nap in the den right away (Mochi is tucked in about ten seconds later).
    static func napNow(_ roamer: inout MenuBarRoamer, _ t: Double) {
        roamer.update(now: t + 4, context: RoamContext(notchDen: true))
        roamer.force(.denNap, now: t + 4, context: RoamContext(notchDen: true))
    }

    // MARK: Geometry

    static let screen = CGRect(x: 0, y: 0, width: 1_470, height: 956)
    static let notchLeft = CGRect(x: 0, y: 924, width: 645.5, height: 32)
    static let notchRight = CGRect(x: 824.5, y: 924, width: 645.5, height: 32)

    static func notched(item x: Double, range: Double? = nil, rightToLeft: Bool = false) -> MenuBarGeometry? {
        RoamGeometry.compute(screenFrame: screen, notchLeftArea: notchLeft, notchRightArea: notchRight,
                             barWindowFrame: CGRect(x: x - 8, y: 923, width: 46, height: 33),
                             itemFrame: CGRect(x: x, y: 928.5, width: 30, height: 22), range: range, rightToLeft: rightToLeft)
    }

    @Test func notchedBarsHaveADenRightAtTheHousing() {
        let geometry = Self.notched(item: 947)!
        #expect(geometry.zone.den == RoamDen(edgeX: 824.5, inward: -1))
        // The overlay starts exactly at the housing, so Mochi is cut off right at its edge.
        #expect(geometry.overlayFrame.minX == 824.5)
        // Left of the housing (a crowded bar): the den is on the right, and the overlay reaches it.
        let left = Self.notched(item: 507)!
        #expect(left.zone.den == RoamDen(edgeX: 645.5, inward: 1))
        #expect(left.overlayFrame.maxX == 645.5)
        #expect(left.zone.maxX < 645.5)
        // Right to left: the status items sit left of the housing, with the den on their right.
        let mirrored = Self.notched(item: 470, rightToLeft: true)!
        #expect(mirrored.zone.den == RoamDen(edgeX: 645.5, inward: 1))
        #expect(mirrored.overlayFrame.maxX == 645.5)
        // No notch, or a roaming range that stops short of it: no den.
        let plain = RoamGeometry.compute(screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900), notchRightArea: nil,
                                         barWindowFrame: CGRect(x: 1_100, y: 876, width: 40, height: 24),
                                         itemFrame: CGRect(x: 1_105, y: 877, width: 30, height: 22), range: nil)
        #expect(plain?.zone.den == nil)
        #expect(Self.notched(item: 1_040, range: 200)?.zone.den == nil)
    }

    @Test func onlyTheOpenSideOfTheEdgeShows() {
        let right = RoamDen(edgeX: 824.5, inward: -1)
        #expect(right.visibleSpan(800, 850) == 824.5...850)
        #expect(right.visibleSpan(790, 820) == nil)
        #expect(right.visibleSpan(830, 860) == 830...860)
        let left = RoamDen(edgeX: 645.5, inward: 1)
        #expect(left.visibleSpan(620, 670) == 620...645.5)
        #expect(left.visibleSpan(650, 700) == nil)
        #expect(right.depth(of: 804.5) == 20)
        #expect(left.x(depth: RoamDen.hideDepth) == 665.5)
        #expect(right.shelters(824) && !right.shelters(840))
        // Hidden deep enough that Mochi (about 17 pt wide, tail included) is out of sight.
        #expect(RoamDen.hideDepth > 0.6 * 60 * 0.28)
    }

    // MARK: Naps

    @Test func denNapsNeedTheNotchAndTheSetting() {
        var inDen = 0
        var naps = 0
        Self.simulate(seconds: 4 * 3_600, context: { _ in RoamContext(idleSeconds: 400, notchDen: true) }) { _, sample, _ in
            if sample.activity == .denNap { naps += 1 }
            if Self.den.depth(of: sample.x) >= RoamDen.hideDepth - 0.01 { inDen += 1 }
        }
        #expect(naps > 0)
        #expect(inDen > 0)
        for (zone, setting) in [(Self.zone, false), (Self.plainZone, true)] {
            Self.simulate(seconds: 2 * 3_600, zone: zone, context: { _ in RoamContext(idleSeconds: 400, notchDen: setting) }) { _, sample, _ in
                #expect(sample.activity != .denNap)
                #expect(sample.x >= Self.zone.minX - 0.001)
            }
        }
    }

    @Test func denNapsAreContinuous() {
        var last: RoamSample?
        var deepest = 0.0
        Self.simulate(seconds: 120, prepare: Self.napNow) { _, sample, roamer in
            if let last { #expect(abs(sample.x - last.x) <= Self.maxStep) }
            last = sample
            deepest = max(deepest, Self.den.depth(of: sample.x))
            #expect(Self.zone.holds(sample.x))
            for (a, b) in zip(roamer.segments, roamer.segments.dropFirst()) {
                #expect(abs(b.fromX - a.toX) < 1e-6)
            }
        }
        #expect(abs(deepest - RoamDen.hideDepth) < 0.01)
        // Asleep in there, then out again onto the bar.
        #expect(last.map { Self.zone.canLinger(at: $0.x) || $0.x >= Self.zone.minX } ?? false)
    }

    @Test func peeksOutWhenClaudeNeedsYou() {
        var peeked: Double?
        Self.simulate(seconds: 40, context: { t in
            RoamContext(activity: t >= 14 && t < 30 ? .waiting : .idle, notchDen: true)
        }, prepare: Self.napNow) { t, sample, roamer in
            if t > 18, t < 30 {
                #expect(roamer.mode == .attending)
                #expect(sample.activity == .denPeek)
                #expect(abs(sample.x - Self.den.x(depth: RoamDen.peekDepth)) < 0.01)
                #expect(sample.facing == 1)
                if peeked == nil { peeked = t }
            }
            if t > 36 {
                // Answered: out of the den and back on the bar.
                #expect(sample.activity != .denPeek)
                #expect(Self.den.depth(of: sample.x) < 0)
            }
        }
        #expect(peeked != nil)
    }

    @Test func peeksForABadgeUntilItIsGone() {
        Self.simulate(seconds: 40, context: { t in
            RoamContext(notchDen: true, attentionBadge: t >= 14 && t < 26)
        }, prepare: Self.napNow) { t, sample, _ in
            if t > 18, t < 26 { #expect(sample.activity == .denPeek) }
            if t > 34 { #expect(Self.den.depth(of: sample.x) < -RoamZone.footprint) }
        }
    }

    @Test func burstsOutToCelebrate() {
        var burst = false
        var sparkles = false
        Self.simulate(seconds: 24, context: { t in
            RoamContext(reacting: t >= 14 && t < 16.5, notchDen: true, celebrating: t >= 14 && t < 16.5)
        }, prepare: Self.napNow) { t, sample, _ in
            if t > 14.4, t < 15 { #expect(sample.activity == .denBurst) }
            if sample.activity == .denBurst { burst = true }
            if sample.props.contains(where: { $0.kind == .sparkle }) { sparkles = true }
            if t > 18 { #expect(sample.x >= Self.zone.minX) }
        }
        #expect(burst)
        #expect(sparkles)
    }

    // MARK: Desktop adventures on the bar

    @Test func awayEmptiesTheBedUntilMochiHopsBackUp() {
        var roamer = MenuBarRoamer(seed: 3)
        roamer.setZone(Self.zone, now: 0, context: RoamContext())
        roamer.update(now: 5, context: RoamContext())
        roamer.update(now: 5, context: RoamContext(away: true))
        #expect(roamer.mode == .away)
        let departure = roamer.awayDeparture
        #expect(departure != nil)
        #expect((departure?.time ?? 99) < 7)
        for t in stride(from: (departure?.time ?? 6) + 0.01, to: 60, by: 0.5) {
            roamer.update(now: t, context: RoamContext(away: true))
            #expect(roamer.sample(at: t).opacity == 0)
        }
        roamer.returnFromAdventure(at: 1_200, now: 60, context: RoamContext())
        #expect(roamer.mode == .free)
        #expect(roamer.awayDeparture == nil)
        let back = roamer.sample(at: 60.1)
        #expect(back.x == 1_200)
        #expect(back.lift < 0)
        #expect(roamer.sample(at: 61).opacity == 1)
        // Then home to the bed.
        var reachedHome = false
        for t in stride(from: 60.0, to: 80, by: 0.25) {
            roamer.update(now: t, context: RoamContext())
            if roamer.isHome(at: t) { reachedHome = true }
        }
        #expect(reachedHome)
    }
}

/// The world keeps Mochi's place free while it is out: nothing starts beside Patch, and it comes
/// back through the bar where the last hop lands.
@Suite("Desktop adventures in the world")
@MainActor
struct AdventureWorldTests {
    @Test func interactionsWaitUntilMochiIsBack() {
        let h = WorldHarness()
        h.world.setRoamZone(NotchDenTests.zone)
        h.send("SessionStart")
        h.run(for: 6)
        h.world.setAdventureActive(true)
        h.run(for: 2)
        #expect(h.world.roamer.mode == .away)
        #expect(h.world.roamer.sample(at: h.clock.uptime).opacity == 0)
        #expect(!h.world.startInteraction(.highFive, priority: .critical))
        h.world.setAdventureActive(false, returningAt: 1_100)
        #expect(h.world.roamer.mode != .away)
        #expect(h.world.roamer.sample(at: h.clock.uptime + 0.05).x == 1_100)
        h.run(for: 12)
        #expect(h.world.roamer.sample(at: h.clock.uptime).opacity == 1)
    }
}
