import 'package:mochi_link/mochi_link.dart';

/// What you've marked done in "Waiting for you" (iOS/MochiPocket/UpdatesStore.swift): your marks here, plus the
/// marks the Mac (`macDone`) and other phones (`phoneDone`) shared, each taken in once, so undoing one here sticks.
/// This phone shares its whole list as `phoneDone`, as the iPhone does.
class DoneMarks {
  DoneMarks({Map<String, double>? done, Map<String, double>? takenIn}) : done = done ?? {}, takenIn = takenIn ?? {};

  /// Item id → when it was marked done (Unix time).
  final Map<String, double> done;

  /// Marks from other devices already taken in.
  final Map<String, double> takenIn;

  static const double keep = 7 * 86400;

  bool isDone(String id) => done.containsKey(id);

  /// Takes in another device's list; true when something new became done.
  bool takeIn(AgentDoneList list, {required double now}) {
    var changed = false;
    for (final entry in list.trimmed(now: DateTime.fromMillisecondsSinceEpoch((now * 1000).round())).ids.entries) {
      if (takenIn.containsKey(entry.key)) continue;
      takenIn[entry.key] = entry.value;
      if (!done.containsKey(entry.key)) {
        done[entry.key] = entry.value;
        changed = true;
      }
    }
    return changed;
  }

  void mark(Iterable<String> ids, {required double now}) {
    for (final id in ids) {
      done.putIfAbsent(id, () => now.roundToDouble());
    }
  }

  void unmark(String id) => done.remove(id);

  /// What this phone shares (`phoneDone`): the newest marks from the last week.
  AgentDoneList shared({required double now}) =>
      AgentDoneList(ids: done).trimmed(now: DateTime.fromMillisecondsSinceEpoch((now * 1000).round()));

  /// Drops marks older than a week.
  void prune({required double now}) {
    done.removeWhere((_, at) => now - at >= keep);
    takenIn.removeWhere((_, at) => now - at >= keep);
  }

  Map<String, Object?> toJson() => {'done': done, 'takenIn': takenIn};

  static DoneMarks fromJson(Map<String, Object?>? json) {
    Map<String, double> marks(Object? raw) => {
      if (raw is Map)
        for (final entry in raw.entries)
          if (entry.value is num) '${entry.key}': (entry.value as num).toDouble(),
    };
    return DoneMarks(done: marks(json?['done']), takenIn: marks(json?['takenIn']));
  }
}
