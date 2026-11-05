import 'dart:convert';
import 'dart:io';

/// The repository's `link-spec` folder (vectors and fixtures shared with Swift, the relay and Mochi Cloud), found
/// by walking up from where the tests run.
Directory specDirectory() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = Directory('${dir.path}/link-spec');
    if (File('${candidate.path}/vectors.json').existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('link-spec/ not found above ${Directory.current.path}');
    dir = parent;
  }
}

Map<String, Object?> readJson(String path) => (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

/// This package's own test fixtures.
File packageFixture(String name) {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/pubspec.yaml').existsSync() || !Directory('${dir.path}/lib').existsSync()) {
    dir = dir.parent;
  }
  return File('${dir.path}/test/fixtures/$name');
}
