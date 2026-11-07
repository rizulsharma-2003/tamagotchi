// Docs/SPRINT_2.md W7, the desktop pet's options as on the Mac (Settings › Desktop Pet, and the Mac's menu-bar style
// for the taskbar): where Mochi lives (roaming the taskbar, playing in its spot, the classic tray icon), the desktop
// pet's size, always on top, clicks passing through, its place on each display, the classic tray icon's frames, and
// Patch only for interesting moments. With a fake taskbar, window, displays and tray, on the test's clock.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show AttentionLevel;
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/platform/displays.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_desktop/src/ui/tray_glyph.dart';

import 'support/fakes.dart';

void main() {
  group('Settings', () {
    test('new in version 5: defaults, saved, read back, and Reset', () {
      final document = MemorySettingsDocument();
      final settings = DesktopSettings(document);
      expect(
        (settings.petStyle, settings.petSize, settings.spotRoom, settings.spotX, settings.petOnTop, settings.petClickThrough),
        (DesktopStyle.roam, PetSize.medium, PetSize.medium, null, true, false),
      );
      expect((settings.trayAnimation, settings.companionOnlyMoments, settings.petPlaces.length, settings.petDisplay), (TrayAnimation.subtle, false, 0, null));
      settings
        ..petStyle = DesktopStyle.spot
        ..spotRoom = PetSize.large
        ..spotX = 812.5
        ..petSize = PetSize.small
        ..petOnTop = false
        ..petClickThrough = true
        ..trayAnimation = TrayAnimation.full
        ..companionOnlyMoments = true
        ..placePet('A', const PetPlace(0.25, 1))
        ..placePet('B', const PetPlace(0.5, 0.5));
      expect(document.json!['v'], 5);
      final again = DesktopSettings(document);
      expect(
        (again.petStyle, again.spotRoom, again.spotX, again.petSize, again.petOnTop, again.petClickThrough, again.trayAnimation),
        (DesktopStyle.spot, PetSize.large, 812.5, PetSize.small, false, true, TrayAnimation.full),
      );
      expect((again.companionOnlyMoments, again.petDisplay), (true, 'B'));
      expect(again.petPlaces, {'A': const PetPlace(0.25, 1), 'B': const PetPlace(0.5, 0.5)});
      again.resetPetPosition();
      expect((again.petPlaces.length, again.petDisplay, again.petPosition), (0, null, null));
      again.reset();
      expect((again.petStyle, again.petSize, again.petOnTop, again.petClickThrough), (DesktopStyle.roam, PetSize.medium, true, false));
    });

    test('a damaged file loads with the defaults', () {
      final settings = DesktopSettings(
        MemorySettingsDocument({'petStyle': 'flying', 'petSize': 7, 'spotX': 'left', 'petPlaces': {'A': 'x', 'B': [2, -1]}, 'petDisplay': 4}),
      );
      expect((settings.petStyle, settings.petSize, settings.spotX, settings.petDisplay), (DesktopStyle.roam, PetSize.medium, null, null));
      expect(settings.petPlaces, {'B': const PetPlace(1, 0)}, reason: 'kept inside the display');
    });

    test('sizes: the Mac’s small, medium and large; medium is the pet’s old size', () {
      expect(SurfaceSizes.standing(PetSize.medium), SurfaceSizes.pet);
      final small = SurfaceSizes.standing(PetSize.small), large = SurfaceSizes.standing(PetSize.large);
      expect(small.height, lessThan(SurfaceSizes.pet.height));
      expect(large.height, greaterThan(SurfaceSizes.pet.height));
      expect(small.width, SurfaceSizes.pet.width, reason: 'never narrower than the bubble');
      expect(PetSize.small.stage / PetSize.medium.stage, closeTo(84 / 116, 0.01));
      expect(PetSize.large.stage / PetSize.medium.stage, closeTo(156 / 116, 0.01));
    });
  });

  group('Places on each display', () {
    const main = FakeDisplays.main1080, side = FakeDisplays.side1440;
    const size = Size(176, 200);

    test('first: bottom left of the main display, just above the taskbar', () {
      final placed = PetPlacing.frameFor([main, side], places: const {}, last: null, size: size, box: 144);
      expect(placed.display, main);
      expect(placed.frame, const PixelRect(0, 1032 - 200, 176, 1032));
    });

    test('each display keeps its own place, at its own scale; a display that’s gone puts the pet on the main one', () {
      const places = {r'\\.\DISPLAY1 1920x1080': PetPlace(1, 0), r'\\.\DISPLAY2 2560x1440': PetPlace(0.5, 0.5)};
      final onSide = PetPlacing.frameFor([main, side], places: places, last: side.key, size: size, box: 144);
      expect(onSide.display, side);
      expect((onSide.frame.width, onSide.frame.height), (264, 300), reason: '150%');
      expect(onSide.frame.left + onSide.frame.width / 2, closeTo((1920 + 4480) / 2, 1));
      expect(PetPlacing.displayOf([main, side], onSide.frame), side);
      final placeBack = PetPlacing.placeOf(side, onSide.frame, box: 216);
      expect(placeBack.x, closeTo(0.5, 0.01));
      expect(placeBack.y, closeTo(0.5, 0.01));

      final gone = PetPlacing.frameFor([main], places: places, last: side.key, size: size, box: 144);
      expect(gone.display, main);
      expect(gone.frame.right, 1920, reason: 'the main display’s own place: the right');
      // The room for the bubble above the pet may go past the top; the pet itself stays inside.
      expect(gone.frame.top, -(200 - 144));
    });

    test('an older single position counts on the main display', () {
      final placed = PetPlacing.frameFor([main], places: const {}, last: null, size: size, box: 144, legacy: const Offset(600, 500));
      expect((placed.frame.left, placed.frame.top), (600, 500));
    });
  });

  group('The pet', () {
    late TestDesktop t;
    late FakePetWindow window;
    late FakeShell shell;
    late FakeTaskbar taskbar;
    late FakeDisplays displays;
    final disposables = <void Function()>[];

    setUp(() {
      t = TestDesktop.make();
      window = FakePetWindow();
      shell = FakeShell(petWindow: window);
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
      displays = FakeDisplays([FakeDisplays.main1080, FakeDisplays.side1440]);
    });

    tearDown(() => t.dispose());

    void petTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final dispose in disposables.reversed) {
          dispose();
        }
        disposables.clear();
      }
    });

    Future<TaskbarStroll> start(WidgetTester tester, {CompanionDirector? companion, int seed = 7}) async {
      final stroll = TaskbarStroll(
        shell: shell,
        taskbar: taskbar,
        settings: t.desktop.settings,
        motion: t.desktop.motion,
        cues: t.desktop.cues,
        companion: companion,
        displays: displays,
        clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        random: Random(seed),
      );
      disposables.add(stroll.dispose);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      return stroll;
    }

    Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.25, void Function()? each}) async {
      for (var s = 0.0; s < seconds; s += step) {
        await tester.pump(Duration(microseconds: (step * 1e6).round()));
        each?.call();
      }
    }

    petTest('plays in its spot: beside the tray at first, never further than its room; a drag along the taskbar moves it', (
      tester,
    ) async {
      final settings = t.desktop.settings..petStyle = DesktopStyle.spot;
      final stroll = await start(tester, seed: 3);
      expect(stroll.placement, PetPlacement.taskbar);
      final stage = stroll.stage!;
      final zones = [for (final zone in stage.zones) StrollLine(zone.minX, zone.maxX)];
      final room = settings.spotRoom.spotRoom;
      final line = TaskbarStroll.spotLine(zones, null, room);
      expect(line.maxX, zones.last.maxX, reason: 'beside the notification area');
      expect(line.maxX - line.minX, room);
      double centre(PixelRect frame) => (frame.left + frame.width / 2) / stage.scale;
      var travelled = false;
      await elapse(tester, 240, step: 0.5, each: () {
        final sample = stroll.sample()!;
        if (sample.travelling) travelled = true;
        expect(sample.x, inInclusiveRange(line.minX - 0.5, line.maxX + 0.5));
      });
      expect(travelled, isTrue, reason: 'it plays: it potters about its spot');
      for (final move in window.moves) {
        expect(centre(move), inInclusiveRange(line.minX - 1, line.maxX + 1));
      }

      // Dragged along the taskbar to the left stretch: its spot is there now.
      stroll.dragStarted();
      final frame = stroll.frame!;
      stroll.dragEnded(Offset(400, frame.top / stage.scale));
      await tester.pump();
      expect(settings.spotX, 400 + frame.width / 2);
      await elapse(tester, 1);
      window.moves.clear();
      await elapse(tester, 120, step: 0.5);
      final moved = TaskbarStroll.spotLine(zones, settings.spotX, room);
      for (final move in window.moves) {
        expect(centre(move), inInclusiveRange(moved.minX - 1, moved.maxX + 1));
      }

      // More room.
      settings.spotRoom = PetSize.large;
      await elapse(tester, 1);
      final larger = TaskbarStroll.spotLine(zones, settings.spotX, PetSize.large.spotRoom);
      expect(stroller(stroll).line, larger);
    });

    petTest('the desktop pet: its size, always on top or not, clicks passing through, and back', (tester) async {
      final settings = t.desktop.settings
        ..petStyle = DesktopStyle.icon
        ..petSize = PetSize.large;
      final stroll = await start(tester);
      expect(stroll.placement, PetPlacement.standing);
      expect(shell.shows.last.size, SurfaceSizes.standing(PetSize.large));
      expect(shell.forms.last.onTop, isTrue);
      expect(shell.forms.last.frame, window.frames.last, reason: 'placed exactly, on its display');
      expect(window.frames.last.height, SurfaceSizes.standing(PetSize.large).height.round());

      settings.petOnTop = false;
      await tester.pump();
      expect(shell.forms.last.onTop, isFalse);

      settings.petSize = PetSize.small;
      await tester.pump();
      expect(shell.shows.last.size, SurfaceSizes.standing(PetSize.small));
      expect(window.frames.last.height, SurfaceSizes.standing(PetSize.small).height.round());

      settings.petClickThrough = true;
      await tester.pump();
      expect(window.clickThrough.last, isTrue);
      expect(stroll.standingClickThrough, isTrue);
      final settles = window.settles;
      settings.petClickThrough = false;
      await tester.pump();
      expect(window.settles, settles + 1, reason: 'it takes clicks again');

      // Through again, then onto the taskbar: it takes clicks there (on Mochi) as usual.
      settings.petClickThrough = true;
      await tester.pump();
      settings.petStyle = DesktopStyle.roam;
      await tester.pump();
      await tester.pump();
      expect(stroll.placement, PetPlacement.taskbar);
      expect(stroll.standingClickThrough, isFalse);
      expect(shell.forms.last.onTop, isTrue, reason: 'over the taskbar');
      expect(window.settles, greaterThan(settles + 1));
    });

    petTest('a place on each display: where it was left on that display; a display that goes puts it on the main one', (tester) async {
      final settings = t.desktop.settings..petStyle = DesktopStyle.icon;
      settings.placePet(FakeDisplays.side1440.key, const PetPlace(0.25, 0.75));
      final stroll = await start(tester);
      expect(stroll.placement, PetPlacement.standing);
      final onSide = window.frames.last;
      expect(PetPlacing.displayOf(displays.displays, onSide), FakeDisplays.side1440);

      // Dragged somewhere else on that display: remembered there.
      window.current = PixelRect.ltwh(3000, 200, onSide.width, onSide.height);
      stroll.dragStarted();
      stroll.dragEnded(const Offset(2000, 133));
      expect(settings.petDisplay, FakeDisplays.side1440.key);
      final remembered = settings.petPlaces[FakeDisplays.side1440.key]!;
      expect(remembered.x, closeTo((3000 - 1920) / (4480 - 1920 - onSide.width), 0.01));

      // The display goes away: on the main display (bottom left: never placed there).
      displays.displays = [FakeDisplays.main1080];
      tester.binding.handleMetricsChanged();
      await elapse(tester, 1);
      expect(PetPlacing.displayOf(displays.displays, window.frames.last), FakeDisplays.main1080);
      expect((window.frames.last.left, window.frames.last.bottom), (0, 1032));

      // Back: on its place there again.
      displays.displays = [FakeDisplays.main1080, FakeDisplays.side1440];
      tester.binding.handleMetricsChanged();
      await elapse(tester, 1);
      expect(window.frames.last, PixelRect.ltwh(3000, 200, onSide.width, onSide.height));
    });

    petTest('dragged off the taskbar: it stands on the desktop just above where it was, and the tray icon is Mochi', (tester) async {
      final settings = t.desktop.settings;
      final stroll = await start(tester);
      final stage = stroll.stage!;
      final frame = stroll.frame!;
      stroll.dragStarted();
      stroll.dragEnded(Offset(frame.left / stage.scale, 600));
      await tester.pump();
      await tester.pump();
      expect((settings.petStyle, stroll.placement), (DesktopStyle.icon, PetPlacement.standing));
      expect(settings.petDisplay, FakeDisplays.main1080.key);
      expect(window.frames.last.bottom, lessThanOrEqualTo(1032), reason: 'above the taskbar');
    });

    petTest('Patch only for interesting moments: his desk comes out for one, and goes again after', (tester) async {
      final library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync());
      final settings = t.desktop.settings
        ..companionVisibility = CompanionVisibility.always
        ..companionOnlyMoments = true;
      final companion = CompanionDirector(
        sessions: t.desktop.sessions,
        settings: settings,
        cues: t.desktop.cues,
        clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        random: Random(2),
      )..library = library;
      disposables.add(companion.dispose);
      final stroll = await start(tester, companion: companion);
      expect(companion.visible, isTrue);
      await elapse(tester, 1);
      expect(stroll.home, isNull, reason: 'nothing interesting: Mochi has the taskbar to itself');

      // Claude finished: Patch comes out to celebrate.
      t.desktop.cue(PetCue.finished);
      await elapse(tester, 0.5);
      expect(stroll.home, isNotNull);
      expect(stroll.anyTimer, isTrue);
      // Once the moment (and anything it started) is over, he goes.
      await elapse(tester, TaskbarStroll.momentLength + 30, step: 0.5);
      expect(stroll.interesting, isFalse);
      expect(stroll.home, isNull);

      // Off: he's at his desk whenever he's around, as before.
      settings.companionOnlyMoments = false;
      await elapse(tester, 1);
      expect(stroll.home, isNotNull);
    });
  });

  group('The classic tray icon', () {
    late TestDesktop t;
    late FakeShell shell;
    late Directory folder;

    setUp(() {
      t = TestDesktop.make();
      shell = FakeShell();
      folder = Directory.systemTemp.createTempSync('mochi_tray_test');
    });

    tearDown(() {
      folder.deleteSync(recursive: true);
      t.dispose();
    });

    test('an .ico with a PNG for each size from 100% to 300%', () async {
      final bytes = await TrayGlyph.ico(const GlyphFrame(mood: GlyphMood.content));
      final data = ByteData.sublistView(bytes);
      expect((data.getUint16(0, Endian.little), data.getUint16(2, Endian.little), data.getUint16(4, Endian.little)), (0, 1, TrayGlyph.sizes.length));
      for (var i = 0; i < TrayGlyph.sizes.length; i++) {
        final entry = 6 + 16 * i;
        expect(data.getUint8(entry), TrayGlyph.sizes[i]);
        final offset = data.getUint32(entry + 12, Endian.little);
        expect(bytes.sublist(offset + 1, offset + 4), 'PNG'.codeUnits, reason: 'a PNG');
      }
    });

    testWidgets('Mochi in the tray while it lives there: its moods, a pulse while Claude works, then the app’s icon again', (tester) async {
      var mood = PetMood.relaxed;
      AttentionLevel? badge;
      final usage = FakeUsage(const SystemActivity(idleSeconds: 1));
      final rhythm = PcRhythm(settings: t.desktop.settings, sampler: usage)..start();
      final settings = t.desktop.settings..petStyle = DesktopStyle.icon;
      final tray = TrayGlyphController(
        shell: shell,
        settings: settings,
        folder: folder.path,
        mood: () => mood,
        cues: t.desktop.cues,
        motion: t.desktop.motion,
        rhythm: rhythm,
        badge: () => badge,
        clock: () => tester.binding.clock.now(),
        random: Random(1),
        write: (frame) async => '${folder.path}/${frame.key}.ico',
      );
      try {
        await tester.pump();
        expect(tray.shown!.mood, GlyphMood.content);
        expect(shell.trayIcons.last.path, endsWith('${tray.shown!.key}.ico'));
        expect(shell.trayIcons.last.tooltip, 'Mochi');

        // Claude works: the light pulses (on, then off, 0.8 s apart).
        mood = PetMood.watching;
        tray.refresh();
        final bulbs = <bool?>{};
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          bulbs.add(tray.shown!.bulb);
        }
        expect(bulbs, {true, false});
        expect(tray.ticking, isTrue);

        // Something waits for you: the badge.
        mood = PetMood.needsYou;
        badge = AttentionLevel.attention;
        tray.refresh();
        expect((tray.shown!.mood, tray.shown!.badge, tray.shown!.bulb), (GlyphMood.waiting, AttentionLevel.attention, null));

        // Static: still, but it still follows the mood.
        settings.trayAnimation = TrayAnimation.off;
        expect(tray.shown!.blink, isFalse);
        mood = PetMood.napping;
        await tester.pump(const Duration(seconds: 6));
        expect(tray.shown!.mood, GlyphMood.sleeping);

        // Nobody can see the screen: no timer.
        settings.trayAnimation = TrayAnimation.subtle;
        usage.change(const SystemActivity(idleSeconds: 400, displaysAsleep: true));
        await tester.pump();
        expect(tray.ticking, isFalse);
        usage.change(const SystemActivity(idleSeconds: 0));
        await tester.pump();
        expect(tray.ticking, isTrue);

        // Back on the taskbar: the app's own icon, and no timer.
        settings.petStyle = DesktopStyle.roam;
        await tester.pump();
        expect((shell.trayIcons.last.path, tray.ticking, tray.shown), (null, false, null));
      } finally {
        tray.dispose();
        rhythm.dispose();
      }
    });

    testWidgets('a finished turn: it hops, then settles', (tester) async {
      var mood = PetMood.relaxed;
      final settings = t.desktop.settings..petStyle = DesktopStyle.icon;
      final tray = TrayGlyphController(
        shell: shell,
        settings: settings,
        folder: folder.path,
        mood: () => mood,
        cues: t.desktop.cues,
        motion: t.desktop.motion,
        clock: () => tester.binding.clock.now(),
        random: Random(1),
        write: (frame) async => '${folder.path}/${frame.key}.ico',
      );
      try {
        mood = PetMood.happy;
        t.desktop.cue(PetCue.finished);
        await tester.pump();
        final bounces = <double>{};
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          bounces.add(tray.shown!.bounce);
        }
        expect(tray.shown!.mood, GlyphMood.celebrating);
        expect(bounces.reduce(max), greaterThan(1.5), reason: 'it hopped');
        await tester.pump(const Duration(seconds: 3));
        expect(tray.shown!.bounce, 0, reason: 'and settled');
      } finally {
        tray.dispose();
      }
    });
  });

  group('Settings › Desktop Pet', () {
    late TestDesktop t;
    late FakeShell shell;

    setUp(() {
      t = TestDesktop.make();
      shell = FakeShell();
    });

    tearDown(() => t.dispose());

    for (final style in DesktopStyle.values) {
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('${style.title}: every option, nothing “not on Windows yet” (${theme.name}, ${scale.toStringAsFixed(0)}× text)', (
            tester,
          ) async {
            t.desktop.settings
              ..themeMode = theme
              ..petStyle = style;
            tester.view.physicalSize = SurfaceSizes.settings;
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.view.reset);
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            await tester.pumpWidget(
              DesktopApp(
                desktop: t.desktop,
                shell: shell,
                initialSurface: Surface.main,
                initialPage: MainPage.settings,
                initialPane: SettingsTab.desktop,
                library: Future<PoseLibrary?>.value(),
              ),
            );
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull);
            expect(find.text(SoonRow.tag), findsNothing);
            for (final text in ['Roams the taskbar', 'Plays in its spot', 'Classic tray icon', 'Small', 'Medium', 'Large', 'Always on top', 'Reset Position']) {
              expect(find.text(text), findsWidgets, reason: text);
            }
            expect(find.text('Room to play'), style == DesktopStyle.spot ? findsOneWidget : findsNothing);
            expect(find.text('Icon animation'), style == DesktopStyle.icon ? findsOneWidget : findsNothing);
            expect(find.text('Only for interesting moments'), style.onTaskbar ? findsOneWidget : findsNothing);
            final content = find.byType(SingleChildScrollView).last;
            await tester.drag(content, const Offset(0, -4000));
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('each option is a setting', (tester) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: shell,
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.desktop,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final settings = t.desktop.settings;
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tap(find.widgetWithText(ChoiceChip, 'Plays in its spot'));
      await tap(find.widgetWithText(ChoiceChip, 'Large').first);
      expect((settings.petStyle, settings.spotRoom), (DesktopStyle.spot, PetSize.large));
      await tap(find.widgetWithText(ChoiceChip, 'Small').last);
      expect(settings.petSize, PetSize.small);
      await tap(find.text('Only for interesting moments'));
      await tap(find.text('Always on top'));
      await tap(find.text('Let clicks pass through Mochi'));
      expect((settings.companionOnlyMoments, settings.petOnTop, settings.petClickThrough), (true, false, true));
      expect(t.document.json!['petClickThrough'], isTrue);
      await tap(find.widgetWithText(ChoiceChip, 'Classic tray icon'));
      await tap(find.widgetWithText(ChoiceChip, 'Expressive'));
      expect((settings.petStyle, settings.trayAnimation), (DesktopStyle.icon, TrayAnimation.full));
      expect(shell.trayStyles.last, DesktopStyle.icon);
      settings.placePet('A', const PetPlace(0.5, 0.5));
      await tester.pump();
      await tap(find.text('Reset Position'));
      expect(settings.petPlaces, isEmpty);
    });
  });
}

/// The stroll's plan (its line is Mochi's room).
Stroller stroller(TaskbarStroll stroll) => stroll.stroller;
