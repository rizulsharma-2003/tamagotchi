import 'dart:convert';
import 'dart:io';

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
    final temporary = File('${file.path}.tmp');
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
