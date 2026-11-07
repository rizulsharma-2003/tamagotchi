import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The app's own small files, in its private files folder (backed up nowhere; see the manifest).
abstract final class AppFiles {
  /// What you marked done ([DoneMarks]).
  static const String done = 'done.json';

  /// The week of "Waiting for you" ([UpdatesHistory]).
  static const String history = 'updates.json';

  /// The platform of the computer last seen in the room.
  static const String host = 'link_host.json';

  /// Appearance and voice.
  static const String settings = 'settings.json';

  /// What notification buttons pressed while the app was closed left for it ([NotificationOutbox]).
  static const String outbox = 'notification_actions.json';

  /// The folder, from any isolate: path_provider's support folder is Android's `Context.getFilesDir()`, the same
  /// folder MainActivity reports, so the app and its background handlers share these files.
  static Future<String?> folder() async {
    try {
      return (await getApplicationSupportDirectory()).path;
    } on Object {
      return null;
    }
  }

  /// [name] in [folder]; in memory when the folder isn't known.
  static LocalDocument document(String? folder, String name) => folder == null ? MemoryDocument() : FileDocument(File('$folder/$name'));
}

/// A small JSON document the app keeps for itself (what you marked done). Not secret: the room key and credential
/// live in [CredentialStore].
abstract interface class LocalDocument {
  Future<Map<String, Object?>?> read();

  Future<void> write(Map<String, Object?> json);

  Future<void> delete();
}

/// A file in the app's private folder.
class FileDocument implements LocalDocument {
  FileDocument(this.file);

  final File file;

  @override
  Future<Map<String, Object?>?> read() async {
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map ? json.cast<String, Object?>() : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(Map<String, Object?> json) async {
    // Its own temporary name: the app and a background handler may write at the same moment.
    final temporary = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await temporary.writeAsString(jsonEncode(json), flush: true);
    await temporary.rename(file.path);
  }

  @override
  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }
}

/// For tests, and when the files folder isn't known.
class MemoryDocument implements LocalDocument {
  MemoryDocument([this.json]);

  Map<String, Object?>? json;

  @override
  Future<Map<String, Object?>?> read() async => json;

  @override
  Future<void> write(Map<String, Object?> json) async => this.json = jsonDecode(jsonEncode(json)) as Map<String, Object?>;

  @override
  Future<void> delete() async => json = null;
}
