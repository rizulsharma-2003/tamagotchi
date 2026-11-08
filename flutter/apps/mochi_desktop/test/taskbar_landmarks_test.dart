// Landmarks on the taskbar (docs/SPRINT_2.md X6): with Mischief's switch on and Mochi free to wander alone, it now and
// then hangs from the clock, bats at the Start button or perches on the widgets tile. The landmarks come from the same
// UI Automation call as the buttons (by AutomationId and ClassName, never by name; any may be missing); the plan
// (ui/pet/stroller.dart) and the stroll (ui/pet/taskbar_stroll.dart) are driven here with a fake taskbar and window.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart' show PetAnimation;
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

const _zones = [StrollLine(190, 680), StrollLine(900, 1500)];

/// The three landmarks as the stroll hands them to the plan (logical pixels, 100% scale): the clock beyond the free
/// stretch, Start just right of the first, the widgets tile to its left.
const _clock = StrollLandmark(StrollVisit.clock, x: 1800, lift: 10, up: 90, reach: 420);
const _start = StrollLandmark(StrollVisit.start, x: 742, reach: 86);
const _widgets = StrollLandmark(StrollVisit.widgets, x: 75, lift: 43, up: 110, reach: 260);

/// Lives [stroller] from [from] to [to] seconds, looking at it each step.
void _live(Stroller stroller, double from, double to, void Function(double t) each, {StrollMode mode = StrollMode.free, double step = 0.05}) {
  for (var t = from; t <= to; t += step) {
    stroller.update(t, mode: mode);
    each(t);
  }
}

bool _inZone(List<StrollLine> zones, double x, [double slack = 0.5]) => zones.any((zone) => x >= zone.minX - slack && x <= zone.maxX + slack);

/// What UI Automation reports on a Windows 11 taskbar (screen 1920×1080, 100%): the elements with their ids and classes,
/// as measured on a Windows 11 PC, in the order Explorer gives them, with names nobody reads.
List<TaskbarElement> _windows11Elements({bool widgets = true, bool start = true}) => [
  const TaskbarElement(PixelRect(0, 1032, 1920, 1080), className: 'Taskbar.TaskbarFrameAutomationPeer'),
  if (widgets) const TaskbarElement(PixelRect(6, 1032, 158, 1080), automationId: 'WidgetsButton', className: 'Taskbar.TaskListButtonAutomationPeer'),
  if (start) const TaskbarElement(PixelRect(720, 1032, 765, 1080), automationId: 'StartButton', className: 'Taskbar.TaskListButtonAutomationPeer'),
  const TaskbarElement(PixelRect(770, 1032, 815, 1080), automationId: 'SearchButton', className: 'Taskbar.TaskListButtonAutomationPeer'),
  const TaskbarElement(PixelRect(820, 1032, 865, 1080), automationId: 'TaskViewButton', className: 'Taskbar.TaskListButtonAutomationPeer'),
  const TaskbarElement(PixelRect(870, 1032, 915, 1080), automationId: 'Chrome', className: 'Taskbar.TaskListButtonAutomationPeer'),
  // The tray's icons share one AutomationId; the clock is the last OmniButton, then the Show Desktop sliver.
  const TaskbarElement(PixelRect(1700, 1032, 1780, 1080), automationId: 'SystemTrayIcon', className: 'SystemTray.OmniButton'),
  const TaskbarElement(PixelRect(1780, 1032, 1843, 1080), automationId: 'SystemTrayIcon', className: 'SystemTray.OmniButton'),
  const TaskbarElement(PixelRect(1913, 1032, 1920, 1080), className: 'SystemTray.ShowDesktopButton'),
];

void main() {
  group('Finding the landmarks', () {
    test('by AutomationId (widgets, Start) and ClassName (the clock, the right-most OmniButton)', () {
      final found = TaskbarLandmarks.of(_windows11Elements());
      expect(found.widgets, const PixelRect(6, 1032, 158, 1080));
      expect(found.start, const PixelRect(720, 1032, 765, 1080));
      expect(found.clock, const PixelRect(1780, 1032, 1843, 1080), reason: 'the tray icons share the clock\'s AutomationId; the clock is the last of their class');
      expect(found.isEmpty, isFalse);
    });

    test('each may be absent: widgets off, no Start, nothing', () {
      expect(TaskbarLandmarks.of(_windows11Elements(widgets: false)).widgets, isNull);
      expect(TaskbarLandmarks.of(_windows11Elements(widgets: false)).start, isNotNull);
      expect(TaskbarLandmarks.of(_windows11Elements(start: false)).start, isNull);
      expect(TaskbarLandmarks.of(const []).isEmpty, isTrue);
      expect(TaskbarLandmarks.of(const []), TaskbarLandmarks.none);
      // An older Windows: its elements have other ids and classes, so none is found.
      final older = TaskbarLandmarks.of(const [
        TaskbarElement(PixelRect(0, 1032, 60, 1080), automationId: 'Start', className: 'Start'),
        TaskbarElement(PixelRect(1700, 1032, 1843, 1080), automationId: 'Clock', className: 'TrayClockWClass'),
      ]);
      expect(older.isEmpty, isTrue);
    });

    test('app buttons and other tray icons are never landmarks, and a container as wide as the taskbar is not a button', () {
      final found = TaskbarLandmarks.of(const [
        TaskbarElement(PixelRect(0, 1032, 1920, 1080), automationId: 'StartButton'),
        TaskbarElement(PixelRect(870, 1032, 915, 1080), automationId: 'Chrome', className: 'Taskbar.TaskListButtonAutomationPeer'),
        TaskbarElement(PixelRect(1700, 1032, 1780, 1080), automationId: 'SystemTrayIcon', className: 'SystemTray.NormalButton'),
        TaskbarElement(PixelRect(1913, 1032, 1920, 1080), className: 'SystemTray.ShowDesktopButton'),
      ]);
      expect(found.isEmpty, isTrue);
    });

    test('an element is only its place, id and class: there is no name to read', () {
      // (TaskbarElement has no name field; UI Automation is never asked for the Name property.)
      const element = TaskbarElement(PixelRect(0, 0, 10, 10), automationId: 'a', className: 'b');
      expect(element.toString(), isNot(contains('Name')));
      expect(element, const TaskbarElement(PixelRect(0, 0, 10, 10), automationId: 'a', className: 'b'));
    });

    test('the estimate path (UI Automation failed) has no landmarks', () {
      final taskbar = FakeTaskbar(FakeTaskbar.bottomTaskbar());
      taskbar.landmarks = TaskbarLandmarks.of(_windows11Elements());
      // buttons() null means the estimate: the stage is estimated and the landmarks of the failed call are none.
      expect(const NoTaskbar().landmarks, TaskbarLandmarks.none);
      final (:stage, :block) = TaskbarStage.of(taskbar.read());
      expect(block, isNull);
      expect(stage!.measured, isFalse);
    });
  });

  group('The plan', () {
    test('each visit is chosen only while its landmark is known', () {
      for (final mark in [_clock, _start, _widgets]) {
        final without = Stroller(random: Random(1))..place(_zones, now: 0, x: 400);
        final picks = {for (var i = 0; i < 1500; i++) without.chooseFreeActivity()};
        expect(picks.contains(mark.kind.activity), isFalse, reason: '${mark.kind.name} unknown');
        final known = Stroller(random: Random(1))
          ..place(_zones, now: 0, x: 400)
          ..setLandmarks([mark], 0);
        final withIt = {for (var i = 0; i < 1500; i++) known.chooseFreeActivity()};
        expect(withIt.contains(mark.kind.activity), isTrue, reason: '${mark.kind.name} known');
        for (final other in StrollVisit.values.where((v) => v != mark.kind)) {
          expect(withIt.contains(other.activity), isFalse, reason: 'only the known one');
        }
      }
    });

    test('about 0.6 each, beside the play activities', () {
      final stroller = Stroller(random: Random(5))
        ..place(_zones, now: 0, x: 400)
        ..setLandmarks([_clock, _start, _widgets], 0);
      const draws = 15000;
      final counts = <StrollActivity, int>{};
      for (var i = 0; i < draws; i++) {
        counts.update(stroller.chooseFreeActivity(), (n) => n + 1, ifAbsent: () => 1);
      }
      // wander 3, sniff 2, fidget 1.8, nap .45, trot .5, hop .6, zoomies 1, butterfly 1.2, ball 1, yarn .5, leaf .6 and
      // three visits at .6: 15.65 in all (the plan never repeats the last pick, which evens the odds out a little).
      for (final visit in StrollVisit.values) {
        expect((counts[visit.activity] ?? 0) / draws, closeTo(0.6 / 15.65, 0.012), reason: visit.name);
      }
    });

    test('a landmark with no free spot beside it is not visited', () {
      // Start far from every stretch (a left-aligned taskbar, Start at the far left, has nothing free beside it).
      const far = StrollLandmark(StrollVisit.start, x: 20, reach: 86);
      final stroller = Stroller(random: Random(1))
        ..place(_zones, now: 0, x: 400)
        ..setLandmarks([far], 0);
      expect({for (var i = 0; i < 1500; i++) stroller.chooseFreeActivity()}.contains(StrollActivity.batStart), isFalse);
      expect(stroller.visitNow(StrollVisit.start, 0), isFalse);
    });

    test('in "Plays in its spot" only landmarks within reach of its room are visited', () {
      // Its room is a short stretch by the notification area; Start is in another, far one.
      final stroller = Stroller(random: Random(1))
        ..place(const [StrollLine(1300, 1500)], now: 0, x: 1400)
        ..setLandmarks([_clock, _start, _widgets], 0);
      final picks = {for (var i = 0; i < 2000; i++) stroller.chooseFreeActivity()};
      expect(picks, contains(StrollActivity.swing), reason: 'the clock is near');
      expect(picks.contains(StrollActivity.batStart), isFalse);
      expect(picks.contains(StrollActivity.perch), isFalse);
    });

    test('the clock: a walk to the nearest free spot, a leap, a 6–10 second hang (idle, both paws up), a drop back', () {
      final stroller = Stroller(random: Random(2))
        ..place(_zones, now: 0, x: 400)
        ..setLandmarks([_clock], 0);
      expect(stroller.visitNow(StrollVisit.clock, 0), isTrue);
      expect(stroller.visit, StrollVisit.clock);
      final segments = stroller.segments;
      final hang = segments.singleWhere((s) => s.style == StrollStyle.hang);
      expect(hang.animation, PetAnimation.idle);
      expect(hang.end - hang.start, inInclusiveRange(6, 10));
      expect(hang.fromX, _clock.x);
      expect(hang.liftFrom, _clock.lift);
      expect(hang.liftTo, _clock.lift);
      final leaps = segments.where((s) => s.arc > 0).toList();
      expect(leaps, hasLength(2));
      expect(leaps.first.toX, _clock.x);
      expect(leaps.first.liftTo, _clock.lift);
      expect(leaps.last.liftTo, 0);
      expect(_inZone(_zones, leaps.last.toX), isTrue, reason: 'back down in free room');
      expect(_inZone(_zones, leaps.first.fromX), isTrue);
      expect(leaps.first.fromX, closeTo(1500, 0.5), reason: 'the free spot nearest the clock (the end of the last stretch)');
      // Frames while it leaps; the hang itself is a hold (no stroll frames).
      expect(leaps.first.travels, isTrue);
      expect(hang.travels, isFalse);
      final mid = leaps.first.start + (leaps.first.end - leaps.first.start) / 2;
      expect(stroller.sample(mid).lift, greaterThan(_clock.lift), reason: 'an arc');
      expect(stroller.sample(hang.start + 1).lift, _clock.lift);
      expect(stroller.sample(hang.start + 1).style, StrollStyle.hang);
      expect(stroller.playRoom(hang.start + 1)!.up, _clock.up, reason: 'the window makes room above');
      expect(stroller.playRoom(leaps.last.end + 1), isNull, reason: 'and gives it back');
      // On its own, back to the stroll.
      _live(stroller, 0, leaps.last.end + 30, (t) {});
      expect(stroller.sample(leaps.last.end + 1).lift, 0);
    });

    test('Start: the free spot right beside it, faces it, three or four bats with a pounce, then on its way', () {
      final stroller = Stroller(random: Random(3))
        ..place(_zones, now: 0, x: 400)
        ..setLandmarks([_start], 0);
      expect(stroller.visitNow(StrollVisit.start, 0), isTrue);
      final plan = stroller.segments;
      final bats = plan.where((s) => s.animation == PetAnimation.bat).toList();
      expect(bats.length, inInclusiveRange(3, 4));
      expect(plan.any((s) => s.animation == PetAnimation.pounce), isTrue);
      expect(bats.every((s) => s.facing == 1), isTrue, reason: 'facing the button on its right');
      for (final s in plan.where((s) => s.activity == StrollActivity.batStart)) {
        expect(_inZone(_zones, s.fromX) && _inZone(_zones, s.toX), isTrue, reason: 'never over the button');
        expect(s.liftTo, 0);
      }
      expect((bats.first.fromX - _start.x).abs(), lessThan(_start.reach));
      expect(stroller.playRoom(bats.first.start + 0.1), isNull, reason: 'no lift, no extra room');
    });

    test('the widgets tile: a leap onto the taskbar\'s top edge, a few seconds sitting there looking out, a hop down', () {
      final stroller = Stroller(random: Random(4))
        ..place(_zones, now: 0, x: 400)
        ..setLandmarks([_widgets], 0);
      expect(stroller.visitNow(StrollVisit.widgets, 0), isTrue);
      final plan = stroller.segments;
      final leaps = plan.where((s) => s.arc > 0).toList();
      expect(leaps, hasLength(2));
      expect(leaps.first.toX, _widgets.x);
      expect(leaps.first.liftTo, _widgets.lift, reason: 'feet on the edge');
      expect(leaps.last.liftTo, 0);
      final up = plan.where((s) => s.liftFrom == _widgets.lift && s.liftTo == _widgets.lift).toList();
      expect(up.any((s) => s.animation == PetAnimation.sit), isTrue);
      expect(up.any((s) => s.animation == PetAnimation.lookAround), isTrue, reason: 'looking out');
      final seconds = up.fold<double>(0, (sum, s) => sum + s.end - s.start);
      expect(seconds, inInclusiveRange(3, 8));
      expect(stroller.playRoom(up.first.start + 0.1)!.up, _widgets.up);
    });

    test('never outside free mode: working, attending, asleep, paused or animation effects off', () {
      for (final mode in [StrollMode.working, StrollMode.attending, StrollMode.asleep, StrollMode.paused, StrollMode.still]) {
        final stroller = Stroller(random: Random(8))
          ..place(_zones, now: 0, x: 400, mode: mode)
          ..setLandmarks([_clock, _start, _widgets], 0);
        expect(stroller.visitNow(StrollVisit.clock, 0), isFalse, reason: mode.name);
        _live(stroller, 0, 1800, (t) {
          final sample = stroller.sample(t);
          expect(sample.lift, 0, reason: mode.name);
          expect(const {StrollActivity.swing, StrollActivity.batStart, StrollActivity.perch}.contains(sample.activity), isFalse, reason: mode.name);
        }, mode: mode, step: 0.5);
      }
    });

    test('they come up on their own in free mode, all three, and Mochi is back in free room each time', () {
      final seen = <StrollActivity>{};
      for (var seed = 0; seed < 8; seed++) {
        final stroller = Stroller(random: Random(seed))
          ..place(_zones, now: 0, x: 400)
          ..setLandmarks([_clock, _start, _widgets], 0);
        _live(stroller, 0, 2400, (t) {
          final sample = stroller.sample(t);
          if (const {StrollActivity.swing, StrollActivity.batStart, StrollActivity.perch}.contains(sample.activity)) seen.add(sample.activity);
          if (sample.lift == 0 && !sample.travelling) expect(_inZone(_zones, sample.x, 1), isTrue, reason: 'seed $seed at $t: x ${sample.x}');
        }, step: 0.1);
      }
      expect(seen, {StrollActivity.swing, StrollActivity.batStart, StrollActivity.perch});
    });

    test('anything that cuts the plan drops Mochi back down first: a reaction, a mode change, the landmark going away', () {
      for (final cut in <(String, void Function(Stroller, double))>[
        ('a reaction', (s, t) => s.react(t, 3, attentive: true)),
        ('Claude needing you', (s, t) => s.update(t, mode: StrollMode.attending)),
        ('a hide', (s, t) => s.hide(t)),
        ('the switch going off', (s, t) => s.setLandmarks(const [], t)),
      ]) {
        final stroller = Stroller(random: Random(2))
          ..place(_zones, now: 0, x: 400)
          ..setLandmarks([_clock], 0);
        expect(stroller.visitNow(StrollVisit.clock, 0), isTrue);
        final hang = stroller.segments.singleWhere((s) => s.style == StrollStyle.hang);
        final at = hang.start + 2;
        _live(stroller, 0, at, (t) {});
        expect(stroller.sample(at).lift, _clock.lift, reason: cut.$1);
        cut.$2(stroller, at);
        expect(stroller.sample(at).x, closeTo(_clock.x, 1), reason: '${cut.$1}: cut where it hangs');
        expect(stroller.sample(at + 2.5).lift, 0, reason: '${cut.$1}: dropped back');
        expect(_inZone(_zones, stroller.sample(at + 2.5).x, 1), isTrue, reason: '${cut.$1}: in free room');
        expect(stroller.sample(at + 0.2).style, isNot(StrollStyle.hang), reason: cut.$1);
        expect(stroller.playRoom(at + 0.2), isNotNull, reason: '${cut.$1}: the window still covers the drop');
        expect(stroller.playRoom(at + 5), isNull, reason: cut.$1);
      }
    });
  });

  group('On the taskbar', () {
    late TestDesktop t;
    late FakePetWindow window;
    late FakeShell shell;
    late FakeTaskbar taskbar;
    final strolls = <TaskbarStroll>[];

    final found = TaskbarLandmarks.of(_windows11Elements());

    setUp(() {
      t = TestDesktop.make();
      window = FakePetWindow();
      shell = FakeShell(petWindow: window);
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading))..landmarks = found;
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
    });

    tearDown(() => t.dispose());

    void landmarkTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final stroll in strolls) {
          stroll.dispose();
        }
        strolls.clear();
      }
    });

    Future<TaskbarStroll> start(WidgetTester tester, {int seed = 7}) async {
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
      );
      strolls.add(stroll);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      return stroll;
    }

    Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.1, void Function()? each}) async {
      for (var s = 0.0; s < seconds; s += step) {
        await tester.pump(Duration(microseconds: (step * 1e6).round()));
        each?.call();
      }
    }

    landmarkTest('each visit happens with the switch on and its landmark present, and not otherwise', (tester) async {
      final stroll = await start(tester);
      for (final kind in StrollVisit.values) {
        expect(stroll.visitNow(kind), isTrue, reason: '${kind.name} with the switch on');
        await elapse(tester, 40);
        expect(stroll.stroller.visit, kind);
        // Back to the stroll before the next.
        expect(stroll.sample()!.lift, 0, reason: '${kind.name} is over');
      }
      // The extra's own switch off: its landmarks are not offered any more.
      t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.landmarks: false});
      await elapse(tester, 0.5);
      for (final kind in StrollVisit.values) {
        expect(stroll.visitNow(kind), isFalse, reason: '${kind.name} with its switch off');
      }
      t.desktop.settings.mischief = const MischiefSettings();
      await elapse(tester, 0.5);
      expect(stroll.visitNow(StrollVisit.clock), isFalse, reason: 'the master switch off');
    });

    landmarkTest('a landmark that is not on the taskbar is not visited: widgets off, UI Automation failing', (tester) async {
      taskbar.landmarks = TaskbarLandmarks.of(_windows11Elements(widgets: false));
      var stroll = await start(tester);
      await elapse(tester, 0.3);
      expect(stroll.visitNow(StrollVisit.widgets), isFalse);
      expect(stroll.visitNow(StrollVisit.clock), isTrue);
      stroll.dispose();
      strolls.clear();
      // UI Automation fails: no buttons, no landmarks, an estimated stage.
      taskbar.measured = null;
      taskbar.landmarks = found;
      stroll = await start(tester);
      await elapse(tester, 0.3);
      expect(stroll.stage!.measured, isFalse);
      for (final kind in StrollVisit.values) {
        expect(stroll.visitNow(kind), isFalse, reason: kind.name);
      }
    });

    landmarkTest('the window grows upwards for the clock and the widgets visits, and gives the room back', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 0.3);
      final box = stroll.box;
      final scale = stroll.stage!.scale;
      final bottom = window.frames.last.bottom;
      final boxHeight = (box.height * scale).round();
      for (final kind in [StrollVisit.clock, StrollVisit.widgets]) {
        var tallest = 0;
        expect(stroll.visitNow(kind), isTrue);
        await elapse(tester, 40, each: () {
          final frame = stroll.frame!;
          expect(frame.bottom, bottom, reason: '${kind.name}: its window keeps its bottom edge');
          if (frame.height > tallest) tallest = frame.height;
          final sample = stroll.sample()!;
          if (sample.lift > 0 && !stroll.moving) {
            expect(sample.lift * scale + 24, lessThan(frame.height), reason: '${kind.name}: Mochi, raised, is inside the window');
            expect((frame.left + frame.right) / 2 / scale, closeTo(sample.x, 3), reason: 'centred on Mochi where it hangs or perches');
          }
        });
        expect(tallest, greaterThan(boxHeight + 20), reason: '${kind.name}: taller for it');
        expect(stroll.frame!.height, boxHeight, reason: '${kind.name}: Mochi\'s box again afterwards');
        expect(stroll.playRoom, isNull);
      }
      // Start has Mochi on the floor all along: the window stays its box.
      final heights = <int>{};
      expect(stroll.visitNow(StrollVisit.start), isTrue);
      await elapse(tester, 30, each: () => heights.add(stroll.frame!.height));
      expect(heights, {boxHeight});
    });

    landmarkTest('the landmark stays clickable except exactly where Mochi\'s body is, which goes up with it', (tester) async {
      // (The cursor buddy would drop Mochi when the pointer comes: it is off here, to look at the clicks alone.)
      t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.cursorBuddy: false});
      final stroll = await start(tester);
      await elapse(tester, 0.3);
      expect(stroll.visitNow(StrollVisit.widgets), isTrue);
      expect(await _until(tester, () => stroll.sample()!.lift > 40 && !stroll.moving, 60, elapse), isTrue);
      final bar = stroll.stage!.bar;
      final body = stroll.bodies().single;
      expect(body.bottom, lessThanOrEqualTo(bar.top + 2), reason: 'perched on the edge, above the taskbar');
      expect(body.bottom - body.top, greaterThan(20));
      // The tile under Mochi's feet is clickable: the pointer on the taskbar below the body passes through to it ...
      taskbar.pointer = ((body.left + body.right) ~/ 2, bar.top + 20);
      await elapse(tester, 0.4);
      expect(window.clickThrough.last, isTrue, reason: 'on the tile itself the click goes through');
      // ... and so does everything beside Mochi in its window ...
      taskbar.pointer = (body.left - 20, body.top + 10);
      await elapse(tester, 0.4);
      expect(window.clickThrough.last, isTrue, reason: 'beside Mochi');
      // ... and only over Mochi's body is the click Mochi's.
      taskbar.pointer = ((body.left + body.right) ~/ 2, (body.top + body.bottom) ~/ 2);
      await elapse(tester, 0.4);
      expect(window.clickThrough.last, isFalse, reason: 'over Mochi: it takes the click');
      expect(stroll.sample()!.lift, greaterThan(40), reason: 'and it is still perched');
    });

    landmarkTest('a pointer arriving cuts a visit short: Mochi drops back and keeps the pointer company', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 0.3);
      expect(stroll.visitNow(StrollVisit.clock), isTrue);
      expect(await _until(tester, () => stroll.sample()!.lift > 0 && !stroll.moving, 60, elapse), isTrue);
      final bar = stroll.stage!.bar;
      taskbar.pointer = (1600, bar.top + 24);
      await elapse(tester, 2.5);
      expect(stroll.sample()!.lift, 0, reason: 'down again');
      expect(stroll.stroller.buddying, isTrue);
      expect(stroll.stroller.segments.any((s) => s.style == StrollStyle.hang && s.end > stroll.now()), isFalse);
    });

    landmarkTest('Claude\'s news cuts a visit short too', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 0.3);
      expect(stroll.visitNow(StrollVisit.widgets), isTrue);
      expect(await _until(tester, () => stroll.sample()!.lift > 0 && !stroll.moving, 60, elapse), isTrue);
      t.desktop.cue(PetCue.finished);
      await elapse(tester, 3);
      expect(stroll.sample()!.lift, 0);
      expect(stroll.playRoom, isNull, reason: 'the window is small again once it is down');
    });

    landmarkTest('turning the extra off while Mochi hangs ends the visit at once', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 0.3);
      expect(stroll.visitNow(StrollVisit.clock), isTrue);
      expect(await _until(tester, () => stroll.sample()!.lift > 0 && !stroll.moving, 60, elapse), isTrue);
      t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.landmarks: false});
      await elapse(tester, 3);
      expect(stroll.sample()!.lift, 0);
      expect(stroll.stroller.visit, StrollVisit.clock, reason: 'the last visit; none is in the plan any more');
      expect(stroll.stroller.visiting(stroll.now()), isFalse);
    });

    landmarkTest('perf: frames only while it leaps; holds, hangs and perches have no stroll frame timer; nothing while unseen', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 0.3);
      expect(stroll.visitNow(StrollVisit.clock), isTrue);
      var sawFrames = false;
      var hungWithoutFrames = false;
      await elapse(tester, 30, each: () {
        final sample = stroll.sample()!;
        if (sample.travelling && stroll.moving) sawFrames = true;
        if (sample.style == StrollStyle.hang && !sample.travelling) {
          hungWithoutFrames = true;
          expect(stroll.moving, isFalse);
        }
      });
      expect(sawFrames, isTrue, reason: 'the leaps are walking-rate frames');
      expect(hungWithoutFrames, isTrue);
      // The view draws a hang a little more often than a calm loop, and nothing is faster than the walk.
      const hang = StrollSample(x: 0, facing: 1, animation: PetAnimation.idle, animationTime: 0, activity: StrollActivity.swing, style: StrollStyle.hang, lift: 10);
      expect(MochiView.frameRate(mood: PetMood.relaxed, roam: hang, small: true), 12);
      expect(MochiView.frameRate(mood: PetMood.relaxed, roam: hang, small: true, calm: true), 10);
      expect(stroll.visitNow(StrollVisit.start), isTrue);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 5, displaysAsleep: true));
      await elapse(tester, 1);
      expect(stroll.anyTimer, isFalse);
    });

    landmarkTest('while Claude works there are no visits', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 0.3);
      stroll.mood = PetMood.watching;
      await elapse(tester, 0.3);
      expect(stroll.visitNow(StrollVisit.clock), isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Elapses up to [limit] seconds until [done].
Future<bool> _until(
  WidgetTester tester,
  bool Function() done,
  double limit,
  Future<void> Function(WidgetTester, double, {double step, void Function()? each}) elapse,
) async {
  for (var s = 0.0; s < limit; s += 0.1) {
    if (done()) return true;
    await elapse(tester, 0.1);
  }
  return done();
}
