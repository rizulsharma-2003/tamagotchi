// Where clicks reach Mochi (and Patch) on the taskbar, at 100%, 150% and 200% display scale, with a fake taskbar,
// a fake window and the test's clock: the window lets clicks through everywhere but on their bodies, measured in
// the physical pixels Windows reports the pointer in, and the bodies are where they're drawn (the middle of Mochi's
// window). Also when Windows keeps the window bigger than asked (a window with a title bar is at least 136 × 39 at
// 100%), which once left Mochi drawn off the spot its clicks were checked at, so a click on it did nothing.

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

void main() {
  late TestDesktop t;

  setUp(() => t = TestDesktop.make());
  tearDown(() => t.dispose());

  final disposables = <void Function()>[];
  void hitTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final dispose in disposables.reversed) {
        dispose();
      }
      disposables.clear();
    }
  });

  /// A 1920 × 1080 (logical) screen at [scale], its taskbar with Windows 11's buttons, and the stroll on it.
  Future<(TaskbarStroll, FakePetWindow, FakeTaskbar)> start(WidgetTester tester, double scale, {(int, int)? minimum, bool patch = false}) async {
    final reading = FakeTaskbar.bottomTaskbar(width: (1920 * scale).round(), height: (1080 * scale).round(), scale: scale);
    final taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    final window = FakePetWindow(minimum: minimum);
    double clock() => tester.binding.clock.now().microsecondsSinceEpoch / 1e6;
    CompanionDirector? companion;
    if (patch) {
      companion = CompanionDirector(t.desktop.world);
      disposables.add(companion.dispose);
      t.desktop.receive(hook('SessionStart', at: DateTime.now()));
    }
    final stroll = TaskbarStroll(
      shell: FakeShell(petWindow: window),
      taskbar: taskbar,
      settings: t.desktop.settings,
      motion: t.desktop.motion,
      cues: t.desktop.cues,
      companion: companion,
      clock: clock,
      random: Random(3),
    );
    disposables.add(stroll.dispose);
    unawaited(stroll.show(Surface.pet));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return (stroll, window, taskbar);
  }

  /// Puts the pointer at [point] and lets the stroll look (it checks 10 times a second).
  Future<bool> clicksThroughAt(WidgetTester tester, FakeTaskbar taskbar, FakePetWindow window, (int, int) point) async {
    taskbar.pointer = point;
    await tester.pump(const Duration(milliseconds: 150));
    return window.clickThrough.isEmpty || window.clickThrough.last;
  }

  hitTest('near Mochi the pointer is checked three times as often, so a quick click still lands', (tester) async {
    final (stroll, window, taskbar) = await start(tester, 1);
    final body = stroll.bodies().single;
    expect(stroll.pointerNear, isFalse);
    taskbar.pointer = (body.left - 60, body.top + 5);
    await tester.pump(const Duration(milliseconds: 120));
    expect(stroll.pointerNear, isTrue, reason: 'close to Mochi');
    // Onto Mochi: clicks are let in within one fast check.
    taskbar.pointer = ((body.left + body.right) ~/ 2, (body.top + body.bottom) ~/ 2);
    await tester.pump(const Duration(milliseconds: 40));
    expect(window.clickThrough.last, isFalse);
    taskbar.pointer = (body.right + 400, body.top);
    await tester.pump(const Duration(milliseconds: 120));
    expect(stroll.pointerNear, isFalse, reason: 'far away: the usual pace');
    expect(window.clickThrough.last, isTrue);
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    final percent = '${(scale * 100).round()}%';

    hitTest('$percent: Mochi takes clicks on its body, where it is drawn, and nowhere else', (tester) async {
      final (stroll, window, taskbar) = await start(tester, scale);
      final frame = stroll.frame!;
      final body = stroll.bodies().single;
      final box = stroll.box;
      // Mochi is drawn in the middle of its window, filling its box's height.
      expect((body.left + body.right) / 2, closeTo((frame.left + frame.right) / 2, 1));
      expect((body.height, body.bottom), ((box.height * scale).round(), frame.bottom));
      expect(body.width, closeTo(box.height * 0.95 * scale, 1));
      final centre = ((frame.left + frame.right) ~/ 2, (frame.top + frame.bottom) ~/ 2);
      expect(await clicksThroughAt(tester, taskbar, window, centre), isFalse, reason: 'on Mochi: it takes the click');
      expect(await clicksThroughAt(tester, taskbar, window, (body.right + 1, centre.$2)), isTrue, reason: 'just right of it');
      expect(await clicksThroughAt(tester, taskbar, window, (body.left - 2, centre.$2)), isTrue, reason: 'just left of it');
      expect(await clicksThroughAt(tester, taskbar, window, (frame.left + 1, frame.top + 1)), isTrue, reason: 'the corner of its window');
      expect(await clicksThroughAt(tester, taskbar, window, (body.left + 1, body.bottom - 1)), isFalse, reason: 'the edge of its body');
    });

    hitTest('$percent: a window Windows keeps bigger than asked is centred on Mochi, and clicks still reach it', (tester) async {
      final minimum = ((136 * scale).round(), (39 * scale).round());
      final (stroll, window, taskbar) = await start(tester, scale, minimum: minimum);
      final frame = stroll.frame!;
      expect(frame, window.current, reason: 'the stroll goes by the window it really has');
      expect(frame.width, minimum.$1);
      final x = stroll.sample()!.x * scale;
      expect((frame.left + frame.right) / 2, closeTo(x, 2), reason: 'Mochi, drawn in the middle, is on its spot');
      final centre = ((frame.left + frame.right) ~/ 2, frame.bottom - (stroll.box.height * scale / 2).round());
      expect(await clicksThroughAt(tester, taskbar, window, centre), isFalse, reason: 'a click on the Mochi you see reaches it');
      // It walks: every move keeps the real size, centred on Mochi.
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(window.moves, isNotEmpty);
      for (final move in window.moves.skip(1)) {
        expect(move.width, minimum.$1);
      }
      final now = stroll.frame!;
      expect((now.left + now.right) / 2, closeTo(stroll.sample()!.x * scale, 2));
    });

    hitTest('$percent: with Patch, both bodies take clicks, in the window, side by side', (tester) async {
      final (stroll, window, taskbar) = await start(tester, scale, patch: true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(stroll.home, isNotNull);
      final frame = stroll.frame!;
      final bodies = stroll.bodies();
      expect(bodies, hasLength(2));
      for (final body in bodies) {
        expect(body.left >= frame.left && body.right <= frame.right && body.top >= frame.top && body.bottom <= frame.bottom, isTrue);
        expect(await clicksThroughAt(tester, taskbar, window, ((body.left + body.right) ~/ 2, (body.top + body.bottom) ~/ 2)), isFalse);
      }
      final gap = ((bodies.first.right + bodies.last.left) ~/ 2, bodies.last.bottom - 2);
      if (bodies.last.left - bodies.first.right > 2) expect(await clicksThroughAt(tester, taskbar, window, gap), isTrue);
    });
  }
}
