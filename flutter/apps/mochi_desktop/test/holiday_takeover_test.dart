// Holiday takeover (docs/SPRINT_2.md X11): Diwali lights or Christmas snow along the top of the window you're using,
// pumpkins on the taskbar at Halloween, nothing on other days; never on a maximised, full-screen, minimised, tiny or
// our own window; clear of the caption buttons; hidden while the window moves; following the focus; no timer while
// it can't run; a preview for 20 seconds and the development switch.

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/foreground_window.dart';
import 'package:mochi_desktop/src/platform/native_stage.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect, TaskbarStage;
import 'package:mochi_desktop/src/platform/window_frames.dart';
import 'package:mochi_desktop/src/ui/stage/holiday_takeover.dart';
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fake_stage.dart';
import 'support/fakes.dart';

void main() {
  const editor = WindowFrame(hwnd: 11, frame: PixelRect(400, 300, 1100, 800));
  const browser = WindowFrame(hwnd: 12, frame: PixelRect(200, 200, 1500, 900));
  const editorFront = ForegroundWindow(11, ForegroundKind.app);
  const browserFront = ForegroundWindow(12, ForegroundKind.app);

  late TestDesktop t;
  late FakeNativeStage stage;
  late FakeForegroundWindows foreground;
  late FakeWindowFrames frames;
  late MischiefStage mischief;
  var today = DateTime(2026, 11, 8, 15);
  TaskbarStage? bar;

  // The desktop is made before each test (outside its fake clock); the day is set when a test builds its stage.
  setUp(() {
    bar = null;
    today = DateTime(2026, 11, 8, 15);
    t = TestDesktop.make(clock: () => today, activity: const SystemActivity(idleSeconds: 1));
    t.desktop.rhythm.sample();
  });

  tearDown(() async {
    await t.dispose();
  });

  /// A MischiefStage on [day] (Diwali on 2026-11-08, Christmas on the 25th of December, Halloween on the 31st of October).
  void make(DateTime day, {w.SeasonalEvent? force, List<WindowFrame>? windows, ForegroundWindow? front = editorFront}) {
    today = day;
    t.desktop.holidays.refresh(greet: false);
    stage = FakeNativeStage();
    foreground = FakeForegroundWindows(front);
    frames = FakeWindowFrames(windows ?? [editor, browser]);
    mischief = MischiefStage(
      desktop: t.desktop,
      stage: stage,
      displays: FakeDisplays(),
      cursor: () => null,
      frames: frames,
      foreground: foreground,
      clock: testSeconds,
      taskbar: () => bar,
      takeoverOccasion: force,
    );
    t.desktop.settings.mischief = const MischiefSettings(enabled: true);
    t.desktop.mischief.start();
    mischief.start();
  }

  /// A widget test that puts everything away at its end (before the test's check for timers still pending).
  void scene(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        mischief.dispose();
        t.desktop.mischief.stop();
      }
    });
  }

  /// Time passes in 100 ms steps, with the real clock moving a little so the pictures can be drawn.
  Future<void> run(WidgetTester tester, double seconds) async {
    for (var i = 0; i < (seconds * 10).round(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 12)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  StageShot? decoration() => stage.showing.values.firstOrNull;

  /// Where the strip's origin (its top-left on the window's top edge) is on the screen: the picture starts 26 logical
  /// pixels above it and 6 to its left (give or take a pixel of rounding).
  int edgeY(StageShot shot) => shot.top + 26;
  int edgeX(StageShot shot) => shot.left + 6;

  group('Diwali lights along the window you are using', () {
    scene('a string of lights sits on the top edge, click-through, in the normal band, clear of the caption buttons', (tester) async {
      make(DateTime(2026, 11, 8, 15));
      await run(tester, 2);
      final shot = decoration()!;
      expect(stage.showing, hasLength(1));
      expect(edgeY(shot), closeTo(300, 2), reason: 'its origin is the window’s top edge, and the art sits above it');
      expect(edgeX(shot), closeTo(412, 2), reason: 'a little in from the corner');
      expect(shot.clickThrough, isTrue);
      expect(shot.topmost, isFalse);
      expect(stage.callsTo('raise'), greaterThan(0));
      final sprite = stage.sprites[shot.sprite]!;
      // The art starts 6 pixels into the picture; it must stop 150 pixels short of the window's right edge.
      expect(edgeX(shot) + sprite.width - 12, lessThanOrEqualTo(1100 - 150 + 2));
      expect(sprite.width, greaterThan(300), reason: 'the strip spans most of the top edge');
    });

    scene('it twinkles at no more than four a second', (tester) async {
      make(DateTime(2026, 11, 8, 15));
      await run(tester, 2);
      final before = stage.shots.length;
      await run(tester, 3);
      final changes = stage.shots.skip(before).map((shot) => shot.sprite).toSet();
      final sent = stage.shots.length - before;
      expect(sent, inInclusiveRange(1, 12), reason: 'at most 4 a second over 3 seconds');
      expect(changes.length, greaterThan(1), reason: 'the lights do twinkle');
    });

    scene('with animation effects off nothing runs: the lights wait', (tester) async {
      make(DateTime(2026, 11, 8, 15));
      await run(tester, 2);
      expect(stage.showing, isNotEmpty);
      t.desktop.motion.value = true;
      await run(tester, 1);
      expect(stage.showing, isEmpty);
      expect(mischief.takeover.watching, isFalse);
    });
  });

  group('Christmas snow', () {
    scene('a cap of snow sits on the window, not twinkling', (tester) async {
      make(DateTime(2026, 12, 25, 15));
      await run(tester, 2);
      final shot = decoration()!;
      expect(mischief.takeover.active, w.SeasonalEvent.christmas);
      expect(edgeY(shot), closeTo(300, 2));
      expect(shot.clickThrough, isTrue);
      final before = stage.shots.length;
      await run(tester, 3);
      expect(stage.shots.length, before, reason: 'a picture that does not change sends nothing');
    });
  });

  group('which windows get it', () {
    Future<void> expectNone(WidgetTester tester, WindowFrame window, {ForegroundWindow? front, bool minimised = false}) async {
      frames.windows = [window];
      if (minimised) frames.minimised.add(window.hwnd);
      foreground.window = front ?? ForegroundWindow(window.hwnd, ForegroundKind.app);
      await run(tester, 2);
      expect(stage.showing, isEmpty, reason: '$window');
    }

    scene('not maximised, full-screen, minimised, tiny or with no room above; not ours, the desktop or the taskbar', (tester) async {
      make(DateTime(2026, 11, 8, 15), windows: [editor]);
      await run(tester, 2);
      expect(stage.showing, isNotEmpty, reason: 'a normal window does');
      await expectNone(tester, const WindowFrame(hwnd: 21, frame: PixelRect(0, 0, 1920, 1032), zoomed: true));
      await expectNone(tester, const WindowFrame(hwnd: 22, frame: PixelRect(0, 0, 1920, 1080)));
      await expectNone(tester, const WindowFrame(hwnd: 23, frame: PixelRect(400, 300, 640, 700)));
      await expectNone(tester, const WindowFrame(hwnd: 24, frame: PixelRect(400, 8, 1400, 700)));
      await expectNone(tester, const WindowFrame(hwnd: 25, frame: PixelRect(400, 300, 1400, 700)), minimised: true);
      await expectNone(tester, const WindowFrame(hwnd: 26, frame: PixelRect(400, 300, 1400, 700)), front: const ForegroundWindow(26, ForegroundKind.ours));
      await expectNone(tester, const WindowFrame(hwnd: 27, frame: PixelRect(400, 300, 1400, 700)), front: const ForegroundWindow(0, ForegroundKind.shell));
      await expectNone(tester, const WindowFrame(hwnd: 28, frame: PixelRect(400, 300, 1400, 700)), front: ForegroundWindow(99, ForegroundKind.app));
    });

    scene('only the window with the focus is decorated, not every window', (tester) async {
      make(DateTime(2026, 11, 8, 15), windows: [editor, browser]);
      await run(tester, 2);
      expect(stage.showing, hasLength(1), reason: 'not every window');
      expect(edgeY(decoration()!), closeTo(300, 2));
    });
  });

  group('while the window moves', () {
    scene('it is hidden when the frame changes and back once the frame has been still for half a second', (tester) async {
      make(DateTime(2026, 11, 8, 15));
      await run(tester, 2);
      expect(stage.showing, isNotEmpty);
      frames.windows = [const WindowFrame(hwnd: 11, frame: PixelRect(420, 320, 1120, 820)), browser];
      await run(tester, 0.4);
      expect(stage.showing, isEmpty, reason: 'moving');
      frames.windows = [const WindowFrame(hwnd: 11, frame: PixelRect(440, 340, 1140, 840)), browser];
      await run(tester, 0.4);
      expect(stage.showing, isEmpty, reason: 'still moving');
      await run(tester, 1.5);
      final shot = decoration()!;
      expect(edgeY(shot), closeTo(340, 2));
      expect(edgeX(shot), closeTo(452, 2));
    });
  });

  group('the focus moves', () {
    scene('the decoration goes to the new window', (tester) async {
      make(DateTime(2026, 11, 8, 15));
      await run(tester, 2);
      expect(edgeY(decoration()!), closeTo(300, 2));
      foreground.window = browserFront;
      await run(tester, 1.5);
      final shot = decoration()!;
      expect(edgeY(shot), closeTo(200, 2));
      expect(edgeX(shot), closeTo(212, 2));
      expect(stage.showing, hasLength(1));
    });
  });

  group('no timers when it cannot run', () {
    scene('none while Mischief is off, none while nobody can see the screen, and nothing read', (tester) async {
      make(DateTime(2026, 11, 8, 15));
      await run(tester, 1);
      expect(mischief.takeover.watching, isTrue);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1, displaysAsleep: true));
      await run(tester, 0.2);
      expect(mischief.takeover.watching, isFalse, reason: 'unseen');
      expect(stage.showing, isEmpty);
      final reads = foreground.reads;
      await run(tester, 3);
      expect(foreground.reads, reads);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1));
      await run(tester, 1);
      expect(mischief.takeover.watching, isTrue);
      t.desktop.settings.mischief = const MischiefSettings();
      await run(tester, 0.3);
      expect(mischief.takeover.watching, isFalse, reason: 'Mischief off');
      expect(stage.showing, isEmpty);
      final after = foreground.reads;
      await run(tester, 3);
      expect(foreground.reads, after);
    });

    scene('the extra’s own switch puts it away too', (tester) async {
      make(DateTime(2026, 11, 8, 15));
      await run(tester, 2);
      expect(stage.showing, isNotEmpty);
      t.desktop.settings.mischief = const MischiefSettings(enabled: true).withExtra(MischiefExtra.holidayTakeover, false);
      await run(tester, 0.3);
      expect(stage.showing, isEmpty);
      expect(mischief.takeover.watching, isFalse);
    });

    scene('read three times a second while it runs', (tester) async {
      make(DateTime(2026, 11, 8, 15));
      await run(tester, 1);
      final reads = foreground.reads;
      await run(tester, 3);
      expect(foreground.reads - reads, inInclusiveRange(8, 10));
    });
  });

  group('only on the right occasions', () {
    scene('New Year’s Day and an ordinary day: nothing, and no timer', (tester) async {
      make(DateTime(2027, 1, 1, 15));
      await run(tester, 2);
      expect(stage.showing, isEmpty);
      expect(mischief.takeover.watching, isFalse);
      expect(HolidayTakeover.takes(w.SeasonalEvent.newYear), isFalse);
      expect(HolidayTakeover.takes(w.SeasonalEvent.valentines), isFalse);
      expect(HolidayTakeover.takes(w.SeasonalEvent.userBirthday), isFalse);
      expect(HolidayTakeover.takes(w.SeasonalEvent.mochiBirthday), isFalse);
      expect(HolidayTakeover.takes(null), isFalse);
    });

    scene('with holidays turned off in Settings › Fun there is none', (tester) async {
      make(DateTime(2026, 11, 8, 15));
      await run(tester, 2);
      expect(stage.showing, isNotEmpty);
      t.desktop.settings.holidays = false;
      await run(tester, 0.5);
      expect(stage.showing, isEmpty);
      expect(mischief.takeover.watching, isFalse);
    });
  });

  group('Halloween pumpkins on the taskbar', () {
    TaskbarStage taskbar(List<({double minX, double maxX})> zones, {bool measured = true}) =>
        TaskbarStage(bar: const PixelRect(0, 1032, 1920, 1080), scale: 1, zones: zones, measured: measured);

    scene('two or three of them stand in the widest free stretch, click-through, never past it', (tester) async {
      bar = taskbar([(minX: 100, maxX: 160), (minX: 700, maxX: 1000)]);
      make(DateTime(2026, 10, 31, 15), windows: []);
      await run(tester, 4.5);
      final shots = stage.showing.values.toList();
      expect(shots, hasLength(3));
      for (final shot in shots) {
        expect(shot.clickThrough, isTrue);
        expect(shot.topmost, isTrue);
        final sprite = stage.sprites[shot.sprite]!;
        final centre = shot.left + sprite.width / 2;
        expect(centre, inInclusiveRange(700, 1000), reason: 'in the free stretch, not over a button');
      }
      expect(shots.map((shot) => shot.top).toSet(), hasLength(1), reason: 'on one line, the taskbar’s');
      expect(shots.first.top, lessThan(1080));
      expect(foreground.reads, 0, reason: 'no window reads for pumpkins');
    });

    scene('none when no stretch is roomy enough, or the buttons are only estimated, or there is no taskbar', (tester) async {
      bar = taskbar([(minX: 100, maxX: 130), (minX: 700, maxX: 720)]);
      make(DateTime(2026, 10, 31, 15), windows: []);
      await run(tester, 2);
      expect(stage.showing, isEmpty);
      bar = taskbar([(minX: 700, maxX: 1000)], measured: false);
      await run(tester, 2.5);
      expect(stage.showing, isEmpty);
      bar = null;
      await run(tester, 2.5);
      expect(stage.showing, isEmpty);
      bar = taskbar([(minX: 700, maxX: 1000)]);
      await run(tester, 4.5);
      expect(stage.showing, isNotEmpty);
      bar = null;
      await run(tester, 2.5);
      expect(stage.showing, isEmpty, reason: 'the pumpkins go with the stretch');
    });

    scene('they are looked for every two seconds, not at the window rate', (tester) async {
      bar = taskbar([(minX: 700, maxX: 1000)]);
      make(DateTime(2026, 10, 31, 15), windows: []);
      await run(tester, 2);
      expect(mischief.takeover.watching, isTrue);
      final before = stage.calls.length;
      await run(tester, 6);
      expect(stage.calls.length, before, reason: 'nothing changed: nothing sent');
    });
  });

  group('the development switch', () {
    test('MOCHI_DESKTOP_TAKEOVER names an occasion', () {
      expect(MischiefStage.takeoverFrom('diwali'), w.SeasonalEvent.diwali);
      expect(MischiefStage.takeoverFrom(' Christmas '), w.SeasonalEvent.christmas);
      expect(MischiefStage.takeoverFrom('HALLOWEEN'), w.SeasonalEvent.halloween);
      expect(MischiefStage.takeoverFrom('easter'), isNull);
      expect(MischiefStage.takeoverFrom(null), isNull);
      expect(MischiefStage.takeoverFrom('newYear'), isNull);
    });

    scene('it forces an occasion on an ordinary day', (tester) async {
      make(DateTime(2027, 3, 3, 15), force: w.SeasonalEvent.christmas);
      await run(tester, 2);
      expect(mischief.takeover.active, w.SeasonalEvent.christmas);
      expect(stage.showing, isNotEmpty);
    });
  });

  group('Try it', () {
    scene('an occasion for 20 seconds, then today’s own', (tester) async {
      make(DateTime(2027, 3, 3, 15));
      await run(tester, 1);
      expect(stage.showing, isEmpty);
      expect(mischief.previewTakeover(w.SeasonalEvent.christmas), isTrue);
      await run(tester, 2);
      expect(mischief.takeover.active, w.SeasonalEvent.christmas);
      expect(stage.showing, isNotEmpty);
      await run(tester, 19);
      expect(mischief.takeover.active, isNull);
      expect(stage.showing, isEmpty);
      expect(mischief.takeover.watching, isFalse);
    });

    scene('a preview of something with no takeover does nothing', (tester) async {
      make(DateTime(2027, 3, 3, 15));
      expect(mischief.previewTakeover(w.SeasonalEvent.valentines), isFalse);
      expect(mischief.takeover.watching, isFalse);
    });
  });
}
