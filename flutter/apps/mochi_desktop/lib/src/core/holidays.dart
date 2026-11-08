// Holidays on this PC, the rest of them (Sprint 2 W20), as the Mac's SeasonController (Sources/App/Features/Seasons)
// runs them: mochi_world's `SeasonTracker` (its calendar checked against the Mac's for every day of 2025–2030) says
// which occasion is on; this keeps it fresh (at launch, a few seconds later with the greeting, on the hour, at
// midnight, when the screen comes back and when the holiday settings change), greets each occasion once (a line, a
// happy hop and Patch celebrating; the note waits until Mochi's window or popover is open), keeps the occasions
// already greeted in `seasons.json`, and sets what the art draws for it: the treat Mochi gets (candy at Halloween, a
// laddoo at Diwali, gingerbread at Christmas, cake on birthdays, a heart cookie on Valentine's Day), the birthday
// candles, New Year's digits and the little decoration beside Patch's desk on the taskbar. Costumes come with the
// occasion (DesktopSettings.wornByPet and wornByCompanion), for both characters.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mochi_art/mochi_art.dart' show SeasonalTreats, SeasonRenderContext;
import 'package:mochi_world/mochi_world.dart' as w;

import 'desktop_settings.dart';
import 'desktop_world.dart';
import 'json_store.dart';

class DesktopHolidays extends ChangeNotifier {
  DesktopHolidays({required this.settings, required this.world, JsonStore? store, DateTime Function()? clock, bool Function()? decorating})
    : store = store ?? MemoryJsonStore(),
      _clock = clock ?? DateTime.now,
      _decorating = decorating ?? (() => false) {
    tracker = w.SeasonTracker.fromJson(this.store.read());
    _seasonal = settings.worldSeasonal;
    refresh(greet: false);
    world.everyMinute(_minute);
    world.windowShown.add(showPendingToast);
    settings.addListener(_settingsChanged);
  }

  final DesktopSettings settings;
  final DesktopWorld world;

  /// The occasions already greeted (`seasons.json`, the Mac's).
  final JsonStore store;
  final DateTime Function() _clock;
  bool Function() _decorating;

  /// The room is being decorated (W18): a greeting's note waits until it isn't.
  set decorating(bool Function() value) => _decorating = value;

  late final w.SeasonTracker tracker;
  late w.SeasonalSettings _seasonal;
  DateTime? _checked;
  Timer? _greet;

  /// The occasion showing (null: none, or holidays are off).
  w.SeasonalEvent? get event => tracker.event;

  /// A few seconds after launch (once the companion has arrived), the greeting for an occasion not yet greeted.
  void start() {
    _greet ??= Timer(const Duration(seconds: 4), refresh);
  }

  /// Re-reads the calendar: the art for the occasion, and the once-per-occasion greeting ([greet] false at launch).
  void refresh({bool greet = true}) {
    final now = _clock();
    _checked = now;
    final before = tracker.event;
    final moment = tracker.refresh(
      now,
      settings: _seasonal,
      adopted: settings.adoptedAt,
      petName: settings.petName,
      companionName: settings.companionName,
      greet: greet,
    );
    final event = tracker.event;
    SeasonalTreats.style = w.TreatStyle.of(event);
    SeasonRenderContext.decorateMenuBar = _seasonal.decorateMenuBar;
    SeasonRenderContext.newYear = w.SeasonCalendar.newYear(now);
    SeasonRenderContext.candles = w.SeasonDecor.candles(event, adopted: settings.adoptedAt, now: now);
    if (moment != null) {
      store.write(tracker.toJson(now: now));
      world.apply(moment);
      showPendingToast();
    }
    if (event != before) {
      world.noteChanged();
      notifyListeners();
    }
  }

  /// On the hour (and so at midnight), with the world's minute check; and when the screen comes back, at its first.
  void _minute() {
    final now = _clock();
    final last = _checked;
    if (last == null || now.hour != last.hour || now.day != last.day || now.difference(last).abs() >= const Duration(hours: 1)) {
      refresh();
    }
  }

  void _settingsChanged() {
    final next = settings.worldSeasonal;
    if (next == _seasonal) return;
    _seasonal = next;
    refresh();
  }

  /// The greeting's note, once Mochi's window or popover is open and the room isn't being decorated.
  void showPendingToast() {
    final toast = tracker.takePendingToast(windowVisible: world.world.windowVisible, decorating: _decorating());
    if (toast == null) return;
    world.world.showToast(title: toast.title, detail: toast.detail, seconds: toast.seconds);
    world.noteChanged();
  }

  @override
  void dispose() {
    _greet?.cancel();
    world.windowShown.remove(showPendingToast);
    settings.removeListener(_settingsChanged);
    super.dispose();
  }
}
