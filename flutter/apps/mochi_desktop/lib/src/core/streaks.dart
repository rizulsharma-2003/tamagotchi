// Streaks for the fireworks (docs/SPRINT_2.md X10): how many days in a row Claude Code has been busy on this PC, counted
// from real, live hook events (never late, simulated or restored ones), and the days that reach a milestone (3, 5, 7,
// 10, 14, 21, 30… in a row). The count starts from the recap's streak (a week of history at most) and carries on in
// `streaks.json` in Mochi's folder, so a milestone is reached once, whenever Mochi was restarted.

import 'dart:async';

import 'package:mochi_world/mochi_world.dart' as w;

import 'json_store.dart';

class StreakWatch {
  StreakWatch({required this.store, required int Function() recapStreak, DateTime Function()? clock, w.WorldCalendar calendar = const w.WorldCalendar.local()})
    : _recapStreak = recapStreak,
      _clock = clock ?? DateTime.now,
      _calendar = calendar {
    final saved = store.read();
    if (saved is Map) {
      _lastDay = saved['lastDay'] is int ? saved['lastDay'] as int : null;
      _count = saved['count'] is int ? saved['count'] as int : 0;
      _celebrated = saved['celebrated'] is int ? saved['celebrated'] as int : null;
    }
  }

  /// Days in a row that get fireworks.
  static const Set<int> milestones = {3, 5, 7, 10, 14, 21, 30, 50, 75, 100, 150, 200, 250, 300, 365, 500, 730, 1000};

  /// Where the count is kept (`streaks.json`).
  final JsonStore store;
  final int Function() _recapStreak;
  final DateTime Function() _clock;
  final w.WorldCalendar _calendar;

  int? _lastDay;
  int _count = 0;
  int? _celebrated;

  final StreamController<int> _reached = StreamController.broadcast(sync: true);

  /// A milestone reached today: the days in a row.
  Stream<int> get reached => _reached.stream;

  /// Days in a row up to the last active one.
  int get count => _count;

  /// A real event from Mochi's world (the recap's journal got it too): the first live one of a day counts the day.
  void observe(w.CompanionEvent event) {
    if (event.delivery != w.EventDelivery.live) return;
    final today = _calendar.dayNumber(_clock());
    final last = _lastDay;
    if (last == today) return;
    if (last == null) {
      // The first time: the recap knows the last week (today included, now that today's event is in its journal).
      _count = _recapStreak().clamp(1, 1 << 20);
    } else {
      _count = last == today - 1 ? _count + 1 : 1;
    }
    _lastDay = today;
    final reached = milestones.contains(_count) && _celebrated != today;
    if (reached) _celebrated = today;
    _save();
    if (reached && !_reached.isClosed) _reached.add(_count);
  }

  void _save() {
    try {
      store.write({'lastDay': _lastDay, 'count': _count, 'celebrated': _celebrated});
    } on Object {
      // A streak is only for the fireworks.
    }
  }

  void dispose() => unawaited(_reached.close());
}
