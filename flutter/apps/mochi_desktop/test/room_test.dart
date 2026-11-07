// The room in Mochi's window (ui/pet/room_view.dart), as the phones' home screens show it: in light and dark, at 1×
// and 2× (text, and pixels), with Patch at his desk while a session is open and his desk empty while he's away; what a
// screen reader hears, and clicks on Mochi and on Patch.

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/room_view.dart';
import 'package:mochi_desktop/src/ui/screens/home_screen.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

void main() {
  late PoseLibrary library;
  late TestDesktop t;

  setUpAll(() => library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync()));
  setUp(() => t = TestDesktop.make());
  tearDown(() => t.dispose());

  Future<DesktopAppState> show(WidgetTester tester, {ThemeMode theme = ThemeMode.light, double scale = 1}) async {
    t.desktop.settings.themeMode = theme;
    tester.view.physicalSize = SurfaceSizes.main * scale;
    tester.view.devicePixelRatio = scale;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      DesktopApp(
        desktop: t.desktop,
        shell: FakeShell(),
        initialSurface: Surface.main,
        library: Future.value(library),
        strollClock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        strollRandom: Random(1),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return tester.state<DesktopAppState>(find.byType(DesktopApp));
  }

  LiveRoomPainter painter(WidgetTester tester) =>
      tester.widget<CustomPaint>(
            find.descendant(of: find.byType(RoomView), matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter is LiveRoomPainter)),
          ).painter!
          as LiveRoomPainter;

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('the room with Patch at work (${theme.name}, ${scale.toStringAsFixed(0)}×)', (tester) async {
        t.desktop.settings.companionName = 'Byte';
        t.desktop.sessions
          ..apply(hook('SessionStart', at: DateTime.now()))
          ..apply(hook('UserPromptSubmit', at: DateTime.now()))
          ..apply(hook('PreToolUse', tool: 'Edit', toolUseId: 'e', at: DateTime.now()));
        await show(tester, theme: theme, scale: scale);
        await tester.pump(const Duration(seconds: 6));
        expect(tester.takeException(), isNull);
        final room = tester.getSize(find.byType(RoomView));
        expect(room.height, closeTo(HomeScreen.roomHeight, 2), reason: 'inside its card');
        final scene = painter(tester);
        expect(scene.dark, theme == ThemeMode.dark, reason: "the room's night colours with the dark theme");
        final frame = scene.frame(scene.clock.value);
        expect(frame.companionVisible, isTrue);
        expect(find.bySemanticsLabel("Mochi's room. Mochi is watching Claude work. Byte is typing at his desk."), findsOneWidget);
        expect(find.text('and Byte · Mochi is watching Claude work'), findsOneWidget);
        expect(find.text('Click Mochi to pet, or Byte for a wave'), findsOneWidget);
        // A click on Patch: a wave.
        final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
        await tester.tap(find.bySemanticsLabel('Byte. Click for a wave.'));
        await tester.pump();
        expect(state.companion.shot?.animation, CompanionAnimation.greet);
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('with Patch away, his desk is empty and only Mochi takes clicks', (tester) async {
    t.desktop.settings.companionVisibility = CompanionVisibility.never;
    await show(tester);
    final scene = painter(tester);
    expect(scene.frame(scene.clock.value).companionVisible, isFalse);
    // ignore: avoid_print
    expect(find.bySemanticsLabel("Mochi's room. Mochi is relaxing. Patch is away."), findsOneWidget);
    expect(find.bySemanticsLabel('Patch. Click for a wave.'), findsNothing);
    expect(find.bySemanticsLabel('Mochi. Click to pet.'), findsOneWidget);
    expect(find.text('Click Mochi to pet'), findsOneWidget);
  });

  testWidgets("the room wears today's look: the theme, the coat, what they wear, the desk thing, the holiday", (tester) async {
    t.desktop.settings
      ..officeTheme = OfficeTheme.gardenOffice
      ..petColor = PetColor.mint
      ..companionAccessory = Accessory.beanie
      ..deskAccessory = Accessory.lavaLamp;
    await show(tester, theme: ThemeMode.dark);
    final config = painter(tester).config;
    expect(
      (config.theme, config.petColor, config.wornByCompanion, config.deskAccessory),
      (OfficeTheme.gardenOffice, PetColor.mint, Accessory.beanie, Accessory.lavaLamp),
    );
    expect(config.season, t.desktop.settings.holidayOn(t.desktop.sessions.now));
  });
}
