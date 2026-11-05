import 'dart:convert';
import 'dart:io';

/// Alert ids already shown as notifications, so one alert shows once even when it arrives twice: over the relay
/// socket and as an FCM push, or in the app and in the background isolate that handles pushes.
abstract interface class ShownAlerts {
  Future<bool> contains(String id);

  /// Records [id] as shown. False when it already was (someone else showed it first).
  Future<bool> claim(String id);
}

/// A small JSON file in the app's private folder, `{id: shownAt}`. Operations run one at a time within an isolate, and
/// under an exclusive file lock between processes. (A POSIX lock doesn't exclude isolates of the same process; the
/// rare race left there is covered by [notificationIdFor]: a second copy replaces the first notification.) Keeps
/// two days, at most [maxIds] ids.
class FileShownAlerts implements ShownAlerts {
  FileShownAlerts(this.file, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final File file;
  final DateTime Function() _clock;
  Future<void> _tail = Future.value();

  static const int maxIds = 300;
  static const Duration keep = Duration(days: 2);

  @override
  Future<bool> contains(String id) => _locked((ids) => (ids.containsKey(id), false));

  @override
  Future<bool> claim(String id) => _locked((ids) {
    if (ids.containsKey(id)) return (false, false);
    ids[id] = _clock().millisecondsSinceEpoch ~/ 1000;
    return (true, true);
  });

  /// Runs [change] on the ids, after any operation already running, under the lock; it returns its answer and
  /// whether to write the ids back.
  Future<bool> _locked((bool, bool) Function(Map<String, int> ids) change) {
    final result = _tail.then((_) => _run(change));
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> _run((bool, bool) Function(Map<String, int> ids) change) async {
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.blockingExclusive);
      await handle.setPosition(0);
      final ids = _decode(utf8.decode(await handle.read(await handle.length()), allowMalformed: true));
      final (answer, write) = change(ids);
      if (write) {
        final cutoff = _clock().subtract(keep).millisecondsSinceEpoch ~/ 1000;
        final kept = ids.entries.where((entry) => entry.value >= cutoff).toList()..sort((a, b) => b.value.compareTo(a.value));
        final bytes = utf8.encode(jsonEncode(Map.fromEntries(kept.take(maxIds))));
        await handle.truncate(0);
        await handle.setPosition(0);
        await handle.writeFrom(bytes);
        await handle.flush();
      }
      return answer;
    } finally {
      try {
        await handle.unlock();
      } on FileSystemException {
        // Closing releases the lock anyway.
      }
      await handle.close();
    }
  }

  static Map<String, int> _decode(String text) {
    try {
      final json = jsonDecode(text);
      return {
        if (json is Map)
          for (final entry in json.entries)
            if (entry.value is int) '${entry.key}': entry.value as int,
      };
    } on FormatException {
      return {};
    }
  }
}

/// For tests, and when the files folder isn't known.
class MemoryShownAlerts implements ShownAlerts {
  final Set<String> ids = {};

  @override
  Future<bool> contains(String id) async => ids.contains(id);

  @override
  Future<bool> claim(String id) async => ids.add(id);
}

/// A notification id that's the same for the same alert in every isolate and run (FNV-1a, 31 bits), so a second copy
/// of an alert replaces the first in the shade instead of adding to it.
int notificationIdFor(String alertId) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(alertId)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}
