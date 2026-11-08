// The cursor buddy on the taskbar (docs/SPRINT_2.md X4, changed on the user's feedback of 2026-11-08): Mochi never leaves
// the taskbar for it. With Mischief's switch on and Mochi free to wander, a pointer on the taskbar brings it trotting to
// the free spot nearest, never under the pointer; a pointer coming to Mochi stops it at once so it can be clicked; the
// pointer leaving, it goes back to strolling. Driven through the real stroll controller with a fake taskbar and window.

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

void main() {
  late TestDesktop t;
  late FakePetWindow window;
  late FakeShell shell;
  late FakeTaskbar taskbar;

  setUp(() {
    t = TestDesktop.make();
    window = FakePetWindow();
    shell = FakeShell(petWindow: window);
    final reading = FakeTaskbar.bottomTaskbar();
    taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    t.desktop.settings.mischief = const MischiefSettings(enabled: true);
  });

  tearDown(() => t.dispose());

  final strolls = <TaskbarStroll>[];
  final disposables = <void Function()>[];
  void buddyTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final stroll in strolls) {
        stroll.dispose();
      }
      strolls.clear();
      for (final dispose in disposables) {
        dispose();
      }
      disposables.clear();
    }
  });

  Future<TaskbarStroll> start(WidgetTester tester, {SystemMotion? motion, TaskbarInfo? info, int seed = 7}) async {
    final stroll = TaskbarStroll(
      shell: shell,
      taskbar: info ?? taskbar,
      settings: t.desktop.settings,
      motion: motion ?? t.desktop.motion,
      cues: t.desktop.cues,
      rhythm: t.desktop.rhythm,
      mischief: t.desktop.mischief,
      clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
      random: Random(seed),
    );
    strolls.add(stroll);
    unawaited(stroll.show(Surface.pet));
    await tester.pump();
    return stroll;
  }

  Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.1, void Function()? each}) async {
    for (var s = 0.0; s < seconds; s += step) {
      await tester.pump(Duration(microseconds: (step * 1e6).round()));
      each?.call();
    }
  }

  /// The pointer at [x] (logical) in the middle of the taskbar.
  void pointAt(TaskbarStroll stroll, double x) {
    final bar = stroll.stage!.bar;
    taskbar.pointer = ((x * stroll.stage!.scale).round(), bar.top + bar.height ~/ 2);
  }

  /// The pointer on the desktop, above the taskbar.
  void pointAway() => taskbar.pointer = (300, 300);

  double mochi(TaskbarStroll stroll) => stroll.sample()!.x;
  double bodyWidth(TaskbarStroll stroll) => stroll.stage!.box.height * 0.95;

  /// A free spot far from Mochi (the other stretch's middle), for the pointer to be at.
  double farFrom(TaskbarStroll stroll) {
    final zones = stroll.stage!.zones;
    final here = mochi(stroll);
    final far = zones.reduce((a, b) => ((a.minX + a.maxX) / 2 - here).abs() > ((b.minX + b.maxX) / 2 - here).abs() ? a : b);
    return (far.minX + far.maxX) / 2;
  }

  /// The far end of the stretch Mochi is in: a walk away, with no hop in it.
  double farInZone(TaskbarStroll stroll) {
    final here = mochi(stroll);
    final zone = stroll.stage!.zones.firstWhere((zone) => here >= zone.minX - 1 && here <= zone.maxX + 1);
    return (here - zone.minX) > (zone.maxX - here) ? zone.minX + 20 : zone.maxX - 20;
  }

  bool inFreeStretch(TaskbarStroll stroll, double x) => stroll.stage!.zones.any((zone) => x >= zone.minX - 1 && x <= zone.maxX + 1);

  buddyTest('a pointer on the taskbar brings Mochi to the free spot beside it, never under it, and only in free stretches', (tester) async {
    final stroll = await start(tester);
    final w = bodyWidth(stroll);
    final target = farFrom(stroll);
    pointAt(stroll, target);
    var travelled = false;
    await elapse(
      tester,
      30,
      each: () {
        final x = mochi(stroll);
        if (stroll.sample()!.travelling) travelled = true;
        expect(inFreeStretch(stroll, x), isTrue, reason: 'never over a button: $x');
        expect((x - target).abs(), greaterThanOrEqualTo(w * 0.99), reason: 'never under the pointer: $x vs $target');
      },
    );
    expect(travelled, isTrue);
    expect(stroll.stroller.buddying, isTrue);
    expect((mochi(stroll) - target).abs(), lessThanOrEqualTo(Stroller.buddyNear * w + 1), reason: 'beside the pointer');
    expect(stroll.placement, PetPlacement.taskbar, reason: 'never leaves the taskbar');
    expect(shell.shows.last.surface, Surface.pet);

    // The pointer wanders along the taskbar: Mochi keeps up, and still never stands under it.
    for (final x in [target - 40, target - 90, target - 160, target - 100]) {
      pointAt(stroll, x);
      await elapse(
        tester,
        6,
        each: () {
          expect(inFreeStretch(stroll, mochi(stroll)), isTrue);
          if (stroll.sample()!.travelling) expect((mochi(stroll) - x).abs(), greaterThanOrEqualTo(w * 0.99));
        },
      );
    }
  });

  buddyTest('a pointer coming to Mochi stops it at once: it faces you, holds still and takes the click', (tester) async {
    final stroll = await start(tester);
    final w = bodyWidth(stroll);
    pointAt(stroll, farInZone(stroll));
    await elapse(tester, 1.5);
    expect(stroll.moving, isTrue, reason: 'on its way');
    // The pointer comes back to Mochi.
    final where = mochi(stroll);
    pointAt(stroll, where + 1.4 * w);
    await elapse(tester, 0.3);
    expect(stroll.sample()!.travelling, isFalse, reason: 'stopped at once');
    expect(stroll.moving, isFalse);
    final stopped = mochi(stroll);
    expect(stroll.sample()!.style, StrollStyle.attentive, reason: 'facing you');
    // Over Mochi and across it: it never moves away.
    for (final dx in [0.8 * w, 0.3 * w, 0.0, -0.4 * w, -1.2 * w, 0.0]) {
      pointAt(stroll, stopped + dx);
      await elapse(tester, 1);
      expect(mochi(stroll), stopped, reason: 'holds still for a pointer at $dx');
      expect(stroll.moving, isFalse);
    }
    // Its window takes the click over its body.
    final body = stroll.stage!.body(stroll.frame!);
    taskbar.pointer = (body.left + body.width ~/ 2, body.top + body.height ~/ 2);
    await elapse(tester, 0.3);
    expect(window.clickThrough.last, isFalse, reason: 'a click opens it, a drag drags it, a right-click is its menu');
    expect(stroll.clickThrough, isFalse);
  });

  buddyTest('the pointer stops: a pounce or a sit facing it; nothing runs while it sits', (tester) async {
    final stroll = await start(tester);
    pointAt(stroll, farFrom(stroll));
    await elapse(tester, 40);
    final x = mochi(stroll);
    expect(stroll.moving, isFalse);
    expect(stroll.waiting, isFalse, reason: 'no wake-up either: it sits for as long as the pointer rests');
    expect(stroll.sample()!.facing, (taskbar.pointer!.$1 / stroll.stage!.scale >= x) ? 1 : -1, reason: 'faces the pointer');
    await elapse(tester, 30);
    expect(mochi(stroll), x);
    expect(stroll.moving || stroll.waiting, isFalse);
  });

  buddyTest('the pointer leaves the taskbar: Mochi watches a second or two, then strolls as usual', (tester) async {
    final stroll = await start(tester, seed: 5);
    pointAt(stroll, farFrom(stroll));
    await elapse(tester, 40);
    expect(stroll.stroller.buddying, isTrue);
    pointAway();
    await elapse(tester, 1);
    expect(stroll.stroller.buddying, isTrue, reason: 'still watching');
    await elapse(tester, 1.5);
    expect(stroll.stroller.buddying, isFalse);
    final moves = window.moves.length;
    await elapse(tester, 240, step: 0.5);
    expect(window.moves.length, greaterThan(moves), reason: 'strolling again');
  });

  buddyTest('playing in its spot, it follows only within its room', (tester) async {
    t.desktop.settings.petStyle = DesktopStyle.spot;
    final stroll = await start(tester);
    final room = stroll.stroller.line!;
    for (final x in [20.0, 1900.0, room.minX - 120, room.maxX + 120]) {
      pointAt(stroll, x);
      await elapse(
        tester,
        15,
        each: () {
          final here = mochi(stroll);
          expect(here, inInclusiveRange(room.minX - 0.5, room.maxX + 0.5), reason: 'in its room: $here');
        },
      );
    }
  });

  buddyTest('with the cursor buddy or Mischief turned off it does nothing', (tester) async {
    final stroll = await start(tester);
    t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.cursorBuddy: false});
    pointAt(stroll, farFrom(stroll));
    await elapse(tester, 20);
    expect(stroll.stroller.buddying, isFalse);
    expect(taskbar.pointer!.$1 / stroll.stage!.scale, isNot(closeTo(mochi(stroll), 120)), reason: 'it did not go to the pointer');
    t.desktop.settings.mischief = const MischiefSettings(enabled: false);
    await elapse(tester, 5);
    expect(stroll.stroller.buddying, isFalse);
  });

  buddyTest('with animation effects off Mochi stays put', (tester) async {
    final motion = SystemMotion(read: () => true);
    disposables.add(motion.dispose);
    final stroll = await start(tester, motion: motion);
    final x = mochi(stroll);
    pointAt(stroll, farFrom(stroll));
    await elapse(tester, 20);
    expect(stroll.stroller.buddying, isFalse);
    expect(mochi(stroll), x);
  });

  buddyTest('switched off while it keeps the pointer company: back to the stroll at once', (tester) async {
    final stroll = await start(tester);
    pointAt(stroll, farFrom(stroll));
    await elapse(tester, 40);
    expect(stroll.stroller.buddying, isTrue);
    t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.cursorBuddy: false});
    await elapse(tester, 0.3);
    expect(stroll.stroller.buddying, isFalse);
  });

  buddyTest('on the desktop (not the taskbar) the buddy does nothing', (tester) async {
    final reading = FakeTaskbar.bottomTaskbar(autoHide: true);
    final hiding = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    final stroll = await start(tester, info: hiding);
    expect(stroll.placement, PetPlacement.standing);
    hiding.pointer = (500, reading.bounds.top + 20);
    await elapse(tester, 10);
    expect(stroll.sample(), isNull);
    expect(stroll.stroller.buddying, isFalse);
    expect(stroll.watchingPointer, isFalse);
    expect(stroll.anyTimer, stroll.checking, reason: 'only the full-screen check runs');
  });

  buddyTest('no frames, pointer reads or buddy while nobody can see the screen', (tester) async {
    final stroll = await start(tester);
    pointAt(stroll, farInZone(stroll));
    await elapse(tester, 1.5);
    expect(stroll.moving, isTrue);
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
    await tester.pump();
    expect(stroll.paused, isTrue);
    expect(stroll.anyTimer, isFalse);
    final moves = window.moves.length;
    final reads = taskbar.cursorReads;
    pointAt(stroll, 100);
    await elapse(tester, 20);
    expect(window.moves.length, moves);
    expect(taskbar.cursorReads, reads, reason: 'the pointer is not read');
    expect(stroll.anyTimer, isFalse);
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 0));
    await elapse(tester, 1);
    expect(stroll.paused, isFalse);
  });
}
