// Explore the desktop (docs/SPRINT_2.md W19): Mochi leaves the taskbar and walks along window tops, sits on the taskbar,
// climbs the screen's edge and hops home. A fake stage, fake windows, displays and clock: the planner's y-up logical pixels
// against Windows' physical ones, each way it sets off, only eligible time counted, a full-screen app or an unseen screen
// (no frames, no surveys), the carry by the scruff and the drop, the settings, one owner at a time and Ask Mochi's commands.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/ask_mochi.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show QuietHours;
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/quick_commands.dart';
import 'package:mochi_desktop/src/platform/displays.dart';
import 'package:mochi_desktop/src/platform/native_stage.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect;
import 'package:mochi_desktop/src/platform/window_frames.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart' show PetHome;
import 'package:mochi_desktop/src/ui/stage/adventure.dart';
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fake_stage.dart';
import 'support/fakes.dart';

/// The taskbar, as the adventure sees it: Mochi stands at [at], goes out and comes back.
class _Home extends ChangeNotifier implements PetHome {
  (int, int) at = (300, 1068);
  bool showing = true;
  final List<int?> returns = [];

  @override
  bool out = false;

  @override
  bool get canGoOut => showing && !out;

  @override
  ({int x, int y, double scale, double facing, double unit})? departure() => showing ? (x: at.$1, y: at.$2, scale: 1, facing: 1.0, unit: 0.56) : null;

  @override
  void goOut() {
    out = true;
    notifyListeners();
  }

  @override
  void comeBack({int? x}) {
    out = false;
    returns.add(x);
    notifyListeners();
  }
}

/// A "random" that always says [value] (0: it's lucky now; 0.99: never).
class _Dice implements math.Random {
  double value = 0.99;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

void main() {
  const main = FakeDisplays.main1080, side = FakeDisplays.side1440;

  // Windows, physical pixels on the main display (1920×1080, taskbar 48 tall): their tops are 780 and 640 up from the bottom.
  const editor = WindowFrame(hwnd: 11, frame: PixelRect(400, 300, 1100, 800));
  const browser = WindowFrame(hwnd: 12, frame: PixelRect(1200, 440, 1800, 900));

  late TestDesktop t;
  late FakeNativeStage stage;
  late _Home home;
  late FakeDisplays displays;
  late FakeWindowFrames frames;
  late MischiefStage mischief;
  (int, int)? pointer;
  var shown = true;
  var fullScreen = false;
  var now = DateTime(2026, 11, 8, 15);
  final menus = <(int, int)>[];

  setUp(() {
    shown = true;
    fullScreen = false;
    pointer = null;
    menus.clear();
    now = DateTime(2026, 11, 8, 15);
    t = TestDesktop.make(clock: () => now, fullScreen: () => fullScreen, activity: const SystemActivity(idleSeconds: 1));
    t.desktop.rhythm.sample();
    stage = FakeNativeStage();
    home = _Home();
    displays = FakeDisplays([main, side]);
    frames = FakeWindowFrames([editor, browser]);
    // Until a test sets Mischief up (the pure ones never do).
    mischief = MischiefStage(desktop: t.desktop, stage: stage, displays: displays, cursor: () => null);
  });

  tearDown(() async {
    mischief.dispose();
    await t.dispose();
  });

  DesktopAdventure adventure() => mischief.adventure!;

  void begin({bool mischiefOn = false}) {
    mischief = MischiefStage(
      desktop: t.desktop,
      stage: stage,
      displays: displays,
      cursor: () => pointer,
      home: home,
      shown: () => shown,
      frames: frames,
      onMenu: (x, y) => menus.add((x, y)),
    );
    t.desktop.mischief.start();
    mischief.start();
    if (mischiefOn) t.desktop.settings.mischief = const MischiefSettings(enabled: true);
  }

  Future<void> run(WidgetTester tester, double seconds, {Duration step = const Duration(milliseconds: 33)}) async {
    final steps = (seconds * 1000 / step.inMilliseconds).ceil();
    for (var i = 0; i < steps; i++) {
      await tester.pump(step);
    }
  }

  /// Lets the pictures Mochi waits for get drawn.
  Future<void> drawn(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 33));
  }

  Future<void> done(WidgetTester tester) async {
    mischief.adventure?.stop();
    mischief.buddy?.stop();
    mischief.roamer?.stop();
    t.desktop.mischief.stop();
    await tester.pump();
  }

  /// Runs until Mochi stands still on something for a while yet (a sit, a sniff), so a click can pet it.
  Future<void> untilStanding(WidgetTester tester) async {
    for (var i = 0; i < 3000; i++) {
      final plan = adventure().plan;
      if (plan != null) {
        final at = t.desktop.world.now();
        final sample = plan.sample(at);
        final segment = plan.segment(at);
        if (sample.move == w.AdventureMove.hold &&
            sample.style == w.AdventureStyle.plain &&
            sample.animation == w.PetAnimation.sit &&
            segment != null &&
            segment.end - at > 1) {
          return;
        }
      }
      await tester.pump(const Duration(milliseconds: 33));
    }
    fail('Mochi never sat down');
  }

  group('the planner’s space', () {
    test('the y flip and the display’s scale, both ways, in one place', () {
      const space = AdventureSpace(main);
      final p = space.point(300, 1068);
      expect(p.x, 300);
      expect(p.y, 12, reason: 'up from the display’s bottom edge');
      expect(space.feet(p), (300, 1068));
      // A window's rectangle: its top edge is the largest y.
      final rect = space.rect(editor.frame);
      expect((rect.minX, rect.minY, rect.maxX, rect.maxY), (400, 280, 1100, 780));
      // The second display is at 150%: logical pixels, y up from its own bottom, x from its own left.
      const second = AdventureSpace(side);
      final q = second.point(2400, 600);
      expect((q.x, q.y), (320, 560));
      expect(second.feet(q), (2400, 600));
      expect(second.screen.maxY, 1440 / 1.5);
    });

    test('the floor is the top of a bottom taskbar (its middle is the dock), else the work area’s bottom; ledges are window tops', () {
      const space = AdventureSpace(main);
      expect(space.taskbarAtBottom, isTrue);
      final terrain = space.terrain([editor.frame, browser.frame], w.AdventureMetrics());
      expect(terrain.floorY, 48);
      expect(terrain.bounds.maxY, 1080);
      expect(terrain.dock!.lower, closeTo(1920 * 0.22, 0.001));
      expect(terrain.ledges.any((l) => l.y == 780 && l.minX == 400 && l.maxX == 1100), isTrue, reason: 'the editor’s top');
      expect(terrain.ledges.any((l) => l.y == 640 && l.minX >= 1200 && l.maxX <= 1800), isTrue, reason: 'the browser’s top');
      // A display without a taskbar on its bottom: its bottom edge, and no dock.
      const second = AdventureSpace(side);
      expect(second.taskbarAtBottom, isFalse);
      final other = second.terrain(const [PixelRect(2400, 600, 3600, 1200)], w.AdventureMetrics());
      expect(other.floorY, 0);
      expect(other.dock, isNull);
      expect(other.ledges.single.y, 560);
      // A taskbar along the side: the floor is still the work area's bottom.
      const left = DisplayArea(key: 'L', monitor: PixelRect(0, 0, 1920, 1080), workArea: PixelRect(60, 0, 1920, 1080), scale: 1);
      expect(const AdventureSpace(left).taskbarAtBottom, isFalse);
      expect(const AdventureSpace(left).terrain(const [], w.AdventureMetrics()).floorY, 0);
    });
  });

  group('setting off', () {
    testWidgets('Explore: Mochi leaves the taskbar from where it stood, and the world knows', (tester) async {
      begin();
      expect(adventure().active, isFalse);
      expect(adventure().explore(), AdventureStart.started);
      expect(adventure().active, isTrue);
      expect(home.out, isTrue);
      expect(t.desktop.world.world.adventureActive, isTrue);
      expect(adventure().space!.display.key, main.key, reason: 'the display it left from');
      expect(adventure().surveying, isTrue);
      expect(adventure().plan!.segments.first.from.x, closeTo(300, 1));
      // It hops out and walks the windows' tops; the plan stays on this display.
      await run(tester, 3);
      expect(adventure().perfState(), startsWith('adventure ('));
      await done(tester);
      expect(adventure().active, isFalse);
      expect(t.desktop.world.world.adventureActive, isFalse);
    });

    testWidgets('a drop off the taskbar: it falls from where you let go onto what is below', (tester) async {
      begin();
      expect(adventure().dropped(700, 250), isTrue);
      expect(adventure().plan!.segments.first.move, w.AdventureMove.fall);
      await drawn(tester);
      await run(tester, 0.35);
      // The editor's top is at y 300 (physical), straight below the drop.
      final feet = adventure().feet!;
      expect(feet.$2, 300);
      expect((feet.$1 - 700).abs(), lessThan(8));
      expect(stage.showing[mischief.pet!.actor], isNotNull);
      expect(stage.showing[mischief.pet!.actor]!.topmost, isTrue);
      await done(tester);
    });

    testWidgets('a drop on another display goes by that display, at its scale and with no taskbar', (tester) async {
      begin();
      expect(adventure().dropped(2400, 1300), isTrue);
      expect(adventure().space!.display.key, side.key);
      expect(adventure().plan!.segments.first.to.y, 0, reason: 'the bottom edge: nothing below');
      await drawn(tester);
      await run(tester, 1);
      expect(adventure().feet!.$2, 1440);
      await done(tester);
      expect(home.returns.last, isNull, reason: 'the taskbar is on another display: it resumes where it left');
    });

    testWidgets('with Adventures off, a drop is left to the taskbar and Explore says no', (tester) async {
      begin();
      t.desktop.settings.adventure = const w.AdventureSettings(enabled: false);
      expect(adventure().dropped(700, 250), isFalse);
      expect(adventure().explore(), AdventureStart.off);
      expect(adventure().active, isFalse);
      expect(home.out, isFalse);
      expect(DesktopAdventure.say(AdventureStart.off, 'Mochi', null), contains('Settings › Fun'));
      await done(tester);
    });

    testWidgets('Explore while it is out brings it home (one big leap), and the taskbar has it back', (tester) async {
      begin();
      adventure().explore();
      await run(tester, 2);
      expect(adventure().explore(), AdventureStart.headingHome);
      expect(adventure().perfState(), 'adventure (heading home)');
      await run(tester, 3);
      expect(adventure().active, isFalse);
      expect(home.out, isFalse);
      expect(home.returns, hasLength(1));
      expect(stage.showing, isEmpty);
      await done(tester);
    });

    testWidgets('no taskbar to leave from, no Mochi on it, or a rule that says no: it stays home', (tester) async {
      begin();
      shown = false;
      expect(adventure().explore(), AdventureStart.nowhere);
      shown = true;
      home.showing = false;
      expect(adventure().explore(), AdventureStart.nowhere);
      home.showing = true;
      t.desktop.settings.pauseReactions = true;
      expect(adventure().explore(), AdventureStart.resting);
      expect(adventure().why, MischiefPause.paused);
      expect(DesktopAdventure.say(AdventureStart.resting, 'Mochi', adventure().why), MischiefPause.paused.note('Mochi'));
      t.desktop.settings.pauseReactions = false;
      fullScreen = true;
      expect(adventure().explore(), AdventureStart.resting);
      expect(adventure().why, MischiefPause.fullScreen);
      fullScreen = false;
      expect(adventure().explore(), AdventureStart.started);
      await done(tester);
    });

    testWidgets('the tray and Ask Mochi: explore and come home work now', (tester) async {
      begin();
      t.desktop.ask
        ..explore = () {
          final start = adventure().explore();
          return AskOutcome(DesktopAdventure.say(start, 'Mochi', adventure().why), ok: start == AdventureStart.started);
        }
        ..comeHome = () => adventure().comeHome() ? const AskOutcome('Coming home!') : const AskOutcome('Mochi is already home.');
      expect(QuickCommands.parse('go explore'), SimpleCommand.explore);
      expect(QuickCommands.parse('come home'), SimpleCommand.comeHome);
      final off = await t.desktop.ask.perform(SimpleCommand.comeHome);
      expect(off.text, 'Mochi is already home.');
      final out = await t.desktop.ask.perform(SimpleCommand.explore);
      expect(out.ok, isTrue);
      expect(out.text, 'Off to explore your desktop!');
      expect(adventure().active, isTrue);
      final back = await t.desktop.ask.perform(SimpleCommand.comeHome);
      expect(back.text, 'Coming home!');
      await run(tester, 3);
      expect(adventure().active, isFalse);
      // Without the app wiring (tests of everything else) the old answer stands.
      t.desktop.ask
        ..explore = null
        ..comeHome = null;
      expect((await t.desktop.ask.perform(SimpleCommand.explore)).text, "That trick isn't on Windows yet.");
      await done(tester);
    });
  });

  group('by itself', () {
    testWidgets('only eligible time counts: a Claude session working, or Mochi in its window, holds the count', (tester) async {
      begin();
      expect(adventure().counting, isTrue);
      // Claude is working for the first 20 minutes: nothing is counted.
      t.desktop.sessions.apply(hook('UserPromptSubmit', at: now));
      await tester.pump(const Duration(minutes: 20));
      expect(adventure().active, isFalse);
      expect(adventure().scheduler.accumulated, 0);
      t.desktop.sessions.apply(hook('Stop', at: now));
      // In its window or the popover (not showing on the taskbar): nothing either.
      shown = false;
      await tester.pump(const Duration(minutes: 20));
      expect(adventure().scheduler.accumulated, 0);
      shown = true;
      // On the taskbar and quiet: a whole stretch later it sets off by itself.
      await tester.pump(const Duration(seconds: 6));
      expect(adventure().scheduler.accumulated, greaterThan(0));
      await tester.pump(Duration(seconds: adventure().scheduler.threshold.ceil() + 10));
      expect(adventure().active, isTrue, reason: 'it set off by itself');
      expect(home.out, isTrue);
      await done(tester);
    });

    testWidgets('quiet hours, a focus session and paused reactions hold it too; “never”, “off” and an unseen screen stop the count', (tester) async {
      begin();
      t.desktop.settings.quietHours = const QuietHours(enabled: true, startMinute: 0, endMinute: 23 * 60);
      await tester.pump(const Duration(minutes: 10));
      expect(adventure().scheduler.accumulated, 0, reason: 'quiet hours');
      t.desktop.settings.quietHours = const QuietHours(enabled: false);
      t.desktop.settings.pauseReactions = true;
      await tester.pump(const Duration(minutes: 10));
      expect(adventure().scheduler.accumulated, 0, reason: 'paused');
      t.desktop.settings.pauseReactions = false;
      t.desktop.settings.adventure = const w.AdventureSettings(spontaneous: w.AdventureFrequency.never);
      expect(adventure().counting, isFalse, reason: 'never: no timer at all');
      t.desktop.settings.adventure = const w.AdventureSettings(enabled: false);
      expect(adventure().counting, isFalse);
      t.desktop.settings.adventure = const w.AdventureSettings();
      expect(adventure().counting, isTrue);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
      expect(adventure().counting, isFalse, reason: 'nobody can see the screen');
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 0));
      expect(adventure().counting, isTrue);
      await done(tester);
    });

    testWidgets('the development switch sets it off every so often while the screen can be seen', (tester) async {
      expect(MischiefStage.adventureDemoFrom('30'), const Duration(seconds: 30));
      expect(MischiefStage.adventureDemoFrom('2'), isNull);
      expect(MischiefStage.adventureDemoFrom(null), isNull);
      mischief = MischiefStage(
        desktop: t.desktop,
        stage: stage,
        displays: displays,
        cursor: () => pointer,
        home: home,
        shown: () => shown,
        frames: frames,
        adventureDemo: const Duration(seconds: 30),
      );
      t.desktop.mischief.start();
      mischief.start();
      await tester.pump(const Duration(seconds: 31));
      expect(adventure().active, isTrue);
      await done(tester);
    });
  });

  group('while it is out', () {
    testWidgets('a full-screen app sends it home at once, and the screen going unseen too: no frames and no surveys then', (tester) async {
      begin();
      adventure().explore();
      await drawn(tester);
      await run(tester, 1);
      expect(adventure().every, DesktopAdventure.moveEvery);
      expect(stage.showing, isNotEmpty);
      fullScreen = true;
      await tester.pump(DesktopAdventure.checkEvery + const Duration(milliseconds: 100));
      expect(adventure().active, isFalse);
      expect(home.out, isFalse);
      expect(home.returns.last, 300, reason: 'to where it left from');
      expect(stage.showing, isEmpty);
      expect(adventure().every, isNull);
      expect(adventure().surveying, isFalse);
      fullScreen = false;
      // Out again, then the display goes off: home, and not a frame or a read after that.
      adventure().explore();
      await run(tester, 1);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
      expect(adventure().active, isFalse);
      expect(adventure().every, isNull);
      expect(adventure().surveying, isFalse);
      final lists = frames.lists, surveys = adventure().surveys, calls = stage.calls.length;
      await run(tester, 5);
      expect(frames.lists, lists);
      expect(adventure().surveys, surveys);
      expect(stage.calls.length, calls);
      expect(adventure().explore(), AdventureStart.resting, reason: 'an unseen screen: the rule says no');
      await done(tester);
    });

    testWidgets('windows are read three times a second while out, and re-route it when its window closes', (tester) async {
      begin();
      frames.windows = [editor];
      adventure().explore();
      final before = frames.lists;
      await run(tester, 2);
      final reads = frames.lists - before;
      expect(reads, inInclusiveRange(5, 7), reason: 'three a second');
      expect(adventure().terrain!.ledges.single.y, 780);
      // The editor closes under Mochi's feet at a moment it stands on it: it falls.
      for (var i = 0; i < 600 && adventure().terrain!.ledge(adventure().plan!.sample(t.desktop.world.now()).point) == null; i++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      frames.windows = [];
      await run(tester, 0.5);
      expect(adventure().terrain!.ledges, isEmpty);
      expect(adventure().plan!.sample(t.desktop.world.now()).point.y, lessThanOrEqualTo(780));
      await done(tester);
    });

    testWidgets('Mochi’s window or the popover opening sends it home at once; Claude needing you hurries it; the animation setting ends it', (tester) async {
      begin();
      adventure().explore();
      await run(tester, 1);
      shown = false;
      mischief.surfaceChanged();
      expect(adventure().active, isFalse);
      expect(home.returns, hasLength(1));
      shown = true;
      adventure().explore();
      await run(tester, 1);
      t.desktop.sessions.apply(hook('Notification', notificationType: 'permission_prompt', at: now));
      adventure().consider();
      expect(adventure().perfState(), 'adventure (heading home)');
      await run(tester, 3);
      expect(adventure().active, isFalse);
      await done(tester);
    });

    testWidgets('draws 30 frames a second while it moves and 8 while it holds, sending only what changed', (tester) async {
      begin();
      adventure().explore();
      await drawn(tester);
      var sawMoving = false, sawHolding = false;
      for (var i = 0; i < 900; i++) {
        await tester.pump(const Duration(milliseconds: 33));
        final every = adventure().every;
        if (every == DesktopAdventure.moveEvery) sawMoving = true;
        if (every == DesktopAdventure.holdEvery) sawHolding = true;
        if (sawMoving && sawHolding) break;
      }
      expect(sawMoving, isTrue);
      expect(sawHolding, isTrue);
      // Standing still sends no more than its eight a second, and only when the picture or the place changed.
      await untilStanding(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 130));
      final sent = mischief.cast.sent, unchanged = mischief.cast.unchanged;
      await run(tester, 0.6);
      expect(mischief.cast.sent - sent + (mischief.cast.unchanged - unchanged), lessThanOrEqualTo(8), reason: 'at most the frames drawn');
      await done(tester);
    });
  });

  group('carrying it', () {
    Future<(int, int)> out(WidgetTester tester) async {
      begin();
      adventure().explore();
      await drawn(tester);
      await untilStanding(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 130));
      return adventure().feet!;
    }

    testWidgets('a press and a drag lifts it by the scruff; let go over a window and it falls onto it and carries on', (tester) async {
      final feet = await out(tester);
      final actor = mischief.pet!.actor;
      stage.point(actor, StagePointerKind.down, screenX: feet.$1, screenY: feet.$2 - 20);
      expect(adventure().carried, isFalse, reason: 'a press alone is not a lift');
      pointer = (feet.$1 + 2, feet.$2 - 18);
      stage.point(actor, StagePointerKind.move, screenX: pointer!.$1, screenY: pointer!.$2);
      expect(adventure().carried, isFalse, reason: 'not far enough yet');
      pointer = (700, 150);
      stage.point(actor, StagePointerKind.move, screenX: 700, screenY: 150);
      expect(adventure().carried, isTrue);
      expect(adventure().perfState(), 'adventure (carried)');
      await run(tester, 0.3);
      // It hangs below the pointer (the scruff is the pointer).
      expect(adventure().feet!.$2, greaterThan(150));
      expect(adventure().feet!.$2, lessThan(150 + 60));
      expect(adventure().every, DesktopAdventure.moveEvery);
      // Let go above the editor (its top is at y 300): it falls onto it.
      stage.point(actor, StagePointerKind.up, screenX: 700, screenY: 150);
      expect(adventure().carried, isFalse);
      expect(adventure().plan, isNotNull);
      await run(tester, 1.5);
      expect(adventure().terrain!.ledge(adventure().plan!.sample(t.desktop.world.now()).point, tolerance: 2), isNotNull);
      expect(adventure().plan!.sample(t.desktop.world.now()).point.y, closeTo(780, 2));
      await done(tester);
    });

    testWidgets('let go on the taskbar and the adventure ends there', (tester) async {
      final feet = await out(tester);
      final actor = mischief.pet!.actor;
      stage.point(actor, StagePointerKind.down, screenX: feet.$1, screenY: feet.$2 - 20);
      pointer = (900, 1050);
      stage.point(actor, StagePointerKind.move, screenX: 900, screenY: 1050);
      expect(adventure().carried, isTrue);
      stage.point(actor, StagePointerKind.up, screenX: 900, screenY: 1050);
      expect(adventure().active, isFalse);
      expect(home.out, isFalse);
      expect(home.returns.last, 900, reason: 'home where it was dropped');
      expect(stage.showing, isEmpty);
      await done(tester);
    });

    testWidgets('a click pets it (it stops for a happy bounce) and a right-click opens the menu', (tester) async {
      final feet = await out(tester);
      final actor = mischief.pet!.actor;
      stage.point(actor, StagePointerKind.down, screenX: feet.$1, screenY: feet.$2 - 20);
      stage.point(actor, StagePointerKind.up, screenX: feet.$1, screenY: feet.$2 - 20);
      expect(adventure().carried, isFalse);
      expect(adventure().plan!.segments.any((s) => s.animation == w.PetAnimation.happyBounce), isTrue);
      stage.point(actor, StagePointerKind.rightUp, screenX: feet.$1, screenY: feet.$2 - 20);
      expect(menus, [(feet.$1, feet.$2 - 20)]);
      await done(tester);
    });
  });

  group('settings', () {
    testWidgets('turning Adventures off hurries it home; “Sets off by itself” never keeps it from Explore', (tester) async {
      begin();
      adventure().explore();
      await run(tester, 1);
      t.desktop.settings.adventure = const w.AdventureSettings(enabled: false);
      expect(adventure().perfState(), 'adventure (heading home)');
      await run(tester, 3);
      expect(adventure().active, isFalse);
      t.desktop.settings.adventure = const w.AdventureSettings(spontaneous: w.AdventureFrequency.never);
      expect(adventure().explore(), AdventureStart.started);
      await done(tester);
    });

    test('the settings are saved under adventure, with the Mac’s keys', () {
      t = TestDesktop.make(settings: {'adventure': {'enabled': false, 'spontaneous': 'rarely'}});
      expect(t.desktop.settings.adventure.enabled, isFalse);
      expect(t.desktop.settings.adventure.spontaneous, w.AdventureFrequency.rarely);
      t.desktop.settings.adventure = const w.AdventureSettings();
      expect(t.document.json?['adventure'], {'enabled': true, 'spontaneous': 'sometimes'});
      mischief = MischiefStage(desktop: t.desktop, stage: FakeNativeStage(), displays: FakeDisplays(), cursor: () => null);
    });
  });

  group('one owner at a time', () {
    testWidgets('an adventure you ask for takes Mochi from the cursor buddy; it does not come back for it until it is home', (tester) async {
      pointer = (900, 500);
      begin(mischiefOn: true);
      await run(tester, 0.3);
      expect(mischief.buddy!.active, isTrue);
      expect(home.out, isTrue);
      expect(adventure().explore(), AdventureStart.started);
      expect(mischief.buddy!.active, isFalse);
      expect(adventure().active, isTrue);
      expect(home.out, isTrue);
      expect(home.returns, isEmpty, reason: 'Mochi never went home in between');
      await run(tester, 2);
      expect(mischief.buddy!.active, isFalse, reason: 'it stays off while the adventure has Mochi');
      expect(adventure().explore(), AdventureStart.headingHome);
      await run(tester, 4);
      expect(adventure().active, isFalse);
      expect(mischief.buddy!.active, isTrue, reason: 'the buddy has Mochi again');
      await done(tester);
    });

    testWidgets('and from the screen roamer', (tester) async {
      final dice = _Dice()..value = 0;
      mischief = MischiefStage(
        desktop: t.desktop,
        stage: stage,
        displays: displays,
        cursor: () => null,
        home: home,
        shown: () => shown,
        frames: frames,
        random: dice,
      );
      t.desktop.mischief.start();
      mischief.start();
      t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.cursorBuddy: false});
      await run(tester, 4.1);
      dice.value = 0.99;
      final roamer = mischief.roamer!;
      expect(roamer.active, isTrue, reason: 'out for a walk to the next display');
      expect(adventure().explore(), AdventureStart.started);
      expect(roamer.active, isFalse);
      expect(adventure().active, isTrue);
      expect(home.returns, isEmpty);
      await run(tester, 3);
      expect(roamer.active, isFalse);
      await done(tester);
    });
  });
}
