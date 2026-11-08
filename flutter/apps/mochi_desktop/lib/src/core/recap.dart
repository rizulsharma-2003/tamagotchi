// The daily recap on this PC (Sprint 2 W16), as the Mac's RecapController (Sources/App/Features/Recap) keeps it: a card
// of the day's real Claude Code activity (sessions, turns, tool calls, green builds and tests, errors bounced back,
// focus minutes, the active stretch, milestones and the streak), presented by Mochi and Patch. Every number comes from
// real, live or late hook events and the focus log; nothing simulated, restored or estimated, and the card says when
// the history doesn't reach back far enough.
//
// The events come from Mochi's world (`onRecord`: real events only, never restored ones) into an `EventJournal`, kept a
// week in `journal.json` in Mochi's folder: event names, session ids, project names, tool names and categories,
// build/test outcomes; never paths (the journal drops them), prompts or Claude Code's notification text.
//
// Once a day from the recap hour (18:00), a day with real activity is announced: a note, a line, both characters
// greeting, and a Windows notification for users who turned recap notifications on (it opens the recap). It's checked
// every minute while the screen can be seen (with the world's tick) and 8 seconds after launch.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'desktop_settings.dart';
import 'desktop_world.dart';
import 'focus.dart';
import 'json_store.dart';
import 'notifications.dart' show NotificationPolicy;
import 'toasts.dart';

class DesktopRecap extends ChangeNotifier {
  DesktopRecap({
    required this.settings,
    required this.world,
    required this.focus,
    required this.toasts,
    JsonStore? store,
    DateTime Function()? clock,
    this.retentionDays = 7,
  }) : store = store ?? MemoryJsonStore(),
       _clock = clock ?? DateTime.now {
    launchedAt = _clock();
    journal = w.EventJournal(retentionDays: retentionDays);
    final saved = this.store.read();
    if (saved is List) journal.load(saved, now: launchedAt);
    world.onRecord = record;
    world.everyMinute(check);
    world.savers.add(save);
  }

  final DesktopSettings settings;
  final DesktopWorld world;
  final DesktopFocus focus;
  final ToastService toasts;

  /// Where the week of events is kept (`journal.json`).
  final JsonStore store;

  /// Days of history kept (the Mac's history retention, a week).
  final int retentionDays;
  final DateTime Function() _clock;

  /// When Mochi started (with history off, events only exist from then on).
  late final DateTime launchedAt;

  /// The real events the recap counts (the Mac's EventJournal).
  late final w.EventJournal journal;

  bool _dirty = false;
  Timer? _first;

  /// Where the card tells you to open the recap, on Windows.
  static const String where = 'Open Recap in Mochi’s popover.';

  /// Starts the evening check: 8 seconds after launch, then every minute with the world.
  void start() {
    _first ??= Timer(const Duration(seconds: 8), check);
  }

  /// A real event from Mochi's world (live or late; never simulated or restored).
  void record(w.CompanionEvent event) {
    if (journal.append(event, now: _clock())) {
      _dirty = true;
      notifyListeners();
    }
  }

  /// From when on the history is complete (anything earlier is unknown, not "nothing happened").
  DateTime historyStart([DateTime? now]) => journal.historyStart(now: now ?? _clock(), launchedAt: launchedAt);

  /// The recap of [day] (today by default).
  w.DailyRecap recap([DateTime? day]) {
    final now = _clock();
    return w.DailyRecap.compute(day: day ?? now, events: journal.all, focus: focus.log.blocks, historyStart: historyStart(now));
  }

  /// The earliest day the card can show (the history kept).
  DateTime get earliestDay {
    final now = _clock();
    final start = now.subtract(Duration(days: retentionDays));
    return DateTime(start.year, start.month, start.day);
  }

  /// The evening announcement, once per active day from the recap hour (the Mac's checkEvening).
  void check() {
    final recapSettings = settings.recap;
    final moment = w.RecapSchedule.check(
      now: _clock(),
      settings: recapSettings,
      recapFor: recap,
      world: world.world.settings,
      where: where,
    );
    if (moment == null) return;
    settings.recap = recapSettings;
    _announce(moment);
  }

  /// Shows [moment] in the world; its notification (for users who asked) opens the recap.
  void _announce(w.FeatureMoment moment) {
    final banner = moment.banner;
    world.apply(w.FeatureMoment(toast: moment.toast, line: moment.line, pet: moment.pet, companion: moment.companion, sound: moment.sound));
    if (banner == null || settings.pauseReactions || NotificationPolicy.isQuiet(settings, _clock())) return;
    toasts.show(Toast(title: banner.title, body: banner.body, target: ToastTarget.recap, group: 'recap')).ignore();
  }

  /// Development and tests: the evening announcement now.
  @visibleForTesting
  void announceNow() {
    final today = recap();
    _announce(
      today.announcement(
        petName: settings.petName,
        companionName: settings.companionName,
        showCompanion: settings.companionVisibility != CompanionVisibility.never,
        banner: settings.recap.banner,
        where: where,
      ),
    );
  }

  /// Writes the week of events if something new came in.
  void save() {
    if (!_dirty) return;
    _dirty = false;
    journal.enforceRetention(_clock());
    store.write(journal.toJsonLines());
  }

  @override
  void dispose() {
    _first?.cancel();
    save();
    world.savers.remove(save);
    if (world.onRecord == record) world.onRecord = null;
    super.dispose();
  }
}
