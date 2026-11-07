// What you see of updates and "Install Mochi": Settings › About › Updates in each state (light and dark, 1× and 2×
// text, no overflow), its buttons and switch, the tray's "Restart to Update", the offer to install in Mochi's window,
// the uninstall steps for how Mochi runs, and Mochi's speech bubble.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/screens/home_screen.dart';
import 'package:mochi_desktop/src/ui/screens/settings_screen.dart';
import 'package:mochi_desktop/src/ui/settings/panes_app.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_desktop/src/update/self_install.dart';
import 'package:mochi_desktop/src/update/update_feed.dart';
import 'package:mochi_desktop/src/update/updater.dart';

import 'support/fakes.dart';
import 'support/update_fakes.dart';

void main() {
  late UpdateRig rig;
  late TestDesktop t;
  late FakeShell shell;
  late FakeInstallSystem system;
  late String downloads;

  setUpAll(loadReleaseKey);

  void build({required bool installed}) {
    system = FakeInstallSystem();
    final exe = installed ? rig.layout.exe : '$downloads${sep}Mochi.exe';
    final installer = SelfInstaller(
      layout: rig.layout,
      executable: exe,
      version: '0.1.0',
      system: system,
      processes: rig.processes,
      processId: () => 4242,
      copyInBackground: false,
    );
    t = TestDesktop.make(
      saved: hostCredentials,
      startup: FakeStartup(),
      updater: rig.updater(installed: installed),
      installer: installer,
    );
    t.desktop.settings.autoUpdate = rig.autoDownload;
    t.desktop.updater.start();
  }

  /// A desktop whose copy runs from the install folder ([installed]) or from Downloads. Its timers (the 6-hourly
  /// check, the motion setting's poll) run on the real event loop, not the widget test's fake one (which must end with
  /// none pending).
  void make({bool installed = true}) => Zone.root.run(() => build(installed: installed));

  setUp(() {
    rig = UpdateRig();
    downloads = '${rig.temp.path}${sep}Downloads${sep}Mochi';
    appFolder(downloads, '0.1.0');
    shell = FakeShell();
  });

  tearDown(() async {
    await t.dispose();
    rig.dispose();
  });

  Future<DesktopAppState> open(
    WidgetTester tester, {
    MainPage page = MainPage.settings,
    Surface surface = Surface.main,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = page == MainPage.settings ? SurfaceSizes.settings : SurfaceSizes.main;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      DesktopApp(
        desktop: t.desktop,
        shell: shell,
        initialSurface: surface,
        initialPage: page,
        initialPane: SettingsTab.about,
        library: Future<PoseLibrary?>.value(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return tester.state<DesktopAppState>(find.byType(DesktopApp));
  }

  Future<void> check(WidgetTester tester) => tester.runAsync(() => t.desktop.updater.check());

  Finder inUpdates(Finder finder) => find.descendant(of: find.byType(UpdatesGroup), matching: finder);

  group('Settings › About › Updates', () {
    for (final theme in [ThemeMode.light, ThemeMode.dark]) {
      for (final scale in [1.0, 2.0]) {
        final variant = '${theme.name}, ${scale.toStringAsFixed(0)}× text';

        testWidgets('up to date ($variant)', (tester) async {
          rig.feed.publish(await tester.runAsync(() => Release.make(version: '0.1.0', build: 1)) as Release);
          make();
          t.desktop.settings.themeMode = theme;
          await check(tester);
          await open(tester, textScale: scale);
          expect(tester.takeException(), isNull);
          expect(inUpdates(find.text('0.1.0 (build 1)')), findsOneWidget);
          expect(inUpdates(find.text('Mochi is up to date')), findsOneWidget);
          expect(inUpdates(find.textContaining('Checked')), findsOneWidget);
          expect(inUpdates(find.text('Download updates automatically')), findsOneWidget);
          expect(inUpdates(find.text('Check for Updates')), findsOneWidget);
          expect(inUpdates(find.text(rig.layout.installDirectory)), findsOneWidget);
        });

        testWidgets('ready, with what’s new ($variant)', (tester) async {
          rig.feed.publish(await tester.runAsync(Release.make) as Release);
          make();
          t.desktop.settings.themeMode = theme;
          await check(tester);
          await open(tester, textScale: scale);
          expect(tester.takeException(), isNull);
          expect(inUpdates(find.text('Mochi 0.2.0 is ready: restart to update')), findsOneWidget);
          expect(inUpdates(find.textContaining('Mochi keeps itself up to date.')), findsOneWidget);
          expect(inUpdates(find.text('Restart to Update')), findsOneWidget);
        });

        testWidgets('couldn’t verify ($variant)', (tester) async {
          rig.feed.publish(await tester.runAsync(() => Release.make(seed: otherSeed)) as Release);
          make();
          t.desktop.settings.themeMode = theme;
          await check(tester);
          await open(tester, textScale: scale);
          expect(tester.takeException(), isNull);
          expect(inUpdates(find.text('Couldn’t verify the update')), findsOneWidget);
          expect(inUpdates(find.text('Restart to Update')), findsNothing);
        });

        testWidgets('not installed: updates are off, and Install Mochi is there ($variant)', (tester) async {
          make(installed: false);
          t.desktop.settings.themeMode = theme;
          await open(tester, textScale: scale);
          expect(tester.takeException(), isNull);
          expect(inUpdates(find.text('Updates are off')), findsOneWidget);
          expect(inUpdates(find.textContaining('so it can’t update itself')), findsOneWidget);
          expect(inUpdates(find.text('Install Mochi')), findsOneWidget);
          expect(inUpdates(find.text('Download updates automatically')), findsNothing);
          expect(inUpdates(find.text('Check for Updates')), findsNothing);
        });
      }
    }

    testWidgets('offline says so', (tester) async {
      rig.feed.manifestError = const UpdateFeedException("Couldn't reach your Mochi Link relay.", offline: true);
      make();
      await check(tester);
      await open(tester);
      expect(inUpdates(find.text('Couldn’t check for updates: offline')), findsOneWidget);
      expect(inUpdates(find.text("Couldn't reach your Mochi Link relay.")), findsOneWidget);
    });

    testWidgets('downloading shows how far it got', (tester) async {
      final release = await tester.runAsync(Release.make) as Release;
      rig.feed
        ..publish(release)
        ..hold = Completer<void>();
      make();
      await tester.runAsync(() async {
        unawaited(t.desktop.updater.check());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await open(tester);
      expect(t.desktop.updater.phase, UpdatePhase.downloading);
      expect(inUpdates(find.text('Downloading Mochi 0.2.0…')), findsOneWidget);
      expect(inUpdates(find.text('50%')), findsOneWidget);
      expect(inUpdates(find.byType(LinearProgressIndicator)), findsOneWidget);
      final checkButton = tester.widget<OutlinedButton>(inUpdates(find.widgetWithText(OutlinedButton, 'Check for Updates')));
      expect(checkButton.onPressed, isNull, reason: 'one thing at a time');
      await tester.runAsync(() async {
        rig.feed.hold!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(t.desktop.updater.phase, UpdatePhase.ready);
    });

    testWidgets('Check for Updates asks the relay; the switch is saved', (tester) async {
      make();
      await open(tester);
      final button = inUpdates(find.text('Check for Updates'));
      await tester.ensureVisible(button);
      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(rig.feed.manifests, 1);
      expect(inUpdates(find.text('Mochi is up to date')), findsOneWidget);

      final row = find.ancestor(of: find.text('Download updates automatically'), matching: find.byType(ToggleRow));
      await tester.ensureVisible(row);
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pump();
      expect(t.desktop.settings.autoUpdate, isFalse);
      expect(t.document.json!['autoUpdate'], isFalse);
    });

    testWidgets('automatic downloads off: Download Update', (tester) async {
      rig
        ..autoDownload = false
        ..feed.publish(await tester.runAsync(Release.make) as Release);
      make();
      await check(tester);
      await open(tester);
      expect(inUpdates(find.text('Mochi 0.2.0 is available')), findsOneWidget);
      final button = inUpdates(find.text('Download Update'));
      await tester.ensureVisible(button);
      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(t.desktop.updater.phase, UpdatePhase.ready);
    });
  });

  group('Restart to Update', () {
    testWidgets('appears in the tray once an update is ready, and hands over to the helper', (tester) async {
      rig.feed.publish(await tester.runAsync(Release.make) as Release);
      make();
      await open(tester);
      expect(shell.trayUpdate, isEmpty, reason: 'nothing to restart for yet');
      await check(tester);
      await tester.pump();
      expect(shell.trayUpdate, [true]);
      final labels = NativeShell.trayItems(roaming: true, updateReady: true).map((item) => item.label).toList();
      expect(labels.first, 'Restart to Update');
      expect(NativeShell.trayItems(roaming: true).map((item) => item.label), isNot(contains('Restart to Update')));

      final button = inUpdates(find.text('Restart to Update'));
      await tester.ensureVisible(button);
      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(rig.processes.launched.map((launch) => launch.arguments.first), ['warm', 'update']);
      expect(rig.processes.launched.last.arguments.take(2), ['update', '--staged']);
      expect(shell.quit_, isTrue, reason: 'Mochi quits so the helper can swap it');
    });

    testWidgets('from the tray', (tester) async {
      rig.feed.publish(await tester.runAsync(Release.make) as Release);
      make();
      await check(tester);
      await open(tester, page: MainPage.home);
      await tester.runAsync(() async {
        shell.controller.add(ShellAction.restartToUpdate);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(rig.processes.launched.last.arguments.first, 'update');
      expect(shell.quit_, isTrue);
    });

    testWidgets('Mochi says so in a speech bubble', (tester) async {
      make();
      tester.view.physicalSize = SurfaceSizes.pet;
      await open(tester, surface: Surface.pet, page: MainPage.home);
      tester.view.physicalSize = SurfaceSizes.pet;
      t.desktop.cue(PetCue.updateReady);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('A new Mochi is ready: restart to update'), findsOneWidget);
      await tester.pump(const Duration(seconds: 13));
      expect(find.text('A new Mochi is ready: restart to update'), findsNothing, reason: 'it never stays in the way');
    });
  });

  group('Install Mochi', () {
    testWidgets('Mochi’s window offers it when Mochi runs from Downloads; Not Now stops asking', (tester) async {
      make(installed: false);
      await open(tester, page: MainPage.home);
      expect(find.byType(InstallCard), findsOneWidget);
      expect(find.textContaining('Mochi is running from $downloads'), findsOneWidget);
      await tester.tap(find.text('Not Now'));
      await tester.pump();
      expect(find.byType(InstallCard), findsNothing);
      expect(t.desktop.settings.installDeclined, isTrue);
      expect(t.document.json!['installDeclined'], isTrue);
    });

    testWidgets('not offered to the installed copy', (tester) async {
      make();
      await open(tester, page: MainPage.home);
      expect(find.byType(InstallCard), findsNothing);
    });

    testWidgets('installs, registers, starts the installed copy and quits', (tester) async {
      make(installed: false);
      await open(tester, page: MainPage.home);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Install Mochi'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(read(rig.layout.exe), 'Mochi 0.1.0');
      expect(system.shortcuts.single.appUserModelId, 'InsideEdge.Mochi');
      expect(system.keys[rig.layout.uninstallKey]!['DisplayVersion'], '0.1.0');
      expect(rig.processes.launched.single.arguments.first, 'launch');
      expect(shell.quit_, isTrue);
    });

    testWidgets('a failed install says why and keeps running', (tester) async {
      make(installed: false);
      File('$downloads${sep}Mochi.exe').deleteSync();
      await open(tester, page: MainPage.home);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Install Mochi'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(find.textContaining('incomplete'), findsOneWidget);
      expect(shell.quit_, isFalse);
    });
  });

  group('Uninstall steps match how Mochi runs', () {
    test('installed: Windows Settings › Apps does the rest', () {
      make();
      final steps = uninstallSteps(t.desktop);
      expect(steps, contains('Windows Settings › Apps › Installed apps'));
      expect(steps, contains('Start-menu shortcut and its startup entry'));
      expect(steps, isNot(contains('Start Mochi with Windows')));
      expect(steps, contains(t.desktop.paths.home));
    });

    test('from a folder: switch off startup, quit, delete the folder', () {
      make(installed: false);
      final steps = uninstallSteps(t.desktop);
      expect(steps, contains('switch off Start Mochi with Windows'));
      expect(steps, contains('delete its folder ($downloads)'));
      expect(steps, isNot(contains('Installed apps')));
    });

    testWidgets('and About shows them', (tester) async {
      make();
      await open(tester);
      final steps = find.descendant(of: find.byType(SettingsScreen), matching: find.textContaining('Installed apps', findRichText: true));
      expect(steps, findsOneWidget);
    });
  });
}
