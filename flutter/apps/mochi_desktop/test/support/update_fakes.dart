// Test doubles for Mochi's updates and "Install Mochi": a signed release made in the test (its own Ed25519 key, a
// real zip), the relay's feed, the processes the helper starts, and the Windows calls an install makes. Everything
// happens in a temporary folder.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mochi_desktop/src/update/self_install.dart';
import 'package:mochi_desktop/src/update/update_feed.dart';
import 'package:mochi_desktop/src/update/update_manifest.dart';
import 'package:mochi_desktop/src/update/update_signing.dart';
import 'package:mochi_desktop/src/update/updater.dart';
import 'package:mochi_wire/mochi_wire.dart';

final String sep = Platform.pathSeparator;

/// The helper's file name on this system.
final String helperName = Platform.isWindows ? 'mochi_hook.exe' : 'mochi_hook';

/// The release key of these tests (fixed, so failures are repeatable) and another one.
final List<int> releaseSeed = List.generate(32, (i) => i + 1);
final List<int> otherSeed = List.generate(32, (i) => 200 - i);

/// A zip of Mochi's app folder (inside a `Mochi/` folder, as scripts/release-windows.sh makes it).
List<int> appZip(String version, {bool withExe = true, bool topFolder = true}) {
  final archive = Archive();
  final prefix = topFolder ? 'Mochi/' : '';
  if (withExe) archive.addFile(ArchiveFile.string('${prefix}Mochi.exe', 'Mochi $version'));
  archive.addFile(ArchiveFile.string('$prefix$helperName', 'helper $version'));
  archive.addFile(ArchiveFile.string('${prefix}data/app.so', 'app $version'));
  archive.addFile(ArchiveFile.bytes('${prefix}data/flutter_assets/blob.bin', List.generate(3000, (i) => i % 256)));
  return ZipEncoder().encodeBytes(archive);
}

/// A release as the release script publishes it: the zip, its manifest and the manifest's signature.
class Release {
  Release._(this.manifest, this.bytes, this.signature, this.zip);

  final UpdateManifest manifest;

  /// The manifest's exact bytes.
  final List<int> bytes;
  final String signature;
  final List<int> zip;

  SignedManifest get signed => SignedManifest(bytes, signature);

  static Future<Release> make({
    String version = '0.2.0',
    int build = 2,
    List<int>? seed,
    List<int>? zip,
    String? sha256,
    String notes = 'Mochi keeps itself up to date.',
    String? minWindows,
  }) async {
    final file = zip ?? appZip(version);
    final manifest = UpdateManifest(
      version: version,
      build: build,
      file: 'Mochi-$version-windows-x64.zip',
      size: file.length,
      sha256: sha256 ?? await sha256Of(file),
      notes: notes,
      publishedAt: DateTime.utc(2026, 11, 7, 12),
      minWindows: minWindows,
    );
    final bytes = manifest.encode();
    return Release._(manifest, bytes, await UpdateSigning.sign(bytes, seed ?? releaseSeed), file);
  }
}

Future<String> sha256Of(List<int> bytes) async {
  final folder = Directory.systemTemp.createTempSync('mochi_sha');
  try {
    final file = File('${folder.path}${sep}x')..writeAsBytesSync(bytes);
    return await UpdateSigning.sha256OfFile(file.path);
  } finally {
    folder.deleteSync(recursive: true);
  }
}

/// The relay's update feed.
class FakeFeed implements UpdateFeed {
  SignedManifest? answer;
  Object? manifestError;
  final Map<String, List<int>> files = {};
  Object? downloadError;

  /// While set, a download waits for it (to look at "Downloading…").
  Completer<void>? hold;
  int manifests = 0;
  int downloads = 0;

  void publish(Release release) {
    answer = release.signed;
    files[release.manifest.file] = release.zip;
  }

  @override
  Future<SignedManifest> manifest() async {
    manifests++;
    final error = manifestError;
    if (error != null) throw error;
    final signed = answer;
    if (signed == null) throw const UpdateFeedException('Nothing has been published yet.', status: 404);
    return signed;
  }

  @override
  Future<void> download(String name, String target, {required int size, void Function(int received)? progress}) async {
    downloads++;
    final error = downloadError;
    if (error != null) throw error;
    final bytes = files[name]!;
    progress?.call(bytes.length ~/ 2);
    final wait = hold;
    if (wait != null) await wait.future;
    File(target)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    progress?.call(bytes.length);
  }
}

/// The processes the app and helper start (none really).
class FakeProcesses implements ProcessControl {
  final List<({String exe, List<String> arguments, String? workingDirectory})> launched = [];
  Object? failLaunch;

  @override
  bool waitForExit(int pid, Duration timeout) => true;

  @override
  String? executablePath(int pid) => null;

  @override
  bool terminate(int pid) => true;

  @override
  Future<void> launch(String executable, List<String> arguments, {String? workingDirectory}) async {
    final error = failLaunch;
    if (error != null) throw error;
    launched.add((exe: executable, arguments: arguments, workingDirectory: workingDirectory));
  }
}

/// The Start menu and HKEY_CURRENT_USER in memory.
class FakeInstallSystem implements InstallSystem {
  final List<({String path, String target, String workingDirectory, String appUserModelId})> shortcuts = [];
  final Map<String, Map<String, Object>> keys = {};
  bool refuse = false;

  @override
  void createShortcut({
    required String path,
    required String target,
    required String workingDirectory,
    required String description,
    required String appUserModelId,
  }) {
    if (refuse) throw const InstallException("Windows didn't let Mochi save the shortcut.");
    shortcuts.add((path: path, target: target, workingDirectory: workingDirectory, appUserModelId: appUserModelId));
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('lnk -> $target ($appUserModelId)');
  }

  @override
  void writeUninstallEntry(String key, Map<String, Object> values) {
    if (refuse) throw const InstallException("Windows didn't let Mochi add itself to Settings › Apps.");
    (keys[key] ??= {}).addAll(values);
  }

  @override
  void deleteUninstallEntry(String key) => keys.remove(key);

  @override
  String? readUninstallValue(String key, String name) => keys[key]?[name] as String?;
}

/// A temporary PC: Mochi's data folder, an install folder, and the update files.
class UpdateRig {
  UpdateRig() : temp = Directory.systemTemp.createTempSync('mochi_update_test') {
    paths = BridgePaths('${temp.path}${sep}Mochi', windows: Platform.isWindows);
    files = UpdateFiles(paths);
    layout = InstallLayout(
      installDirectory: '${temp.path}${sep}Programs${sep}Mochi',
      startMenuDirectory: '${temp.path}${sep}Start Menu${sep}Programs',
      windows: Platform.isWindows,
    );
    appFolder(layout.installDirectory, '0.1.0');
  }

  final Directory temp;
  late final BridgePaths paths;
  late final UpdateFiles files;
  late final InstallLayout layout;
  final FakeFeed feed = FakeFeed();
  final FakeProcesses processes = FakeProcesses();
  bool autoDownload = true;

  /// The installed copy's exe.
  String get exe => layout.exe;

  Updater updater({
    bool installed = true,
    List<int>? publicKey,
    String? windowsVersion = '10.0.22631',
    int currentBuild = 1,
    String currentVersion = '0.1.0',
  }) => Updater(
    files: files,
    layout: layout,
    installed: installed,
    currentVersion: currentVersion,
    currentBuild: currentBuild,
    feed: feed,
    publicKey: publicKey ?? releasePublicKey,
    autoDownload: () => autoDownload,
    windowsVersion: windowsVersion,
    unzip: const ArchiveUnzipper(background: false),
    processes: processes,
    helper: () => '${layout.installDirectory}$sep$helperName',
    processId: () => 4242,
    clock: () => DateTime(2026, 11, 7, 10, 42),
    firstCheckAfter: const Duration(days: 1),
    checkEvery: const Duration(days: 2),
    hashInBackground: false,
  );

  void dispose() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

/// The release key's public half (set by [loadReleaseKey]).
late List<int> releasePublicKey;

Future<void> loadReleaseKey() async => releasePublicKey = await UpdateSigning.publicKey(releaseSeed);

/// A folder that looks like Mochi's app folder.
void appFolder(String path, String version) {
  Directory('$path${sep}data').createSync(recursive: true);
  File('$path${sep}Mochi.exe').writeAsStringSync('Mochi $version');
  File('$path$sep$helperName').writeAsStringSync('helper $version');
  File('$path${sep}data${sep}app.so').writeAsStringSync('app $version');
}

String read(String path) => File(path).readAsStringSync();

Map<String, Object?> readJson(String path) => (jsonDecode(read(path)) as Map).cast<String, Object?>();
