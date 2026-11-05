import 'dart:convert';
import 'dart:io';

import 'bridge_paths.dart';

/// What [EventSpool.drain] took out of the spool.
class SpoolDrain {
  const SpoolDrain(this.lines, this.dropped);

  final List<String> lines;

  /// Events thrown away because the spool was full.
  final int dropped;
}

/// A small bounded journal of events the helper couldn't deliver because the app wasn't running (Swift `EventSpool`).
/// The app drains it at launch and treats those events as late: they update the sessions but never play reactions.
/// Summaries are never spooled (the helper strips them first).
abstract final class EventSpool {
  static const int maxBytes = 512 * 1024;
  static const String _droppedPrefix = '{"spoolDropped":';

  /// Appends one line (with its newline). When the spool is full the oldest half is dropped and counted in a marker
  /// line, so the app can say how many it missed. False when it couldn't write.
  static bool append(String line, String path, {int maxBytes = maxBytes}) {
    final bytes = utf8.encode(line.endsWith('\n') ? line : '$line\n');
    if (bytes.length >= maxBytes ~/ 4) return false;
    final file = File(path);
    if (!BridgePaths.ensurePrivateDirectory(file.parent.path)) return false;
    final created = !file.existsSync();
    RandomAccessFile? handle;
    try {
      handle = file.openSync(mode: FileMode.append);
      if (created) BridgePaths.restrict(path);
      handle.lockSync(FileLock.blockingExclusive);
      final size = handle.lengthSync();
      if (size + bytes.length > maxBytes) {
        handle.setPositionSync(0);
        final existing = utf8.decode(handle.readSync(size), allowMalformed: true);
        var dropped = 0;
        final kept = <String>[];
        for (final item in existing.split('\n')) {
          if (item.isEmpty) continue;
          final marker = droppedCount(item);
          if (marker != null) {
            dropped += marker;
          } else {
            kept.add(item);
          }
        }
        final remove = kept.isEmpty ? 0 : (kept.length ~/ 2).clamp(1, kept.length);
        dropped += remove;
        final rebuilt = StringBuffer('$_droppedPrefix$dropped}\n');
        for (final item in kept.skip(remove)) {
          rebuilt.write('$item\n');
        }
        handle.truncateSync(0);
        handle.setPositionSync(0);
        handle.writeFromSync(utf8.encode(rebuilt.toString()));
      }
      handle.setPositionSync(handle.lengthSync());
      handle.writeFromSync(bytes);
      return true;
    } on FileSystemException {
      return false;
    } finally {
      try {
        handle?.unlockSync();
      } on FileSystemException {
        // Closing releases it anyway.
      }
      handle?.closeSync();
    }
  }

  /// Reads and empties the spool, safely against a helper appending at the same moment.
  static SpoolDrain drain(String path) {
    final file = File(path);
    if (!file.existsSync()) return const SpoolDrain([], 0);
    RandomAccessFile? handle;
    try {
      handle = file.openSync(mode: FileMode.append);
      handle.lockSync(FileLock.blockingExclusive);
      final size = handle.lengthSync();
      if (size == 0) return const SpoolDrain([], 0);
      handle.setPositionSync(0);
      final text = utf8.decode(handle.readSync(size.clamp(0, maxBytes * 2)), allowMalformed: true);
      handle.truncateSync(0);
      final lines = <String>[];
      var dropped = 0;
      for (final item in text.split('\n')) {
        if (item.trim().isEmpty) continue;
        final marker = droppedCount(item);
        if (marker != null) {
          dropped += marker;
        } else {
          lines.add(item);
        }
      }
      return SpoolDrain(lines, dropped);
    } on FileSystemException {
      return const SpoolDrain([], 0);
    } finally {
      try {
        handle?.unlockSync();
      } on FileSystemException {
        // Closing releases it anyway.
      }
      handle?.closeSync();
    }
  }

  static int? droppedCount(String line) {
    if (!line.startsWith(_droppedPrefix)) return null;
    try {
      final json = jsonDecode(line);
      final count = json is Map ? json['spoolDropped'] : null;
      return count is int ? count : null;
    } on FormatException {
      return null;
    }
  }
}
