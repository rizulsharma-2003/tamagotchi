// Mochi's stroll plan (ui/pet/stroller.dart), run on a fake clock: it walks along the whole taskbar, over the buttons, but
// rests and naps only in the free stretches, turns at their ends, goes to another stretch on foot (it fades there only
// with animation effects off), stops for you when Claude needs you, and holds still for a moment. Plus how often the
// pet is drawn, and the recorded one-shots' lengths.

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';

const left = StrollLine(190, 680);
const right = StrollLine(1236, 1600);
const zones = [left, right];

bool inZone(double x) => zones.any((zone) => x >= zone.minX - 0.01 && x <= zone.maxX + 0.01);

/// Runs [stroller] from [from] to [to] seconds in [step]s, in [mode], collecting every segment it planned.
Set<StrollSegment> run(Stroller stroller, double from, double to, {StrollMode mode = StrollMode.free, double idle = 0, double step = 0.25}) {
  final seen = <StrollSegment>{};
  for (var t = from; t <= to; t += step) {
    stroller.update(t, mode: mode, idleSeconds: idle);
    seen.addAll(stroller.segments);
  }
  return seen;
}

void main() {
  group('Walking', () {
    test('walks over the buttons but only stops (rests, sits, naps, fidgets) in the free stretches, with any dice', () {
      var crossings = 0;
      for (var seed = 0; seed < 12; seed++) {
        final stroller = Stroller(random: Random(seed))..place(zones, now: 0, x: 300);
        final seen = <StrollSegment>{};
        for (var t = 0.0; t < 1800; t += 0.5) {
          stroller.update(t, mode: StrollMode.free);
          seen.addAll(stroller.segments);
          final sample = stroller.sample(t);
          if (!sample.travelling) expect(inZone(sample.x), isTrue, reason: 'seed $seed at $t: ${sample.x} lingers over a button');
          // On the taskbar all the way: never past the first stretch or the last.
          expect(sample.x, inInclusiveRange(left.minX - 0.01, right.maxX + 0.01));
        }
        for (final segment in seen) {
          // Every piece starts and ends in free room (what happens between is the walk's).
          expect(inZone(segment.fromX) && inZone(segment.toX), isTrue, reason: '$segment');
          if (segment.travels && !segment.crosses && !segment.hop) {
            // A walk that doesn't cross the buttons keeps to one stretch.
            expect(zones.any((zone) => [segment.fromX, segment.toX].every((x) => x >= zone.minX - 0.01 && x <= zone.maxX + 0.01)), isTrue);
          }
          if (segment.crosses && (segment.fromX < left.maxX) != (segment.toX < left.maxX)) crossings++;
        }
        expect(seen.any((segment) => segment.travels && !segment.hop), isTrue, reason: 'seed $seed walks');
      }
      expect(crossings, greaterThan(0), reason: 'it walked from one stretch to the other');
    });

    test('turns round at the end of a stretch, and walks at an amble with the walk cycle', () {
      var turns = 0;
      for (var seed = 0; seed < 12; seed++) {
        final stroller = Stroller(random: Random(seed))..place(zones, now: 0, x: 300);
        final seen = run(stroller, 0, 1800, step: 0.5).toList()..sort((a, b) => a.start.compareTo(b.start));
        for (var i = 0; i < seen.length - 1; i++) {
          final walk = seen[i];
          // (A pounce or a leap that carries Mochi forward a step is the play's; test/stroll_play_test.dart.)
          if (!walk.travels || walk.hop || walk.oneShot) continue;
          expect(walk.animation, anyOf(PetAnimation.walk, PetAnimation.run));
          expect(walk.facing, walk.toX > walk.fromX ? 1 : -1, reason: 'faces the way it walks');
          final speed = (walk.toX - walk.fromX).abs() / (walk.end - walk.start);
          // (The play sprints: zoomies and chasing a toy go faster, as the Mac's do; test/stroll_play_test.dart.)
          const play = {StrollActivity.zoomies, StrollActivity.butterfly, StrollActivity.ball, StrollActivity.yarn, StrollActivity.leaf};
          if (!play.contains(walk.activity)) expect(speed, lessThanOrEqualTo(const StrollTuning().trotSpeed + 0.01));
          // (Heading into the end of a stretch; a walk over the buttons ends at the near edge of the one it reaches.)
          final atEnd = zones.any((zone) => (walk.toX - (walk.facing > 0 ? zone.maxX : zone.minX)).abs() < 0.01);
          if (atEnd) {
            final next = seen[i + 1];
            expect(next.facing, -walk.facing, reason: 'turns round at the end of the stretch');
            expect(next.style, StrollStyle.notice);
            turns++;
          }
        }
      }
      expect(turns, greaterThan(0));
    });

    test('rests between outings (sitting or standing, with a glance now and then)', () {
      final stroller = Stroller(random: Random(3))..place(zones, now: 0, x: 400);
      final seen = run(stroller, 0, 1200);
      final rests = seen.where((segment) => segment.activity == StrollActivity.rest && !segment.travels);
      expect(rests.map((segment) => segment.animation).toSet(), containsAll([PetAnimation.idle, PetAnimation.sit]));
      // Outings and rests add up to long still stretches: walking is the smaller part of the time.
      final walking = seen.where((segment) => segment.travels).fold<double>(0, (sum, segment) => sum + segment.end - segment.start);
      expect(walking, lessThan(1200 * 0.5));
      expect(walking, greaterThan(1200 * 0.03));
    });

    test('a trip to the other stretch is a walk (a trot when far) over the buttons, with no fade', () {
      var trips = 0;
      for (var seed = 0; seed < 12; seed++) {
        final stroller = Stroller(random: Random(seed))..place(zones, now: 0, x: 300);
        final seen = run(stroller, 0, 1800, step: 0.5);
        expect(seen.where((segment) => segment.hop), isEmpty, reason: 'seed $seed fades');
        for (final trip in seen.where((segment) => segment.crosses && segment.travels && (segment.fromX < left.maxX) != (segment.toX < left.maxX))) {
          trips++;
          expect(trip.animation, anyOf(PetAnimation.walk, PetAnimation.run));
          expect(trip.opacityAt((trip.start + trip.end) / 2), 1, reason: 'in plain sight all the way');
          final middle = trip.xAt((trip.start + trip.end) / 2);
          expect(middle, inInclusiveRange(min(trip.fromX, trip.toX), max(trip.fromX, trip.toX)), reason: 'on the way');
        }
      }
      expect(trips, greaterThan(0));
    });

    test('with animation effects off Mochi fades to its new stretch instead (as the Mac does with Reduce Motion)', () {
      final stroller = Stroller(random: Random(1))..place(zones, now: 0, x: 300, mode: StrollMode.still);
      // The buttons moved: where it stood is no longer free.
      stroller.place(const [right], now: 10);
      final hop = stroller.segments.firstWhere((segment) => segment.hop);
      expect(hop.toX, right.minX, reason: 'the nearest free spot');
      expect(hop.opacityAt((hop.start + hop.end) / 2), closeTo(0, 0.01));
      expect(hop.opacityAt(hop.start + 0.01), greaterThan(0.9));
      expect(hop.xAt((hop.start + hop.end) / 2 - 0.01), hop.fromX, reason: 'still where it was until it has faded out');
      expect(hop.xAt((hop.start + hop.end) / 2 + 0.01), hop.toX);
      // The same in free mode is a walk.
      final walker = Stroller(random: Random(1))..place(zones, now: 0, x: 300);
      walker.place(const [right], now: 10);
      final walk = walker.segments.firstWhere((segment) => segment.travels);
      expect((walk.hop, walk.crosses, walk.animation == PetAnimation.walk || walk.animation == PetAnimation.run), (false, true, true));
    });

    test('one stretch only: nowhere to cross to, no fades', () {
      final stroller = Stroller(random: Random(1))..place([left], now: 0, x: 300);
      final seen = run(stroller, 0, 1800);
      expect(seen.where((segment) => segment.hop), isEmpty);
      for (final segment in seen) {
        expect(segment.fromX >= left.minX - 0.01 && segment.toX <= left.maxX + 0.01, isTrue);
      }
    });

    test('wandering picks places anywhere free on the taskbar: every stretch is visited, each in turn as often as it is long', () {
      const three = [StrollLine(190, 500), StrollLine(700, 1000), StrollLine(1300, 1900)];
      final visits = List.filled(three.length, 0.0);
      for (var seed = 0; seed < 30; seed++) {
        final stroller = Stroller(random: Random(seed))..place(three, now: 0, x: 300);
        for (final segment in run(stroller, 0, 3600, step: 0.5)) {
          if (segment.activity != StrollActivity.wander || !segment.travels || segment.oneShot) continue;
          final index = three.indexWhere((zone) => segment.toX >= zone.minX - 0.01 && segment.toX <= zone.maxX + 0.01);
          expect(index, isNonNegative, reason: 'a free spot: ${segment.toX}');
          visits[index]++;
        }
      }
      expect(visits.every((count) => count > 20), isTrue, reason: '$visits');
      // The longest stretch is the likeliest.
      expect(visits[2], greaterThan(visits[1]));
    });

    test('naps, more the longer Claude has been quiet', () {
      int naps(double idle) {
        var count = 0;
        for (var seed = 0; seed < 16; seed++) {
          final stroller = Stroller(random: Random(seed))..place(zones, now: 0, x: 300);
          count += run(stroller, 0, 3600, idle: idle, step: 1).where((segment) => segment.animation == PetAnimation.curl).length;
        }
        return count;
      }

      final busy = naps(0);
      final quiet = naps(1000);
      expect(quiet, greaterThan(busy));
    });

    test('free stretches that move: a plan still inside them carries on; otherwise Mochi hops into one', () {
      final stroller = Stroller(random: Random(2))..place(zones, now: 0, x: 300);
      run(stroller, 0, 5);
      final plan = stroller.segments;
      stroller.rezone([const StrollLine(150, 700), right], now: 5);
      expect(stroller.segments, plan, reason: 'a wider stretch changes nothing');
      stroller.rezone([const StrollLine(900, 1100)], now: 6);
      run(stroller, 6, 30);
      expect(stroller.sample(30).x, inInclusiveRange(900, 1100));
    });
  });

  group('Claude', () {
    test('needs you: Mochi stops where it is, faces you and waves, then watches you with a wave a minute', () {
      final stroller = Stroller(random: Random(5))..place(zones, now: 0, x: 300);
      // Until it's walking.
      var t = 0.0;
      while (!stroller.travellingAt(t)) {
        t += 0.1;
        stroller.update(t, mode: StrollMode.free);
      }
      t += 0.5;
      stroller.update(t, mode: StrollMode.free);
      final there = stroller.sample(t).x;
      stroller.update(t, mode: StrollMode.attending);
      final first = stroller.sample(t);
      expect(first.x, closeTo(there, 0.01));
      expect(first.animation, PetAnimation.waveGently);
      expect(first.style, StrollStyle.attentive);
      expect(first.travelling, isFalse);
      for (var u = t; u < t + 900; u += 1) {
        stroller.update(u, mode: StrollMode.attending);
        final sample = stroller.sample(u);
        expect(sample.travelling, isFalse);
        expect(sample.x, closeTo(there, 0.01));
        expect(sample.style, StrollStyle.attentive);
      }
      stroller.update(t + 20, mode: StrollMode.attending);
      expect(stroller.sample(t + 20).animation, PetAnimation.sit);
      expect(stroller.nextChange(t + 900), isNull, reason: 'nothing to wake up for');
    });

    test('works: Mochi mostly sits and watches, with a short potter now and then', () {
      final stroller = Stroller(random: Random(8))..place(zones, now: 0, x: 400);
      final seen = run(stroller, 0, 1800, mode: StrollMode.working);
      final watching = seen.where((segment) => segment.animation == PetAnimation.watch).fold<double>(0, (sum, s) => sum + s.end - s.start);
      expect(watching, greaterThan(1800 * 0.6));
      for (final walk in seen.where((segment) => segment.travels)) {
        expect((walk.toX - walk.fromX).abs(), lessThanOrEqualTo(150.01));
      }
    });

    test('a long quiet stretch: a yawn, then it sleeps where it is (and nothing wakes the timer)', () {
      final stroller = Stroller(random: Random(4))..place(zones, now: 0, x: 400);
      stroller.update(10, mode: StrollMode.asleep);
      expect(stroller.sample(10).animation, PetAnimation.yawn);
      stroller.update(15, mode: StrollMode.asleep);
      expect(stroller.sample(15).animation, PetAnimation.sleep);
      expect(stroller.nextChange(15), isNull);
      expect(run(stroller, 15, 600, mode: StrollMode.asleep).where((segment) => segment.travels), isEmpty);
    });

    test('animation effects off: Mochi stays put', () {
      final stroller = Stroller(random: Random(6))..place(zones, now: 0, x: 400);
      final seen = run(stroller, 0, 1200, mode: StrollMode.still);
      expect(seen.where((segment) => segment.travels), isEmpty);
      expect(stroller.sample(1200).x, 400);
    });

    test('a finished turn: Mochi holds still facing you while it celebrates, then carries on (a mode change waits)', () {
      final stroller = Stroller(random: Random(9))..place(zones, now: 0, x: 400);
      run(stroller, 0, 30, mode: StrollMode.working);
      final x = stroller.sample(30).x;
      stroller.react(30, 2.6, attentive: true);
      stroller.update(30.5, mode: StrollMode.free);
      final during = stroller.sample(31);
      expect(during.activity, StrollActivity.react);
      expect(during.style, StrollStyle.attentive);
      expect(during.x, x);
      expect(stroller.nextChange(31), lessThanOrEqualTo(32.6));
      stroller.update(32.7, mode: StrollMode.free);
      expect(stroller.sample(32.8).activity, isNot(StrollActivity.react));
      expect(stroller.mode, StrollMode.free);
    });

    test('mode from the mood', () {
      expect(StrollMode.of(PetMood.needsYou, reducedMotion: true), StrollMode.attending);
      expect(StrollMode.of(PetMood.napping, reducedMotion: false), StrollMode.asleep);
      expect(StrollMode.of(PetMood.relaxed, reducedMotion: true), StrollMode.still);
      expect(StrollMode.of(PetMood.watching, reducedMotion: false), StrollMode.working);
      expect(StrollMode.of(PetMood.happy, reducedMotion: false), StrollMode.free);
    });
  });

  test('a drag holds Mochi still until it\'s let go', () {
    final stroller = Stroller(random: Random(11))..place(zones, now: 0, x: 400);
    run(stroller, 0, 20);
    final x = stroller.sample(20).x;
    stroller.react(20, double.infinity);
    expect(run(stroller, 20, 200).where((segment) => segment.end > 20 && segment.travels), isEmpty);
    expect(stroller.sample(200).x, x);
    stroller.resume(200);
    expect(run(stroller, 200, 600).where((segment) => segment.travels), isNotEmpty);
  });

  test('the walk cycle follows the distance walked, so the feet keep pace with the ground', () {
    final stroller = Stroller(random: Random(5))..place(zones, now: 0, x: 300);
    var t = 0.0;
    while (!stroller.travellingAt(t) || stroller.sample(t).animation != PetAnimation.walk) {
      t += 0.05;
      stroller.update(t, mode: StrollMode.free);
    }
    final a = stroller.sample(t + 0.6);
    final b = stroller.sample(t + 0.8);
    final walked = (b.x - a.x).abs();
    expect(b.animationTime - a.animationTime, closeTo(walked / const StrollTuning().walkGait, 0.001));
  });

  test('the pet is drawn as often as what it does needs', () {
    expect(MochiView.frameRate(mood: PetMood.relaxed, roam: _sample(travelling: true)), 25);
    expect(MochiView.frameRate(mood: PetMood.relaxed, oneShot: true), 24);
    expect(MochiView.frameRate(mood: PetMood.relaxed), 12);
    expect(MochiView.frameRate(mood: PetMood.napping), 6);
    expect(MochiView.frameRate(mood: PetMood.relaxed, roam: _sample(animation: PetAnimation.curl)), 6);
    expect(MochiView.frameRate(mood: PetMood.relaxed, roam: _sample(travelling: true), calm: true), 10);
  });

  test('the one-shots\' lengths match the recorded animations', () {
    final library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync());
    for (final MapEntry(key: animation, value: length) in strollOneShotLengths.entries) {
      final track = library.petTrack(animation);
      expect(track, isNotNull, reason: '$animation is recorded');
      expect(track!.length, closeTo(length, 0.05), reason: '$animation');
    }
    for (final loop in [PetAnimation.walk, PetAnimation.run, PetAnimation.sit, PetAnimation.curl, PetAnimation.watch]) {
      expect(library.petTrack(loop)?.loop, isTrue, reason: '$loop loops');
    }
  });
}

StrollSample _sample({bool travelling = false, PetAnimation animation = PetAnimation.walk}) => StrollSample(
  x: 0,
  facing: 1,
  animation: animation,
  animationTime: 0,
  activity: StrollActivity.wander,
  travelling: travelling,
);
