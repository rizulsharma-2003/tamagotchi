// Feel the purr on Windows (docs/SPRINT_2.md W21), the Mac's PurrSession without a Force Touch trackpad: press and
// hold Mochi (the desktop pet, the taskbar's Mochi, its room) and it keeps purring: petted at once and every 3 seconds,
// purr lines at its sides, a soft purr sound in bursts with Mochi's sounds on (Settings › Fun › Touch, the Mac's
// `hapticPurr`), never in quiet mode or while the screen can't be seen; letting go or half a minute ends it, and its
// timer with it. A click still pets; the screen reader has a Purr action.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart' show SystemActivity;
import 'package:mochi_desktop/src/core/purr.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/purr_hold.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

void main() {
  late TestDesktop t;
  final now = DateTime(2026, 11, 8, 15);

  setUp(() => t = TestDesktop.make(clock: () => now, settings: {'soundEnabled': true}));
  tearDown(() => t.dispose());

  group('The purr', () {
    testWidgets('holding on: petted at once and every 3 seconds, a purr in bursts, until you let go', (tester) async {
      final purr = t.desktop.purr;
      final points = t.desktop.world.world.progress.affectionPoints;
      purr.begin();
      expect(purr.active, isTrue);
      expect(t.desktop.world.world.pet.current.animation.name, startsWith('pet'), reason: 'petted at once');
      expect(t.desktop.world.world.progress.affectionPoints, greaterThan(points));
      expect(purr.bursts, 1);
      await tester.pump(const Duration(milliseconds: 950));
      expect(purr.bursts, 2, reason: 'a breath later, another');
      final petted = t.desktop.world.world.progress.affectionPoints;
      await tester.pump(const Duration(seconds: 3));
      expect(t.desktop.world.world.progress.affectionPoints, greaterThanOrEqualTo(petted));
      expect(t.desktop.world.world.pet.current.animation.name, startsWith('pet'), reason: 'petted again');
      purr.end();
      expect(purr.active, isFalse);
      final bursts = purr.bursts;
      await tester.pump(const Duration(seconds: 2));
      expect(purr.bursts, bursts, reason: 'nothing runs once you let go');
    });

    testWidgets('half a minute without moving ends it, as on the Mac', (tester) async {
      final purr = t.desktop.purr..begin();
      await tester.pump(const Duration(seconds: 31));
      expect(purr.active, isFalse);
    });

    testWidgets('no sound with Mochi’s sounds off, the purr sound off, in quiet mode or while the screen can’t be seen', (tester) async {
      final purr = t.desktop.purr;
      final settings = t.desktop.settings;
      for (final (name, change, undo) in [
        ('sounds off', () => settings.soundEnabled = false, () => settings.soundEnabled = true),
        ('purr off', () => settings.purrSound = false, () => settings.purrSound = true),
        ('quiet mode', () => settings.quietMode = true, () => settings.quietMode = false),
        (
          'screen off',
          () {
            t.usage.activity = const SystemActivity(idleSeconds: 0, displaysAsleep: true);
            t.desktop.rhythm.sample();
          },
          () {
            t.usage.activity = const SystemActivity(idleSeconds: 0);
            t.desktop.rhythm.sample();
          },
        ),
      ]) {
        change();
        purr.begin();
        await tester.pump(const Duration(seconds: 2));
        expect(purr.bursts, 0, reason: name);
        purr.end();
        undo();
      }
      expect((t.document.json!['hapticPurr']), isTrue, reason: 'the Mac’s key');
    });

    test('the purr lines: two at Mochi’s sides, still with animations off', () {
      final pose = w.PetPose();
      final purring = PurrSession.decorate(pose, 12.3);
      final lines = purring.effects.where((e) => e.kind == w.EffectKind.purr).toList();
      expect(lines.map((e) => (e.x, e.variant)), [(-0.62, 0), (0.62, 1)]);
      expect(pose.effects, isEmpty, reason: 'the world’s pose is left as it was');
      expect(PurrSession.decorate(pose, 12.3, calm: true).effects.map((e) => e.phase), [0, 0]);
    });

    testWidgets('the screen reader’s Purr: a few seconds of it', (tester) async {
      final purr = t.desktop.purr..pulse();
      expect(purr.active, isTrue);
      await tester.pump(const Duration(seconds: 4));
      expect(purr.active, isFalse);
    });
  });

  group('Holding Mochi', () {
    Future<DesktopAppState> app(WidgetTester tester, {Surface surface = Surface.pet, ThemeMode theme = ThemeMode.light}) async {
      t.desktop.settings.themeMode = theme;
      tester.view.physicalSize = surface == Surface.pet ? SurfaceSizes.pet : SurfaceSizes.main;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(desktop: t.desktop, shell: FakeShell(), initialSurface: surface, library: Future<PoseLibrary?>.value()),
      );
      await tester.pump(const Duration(milliseconds: 300));
      return tester.state<DesktopAppState>(find.byType(DesktopApp));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 8));
    }

    testWidgets('the desktop pet: press and hold to purr (drawn every frame meanwhile), a click still pets', (tester) async {
      final handle = tester.ensureSemantics();
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        await app(tester, theme: theme);
        final purr = t.desktop.purr;
        final mochi = find.byType(PurrHold).first;
        final gesture = await tester.startGesture(tester.getCenter(mochi));
        await tester.pump(const Duration(milliseconds: 200));
        expect(purr.active, isFalse, reason: 'not yet');
        await tester.pump(const Duration(milliseconds: 200));
        expect(purr.active, isTrue, reason: 'held for the Mac’s 0.3 s');
        final view = tester.state<MochiViewState>(find.byType(MochiView));
        await tester.pump(const Duration(milliseconds: 100));
        expect(view.fps, 24, reason: 'smooth while it purrs');
        expect(tester.takeException(), isNull);
        await gesture.up();
        expect(purr.active, isFalse);
        await tester.tap(mochi);
        await tester.pump(const Duration(milliseconds: 50));
        expect(purr.active, isFalse, reason: 'a click pets, no purr');
        expect(find.bySemanticsLabel(RegExp('^Mochi')), findsWidgets);
        final node = tester.getSemantics(find.byType(PurrHold).first);
        expect(node.getSemanticsData().customSemanticsActionIds, isNotEmpty, reason: 'the screen reader’s Purr');
        await close(tester);
      }
      handle.dispose();
    });

    testWidgets('Mochi in its room (Mochi’s window): press and hold to purr', (tester) async {
      await app(tester, surface: Surface.main);
      final purr = t.desktop.purr;
      final mochi = find.byType(PurrHold).first;
      final gesture = await tester.startGesture(tester.getCenter(mochi));
      await tester.pump(const Duration(milliseconds: 400));
      expect(purr.active, isTrue);
      await gesture.up();
      expect(purr.active, isFalse);
      await close(tester);
    });

    testWidgets('Settings › Fun › Touch: the purr’s sound, under the Mac’s `hapticPurr`', (tester) async {
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
      await tester.ensureVisible(find.text('Touch'));
      await tester.tap(find.text('Purr sound while you hold Mochi'));
      await tester.pump();
      expect(t.desktop.settings.purrSound, isFalse);
      expect(t.document.json!['hapticPurr'], isFalse);
      t.desktop.settings.soundEnabled = false;
      await tester.pump();
      expect(find.text('Turn on Play sounds (Notifications › Sound) to hear it.'), findsOneWidget, reason: 'no dead switch');
      await close(tester);
    });
  });
}
