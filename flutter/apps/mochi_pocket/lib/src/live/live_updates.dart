import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';

import '../services/local_file.dart';
import 'live_notifier.dart';
import 'live_update_view.dart';

/// What happened to one Live Activity update.
enum LiveOutcome {
  /// Shown, or updated in place.
  shown,

  /// The computer ended it: it stays, without its timer, until the dismissal time.
  ended,

  /// Taken away (an end whose dismissal time has passed, End It on the computer, or the setting turned off).
  removed,

  /// Already handled: the same update by push and on the socket, or an older one arriving after a newer one.
  duplicate,

  /// From long ago (a push held while the phone was offline): Claude has moved on since.
  stale,

  /// You swiped this turn's notification away: it comes back for Claude's next turn, or when Claude needs you.
  dismissed,

  /// An update for a notification that isn't showing, and nothing to start one for (Claude finished or is idle).
  notStarted,

  /// "Show Mochi on my lock screen" is off.
  off,

  /// Notifications are turned off for Mochi.
  blocked,
}

/// What this phone remembers about the notification (`live_update.json`, shared by the app and the push handler).
class LiveRecord {
  LiveRecord({
    this.timestamp,
    this.lastId,
    this.showing = false,
    this.since,
    this.phase,
    this.expiresAt,
    this.dismissedSince,
    this.handledEndAt,
    this.view,
  });

  /// The newest update handled (the computer's clock, seconds).
  int? timestamp;
  String? lastId;

  /// This phone posted it and hasn't taken it away.
  bool showing;

  /// The turn or wait it shows began then (seconds).
  double? since;
  String? phase;

  /// It leaves by itself then (seconds) if no update comes.
  double? expiresAt;

  /// You swiped away the notification of the turn that began then: updates for it stay away.
  double? dismissedSince;

  /// The newest `activityEnded` from the computer that was followed.
  double? handledEndAt;

  /// What it shows, to end it from an `activityEnded`.
  Map<String, Object?>? view;

  static LiveRecord fromJson(Map<String, Object?>? json) {
    double? number(Object? value) => value is num ? value.toDouble() : null;
    return LiveRecord(
      timestamp: (json?['timestamp'] as num?)?.toInt(),
      lastId: json?['lastId'] as String?,
      showing: json?['showing'] == true,
      since: number(json?['since']),
      phase: json?['phase'] as String?,
      expiresAt: number(json?['expiresAt']),
      dismissedSince: number(json?['dismissedSince']),
      handledEndAt: number(json?['handledEndAt']),
      view: (json?['view'] as Map?)?.cast<String, Object?>(),
    );
  }

  Map<String, Object?> toJson() => {
    'timestamp': ?timestamp,
    'lastId': ?lastId,
    'showing': showing,
    'since': ?since,
    'phase': ?phase,
    'expiresAt': ?expiresAt,
    'dismissedSince': ?dismissedSince,
    'handledEndAt': ?handledEndAt,
    'view': ?view,
  };
}

/// Mochi on the lock screen while Claude works (A1): the iPhone's Live Activity, as an ongoing notification. The
/// computer's `liveActivity` updates arrive twice when the app is open (on the socket and by FCM) and once by FCM
/// otherwise; this shows each once, in order, the way the iPhone does:
///
/// - **Updated in place.** A repeat (same id) or anything not newer than the last (the computer's timestamp) is
///   dropped; so is an update from more than [maxAge] ago (Claude has moved on).
/// - **Started** by a start, or by an update while Claude works or waits (a start FCM folded into a later update).
///   An update about a finished or idle turn doesn't start one, as on the iPhone.
/// - **Ended** as on the iPhone: the computer's end keeps it, without its timer, until the dismissal time (three
///   minutes after Claude finished or went idle), or takes it away at once (End It on the computer). An
///   `activityEnded` from the computer does the same when the end push didn't come.
/// - **Swiped away** (Android 14+ lets you): this turn's updates stay away; Claude's next turn, or Claude needing
///   you, brings it back (the Mac's "ended by hand").
/// - **Off** with the setting: nothing is shown, and what's showing goes.
class LiveUpdates {
  LiveUpdates({
    required LiveNotifier notifier,
    required LocalDocument record,
    required Future<bool> Function() enabled,
    DateTime Function()? clock,
  }) : _notifier = notifier,
       _record = record,
       _enabled = enabled,
       _clock = clock ?? DateTime.now;

  final LiveNotifier _notifier;
  final LocalDocument _record;
  final Future<bool> Function() _enabled;
  final DateTime Function() _clock;

  /// The file the app and the push handler share.
  static const String file = 'live_update.json';

  /// A development build's throwaway test room keeps its own (DebugActionRoom).
  static const String debugFile = 'debug_live_update.json';

  /// Older updates are history: a phone that was offline mustn't show a turn that's long over.
  static const Duration maxAge = Duration(minutes: 10);

  /// One update at a time (the socket and the push may bring the same one at once).
  Future<void> _queue = Future.value();

  LiveNotifier get notifier => _notifier;

  Future<T> _serially<T>(Future<T> Function() work) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await work());
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  double get _now => _clock().millisecondsSinceEpoch / 1000;

  Future<LiveRecord> _read() async {
    try {
      return LiveRecord.fromJson(await _record.read());
    } on Object {
      return LiveRecord();
    }
  }

  Future<void> _save(LiveRecord record) async {
    try {
      await _record.write(record.toJson());
    } on Object catch (error) {
      _log('the live update record was not saved (${error.runtimeType})');
    }
  }

  /// Shows, updates or ends the notification for one update from the computer.
  Future<LiveOutcome> handle(LinkLiveActivity activity, {required LinkHostName host}) => _serially(() => _handle(activity, host: host));

  Future<LiveOutcome> _handle(LinkLiveActivity activity, {required LinkHostName host}) async {
    final record = await _read();
    final now = _now;
    if (activity.id.isNotEmpty && activity.id == record.lastId) return LiveOutcome.duplicate;
    final last = record.timestamp;
    if (last != null && activity.timestamp <= last) return LiveOutcome.duplicate;
    record
      ..timestamp = activity.timestamp
      ..lastId = activity.id.isEmpty ? null : activity.id;
    if (!activity.isEnd && now - activity.timestamp > maxAge.inSeconds) {
      await _save(record);
      return LiveOutcome.stale;
    }
    if (!await _enabled()) {
      if (record.showing) await _notifier.cancel(force: true);
      record.showing = false;
      await _save(record);
      return LiveOutcome.off;
    }
    final showing = await _notifier.isShowing();
    if (record.showing && !showing && (record.expiresAt == null || now < record.expiresAt!)) {
      // It was up a moment ago and nothing took it away: you did.
      record.dismissedSince = math.max(record.dismissedSince ?? double.negativeInfinity, record.since ?? now);
    }
    record.showing = showing && record.showing;
    final view = LiveUpdateView.of(activity, host: host, now: _clock());

    if (activity.isEnd) {
      final wasShowing = record.showing;
      record
        ..showing = false
        ..view = null;
      await _save(record);
      if (!wasShowing) {
        await _notifier.cancel(timestamp: activity.timestamp);
        return LiveOutcome.notStarted;
      }
      if ((view.timeoutMs ?? 0) <= 0) {
        await _notifier.cancel(timestamp: activity.timestamp);
        return LiveOutcome.removed;
      }
      return await _notifier.show(view) == LiveUpdatePosted.blocked ? LiveOutcome.blocked : LiveOutcome.ended;
    }

    final dismissedSince = record.dismissedSince;
    if (dismissedSince != null && activity.since <= dismissedSince) {
      await _save(record);
      return LiveOutcome.dismissed;
    }
    if (!record.showing && !activity.isStart && activity.art != 'working' && activity.art != 'waiting') {
      await _save(record);
      return LiveOutcome.notStarted;
    }
    final posted = await _notifier.show(view);
    switch (posted) {
      case LiveUpdatePosted.shown:
        record
          ..showing = true
          ..since = activity.since
          ..phase = activity.art
          ..expiresAt = now + (view.timeoutMs ?? 0) / 1000
          ..view = view.toMap();
        await _save(record);
        return LiveOutcome.shown;
      case LiveUpdatePosted.older:
        // The other isolate showed a newer one first.
        await _save(record);
        return LiveOutcome.duplicate;
      case LiveUpdatePosted.blocked || LiveUpdatePosted.unavailable:
        record.showing = false;
        await _save(record);
        return LiveOutcome.blocked;
    }
  }

  /// The computer ended its Live Activity (`activityEnded`, End It on the Mac or Claude's turn over): as the iPhone's
  /// `followMacEnd`, for when the end push didn't reach this phone. Only the turn that ended (or an older one) goes.
  Future<LiveOutcome?> macEnded(ActivityEnded ended) => _serially(() async {
    final record = await _read();
    if (ended.at <= (record.handledEndAt ?? double.negativeInfinity)) return null;
    record.handledEndAt = ended.at;
    final since = ended.since ?? ended.at;
    if (!record.showing || (record.since ?? 0) > since) {
      await _save(record);
      return null;
    }
    final dismissAt = ended.dismissAt ?? ended.at;
    final left = dismissAt - _now;
    final view = LiveUpdateView.fromMap(record.view);
    record
      ..showing = false
      ..view = null;
    await _save(record);
    if (left <= 0 || view == null || !await _notifier.isShowing()) {
      await _notifier.cancel(force: true);
      return LiveOutcome.removed;
    }
    await _notifier.show(view.ended(timeout: Duration(milliseconds: (left * 1000).round()), force: true));
    return LiveOutcome.ended;
  });

  /// "Show Mochi on my lock screen" turned off: what's showing goes.
  Future<void> turnedOff() => _serially(() async {
    final record = await _read();
    record
      ..showing = false
      ..view = null;
    await _save(record);
    await _notifier.cancel(force: true);
  });

  /// Settings' sample for [phase] (the iPhone's "Show on Lock Screen"): shown for two minutes, whatever came before.
  Future<LiveUpdatePosted> sample(String phase, {required LinkHostName host}) =>
      _notifier.show(LiveUpdateView.sample(phase, host: host, now: _clock()));

  /// Takes the sample (or anything showing) away.
  Future<void> removeSample() => _serially(() async {
    final record = await _read();
    record.showing = false;
    await _save(record);
    await _notifier.cancel(force: true);
  });

  /// After unpairing: nothing from that room stays, and a new room starts afresh.
  Future<void> forget() => _serially(() async {
    await _notifier.cancel(force: true);
    await _notifier.reset();
    try {
      await _record.delete();
    } on Object {
      // Nothing kept.
    }
  });

  static void _log(String message) {
    if (kDebugMode) debugPrint('Mochi: $message');
  }
}
