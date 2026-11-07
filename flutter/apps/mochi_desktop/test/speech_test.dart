// Mochi talks (docs/SPRINT_2.md W11) on Windows: Mochi's world decides when Mochi and Patch say something (the Mac's
// SpeechController, mochi_world's SpeechDirector) and the bubbles show it on the taskbar pet, the desktop pet and in the
// room; Settings › Fun › Talking has the Mac's switches; fresh lines come from Claude Haiku through `claude -p`, with
// only the kind of moment sent.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/fresh_lines.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/room_view.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_wire/mochi_wire.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

void main() {
  group('When Mochi and Patch speak', () {
    late DateTime now;
    late double seconds;
    late TestDesktop t;

    setUp(() {
      now = DateTime(2026, 11, 8, 15);
      seconds = 1000;
      t = TestDesktop.make(clock: () => now, uptime: () => seconds);
    });
    tearDown(() => t.dispose());

    void later(Duration by) {
      final steps = (by.inMilliseconds / 250).ceil();
      for (var i = 0; i < steps; i++) {
        now = now.add(const Duration(milliseconds: 250));
        seconds += 0.25;
        t.desktop.world.tick();
      }
    }

    WireEvent event(String name) => hook(name, at: now)..id = 'id-$name-${now.microsecondsSinceEpoch}';

    test("Claude's moments: a finished turn gets a word, and the bubble goes after its time", () {
      t.desktop.receive(event('SessionStart'));
      later(const Duration(seconds: 40));
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(seconds: 40));
      t.desktop.receive(event('Stop'));
      final said = t.desktop.world.speechNow.value;
      expect(said, isNotNull);
      expect(
        w.SpeechLines.lines(w.SpeechOccasion.turnCompleted).map((line) => line.text),
        contains(said!.text),
        reason: 'one of the Mac’s lines for a finished turn',
      );
      later(const Duration(seconds: 7));
      expect(t.desktop.world.speechNow.value, isNull, reason: 'gone after its few seconds');
    });

    test('quiet keeps only what matters; talking off says nothing; pausing reactions too', () {
      t.desktop.settings.chattiness = w.Chattiness.quiet;
      t.desktop.receive(event('SessionStart'));
      later(const Duration(seconds: 30));
      t.desktop.receive(event('UserPromptSubmit'));
      expect(t.desktop.world.speechNow.value, isNull, reason: 'a new task is a small thing');
      later(const Duration(seconds: 30));
      t.desktop.receive(event('Stop'));
      expect(t.desktop.world.speechNow.value, isNotNull, reason: 'a finished turn matters');
      later(const Duration(seconds: 30));

      t.desktop.settings.speechEnabled = false;
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(seconds: 30));
      t.desktop.receive(event('Stop'));
      expect(t.desktop.world.speechNow.value, isNull);

      t.desktop.settings
        ..speechEnabled = true
        ..pauseReactions = true;
      later(const Duration(seconds: 30));
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(seconds: 30));
      t.desktop.receive(event('Stop'));
      expect(t.desktop.world.speechNow.value, isNull);
    });

    test('petting gets a word now and then; chatty muses while nothing is going on', () {
      var spoke = 0;
      for (var i = 0; i < 10; i++) {
        t.desktop.interact('pet');
        if (t.desktop.world.speechNow.value != null) spoke++;
        later(const Duration(seconds: 35));
      }
      expect(spoke, greaterThan(0));
      t.desktop.settings.chattiness = w.Chattiness.chatty;
      var musings = 0;
      void heard() {
        if (t.desktop.world.speechNow.value != null) musings++;
      }

      t.desktop.world.speechNow.addListener(heard);
      for (var minute = 0; minute < 40; minute++) {
        // You're here (Mochi stays awake).
        if (minute % 5 == 0) t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1));
        later(const Duration(minutes: 1));
      }
      t.desktop.world.speechNow.removeListener(heard);
      expect(musings, greaterThan(0));
    });

    test('Mochi says good morning (once) when you open its window', () {
      now = DateTime(2026, 11, 8, 9);
      later(const Duration(seconds: 6));
      expect(t.desktop.world.speechNow.value, isNull, reason: 'greetings wait for you to be clearly here');
      t.desktop.world.setWindowVisible(true);
      later(const Duration(seconds: 6));
      expect(w.SpeechLines.lines(w.SpeechOccasion.morning).map((line) => line.text), contains(t.desktop.world.speechNow.value?.text));
      later(const Duration(seconds: 10));
      t.desktop.world.setWindowVisible(false);
      t.desktop.world.setWindowVisible(true);
      later(const Duration(seconds: 6));
      expect(t.desktop.world.speechNow.value, isNull, reason: 'once per part of the day');
    });
  });

  group('Fresh lines from Claude Haiku', () {
    const asked = [w.SpeechOccasion.morning, w.SpeechOccasion.turnCompleted, w.SpeechOccasion.petted];

    test('one request through claude -p with Haiku: only the kinds of moment are sent', () async {
      final claude = FakeClaude(
        output: FakeClaude.result(
          jsonEncode({'morning': 'Sunny paws, sunny code!', 'turnCompleted': '"Done and dusted!"', 'petted': 'As an AI I cannot purr'}),
        ),
      );
      final lines = await HaikuLineWriter(() => claude).call(asked, petName: 'Biscuit', companionName: 'Byte');
      expect(claude.runs, hasLength(1));
      final run = claude.runs.single;
      expect(run.arguments.take(3), ['-p', '--model', 'haiku']);
      expect(run.arguments, containsAll(['--tools', '--no-session-persistence', '--system-prompt']));
      final system = run.arguments.last;
      expect(system, contains('Biscuit'));
      expect(system, contains('the Windows taskbar'));
      expect(system, isNot(contains('\n')), reason: 'one line (claude.cmd runs through cmd.exe)');
      expect(run.input, contains('- morning (voice "pet"): It is morning and the user just showed up. What do you say?'));
      expect(run.input.split('\n'), hasLength(3));
      expect(lines[w.SpeechOccasion.morning]?.single.text, 'Sunny paws, sunny code!');
      expect(lines[w.SpeechOccasion.turnCompleted]?.single.text, 'Done and dusted!', reason: 'quotes cleaned off');
      expect(lines.containsKey(w.SpeechOccasion.petted), isFalse, reason: 'a refusal is dropped');
    });

    test('no Claude Code, an error or a reply without JSON: no fresh lines (the hand-written ones carry on)', () async {
      expect(await HaikuLineWriter(() => null).call(asked, petName: 'Mochi', companionName: 'Patch'), isEmpty);
      final failing = FakeClaude(output: '', exitCode: 1);
      expect(await HaikuLineWriter(() => failing).call(asked, petName: 'Mochi', companionName: 'Patch'), isEmpty);
      final chatty = FakeClaude(output: FakeClaude.result('Sure! Here are some lines.'));
      expect(await HaikuLineWriter(() => chatty).call(asked, petName: 'Mochi', companionName: 'Patch'), isEmpty);
    });

    test('with the switch on, Mochi asks every couple of hours and keeps the lines', () async {
      final t = TestDesktop.make();
      addTearDown(t.dispose);
      t.claude.output = FakeClaude.result(jsonEncode({'idle': 'Tail wiggles and code giggles'}));
      final speech = t.desktop.world.speech;
      expect(speech.refillFreshLines(), isNull, reason: 'off by default on Windows');
      t.desktop.settings.speechFreshLines = true;
      await speech.refillFreshLines();
      expect(t.claude.runs, hasLength(1));
      expect(speech.freshLines[w.SpeechOccasion.idle]?.single.text, 'Tail wiggles and code giggles');
      expect(speech.refillFreshLines(), isNull, reason: 'not again so soon');
    });
  });

  group('The bubbles', () {
    late TestDesktop t;

    setUp(() => t = TestDesktop.make());
    tearDown(() => t.dispose());

    Future<DesktopAppState> show(WidgetTester tester, {required Surface surface, ThemeMode theme = ThemeMode.light, double scale = 1}) async {
      t.desktop.settings.themeMode = theme;
      tester.view.physicalSize = (surface == Surface.main ? SurfaceSizes.main : SurfaceSizes.pet) * scale;
      tester.view.devicePixelRatio = scale;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: surface,
          library: Future<PoseLibrary?>.value(),
          strollClock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      return tester.state<DesktopAppState>(find.byType(DesktopApp));
    }

    for (final theme in [ThemeMode.light, ThemeMode.dark]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('on the desktop pet, and in the room, over whoever speaks (${theme.name}, ${scale.toStringAsFixed(0)}× text)', (tester) async {
          await show(tester, surface: Surface.pet, theme: theme, scale: scale);
          final world = t.desktop.world;
          world.world.say('Wheee! Again!');
          world.tick();
          await tester.pump();
          expect(find.text('Wheee! Again!'), findsOneWidget);
          expect(find.bySemanticsLabel(RegExp('Wheee! Again!')), findsOneWidget, reason: 'the spoken label says it too');
          expect(tester.takeException(), isNull);
          await tester.pump(const Duration(seconds: 7));
          world.tick();
          await tester.pump();
          expect(find.text('Wheee! Again!'), findsNothing);

          // Mochi's window: the room, with Patch's line over his desk, and the world's note at the top.
          final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
          state.open(MainPage.home);
          await tester.pump(const Duration(milliseconds: 300));
          t.desktop.receive(hook('SessionStart', at: DateTime.now()));
          await tester.pump(const Duration(seconds: 6));
          world.tick();
          world.world.say('Booting up… hello!', speaker: w.SpeechSpeaker.companion);
          world.world.showToast(title: 'Friendship level 2', detail: 'Mochi is happy you’re here.');
          world.tick();
          await tester.pump();
          final bubble = find.descendant(of: find.byType(RoomView), matching: find.text('Booting up… hello!'));
          expect(bubble, findsOneWidget);
          final room = tester.getRect(find.byType(RoomView));
          expect(tester.getCenter(bubble).dx, greaterThan(room.center.dx), reason: 'over Patch, on the right');
          expect(find.text('Friendship level 2'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pump(const Duration(seconds: 8));
          world.tick();
          await tester.pump();
        });
      }
    }

    testWidgets('Claude needing you outranks a word from Mochi; a line from Patch off the taskbar is by his name', (tester) async {
      await show(tester, surface: Surface.pet);
      final world = t.desktop.world;
      t.desktop.settings.companionName = 'Byte';
      t.desktop.receive(hook('SessionStart', at: DateTime.now()));
      // Past the welcome and the note about the first session's achievement.
      await tester.pump(const Duration(seconds: 8));
      world.tick();
      world.world.say('Let me think…', speaker: w.SpeechSpeaker.companion);
      world.tick();
      await tester.pump();
      expect(find.text('Byte: Let me think…'), findsOneWidget, reason: 'Patch is not beside Mochi here');
      t.desktop.receive(hook('Notification', notificationType: 'permission_prompt', at: DateTime.now()));
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.textContaining('Claude needs you'), findsOneWidget);
      expect(find.text('Byte: Let me think…'), findsNothing);
      expect(find.byType(MochiView), findsOneWidget);
    });

    testWidgets('Settings › Fun › Talking: the switches, chattiness and fresh lines, by keyboard too', (tester) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.fun,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final settings = t.desktop.settings;
      expect(find.text('Talking'), findsOneWidget);
      expect(find.text('Not on Windows yet'), findsWidgets, reason: 'games and the rest are still to come');
      expect(find.text('Talking in speech bubbles'), findsNothing, reason: 'no “Not on Windows yet” row for it any more');

      await tester.tap(find.widgetWithText(ChoiceChip, 'Chatty'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.chattiness, w.Chattiness.chatty);
      expect((t.document.json!['speech'] as Map)['chattiness'], 'chatty');
      expect(t.desktop.world.world.settings.chattiness, w.Chattiness.chatty, reason: 'Mochi’s world follows');

      final fresh = find.ancestor(of: find.text('Fresh lines from Claude Haiku'), matching: find.byType(ToggleRow));
      await tester.tap(find.descendant(of: fresh, matching: find.byType(Switch)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.speechFreshLines, isTrue);
      expect((t.document.json!['speech'] as Map)['useAppleIntelligence'], isTrue, reason: 'the Mac’s key');

      // Talking off: chattiness and fresh lines can't be changed meanwhile.
      final talking = find.ancestor(of: find.text('Mochi and Patch talk in speech bubbles'), matching: find.byType(ToggleRow));
      final toggle = find.descendant(of: talking, matching: find.byType(Switch));
      Focus.of(tester.element(find.descendant(of: toggle, matching: find.byType(CustomPaint)).last)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.speechEnabled, isFalse);
      expect(tester.widget<Switch>(find.descendant(of: fresh, matching: find.byType(Switch))).onChanged, isNull);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Quiet')).onSelected, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
