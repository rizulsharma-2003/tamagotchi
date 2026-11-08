// Weather and time moods (docs/SPRINT_2.md X12): the morning coffee with Patch (once a day, only between 06:00 and 11:00, only
// with Patch on the taskbar), the umbrella when it rains (opt-in city, Open-Meteo asked every 30 minutes while it's wanted,
// nothing sent otherwise, the umbrella shown or hidden by state) and the late-night reshuffle of the taskbar stroll's choices.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/moods.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show NotificationPreferences, QuietHours;
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';

import 'support/fakes.dart';

void main() {
  group('The pieces', () {
    test('coordinates are kept to one decimal, and nothing else about the place', () {
      expect(LocalWeatherSettings.round1(18.5204), 18.5);
      expect(LocalWeatherSettings.round1(73.8567), 73.9);
      expect(LocalWeatherSettings.round1(-33.8688), -33.9);
      expect(LocalWeatherSettings.round1(0.04), 0.0);
      final weather = const LocalWeatherSettings(enabled: true).withCity('Pune, IN', 18.5204, 73.8567);
      expect((weather.latitude, weather.longitude, weather.city), (18.5, 73.9, 'Pune, IN'));
      expect(weather.toJson(), {'enabled': true, 'city': 'Pune, IN', 'lat': 18.5, 'lon': 73.9});
      // Read back, even a file with exact coordinates is rounded.
      final read = LocalWeatherSettings.fromJson({'enabled': true, 'city': 'Pune', 'lat': 18.5204, 'lon': 73.8567, 'street': '1 Main St'});
      expect((read.latitude, read.longitude), (18.5, 73.9));
      expect(read.toJson().keys, ['enabled', 'city', 'lat', 'lon']);
      expect(LocalWeatherSettings.fromJson({'enabled': true, 'city': 'X', 'lat': 120, 'lon': 0}).hasCity, isFalse);
      expect(LocalWeatherSettings.fromJson('nonsense').enabled, isFalse);
      expect(const LocalWeatherSettings().enabled, isFalse, reason: 'off at first');
      expect(const LocalWeatherSettings(enabled: true).ready, isFalse, reason: 'on, but no city yet');
    });

    test('the URLs: the geocoding takes the name and a count of one; the forecast takes only the rounded position', () {
      final geocoding = DesktopMoods.geocodingUri('São Paulo');
      expect((geocoding.scheme, geocoding.host, geocoding.path), ('https', 'geocoding-api.open-meteo.com', '/v1/search'));
      expect(geocoding.queryParameters, {'name': 'São Paulo', 'count': '1'});
      expect(
        DesktopMoods.forecastUri(18.5204, 73.8567).toString(),
        'https://api.open-meteo.com/v1/forecast?latitude=18.5&longitude=73.9&current=weather_code,is_day',
      );
      expect(DesktopMoods.forecastUri(-33.8688, 151.2093).queryParameters.keys, ['latitude', 'longitude', 'current']);
      expect(DesktopMoods.headers, {'User-Agent': 'Mochi'});
    });

    test('drizzle, rain, showers and thunderstorms mean rain; nothing else does', () {
      for (final code in [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99]) {
        expect(DesktopMoods.isRain(code), isTrue, reason: '$code');
      }
      for (final code in [0, 1, 2, 3, 45, 48, 50, 68, 71, 73, 75, 77, 85, 86, 79, 83, 94, 100]) {
        expect(DesktopMoods.isRain(code), isFalse, reason: '$code');
      }
      expect(DesktopMoods.codeIn({'current': {'weather_code': 63, 'is_day': 1}}), 63);
      expect(DesktopMoods.codeIn({'current': {}}), isNull);
      expect(DesktopMoods.codeIn('x'), isNull);
    });

    test('a geocoding answer: the first result’s display name and position', () {
      final city = DesktopMoods.cityIn({
        'results': [
          {'name': 'Pune', 'latitude': 18.51957, 'longitude': 73.85535, 'country_code': 'IN', 'admin1': 'Maharashtra', 'id': 1259229},
        ],
      })!;
      expect((city.name, city.latitude, city.longitude), ('Pune, IN', 18.51957, 73.85535));
      expect(DesktopMoods.cityIn({'results': []}), isNull);
      expect(DesktopMoods.cityIn({'generationtime_ms': 1}), isNull);
    });

    test('the setting is saved and read back; a coffee day only in its shape', () {
      final document = MemorySettingsDocument();
      final settings = DesktopSettings(document);
      expect(settings.weather.enabled, isFalse);
      settings.weather = const LocalWeatherSettings(enabled: true).withCity('Pune, IN', 18.5204, 73.8567);
      settings.coffeeDay = '2026-11-24';
      final again = DesktopSettings(MemorySettingsDocument(document.json));
      expect(again.weather, settings.weather);
      expect(again.coffeeDay, '2026-11-24');
      document.json!['coffeeDay'] = 'yesterday';
      expect(DesktopSettings(MemorySettingsDocument(document.json)).coffeeDay, isNull);
    });
  });

  group('The weather', () {
    late TestDesktop t;
    late DesktopMoods moods;
    late List<http.Request> requests;
    var answers = <http.Response Function(http.Request)>[];
    http.Response Function(http.Request) forecast = (_) => http.Response('{}', 200);

    http.Response rainy(http.Request _) => http.Response(jsonEncode({'current': {'weather_code': 63, 'is_day': 1}}), 200);
    http.Response clear(http.Request _) => http.Response(jsonEncode({'current': {'weather_code': 1, 'is_day': 1}}), 200);

    setUp(() {
      t = TestDesktop.make(clock: () => DateTime(2026, 11, 24, 15));
      t.desktop.rhythm.sample();
      requests = [];
      answers = [];
      forecast = rainy;
    });

    tearDown(() => t.dispose());

    /// Moods on a clock that follows the test's fake time from 15:00.
    DesktopMoods make(WidgetTester tester, {bool? forced}) {
      final zero = tester.binding.clock.now();
      final start = DateTime(2026, 11, 24, 15);
      moods = DesktopMoods(
        settings: t.desktop.settings,
        world: t.desktop.world,
        rhythm: t.desktop.rhythm,
        gate: t.desktop.mischief,
        clock: () => start.add(tester.binding.clock.now().difference(zero)),
        client: () => MockClient((request) async {
          requests.add(request);
          if (request.url.host == DesktopMoods.geocodingHost) {
            return http.Response(
              jsonEncode({
                'results': [
                  {'name': 'Pune', 'latitude': 18.52043, 'longitude': 73.85674, 'country_code': 'IN'},
                ],
              }),
              200,
            );
          }
          if (answers.isNotEmpty) return answers.removeAt(0)(request);
          return forecast(request);
        }),
        forced: forced,
      );
      t.desktop.mischief.start();
      moods.start();
      return moods;
    }

    Future<void> pass(WidgetTester tester, Duration by) async {
      for (var left = by; left > Duration.zero; left -= const Duration(seconds: 30)) {
        await tester.pump(left < const Duration(seconds: 30) ? left : const Duration(seconds: 30));
      }
    }

    void on({String city = 'Pune, IN'}) {
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      t.desktop.settings.weather = LocalWeatherSettings(enabled: true).withCity(city, 18.5204, 73.8567);
    }

    void away(WidgetTester tester) {
      moods.dispose();
      t.desktop.mischief.stop();
    }

    Future<void> scene(WidgetTester tester, Future<void> Function() body) async {
      try {
        await body();
      } finally {
        away(tester);
      }
    }

    testWidgets('a city is looked up once (only its name sent) and kept rounded; then the weather there is asked for', (tester) async {
      make(tester);
      await scene(tester, () async {
        t.desktop.settings.mischief = const MischiefSettings(enabled: true);
        t.desktop.settings.weather = const LocalWeatherSettings(enabled: true);
        expect(await moods.setCity('  Pune '), isNull);
        expect(requests, hasLength(1));
        expect(requests.single.url.queryParameters, {'name': 'Pune', 'count': '1'});
        expect(requests.single.headers.keys.map((key) => key.toLowerCase()), ['user-agent']);
        expect(requests.single.headers['User-Agent'], 'Mochi');
        expect(requests.single.body, isEmpty);
        final weather = t.desktop.settings.weather;
        expect((weather.city, weather.latitude, weather.longitude), ('Pune, IN', 18.5, 73.9));
        await pass(tester, const Duration(seconds: 1));
        expect(requests, hasLength(2));
        expect(requests.last.url.toString(), 'https://api.open-meteo.com/v1/forecast?latitude=18.5&longitude=73.9&current=weather_code,is_day');
        expect(moods.raining, isTrue);
      });
    });

    testWidgets('a city nobody knows, or no connection, says so and keeps nothing', (tester) async {
      make(tester);
      await scene(tester, () async {
        expect(await moods.setCity('   '), CityProblem.empty);
        expect(requests, isEmpty, reason: 'nothing typed: nothing sent');
      });
    });

    testWidgets('no request while it is off, while the extra is off, without a city, or while nobody can see the screen', (tester) async {
      make(tester);
      await scene(tester, () async {
        await pass(tester, const Duration(minutes: 70));
        expect(requests, isEmpty, reason: 'Mischief is off at first');
        t.desktop.settings.mischief = const MischiefSettings(enabled: true);
        t.desktop.settings.weather = const LocalWeatherSettings(enabled: true);
        await pass(tester, const Duration(minutes: 70));
        expect(requests, isEmpty, reason: 'Local weather is on but there is no city');
        expect(moods.watching, isFalse);
        t.desktop.settings.weather = const LocalWeatherSettings().withCity('Pune, IN', 18.5, 73.9);
        await pass(tester, const Duration(minutes: 70));
        expect(requests, isEmpty, reason: 'a city, but the switch is off');
        t.desktop.settings.mischief = const MischiefSettings(enabled: true).withExtra(MischiefExtra.moods, false);
        t.desktop.settings.weather = t.desktop.settings.weather.copyWith(enabled: true);
        await pass(tester, const Duration(minutes: 70));
        expect(requests, isEmpty, reason: 'Weather and time moods is off');
        t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1, displaysAsleep: true));
        t.desktop.settings.mischief = const MischiefSettings(enabled: true);
        await pass(tester, const Duration(minutes: 70));
        expect(requests, isEmpty, reason: 'nobody can see the screen');
        expect(moods.watching, isFalse);
        t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1));
        await pass(tester, const Duration(seconds: 5));
        expect(requests, hasLength(1), reason: 'the screen is back: one request, at once');
      });
    });

    testWidgets('every 30 minutes, not sooner; turning it off stops it; a short look away does not repeat it', (tester) async {
      make(tester);
      await scene(tester, () async {
        on();
        await pass(tester, const Duration(seconds: 5));
        expect(requests, hasLength(1));
        await pass(tester, const Duration(minutes: 29));
        expect(requests, hasLength(1), reason: '29 minutes: still the same slot');
        await pass(tester, const Duration(minutes: 2));
        expect(requests, hasLength(2));
        // The screen goes off and comes back inside the slot: nothing is asked.
        t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1, displaysAsleep: true));
        await pass(tester, const Duration(minutes: 5));
        t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1));
        await pass(tester, const Duration(minutes: 5));
        expect(requests, hasLength(2));
        expect(moods.watching, isTrue, reason: 'a timer for the rest of the slot');
        await pass(tester, const Duration(minutes: 25));
        expect(requests, hasLength(3));
        t.desktop.settings.weather = t.desktop.settings.weather.copyWith(enabled: false);
        await pass(tester, const Duration(minutes: 90));
        expect(requests, hasLength(3));
        expect(moods.watching, isFalse);
      });
    });

    testWidgets('a failed answer is silent: no umbrella, and the next try is the next 30-minute slot', (tester) async {
      make(tester);
      await scene(tester, () async {
        answers = [(_) => http.Response('nope', 500), (_) => throw http.ClientException('offline')];
        on();
        await pass(tester, const Duration(seconds: 5));
        expect(requests, hasLength(1));
        expect(moods.raining, isFalse);
        await pass(tester, const Duration(minutes: 20));
        expect(requests, hasLength(1), reason: 'no retry storm');
        await pass(tester, const Duration(minutes: 11));
        expect(requests, hasLength(2), reason: 'the next slot (this one throws)');
        expect(moods.raining, isFalse);
        await pass(tester, const Duration(minutes: 31));
        expect(requests, hasLength(3));
        expect(moods.raining, isTrue, reason: 'and the one after that worked');
      });
    });

    testWidgets('the umbrella: up while it rains and Mischief may, down when it clears, when a switch goes off or while Mischief rests', (tester) async {
      make(tester);
      await scene(tester, () async {
        expect(moods.umbrella.value, isFalse);
        on();
        await pass(tester, const Duration(seconds: 5));
        expect(moods.umbrella.value, isTrue, reason: 'it rains');
        // Quiet hours: Mischief rests, so does the umbrella.
        t.desktop.settings.quietMode = true;
        await pass(tester, const Duration(seconds: 3));
        expect(moods.umbrella.value, isFalse);
        t.desktop.settings.quietMode = false;
        await pass(tester, const Duration(seconds: 3));
        expect(moods.umbrella.value, isTrue);
        // The extra off.
        t.desktop.settings.mischief = const MischiefSettings(enabled: true).withExtra(MischiefExtra.moods, false);
        await pass(tester, const Duration(seconds: 3));
        expect(moods.umbrella.value, isFalse);
        t.desktop.settings.mischief = const MischiefSettings(enabled: true);
        await pass(tester, const Duration(seconds: 3));
        expect(moods.umbrella.value, isTrue);
        // Local weather off.
        t.desktop.settings.weather = t.desktop.settings.weather.copyWith(enabled: false);
        await pass(tester, const Duration(seconds: 3));
        expect(moods.umbrella.value, isFalse);
        // On again: it asks again (a new slot after the last), and it has stopped raining.
        forecast = clear;
        t.desktop.settings.weather = t.desktop.settings.weather.copyWith(enabled: true);
        await pass(tester, const Duration(minutes: 31));
        expect(moods.raining, isFalse);
        expect(moods.umbrella.value, isFalse);
      });
    });

    testWidgets('a different city drops the old answer at once', (tester) async {
      make(tester);
      await scene(tester, () async {
        on(city: 'Madrid, ES');
        await pass(tester, const Duration(seconds: 5));
        expect(moods.umbrella.value, isTrue);
        forecast = clear;
        await moods.setCity('Pune');
        expect(moods.umbrella.value, isFalse);
        await pass(tester, const Duration(seconds: 5));
        expect(requests.where((request) => request.url.host == DesktopMoods.forecastHost), hasLength(2), reason: 'asked for the new city at once');
        expect(moods.raining, isFalse);
      });
    });

    testWidgets('the development switch skips the network and the city: rain or clear', (tester) async {
      make(tester, forced: true);
      await scene(tester, () async {
        expect(t.desktop.settings.weather.ready, isFalse);
        t.desktop.settings.mischief = const MischiefSettings(enabled: true);
        await pass(tester, const Duration(minutes: 70));
        expect(requests, isEmpty);
        expect(moods.watching, isFalse);
        expect(moods.umbrella.value, isTrue);
        t.desktop.settings.mischief = const MischiefSettings(enabled: true).withExtra(MischiefExtra.moods, false);
        await pass(tester, const Duration(seconds: 3));
        expect(moods.umbrella.value, isFalse, reason: 'still behind the extra');
      });
      expect(MischiefStage.weatherFrom('rain'), isTrue);
      expect(MischiefStage.weatherFrom(' Clear '), isFalse);
      expect(MischiefStage.weatherFrom('snow'), isNull);
      expect(MischiefStage.weatherFrom(null), isNull);
    });
  });

  group('The umbrella in the picture', () {
    late TestDesktop t;

    setUp(() => t = TestDesktop.make());
    tearDown(() => t.dispose());

    /// The view's pixels for [sample] in a window 300 by 80 logical pixels, with the umbrella up or not.
    Future<Uint8List> draw(WidgetTester tester, StrollSample sample, {required bool umbrella}) async {
      final key = GlobalKey();
      final up = ValueNotifier(umbrella);
      addTearDown(up.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(300, 80);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(300, 80)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 80,
                child: RepaintBoundary(
                  key: key,
                  child: MochiView(
                    world: t.desktop.world,
                    sessions: t.desktop.sessions,
                    lastActivity: () => t.desktop.sessions.now,
                    fill: SurfaceSizes.taskbarFill,
                    feet: SurfaceSizes.taskbarFeet,
                    detail: RenderDetail.tiny,
                    stroll: () => sample,
                    time: () => 2.0,
                    umbrella: up,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final pixels = await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      return pixels!;
    }

    int differences(Uint8List a, Uint8List b) {
      var n = 0;
      for (var i = 3; i < a.length; i += 4) {
        if ((a[i] - b[i]).abs() > 40) n++;
      }
      return n;
    }

    const walking = StrollSample(x: 500, facing: 1, animation: PetAnimation.walk, animationTime: 2.0, activity: StrollActivity.wander, travelling: true);
    const standing = StrollSample(x: 500, facing: 1, animation: PetAnimation.idle, animationTime: 2.0, activity: StrollActivity.rest);

    testWidgets('held while Mochi walks or stands: pixels the same Mochi does not have, beside it', (tester) async {
      for (final sample in [walking, standing]) {
        final bare = await draw(tester, sample, umbrella: false);
        final held = await draw(tester, sample, umbrella: true);
        expect(differences(bare, held), greaterThan(80), reason: '${sample.animation}: the umbrella is drawn');
        // Only on the taskbar's window: it stays inside it (nothing beyond the 300 px of it, trivially) and never covers the
        // far side from where it's held.
        var left = 0;
        for (var y = 0; y < 80; y++) {
          for (var x = 0; x < 120; x++) {
            if ((bare[(y * 300 + x) * 4 + 3] - held[(y * 300 + x) * 4 + 3]).abs() > 40) left++;
          }
        }
        expect(left, 0, reason: 'held on the side it faces; nothing on the other');
      }
    });

    testWidgets('held on the other side when Mochi faces the other way', (tester) async {
      const facingLeft = StrollSample(x: 500, facing: -1, animation: PetAnimation.idle, animationTime: 2.0, activity: StrollActivity.rest);
      final bare = await draw(tester, facingLeft, umbrella: false);
      final held = await draw(tester, facingLeft, umbrella: true);
      var right = 0;
      for (var y = 0; y < 80; y++) {
        for (var x = 180; x < 300; x++) {
          if ((bare[(y * 300 + x) * 4 + 3] - held[(y * 300 + x) * 4 + 3]).abs() > 40) right++;
        }
      }
      expect(differences(bare, held), greaterThan(80));
      expect(right, 0);
    });

    testWidgets('not while asleep, not hiding in the taskbar (Peekaboo), not raised on a landmark', (tester) async {
      const asleep = StrollSample(x: 500, facing: 1, animation: PetAnimation.curl, animationTime: 2.0, activity: StrollActivity.nap);
      const sleeping = StrollSample(x: 500, facing: 1, animation: PetAnimation.sleep, animationTime: 2.0, activity: StrollActivity.sleep);
      const hiding = StrollSample(x: 500, facing: 1, animation: PetAnimation.sit, animationTime: 2.0, activity: StrollActivity.hide, sink: 1);
      const sinking = StrollSample(x: 500, facing: 1, animation: PetAnimation.sit, animationTime: 2.0, activity: StrollActivity.hide, sink: 0.5);
      const perched = StrollSample(x: 500, facing: 1, animation: PetAnimation.idle, animationTime: 2.0, activity: StrollActivity.perch, lift: 12);
      for (final sample in [asleep, sleeping, hiding, sinking, perched]) {
        final bare = await draw(tester, sample, umbrella: false);
        final held = await draw(tester, sample, umbrella: true);
        expect(differences(bare, held), 0, reason: '${sample.animation} ${sample.activity}: no umbrella');
      }
    });

    testWidgets('nothing without a taskbar stroll (standing on the desktop), whatever the weather', (tester) async {
      Future<Uint8List> standingOnDesktop(bool umbrella) async {
        final key = GlobalKey();
        final up = ValueNotifier(umbrella);
        addTearDown(up.dispose);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(300, 80);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(size: Size(300, 80)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  height: 80,
                  child: RepaintBoundary(
                    key: key,
                    child: MochiView(
                      world: t.desktop.world,
                      sessions: t.desktop.sessions,
                      lastActivity: () => t.desktop.sessions.now,
                      time: () => 2.0,
                      umbrella: up,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        return (await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return data!.buffer.asUint8List();
        }))!;
      }

      expect(differences(await standingOnDesktop(false), await standingOnDesktop(true)), 0);
    });
  });

  group('Morning coffee with Patch', () {
    late DateTime now;
    late double seconds;
    late TestDesktop t;
    late DesktopMoods moods;
    var patchHere = true;

    setUp(() {
      now = DateTime(2026, 11, 24, 7, 30);
      seconds = 1000;
      patchHere = true;
      t = TestDesktop.make(clock: () => now, uptime: () => seconds, activity: const SystemActivity(idleSeconds: 1));
      t.desktop.rhythm.sample();
      t.desktop.settings.companionVisibility = CompanionVisibility.always;
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
    });

    tearDown(() async {
      moods.dispose();
      t.desktop.mischief.stop();
      await t.dispose();
    });

    void later(Duration by) {
      final steps = (by.inMilliseconds / 250).ceil();
      for (var i = 0; i < steps; i++) {
        now = now.add(const Duration(milliseconds: 250));
        seconds += 0.25;
        t.desktop.world.tick();
      }
    }

    DesktopMoods open() {
      moods = DesktopMoods(
        settings: t.desktop.settings,
        world: t.desktop.world,
        rhythm: t.desktop.rhythm,
        gate: t.desktop.mischief,
        patchOnTaskbar: () => patchHere,
        clock: () => now,
      );
      t.desktop.mischief.start();
      moods.start();
      return moods;
    }

    bool coffee() => t.desktop.world.world.interaction?.id == InteractionID.coffeeDelivery;

    /// Patch is at his desk and nothing is going on.
    void settle() => later(const Duration(seconds: 20));

    test('the first time you are at the PC in the morning, Mochi brings Patch his coffee; the day is remembered', () {
      settle();
      expect(t.desktop.world.world.companionPresent, isTrue);
      open();
      expect(coffee(), isTrue, reason: 'launch, 07:30, Patch on the taskbar, both free');
      expect(t.desktop.settings.coffeeDay, '2026-11-24');
    });

    test('once a day, across restarts: the same day again does nothing, the next day does', () {
      settle();
      open();
      expect(coffee(), isTrue);
      later(const Duration(seconds: 12));
      expect(coffee(), isFalse, reason: 'the moment is over');
      moods.dispose();
      // A restart the same morning (a new moods over the same settings file).
      open();
      later(const Duration(minutes: 4));
      expect(coffee(), isFalse);
      expect(t.desktop.settings.coffeeDay, '2026-11-24');
      moods.dispose();
      now = DateTime(2026, 11, 25, 9);
      settle();
      open();
      expect(coffee(), isTrue, reason: 'a new day');
      expect(t.desktop.settings.coffeeDay, '2026-11-25');
    });

    test('only between 06:00 and 11:00 local time', () {
      for (final (hour, minute, expected) in [(5, 59, false), (6, 0, true), (10, 59, true), (11, 0, false), (15, 0, false), (23, 30, false)]) {
        t.desktop.settings.coffeeDay = null;
        now = DateTime(2026, 11, 24, hour, minute);
        settle();
        // settle() moves the clock on twenty seconds: keep the minute under test.
        now = DateTime(2026, 11, 24, hour, minute);
        open();
        expect(coffee(), expected, reason: '$hour:$minute');
        moods.dispose();
        t.desktop.mischief.stop();
        later(const Duration(seconds: 12));
      }
    });

    test('only with Patch on the taskbar; it keeps trying for three minutes, then gives up until you are back', () {
      settle();
      patchHere = false;
      open();
      expect(coffee(), isFalse);
      expect(t.desktop.settings.coffeeDay, isNull);
      patchHere = true;
      // (The world's own ambient moments may be playing at a minute's tick: it tries again the next.)
      later(const Duration(minutes: 2));
      expect(t.desktop.settings.coffeeDay, '2026-11-24', reason: 'Patch is on the taskbar now: tried again on the minute');
      later(const Duration(seconds: 12));
      moods.dispose();
      // Gave up after three minutes.
      t.desktop.settings.coffeeDay = null;
      patchHere = false;
      open();
      later(const Duration(minutes: 4));
      patchHere = true;
      later(const Duration(minutes: 3));
      expect(t.desktop.settings.coffeeDay, isNull, reason: 'the three minutes were over');
    });

    test('back from being away counts as arriving', () {
      now = DateTime(2026, 11, 24, 7, 0);
      settle();
      // Launch with the day already done: nothing to bring.
      t.desktop.settings.coffeeDay = '2026-11-24';
      open();
      later(const Duration(minutes: 4));
      t.desktop.settings.coffeeDay = null;
      later(const Duration(minutes: 2));
      expect(t.desktop.settings.coffeeDay, isNull, reason: 'the three minutes after launch are over');
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 600));
      expect(t.desktop.rhythm.away, isTrue);
      later(const Duration(minutes: 2));
      expect(t.desktop.settings.coffeeDay, isNull, reason: 'away: nobody to bring it to');
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1));
      later(const Duration(minutes: 2));
      expect(t.desktop.settings.coffeeDay, '2026-11-24', reason: 'back at the PC in the morning');
    });

    test('only when both are awake and free', () {
      settle();
      // Mochi asleep.
      t.desktop.world.world.petAsleep = true;
      open();
      expect(coffee(), isFalse);
      expect(moods.whyNoCoffee(), 'Mochi is asleep');
      t.desktop.world.world.petAsleep = false;
      // Busy with a moment of its own.
      expect(t.desktop.world.world.startInteraction(InteractionID.ballDistraction), isTrue);
      expect(moods.whyNoCoffee(), 'busy');
      expect(coffee(), isFalse);
      expect(t.desktop.settings.coffeeDay, isNull);
      // Free again: the next minute brings it.
      later(const Duration(minutes: 2));
      expect(t.desktop.settings.coffeeDay, '2026-11-24');
    });

    test('behind its switches: Mischief off, the extra off, quiet mode, paused reactions, nobody watching', () {
      settle();
      for (final (name, setup) in <(String, void Function())>[
        ('Mischief off', () => t.desktop.settings.mischief = const MischiefSettings()),
        ('the extra off', () => t.desktop.settings.mischief = const MischiefSettings(enabled: true).withExtra(MischiefExtra.moods, false)),
        ('quiet mode', () => t.desktop.settings.quietMode = true),
        ('paused reactions', () => t.desktop.settings.pauseReactions = true),
        ('nobody can see the screen', () => t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1, displaysAsleep: true))),
      ]) {
        t.desktop.settings.mischief = const MischiefSettings(enabled: true);
        t.desktop.settings.quietMode = false;
        t.desktop.settings.pauseReactions = false;
        t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1));
        t.desktop.settings.coffeeDay = null;
        setup();
        open();
        expect(coffee(), isFalse, reason: name);
        expect(t.desktop.settings.coffeeDay, isNull, reason: name);
        moods.dispose();
        t.desktop.mischief.stop();
      }
    });
  });

  group('Late at night', () {
    NotificationPreferencesForTest prefs({bool quietMode = false, QuietHours hours = const QuietHours()}) => NotificationPreferencesForTest(quietMode, hours);

    test('quiet hours when they are set; 23:00 to 05:00 when none are', () {
      final none = prefs();
      expect(LateNight.at(none, DateTime(2026, 11, 8, 22, 59)), isFalse);
      expect(LateNight.at(none, DateTime(2026, 11, 8, 23)), isTrue);
      expect(LateNight.at(none, DateTime(2026, 11, 9, 4, 59)), isTrue);
      expect(LateNight.at(none, DateTime(2026, 11, 9, 5)), isFalse);
      expect(LateNight.at(none, DateTime(2026, 11, 8, 14)), isFalse);
      final evening = prefs(hours: const QuietHours(enabled: true, startMinute: 20 * 60, endMinute: 7 * 60));
      expect(LateNight.at(evening, DateTime(2026, 11, 8, 20, 30)), isTrue, reason: 'their hours, not the default ones');
      expect(LateNight.at(evening, DateTime(2026, 11, 8, 23, 30)), isTrue);
      expect(LateNight.at(evening, DateTime(2026, 11, 9, 6)), isTrue);
      expect(LateNight.at(evening, DateTime(2026, 11, 9, 7)), isFalse);
      final day = prefs(hours: const QuietHours(enabled: true, startMinute: 13 * 60, endMinute: 15 * 60));
      expect(LateNight.at(day, DateTime(2026, 11, 8, 23, 30)), isFalse, reason: 'set hours replace the default late night');
      expect(LateNight.at(day, DateTime(2026, 11, 8, 14)), isTrue);
      expect(LateNight.at(prefs(quietMode: true), DateTime(2026, 11, 8, 14)), isTrue, reason: 'quiet mode');
    });

    /// How often each free activity is chosen over [draws] draws.
    Map<StrollActivity, int> counts(bool late, {double idle = 0, int draws = 6000}) {
      final stroller = Stroller(random: Random(7));
      stroller.lateNight = late;
      stroller.place([const StrollLine(100, 1500)], now: 0, x: 400, mode: StrollMode.free, idleSeconds: idle);
      final counts = <StrollActivity, int>{};
      for (var i = 0; i < draws; i++) {
        counts.update(stroller.chooseFreeActivity(), (n) => n + 1, ifAbsent: () => 1);
      }
      return counts;
    }

    test('the Mac’s quiet-hours weights: naps three times as likely, zoomies a quarter, the toys half', () {
      final day = counts(false), night = counts(true);
      double share(Map<StrollActivity, int> counts, StrollActivity activity) => (counts[activity] ?? 0) / counts.values.fold(0, (a, b) => a + b);
      // The weights sum to 12.05 by day and 10.85 at night, so what is unchanged is 1.11 times as likely and the rest scale from that.
      final naps = share(night, StrollActivity.nap) / share(day, StrollActivity.nap);
      expect(naps, inInclusiveRange(2.8, 3.9), reason: 'about three times as many naps');
      final zoomies = share(night, StrollActivity.zoomies) / share(day, StrollActivity.zoomies);
      expect(zoomies, inInclusiveRange(0.2, 0.36), reason: 'a quarter of the zoomies');
      for (final toy in [StrollActivity.ball, StrollActivity.yarn, StrollActivity.butterfly]) {
        final ratio = share(night, toy) / share(day, toy);
        expect(ratio, inInclusiveRange(0.45, 0.66), reason: '$toy: half as often');
      }
      for (final same in [StrollActivity.wander, StrollActivity.sniff]) {
        expect(share(night, same) / share(day, same), inInclusiveRange(1.0, 1.25), reason: '$same carries on, a little more often as the rest shrinks');
      }
    });

    /// What the plan holds over an hour and a half, each segment once, by when it starts.
    List<StrollSegment> plan(bool late, int seed) {
      final stroller = Stroller(random: Random(seed));
      stroller.lateNight = late;
      stroller.place([const StrollLine(100, 1500)], now: 0, x: 400, mode: StrollMode.free);
      final seen = <double, StrollSegment>{};
      for (var now = 0.0; now < 5400; now += 5) {
        stroller.update(now, mode: StrollMode.free);
        for (final segment in stroller.segments) {
          seen[segment.start] = segment;
        }
      }
      return [for (final start in seen.keys.toList()..sort()) seen[start]!];
    }

    test('a nap lasts twice as long and the rests between outings 1.4 times as long late at night', () {
      double napLength(bool late) {
        var total = 0.0, naps = 0;
        for (var seed = 0; seed < 40; seed++) {
          for (final segment in plan(late, seed)) {
            if (segment.animation == PetAnimation.curl && segment.end.isFinite) {
              total += segment.end - segment.start;
              naps++;
            }
          }
        }
        expect(naps, greaterThan(40));
        return total / naps;
      }

      double restLength(bool late) {
        // A rest is the run of segments the stroll marks as resting; its length is what is spent standing or sitting.
        var total = 0.0, rests = 0;
        for (var seed = 0; seed < 40; seed++) {
          StrollActivity? before;
          for (final segment in plan(late, seed)) {
            if (segment.activity == StrollActivity.rest) {
              total += segment.end - segment.start;
              if (before != StrollActivity.rest) rests++;
            }
            before = segment.activity;
          }
        }
        return total / rests;
      }

      expect(napLength(true) / napLength(false), inInclusiveRange(1.7, 2.3));
      expect(restLength(true) / restLength(false), inInclusiveRange(1.25, 1.55));
    });

    test('a yawn among the fidgets late at night, even when you were just here', () {
      int yawns(bool late) {
        var n = 0;
        for (var seed = 0; seed < 40; seed++) {
          n += plan(late, seed).where((segment) => segment.animation == PetAnimation.yawn && segment.activity != StrollActivity.nap).length;
        }
        return n;
      }

      expect(yawns(false), 0, reason: 'by day, with the PC in use, a free Mochi does not yawn');
      expect(yawns(true), greaterThan(10));
    });
  });
}

/// Just enough of the notification settings for [LateNight].
class NotificationPreferencesForTest implements NotificationPreferences {
  NotificationPreferencesForTest(this.quietMode, this.quietHours);

  @override
  final bool quietMode;
  @override
  final QuietHours quietHours;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
