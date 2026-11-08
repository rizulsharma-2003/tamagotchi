// Weather and time moods (docs/SPRINT_2.md X12, Mischief: `MischiefExtra.moods`). Two things, both small:
//
// - Morning coffee with Patch: once a day, the first time you're at the PC between 06:00 and 11:00 local time (at launch,
//   or when you're back from being away), Mochi brings Patch his coffee: mochi_world's `coffeeDelivery` moment, started
//   through the world as its scheduler starts it. Only when Patch is on the taskbar, both are awake and neither is busy,
//   and the day isn't already done; the day is kept in the settings file, so a restart doesn't repeat it. It tries for three
//   minutes after you arrive (once a minute, on the world's own tick) and then gives up until the next arrival.
//
// - An umbrella when it rains (behind a separate "Local weather" switch, off at first): you type a city once; Open-Meteo's
//   geocoding gives its position, and only the city's display name and its position rounded to a tenth of a degree are
//   kept. Every 30 minutes, while the switch is on, a city is set and the screen can be seen, one request asks
//   Open-Meteo for the weather code there (`current=weather_code,is_day`): no key, no account, no identifiers and a
//   generic User-Agent ("Mochi"). A failure is silent: no umbrella, and the next try is the next 30-minute slot. The WMO
//   codes for drizzle, rain, showers and thunderstorms (51–67, 80–82, 95–99) mean rain. [umbrella] says whether Mochi holds
//   one now: it rains, Mischief may run the extra, and the switches are on. The umbrella itself is drawn by the pet's own
//   view (ui/pet/umbrella_art.dart): never part of the synced look, never a shared prop, never on the native stage.
//
// `MOCHI_DESKTOP_WEATHER=rain|clear` forces the weather and skips the network (and the need for a city), for checking.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mochi_world/mochi_world.dart' as w;

import 'desktop_settings.dart';
import 'desktop_world.dart';
import 'mischief.dart';
import 'pc_rhythm.dart';

/// A city found by the geocoding: its display name and its position (not yet rounded).
@immutable
class GeoCity {
  const GeoCity(this.name, this.latitude, this.longitude);

  final String name;
  final double latitude;
  final double longitude;
}

/// Why a city couldn't be set.
enum CityProblem {
  /// Nothing typed.
  empty,

  /// Open-Meteo knows no such place.
  notFound,

  /// Open-Meteo couldn't be reached.
  offline,
}

class DesktopMoods extends ChangeNotifier {
  DesktopMoods({
    required this.settings,
    required this.world,
    required this.rhythm,
    required this.gate,
    this.patchOnTaskbar = _never,
    DateTime Function()? clock,
    http.Client Function()? client,
    this.pace = const Duration(minutes: 30),
    this.forced,
  }) : _clock = clock ?? DateTime.now,
       _client = client ?? http.Client.new;

  final DesktopSettings settings;
  final DesktopWorld world;
  final PcRhythm rhythm;
  final MischiefGate gate;

  /// Patch is on the taskbar now (the stroll knows).
  final bool Function() patchOnTaskbar;
  final DateTime Function() _clock;
  final http.Client Function() _client;

  /// How often the weather is asked for.
  final Duration pace;

  /// Development: the weather is this (`MOCHI_DESKTOP_WEATHER=rain|clear`), with no network.
  final bool? forced;

  static bool _never() => false;

  static const String geocodingHost = 'geocoding-api.open-meteo.com';
  static const String forecastHost = 'api.open-meteo.com';

  /// Open-Meteo gets this and nothing else about this app.
  static const Map<String, String> headers = {'User-Agent': 'Mochi'};

  /// The morning, local time: from 06:00 up to (not including) 11:00.
  static const int morningFrom = 6;
  static const int morningUntil = 11;

  /// After you arrive, the coffee is tried for this long.
  static const Duration coffeeTries = Duration(minutes: 3);

  /// A request waits this long for an answer.
  static const Duration timeout = Duration(seconds: 15);

  // MARK: Pieces

  /// The geocoding request for [name]: only the name goes.
  static Uri geocodingUri(String name) => Uri.https(geocodingHost, '/v1/search', {'name': name, 'count': '1'});

  /// The forecast request for a position (rounded to a tenth of a degree): only the position goes.
  static Uri forecastUri(double latitude, double longitude) => Uri.parse(
    'https://$forecastHost/v1/forecast?latitude=${LocalWeatherSettings.round1(latitude)}&longitude=${LocalWeatherSettings.round1(longitude)}'
    '&current=weather_code,is_day',
  );

  /// WMO weather codes that mean rain: drizzle and rain (51–67), showers (80–82), thunderstorms (95–99).
  static bool isRain(int code) => (code >= 51 && code <= 67) || (code >= 80 && code <= 82) || (code >= 95 && code <= 99);

  /// The city in a geocoding answer (the first result), or null.
  static GeoCity? cityIn(Object? json) {
    if (json is! Map) return null;
    final results = json['results'];
    if (results is! List || results.isEmpty || results.first is! Map) return null;
    final first = results.first as Map;
    final name = first['name'], lat = first['latitude'], lon = first['longitude'];
    if (name is! String || name.isEmpty || lat is! num || lon is! num) return null;
    final country = first['country_code'];
    final shown = country is String && country.isNotEmpty ? '$name, $country' : name;
    return GeoCity(shown.length > 80 ? shown.substring(0, 80) : shown, lat.toDouble(), lon.toDouble());
  }

  /// The weather code in a forecast answer, or null.
  static int? codeIn(Object? json) {
    if (json is! Map) return null;
    final current = json['current'];
    if (current is! Map) return null;
    final code = current['weather_code'];
    return code is num ? code.toInt() : null;
  }

  // MARK: State

  bool _started = false;
  bool _disposed = false;
  bool _raining = false;
  Timer? _weatherTimer;
  DateTime? _nextAsk;
  bool _asking = false;
  LocalWeatherSettings _seenWeather = const LocalWeatherSettings();
  bool _wasAway = false;
  DateTime? _tryUntil;

  /// Requests made so far (tests): the forecast's, and the geocoding's.
  int forecasts = 0;
  int geocodes = 0;

  /// It's raining where the city is (as of the last answer).
  bool get raining => forced ?? _raining;

  /// Mochi holds an umbrella now: it rains, the extra and (unless forced) Local weather are on, and Mischief may run it.
  final ValueNotifier<bool> umbrella = ValueNotifier(false);

  /// The weather is being asked for on a timer (tests: not while the switches are off, nobody can see the screen or there's
  /// no city).
  bool get watching => _weatherTimer != null;

  bool get _wanted => settings.mischief.allows(MischiefExtra.moods) && settings.weather.ready && !rhythm.unseen;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _seenWeather = settings.weather;
    settings.addListener(_settingsChanged);
    gate.addListener(_updateUmbrella);
    gate.onStop(_gateStopped);
    rhythm.addListener(_rhythmChanged);
    world.everyMinute(_minute);
    _wasAway = rhythm.away ?? false;
    _arm();
    _planWeather();
    _updateUmbrella();
  }

  void _gateStopped() {
    if (_disposed) return;
    _weatherTimer?.cancel();
    _weatherTimer = null;
    umbrella.value = false;
  }

  void _settingsChanged() {
    final next = settings.weather;
    if (next.city != _seenWeather.city || next.latitude != _seenWeather.latitude || next.longitude != _seenWeather.longitude) {
      // Another city: the old answer is no good.
      _raining = false;
      _nextAsk = null;
      _weatherTimer?.cancel();
      _weatherTimer = null;
    }
    if (!next.enabled) _raining = false;
    _seenWeather = next;
    _planWeather();
    _updateUmbrella();
    _attemptCoffee();
  }

  void _rhythmChanged() {
    final away = rhythm.away ?? false;
    if (_wasAway && !away) _arm();
    _wasAway = away;
    _planWeather();
  }

  // MARK: The umbrella

  void _updateUmbrella() {
    final on = _started && !_disposed && raining && gate.may(MischiefExtra.moods) && (forced != null || settings.weather.ready);
    if (umbrella.value != on) umbrella.value = on;
  }

  /// Looks at the weather again when the switches, the city or the screen change: a timer for the next 30-minute slot while
  /// it's wanted (and asking at once when that's due), none otherwise.
  void _planWeather() {
    if (!_started || _disposed || forced != null || !_wanted || !gate.started) {
      _weatherTimer?.cancel();
      _weatherTimer = null;
      return;
    }
    if (_weatherTimer != null) return;
    final next = _nextAsk;
    final wait = next == null ? Duration.zero : next.difference(_clock());
    _weatherTimer = Timer(wait.isNegative ? Duration.zero : wait, _ask);
  }

  Future<void> _ask() async {
    _weatherTimer = null;
    if (_disposed || !_wanted || _asking) return;
    final weather = settings.weather;
    _asking = true;
    forecasts++;
    var rain = false;
    final client = _client();
    try {
      final response = await client.get(forecastUri(weather.latitude!, weather.longitude!), headers: headers).timeout(timeout);
      if (response.statusCode == 200) {
        final code = codeIn(jsonDecode(utf8.decode(response.bodyBytes)));
        rain = code != null && isRain(code);
      }
    } on Object {
      // Silent: no umbrella, and the next try is the next slot.
    } finally {
      client.close();
      _asking = false;
    }
    if (_disposed) return;
    _raining = rain;
    _nextAsk = _clock().add(pace);
    _updateUmbrella();
    notifyListeners();
    _planWeather();
  }

  /// Settings' "Set": looks [name] up (one request: only the name goes), keeps its display name and its position rounded to a
  /// tenth of a degree, and asks for the weather there. Null when it worked.
  Future<CityProblem?> setCity(String name) async {
    final typed = name.trim();
    if (typed.isEmpty) return CityProblem.empty;
    geocodes++;
    final client = _client();
    GeoCity? found;
    try {
      final response = await client.get(geocodingUri(typed), headers: headers).timeout(timeout);
      if (response.statusCode != 200) return CityProblem.offline;
      found = cityIn(jsonDecode(utf8.decode(response.bodyBytes)));
    } on Object {
      return CityProblem.offline;
    } finally {
      client.close();
    }
    if (found == null) return CityProblem.notFound;
    if (_disposed) return null;
    settings.weather = settings.weather.withCity(found.name, found.latitude, found.longitude);
    return null;
  }

  /// Settings' "Forget": the city is dropped.
  void forgetCity() => settings.weather = settings.weather.withoutCity();

  // MARK: Morning coffee

  /// You've just arrived (launch, or back from away): the coffee is tried for the next few minutes.
  void _arm() {
    _tryUntil = _clock().add(coffeeTries);
    _attemptCoffee();
  }

  void _minute() {
    if (_disposed) return;
    _attemptCoffee();
  }

  /// "2026-11-08".
  static String dayOf(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// Why the coffee can't be brought now, or null: it can.
  String? whyNoCoffee() {
    final now = _clock();
    if (!_started || _disposed) return 'stopped';
    if (!gate.may(MischiefExtra.moods)) return 'gate';
    if (now.hour < morningFrom || now.hour >= morningUntil) return 'not morning';
    if (settings.coffeeDay == dayOf(now)) return 'done today';
    if (rhythm.away == true) return 'away';
    if (!patchOnTaskbar()) return 'no Patch on the taskbar';
    final mochi = world.world;
    if (!mochi.companionPresent || mochi.companion.current.animation == w.CompanionAnimation.absent || mochi.companion.base == w.CompanionAnimation.sleep) {
      return 'Patch is not up';
    }
    if (world.asleep || mochi.petAsleep) return 'Mochi is asleep';
    if (world.reacting || mochi.pet.isPlayingOneShot || mochi.companion.isPlayingOneShot || mochi.adventureActive) return 'busy';
    return null;
  }

  void _attemptCoffee() {
    final until = _tryUntil;
    if (until == null) return;
    if (!_clock().isBefore(until)) {
      _tryUntil = null;
      return;
    }
    if (whyNoCoffee() != null) return;
    if (world.world.startInteraction(w.InteractionID.coffeeDelivery)) {
      settings.coffeeDay = dayOf(_clock());
      _tryUntil = null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _weatherTimer?.cancel();
    if (_started) {
      settings.removeListener(_settingsChanged);
      gate.removeListener(_updateUmbrella);
      rhythm.removeListener(_rhythmChanged);
    }
    umbrella.dispose();
    super.dispose();
  }
}
