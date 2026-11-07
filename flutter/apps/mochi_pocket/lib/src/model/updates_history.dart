import 'package:mochi_link/mochi_link.dart';

import '../services/local_file.dart';

/// One update as this phone first saw it (Swift `UpdatesStore.Entry`).
class HistoryEntry {
  HistoryEntry({required this.note, required this.firstSeen});

  /// Its latest words: a known item that comes again with new ones takes them.
  AgentNote note;

  /// When it first reached this phone (Unix time).
  final double firstSeen;

  String get id => note.id;

  Map<String, Object?> toJson() => {'note': note.toJson(), 'firstSeen': firstSeen};

  static HistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final note = AgentNote.fromJson(json['note']);
    final firstSeen = json['firstSeen'];
    if (note == null || firstSeen is! num) return null;
    return HistoryEntry(note: note, firstSeen: firstSeen.toDouble());
  }
}

/// One day of earlier updates, newest first.
class HistoryDay {
  const HistoryDay(this.day, this.entries);

  /// Midnight (local time) at the start of the day.
  final DateTime day;
  final List<HistoryEntry> entries;
}

/// Everything "Waiting for you" showed on this phone in the last week (iOS/MochiPocket/UpdatesStore.swift): each item
/// of every card from your computer or Mochi Cloud, with when it first came in. Kept in the app's own files
/// (`updates.json`), next to the done marks. The Updates screen shows it by day under what's waiting now.
class UpdatesHistory {
  UpdatesHistory([List<HistoryEntry>? entries]) : entries = entries ?? [];

  /// Newest first.
  final List<HistoryEntry> entries;

  /// A week, at most 300 items (the iPhone's limits).
  static const double keep = 7 * 86400;
  static const int maxEntries = 300;

  bool get isEmpty => entries.isEmpty;

  HistoryEntry? operator [](String id) => entries.where((entry) => entry.id == id).firstOrNull;

  /// The items of a card: new ones join the history (at the top, in the card's order), known ones get their latest
  /// words. True when anything changed.
  bool record(Iterable<AgentNote> notes, {required double now}) {
    var changed = false;
    final added = <HistoryEntry>[];
    for (final note in notes) {
      final known = this[note.id] ?? added.where((entry) => entry.id == note.id).firstOrNull;
      if (known == null) {
        added.add(HistoryEntry(note: note, firstSeen: now));
      } else if (!_same(known.note, note)) {
        known.note = note;
        changed = true;
      }
    }
    if (added.isNotEmpty) {
      entries.insertAll(0, added);
      changed = true;
    }
    if (changed) prune(now: now);
    return changed;
  }

  /// Takes in what another isolate wrote (the push handler records cards that arrive while the app is closed): the
  /// earliest sighting of each item wins, and this copy's words stay.
  bool merge(UpdatesHistory other, {required double now}) {
    var changed = false;
    for (final entry in other.entries) {
      final index = entries.indexWhere((known) => known.id == entry.id);
      if (index < 0) {
        entries.add(entry);
        changed = true;
      } else if (entry.firstSeen < entries[index].firstSeen) {
        entries[index] = HistoryEntry(note: entries[index].note, firstSeen: entry.firstSeen);
        changed = true;
      }
    }
    if (changed) {
      _newestFirst(entries);
      prune(now: now);
    }
    return changed;
  }

  /// Drops what's older than a week, and the oldest past 300.
  void prune({required double now}) {
    entries.removeWhere((entry) => now - entry.firstSeen >= keep);
    if (entries.length > maxEntries) entries.removeRange(maxEntries, entries.length);
  }

  /// Earlier updates by day (local time), newest day first and newest first within a day, leaving out [excluding]
  /// (what's waiting on the card now) (Swift `history(excluding:)`).
  List<HistoryDay> days({Set<String> excluding = const {}}) {
    final byDay = <DateTime, List<HistoryEntry>>{};
    for (final entry in entries) {
      if (excluding.contains(entry.id)) continue;
      final seen = timeOf(entry.firstSeen);
      byDay.putIfAbsent(DateTime(seen.year, seen.month, seen.day), () => []).add(entry);
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final day in days) HistoryDay(day, _newestFirst(byDay[day]!))];
  }

  Map<String, Object?> toJson() => {
    'entries': [for (final entry in entries) entry.toJson()],
  };

  static UpdatesHistory fromJson(Map<String, Object?>? json) {
    final raw = json?['entries'];
    return UpdatesHistory(_newestFirst([if (raw is List) ...raw.map(HistoryEntry.fromJson).whereType<HistoryEntry>()]));
  }

  /// Newest first; items that came in together keep their card's order (a stable sort).
  static List<HistoryEntry> _newestFirst(List<HistoryEntry> entries) {
    final order = {for (final (index, entry) in entries.indexed) entry: index};
    return entries..sort((a, b) {
      final time = b.firstSeen.compareTo(a.firstSeen);
      return time != 0 ? time : order[a]!.compareTo(order[b]!);
    });
  }

  static bool _same(AgentNote a, AgentNote b) => _encoded(a) == _encoded(b);

  static String _encoded(AgentNote note) => note.toJson().toString();
}

/// Adds a card's items to the history kept in [document] (from the push handler, while the app may be closed).
Future<void> recordHistory(LocalDocument document, List<AgentNote> notes, {DateTime? now}) async {
  final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
  final history = UpdatesHistory.fromJson(await document.read());
  if (history.record(notes, now: seconds)) await document.write(history.toJson());
}

/// Unix seconds as local time.
DateTime timeOf(double seconds) => DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
