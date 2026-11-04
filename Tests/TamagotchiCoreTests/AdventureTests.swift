import CoreGraphics
import Foundation
import Testing
@testable import TamagotchiCore

/// Mochi's desktop adventures: only window frames go in; out comes a deterministic route that stays
/// on screen, walks on visible window tops, sits on the Dock, climbs the edge nearest home and hops
/// back into the menu bar, re-routed from where Mochi is when windows change.
@Suite("Desktop adventures")
struct AdventureTests {
    /// The measured MacBook: 1470 × 956 pt, a 33 pt menu bar and an 81 pt Dock band.
    static let visible = CGRect(x: 0, y: 81, width: 1_470, height: 842)
    static let dock = 480.0...990.0
    static let bar = 836.5...1_278.0
    /// Front to back, AppKit coordinates (y up).
    static let windows: [CGRect] = [
        CGRect(x: 120, y: 300, width: 640, height: 420),
        CGRect(x: 560, y: 200, width: 700, height: 380),
        CGRect(x: 900, y: 420, width: 420, height: 360),
        CGRect(x: 30, y: 600, width: 60, height: 40),
    ]
    static let start = AdventurePoint(x: 1_000, y: 923 + 50)
    static let metrics = AdventurePlanner.Metrics()

    static func terrain(_ windows: [CGRect] = windows) -> AdventureTerrain {
        AdventureTerrain(bounds: visible, floorY: 81, dock: dock, windows: windows)
    }

    static func plan(seed: UInt64 = 7, terrain: AdventureTerrain = terrain()) -> AdventurePlan {
        AdventurePlanner.plan(from: start, at: 100, terrain: terrain, bar: bar, seed: seed)
    }

    static func samples(_ plan: AdventurePlan, fps: Double = 30) -> [(TimeInterval, AdventureSample)] {
        var result: [(TimeInterval, AdventureSample)] = []
        var t = plan.start
        while t <= plan.end + 0.2 {
            result.append((t, plan.sample(at: t)))
            t += 1 / fps
        }
        return result
    }

    // MARK: Terrain

    @Test func terrainKeepsOnlyVisibleWindowTops() {
        let terrain = Self.terrain()
        // The front window's top whole; the one behind it only right of the front one; the tiny palette not at all.
        #expect(terrain.ledges.contains { $0.window == 0 && $0.y == 720 && $0.minX == 120 && $0.maxX == 760 })
        #expect(terrain.ledges.contains { $0.window == 1 && $0.y == 580 && $0.minX == 764 && $0.maxX == 1_260 })
        #expect(terrain.ledges.contains { $0.window == 2 && $0.y == 780 })
        #expect(!terrain.ledges.contains { $0.window == 3 })
        // Highest first.
        #expect(terrain.ledges.map(\.y) == terrain.ledges.map(\.y).sorted(by: >))

        let tricky = Self.terrain([
            CGRect(x: 100, y: 81, width: 1_000, height: 842),     // maximised: its top is under the menu bar
            CGRect(x: 2_000, y: 300, width: 600, height: 400),    // on another display
            CGRect(x: 300, y: 300, width: 600, height: 400),      // hidden behind the maximised one
        ])
        #expect(tricky.ledges.isEmpty)
    }

    @Test func fullScreenAppsAreRecognised() {
        let screen = CGRect(x: 0, y: 0, width: 1_470, height: 956)
        #expect(AdventureTerrain.looksFullScreen(windows: [screen], screen: screen))
        #expect(!AdventureTerrain.looksFullScreen(windows: Self.windows, screen: screen))
    }

    // MARK: Plans

    @Test func sameSeedSameAdventure() {
        #expect(Self.plan(seed: 3) == Self.plan(seed: 3))
        #expect(Self.plan(seed: 3).segments != Self.plan(seed: 4).segments)
    }

    @Test func continuousFromStartToEnd() {
        for seed in [1, 2, 3, 4, 5] as [UInt64] {
            let plan = Self.plan(seed: seed)
            for (a, b) in zip(plan.segments, plan.segments.dropFirst()) {
                #expect(abs(b.start - a.end) < 1e-9)
                #expect(a.to.distance(to: b.from) < 1e-6)
                #expect(abs(b.turn - a.turnTo) < 1e-9)
            }
            // Never a jump between frames (the fastest moves are falls and the leap home).
            var last: AdventurePoint?
            for (_, sample) in Self.samples(plan) {
                if let last { #expect(last.distance(to: sample.point) < 60) }
                last = sample.point
            }
        }
    }

    @Test func staysOnScreenAndEndsInTheMenuBar() {
        for seed in [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64] {
            let plan = Self.plan(seed: seed)
            for (_, sample) in Self.samples(plan) {
                #expect(sample.point.x >= Self.visible.minX - 0.001 && sample.point.x <= Self.visible.maxX + 0.001)
                #expect(sample.point.y >= 81 - 0.001)
                if sample.point.y > Self.visible.maxY {
                    // Only dropping in out of the menu bar, or hopping back up into it.
                    #expect(sample.phase == .arriving || sample.phase == .returning)
                }
            }
            let last = plan.segments.last!
            #expect(last.phase == .returning && last.move == .hop)
            #expect(last.to.y > Self.visible.maxY + Self.metrics.height)
            #expect(Self.bar.contains(last.to.x))
            #expect(plan.homeX == last.to.x)
            #expect(plan.sample(at: plan.end + 1).finished)
        }
    }

    @Test func walksWindowTopsSitsOnTheDockAndClimbsTheEdgeNearestHome() {
        let terrain = Self.terrain()
        for seed in [1, 2, 3, 4, 5] as [UInt64] {
            let plan = Self.plan(seed: seed)
            // Wherever Mochi stands, something holds it up.
            for segment in plan.segments where (segment.move == .hold || segment.move == .walk) && segment.phase < .climbing {
                #expect(terrain.supports(segment.from, tolerance: 8), "seed \(seed): \(segment)")
            }
            #expect(plan.segments.contains { $0.phase == .exploring && terrain.ledge(at: $0.to, tolerance: 1) != nil })
            #expect(plan.segments.contains { $0.phase == .dock && $0.animation == .sit && $0.from.y == 81 && Self.dock.contains($0.from.x) })
            // Home is on the right of the screen, so up the right edge, facing and leaning into it.
            let climb = plan.segments.first { $0.move == .climb }
            #expect(climb?.from.x == Double(Self.visible.maxX) - Self.metrics.halfWidth * 0.8)
            #expect(climb?.facing == 1)
            #expect(abs((climb?.turn ?? 0) - AdventurePlanner.climbLean) < 1e-9)
            #expect((climb?.to.y ?? 0) > Self.visible.maxY - Self.metrics.height - 10)
        }
    }

    @Test func lastsAboutAMinute() {
        let lone = Self.terrain([CGRect(x: 600, y: 300, width: 500, height: 450)])
        for terrain in [Self.terrain(), lone, Self.terrain([])] {
            for seed in 1...12 as ClosedRange<UInt64> {
                let length = Self.plan(seed: seed, terrain: terrain).end - 100
                #expect(length >= 28 && length <= 100, "seed \(seed): \(length) s")
            }
        }
    }

    @Test func withoutWindowsItStillGoesRoundTheScreen() {
        let plan = Self.plan(terrain: Self.terrain([]))
        #expect(!plan.segments.contains { $0.phase == .exploring && $0.move == .hop })
        #expect(plan.segments.contains { $0.move == .climb })
        #expect(plan.segments.last?.phase == .returning)
        // Dropped from the menu bar straight to the floor, where it strolls a little before the Dock.
        #expect(plan.segments.first?.move == .fall)
        #expect(plan.segments.first?.to.y == 81)
        #expect(plan.segments.contains { $0.phase == .exploring && $0.move == .walk })
        #expect(plan.end - 100 >= 28)
    }

    @Test func leftSideHomesClimbTheLeftEdge() {
        let plan = AdventurePlanner.plan(from: AdventurePoint(x: 300, y: 980), at: 0, terrain: Self.terrain(), bar: 180...600, seed: 9)
        let climb = plan.segments.first { $0.move == .climb }
        #expect(climb?.from.x == Double(Self.visible.minX) + Self.metrics.halfWidth * 0.8)
        #expect(climb?.facing == -1)
        #expect(abs((climb?.turn ?? 0) + AdventurePlanner.climbLean) < 1e-9)
        #expect(plan.homeX == 180)
    }

    // MARK: Changes

    @Test func aWindowClosingUnderMochiMakesItFall() {
        let terrain = Self.terrain()
        for seed in [1, 2, 3, 4] as [UInt64] {
            let plan = Self.plan(seed: seed)
            // A moment when Mochi stands on a window top.
            guard let moment = plan.segments.first(where: { $0.move == .hold && $0.phase == .exploring && $0.duration > 0.5
                && terrain.ledge(at: $0.from) != nil }) else { continue }
            let t = moment.start + moment.duration / 2
            let window = terrain.ledge(at: moment.from)!.window
            var remaining = Self.windows
            remaining.remove(at: window)
            let changed = Self.terrain(remaining)
            let adapted = AdventurePlanner.adapt(plan, at: t, to: changed)
            #expect(adapted != nil)
            guard let adapted else { continue }
            // Right where it was, then down.
            #expect(adapted.sample(at: t).point.distance(to: plan.sample(at: t).point) < 1e-6)
            #expect(adapted.segments.first { $0.start >= t - 1e-9 }?.move == .fall)
            // From here on it only stands where something holds it up.
            for segment in adapted.segments where segment.start >= t && (segment.move == .hold || segment.move == .walk) && segment.phase < .climbing {
                #expect(changed.supports(segment.from, tolerance: 8))
            }
            #expect(adapted.segments.last?.phase == .returning)
            #expect(Self.bar.contains(adapted.homeX))
            for (a, b) in zip(adapted.segments, adapted.segments.dropFirst()) {
                #expect(a.to.distance(to: b.from) < 1e-6)
                #expect(abs(b.start - a.end) < 1e-9)
            }
        }
    }

    @Test func unchangedGroundKeepsThePlan() {
        let plan = Self.plan(seed: 2)
        #expect(AdventurePlanner.adapt(plan, at: 105, to: Self.terrain()) == nil)
        // On the way up the wall nothing about windows matters.
        let climb = plan.segments.first { $0.move == .climb }!
        #expect(AdventurePlanner.adapt(plan, at: climb.start + 0.5, to: Self.terrain([])) == nil)
    }

    @Test func hurryingHomeIsOneLeap() {
        let plan = Self.plan(seed: 5)
        let t = 112.0
        let hurried = AdventurePlanner.hurryHome(plan, at: t, terrain: Self.terrain())
        #expect(hurried.sample(at: t).point.distance(to: plan.sample(at: t).point) < 1e-6)
        #expect(hurried.end - t < 1.6)
        #expect(hurried.segments.last?.phase == .returning)
        #expect(Self.bar.contains(hurried.homeX))
        for (a, b) in zip(hurried.segments, hurried.segments.dropFirst()) {
            #expect(a.to.distance(to: b.from) < 1e-6)
        }
        // Straight up from where it is, as far as the bar allows.
        let x = plan.sample(at: t).point.x
        #expect(hurried.homeX == min(Self.bar.upperBound, max(Self.bar.lowerBound, x)))
    }

    @Test func pettingPausesWhereMochiStands() {
        let plan = Self.plan(seed: 6)
        let walk = plan.segments.first { $0.move == .walk && $0.phase == .dock }!
        let t = walk.start + walk.duration / 2
        let petted = AdventurePlanner.interject(.happyBounce, into: plan, at: t)!
        let here = plan.sample(at: t).point
        #expect(petted.sample(at: t + 0.5).animation == .happyBounce)
        #expect(petted.sample(at: t + 0.5).point.distance(to: here) < 1e-6)
        #expect(abs(petted.end - plan.end - PetAnimation.happyBounce.defaultDuration) < 1e-9)
        for (a, b) in zip(petted.segments, petted.segments.dropFirst()) {
            #expect(abs(b.start - a.end) < 1e-9)
            #expect(a.to.distance(to: b.from) < 1e-6)
        }
        // Not in mid-air, and not on the wall.
        let hop = plan.segments.first { $0.move == .hop }!
        #expect(AdventurePlanner.interject(.happyBounce, into: plan, at: hop.start + hop.duration / 2) == nil)
        let climb = plan.segments.first { $0.move == .climb }!
        #expect(AdventurePlanner.interject(.happyBounce, into: plan, at: climb.start + 1) == nil)
    }

    // MARK: Spontaneous adventures

    static func triggers(_ frequency: AdventureFrequency, seed: UInt64 = 1, hours: Double, eligible: (Double) -> Bool = { _ in true }) -> [Double] {
        var scheduler = AdventureScheduler(seed: seed, frequency: frequency)
        var result: [Double] = []
        var t = 0.0
        while t < hours * 3_600 {
            if scheduler.tick(now: t, eligible: eligible(t), frequency: frequency) { result.append(t) }
            t += 1
        }
        return result
    }

    @Test func spontaneousAdventuresFollowTheFrequency() {
        let sometimes = Self.triggers(.sometimes, hours: 10)
        let rarely = Self.triggers(.rarely, hours: 10)
        #expect(sometimes.count >= 10 && sometimes.count <= 13)
        #expect(rarely.count >= 3 && rarely.count <= 5)
        #expect(Self.triggers(.never, hours: 10).isEmpty)
        for (a, b) in zip(sometimes, sometimes.dropFirst()) { #expect(b - a >= 45 * 60 - 1 && b - a <= 60 * 60 + 1) }
        // Deterministic per seed.
        #expect(Self.triggers(.sometimes, seed: 4, hours: 5) == Self.triggers(.sometimes, seed: 4, hours: 5))
        #expect(Self.triggers(.sometimes, seed: 4, hours: 5) != Self.triggers(.sometimes, seed: 5, hours: 5))
    }

    @Test func onlyIdleTimeCounts() {
        #expect(Self.triggers(.sometimes, hours: 6) { _ in false }.isEmpty)
        // Busy every other half hour: about half the pace.
        let half = Self.triggers(.sometimes, hours: 10) { Int($0 / 1_800) % 2 == 0 }
        #expect(half.count >= 4 && half.count <= 7)
        // A long gap (the Mac slept) counts for a few seconds only.
        var scheduler = AdventureScheduler(seed: 1, frequency: .sometimes)
        _ = scheduler.tick(now: 0, eligible: true, frequency: .sometimes)
        let fired = scheduler.tick(now: 10 * 3_600, eligible: true, frequency: .sometimes)
        #expect(!fired)
        #expect(scheduler.accumulated <= AdventureScheduler.maxStep)
    }
}
