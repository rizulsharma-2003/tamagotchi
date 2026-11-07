// Every screen in light and dark, at 1× and 2× text, at the window's real size: no overflow, the spoken names are
// there, and the keyboard works. (The test font is wider than Nunito, so this errs on the safe side.)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

void main() {
  late TestDesktop t;
  late FakeShell shell;

  Future<void> show(WidgetTester tester, {required Surface surface, MainPage page = MainPage.home, double textScale = 1}) async {
    final size = switch ((surface, page)) {
      (Surface.pet, _) => SurfaceSizes.pet,
      (_, MainPage.settings) => SurfaceSizes.settings,
      _ => SurfaceSizes.main,
    };
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      DesktopApp(desktop: t.desktop, shell: shell, initialSurface: surface, initialPage: page, library: Future<PoseLibrary?>.value()),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  void someSessions() {
    final now = DateTime.now();
    final sessions = t.desktop.sessions;
    sessions
      ..apply(hook('UserPromptSubmit', session: 'a', project: 'web', at: now))
      ..apply(hook('PreToolUse', session: 'a', project: 'web', tool: 'Bash', toolUseId: 'b', at: now))
      ..apply(hook('Notification', session: 'b', project: 'api-server-with-a-long-name', notificationType: 'permission_prompt', at: now))
      ..apply(hook('Stop', session: 'c', project: 'mobile', at: now));
  }

  setUp(() {
    t = TestDesktop.make(saved: hostCredentials);
    shell = FakeShell();
  });

  tearDown(() => t.dispose());

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    for (final scale in [1.0, 2.0]) {
      final variant = '${theme.name}, ${scale.toStringAsFixed(0)}× text';

      testWidgets('home ($variant)', (tester) async {
        t.desktop.settings.themeMode = theme;
        someSessions();
        await show(tester, surface: Surface.main, textScale: scale);
        expect(tester.takeException(), isNull);
        expect(find.text('Connect Claude Code'), findsWidgets);
        await tester.scrollUntilVisible(find.text('Claude sessions'), 200, scrollable: find.byType(Scrollable).first);
        await tester.scrollUntilVisible(find.textContaining('mobile'), 200, scrollable: find.byType(Scrollable).first);
        expect(find.bySemanticsLabel(RegExp(r'^web\. Working\. Running Bash')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(r'Needs you\. Waiting for your permission')), findsOneWidget);
        expect(find.byTooltip('Settings'), findsOneWidget);
        expect(find.byTooltip('Pair a phone'), findsOneWidget);
        expect(find.byTooltip('Close (Mochi stays on your desktop)'), findsOneWidget);
        await tester.scrollUntilVisible(find.byType(TextField), 200, scrollable: find.byType(Scrollable).first);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        expect(Theme.of(tester.element(find.byType(TextField))).brightness, theme == ThemeMode.dark ? Brightness.dark : Brightness.light);
      });

      testWidgets('pairing with a code and devices ($variant)', (tester) async {
        t.desktop.settings.themeMode = theme;
        await tester.runAsync(() async {
          await t.desktop.link.start();
          await t.desktop.link.showCode();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          t.socket.sync(
            devices: [
              {'id': 'dev_pc', 'role': 'host', 'platform': 'windows', 'name': 'TEST-PC', 'online': true},
              {'id': 'dev_phone', 'role': 'pocket', 'platform': 'ios', 'name': "Rizul's iPhone", 'app': '1.4', 'online': true},
              {'id': 'dev_droid', 'role': 'pocket', 'platform': 'android', 'name': 'Pixel 8', 'online': false, 'lastSeen': 1762300000},
            ],
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await show(tester, surface: Surface.main, page: MainPage.pairing, textScale: scale);
        expect(tester.takeException(), isNull);
        expect(find.bySemanticsLabel('Pairing QR code'), findsOneWidget);
        expect(find.text('Copy Link'), findsOneWidget);
        expect(find.textContaining('tap Scan the Code'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Unpair This PC…'), 200, scrollable: find.byType(Scrollable).first);
        expect(find.text("Rizul's iPhone · iOS"), findsOneWidget);
        expect(find.text('Pixel 8 · Android'), findsOneWidget);
        expect(find.text('Send a Test to All Phones'), findsOneWidget);
        expect(find.text('Online'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the desktop pet ($variant)', (tester) async {
        t.desktop.settings.themeMode = theme;
        t.desktop.sessions.apply(hook('Notification', project: 'web', notificationType: 'permission_prompt'));
        await show(tester, surface: Surface.pet, textScale: scale);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        expect(find.text('Claude needs you in web'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(r'^Mochi\. Claude needs you\.')), findsOneWidget);
      });
    }
  }

  testWidgets('keyboard: Escape goes back and then closes to the pet; Ctrl+, opens Settings', (tester) async {
    await show(tester, surface: Surface.main, page: MainPage.pairing);
    final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state.page, MainPage.home);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(state.page, MainPage.settings);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state.surface, Surface.pet);
    expect(shell.shown.last, Surface.pet);
  });

  testWidgets('Tab moves the keyboard focus through the controls, and pages open at the top', (tester) async {
    someSessions();
    await show(tester, surface: Surface.main, page: MainPage.settings);
    expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, 0);
    final focused = <FocusNode>{};
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final node = FocusManager.instance.primaryFocus;
      if (node != null) focused.add(node);
    }
    expect(focused.length, greaterThanOrEqualTo(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tray menu and the window: Show, Pair, Settings, close back to the pet, Quit', (tester) async {
    await show(tester, surface: Surface.pet);
    final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
    shell.controller.add(ShellAction.pair);
    await tester.pump();
    expect((state.surface, state.page), (Surface.main, MainPage.pairing));
    shell.controller.add(ShellAction.settings);
    await tester.pump();
    expect(state.page, MainPage.settings);
    shell.controller.add(ShellAction.closeWindow);
    await tester.pump();
    expect(state.surface, Surface.pet);
    t.desktop.settings.showPet = false;
    await tester.pump();
    expect(state.surface, Surface.hidden);
    shell.controller.add(ShellAction.showMain);
    await tester.pump();
    expect((state.surface, state.page), (Surface.main, MainPage.home));
    await tester.tap(find.byTooltip('Close (Mochi stays on your desktop)'));
    await tester.pump();
    expect(state.surface, Surface.hidden, reason: 'the pet is turned off');
    expect(shell.shown, containsAllInOrder([Surface.pet, Surface.main, Surface.pet, Surface.hidden, Surface.main, Surface.hidden]));
  });
}
