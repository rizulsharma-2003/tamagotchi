// W19: Mochi's desktop adventures, ported from Tests/TamagotchiCoreTests/AdventureTests.swift. Only window frames go in;
// out comes a deterministic route that stays on screen, walks on visible window tops, sits on the Dock, climbs the edge
// nearest home and hops back out of the top, re-routed from where Mochi is when windows change.

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

// The measured MacBook: 1470 × 956 pt, a 33 pt menu bar and an 81 pt Dock band.
const visible = AdventureRect(0, 81, 1470, 842);
const dock = AdventureSpan(480, 990);
const bar = AdventureSpan(836.5, 1278);

// Front to back, AppKit coordinates (y up).
const windows = [
  AdventureRect(120, 300, 640, 420),
  AdventureRect(560, 200, 700, 380),
  AdventureRect(900, 420, 420, 360),
  AdventureRect(30, 600, 60, 40),
];
const start = AdventurePoint(1000, 923 + 50);

AdventureTerrain terrainOf([List<AdventureRect> list = windows]) => AdventureTerrain(bounds: visible, floorY: 81, dock: dock, windows: list);

AdventurePlan planOf({int seed = 7, AdventureTerrain? terrain}) =>
    AdventurePlanner.plan(from: start, at: 100, terrain: terrain ?? terrainOf(), bar: bar, seed: seed);

List<(double, AdventureSample)> samplesOf(AdventurePlan plan, {double fps = 30}) {
  final result = <(double, AdventureSample)>[];
  var t = plan.start;
  while (t <= plan.end + 0.2) {
    result.add((t, plan.sample(t)));
    t += 1 / fps;
  }
  return result;
}

double _min(double a, double b) => a < b ? a : b;
double _max(double a, double b) => a > b ? a : b;

void main() {
  final metrics = AdventureMetrics();

  group('terrain', () {
    test('keeps only visible window tops', () {
      final terrain = terrainOf();
      // The front window's top whole; the one behind it only right of the front one; the tiny palette not at all.
      expect(terrain.ledges.any((l) => l.window == 0 && l.y == 720 && l.minX == 120 && l.maxX == 760), isTrue);
      expect(terrain.ledges.any((l) => l.window == 1 && l.y == 580 && l.minX == 764 && l.maxX == 1260), isTrue);
      expect(terrain.ledges.any((l) => l.window == 2 && l.y == 780), isTrue);
      expect(terrain.ledges.any((l) => l.window == 3), isFalse);
      // Highest first.
      final ys = terrain.ledges.map((l) => l.y).toList();
      expect(ys, [...ys]..sort((a, b) => b.compareTo(a)));

      final tricky = terrainOf(const [
        AdventureRect(100, 81, 1000, 842), // maximised: its top is under the menu bar
        AdventureRect(2000, 300, 600, 400), // on another display
        AdventureRect(300, 300, 600, 400), // hidden behind the maximised one
      ]);
      expect(tricky.ledges, isEmpty);
    });

    test('full-screen apps are recognised', () {
      const screen = AdventureRect(0, 0, 1470, 956);
      expect(AdventureTerrain.looksFullScreen(windows: const [screen], screen: screen), isTrue);
      expect(AdventureTerrain.looksFullScreen(windows: windows, screen: screen), isFalse);
    });

    test('a terrain is equal to another made from the same windows, and not from others', () {
      expect(terrainOf(), terrainOf());
      expect(terrainOf(), isNot(terrainOf(windows.sublist(1))));
    });
  });

  group('plans', () {
    test('the same seed gives the same adventure', () {
      expect(planOf(seed: 3).segments, planOf(seed: 3).segments);
      expect(planOf(seed: 3).segments, isNot(planOf(seed: 4).segments));
    });

    test('continuous from start to end', () {
      for (final seed in [1, 2, 3, 4, 5]) {
        final plan = planOf(seed: seed);
        for (var i = 1; i < plan.segments.length; i++) {
          final a = plan.segments[i - 1], b = plan.segments[i];
          expect((b.start - a.end).abs(), lessThan(1e-9));
          expect(a.to.distanceTo(b.from), lessThan(1e-6));
          expect((b.turn - a.turnTo).abs(), lessThan(1e-9));
        }
        // Never a jump between frames (the fastest moves are falls and the leap home).
        AdventurePoint? last;
        for (final (_, sample) in samplesOf(plan)) {
          if (last != null) expect(last.distanceTo(sample.point), lessThan(60));
          last = sample.point;
        }
      }
    });

    test('stays on screen and ends by hopping out of the top', () {
      for (final seed in [1, 2, 3, 4, 5, 6, 7, 8]) {
        final plan = planOf(seed: seed);
        for (final (_, sample) in samplesOf(plan)) {
          expect(sample.point.x, inInclusiveRange(visible.minX - 0.001, visible.maxX + 0.001));
          expect(sample.point.y, greaterThanOrEqualTo(81 - 0.001));
          if (sample.point.y > visible.maxY) {
            // Only dropping in from the top, or hopping back up out of it.
            expect(sample.phase == AdventurePhase.arriving || sample.phase == AdventurePhase.returning, isTrue);
          }
        }
        final last = plan.segments.last;
        expect(last.phase, AdventurePhase.returning);
        expect(last.move, AdventureMove.hop);
        expect(last.to.y, greaterThan(visible.maxY + metrics.height));
        expect(bar.contains(last.to.x), isTrue);
        expect(plan.homeX, last.to.x);
        expect(plan.sample(plan.end + 1).finished, isTrue);
      }
    });

    test('walks window tops, sits on the Dock and climbs the edge nearest home', () {
      final terrain = terrainOf();
      for (final seed in [1, 2, 3, 4, 5]) {
        final plan = planOf(seed: seed);
        // Wherever Mochi stands, something holds it up.
        for (final s in plan.segments) {
          if ((s.move == AdventureMove.hold || s.move == AdventureMove.walk) && s.phase < AdventurePhase.climbing) {
            expect(terrain.supports(s.from, tolerance: 8), isTrue, reason: 'seed $seed: $s');
          }
        }
        expect(plan.segments.any((s) => s.phase == AdventurePhase.exploring && terrain.ledge(s.to, tolerance: 1) != null), isTrue);
        expect(plan.segments.any((s) => s.phase == AdventurePhase.dock && s.animation == PetAnimation.sit && s.from.y == 81 && dock.contains(s.from.x)), isTrue);
        // Home is on the right of the screen, so up the right edge, facing and leaning into it.
        final climb = plan.segments.firstWhere((s) => s.move == AdventureMove.climb);
        expect(climb.from.x, visible.maxX - metrics.halfWidth * 0.8);
        expect(climb.facing, 1);
        expect((climb.turn - AdventurePlanner.climbLean).abs(), lessThan(1e-9));
        expect(climb.to.y, greaterThan(visible.maxY - metrics.height - 10));
      }
    });

    test('lasts about a minute', () {
      final lone = terrainOf(const [AdventureRect(600, 300, 500, 450)]);
      for (final terrain in [terrainOf(), lone, terrainOf(const [])]) {
        for (var seed = 1; seed <= 12; seed++) {
          final length = planOf(seed: seed, terrain: terrain).end - 100;
          expect(length, inInclusiveRange(28, 100), reason: 'seed $seed: $length s');
        }
      }
    });

    test('without windows it still goes round the screen', () {
      final plan = planOf(terrain: terrainOf(const []));
      expect(plan.segments.any((s) => s.phase == AdventurePhase.exploring && s.move == AdventureMove.hop), isFalse);
      expect(plan.segments.any((s) => s.move == AdventureMove.climb), isTrue);
      expect(plan.segments.last.phase, AdventurePhase.returning);
      // Dropped from the top straight to the floor, where it strolls a little before the Dock.
      expect(plan.segments.first.move, AdventureMove.fall);
      expect(plan.segments.first.to.y, 81);
      expect(plan.segments.any((s) => s.phase == AdventurePhase.exploring && s.move == AdventureMove.walk), isTrue);
      expect(plan.end - 100, greaterThanOrEqualTo(28));
    });

    test('a left-side home climbs the left edge', () {
      final plan = AdventurePlanner.plan(from: const AdventurePoint(300, 980), at: 0, terrain: terrainOf(), bar: const AdventureSpan(180, 600), seed: 9);
      final climb = plan.segments.firstWhere((s) => s.move == AdventureMove.climb);
      expect(climb.from.x, visible.minX + metrics.halfWidth * 0.8);
      expect(climb.facing, -1);
      expect((climb.turn + AdventurePlanner.climbLean).abs(), lessThan(1e-9));
      expect(plan.homeX, 180);
    });
  });

  group('changes', () {
    test('a window closing under Mochi makes it fall', () {
      final terrain = terrainOf();
      for (final seed in [1, 2, 3, 4]) {
        final plan = planOf(seed: seed);
        // A moment when Mochi stands on a window top.
        final moment = plan.segments
            .where((s) => s.move == AdventureMove.hold && s.phase == AdventurePhase.exploring && s.duration > 0.5 && terrain.ledge(s.from) != null)
            .firstOrNull;
        if (moment == null) continue;
        final t = moment.start + moment.duration / 2;
        final window = terrain.ledge(moment.from)!.window;
        final remaining = [...windows]..removeAt(window);
        final changed = terrainOf(remaining);
        final adapted = AdventurePlanner.adapt(plan, at: t, to: changed);
        expect(adapted, isNotNull);
        if (adapted == null) continue;
        // Right where it was, then down.
        expect(adapted.sample(t).point.distanceTo(plan.sample(t).point), lessThan(1e-6));
        expect(adapted.segments.firstWhere((s) => s.start >= t - 1e-9).move, AdventureMove.fall);
        // From here on it only stands where something holds it up.
        for (final s in adapted.segments) {
          if (s.start >= t && (s.move == AdventureMove.hold || s.move == AdventureMove.walk) && s.phase < AdventurePhase.climbing) {
            expect(changed.supports(s.from, tolerance: 8), isTrue);
          }
        }
        expect(adapted.segments.last.phase, AdventurePhase.returning);
        expect(bar.contains(adapted.homeX), isTrue);
        for (var i = 1; i < adapted.segments.length; i++) {
          final a = adapted.segments[i - 1], b = adapted.segments[i];
          expect(a.to.distanceTo(b.from), lessThan(1e-6));
          expect((b.start - a.end).abs(), lessThan(1e-9));
        }
      }
    });

    test('unchanged ground keeps the plan', () {
      final plan = planOf(seed: 2);
      expect(AdventurePlanner.adapt(plan, at: 105, to: terrainOf()), isNull);
      // On the way up the wall nothing about windows matters.
      final climb = plan.segments.firstWhere((s) => s.move == AdventureMove.climb);
      expect(AdventurePlanner.adapt(plan, at: climb.start + 0.5, to: terrainOf(const [])), isNull);
    });

    test('hurrying home is one leap', () {
      final plan = planOf(seed: 5);
      const t = 112.0;
      final hurried = AdventurePlanner.hurryHome(plan, at: t, terrain: terrainOf());
      expect(hurried.sample(t).point.distanceTo(plan.sample(t).point), lessThan(1e-6));
      expect(hurried.end - t, lessThan(1.6));
      expect(hurried.segments.last.phase, AdventurePhase.returning);
      expect(bar.contains(hurried.homeX), isTrue);
      for (var i = 1; i < hurried.segments.length; i++) {
        expect(hurried.segments[i - 1].to.distanceTo(hurried.segments[i].from), lessThan(1e-6));
      }
      // Straight up from where it is, as far as the bar allows.
      final x = plan.sample(t).point.x;
      expect(hurried.homeX, _min(bar.upper, _max(bar.lower, x)));
    });

    test('petting pauses where Mochi stands', () {
      final plan = planOf(seed: 6);
      final walk = plan.segments.firstWhere((s) => s.move == AdventureMove.walk && s.phase == AdventurePhase.dock);
      final t = walk.start + walk.duration / 2;
      final petted = AdventurePlanner.interject(PetAnimation.happyBounce, into: plan, at: t)!;
      final here = plan.sample(t).point;
      expect(petted.sample(t + 0.5).animation, PetAnimation.happyBounce);
      expect(petted.sample(t + 0.5).point.distanceTo(here), lessThan(1e-6));
      expect((petted.end - plan.end - PetAnimation.happyBounce.defaultDuration).abs(), lessThan(1e-9));
      for (var i = 1; i < petted.segments.length; i++) {
        expect((petted.segments[i].start - petted.segments[i - 1].end).abs(), lessThan(1e-9));
        expect(petted.segments[i - 1].to.distanceTo(petted.segments[i].from), lessThan(1e-6));
      }
      // Not in mid-air, and not on the wall.
      final hop = plan.segments.firstWhere((s) => s.move == AdventureMove.hop);
      expect(AdventurePlanner.interject(PetAnimation.happyBounce, into: plan, at: hop.start + hop.duration / 2), isNull);
      final climb = plan.segments.firstWhere((s) => s.move == AdventureMove.climb);
      expect(AdventurePlanner.interject(PetAnimation.happyBounce, into: plan, at: climb.start + 1), isNull);
    });
  });

  group('spontaneous adventures', () {
    List<double> triggers(AdventureFrequency frequency, {int seed = 1, required double hours, bool Function(double)? eligible}) {
      final scheduler = AdventureScheduler(seed: seed, frequency: frequency);
      final result = <double>[];
      for (var t = 0.0; t < hours * 3600; t += 1) {
        if (scheduler.tick(now: t, eligible: eligible?.call(t) ?? true, frequency: frequency)) result.add(t);
      }
      return result;
    }

    test('follow the frequency', () {
      final sometimes = triggers(AdventureFrequency.sometimes, hours: 10);
      final rarely = triggers(AdventureFrequency.rarely, hours: 10);
      expect(sometimes.length, inInclusiveRange(10, 13));
      expect(rarely.length, inInclusiveRange(3, 5));
      expect(triggers(AdventureFrequency.never, hours: 10), isEmpty);
      for (var i = 1; i < sometimes.length; i++) {
        final gap = sometimes[i] - sometimes[i - 1];
        expect(gap, inInclusiveRange(45 * 60 - 1, 60 * 60 + 1));
      }
      // Deterministic per seed.
      expect(triggers(AdventureFrequency.sometimes, seed: 4, hours: 5), triggers(AdventureFrequency.sometimes, seed: 4, hours: 5));
      expect(triggers(AdventureFrequency.sometimes, seed: 4, hours: 5), isNot(triggers(AdventureFrequency.sometimes, seed: 5, hours: 5)));
    });

    test('only idle time counts', () {
      expect(triggers(AdventureFrequency.sometimes, hours: 6, eligible: (_) => false), isEmpty);
      // Busy every other half hour: about half the pace.
      final half = triggers(AdventureFrequency.sometimes, hours: 10, eligible: (t) => (t / 1800).floor() % 2 == 0);
      expect(half.length, inInclusiveRange(4, 7));
      // A long gap (the PC slept) counts for a few seconds only.
      final scheduler = AdventureScheduler(seed: 1, frequency: AdventureFrequency.sometimes);
      scheduler.tick(now: 0, eligible: true, frequency: AdventureFrequency.sometimes);
      final fired = scheduler.tick(now: 10 * 3600, eligible: true, frequency: AdventureFrequency.sometimes);
      expect(fired, isFalse);
      expect(scheduler.accumulated, lessThanOrEqualTo(AdventureScheduler.maxStep));
    });

    test('the settings keep the Mac keys and defaults', () {
      expect(const AdventureSettings().toJson(), {'enabled': true, 'spontaneous': 'sometimes'});
      final back = AdventureSettings.fromJson({'enabled': false, 'spontaneous': 'rarely'});
      expect(back.enabled, isFalse);
      expect(back.spontaneous, AdventureFrequency.rarely);
      expect(AdventureSettings.fromJson(null), const AdventureSettings());
      expect(AdventureSettings.fromJson({'spontaneous': 'daily'}).spontaneous, AdventureFrequency.sometimes);
      expect(AdventureFrequency.never.title, 'Never');
    });
  });
}
