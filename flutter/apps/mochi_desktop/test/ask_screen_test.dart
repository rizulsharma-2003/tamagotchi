// "What's on my screen?" (docs/SPRINT_2.md X17): off by default and hidden while off; one picture of the window you were
// using before Mochi came up, only when the button is pressed; shown on a preview card; written for Claude Code only on
// Send and gone when the request ends however it ends, and at startup. A fake capturer, a fake Assistant folder.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/ask_attach.dart';
import 'package:mochi_desktop/src/core/ask_mochi.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/screen_peek.dart';
import 'package:mochi_desktop/src/platform/foreground_window.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/screens/home_screen.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart' show ToggleRow;
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_ui/mochi_ui.dart';

import 'support/attach_fakes.dart';
import 'support/brain_fakes.dart';
import 'support/fakes.dart';

final DateTime _noon = DateTime(2026, 11, 9, 12);
const int _chrome = 0x1001;
const int _notepad = 0x1002;

ScreenGrab _seen(String app) => ScreenGrab.seen(png: FakeCapturer.png, app: app);

void main() {
  group('which window', () {
    test('the last window that is an app is remembered; Mochi\'s own, the desktop and nothing are not', () {
      final windows = FakeForegroundWindows();
      final memory = ForegroundMemory(windows);
      expect(memory.hwnd, 0);
      windows.window = const ForegroundWindow(_chrome, ForegroundKind.app);
      memory.note();
      expect(memory.hwnd, _chrome);
      for (final other in [
        const ForegroundWindow(0x9, ForegroundKind.ours),
        const ForegroundWindow(0x8, ForegroundKind.shell),
        const ForegroundWindow(0, ForegroundKind.app),
        null,
      ]) {
        windows.window = other;
        memory.note();
        expect(memory.hwnd, _chrome, reason: '$other is not a window you were using');
      }
      windows.window = const ForegroundWindow(_notepad, ForegroundKind.app);
      memory.note();
      expect(memory.hwnd, _notepad, reason: 'the latest wins');
      expect(windows.reads, 6, reason: 'one read per event, nothing else');
    });

    test('program names are cleaned for the card and the prompt', () {
      expect(AppNames.clean('chrome.exe'), 'chrome');
      expect(AppNames.clean('Visual Studio Code'), 'Visual Studio Code');
      expect(AppNames.clean('evil"\nname[end].EXE'), 'evilnameend');
      expect(AppNames.clean(''), 'that app');
      expect(AppNames.clean(null), 'that app');
      expect(AppNames.clean('x' * 100).length, 40);
    });
  });

  group('ScreenPeek', () {
    late FakeForegroundWindows windows;
    late FakeCapturer capturer;
    late bool enabled;
    late ScreenPeek peek;

    setUp(() {
      windows = FakeForegroundWindows(const ForegroundWindow(_chrome, ForegroundKind.app));
      capturer = FakeCapturer()..grabs[_chrome] = _seen('chrome');
      enabled = true;
      peek = ScreenPeek(memory: ForegroundMemory(windows)..note(), capturer: capturer, enabled: () => enabled);
    });

    test('nothing is captured until look() is called: not at creation, not by asking for the preview', () async {
      expect(capturer.captured, isEmpty);
      expect(peek.preview, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(capturer.captured, isEmpty);
    });

    test('look() captures the remembered window (and only it), and the picture is the preview', () async {
      windows.window = const ForegroundWindow(_notepad, ForegroundKind.app);
      await peek.look();
      expect(capturer.captured, [_chrome], reason: 'the window remembered, not whatever has the focus now');
      expect(peek.preview!.app, 'chrome');
      expect(peek.preview!.png, FakeCapturer.png);
      expect(peek.note, isNull);
    });

    test('when it is off, look() does nothing and there is no preview', () async {
      enabled = false;
      await peek.look();
      expect(capturer.captured, isEmpty);
      expect(peek.preview, isNull);
    });

    test('turning it off drops a picture that was waiting', () async {
      await peek.look();
      expect(peek.preview, isNotNull);
      var heard = 0;
      peek.addListener(() => heard++);
      enabled = false;
      peek.settingsChanged();
      expect(peek.preview, isNull);
      expect(heard, 1);
      enabled = true;
      peek.settingsChanged();
      expect(peek.preview, isNull, reason: 'it does not come back');
    });

    test('Remove drops the picture; a later answer for it is not shown', () async {
      await peek.look();
      peek.remove();
      expect(peek.preview, isNull);
      final slow = peek.look();
      peek.remove();
      await slow;
      expect(peek.preview, isNull, reason: 'removed while it was being taken');
      expect(peek.busy, isFalse);
    });

    test('minimised, cloaked, our own, a shell window, or a failed capture: Mochi says it couldn\'t see that window', () async {
      for (final failure in ScreenFailure.values) {
        capturer.grabs[_chrome] = ScreenGrab.failed(failure);
        await peek.look();
        expect(peek.preview, isNull, reason: '$failure');
        expect(peek.note, startsWith("Mochi couldn't see that window"), reason: '$failure');
      }
      capturer.grabs[_chrome] = const ScreenGrab.failed(ScreenFailure.minimised);
      await peek.look();
      expect(peek.note, contains('minimised'));
      capturer.throws = true;
      await peek.look();
      expect(peek.note, "Mochi couldn't see that window.");
      expect(peek.preview, isNull);
    });

    test('an empty picture is a failure, not a preview', () async {
      capturer.grabs[_chrome] = ScreenGrab.seen(png: FakeCapturer.png.sublist(0, 0), app: 'chrome');
      await peek.look();
      expect(peek.preview, isNull);
      expect(peek.note, isNotNull);
    });

    test('with no window remembered, Mochi asks you to open it with the shortcut while you are in that window', () async {
      final none = ScreenPeek(memory: ForegroundMemory(FakeForegroundWindows()), capturer: capturer, enabled: () => true);
      await none.look();
      expect(capturer.captured, isEmpty);
      expect(none.note, contains("doesn't know which window"));
      expect(none.note, contains('shortcut'));
    });
  });

  group('the picture file', () {
    late Directory dir;
    late FolderScreenshotStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('mochi_shots');
      store = FolderScreenshotStore('${dir.path}${Platform.pathSeparator}Assistant');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('written under a random name in the Assistant folder, and deleted', () {
      final one = store.write(FakeCapturer.png)!;
      final two = store.write(FakeCapturer.png)!;
      expect(one, isNot(two));
      expect(one.substring(one.lastIndexOf(Platform.pathSeparator) + 1), matches(FolderScreenshotStore.pattern));
      expect(File(one).readAsBytesSync(), FakeCapturer.png);
      store.delete(one);
      expect(File(one).existsSync(), isFalse);
      expect(File(two).existsSync(), isTrue);
      store.delete(one);
    });

    test('only this store\'s own files can be deleted, and startup sweeps only the leftovers that match', () {
      final shot = store.write(FakeCapturer.png)!;
      final left = store.write(FakeCapturer.png)!;
      final other = File('${store.directory}${Platform.pathSeparator}notes.png')..writeAsStringSync('mine');
      final lookalike = File('${store.directory}${Platform.pathSeparator}mochi-screen-xyz.png')..writeAsStringSync('mine');
      final outside = File('${dir.path}${Platform.pathSeparator}mochi-screen-${'a' * 32}.png')..writeAsStringSync('mine');
      store.delete(other.path);
      store.delete(outside.path);
      expect(other.existsSync(), isTrue, reason: 'not a name it gave');
      expect(outside.existsSync(), isTrue);
      store.sweep();
      expect(File(shot).existsSync(), isFalse);
      expect(File(left).existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(lookalike.existsSync(), isTrue);
      expect(outside.existsSync(), isTrue, reason: 'outside the Assistant folder');
    });

    test('a missing folder and an unwritable place are not errors', () {
      FolderScreenshotStore('${dir.path}${Platform.pathSeparator}nope').sweep();
      final blocked = File('${dir.path}${Platform.pathSeparator}file')..writeAsStringSync('x');
      expect(FolderScreenshotStore(blocked.path).write(FakeCapturer.png), isNull);
    });
  });

  group('the settings switch', () {
    test('off at first, saved when turned on', () {
      final document = MemorySettingsDocument();
      final settings = DesktopSettings(document);
      expect(settings.showScreen, isFalse);
      settings.showScreen = true;
      expect(document.json!['showScreen'], true);
      expect(DesktopSettings(MemorySettingsDocument(document.json)).showScreen, isTrue);
      settings.showScreen = false;
      expect(DesktopSettings(MemorySettingsDocument(document.json)).showScreen, isFalse);
    });

    late TestDesktop t;
    setUp(() => t = TestDesktop.make(clock: () => _noon));
    tearDown(() => t.dispose());

    testWidgets('Settings › Assistant has "Let me show Mochi my screen", off, and it turns on and off', (tester) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(t.desktop.start);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          library: Future<PoseLibrary?>.value(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.assistant,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final row = find.text('Let me show Mochi my screen');
      await tester.ensureVisible(row);
      expect(row, findsOneWidget);
      final toggle = find.descendant(of: find.ancestor(of: row, matching: find.byType(ToggleRow)), matching: find.byType(Switch));
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(t.desktop.settings.showScreen, isFalse);
      await tester.tap(toggle);
      await tester.pump();
      expect(t.desktop.settings.showScreen, isTrue);
      await tester.tap(toggle);
      await tester.pump();
      expect(t.desktop.settings.showScreen, isFalse);
    });
  });

  group('in the Ask box', () {
    late FakeCapturer capturer;
    late FakeForegroundWindows windows;
    late FakeScreenshots store;
    late BrainRig rig;
    late AskMochi ask;
    late DesktopSettings settings;

    Future<void> pumpBox(WidgetTester tester, {bool enabled = false}) async {
      rig = BrainRig();
      addTearDown(rig.brain.dispose);
      settings = DesktopSettings(MemorySettingsDocument())..showScreen = enabled;
      windows = FakeForegroundWindows(const ForegroundWindow(_chrome, ForegroundKind.app));
      capturer = FakeCapturer()..grabs[_chrome] = _seen('chrome');
      store = FakeScreenshots();
      ask = AskMochi(
        sessions: rig.sessions,
        runner: () => null,
        cue: (_) {},
        brainFactory: (self) => rig.brain,
        screenshots: store,
        log: rig.logs.add,
        clock: () => DateTime(2026, 11, 9, 10),
      );
      ask.peek = ScreenPeek(memory: ForegroundMemory(windows)..note(), capturer: capturer, enabled: () => settings.showScreen);
      settings.addListener(ask.peek!.settingsChanged);
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: mochiTheme(Brightness.light, formFactor: MochiFormFactor.desktop),
          home: Scaffold(body: SingleChildScrollView(child: AskBox(ask: ask))),
        ),
      );
    }

    final button = find.text("What's on my screen?");

    Future<void> press(WidgetTester tester) async {
      await tester.tap(button);
      await tester.pump();
      await tester.pump();
    }

    Future<void> send(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Send to Mochi'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }

    testWidgets('off by default: there is no button, and nothing is ever captured', (tester) async {
      await pumpBox(tester);
      expect(settings.showScreen, isFalse);
      expect(button, findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(capturer.captured, isEmpty);
    });

    testWidgets('a box with no screen peek at all has no button either', (tester) async {
      await pumpBox(tester, enabled: true);
      ask.peek = null;
      await tester.pumpWidget(
        MaterialApp(
          theme: mochiTheme(Brightness.light, formFactor: MochiFormFactor.desktop),
          home: Scaffold(body: SingleChildScrollView(child: AskBox(key: UniqueKey(), ask: ask))),
        ),
      );
      expect(button, findsNothing);
    });

    testWidgets('turned on, the button shows; turned off again it goes, with any picture', (tester) async {
      await pumpBox(tester);
      settings.showScreen = true;
      await tester.pump();
      expect(button, findsOneWidget);
      await press(tester);
      expect(find.text('Your chrome window'), findsOneWidget);
      settings.showScreen = false;
      await tester.pump();
      expect(button, findsNothing);
      expect(find.text('Your chrome window'), findsNothing);
      settings.showScreen = true;
      await tester.pump();
      expect(find.text('Your chrome window'), findsNothing, reason: 'the old picture did not come back');
    });

    testWidgets('the capture happens only when the button is pressed: not on build, focus, typing, Send or time passing', (tester) async {
      await pumpBox(tester, enabled: true);
      await tester.pump(const Duration(seconds: 5));
      await tester.enterText(find.byType(TextField).first, 'hello');
      await tester.pump();
      expect(capturer.captured, isEmpty);
      await send(tester);
      expect(capturer.captured, isEmpty, reason: 'a plain question takes no picture');
      await press(tester);
      expect(capturer.captured, [_chrome], reason: 'once, and the window remembered before Mochi came up');
      await tester.pump(const Duration(seconds: 5));
      expect(capturer.captured, hasLength(1), reason: 'no polling');
    });

    testWidgets('the button is reachable by keyboard and named for a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBox(tester, enabled: true);
      final named = find.bySemanticsLabel(RegExp(r"^What's on my screen\?: takes one picture of the window you were using"));
      expect(named, findsOneWidget);
      expect(tester.getSemantics(named).flagsCollection.isButton, isTrue);
      var reached = false;
      await tester.tap(find.byType(TextField).first);
      for (var i = 0; i < 8 && !reached; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
          if (element.widget is TextButton && find.descendant(of: find.byWidget(element.widget), matching: button).evaluate().isNotEmpty) {
            reached = true;
          }
          return !reached;
        });
      }
      expect(reached, isTrue, reason: 'Tab gets to the button');
      expect(capturer.captured, isEmpty, reason: 'focus alone takes nothing');
      handle.dispose();
    });

    testWidgets('the preview card shows the window\'s program, Remove and Send; nothing is written or sent yet', (tester) async {
      await pumpBox(tester, enabled: true);
      await press(tester);
      expect(find.text('Your chrome window'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Remove'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Send'), findsOneWidget);
      expect(find.textContaining('Nothing leaves this PC until you press Send'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text("What's on my screen?"), findsWidgets, reason: 'the suggestion in the question box, too');
      expect(store.written, isEmpty, reason: 'nothing on disk before Send');
      expect(rig.launches, isEmpty);
      expect(ask.exchanges, isEmpty);
    });

    testWidgets('Remove takes the picture away: nothing was written, and Send then sends nothing', (tester) async {
      await pumpBox(tester, enabled: true);
      await press(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pump();
      expect(find.text('Your chrome window'), findsNothing);
      expect(store.written, isEmpty);
      await send(tester);
      expect(rig.launches, isEmpty);
      expect(ask.exchanges, isEmpty);
    });

    testWidgets('a failed capture shows Mochi\'s note and no card', (tester) async {
      await pumpBox(tester, enabled: true);
      capturer.grabs[_chrome] = const ScreenGrab.failed(ScreenFailure.minimised);
      await press(tester);
      expect(find.textContaining("Mochi couldn't see that window (it is minimised)"), findsOneWidget);
      expect(find.text('Your chrome window'), findsNothing);
      expect(store.written, isEmpty);
    });

    testWidgets('Send on the card sends the picture: written under a random name, handed over for Read, named in the prompt', (tester) async {
      await pumpBox(tester, enabled: true);
      await press(tester);
      await tester.enterText(find.byType(TextField).first, 'what am I looking at?');
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Send'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      await tester.runAsync(rig.settle);
      final path = store.written.single;
      expect(rig.process.requests.single, contains('[Request] what am I looking at?'));
      expect(rig.process.requests.single, contains('picture of their chrome window: "$path". Read it with the Read tool'));
      expect(find.text('Your chrome window'), findsNothing, reason: 'sent: the card is gone');
      expect(find.text('what am I looking at?  ·  with a picture of your window'), findsOneWidget);
      rig.process.print(FakeBrainProcess.init());
      expect((await tester.runAsync(() => rig.approveTool('Read', {'file_path': path})))!['behavior'], 'allow');
      expect((await tester.runAsync(() => rig.approveTool('Read', {'file_path': '$path.lnk'})))!['behavior'], 'deny');
      expect((await tester.runAsync(() => rig.approveTool('Read', {'file_path': r'C:\Windows\win.ini'})))!['behavior'], 'deny');
      expect(store.files, {path}, reason: 'still there while the request runs');
      rig.process.print(FakeBrainProcess.result('A browser.'));
      await tester.runAsync(rig.settle);
      expect(store.files, isEmpty, reason: 'deleted when the request ended');
      expect(store.deleted, [path]);
      expect(rig.logs.join('\n'), contains('screen shown'));
      expect(rig.logs.join('\n'), isNot(contains('mochi-screen')));
    });

    testWidgets('Send with no question asks "What\'s on my screen?"', (tester) async {
      await pumpBox(tester, enabled: true);
      await press(tester);
      await send(tester);
      await tester.runAsync(rig.settle);
      expect(rig.process.requests.single, contains("[Request] What's on my screen?"));
    });
  });

  group('the picture is deleted however the request ends', () {
    late BrainRig rig;
    late FakeScreenshots store;
    late AskMochi ask;

    setUp(() {
      rig = BrainRig();
      addTearDown(rig.brain.dispose);
      store = FakeScreenshots();
      ask = AskMochi(sessions: rig.sessions, runner: () => null, cue: (_) {}, brainFactory: (self) => rig.brain, screenshots: store);
    });

    Future<Future<AskOutcome>> sendPicture([String text = 'look']) async {
      final outcome = ask.ask(text, extras: AskExtras(screen: ScreenPreview(png: FakeCapturer.png, app: 'chrome')));
      await rig.settle();
      expect(store.files, hasLength(1), reason: 'written on Send');
      rig.process.print(FakeBrainProcess.init());
      return outcome;
    }

    test('finished', () async {
      final outcome = await sendPicture();
      rig.process.print(FakeBrainProcess.result('Fine.'));
      expect((await outcome).ok, isTrue);
      expect(store.files, isEmpty);
    });

    test('failed (an error result)', () async {
      final outcome = await sendPicture();
      rig.process.print(FakeBrainProcess.result('bad', error: true));
      expect((await outcome).ok, isFalse);
      expect(store.files, isEmpty);
    });

    test('the helper stopping', () async {
      final outcome = await sendPicture();
      rig.process.exit(2);
      expect((await outcome).ok, isFalse);
      expect(store.files, isEmpty);
    });

    test('cancelled', () async {
      final outcome = await sendPicture();
      ask.cancel();
      expect((await outcome).text, 'Okay, I stopped.');
      expect(store.files, isEmpty);
    });

    test('timed out', () async {
      final outcome = await sendPicture();
      rig.clock.fire(const Duration(seconds: 120));
      expect((await outcome).text, contains('too long'));
      expect(store.files, isEmpty);
    });

    test('a newer request takes over', () async {
      final first = await sendPicture();
      final second = ask.ask('and now?');
      expect((await first).text, contains('newer request'));
      expect(store.files, isEmpty);
      await rig.settle();
      rig.process.print(FakeBrainProcess.init());
      rig.process.print(FakeBrainProcess.result('Ok.'));
      await second;
    });

    test('the app quitting deletes it at once, before the request\'s own ending runs', () async {
      final outcome = await sendPicture();
      ask.shutdown();
      expect(store.files, isEmpty, reason: 'synchronously');
      await outcome;
    });

    test('the helper never starting: written nowhere (the one-off path can not read a picture)', () async {
      final broken = BrainRig(spawnFails: true);
      addTearDown(broken.brain.dispose);
      final ask = AskMochi(sessions: broken.sessions, runner: () => null, cue: (_) {}, brainFactory: (self) => broken.brain, screenshots: store);
      final outcome = await ask.ask('look', extras: AskExtras(screen: ScreenPreview(png: FakeCapturer.png, app: 'chrome')));
      expect(outcome.ok, isFalse);
      expect(outcome.text, contains('nothing was sent'));
      expect(store.files, isEmpty);
    });

    test('no brain at all: no picture is written', () async {
      final claude = FakeClaude(output: FakeClaude.result('x'));
      final plain = AskMochi(sessions: rig.sessions, runner: () => claude, cue: (_) {}, screenshots: store);
      final outcome = await plain.ask('look', extras: AskExtras(screen: ScreenPreview(png: FakeCapturer.png, app: 'chrome')));
      expect(outcome.ok, isFalse);
      expect(store.written, isEmpty);
      expect(claude.runs, isEmpty);
    });

    test('a picture that can not be saved is not sent', () async {
      store.failWrites = true;
      final outcome = await ask.ask('look', extras: AskExtras(screen: ScreenPreview(png: FakeCapturer.png, app: 'chrome')));
      expect(outcome.ok, isFalse);
      expect(outcome.text, contains("didn't send anything"));
      expect(rig.processes, isEmpty, reason: 'no helper was asked');
    });

    test('a file and a picture together: both are on the hand-over list, and only they', () async {
      final answer = ask.ask(
        'both',
        extras: AskExtras(files: [AttachedFile(path: r'C:\d\a.txt', name: 'a.txt', size: 1)], screen: ScreenPreview(png: FakeCapturer.png, app: 'chrome')),
      );
      await rig.settle();
      rig.process.print(FakeBrainProcess.init());
      final path = store.written.single;
      expect((await rig.approveTool('Read', {'file_path': r'C:\d\a.txt'}))['behavior'], 'allow');
      expect((await rig.approveTool('Read', {'file_path': path}))['behavior'], 'allow');
      expect((await rig.approveTool('Read', {'file_path': r'C:\d\b.txt'}))['behavior'], 'deny');
      rig.process.print(FakeBrainProcess.result('Ok.'));
      await answer;
      expect(store.files, isEmpty);
    });
  });

  group('startup and the app', () {
    late FakeForegroundWindows windows;
    late FakeDrops drops;
    late TestDesktop t;
    setUp(() {
      windows = FakeForegroundWindows(const ForegroundWindow(_notepad, ForegroundKind.app));
      drops = FakeDrops();
      t = TestDesktop.make(clock: () => _noon, foregroundWindows: windows, drops: drops);
    });
    tearDown(() => t.dispose());

    test('leftover pictures are swept once at startup', () {
      final store = FakeScreenshots()..files.add(r'C:\Assistant\mochi-screen-0.png');
      final own = TestDesktop.make(screenshots: store);
      addTearDown(own.dispose);
      expect(store.sweeps, 1);
      expect(store.files, isEmpty);
    });

    testWidgets('Mochi\'s window coming up from the pet notes the window you were in; it is not read again while it stays up', (tester) async {
      tester.view.physicalSize = SurfaceSizes.main;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(t.desktop.start);
      await tester.pumpWidget(DesktopApp(desktop: t.desktop, shell: FakeShell(), library: Future<PoseLibrary?>.value()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(windows.reads, 0, reason: 'nothing at startup, nothing on a timer');
      final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
      state.openAsk();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 800));
      expect(state.surface, Surface.main);
      expect(t.desktop.foreground.hwnd, _notepad);
      expect(windows.reads, 1);
      // Mochi's own window has the focus now; asking again, or going to Settings, doesn't look again.
      windows.window = const ForegroundWindow(0x77, ForegroundKind.ours);
      state.openAsk();
      state.open(MainPage.settings);
      await tester.pump(const Duration(milliseconds: 300));
      expect(windows.reads, 1);
      expect(t.desktop.foreground.hwnd, _notepad);
    });

    testWidgets('something dropped on the pet opens Ask Mochi with it waiting; nothing is sent', (tester) async {
      tester.view.physicalSize = SurfaceSizes.main;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(t.desktop.start);
      await tester.pumpWidget(DesktopApp(desktop: t.desktop, shell: FakeShell(), library: Future<PoseLibrary?>.value()));
      await tester.pump(const Duration(milliseconds: 100));
      final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
      expect(state.surface, isNot(Surface.main));
      drops.drop(const DropPayload(text: 'dropped on the taskbar'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 800));
      expect(state.surface, Surface.main);
      expect(find.text('dropped on the taskbar'), findsOneWidget);
      expect(find.text('What you dropped · 22 characters'), findsOneWidget);
      expect(t.claude.runs, isEmpty);
      expect(t.desktop.ask.exchanges, isEmpty);
    });
  });
}
