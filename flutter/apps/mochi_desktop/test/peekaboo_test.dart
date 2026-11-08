// Peekaboo (docs/SPRINT_2.md X3): out on the desktop, Mochi's actor isn't topmost and sits just below the window you're
// using, placed again only when that window changes; topmost as before with the switch off; the top of the normal band
// for our own windows, the desktop and the shell; and no foreground reads while Mochi is home or the screen is unseen.
// (The taskbar's hide-while-you're-away is in taskbar_peekaboo_test.dart.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/foreground_window.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect;
import 'package:mochi_desktop/src/platform/window_frames.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart' show PetHome;
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';

import 'support/fake_stage.dart';
import 'support/fakes.dart';

class _Home extends ChangeNotifier implements PetHome {
  bool showing = true;

  @override
  bool out = false;

  @override
  bool get canGoOut => showing && !out;

  @override
  ({int x, int y, double scale, double facing, double unit})? departure() => showing ? (x: 300, y: 1068, scale: 1, facing: 1.0, unit: 0.56) : null;

  @override
  void goOut() {
    out = true;
    notifyListeners();
  }

  @override
  void comeBack({int? x}) {
    out = false;
    notifyListeners();
  }
}

void main() {
  const editor = WindowFrame(hwnd: 11, frame: PixelRect(400, 300, 1100, 800));
  const editorFront = ForegroundWindow(11, ForegroundKind.app);
  const browserFront = ForegroundWindow(12, ForegroundKind.app);

  late TestDesktop t;
  late FakeNativeStage stage;
  late _Home home;
  late FakeForegroundWindows foreground;
  late MischiefStage mischief;
  var now = DateTime(2026, 11, 8, 15);

  setUp(() {
    now = DateTime(2026, 11, 8, 15);
    t = TestDesktop.make(clock: () => now, activity: const SystemActivity(idleSeconds: 1));
    t.desktop.rhythm.sample();
    stage = FakeNativeStage();
    home = _Home();
    foreground = FakeForegroundWindows(editorFront);
    mischief = MischiefStage(
      desktop: t.desktop,
      stage: stage,
      displays: FakeDisplays(),
      cursor: () => null,
      home: home,
      frames: FakeWindowFrames([editor]),
      foreground: foreground,
    );
    t.desktop.mischief.start();
    mischief.start();
  });

  tearDown(() async {
    mischief.dispose();
    await t.dispose();
  });

  Future<void> run(WidgetTester tester, double seconds) async {
    for (var i = 0; i < (seconds * 1000 / 33).ceil(); i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  /// Sets Mochi off and lets its first picture get drawn and shown.
  Future<void> goOut(WidgetTester tester) async {
    mischief.adventure!.explore();
    for (var i = 0; i < 20 && stage.showing.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(stage.showing, isNotEmpty, reason: 'Mochi is shown');
  }

  Future<void> done(WidgetTester tester) async {
    mischief.adventure?.stop();
    mischief.roamer?.stop();
    t.desktop.mischief.stop();
    await tester.pump();
  }

  void peekaboo(bool on) =>
      t.desktop.settings.mischief = MischiefSettings(enabled: true, extras: {MischiefExtra.peekaboo: on});

  group('behind the window you are using', () {
    testWidgets('with Peekaboo on, the actor is not topmost and goes just below the foreground window', (tester) async {
      peekaboo(true);
      await goOut(tester);
      final actor = mischief.pet!.actor;
      expect(stage.showing[actor]!.topmost, isFalse);
      expect(stage.belows, [(actor, 11)]);
      await done(tester);
    });

    testWidgets('it is placed again only when the foreground window changes', (tester) async {
      peekaboo(true);
      await goOut(tester);
      final actor = mischief.pet!.actor;
      await run(tester, 3);
      expect(stage.belows, [(actor, 11)], reason: 'still the same window: no more calls, though it was read');
      expect(foreground.reads, greaterThan(5), reason: 'read three times a second');
      foreground.window = browserFront;
      await run(tester, 1);
      expect(stage.belows, [(actor, 11), (actor, 12)]);
      await run(tester, 2);
      expect(stage.belows, hasLength(2));
      await done(tester);
    });

    testWidgets('our own windows, the desktop and the shell: the top of the normal band, below nothing', (tester) async {
      peekaboo(true);
      await goOut(tester);
      final actor = mischief.pet!.actor;
      final raises = stage.callsTo('raise');
      foreground.window = const ForegroundWindow(77, ForegroundKind.ours);
      await run(tester, 1);
      expect(stage.callsTo('raise'), raises + 1);
      foreground.window = const ForegroundWindow(0, ForegroundKind.shell);
      await run(tester, 1);
      expect(stage.callsTo('raise'), raises + 2);
      expect(stage.belows, [(actor, 11)], reason: 'only the app window put it below');
      expect(stage.showing[actor]!.topmost, isFalse);
      await done(tester);
    });

    testWidgets('with the switch off the actor stays topmost and the foreground is never read', (tester) async {
      peekaboo(false);
      await goOut(tester);
      await run(tester, 2);
      expect(stage.showing[mischief.pet!.actor]!.topmost, isTrue);
      expect(stage.belows, isEmpty);
      expect(foreground.reads, 0);
      await done(tester);
    });

    testWidgets('the switch coming on while Mochi is out shows it non-topmost before placing it below', (tester) async {
      peekaboo(false);
      await goOut(tester);
      expect(stage.showing[mischief.pet!.actor]!.topmost, isTrue);
      peekaboo(true);
      await run(tester, 1);
      expect(stage.showing[mischief.pet!.actor]!.topmost, isFalse);
      expect(stage.belows, hasLength(1));
      final order = stage.calls.lastIndexOf('below');
      expect(stage.calls.sublist(0, order).contains('show'), isTrue);
      peekaboo(false);
      await run(tester, 1);
      expect(stage.showing[mischief.pet!.actor]!.topmost, isTrue, reason: 'back above everything');
      await done(tester);
    });

    testWidgets('the periodic raise does not lift it over the window you are using', (tester) async {
      peekaboo(true);
      await goOut(tester);
      final raises = stage.callsTo('raise');
      await run(tester, 6);
      expect(stage.callsTo('raise'), raises, reason: 'the adventure raises it every couple of seconds; not while it hides');
      await done(tester);
    });

    testWidgets('nothing is read while Mochi is home, or while nobody can see the screen', (tester) async {
      peekaboo(true);
      await run(tester, 2);
      expect(foreground.reads, 0, reason: 'home');
      expect(mischief.pet!.behind!.watching, isFalse);
      await goOut(tester);
      expect(mischief.pet!.behind!.watching, isTrue);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1, displaysAsleep: true));
      await tester.pump();
      await run(tester, 1);
      final reads = foreground.reads;
      await run(tester, 3);
      expect(foreground.reads, reads, reason: 'unseen: it went home and nothing is read');
      expect(mischief.pet!.behind!.watching, isFalse);
      await done(tester);
    });
  });

  test('Peekaboo is a moving extra with a switch in Settings', () {
    expect(MischiefExtra.available, contains(MischiefExtra.peekaboo));
    expect(MischiefExtra.peekaboo.moves, isTrue);
    expect(MischiefExtra.peekaboo.title, 'Peekaboo');
  });
}
