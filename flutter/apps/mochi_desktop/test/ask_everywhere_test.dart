// Ask Mochi from everywhere (docs/SPRINT_2.md X16): the popover's button, the global shortcut, the tray menu and the Start
// menu's jump list (`Mochi.exe --ask` / `--explore`) all open Ask Mochi through one path, with the question box focused.
// The phones already work and are not touched.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/hotkeys.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart' show DesktopStyle;
import 'package:mochi_desktop/src/core/jump_list.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/screens/home_screen.dart';
import 'package:mochi_desktop/src/ui/settings/shortcut_row.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_desktop/src/update/self_install.dart';

import 'support/fakes.dart';
import 'support/update_fakes.dart';

final DateTime noon = DateTime(2026, 11, 9, 12);

bool askHasFocus() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<AskBox>() != null;

void main() {
  group('the launch argument (a second launch hands it to the running Mochi; a first launch has it in main)', () {
    test('--ask and --explore are routed; anything else is ignored', () {
      expect(LaunchRequest.parse('--ask'), ShellAction.ask);
      expect(LaunchRequest.parse('--explore'), ShellAction.explore);
      expect(LaunchRequest.parse(null), isNull, reason: 'the plain "show Mochi" has no argument');
      for (final unknown in ['--installed', '--Ask', 'ask', '', '--ask --explore', '--ask=1', 42, true]) {
        expect(LaunchRequest.parse(unknown), isNull, reason: '$unknown');
      }
    });

    test('the first recognised argument of a command line wins; unknown ones around it are skipped', () {
      expect(LaunchRequest.fromArguments(['--installed']), isNull);
      expect(LaunchRequest.fromArguments(const []), isNull);
      expect(LaunchRequest.fromArguments(['--installed', '--ask']), ShellAction.ask);
      expect(LaunchRequest.fromArguments(['--bogus', '--explore', '--ask']), ShellAction.explore);
    });

    test('a first launch holds the request until the app listens, then delivers it once', () async {
      final shell = NativeShell();
      shell.launch(ShellAction.ask);
      final first = shell.actions.first;
      expect(await first.timeout(const Duration(seconds: 1)), ShellAction.ask);
      final later = <ShellAction>[];
      final sub = shell.actions.listen(later.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(later, isEmpty, reason: 'not delivered twice');
      shell.launch(ShellAction.explore);
      await Future<void>.delayed(Duration.zero);
      expect(later, [ShellAction.explore], reason: 'while it listens, at once');
    });
  });

  group('the tray menu', () {
    test('has "Ask Mochi…", right under Show Mochi, and choosing it is the ask action', () async {
      final items = NativeShell.trayItems(style: DesktopStyle.roam);
      final labels = items.map((item) => item.label).toList();
      expect(labels, contains('Ask Mochi…'));
      expect(labels.indexOf('Ask Mochi…'), labels.indexOf('Show Mochi') + 1);
      expect(items.firstWhere((item) => item.label == 'Ask Mochi…').key, ShellAction.ask.name);
      final shell = NativeShell();
      final heard = shell.actions.first;
      shell.onTrayMenuItemClick(items.firstWhere((item) => item.label == 'Ask Mochi…'));
      expect(await heard.timeout(const Duration(seconds: 1)), ShellAction.ask);
    });
  });

  group('the shortcut (W4’s Ask Mochi row)', () {
    test('Ctrl+Alt+Space by default: free in the code, off Alt+Space (Windows’ window menu) and off Mochi’s pet shortcut', () {
      expect(MochiShortcut.ask.defaultHotkey, Hotkey.askDefault);
      expect(Hotkey.askDefault.label, 'Ctrl+Alt+Space');
      expect(HotkeyConflicts.problem(Hotkey.askDefault, shortcut: MochiShortcut.ask, other: Hotkey.petDefault), isNull);
      expect(HotkeyConflicts.reserved.containsKey(Hotkey.askDefault), isFalse);
      expect(Hotkey.askDefault, isNot(Hotkey.petDefault));
    });

    test('a combination Windows has, the app you are in has, or the pet shortcut has is refused with the reason', () {
      String? problem(Hotkey hotkey) => HotkeyConflicts.problem(hotkey, shortcut: MochiShortcut.ask, other: Hotkey.petDefault);
      expect(problem(const Hotkey(0x20, alt: true)), contains('window menu'));
      expect(problem(const Hotkey(0x20, alt: true)), contains(Hotkey.askDefault.label), reason: 'it suggests the default');
      expect(problem(const Hotkey(0x20, ctrl: true, shift: true)), contains('belongs to the app you’re in'));
      expect(problem(Hotkey.petDefault), contains('already Mochi’s shortcut for “Show or hide the desktop pet”'));
    });

    late TestDesktop t;
    setUp(() => t = TestDesktop.make(clock: () => noon));
    tearDown(() => t.dispose());

    testWidgets('pressing it opens Ask Mochi with the question box focused', (tester) async {
      tester.view.physicalSize = SurfaceSizes.main;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(t.desktop.start);
      await tester.pumpWidget(DesktopApp(desktop: t.desktop, shell: FakeShell(), library: Future<PoseLibrary?>.value()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(t.hotkeys.registered[MochiShortcut.ask.id], Hotkey.askDefault, reason: 'registered at start');
      final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
      t.hotkeys.press(MochiShortcut.ask);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 800));
      expect((state.surface, state.page), (Surface.main, MainPage.home));
      expect(askHasFocus(), isTrue);
    });

    testWidgets('Settings has the Ask Mochi row, with its combination and the way to change it', (tester) async {
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
      final row = find.byWidgetPredicate((widget) => widget is ShortcutRow && widget.shortcut == MochiShortcut.ask);
      await tester.ensureVisible(row);
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Ctrl')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Space')), findsOneWidget);
    });
  });

  group('each way in opens Ask Mochi with the focus (one shared path: openAsk)', () {
    late TestDesktop t;
    late FakeShell shell;

    setUp(() {
      t = TestDesktop.make(clock: () => noon);
      shell = FakeShell();
    });
    tearDown(() => t.dispose());

    Future<DesktopAppState> open(WidgetTester tester) async {
      tester.view.physicalSize = SurfaceSizes.main;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(t.desktop.start);
      await tester.pumpWidget(DesktopApp(desktop: t.desktop, shell: shell, library: Future<PoseLibrary?>.value()));
      await tester.pump(const Duration(milliseconds: 100));
      return tester.state<DesktopAppState>(find.byType(DesktopApp));
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 800));
    }

    testWidgets('the tray’s "Ask Mochi…" (and the jump list’s task, which arrives as the same action)', (tester) async {
      final state = await open(tester);
      expect(state.surface, Surface.pet);
      shell.controller.add(ShellAction.ask);
      await settle(tester);
      expect((state.surface, state.page), (Surface.main, MainPage.home));
      expect(tester.widget<AskBox>(find.byType(AskBox)).autofocus, isTrue);
      expect(askHasFocus(), isTrue);
    });

    testWidgets('while the window already shows: the box takes the focus again (the tray, or a second launch with --ask)', (tester) async {
      final state = await open(tester);
      shell.controller.add(ShellAction.showMain);
      await settle(tester);
      expect((state.surface, state.page), (Surface.main, MainPage.home));
      // The user clicked elsewhere in the window.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(askHasFocus(), isFalse);
      shell.controller.add(ShellAction.ask);
      await settle(tester);
      expect(askHasFocus(), isTrue);
      expect(state.surface, Surface.main);
    });

    testWidgets('from Settings, it goes to Mochi’s window and the box', (tester) async {
      final state = await open(tester);
      state.open(MainPage.settings);
      await settle(tester);
      expect(state.page, MainPage.settings);
      shell.controller.add(ShellAction.ask);
      await settle(tester);
      expect((state.surface, state.page), (Surface.main, MainPage.home));
      expect(askHasFocus(), isTrue);
    });

    testWidgets('--explore from the jump list is the tray’s Explore: Mochi sets off', (tester) async {
      final state = await open(tester);
      shell.controller.add(LaunchRequest.parse('--explore')!);
      await tester.pump(const Duration(milliseconds: 300));
      // Adventures on (the default) with nothing blocking: out, not still standing in the popover or window.
      expect(state.surface, Surface.pet);
      expect(shell.shown.where((surface) => surface == Surface.main), isEmpty, reason: 'Explore opens no window');
    });

    testWidgets('an unknown argument does nothing more than show Mochi', (tester) async {
      final state = await open(tester);
      shell.controller.add(LaunchRequest.parse('--whatever') ?? ShellAction.showMain);
      await settle(tester);
      expect((state.surface, state.page), (Surface.main, MainPage.home));
      expect(askHasFocus(), isFalse, reason: 'the window, not the question box');
    });
  });

  group('the Start-menu jump list', () {
    late UpdateRig rig;
    setUp(() => rig = UpdateRig());
    tearDown(() => rig.temp.deleteSync(recursive: true));

    SelfInstaller installer({required bool installed}) => SelfInstaller(
      layout: rig.layout,
      executable: installed ? rig.layout.exe : '${rig.temp.path}${sep}Downloads${sep}Mochi.exe',
      version: '0.2.7',
      system: FakeInstallSystem(),
    );

    test('built once for the installed copy', () async {
      final service = FakeJumpList();
      final list = StartMenuJumpList(service: service, installed: () => installer(installed: true).installed);
      await list.buildOnce();
      await list.buildOnce();
      expect(service.builds, 1, reason: 'once at startup, not again');
    });

    test('never for a copy run from Downloads or a build folder', () async {
      final service = FakeJumpList();
      final list = StartMenuJumpList(service: service, installed: () => installer(installed: false).installed);
      await list.buildOnce();
      expect(service.builds, 0);
      expect(list.asked, isFalse);
    });

    test('fails quietly: a bad HRESULT or a runner that is not there changes nothing and throws nothing', () async {
      final bad = FakeJumpList()..answer = -2147467259;
      await StartMenuJumpList(service: bad, installed: () => true).buildOnce();
      expect(bad.builds, 1);
      final gone = FakeJumpList()..throws = true;
      await StartMenuJumpList(service: gone, installed: () => true).buildOnce();
      expect(gone.builds, 1);
    });

    test('Mochi asks for it once at startup, for the installed copy only', () async {
      final installedService = FakeJumpList();
      final installedDesktop = TestDesktop.make(clock: () => noon, installer: installer(installed: true), jumpList: installedService);
      addTearDown(installedDesktop.dispose);
      await installedDesktop.desktop.start();
      await Future<void>.delayed(Duration.zero);
      expect(installedService.builds, 1);

      final otherService = FakeJumpList();
      final otherDesktop = TestDesktop.make(clock: () => noon, installer: installer(installed: false), jumpList: otherService);
      addTearDown(otherDesktop.dispose);
      await otherDesktop.desktop.start();
      await Future<void>.delayed(Duration.zero);
      expect(otherService.builds, 0);
    });

    test('the macOS development build has no jump list at all', () async {
      final plain = TestDesktop.make(clock: () => noon);
      addTearDown(plain.dispose);
      expect(plain.desktop.jumpList, isNull);
      await plain.desktop.start();
    });
  });

  test('the runner has the jump list and the argument hand-over (read, since the C++ builds on Windows only)', () {
    final main = File('windows/runner/main.cpp').readAsStringSync();
    final window = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final jump = File('windows/runner/jump_list.cpp').readAsStringSync();
    expect(main, contains('"--ask"'));
    expect(main, contains('"--explore"'));
    expect(main, contains('LaunchRequestFromArguments()'));
    expect(window, contains('"--ask"'));
    expect(window, contains('buildJumpList'));
    expect(jump, contains('L"Ask Mochi"'));
    expect(jump, contains('L"Explore"'));
    expect(jump, contains('L"InsideEdge.Mochi"'), reason: 'the AppUserModelID of the installed copy');
    expect(File('windows/runner/CMakeLists.txt').readAsStringSync(), contains('"jump_list.cpp"'));
    // Every COM call is checked: no unchecked HRESULT, nothing thrown.
    expect(jump, isNot(contains('throw')));
  });
}
