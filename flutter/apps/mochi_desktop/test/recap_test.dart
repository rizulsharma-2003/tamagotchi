// The daily recap on Windows (docs/SPRINT_2.md W16), as the Mac's RecapController keeps it: an event journal fed only
// with real events from Mochi's world (never simulated or restored ones, never paths), kept a week in journal.json; the
// day's card from it and the focus log; the evening announcement once per active day from the recap hour (with a
// Windows notification that opens the recap, for users who asked); the card drawn by the app and saved or copied as a
// picture; Settings › Fun › Daily recap. Light and dark, 1× and 2× text, the screen reader, timers stopping.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_world.dart' show MemoryWorldStore;
import 'package:mochi_desktop/src/core/pc_rhythm.dart' show SystemActivity;
import 'package:mochi_desktop/src/core/toasts.dart';
import 'package:mochi_desktop/src/platform/image_export.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/recap/recap_card.dart';
import 'package:mochi_desktop/src/ui/recap/recap_screen.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_wire/mochi_wire.dart' show WireOrigin;
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

/// The clipboard and Downloads, as the test sees them.
class FakeImages implements ImageExport {
  final List<ExportedImage> copied = [];
  final List<(String, Uint8List)> saved = [];
  final List<String> revealed = [];

  @override
  bool get canCopy => true;

  @override
  Future<bool> copy(ExportedImage image) async {
    copied.add(image);
    return true;
  }

  @override
  Future<String?> save(Uint8List png, String name) async {
    saved.add((name, png));
    return r'C:\Users\you\Downloads\' + name;
  }

  @override
  Future<void> reveal(String path) async => revealed.add(path);
}

void main() {
  late DateTime now;
  late double seconds;
  late TestDesktop t;

  setUp(() {
    now = DateTime(2026, 11, 8, 15);
    seconds = 1000;
  });

  TestDesktop make({Map<String, Object?>? settings, Map<String, Object?> files = const {}}) =>
      t = TestDesktop.make(clock: () => now, uptime: () => seconds, settings: settings, files: files);

  /// A turn in "web": the session, a prompt, a shell command and its result, the end of the turn.
  void turn({String session = 's1'}) {
    t.desktop.receive(hook('SessionStart', session: session, at: now));
    now = now.add(const Duration(minutes: 2));
    t.desktop.receive(hook('UserPromptSubmit', session: session, at: now));
    t.desktop.receive(hook('PreToolUse', session: session, tool: 'Bash', toolUseId: 'b1-$session', at: now));
    now = now.add(const Duration(minutes: 1));
    t.desktop.receive(hook('PostToolUse', session: session, tool: 'Bash', toolUseId: 'b1-$session', at: now));
    now = now.add(const Duration(minutes: 3));
    t.desktop.receive(hook('Stop', session: session, at: now));
  }

  group('The journal and the numbers', () {
    tearDown(() => t.dispose());

    test('real events from the world, never simulated ones; a day’s turns, sessions and tool calls', () {
      make();
      turn();
      final simulated = hook('Stop', session: 'sim', at: now)..origin = WireOrigin.simulator;
      t.desktop.receive(simulated);
      final journal = t.desktop.recap.journal;
      expect(journal.all.map((e) => e.sessionID).toSet(), {'s1'}, reason: 'nothing simulated');
      final today = t.desktop.recap.recap();
      expect((today.sessions, today.turnsFinished, today.toolCalls), (1, 1, 1));
      expect(today.topToolCategory, w.ToolCategory.shell);
      expect(today.streak, 1);
      expect(today.title(now: now, petName: 'Mochi', companionName: 'Patch'), 'Today with Mochi & Patch');
      expect(today.summary(petName: 'Mochi', companionName: 'Patch'), '1 turn finished across 1 session. Nice and steady.');
    });

    test('focus blocks count too', () {
      make();
      turn();
      t.desktop.focus.begin(durations: w.FocusDurations(focus: 25 * 60, shortBreak: 300, longBreak: 900, cyclesBeforeLongBreak: 4));
      now = now.add(const Duration(minutes: 25, seconds: 1));
      t.desktop.focus.tick();
      t.desktop.focus.stop();
      final today = t.desktop.recap.recap();
      expect((today.focusBlocks, today.focusMinutes), (1, 25));
      expect(today.tiles.whereType<w.RecapFocus>().single.value, '25 min');
    });

    test('kept a week in journal.json, without paths; read back at the next launch', () {
      make();
      turn();
      t.desktop.world.save();
      final saved = t.stores['journal.json']!.json! as List;
      expect(saved, isNotEmpty);
      expect(jsonEncode(saved), isNot(contains('/code/web')), reason: 'paths are never kept');
      final files = {'journal.json': saved};
      t.dispose();
      make(files: files);
      expect(t.desktop.recap.recap().turnsFinished, 1, reason: 'the day survives a restart');
    });

    test('a launch rebuilds Claude’s sessions from world.json without counting them twice', () {
      make();
      turn();
      t.desktop.world.save();
      final world = t.worldStore.json;
      final journal = t.stores['journal.json']!.json;
      t.dispose();
      t = TestDesktop.make(clock: () => now, uptime: () => seconds, worldStore: MemoryWorldStore(world), files: {'journal.json': journal});
      expect(t.desktop.recap.journal.all.where((e) => e.kind == w.EventKind.turnCompleted), hasLength(1));
    });
  });

  group('The evening announcement', () {
    tearDown(() => t.dispose());

    test('from 18:00, once per active day: a note, a line, both greeting; checked each minute with the world', () {
      make();
      turn();
      t.desktop.recap.check();
      expect(t.desktop.world.toastNow.value?.title, isNot('Your day with Claude is ready'), reason: 'not before 18:00');
      now = DateTime(2026, 11, 8, 18, 0, 30);
      seconds += 120;
      t.desktop.world.tick();
      expect(t.desktop.world.toastNow.value?.title, 'Your day with Claude is ready');
      expect(t.desktop.world.toastNow.value?.detail, 'Mochi & Patch made you a recap card. Open Recap in Mochi’s popover.');
      expect(t.desktop.world.speechNow.value?.text, 'Your day with Claude is ready! Want to see?');
      expect(t.desktop.world.world.pet.current.animation, w.PetAnimation.greet);
      expect((t.document.json!['recap']! as Map)['lastAnnouncedDay'], '2026-11-08', reason: 'the Mac’s key');
      expect(t.toasts.shown, isEmpty, reason: 'no Windows notification unless asked for');
      t.desktop.world.world.showToast(title: 'Something else', detail: '');
      now = now.add(const Duration(minutes: 5));
      t.desktop.recap.check();
      expect(t.desktop.world.world.activeToast?.title, 'Something else', reason: 'once a day');
    });

    test('a quiet day isn’t announced', () {
      make();
      now = DateTime(2026, 11, 8, 19);
      t.desktop.recap.check();
      expect(t.desktop.settings.recap.lastAnnouncedDay, isNull);
    });

    test('with notifications on, a Windows notification that opens the recap (never while paused)', () {
      make(settings: {
        'recap': {'banner': true},
      });
      turn();
      now = DateTime(2026, 11, 8, 18, 5);
      t.desktop.recap.check();
      final toast = t.toasts.shown.single;
      expect((toast.title, toast.target), ('Your day with Claude is ready', ToastTarget.recap));
      expect(toast.body, 'Mochi & Patch made you a recap card. 1 turn finished · 1 session.');
      expect(ToastTarget.parse(ToastTarget.recap.encode()), ToastTarget.recap);
      t.desktop.settings.pauseReactions = true;
      t.desktop.recap.announceNow();
      expect(t.toasts.shown, hasLength(1), reason: 'paused');
    });
  });

  group('The card', () {
    late FakeImages images;
    late FakeShell shell;

    setUp(() {
      images = FakeImages();
      shell = FakeShell();
      make();
    });
    tearDown(() => t.dispose());

    Future<DesktopAppState> open(WidgetTester tester, {double scale = 1, MainPage page = MainPage.recap, SettingsTab? pane}) async {
      tester.view.physicalSize = page == MainPage.settings ? SurfaceSizes.settings : SurfaceSizes.recap;
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
          images: images,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      return tester.state<DesktopAppState>(find.byType(DesktopApp));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    }

    /// Lets the picture be drawn (the engine's real work) until [done], and the page hear back.
    Future<void> drawn(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 60 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pump();
    }

    testWidgets('today’s card for the screen reader, light and dark at 1× and 2× text; back a day and forward', (tester) async {
      final handle = tester.ensureSemantics();
      turn();
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        for (final scale in [1.0, 2.0]) {
          t.desktop.settings.themeMode = theme;
          await open(tester, scale: scale);
          expect(tester.takeException(), isNull, reason: '${theme.name} ${scale}x');
          expect(find.text('Save Image…'), findsOneWidget);
          expect(
            find.bySemanticsLabel(RegExp(
              r'^Today with Mochi & Patch\. Sunday, 8 November 2026\. At least 1 day in a row\. 1 turn finished\. 1 session\. '
              r'1 tool call, Mostly in the shell\. 3:00 PM–3:06 PM active, 6 min\. 1 turn finished across 1 session\. Nice and steady\. '
              r'From real Claude Code events on this PC\.$',
            )),
            findsOneWidget,
          );
          await close(tester);
        }
      }
      final state = await open(tester);
      final screen = tester.state<RecapScreenState>(find.byType(RecapScreen));
      expect(state.page, MainPage.recap);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right_rounded)).onPressed, isNull, reason: 'no tomorrow');
      await tester.tap(find.byTooltip('Previous day'));
      await tester.pump();
      expect(screen.day, DateTime(2026, 11, 7));
      expect(find.bySemanticsLabel(RegExp(r'^A quiet day with Mochi & Patch\. Saturday, 7 November 2026\.')), findsOneWidget);
      await tester.tap(find.byTooltip('Next day'));
      await tester.pump();
      expect(screen.day, DateTime(2026, 11, 8));
      handle.dispose();
      await close(tester);
    });

    testWidgets('Copy Image and Save Image… (Ctrl+S): a picture drawn by the app, saved to Downloads', (tester) async {
      turn();
      await open(tester);
      await tester.tap(find.text('Copy Image'));
      await drawn(tester, () => images.copied.isNotEmpty);
      final copied = images.copied.single;
      expect((copied.width, copied.height), (840, 1120), reason: 'twice the card’s size');
      expect(copied.png.sublist(1, 4), utf8.encode('PNG'));
      expect(copied.rgbaOnWhite.length, 840 * 1120 * 4);
      expect(find.text('Copied'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await drawn(tester, () => images.saved.isNotEmpty);
      expect(images.saved.single.$1, 'Recap 2026-11-08.png');
      expect(find.text('Saved to Downloads as Recap 2026-11-08.png.'), findsOneWidget);
      await tester.ensureVisible(find.text('Show in Folder'));
      await tester.tap(find.text('Show in Folder'));
      expect(images.revealed.single, endsWith('Recap 2026-11-08.png'));
      await tester.pump(const Duration(seconds: 2));
      await close(tester);
    });

    testWidgets('only the characters move: 30 frames a second, none while the screen can’t be seen', (tester) async {
      await open(tester);
      final screen = tester.state<RecapScreenState>(find.byType(RecapScreen));
      expect(screen.fps, 30);
      t.usage.activity = const SystemActivity(idleSeconds: 0, displaysAsleep: true);
      t.desktop.rhythm.sample();
      await tester.pump();
      expect(screen.fps, 0);
      t.usage.activity = const SystemActivity(idleSeconds: 0);
      t.desktop.rhythm.sample();
      await tester.pump();
      expect(screen.fps, 30);
      await close(tester);
    });

    testWidgets('the recap’s notification, the tray and the popover’s Recap open the card', (tester) async {
      final state = await open(tester, page: MainPage.home);
      state.openFromNotification(ToastTarget.recap);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.page, MainPage.recap);
      state.open(MainPage.home);
      await tester.pump(const Duration(milliseconds: 300));
      shell.controller.add(ShellAction.recap);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.page, MainPage.recap);
      expect(NativeShell.trayItems(style: t.desktop.settings.petStyle).map((item) => item.label), contains('Today’s Recap…'));
      await close(tester);
    });

    testWidgets('Settings › Fun › Daily recap: the Mac’s choices under `recap`, and Open Recap…', (tester) async {
      await open(tester, page: MainPage.settings, pane: SettingsTab.fun);
      await tester.ensureVisible(find.text('Daily recap'));
      await tester.tap(find.text('Also show a notification'));
      await tester.pump();
      expect((t.document.json!['recap']! as Map)['banner'], isTrue);
      await tester.tap(find.text('Tell me when my day’s recap is ready'));
      await tester.pump();
      expect(t.desktop.settings.recap.announce, isFalse);
      expect(find.text('Daily recap'), findsOneWidget);
      expect(find.text('A card of what you and Claude did today.'), findsNothing, reason: 'no “Not on Windows yet” row any more');
      await tester.ensureVisible(find.text('Open Recap…'));
      await tester.tap(find.text('Open Recap…'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.state<DesktopAppState>(find.byType(DesktopApp)).page, MainPage.recap);
      await close(tester);
    });
  });

  test('the clipboard’s bitmap: a 32-bit DIB, rows from the bottom up, on white', () {
    final rgba = Uint8List.fromList([10, 20, 30, 255, 40, 50, 60, 255]);
    final dib = Win32ImageExport.dib(ExportedImage(png: Uint8List(0), rgbaOnWhite: rgba, width: 1, height: 2));
    final header = ByteData.sublistView(dib);
    expect((header.getUint32(0, Endian.little), header.getInt32(4, Endian.little), header.getInt32(8, Endian.little)), (40, 1, 2));
    expect(header.getUint16(14, Endian.little), 32);
    expect(dib.sublist(40), [60, 50, 40, 255, 30, 20, 10, 255], reason: 'BGRA, the bottom row first');
    expect(RecapText.date(DateTime(2026, 11, 8)), 'Sunday, 8 November 2026');
  });
}
