// The focus buddy on Windows (docs/SPRINT_2.md W15), as the Mac's FocusController runs it: Mochi naps while you focus,
// non-urgent sounds stay quiet, a break wakes Mochi for a stretch (with the chime and the notification as Settings
// says), completed blocks are kept for the recap in focus-log.json, and a block the PC slept through isn't counted. It
// ticks once a second only while a session runs and the screen can be seen. The popover's row, the menus and Settings ›
// Fun › Focus buddy; light and dark, 1× and 2× text, the screen reader.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart' show SystemActivity;
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_desktop/src/ui/popover/popover_view.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

void main() {
  late DateTime now;
  late double seconds;
  late TestDesktop t;

  setUp(() {
    now = DateTime(2026, 11, 8, 10);
    seconds = 500;
  });

  TestDesktop make({Map<String, Object?>? settings, Map<String, Object?> files = const {}}) =>
      t = TestDesktop.make(clock: () => now, uptime: () => seconds, settings: {'soundEnabled': true, ...?settings}, files: files);

  /// Time passes, the world and the focus buddy moving on as their timers would.
  void later(Duration by, {bool focusTicks = true}) {
    final steps = (by.inMilliseconds / 250).ceil();
    for (var i = 0; i < steps; i++) {
      now = now.add(const Duration(milliseconds: 250));
      seconds += 0.25;
      t.desktop.world.tick();
      if (focusTicks && i % 4 == 3) t.desktop.focus.tick();
    }
  }

  group('A focus session', () {
    tearDown(() => t.dispose());

    test('starting it: Mochi yawns and naps through the block, as on the Mac', () {
      make();
      final focus = t.desktop.focus;
      expect(focus.running, isFalse);
      expect(focus.menuTitle, 'Start Focus');
      focus.toggle();
      expect(focus.running, isTrue);
      expect(t.desktop.world.toastNow.value?.title, 'Focus · 25 minutes');
      expect(t.desktop.world.toastNow.value?.detail, 'Mochi wakes you for a stretch break.');
      expect(t.desktop.world.speechNow.value?.text, "Focus time. I'll nap right here.");
      expect(t.desktop.world.world.pet.current.animation, w.PetAnimation.yawn);
      expect(t.desktop.world.asleep, isTrue, reason: 'Mochi naps while you focus (the taskbar’s Mochi too)');
      later(const Duration(minutes: 1));
      expect(focus.menuTitle, 'Stop Focus (Focus 24:00 left)');
      expect(t.desktop.world.world.pet.base, w.PetAnimation.sleep);
    });

    test('while a block runs only what needs you makes a sound', () async {
      make();
      await t.desktop.start();
      t.desktop.focus.begin();
      final before = t.sound.played.length;
      t.desktop.receive(hook('SessionStart', at: now));
      t.desktop.receive(hook('UserPromptSubmit', at: now));
      expect(t.sound.played.length, before, reason: 'no greeting chime during focus');
      t.desktop.receive(hook('PermissionRequest', tool: 'Bash', at: now));
      expect(t.sound.played.length, before + 1, reason: 'Claude needs you: that still sounds');
      t.desktop.focus.stop();
      expect(t.desktop.reactions.focusing(), isFalse);
    });

    test('a break wakes Mochi for a stretch, with the chime and (if asked for) a notification; the block is kept', () {
      make(settings: {
        'focus': {'workMinutes': 25, 'bannerAtBreak': true},
      });
      final focus = t.desktop.focus..begin();
      final sounds = t.sound.played.length;
      later(const Duration(minutes: 25, seconds: 1));
      expect(focus.status?.phase, w.FocusPhase.shortBreak);
      expect(t.desktop.world.toastNow.value?.title, 'Stretch break!');
      expect(t.desktop.world.toastNow.value?.detail, 'Focus block 1 done · 5 minutes break.');
      expect(t.desktop.world.asleep, isFalse, reason: 'awake for the break');
      expect(t.sound.played.length, greaterThan(sounds), reason: 'the chime');
      expect(t.toasts.shown.last.title, 'Stretch break!', reason: 'the notification Settings asked for');
      expect(t.toasts.shown.last.body, 'Mochi is awake. Stand up, stretch and rest your eyes.');
      later(const Duration(seconds: 2));
      expect(t.desktop.world.world.pet.current.animation, w.PetAnimation.stretch);
      expect(focus.log.blocks, hasLength(1));
      final saved = t.stores['focus-log.json']!.json! as List;
      expect(saved.single, {'endedAt': isA<num>(), 'minutes': 25.0}, reason: 'the Mac’s focus-log.json');
      later(const Duration(minutes: 5));
      expect(focus.status?.phase, w.FocusPhase.focus);
      expect(focus.status?.cycle, 2);
      expect(t.desktop.world.toastNow.value?.title, 'Back to focus');
    });

    test('a phase the PC slept through ends the session quietly and isn’t counted', () {
      make();
      final focus = t.desktop.focus..begin();
      now = now.add(const Duration(minutes: 40));
      focus.tick();
      expect(focus.running, isFalse);
      expect(t.desktop.world.toastNow.value?.title, 'Focus session ended');
      expect(t.desktop.world.toastNow.value?.detail, "Your PC was asleep when the block ended, so it wasn't counted.");
      expect(focus.log.blocks, isEmpty);
    });

    test('skipping a block starts the break without counting it; stopping says so', () {
      make();
      final focus = t.desktop.focus..begin();
      focus.skip();
      expect(focus.status?.phase, w.FocusPhase.shortBreak);
      expect(focus.log.blocks, isEmpty);
      focus.stop();
      expect(focus.running, isFalse);
      expect(t.desktop.world.speechNow.value?.text, 'Okay! Back to playing.');
    });

    test('the kept blocks come back at the next launch (a week of them)', () {
      final ended = DateTime(2026, 11, 7, 16);
      final old = DateTime(2026, 10, 20, 16);
      make(files: {
        'focus-log.json': [
          {'endedAt': old.toUtc().microsecondsSinceEpoch / 1e6, 'minutes': 25},
          {'endedAt': ended.toUtc().microsecondsSinceEpoch / 1e6, 'minutes': 25},
        ],
      });
      expect(t.desktop.focus.log.blocks.map((b) => b.endedAt), [ended.toUtc()], reason: 'older than a week is dropped');
    });

    test('settings are the Mac’s `focus`; naps can be turned off', () {
      make();
      t.desktop.settings.focus = const w.FocusSettings(workMinutes: 50, napsDuringFocus: false);
      expect((t.document.json!['focus']! as Map)['workMinutes'], 50);
      final focus = t.desktop.focus..begin();
      expect(t.desktop.world.toastNow.value?.title, 'Focus · 50 minutes');
      expect(t.desktop.world.asleep, isFalse, reason: 'Mochi keeps you company instead');
      expect(focus.status?.duration, 3000);
    });
  });

  group('Timers', () {
    tearDown(() => t.dispose());

    test('nothing ticks without a session; every second with one; one wake at the end while the screen is off', () {
      make();
      final focus = t.desktop.focus;
      expect(focus.ticking, isFalse);
      focus.begin();
      expect((focus.ticking, focus.everySecond), (true, true));
      t.usage.activity = const SystemActivity(idleSeconds: 0, displaysAsleep: true);
      t.desktop.rhythm.sample();
      expect((focus.ticking, focus.everySecond), (true, false), reason: 'one timer for the end of the block');
      t.usage.activity = const SystemActivity(idleSeconds: 0);
      t.desktop.rhythm.sample();
      expect(focus.everySecond, isTrue);
      focus.stop();
      expect(focus.ticking, isFalse);
    });

    testWidgets('the end-of-phase wake brings the break on time while nobody looks', (tester) async {
      final start = tester.binding.clock.now();
      t = TestDesktop.make(clock: () => now.add(tester.binding.clock.now().difference(start)), settings: {'soundEnabled': true});
      final focus = t.desktop.focus..begin(durations: w.FocusDurations(focus: 20, shortBreak: 10, longBreak: 10, cyclesBeforeLongBreak: 2));
      t.usage.activity = const SystemActivity(idleSeconds: 0, displaysAsleep: true);
      t.desktop.rhythm.sample();
      await tester.pump(const Duration(seconds: 21));
      expect(focus.status?.phase, w.FocusPhase.shortBreak);
      focus.stop();
      await t.dispose();
    });
  });

  group('On screen', () {
    late FakeShell shell;
    setUp(() {
      shell = FakeShell();
      make();
    });
    tearDown(() => t.dispose());

    Future<DesktopAppState> app(WidgetTester tester, {required Size size, MainPage page = MainPage.home, double scale = 1, SettingsTab? pane}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: shell,
          initialSurface: Surface.main,
          initialPage: page,
          initialPane: pane,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      return tester.state<DesktopAppState>(find.byType(DesktopApp));
    }

    testWidgets('the popover’s row counts down, Skip and Stop work, light and dark at 1× and 2× text', (tester) async {
      final companion = CompanionDirector(t.desktop.world);
      addTearDown(companion.dispose);
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        for (final scale in [1.0, 2.0]) {
          t.desktop.settings.themeMode = theme;
          t.desktop.focus.begin();
          tester.view.physicalSize = SurfaceSizes.popover;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: theme == ThemeMode.dark ? Brightness.dark : Brightness.light),
              home: Scaffold(
                body: PopoverView(
                  desktop: t.desktop,
                  companion: companion,
                  lastActivity: () => now,
                  onClose: () {},
                  onOpenMain: () {},
                  onAsk: () {},
                  onSettings: () {},
                  onSetUpClaude: () {},
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull, reason: '${theme.name} ${scale}x');
          await tester.ensureVisible(find.byType(FocusRow));
          expect(find.bySemanticsLabel('Focus 25:00 left, focus block 1 of 4'), findsOneWidget);
          now = now.add(const Duration(seconds: 3));
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('Focus 24:57 left'), findsOneWidget, reason: 'it counts down once a second');
          expect(find.text('Stop'), findsOneWidget, reason: 'the fun row’s Focus is Stop now');
          await tester.tap(find.text('Skip'));
          await tester.pump();
          expect(t.desktop.focus.status?.phase, w.FocusPhase.shortBreak);
          await tester.tap(find.byTooltip('Stop focus'));
          await tester.pump();
          expect(t.desktop.focus.running, isFalse);
          expect(find.byType(FocusRow), findsNothing);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 5));
        }
      }
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.reset();
    });

    testWidgets('the tray says Start or Stop Focus, and its item toggles a session', (tester) async {
      await app(tester, size: SurfaceSizes.main);
      shell.controller.add(ShellAction.focus);
      await tester.pump();
      expect(t.desktop.focus.running, isTrue);
      expect(shell.trayFocus.last, isTrue);
      expect(NativeShell.trayItems(style: t.desktop.settings.petStyle, focusing: true).map((item) => item.label), contains('Stop Focus'));
      shell.controller.add(ShellAction.focus);
      await tester.pump();
      expect(t.desktop.focus.running, isFalse);
      expect(shell.trayFocus.last, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Settings › Fun › Focus buddy: the Mac’s choices, saved under `focus`, and Start Focus', (tester) async {
      await app(tester, size: SurfaceSizes.settings, page: MainPage.settings, pane: SettingsTab.fun);
      await tester.ensureVisible(find.text('Focus buddy'));
      expect(find.text('Focus block'), findsOneWidget);
      expect(find.text('25 min'), findsOneWidget);
      await tester.tap(find.text('Mochi naps while you focus'));
      await tester.pump();
      expect(t.desktop.settings.focus.napsDuringFocus, isFalse);
      expect((t.document.json!['focus']! as Map)['napsDuringFocus'], isFalse);
      await tester.ensureVisible(find.text('Start Focus'));
      await tester.tap(find.text('Start Focus'));
      await tester.pump();
      expect(t.desktop.focus.running, isTrue);
      expect(find.text('Stop Focus'), findsOneWidget);
      expect(find.text('Focus sessions'), findsNothing, reason: 'no “Not on Windows yet” row for it any more');
      t.desktop.focus.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
