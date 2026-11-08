// Window nudges on the stage (docs/SPRINT_2.md X2): the wobble when Mochi lands on a window, the shove on a pause, the
// tug when Claude needs you; Mochi's feet riding the window; the Title-bar walker not taking Mochi's own nudges for a drag;
// every way the adventure or the app ends sending the window home; the journal replayed at start; the development switch.
// The put-back contract itself is in window_nudge_test.dart.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/json_store.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/core/window_nudge.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect;
import 'package:mochi_desktop/src/platform/window_frames.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart' show PetHome;
import 'package:mochi_desktop/src/ui/stage/adventure.dart';
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';

import 'support/fake_mover.dart';
import 'support/fake_stage.dart';
import 'support/fakes.dart';

class _Home extends ChangeNotifier implements PetHome {
  final (int, int) at = (300, 1068);

  @override
  bool out = false;

  @override
  bool get canGoOut => !out;

  @override
  ({int x, int y, double scale, double facing, double unit})? departure() => (x: at.$1, y: at.$2, scale: 1, facing: 1.0, unit: 0.56);

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

/// Dice that always say [value] to nextInt (0: lucky now; 1: never).
class _Dice implements math.Random {
  int value = 1;

  @override
  double nextDouble() => 0.99;

  @override
  int nextInt(int max) => value;

  @override
  bool nextBool() => false;
}

void main() {
  const editorRect = PixelRect(400, 300, 1100, 800);
  const browserRect = PixelRect(1200, 440, 1800, 900);
  const terminalRect = PixelRect(300, 500, 900, 900);

  late TestDesktop t;
  late FakeNativeStage stage;
  late _Home home;
  late FakeWindowFrames frames;
  late FakeMover mover;
  late MemoryJsonStore store;
  late MischiefStage mischief;
  late List<String> log;
  late _Dice dice;
  var now = DateTime(2026, 11, 8, 15);

  setUp(() {
    now = DateTime(2026, 11, 8, 15);
    t = TestDesktop.make(clock: () => now, activity: const SystemActivity(idleSeconds: 1));
    t.desktop.rhythm.sample();
    stage = FakeNativeStage();
    home = _Home();
    log = [];
    dice = _Dice();
    store = MemoryJsonStore();
    frames = FakeWindowFrames([WindowFrame(hwnd: 11, frame: editorRect)]);
    mover = FakeMover({11: FakeWin(editorRect, process: 'notepad.exe')});
    // The fake keeps the frames the adventure reads in step with the windows Windows moved.
    mover.moved = (hwnd, dx, dy) {
      frames.windows = [
        for (final w in frames.windows) w.hwnd == hwnd ? WindowFrame(hwnd: hwnd, frame: w.frame.shifted(dx, dy), zoomed: w.zoomed) : w,
      ];
    };
    mischief = MischiefStage(desktop: t.desktop, stage: stage, displays: FakeDisplays(), cursor: () => null);
  });

  tearDown(() async {
    mischief.dispose();
    await t.dispose();
  });

  DesktopAdventure adventure() => mischief.adventure!;

  void begin({bool walker = true, bool nudges = true, NudgeForce? force, bool master = true}) {
    mischief = MischiefStage(
      desktop: t.desktop,
      stage: stage,
      displays: FakeDisplays([FakeDisplays.main1080, FakeDisplays.side1440]),
      cursor: () => null,
      home: home,
      frames: frames,
      mover: mover,
      nudgeStore: store,
      nudgeLog: log.add,
      nudgeForce: force,
      random: dice,
    );
    t.desktop.mischief.start();
    mischief.start();
    t.desktop.settings.mischief = MischiefSettings(
      enabled: master,
      extras: {MischiefExtra.cursorBuddy: false, MischiefExtra.roamScreens: false, MischiefExtra.titleBars: walker, MischiefExtra.windowNudges: nudges},
    );
  }

  Future<void> run(WidgetTester tester, double seconds) async {
    for (var i = 0; i < (seconds * 1000 / 33).ceil(); i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  Future<void> done(WidgetTester tester) async {
    mischief.adventure?.stop();
    mischief.roamer?.stop();
    mischief.dispose();
    t.desktop.mischief.stop();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Drops Mochi over the editor and runs [seconds], reporting every frame to [seen].
  Future<void> drop(WidgetTester tester, double seconds, {void Function()? seen}) async {
    expect(adventure().dropped(700, 250), isTrue);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    for (var i = 0; i < (seconds * 1000 / 33).ceil(); i++) {
      await tester.pump(const Duration(milliseconds: 33));
      seen?.call();
    }
  }

  int dyNow() => mover.windows[11]!.rect.top - editorRect.top;
  int dxNow() => mover.windows[11]!.rect.left - editorRect.left;
  int lines(String kind) => log.where((l) => l.startsWith('nudge: $kind,')).length;

  group('the wobble', () {
    for (final walker in [true, false]) {
      testWidgets('landing on a window dips it 3 px and springs it back; Mochi rides it (Title-bar walker ${walker ? 'on' : 'off'})', (tester) async {
        begin(walker: walker);
        var maxDy = 0;
        var fed = 0;
        var rode = false;
        var replanned = false;
        Object? lastPlan;
        await drop(
          tester,
          1.6,
          seen: () {
            maxDy = math.max(maxDy, dyNow());
            final feet = adventure().feet;
            if (adventure().riding) rode = true;
            final plan = adventure().plan;
            if (mischief.nudger.running && lastPlan != null && !identical(plan, lastPlan)) replanned = true;
            lastPlan = plan;
            if (dyNow() > 0 && feet != null && feet.$2 == editorRect.top + dyNow()) fed++;
          },
        );
        expect(maxDy, 3, reason: 'down 3 px');
        expect(lines('wobble'), 1, reason: 'once');
        expect(log, contains('nudge: wobble, home ok'));
        expect(fed, greaterThan(0), reason: 'Mochi’s feet were on the top edge while it dipped');
        expect(rode, isFalse, reason: 'its own nudge is not a drag: no holding-on pose');
        expect(replanned, isFalse, reason: 'and no fall or re-survey because of it');
        expect(mover.windows[11]!.rect, editorRect);
        expect(mover.moves.last, (11, 400, 300));
        expect(t.desktop.mischief.may(MischiefExtra.windowNudges), isTrue);
        expect(adventure().feet!.$2, 300, reason: 'back on the real top edge');
        await done(tester);
      });
    }

    testWidgets('a display at 150% dips 4.5 px (rounded)', (tester) async {
      // The editor sits on the main (100%) display; scale 1.5 is the second display's: covered by the motion's own test.
      expect(NudgeMotion.wobble(scale: 1.5).at(0.09).$2, 5);
    });

    testWidgets('at most once per window per outing', (tester) async {
      begin();
      mover.windows[12] = FakeWin(browserRect);
      frames.windows = [WindowFrame(hwnd: 11, frame: editorRect), WindowFrame(hwnd: 12, frame: browserRect)];
      await drop(tester, 40);
      expect(lines('wobble'), lessThanOrEqualTo(2), reason: 'two windows, each wobbles once');
      expect(lines('wobble'), greaterThanOrEqualTo(1));
      final dips = <int>{for (final m in mover.moves) m.$1};
      expect(dips.length, lessThanOrEqualTo(2));
      await done(tester);
    });

    testWidgets('never the window you are using', (tester) async {
      begin();
      mover.foregroundHwnd = 11;
      await drop(tester, 2);
      expect(mover.attempts, isEmpty);
      expect(lines('wobble'), 0);
      await done(tester);
    });

    testWidgets('nothing with the extra off', (tester) async {
      begin(nudges: false);
      await drop(tester, 2);
      expect(mover.attempts, isEmpty);
      await done(tester);
    });

    testWidgets('nothing with the extra on but Mischief off', (tester) async {
      begin(master: false);
      await drop(tester, 2);
      expect(mover.attempts, isEmpty);
      await done(tester);
    });

    testWidgets('a window that does not qualify is never moved (a dialog, a snapped window)', (tester) async {
      begin();
      mover.windows[11]!.owned = true;
      await drop(tester, 2);
      expect(mover.attempts, isEmpty);
      await done(tester);
    });
  });

  group('the shove', () {
    testWidgets('on a long enough pause, the window slides 8 px the way Mochi faces and back; Mochi rides along; once per outing', (tester) async {
      dice.value = 0;
      begin();
      var maxDx = 0;
      var rode = false;
      var fed = 0;
      await drop(
        tester,
        45,
        seen: () {
          maxDx = math.max(maxDx, dxNow().abs());
          if (adventure().riding) rode = true;
          final feet = adventure().feet;
          if (dxNow() != 0 && dyNow() == 0 && feet != null && feet.$2 == editorRect.top) fed++;
        },
      );
      expect(lines('shove'), 1, reason: 'at most once per outing');
      expect(maxDx, 8);
      expect(rode, isFalse);
      expect(fed, greaterThan(0));
      expect(mover.windows[11]!.rect, editorRect);
      expect(log, contains('nudge: shove, home ok'));
      await done(tester);
    });

    testWidgets('about one pause in four: with unlucky dice it never shoves', (tester) async {
      dice.value = 1;
      begin();
      await drop(tester, 45);
      expect(lines('shove'), 0);
      await done(tester);
    });

    testWidgets('a user drag during a shove stops it with nothing put back, and Mochi rides the drag', (tester) async {
      dice.value = 0;
      begin();
      expect(adventure().dropped(700, 250), isTrue);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      var shoving = false;
      for (var i = 0; i < 1500 && !shoving; i++) {
        await tester.pump(const Duration(milliseconds: 33));
        shoving = mischief.nudger.running && mischief.nudger.kind == NudgeKind.shove;
      }
      expect(shoving, isTrue, reason: 'a pause came');
      await run(tester, 0.4);
      final moves = mover.moves.length;
      mover.windows[11]!.rect = mover.windows[11]!.rect.shifted(0, 60);
      frames.windows = [WindowFrame(hwnd: 11, frame: frames.windows.first.frame.shifted(0, 60))];
      await run(tester, 0.3);
      expect(mover.moves.length, moves, reason: 'nothing put back');
      expect(mover.windows[11]!.rect.top, editorRect.top + 60, reason: 'the user’s move wins');
      expect(adventure().riding, isTrue, reason: 'a real drag is ridden');
      expect(log, contains('nudge: shove, left (moved by you)'));
      await done(tester);
    });
  });

  group('the Title-bar walker is told about the nudge', () {
    test('a frame moved by the nudge is expected, not a drag', () {
      final nudger = WindowNudger(mover: mover, store: MemoryJsonStore(), allowed: () => true, clock: () => 0);
      expect(nudger.expects(11, editorRect, editorRect.shifted(0, 3)), isFalse, reason: 'nothing runs');
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      expect(nudger.expects(11, editorRect, editorRect), isTrue, reason: 'home');
      expect(nudger.expects(11, editorRect, editorRect.shifted(0, 40)), isFalse);
      expect(nudger.expects(12, editorRect, editorRect), isFalse, reason: 'any other window');
      nudger.dispose();
    });
  });

  group('every way out sends the window home', () {
    Future<void> shoving(WidgetTester tester) async {
      dice.value = 0;
      begin();
      expect(adventure().dropped(700, 250), isTrue);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      var going = false;
      for (var i = 0; i < 1500 && !going; i++) {
        await tester.pump(const Duration(milliseconds: 33));
        going = mischief.nudger.running && mover.windows[11]!.rect != editorRect;
      }
      expect(going, isTrue);
    }

    void expectHome(int moves) {
      expect(mover.windows[11]!.rect, editorRect);
      expect(mover.moves.length, moves + 1, reason: 'one move');
      expect(mover.moves.last, (11, 400, 300));
      expect(mischief.nudger.running, isFalse);
    }

    testWidgets('the adventure is sent home', (tester) async {
      await shoving(tester);
      final moves = mover.moves.length;
      adventure().comeHome();
      await tester.pump(const Duration(milliseconds: 200));
      expectHome(moves);
      await done(tester);
    });

    testWidgets('the extra is turned off', (tester) async {
      await shoving(tester);
      final moves = mover.moves.length;
      t.desktop.settings.mischief = t.desktop.settings.mischief.withExtra(MischiefExtra.windowNudges, false);
      await tester.pump(const Duration(milliseconds: 200));
      expectHome(moves);
      await done(tester);
    });

    testWidgets('Mischief is turned off', (tester) async {
      await shoving(tester);
      final moves = mover.moves.length;
      t.desktop.settings.mischief = t.desktop.settings.mischief.copyWith(enabled: false);
      await tester.pump(const Duration(milliseconds: 200));
      expectHome(moves);
      await done(tester);
    });

    testWidgets('the gate closes (quiet hours)', (tester) async {
      await shoving(tester);
      final moves = mover.moves.length;
      t.desktop.settings.quietMode = true;
      await tester.pump(const Duration(milliseconds: 200));
      expectHome(moves);
      await done(tester);
    });

    testWidgets('a mouse button goes down', (tester) async {
      await shoving(tester);
      final moves = mover.moves.length;
      mover.mouse = true;
      await tester.pump(const Duration(milliseconds: 200));
      expectHome(moves);
      mover.mouse = false;
      await done(tester);
    });

    testWidgets('the window becomes the foreground', (tester) async {
      await shoving(tester);
      final moves = mover.moves.length;
      mover.foregroundHwnd = 11;
      await tester.pump(const Duration(milliseconds: 200));
      expectHome(moves);
      await done(tester);
    });

    testWidgets('the app quits: desktop.dispose reaches the put-back', (tester) async {
      await shoving(tester);
      final moves = mover.moves.length;
      await tester.runAsync(() => t.desktop.dispose());
      expectHome(moves);
      await done(tester);
    });

    testWidgets('the stage is disposed', (tester) async {
      await shoving(tester);
      final moves = mover.moves.length;
      mischief.dispose();
      expectHome(moves);
      await done(tester);
    });

    testWidgets('Windows ends the session', (tester) async {
      await t.dispose();
      final controller = StreamController<void>.broadcast();
      t = TestDesktop.make(clock: () => now, activity: const SystemActivity(idleSeconds: 1), sessionEnding: controller.stream);
      t.desktop.rhythm.sample();
      await shoving(tester);
      final moves = mover.moves.length;
      controller.add(null);
      await tester.pump(const Duration(milliseconds: 10));
      expectHome(moves);
      await controller.close();
      await done(tester);
      await t.dispose();
      await done(tester);
    });
  });

  group('the terminal tug', () {
    late FakeWin terminal;

    void setUpWindows() {
      terminal = FakeWin(terminalRect, process: 'WindowsTerminal.exe');
      mover.windows[21] = terminal;
      mover.windows[22] = FakeWin(const PixelRect(100, 100, 600, 500), process: 'Code.exe');
      mover.windows[23] = FakeWin(const PixelRect(1000, 100, 1500, 500), process: 'chrome.exe');
      // Front to back: a browser, the terminal, the editor.
      frames.windows = [
        const WindowFrame(hwnd: 23, frame: PixelRect(1000, 100, 1500, 500)),
        const WindowFrame(hwnd: 21, frame: terminalRect),
        const WindowFrame(hwnd: 22, frame: PixelRect(100, 100, 600, 500)),
      ];
      mover.moved = null;
    }

    Future<void> needsYou(WidgetTester tester) async {
      t.desktop.cue(PetCue.needsYou);
      await tester.pump();
    }

    testWidgets('the front-most editor or terminal shakes ±6 px three times in about 450 ms and ends exactly home', (tester) async {
      begin();
      setUpWindows();
      await needsYou(tester);
      expect(mischief.nudger.running, isTrue);
      expect(mischief.nudger.hwnd, 21, reason: 'not the browser in front of it, not the editor behind');
      var most = 0, least = 0;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 33));
        final dx = terminal.rect.left - terminalRect.left;
        most = math.max(most, dx);
        least = math.min(least, dx);
      }
      expect((most, least), (6, -6));
      expect(terminal.rect, terminalRect);
      expect(mover.moves.last, (21, 300, 500));
      expect(log, ['nudge: tug, home ok']);
      expect(mover.attempts.every((a) => a.$1 == 21), isTrue, reason: 'only that window');
      await done(tester);
    });

    testWidgets('only if it is not the foreground window', (tester) async {
      begin();
      setUpWindows();
      mover.foregroundHwnd = 21;
      await needsYou(tester);
      expect(mischief.nudger.running, isTrue);
      expect(mischief.nudger.hwnd, 22, reason: 'the next editor behind: the one you use is left alone');
      await run(tester, 1);
      expect(mover.attempts.where((a) => a.$1 == 21), isEmpty);
      await done(tester);
    });

    testWidgets('once per needs-you and at most once every two minutes', (tester) async {
      begin();
      setUpWindows();
      await needsYou(tester);
      await run(tester, 1);
      expect(lines('tug'), 1);
      await needsYou(tester);
      await run(tester, 1);
      expect(lines('tug'), 1, reason: 'within two minutes');
      await tester.pump(const Duration(seconds: 100));
      await needsYou(tester);
      await run(tester, 1);
      expect(lines('tug'), 1, reason: 'still within two minutes');
      await tester.pump(const Duration(seconds: 30));
      await needsYou(tester);
      await run(tester, 1);
      expect(lines('tug'), 2, reason: 'two minutes later');
      await done(tester);
    });

    testWidgets('only when you are at the PC', (tester) async {
      begin();
      setUpWindows();
      t.usage.activity = const SystemActivity(idleSeconds: 600);
      t.desktop.rhythm.sample();
      expect(t.desktop.rhythm.away, isTrue);
      await needsYou(tester);
      expect(mischief.nudger.running, isFalse);
      expect(mover.attempts, isEmpty);
      await done(tester);
    });

    testWidgets('only while the extra may run, and only for editors and terminals', (tester) async {
      begin(nudges: false);
      setUpWindows();
      await needsYou(tester);
      expect(mover.attempts, isEmpty, reason: 'the extra is off');
      await done(tester);
      mischief.dispose();
      begin();
      setUpWindows();
      mover.windows[21]!.process = 'notepad.exe';
      mover.windows[22]!.process = null;
      await needsYou(tester);
      expect(mischief.nudger.running, isFalse, reason: 'nothing that matches X7’s list');
      await done(tester);
    });

    testWidgets('a window that does not qualify is skipped for the next one', (tester) async {
      begin();
      setUpWindows();
      terminal.zoomed = true;
      await needsYou(tester);
      expect(mischief.nudger.hwnd, 22);
      await done(tester);
    });

    testWidgets('does not tug the window it is already shaking twice, and never while another nudge runs', (tester) async {
      begin();
      setUpWindows();
      expect(mischief.nudger.start(22, NudgeKind.shove), isTrue);
      await needsYou(tester);
      expect(mischief.nudger.hwnd, 22, reason: 'one window at a time');
      expect(mover.attempts.where((a) => a.$1 == 21), isEmpty);
      await done(tester);
    });
  });

  group('startup and the development switch', () {
    testWidgets('a journal left by a crash puts the window back when the stage starts', (tester) async {
      store.json = {'hwnd': 11, 'pid': 100, 'home': [400, 300], 'placed': [408, 300]};
      mover.windows[11]!.rect = editorRect.shifted(8, 0);
      begin();
      expect(mover.windows[11]!.rect, editorRect);
      expect(store.json, isNull);
      await done(tester);
    });

    testWidgets('MOCHI_DESKTOP_NUDGE=wobble: every landing wobbles, even the same window again', (tester) async {
      expect(MischiefStage.nudgeFrom('wobble'), NudgeForce.wobble);
      expect(MischiefStage.nudgeFrom('shove'), NudgeForce.shove);
      expect(MischiefStage.nudgeFrom('tug'), NudgeForce.tug);
      expect(MischiefStage.nudgeFrom('x'), isNull);
      begin(force: NudgeForce.wobble);
      await drop(tester, 30);
      expect(lines('wobble'), greaterThanOrEqualTo(1));
      expect(lines('shove'), 0, reason: 'only that motion');
      await done(tester);
    });

    testWidgets('MOCHI_DESKTOP_NUDGE=shove: every eligible pause shoves, and no wobbles', (tester) async {
      begin(force: NudgeForce.shove);
      await drop(tester, 45);
      expect(lines('shove'), greaterThanOrEqualTo(1));
      expect(lines('wobble'), 0);
      await done(tester);
    });

    testWidgets('MOCHI_DESKTOP_NUDGE=tug: the tug 10 s after start and every 60 s while the screen is seen; the gate still applies', (tester) async {
      begin(force: NudgeForce.tug);
      mover.windows[21] = FakeWin(terminalRect, process: 'WindowsTerminal.exe');
      frames.windows = [const WindowFrame(hwnd: 21, frame: terminalRect)];
      await tester.pump(const Duration(seconds: 9));
      expect(lines('tug'), 0);
      await tester.pump(const Duration(seconds: 2));
      await run(tester, 1);
      expect(lines('tug'), 1);
      await tester.pump(const Duration(seconds: 61));
      await run(tester, 1);
      expect(lines('tug'), 2);
      t.desktop.settings.mischief = t.desktop.settings.mischief.withExtra(MischiefExtra.windowNudges, false);
      await tester.pump(const Duration(seconds: 61));
      await run(tester, 1);
      expect(lines('tug'), 2, reason: 'the extra is off');
      await done(tester);
    });
  });
}
