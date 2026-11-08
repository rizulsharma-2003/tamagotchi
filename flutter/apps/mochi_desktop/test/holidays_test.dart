// Holidays on Windows, the rest (docs/SPRINT_2.md W20), as the Mac's SeasonController runs them: the occasion kept fresh
// (launch, a few seconds later, the hour, midnight, the screen coming back, the settings), greeted once per occasion
// (its note waiting for Mochi's window), the greeted ones kept in seasons.json; the seasonal treat, costumes on both
// characters, the candles and New Year's digits; the little decoration beside Patch's desk on the taskbar
// (Settings › Fun › Holidays, the Mac's `seasonal.decorateMenuBar`).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

void main() {
  late DateTime now;
  late double seconds;
  late TestDesktop t;

  setUp(() {
    now = DateTime(2026, 11, 8, 9);
    seconds = 100;
  });
  tearDown(() => t.dispose());

  TestDesktop make({Map<String, Object?>? settings, Map<String, Object?> files = const {}}) => t = TestDesktop.make(
    clock: () => now,
    uptime: () => seconds,
    settings: {'adoptedAt': '2026-01-15T10:00:00.000', ...?settings},
    files: files,
  );

  /// Time passes with the world ticking (its minute check moves the holidays on).
  void later(Duration by) {
    final steps = (by.inMilliseconds / 250).ceil();
    for (var i = 0; i < steps; i++) {
      now = now.add(const Duration(milliseconds: 250));
      seconds += 0.25;
      t.desktop.world.tick();
    }
  }

  test('Diwali: laddoos for treats from launch; the greeting a few seconds in, its note when Mochi’s window opens; once', () {
    make();
    final holidays = t.desktop.holidays;
    expect(holidays.event, w.SeasonalEvent.diwali);
    expect(SeasonalTreats.style, w.TreatStyle.laddoo, reason: 'the seasonal treat');
    expect(t.desktop.world.speechNow.value, isNull, reason: 'no greeting right at launch');
    holidays.refresh();
    expect(t.desktop.world.speechNow.value?.text, 'So many lights!');
    expect(t.desktop.world.world.pet.current.animation, w.PetAnimation.dance);
    expect(t.desktop.world.toastNow.value, isNull, reason: 'the note waits for Mochi’s window');
    t.desktop.world.setWindowVisible(true);
    expect(t.desktop.world.toastNow.value?.title, 'Happy Diwali!');
    expect(t.desktop.world.toastNow.value?.detail, 'Diyas, lights and a rangoli — and laddoos for treats.');
    expect(t.stores['seasons.json']!.json, {
      'greeted': ['diwali-2026'],
    }, reason: 'the Mac’s seasons.json');
    t.desktop.world.world.say('Hello again', duration: 1);
    holidays.refresh();
    expect(t.desktop.world.world.activeSpeech?.text, 'Hello again', reason: 'greeted once per occasion');
    expect(t.desktop.settings.wornByPet(now), Accessory.flowerCrown, reason: 'the costume, on both characters');
    expect(t.desktop.settings.wornByCompanion(now), Accessory.flowerCrown);
  });

  test('a later launch remembers what was greeted', () {
    make(
      files: {
        'seasons.json': {
          'greeted': ['diwali-2026'],
        },
      },
    );
    t.desktop.holidays.refresh();
    expect(t.desktop.world.speechNow.value, isNull);
  });

  test('on the hour and at midnight: Diwali’s last day ends, the cookies come back', () {
    now = DateTime(2026, 11, 10, 23, 58);
    make();
    expect(t.desktop.holidays.event, w.SeasonalEvent.diwali);
    later(const Duration(minutes: 3));
    expect(t.desktop.holidays.event, isNull);
    expect(SeasonalTreats.style, w.TreatStyle.cookie);
  });

  test('your birthday entered for today: party hats, cake and candles; turning holidays off takes it all away', () {
    make();
    t.desktop.settings.setBirthday(11, 8);
    expect(t.desktop.holidays.event, w.SeasonalEvent.userBirthday, reason: 'over Diwali');
    expect(t.desktop.world.speechNow.value?.text, 'Happy birthday to you!');
    expect(SeasonalTreats.style, w.TreatStyle.cakeSlice);
    expect(SeasonRenderContext.candles, 3);
    expect(t.desktop.settings.wornByPet(now), Accessory.partyHat);
    t.desktop.settings.holidays = false;
    expect(t.desktop.holidays.event, isNull);
    expect(SeasonalTreats.style, w.TreatStyle.cookie);
    expect(t.desktop.settings.wornByPet(now), isNull);
  });

  test('New Year’s digits and Mochi’s own birthday candles', () {
    now = DateTime(2026, 12, 31, 20);
    make();
    expect(SeasonRenderContext.newYear, 2027);
    now = DateTime(2028, 1, 15, 12);
    t.desktop.holidays.refresh();
    expect(t.desktop.holidays.event, w.SeasonalEvent.mochiBirthday);
    expect(SeasonRenderContext.candles, 2, reason: 'two years together');
  });

  test('the taskbar’s decoration follows its switch (the Mac’s key)', () {
    make();
    expect(SeasonRenderContext.decorateMenuBar, isTrue);
    t.desktop.settings.decorateTaskbar = false;
    expect(SeasonRenderContext.decorateMenuBar, isFalse);
    expect((t.document.json!['seasonal']! as Map)['decorateMenuBar'], isFalse);
  });

  group('Settings', () {
    setUp(make);

    testWidgets('Settings › Fun › Holidays: the Mac’s status line and the taskbar decoration’s switch, light and dark, 1× and 2×', (
      tester,
    ) async {
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        for (final scale in [1.0, 2.0]) {
          t.desktop.settings.themeMode = theme;
          tester.view.physicalSize = SurfaceSizes.settings;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
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
          expect(tester.takeException(), isNull, reason: '${theme.name} ${scale}x');
          await tester.ensureVisible(find.text('Celebrate holidays with decorations, costumes and treats'));
          expect(
            find.text(
              'Diwali until 10 November. Next: Christmas from 18 December. Mochi’s birthday is 15 January, the day you met.'.replaceAll(
                '’',
                "'",
              ),
            ),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 6));
        }
      }
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.physicalSize = SurfaceSizes.settings;
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
      await tester.ensureVisible(find.text('A little decoration beside Patch’s desk on the taskbar'));
      await tester.tap(find.text('A little decoration beside Patch’s desk on the taskbar'));
      await tester.pump();
      expect(t.desktop.settings.decorateTaskbar, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      tester.view.reset();
    });
  });
}
