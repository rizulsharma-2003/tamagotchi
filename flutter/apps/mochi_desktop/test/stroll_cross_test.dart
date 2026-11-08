// Mochi walking across the taskbar's buttons (docs/SPRINT_2.md, the taskbar stroll's crossing, as the Mac's roamer runs, leaps and
// plays across other apps' status items and lingers only where the bar is free): the zoomies cross, the cursor buddy and the
// landmarks are reached on foot, "Plays in its spot" keeps to its room, whatever cuts a trip in the middle walks on to free
// room first, and the pet's window takes clicks on Mochi's body while it's over a button, and nowhere else.

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart' show PetAnimation;
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

const _left = StrollLine(190, 680);
const _right = StrollLine(1236, 1600);
const _zones = [_left, _right];

bool _free(double x) => _zones.any((zone) => x >= zone.minX - 0.01 && x <= zone.maxX + 0.01);
bool _inLeft(double x) => x <= _left.maxX + 0.01;

/// Lives [stroller] to [to] seconds, collecting every segment it plans.
Set<StrollSegment> _live(Stroller stroller, double to, {double step = 0.25}) {
  final seen = <StrollSegment>{};
  for (var t = 0.0; t <= to; t += step) {
    stroller.update(t, mode: StrollMode.free);
    seen.addAll(stroller.segments);
  }
  return seen;
}

bool _crossing(StrollSegment segment) => segment.travels && _inLeft(segment.fromX) != _inLeft(segment.toX);

void main() {
  group('the plan', () {
    test('the zoomies may cross the buttons, and the toys never do', () {
      var zoomed = 0;
      for (var seed = 0; seed < 40; seed++) {
        final stroller = Stroller(random: Random(seed))..place(_zones, now: 0, x: 300);
        for (final segment in _live(stroller, 2400)) {
          if (segment.activity == StrollActivity.zoomies && _crossing(segment)) {
            zoomed++;
            expect(segment.crosses, isTrue);
            expect(segment.animation, PetAnimation.run, reason: 'a sprint');
          }
          if (const {StrollActivity.ball, StrollActivity.yarn, StrollActivity.butterfly, StrollActivity.leaf}.contains(segment.activity)) {
            expect(_crossing(segment), isFalse, reason: 'a toy stays in one free stretch: $segment');
          }
        }
      }
      expect(zoomed, greaterThan(0), reason: 'a sprint from one stretch to the other');
    });

    test('the cursor buddy reaches the pointer in the other stretch by walking over the buttons, not by fading', () {
      for (final (from, pointer) in [(300.0, 1450.0), (1400.0, 250.0)]) {
        final stroller = Stroller(random: Random(2))..place(_zones, now: 0, x: from);
        expect(stroller.follow(0.5, pointerX: pointer, bodyWidth: 38, allowed: true), isTrue);
        final trip = stroller.segments.firstWhere(_crossing);
        expect(trip.hop, isFalse);
        expect(trip.crosses, isTrue);
        expect(trip.animation, anyOf(PetAnimation.walk, PetAnimation.run));
        expect(_free(trip.toX), isTrue, reason: 'it sits beside the pointer in free room');
        expect((trip.toX - pointer).abs(), greaterThanOrEqualTo(38 * Stroller.buddyLeast), reason: 'never under it');
        expect(stroller.segments.any((segment) => segment.hop), isFalse);
        // It arrives, and sits.
        final end = trip.end + 0.1;
        stroller.update(end, mode: StrollMode.free);
        expect(stroller.sample(end).x, closeTo(trip.toX, 0.01));
        expect(stroller.sample(end).travelling, isFalse);
      }
    });

    test('the landmarks are reached by walking to the free spot beside them, over the buttons', () {
      const marks = [
        StrollLandmark(StrollVisit.clock, x: 1560, lift: 8, up: 90, reach: 900),
        StrollLandmark(StrollVisit.start, x: 900, reach: 900),
        StrollLandmark(StrollVisit.widgets, x: 100, lift: 30, up: 90, reach: 900),
      ];
      var visits = 0;
      for (final (kind, from) in [(StrollVisit.clock, 300.0), (StrollVisit.widgets, 1400.0), (StrollVisit.start, 1400.0)]) {
        final stroller = Stroller(random: Random(4))..place(_zones, now: 0, x: from);
        stroller.setLandmarks(marks, 0);
        expect(stroller.visitNow(kind, 1), isTrue, reason: kind.name);
        final plan = stroller.segments;
        expect(plan.any((segment) => segment.hop), isFalse, reason: '${kind.name}: no fade');
        final spot = plan.firstWhere((segment) => segment.travels && !segment.oneShot && segment.crosses, orElse: () => plan.first);
        if (_crossing(spot)) {
          visits++;
          expect(spot.animation, anyOf(PetAnimation.walk, PetAnimation.run));
          expect(_free(spot.toX), isTrue);
        }
      }
      expect(visits, 3, reason: 'each visit began with a walk to the other stretch');
    });

    test('playing in its spot is unchanged: one room, no crossing, nothing but the room', () {
      const room = StrollLine(300, 520);
      for (var seed = 0; seed < 12; seed++) {
        final stroller = Stroller(random: Random(seed))..place(const [room], now: 0, x: 400);
        for (final segment in _live(stroller, 1800)) {
          expect(segment.crosses || segment.hop, isFalse, reason: '$segment');
          expect(segment.fromX >= room.minX - 0.01 && segment.toX <= room.maxX + 0.01, isTrue, reason: '$segment');
          expect(segment.activity, isNot(StrollActivity.cross));
        }
        expect({for (var i = 0; i < 300; i++) stroller.chooseFreeActivity()}, isNot(contains(StrollActivity.cross)));
      }
    });

    test('beside Patch Mochi keeps to its little stretch, as ever', () {
      final stroller = Stroller(random: Random(3))..place(_zones, now: 0, x: 400, home: 600);
      for (final segment in _live(stroller, 1800)) {
        expect(segment.crosses || segment.hop, isFalse);
      }
    });

    test('a reaction in the middle of a trip lets Mochi walk on to free room before it holds still', () {
      var tested = 0;
      for (var seed = 0; seed < 40 && tested < 5; seed++) {
        final stroller = Stroller(random: Random(seed))..place(_zones, now: 0, x: 300);
        final trip = _live(stroller, 1500).where((segment) => _crossing(segment) && segment.end - segment.start > 4).firstOrNull;
        if (trip == null) continue;
        final stroller2 = Stroller(random: Random(seed))..place(_zones, now: 0, x: 300);
        for (var t = 0.0; t < trip.start + (trip.end - trip.start) * 0.5; t += 0.25) {
          stroller2.update(t, mode: StrollMode.free);
        }
        final at = trip.start + (trip.end - trip.start) * 0.5;
        final over = stroller2.sample(at).x;
        if (_free(over)) continue;
        tested++;
        stroller2.react(at, 3);
        // Every moment it isn't walking, it's over free room.
        for (var t = at; t < at + 12; t += 0.1) {
          final sample = stroller2.sample(t);
          if (!sample.travelling) expect(_free(sample.x), isTrue, reason: 'seed $seed at $t: ${sample.x}');
        }
      }
      expect(tested, greaterThan(0));
    });
  });

  group('the pet window', () {
    late TestDesktop t;
    late FakePetWindow window;
    late FakeTaskbar taskbar;
    final strolls = <TaskbarStroll>[];

    setUp(() {
      t = TestDesktop.make();
      window = FakePetWindow();
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    });

    tearDown(() => t.dispose());

    testWidgets('takes clicks on Mochi\'s body while Mochi is over a button, and lets them through everywhere else', (tester) async {
      try {
        final stroll = TaskbarStroll(
          shell: FakeShell(petWindow: window),
          taskbar: taskbar,
          settings: t.desktop.settings,
          motion: t.desktop.motion,
          cues: t.desktop.cues,
          clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
          random: Random(3),
        );
        strolls.add(stroll);
        unawaited(stroll.show(Surface.pet));
        await tester.pump();
        final scale = stroll.stage!.scale;
        var over = 0;
        for (var step = 0; step < 4000 && over < 3; step++) {
          await tester.pump(const Duration(milliseconds: 100));
          final sample = stroll.sample()!;
          if (_free(sample.x) || !stroll.moving) continue;
          over++;
          final frame = stroll.frame!;
          final body = stroll.bodies().single;
          expect((body.left + body.right) / 2, closeTo((frame.left + frame.right) / 2, 1), reason: 'Mochi is drawn in the middle of its window');
          expect(body.bottom, frame.bottom);
          // The pointer on Mochi: clicks are let in at the next check; a pointer a body away: through.
          taskbar.pointer = ((body.left + body.right) ~/ 2, (body.top + body.bottom) ~/ 2);
          await tester.pump(const Duration(milliseconds: 120));
          expect(window.clickThrough.last, isFalse, reason: 'over Mochi, over a button');
          final now = stroll.bodies().single;
          taskbar.pointer = (now.right + (50 * scale).round(), now.top + 5);
          await tester.pump(const Duration(milliseconds: 150));
          expect(window.clickThrough.last, isTrue, reason: 'beside Mochi, the button under the pointer gets the click');
          taskbar.pointer = null;
        }
        expect(over, 3, reason: 'Mochi crossed the buttons three times');
      } finally {
        for (final stroll in strolls) {
          stroll.dispose();
        }
        strolls.clear();
      }
    });
  });
}
