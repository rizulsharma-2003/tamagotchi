// Mochi is always clickable (the user's feedback of 2026-11-08): a pointer coming to Mochi stops it where it is, with or
// without the cursor buddy, and it holds still while the pointer stays near, even over a taskbar button; a second after the
// pointer left it carries on (first to free room if it stands over a button). Peekaboo, a lifted landmark visit, a drag and
// the buddy's own hold are left alone. Also the calm cost of the stage-drawn Mochi.

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show TaskbarStage;
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

const _left = StrollLine(190, 680);
const _right = StrollLine(1236, 1600);
const _zones = [_left, _right];
bool _free(double x) => _zones.any((zone) => x >= zone.minX - 0.01 && x <= zone.maxX + 0.01);

/// A fresh stroller at [seed], lived (nothing near) until [until] says Mochi is where the test wants it.
(Stroller, double) _until(int seed, bool Function(Stroller stroller, double now) until, {StrollMode mode = StrollMode.free}) {
  final stroller = Stroller(random: Random(seed))..place(_zones, now: 0, x: 300);
  for (var now = 0.0; now < 3000; now += 0.1) {
    stroller.update(now, mode: mode);
    if (until(stroller, now)) return (stroller, now);
  }
  throw StateError('seed $seed never got there');
}

bool _walking(Stroller s, double now) => s.sample(now).travelling && !s.segments.any((g) => g.hop && g.start <= now && now < g.end);
bool _overButton(Stroller s, double now) => s.sample(now).travelling && !_free(s.sample(now).x);

/// Pointer ticks (10 a second) from [from] for [seconds], near or not; returns the xs seen.
List<double> _ticks(Stroller s, double from, double seconds, {required bool near}) {
  final xs = <double>[];
  for (var now = from; now <= from + seconds + 1e-9; now += 0.1) {
    s.update(now, mode: StrollMode.free);
    s.reach(now, near: near);
    xs.add(s.sample(now).x);
  }
  return xs;
}

void main() {
  group('the stroll holds for a pointer', () {
    test('a walking Mochi stops within one pointer tick and its x does not change while the pointer stays', () {
      for (var seed = 0; seed < 12; seed++) {
        final (s, now) = _until(seed, _walking);
        final before = s.sample(now).x;
        expect(s.reach(now, near: true), isTrue, reason: 'seed $seed');
        expect(s.reaching, isTrue);
        final xs = _ticks(s, now + 0.1, 30, near: true);
        expect(xs.every((x) => (x - before).abs() < 0.01), isTrue, reason: 'seed $seed holds at $before: $xs');
        expect(s.sample(now + 0.1).travelling, isFalse);
        expect(s.sample(now + 0.1).style, StrollStyle.attentive, reason: 'facing you');
        expect(s.nextChange(now + 31), isNull, reason: 'nothing wakes it: it holds');
      }
    });

    test('the same crossing over a button: it stops on the button, not at the free spot', () {
      var stoppedOver = 0;
      for (var seed = 0; seed < 40 && stoppedOver < 3; seed++) {
        final Stroller s;
        final double now;
        try {
          (s, now) = _until(seed, _overButton);
        } on StateError {
          continue;
        }
        final before = s.sample(now).x;
        expect(s.reach(now, near: true), isTrue);
        final xs = _ticks(s, now + 0.1, 20, near: true);
        expect(xs.every((x) => (x - before).abs() < 0.01), isTrue, reason: 'seed $seed holds over the button at $before');
        expect(_free(before), isFalse);
        stoppedOver++;
      }
      expect(stoppedOver, greaterThan(0));
    });

    test('leaving: about a second later it carries on, and a crossing Mochi ends over free room', () {
      var checked = 0;
      for (var seed = 0; seed < 40 && checked < 3; seed++) {
        final Stroller s;
        final double now;
        try {
          (s, now) = _until(seed, _overButton);
        } on StateError {
          continue;
        }
        s.reach(now, near: true);
        final held = s.sample(now).x;
        _ticks(s, now + 0.1, 2, near: true);
        final t = now + 2.2;
        var resumed = false;
        var left = t;
        for (; left < t + 3; left += 0.1) {
          s.update(left, mode: StrollMode.free);
          if (s.reach(left, near: false)) {
            resumed = true;
            break;
          }
          expect(s.sample(left).x, closeTo(held, 0.01), reason: 'holds while it waits');
        }
        expect(resumed, isTrue);
        expect(left - t, inInclusiveRange(0.9, 1.2), reason: 'about a second: ${left - t}');
        expect(s.reaching, isFalse);
        var moved = false;
        for (var u = left; u < left + 12; u += 0.1) {
          s.update(u, mode: StrollMode.free);
          if (s.sample(u).travelling) moved = true;
        }
        expect(moved, isTrue, reason: 'walks on to free room');
        for (var u = left + 12; u < left + 400; u += 0.1) {
          s.update(u, mode: StrollMode.free);
          if (!s.sample(u).travelling) {
            expect(_free(s.sample(u).x), isTrue, reason: 'rests in free room: ${s.sample(u).x}');
          }
        }
        checked++;
      }
      expect(checked, greaterThan(0));
    });

    test('brushing past for under a second does not make it jerk', () {
      final (s, now) = _until(3, _walking);
      s.reach(now, near: true);
      final held = s.sample(now).x;
      final plan = s.segments.length;
      var t = now + 0.1;
      for (final (near, seconds) in [(true, 0.5), (false, 0.5), (true, 0.5), (false, 0.8), (true, 1.0)]) {
        for (final end = t + seconds; t < end; t += 0.1) {
          s.update(t, mode: StrollMode.free);
          expect(s.reach(t, near: near), isFalse, reason: 'at $t');
          expect(s.sample(t).x, closeTo(held, 0.01));
          expect(s.sample(t).travelling, isFalse);
        }
      }
      expect(s.segments.length, plan);
      expect(s.reaching, isTrue);
    });

    test('a Mochi that is not about to walk is not cut for a pointer', () {
      final (s, now) = _until(
        1,
        (s, now) => !s.sample(now).travelling && s.segments.every((g) => !g.travels || g.start > now + Stroller.reachAhead + 0.5 || g.end <= now),
      );
      final plan = [...s.segments];
      expect(s.reach(now, near: true), isFalse);
      expect(s.segments, plan);
    });

    test('the cursor buddy keeps its own behaviour: active, reach leaves it alone', () {
      final s = Stroller(random: Random(2))..place(_zones, now: 0, x: 300);
      expect(s.follow(0.5, pointerX: 1450, bodyWidth: 38, allowed: true), isTrue);
      final plan = [...s.segments];
      expect(s.reach(0.6, near: true), isFalse);
      expect(s.segments, plan);
      expect(s.buddying, isTrue);
      expect(s.reaching, isFalse);
      s.update(60, mode: StrollMode.free);
      s.follow(60, pointerX: s.sample(60).x + 20, bodyWidth: 38, allowed: true);
      expect(s.reach(60.1, near: true), isFalse);
      expect(s.buddying, isTrue);
      s.follow(61, pointerX: 100, bodyWidth: 38, allowed: false);
      expect(s.buddying, isFalse);
    });

    test('Peekaboo is untouched: a hiding Mochi takes clicks as it is', () {
      final s = Stroller(random: Random(4))..place(_zones, now: 0, x: 300);
      expect(s.hide(0.5), isTrue);
      for (var now = 1.0; now < 30; now += 0.1) {
        s.update(now, mode: StrollMode.free);
        expect(s.reach(now, near: true), isFalse);
      }
      expect(s.hiding, isTrue);
      expect(s.reaching, isFalse);
    });

    test('a landmark visit with Mochi lifted is not cut (it is not walking, and would leap away)', () {
      const marks = [StrollLandmark(StrollVisit.clock, x: 1560, lift: 8, up: 90, reach: 900)];
      final s = Stroller(random: Random(5))
        ..place(_zones, now: 0, x: 1400)
        ..setLandmarks(marks, 0);
      expect(s.visitNow(StrollVisit.clock, 1), isTrue);
      var lifted = 0;
      for (var now = 1.0; now < 40; now += 0.1) {
        s.update(now, mode: StrollMode.free);
        if (s.sample(now).lift > 0) {
          lifted++;
          final plan = [...s.segments];
          expect(s.reach(now, near: true), isFalse, reason: 'lifted at $now');
          expect(s.segments, plan);
        }
      }
      expect(lifted, greaterThan(10));
    });

    test('a drag still holds Mochi and lets go; reach waits for the drag', () {
      final (s, now) = _until(3, _walking);
      s.react(now, double.infinity);
      final held = s.sample(now + 0.1).x;
      for (var t = now + 0.1; t < now + 5; t += 0.1) {
        s.update(t, mode: StrollMode.free);
        expect(s.reach(t, near: true), isFalse);
        expect(s.sample(t).x, closeTo(held, 0.01));
      }
      expect(s.reaching, isFalse);
      s.resume(now + 6);
      var moved = false;
      for (var t = now + 6; t < now + 400; t += 0.1) {
        s.update(t, mode: StrollMode.free);
        if (s.sample(t).travelling) moved = true;
      }
      expect(moved, isTrue, reason: 'strolls again after the drag');
    });

    test('with animation effects off (still) reach does nothing', () {
      final (s, now) = _until(3, (s, now) => now > 5, mode: StrollMode.still);
      expect(s.reach(now, near: true), isFalse);
      expect(s.reaching, isFalse);
    });

    test('a mode change while it holds goes on holding; the new mode starts after the pointer has left', () {
      final (s, now) = _until(3, _walking);
      s.reach(now, near: true);
      final held = s.sample(now).x;
      s.update(now + 1, mode: StrollMode.attending);
      expect(s.reaching, isTrue);
      expect(s.sample(now + 1).x, closeTo(held, 0.01));
      expect(s.reach(now + 1.1, near: false), isFalse);
      s.update(now + 2.2, mode: StrollMode.attending);
      expect(s.reach(now + 2.2, near: false), isTrue);
      expect(s.mode, StrollMode.attending);
      expect(s.sample(now + 2.3).x, closeTo(held, 25), reason: 'attending: it carries on from where it stood');
    });
  });

  group('on the taskbar', () {
    late TestDesktop t;
    late FakePetWindow window;
    late FakeShell shell;
    late FakeTaskbar taskbar;
    final strolls = <TaskbarStroll>[];

    setUp(() {
      t = TestDesktop.make();
      window = FakePetWindow();
      shell = FakeShell(petWindow: window);
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    });

    tearDown(() => t.dispose());

    void reachTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final stroll in strolls) {
          stroll.dispose();
        }
        strolls.clear();
      }
    });

    Future<TaskbarStroll> start(WidgetTester tester, {int seed = 7, TaskbarStand? stand}) async {
      final stroll = TaskbarStroll(
        shell: shell,
        taskbar: taskbar,
        settings: t.desktop.settings,
        motion: t.desktop.motion,
        cues: t.desktop.cues,
        rhythm: t.desktop.rhythm,
        mischief: t.desktop.mischief,
        clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        random: Random(seed),
      )..stand = stand;
      strolls.add(stroll);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      return stroll;
    }

    /// Elapses up to [seconds], stopping once [until] holds.
    Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.1, bool Function()? until}) async {
      for (var s = 0.0; s < seconds; s += step) {
        await tester.pump(Duration(microseconds: (step * 1e6).round()));
        if (until != null && until()) return;
      }
    }

    double mochi(TaskbarStroll stroll) => stroll.sample()!.x;

    void pointOnMochi(TaskbarStroll stroll, [TaskbarStage? onStage]) {
      final body = (onStage ?? stroll.stage!).bodyAt(mochi(stroll));
      taskbar.pointer = (body.left + body.width ~/ 2, body.top + body.height ~/ 2);
    }

    reachTest('the buddy off: a walking Mochi stops when the pointer arrives, holds, and takes the click', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 600, until: () => stroll.sample()!.travelling);
      expect(stroll.sample()!.travelling, isTrue, reason: 'on its way');
      pointOnMochi(stroll);
      await elapse(tester, 0.15);
      expect(stroll.sample()!.travelling, isFalse, reason: 'stopped within a tick or two');
      final x = mochi(stroll);
      await elapse(tester, 8);
      expect(mochi(stroll), x);
      expect(stroll.moving, isFalse);
      final body = stroll.stage!.body(stroll.frame!);
      expect(body.contains(taskbar.pointer!.$1, taskbar.pointer!.$2), isTrue, reason: 'the click lands where Mochi is');
      expect(window.clickThrough.last, isFalse);
      // Away: it waits a second or so, then strolls on.
      taskbar.pointer = (300, 300);
      await elapse(tester, 0.6);
      expect(mochi(stroll), x);
      await elapse(tester, 600, step: 0.5, until: () => (mochi(stroll) - x).abs() > 1);
      expect((mochi(stroll) - x).abs(), greaterThan(1), reason: 'strolls on');
    });

    reachTest('the stage-drawn Mochi (Mochi\'s window open) holds for the pointer too', (tester) async {
      final stand = _Stand();
      final stroll = await start(tester, stand: stand);
      final stage = stroll.stage!;
      unawaited(stroll.show(Surface.main));
      await tester.pump();
      expect(stroll.placement, PetPlacement.stage);
      await elapse(tester, 600, until: () => stroll.sample()!.travelling);
      expect(stroll.sample()!.travelling, isTrue);
      pointOnMochi(stroll, stage);
      await elapse(tester, 0.15);
      expect(stroll.sample()!.travelling, isFalse);
      final x = mochi(stroll);
      await elapse(tester, 8);
      expect(mochi(stroll), x);
      expect(stand.shows.last.x, closeTo(x, 0.01), reason: 'drawn where it stopped');
      final shows = stand.shows.length;
      await elapse(tester, 8);
      // (A mood change from the pet's world may redraw once; a timer would be dozens.)
      expect(stand.shows.length - shows, lessThan(3), reason: 'a held Mochi costs nothing: no redraw timer');
      taskbar.pointer = (300, 300);
      await elapse(tester, 600, step: 0.5, until: () => (mochi(stroll) - x).abs() > 1);
      expect((mochi(stroll) - x).abs(), greaterThan(1), reason: 'strolls on');
    });

    reachTest('dragging still works: the body takes the press and a drag hold freezes Mochi', (tester) async {
      final stroll = await start(tester);
      pointOnMochi(stroll);
      await elapse(tester, 1);
      expect(window.clickThrough.last, isFalse, reason: 'the body takes the press that starts a drag');
      expect(stroll.stroller.isPlaced, isTrue);
    });
  });

  group('calm cost on the stage', () {
    late TestDesktop t;
    late FakeShell shell;
    late FakeTaskbar taskbar;
    final strolls = <TaskbarStroll>[];

    setUp(() {
      t = TestDesktop.make();
      shell = FakeShell(petWindow: FakePetWindow());
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    });

    tearDown(() => t.dispose());

    /// Runs 60 s of a calm stroll (the pointer away) and counts what the stage is told, to compare with the pet window,
    /// which draws by itself at 8 fps only during one-shots and nothing during holds and rests.
    testWidgets('60 s calm on the stage: the draws are the one-shots and the picture changes, nothing else', (tester) async {
      final stand = _Stand();
      final stroll = TaskbarStroll(
        shell: shell,
        taskbar: taskbar,
        settings: t.desktop.settings,
        motion: t.desktop.motion,
        cues: t.desktop.cues,
        rhythm: t.desktop.rhythm,
        mischief: t.desktop.mischief,
        clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        random: Random(11),
      )..stand = stand;
      strolls.add(stroll);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      unawaited(stroll.show(Surface.main));
      await tester.pump();
      try {
        expect(stroll.placement, PetPlacement.stage);
        // Past the hand-over (the first draws as the stage takes Mochi over).
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final first = stand.shows.length;
        var walkingDraws = 0;
        var playingDraws = 0;
        var playingSeconds = 0.0;
        var otherDraws = 0;
        var changes = 0;
        var timerOutsideOneShot = 0;
        double? lastSegment;
        for (var i = 0; i < 600; i++) {
          final before = stand.shows.length;
          await tester.pump(const Duration(milliseconds: 100));
          final now = tester.binding.clock.now().microsecondsSinceEpoch / 1e6;
          final drawn = stand.shows.length - before;
          final sample = stroll.sample()!;
          final segments = stroll.stroller.segments;
          final here = segments.cast<StrollSegment?>().firstWhere((g) => now < g!.end, orElse: () => null);
          if (here != null && here.start != lastSegment) {
            changes++;
            lastSegment = here.start;
          }
          if (sample.travelling) {
            walkingDraws += drawn;
          } else if (stroll.stroller.playingAt(now)) {
            playingDraws += drawn;
            playingSeconds += 0.1;
          } else {
            otherDraws += drawn;
            if (stroll.moving) timerOutsideOneShot++;
          }
        }
        var identical = 0;
        for (var i = first + 1; i < stand.shows.length; i++) {
          final a = stand.shows[i - 1];
          final b = stand.shows[i];
          if (a.feet == b.feet && a.animation == b.animation && a.animationTime == b.animationTime && a.facing == b.facing) {
            identical++;
          }
        }
        // ignore: avoid_print
        print(
          'calm 60 s on the stage: walking draws=$walkingDraws, one-shot draws=$playingDraws over ${playingSeconds.toStringAsFixed(1)} s '
          '(${(playingDraws / max(playingSeconds, 0.1)).toStringAsFixed(1)}/s), draws outside walking and one-shots=$otherDraws, '
          'plan pieces started=$changes, frame-timer ticks outside a one-shot=$timerOutsideOneShot, identical frames=$identical',
        );
        expect(identical, 0, reason: 'the stage is never told the same picture twice in a row');
        // A hold or a rest is drawn when its picture begins (a walk's last frame and the plan's next piece), never on a timer:
        // a few more than the plan's pieces at most.
        expect(otherDraws, lessThanOrEqualTo(changes * 2), reason: 'a hold or a rest redraws only when a piece of the plan begins');
        expect(timerOutsideOneShot, lessThanOrEqualTo(changes), reason: 'the 125 ms timer stops when the one-shot ends');
        expect(playingDraws / max(playingSeconds, 0.1), lessThanOrEqualTo(8.5), reason: 'a one-shot is drawn at 8 fps at most');
      } finally {
        for (final stroll in strolls) {
          stroll.dispose();
        }
        strolls.clear();
      }
    });
  });
}

/// A stand that records what it's shown.
class _Stand implements TaskbarStand {
  final List<({double x, (int, int) feet, Object animation, double animationTime, double facing, StrollSample sample})> shows = [];
  @override
  bool shown = false;

  @override
  bool show(StrollSample sample, {required (int, int) feet, required double ratio, required double unit}) {
    shows.add((x: sample.x, feet: feet, animation: sample.animation, animationTime: sample.animationTime, facing: sample.facing, sample: sample));
    shown = true;
    return true;
  }

  @override
  void raise() {}

  @override
  void hide() => shown = false;
}
