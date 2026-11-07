import 'package:mochi_link/mochi_link.dart';

/// What you've marked done in "Waiting for you" (iOS/MochiPocket/UpdatesStore.swift): your marks here, plus the
/// marks the Mac (`macDone`) and other phones (`phoneDone`) shared, each taken in once, so undoing one here sticks.
/// This phone shares its whole list as `phoneDone`, as the iPhone does. Each mark remembers where it was made, for
/// the Updates history ("Done on your Mac").
class DoneMarks {
  DoneMarks({Map<String, double>? done, Map<String, double>? takenIn, Map<String, String>? by})
    : done = done ?? {},
      takenIn = takenIn ?? {},
      by = by ?? {};

  /// Item id → when it was marked done (Unix time).
  final Map<String, double> done;

  /// Marks already accounted for: other devices' lists taken in, and this phone's own marks (which come back in
  /// those lists), so undoing one here isn't undone by the next list.
  final Map<String, double> takenIn;

  /// Item id → where it was marked done: [here], [computer], or another phone's device id. Missing for marks made
  /// before this was kept.
  final Map<String, String> by;

  /// Marked on this phone (in the app or from a notification).
  static const String here = 'here';

  /// Marked on the computer (`macDone`).
  static const String computer = 'host';

  static const double keep = 7 * 86400;

  bool isDone(String id) => done.containsKey(id);

  /// When [id] was marked done, if it is.
  double? doneAt(String id) => done[id];

  /// Where [id] was marked done: [here], [computer] or a device id (null when not known).
  String? doneBy(String id) => by[id];

  /// Takes in another device's list ([from]: [computer] for `macDone`, else the phone's device id); true when
  /// something new became done.
  bool takeIn(AgentDoneList list, {required double now, String? from}) {
    var changed = false;
    for (final entry in list.trimmed(now: DateTime.fromMillisecondsSinceEpoch((now * 1000).round())).ids.entries) {
      if (takenIn.containsKey(entry.key)) continue;
      takenIn[entry.key] = entry.value;
      if (!done.containsKey(entry.key)) {
        done[entry.key] = entry.value;
        if (from != null) by[entry.key] = from;
        changed = true;
      }
    }
    return changed;
  }

  /// Marks [ids] done on this phone; ones already done keep their time and place. True when any was new.
  bool mark(Iterable<String> ids, {required double now}) {
    var changed = false;
    for (final id in ids) {
      if (done.containsKey(id)) continue;
      done[id] = now.roundToDouble();
      takenIn.putIfAbsent(id, () => now.roundToDouble());
      by[id] = here;
      changed = true;
    }
    return changed;
  }

  void unmark(String id) {
    done.remove(id);
    by.remove(id);
  }

  /// What this phone shares (`phoneDone`): the newest marks from the last week.
  AgentDoneList shared({required double now}) =>
      AgentDoneList(ids: done).trimmed(now: DateTime.fromMillisecondsSinceEpoch((now * 1000).round()));

  /// Drops marks older than a week.
  void prune({required double now}) {
    done.removeWhere((_, at) => now - at >= keep);
    takenIn.removeWhere((_, at) => now - at >= keep);
    by.removeWhere((id, _) => !done.containsKey(id));
  }

  Map<String, Object?> toJson() => {'done': done, 'takenIn': takenIn, 'by': by};

  static DoneMarks fromJson(Map<String, Object?>? json) {
    Map<String, double> marks(Object? raw) => {
      if (raw is Map)
        for (final entry in raw.entries)
          if (entry.value is num) '${entry.key}': (entry.value as num).toDouble(),
    };
    final rawBy = json?['by'];
    return DoneMarks(
      done: marks(json?['done']),
      takenIn: marks(json?['takenIn']),
      by: {
        if (rawBy is Map)
          for (final entry in rawBy.entries)
            if (entry.value is String) '${entry.key}': entry.value as String,
      },
    );
  }
}
