// An update's manifest (docs/SPRINT_2.md W29): what scripts/release-windows.sh publishes on the user's Mochi Link
// relay next to the zip, signed with the release key. Pure Dart (no Flutter): the release tool writes it with the same
// code the app reads it with.

import 'dart:convert';

/// The manifest wasn't one Mochi can use.
class ManifestException implements Exception {
  const ManifestException(this.message);

  final String message;

  @override
  String toString() => 'ManifestException: $message';
}

/// `{version, build, file, size, sha256, notes, publishedAt, minWindows}`. Read only after its signature checked out;
/// even then every field is checked, so a mistake in a release can't send the app somewhere odd.
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.build,
    required this.file,
    required this.size,
    required this.sha256,
    this.notes = '',
    this.publishedAt,
    this.minWindows,
  });

  /// "0.2.0": what people see.
  final String version;

  /// 2: what decides which copy is newer (it only ever grows).
  final int build;

  /// The zip's name on the relay: `Mochi-0.2.0-windows-x64.zip`.
  final String file;

  /// The zip's size in bytes.
  final int size;

  /// The zip's SHA-256, lowercase hex.
  final String sha256;

  /// What's new, in a few lines (shown in Settings › About).
  final String notes;
  final DateTime? publishedAt;

  /// The oldest Windows it runs on, "10.0.17763" (null: any).
  final String? minWindows;

  static final RegExp _version = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}(?:[-+][0-9A-Za-z.-]{1,20})?$');
  static final RegExp _file = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.zip$');
  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _windows = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,6}$');

  /// Bigger than any Mochi zip could be (KV values stop at 25 MiB).
  static const int maxSize = 64 * 1024 * 1024;
  static const int maxNotes = 4000;

  static UpdateManifest parse(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const ManifestException('The manifest is not JSON.');
    }
    if (json is! Map<String, Object?>) throw const ManifestException('The manifest is not a JSON object.');
    final version = json['version'], build = json['build'], file = json['file'], size = json['size'], sha = json['sha256'];
    if (version is! String || !_version.hasMatch(version)) throw const ManifestException('The manifest has no usable version.');
    if (build is! int || build < 1 || build > 999999999) throw const ManifestException('The manifest has no usable build number.');
    if (file is! String || !_file.hasMatch(file)) throw const ManifestException('The manifest names no usable file.');
    if (size is! int || size < 1 || size > maxSize) throw const ManifestException('The manifest has no usable size.');
    if (sha is! String || !_sha256.hasMatch(sha)) throw const ManifestException('The manifest has no usable SHA-256.');
    final notes = json['notes'];
    final published = json['publishedAt'];
    final minWindows = json['minWindows'];
    if (minWindows != null && (minWindows is! String || !_windows.hasMatch(minWindows))) {
      throw const ManifestException('The manifest names no usable Windows version.');
    }
    return UpdateManifest(
      version: version,
      build: build,
      file: file,
      size: size,
      sha256: sha,
      notes: notes is String ? (notes.length > maxNotes ? notes.substring(0, maxNotes) : notes).trim() : '',
      publishedAt: published is String ? DateTime.tryParse(published) : null,
      minWindows: minWindows as String?,
    );
  }

  /// The bytes the release signs: compact JSON in this key order.
  List<int> encode() => utf8.encode(jsonEncode(toJson()));

  Map<String, Object?> toJson() => {
    'version': version,
    'build': build,
    'file': file,
    'size': size,
    'sha256': sha256,
    'notes': notes,
    if (publishedAt != null) 'publishedAt': publishedAt!.toUtc().toIso8601String(),
    'minWindows': ?minWindows,
  };

  /// Whether a Windows of [running] ("10.0.22631") is new enough; true when either is unknown.
  bool runsOn(String? running) {
    final needed = minWindows;
    if (needed == null || running == null) return true;
    final have = _numbers(running), want = _numbers(needed);
    if (have == null || want == null) return true;
    for (var i = 0; i < 3; i++) {
      if (have[i] != want[i]) return have[i] > want[i];
    }
    return true;
  }

  static List<int>? _numbers(String text) {
    final parts = text.split('.').map(int.tryParse).toList();
    if (parts.length != 3 || parts.any((part) => part == null)) return null;
    return parts.cast<int>();
  }

  @override
  String toString() => 'UpdateManifest($version, build $build, $file, $size bytes)';
}

/// "10.0.22631" from dart:io's `Platform.operatingSystemVersion` on Windows (`"Windows 10 Pro" 10.0 (Build 22631)`);
/// null when it doesn't say.
String? windowsVersion(String operatingSystemVersion) {
  final match = RegExp(r'(\d+)\.(\d+)\s*\(Build (\d+)\)').firstMatch(operatingSystemVersion);
  return match == null ? null : '${match[1]}.${match[2]}.${match[3]}';
}
