// Mochi grows up (docs/SPRINT_2.md W12) and Progress (W13) on Windows: the stage from the friendship, announced once
// per stage (the Mac's GrowthController), drawn everywhere; the hearts in the popover, and Settings › Characters ›
// Friendship with every achievement and Reset Progress; what's earned unlocks more to wear.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_world.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

/// A saved world whose friendship is [points] strong, over [days] days, met [weeks] weeks before [now].
MemoryWorldStore saved({required DateTime now, int points = 0, int days = 0, int weeks = 0, Map<String, DateTime> unlocked = const {}}) =>
    MemoryWorldStore({
      'v': 1,
      'seed': 7,
      'world': {
        'v': 1,
        'progress': {
          'affectionPoints': points,
          'interactionDays': [for (var i = 0; i < days; i++) '2026-10-${(i + 1).toString().padLeft(2, '0')}'],
          'firstMetAt': now.subtract(Duration(days: 7 * weeks)).toUtc().toIso8601String(),
          'unlocked': {for (final e in unlocked.entries) e.key: e.value.toUtc().toIso8601String()},
        },
        'history': <Object?>[],
      },
    });

void main() {
  group('Growing up', () {
    late DateTime now;
    late double seconds;

    void later(TestDesktop t, Duration by) {
      final steps = (by.inMilliseconds / 250).ceil();
      for (var i = 0; i < steps; i++) {
        now = now.add(const Duration(milliseconds: 250));
        seconds += 0.25;
        t.desktop.world.tick();
      }
    }

    setUp(() {
      now = DateTime(2026, 11, 8, 12);
      seconds = 1000;
    });

    test('the first look introduces the kitten (once), as the Mac does', () {
      final t = TestDesktop.make(clock: () => now, uptime: () => seconds);
      addTearDown(t.dispose);
      expect(t.desktop.world.stage, LifeStage.kitten);
      expect(PetRenderer.stage, LifeStage.kitten, reason: 'drawn as a kitten everywhere');
      later(t, const Duration(minutes: 1, seconds: 1));
      expect(t.desktop.world.toastNow.value?.title, 'Meet kitten Mochi!');
      expect(t.desktop.settings.lifeStageSeen, 0);
      expect(t.document.json!['lifeStageSeen'], 0, reason: 'the Mac’s key');
      later(t, const Duration(minutes: 3));
      expect(t.desktop.world.toastNow.value, isNull, reason: 'said once');
    });

    test('a stage reached later is celebrated: a note, a victory and a line; never again for that stage', () {
      final t = TestDesktop.make(
        clock: () => now,
        uptime: () => seconds,
        settings: {'lifeStageSeen': 0, 'petName': 'Biscuit'},
        worldStore: saved(now: now, points: 35, days: 4),
      );
      addTearDown(t.dispose);
      expect(t.desktop.world.stage, LifeStage.young);
      later(t, const Duration(minutes: 1, seconds: 1));
      expect(t.desktop.world.toastNow.value?.title, 'Biscuit grew up!');
      expect(t.desktop.world.world.pet.current.animation, PetAnimation.victory);
      expect(t.desktop.world.speechNow.value?.text, 'Look how big I am!');
      expect(t.desktop.settings.lifeStageSeen, 1);
      later(t, const Duration(minutes: 2));
      expect(t.desktop.world.toastNow.value, isNull);
    });

    test('"grows up" off: drawn grown up, nothing announced; on again: the stage it has reached', () {
      final t = TestDesktop.make(clock: () => now, uptime: () => seconds, settings: {'lifeStages': false});
      addTearDown(t.dispose);
      expect(t.desktop.world.stage, LifeStage.grownUp);
      later(t, const Duration(minutes: 2));
      expect(t.desktop.world.toastNow.value, isNull);
      t.desktop.settings.lifeStages = true;
      expect(t.desktop.world.stage, LifeStage.kitten);
      expect(t.desktop.world.world.settings.lifeStages, isTrue);
    });
  });

  group('Progress', () {
    late TestDesktop t;
    final now = DateTime(2026, 11, 8, 12);

    setUp(() {
      t = TestDesktop.make(
        saved: hostCredentials,
        clock: () => now,
        worldStore: saved(
          now: now,
          points: 42,
          days: 5,
          unlocked: {'firstSession': DateTime(2026, 11, 2, 9), 'firstTurn': DateTime(2026, 11, 3, 10)},
        ),
      );
    });
    tearDown(() => t.dispose());

    Future<DesktopAppState> open(WidgetTester tester, {required ThemeMode theme, required double scale, SettingsTab pane = SettingsTab.characters}) async {
      t.desktop.settings.themeMode = theme;
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: pane,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      return tester.state<DesktopAppState>(find.byType(DesktopApp));
    }

    for (final theme in [ThemeMode.light, ThemeMode.dark]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('Settings › Characters › Friendship: hearts, points and every achievement (${theme.name}, ${scale.toStringAsFixed(0)}× text)', (
          tester,
        ) async {
          await open(tester, theme: theme, scale: scale);
          expect(find.text('Friendship'), findsOneWidget);
          expect(find.text('42 points'), findsOneWidget);
          expect(find.bySemanticsLabel(RegExp('Friendship level.*level 2 of 5.*42 points', dotAll: true)), findsOneWidget);
          for (final id in w.AchievementID.values) {
            expect(find.text(id.title), findsOneWidget, reason: id.name);
          }
          expect(find.text('2 November 2026'), findsOneWidget, reason: 'when “Hello, Patch” was earned');
          expect(find.bySemanticsLabel(RegExp(r'Hello, Patch.*Earned on 2 November 2026', dotAll: true)), findsOneWidget);
          expect(find.bySemanticsLabel(RegExp(r'Green Light.*Not earned yet', dotAll: true)), findsOneWidget);
          expect(find.textContaining('Unlocks: Tiny Trophy.'), findsOneWidget);
          expect(find.text('Friendship and achievements'), findsNothing, reason: 'no “Not on Windows yet” row any more');
          final content = find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Column)).first;
          await tester.drag(content, const Offset(0, -4000));
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('Reset Progress asks first, then the hearts and achievements start again (by keyboard)', (tester) async {
      await open(tester, theme: ThemeMode.light, scale: 1);
      final reset = find.widgetWithText(OutlinedButton, 'Reset Progress…');
      await tester.ensureVisible(reset);
      await tester.pump();
      Focus.of(tester.element(find.text('Reset Progress…'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Reset friendship and achievements?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(t.desktop.world.world.progress.affectionPoints, 42);
      await tester.tap(reset);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Reset').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(t.desktop.world.world.progress.affectionPoints, 0);
      expect(t.desktop.world.world.progress.unlockedIDs, isEmpty);
      expect(find.text('0 points'), findsOneWidget);
    });

    testWidgets('what isn’t earned yet says how to get it and can’t be chosen; Notifications has the achievements row', (tester) async {
      await open(tester, theme: ThemeMode.light, scale: 1);
      final wears = find.ancestor(of: find.text('Mochi wears'), matching: find.byType(MenuRow<Accessory?>));
      final menu = tester.widget<MenuRow<Accessory?>>(wears);
      expect(menu.locked, contains(Accessory.graduationCap), reason: 'Milestone Maker isn’t earned');
      expect(menu.locked, isNot(contains(Accessory.partyHat)), reason: 'First Finish is');
      expect(menu.items, contains((Accessory.graduationCap, 'Graduation Cap — Unlock: Milestone Maker')));
      expect(menu.items, contains((Accessory.santaHat, 'Festive Hat — Seasonal (December)')));

      final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
      state.settingsNavigation.tab = SettingsTab.notifications;
      await tester.pump(const Duration(milliseconds: 300));
      final achievements = find.text('Achievements');
      await tester.ensureVisible(achievements.first);
      await tester.pump();
      // Achievements is the last category: its Animate box can be changed now.
      final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(boxes, hasLength(4 * 9));
      expect(boxes[4 * 8].onChanged, isNotNull);
      expect(find.text('Not on Windows yet'), findsNothing, reason: 'every category works on Windows now');
    });

    testWidgets('Settings › Fun › Growing up: the switch, and where Mochi is', (tester) async {
      await open(tester, theme: ThemeMode.dark, scale: 2, pane: SettingsTab.fun);
      final growing = find.text('Mochi grows up over time');
      await tester.ensureVisible(growing);
      await tester.pump();
      expect(find.textContaining('Mochi is a young cat.'), findsOneWidget);
      expect(find.textContaining('Grows up with friendship level 4'), findsOneWidget);
      await tester.tap(find.descendant(of: find.ancestor(of: growing, matching: find.byType(ToggleRow)), matching: find.byType(Switch)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(t.desktop.settings.lifeStages, isFalse);
      expect(find.textContaining('Mochi is drawn grown up.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Settings › Privacy says what Mochi’s world keeps, and where', (tester) async {
      await open(tester, theme: ThemeMode.light, scale: 1, pane: SettingsTab.privacy);
      expect(find.text('Mochi’s world'), findsOneWidget);
      expect(find.textContaining('Claude Code’s events of the last three hours'), findsOneWidget);
      expect(find.textContaining('No history of your sessions is kept'), findsNothing);
    });

    testWidgets('the popover: five hearts, the level and the points to the next, as on the Mac', (tester) async {
      tester.view.physicalSize = SurfaceSizes.popover;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(desktop: t.desktop, shell: FakeShell(), initialSurface: Surface.pet, library: Future<PoseLibrary?>.value()),
      );
      await tester.pump(const Duration(milliseconds: 300));
      tester.state<DesktopAppState>(find.byType(DesktopApp)).openPopover();
      for (var ms = 0; ms < 800; ms += 16) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.bySemanticsLabel('Friendship level 2 of 5, 18 points to the next'), findsOneWidget);
      await tester.ensureVisible(find.text('Friendship level 2'));
      expect(find.text('18 to next'), findsOneWidget);
      t.desktop.interact('play');
      await tester.pump();
      expect(find.text('16 to next'), findsOneWidget, reason: 'it follows as you play');
      expect(tester.takeException(), isNull);
    });
  });
}
