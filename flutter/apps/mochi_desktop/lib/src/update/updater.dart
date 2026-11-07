// Mochi for Windows keeps itself up to date (docs/SPRINT_2.md W29). At launch and every 6 hours it asks the user's own
// Mochi Link relay for the newest manifest, checks its Ed25519 signature against the release key compiled into the
// app, downloads the zip it names in the background, checks the zip's SHA-256, and unpacks it into Mochi's folder. It
// never interrupts: Mochi says a new version is ready (a speech bubble, "Restart to Update" in the tray), and the copy
// is installed only when you choose to restart it, or at Mochi's next launch. The helper (mochi_hook update) does the
// swap, because nothing in the app folder may be running while it's replaced.
//
// Nothing unverified is ever installed: a manifest without a good signature or a zip with the wrong SHA-256 is thrown
// away and Settings says "Couldn't verify the update".

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'update_feed.dart';
import 'update_manifest.dart';
import 'update_signing.dart';

/// Where an update stands, for Settings › About and the tray.
enum UpdatePhase {
  /// Not on this build (the macOS development build, or a build without the release key).
  unsupported,

  /// Running from somewhere other than the install folder: updates are off.
  notInstalled,

  /// Installed; no check yet.
  idle,
  checking,
  upToDate,

  /// A newer version, not downloaded (automatic downloads are off).
  available,
  downloading,

  /// Checking the download's SHA-256 and unpacking it.
  verifying,

  /// Verified and unpacked: restart to update.
  ready,

  /// A signature or checksum didn't match: the file was thrown away.
  couldNotVerify,

  /// The relay couldn't be reached.
  offline,
  failed,

  /// Handed to the helper; Mochi is quitting.
  applying,
}

/// A verified copy waiting in update\staged (update\ready.json).
class ReadyUpdate {
  const ReadyUpdate({required this.version, required this.build, required this.root, this.notes = ''});

  final String version;
  final int build;

  /// The unpacked folder with Mochi.exe in it.
  final String root;
  final String notes;

  Map<String, Object?> toJson() => {'version': version, 'build': build, 'root': root, 'notes': notes};

  static ReadyUpdate? read(String path) {
    try {
      final json = jsonDecode(File(path).readAsStringSync());
      if (json is! Map) return null;
      final version = json['version'], build = json['build'], root = json['root'], notes = json['notes'];
      if (version is! String || build is! int || root is! String) return null;
      return ReadyUpdate(version: version, build: build, root: root, notes: notes is String ? notes : '');
    } on Object {
      return null;
    }
  }
}

/// Unpacks a zip (package:archive, in a background isolate so Mochi keeps moving).
abstract interface class Unzipper {
  Future<void> extract(String zip, String destination);
}

class ArchiveUnzipper implements Unzipper {
  const ArchiveUnzipper({this.background = true});

  final bool background;

  @override
  Future<void> extract(String zip, String destination) =>
      background ? Isolate.run(() => _extract(zip, destination)) : Future.sync(() => _extract(zip, destination));

  static void _extract(String zip, String destination) {
    final input = InputFileStream(zip);
    try {
      // Entries that would land outside [destination] are skipped by package:archive.
      extractArchiveToDiskSync(ZipDecoder().decodeStream(input), destination);
    } finally {
      input.closeSync();
    }
  }
}

class Updater extends ChangeNotifier {
  Updater({
    required this.files,
    required this.layout,
    required this.installed,
    required this.currentVersion,
    required this.currentBuild,
    this.feed,
    List<int>? publicKey,
    bool Function()? autoDownload,
    this.windowsVersion,
    Unzipper? unzip,
    ProcessControl? processes,
    String? Function()? helper,
    int Function()? processId,
    DateTime Function()? clock,
    this.checkEvery = const Duration(hours: 6),
    this.firstCheckAfter = const Duration(seconds: 20),
    this.supported = true,
    bool hashInBackground = true,
  }) : publicKey = publicKey ?? const [],
       _autoDownload = autoDownload ?? (() => true),
       _unzip = unzip ?? const ArchiveUnzipper(),
       _processes = processes,
       _helper = helper,
       _processId = processId ?? (() => pid),
       _clock = clock ?? DateTime.now,
       _hashInBackground = hashInBackground;

  /// Updates aren't part of this build (the macOS development build, the demo, most tests).
  factory Updater.unsupported() => Updater(
    files: UpdateFiles(BridgePaths(Directory.systemTemp.path)),
    layout: InstallLayout.resolve(windows: false),
    installed: false,
    currentVersion: '',
    currentBuild: 0,
    supported: false,
  );

  final UpdateFiles files;
  final InstallLayout layout;

  /// This copy runs from the install folder.
  final bool installed;
  final String currentVersion;
  final int currentBuild;
  final UpdateFeed? feed;

  /// The release key's public half (32 bytes). Empty: this build can't verify anything, so it installs nothing.
  final List<int> publicKey;

  /// "10.0.22631" (null: unknown).
  final String? windowsVersion;
  final Duration checkEvery;
  final Duration firstCheckAfter;
  final bool supported;
  final bool Function() _autoDownload;
  final Unzipper _unzip;
  final ProcessControl? _processes;
  final String? Function()? _helper;
  final int Function() _processId;
  final DateTime Function() _clock;
  final bool _hashInBackground;

  UpdatePhase _phase = UpdatePhase.idle;
  UpdateManifest? _manifest;
  ReadyUpdate? _ready;
  double? _progress;
  String? _problem;
  DateTime? _checkedAt;
  String? _updatedTo;
  bool _busy = false;
  bool _started = false;
  Timer? _first;
  Timer? _every;

  UpdatePhase get phase => _phase;

  /// The newer version found (null when up to date or not checked).
  UpdateManifest? get manifest => _manifest;

  /// The verified copy waiting to be installed.
  ReadyUpdate? get ready => _ready;

  /// 0–1 while downloading.
  double? get progress => _progress;

  /// What went wrong, in words.
  String? get problem => _problem;
  DateTime? get checkedAt => _checkedAt;

  /// The version this launch was updated to (set when the helper reported success), for "Mochi updated to …".
  String? get updatedTo => _updatedTo;

  /// The version waiting or found, for the status line.
  String? get newVersion => _ready?.version ?? _manifest?.version;

  /// What's new in it.
  String get notes => _ready?.notes ?? _manifest?.notes ?? '';

  bool get canCheck => supported && installed && publicKey.length == UpdateSigning.keyLength && feed != null;

  /// Called when a verified update becomes ready (Mochi's speech bubble).
  void Function(ReadyUpdate update)? onReady;

  /// At launch: tidies after the last update, picks up a copy that's ready, and starts checking.
  void start() {
    if (_started) return;
    _started = true;
    if (!supported) return _set(UpdatePhase.unsupported);
    if (!installed) return _set(UpdatePhase.notInstalled);
    if (!canCheck) return _set(UpdatePhase.unsupported);
    _tidy();
    final ready = _readReady();
    if (ready != null) {
      _ready = ready;
      _set(UpdatePhase.ready);
      unawaited(_warmRunner(ready));
    } else if (_phase != UpdatePhase.failed) {
      _set(UpdatePhase.idle);
    }
    _first = Timer(firstCheckAfter, () => unawaited(check()));
    _every = Timer.periodic(checkEvery, (_) => unawaited(check()));
  }

  /// A verified copy that's newer than this one, if there is one (also used at launch, before any window shows).
  ReadyUpdate? _readReady() {
    final ready = ReadyUpdate.read(files.ready);
    if (ready == null) return null;
    final usable = ready.build > currentBuild && File('${ready.root}${layout.separator}${InstallLayout.exeName}').existsSync();
    if (usable) return ready;
    _delete(files.ready);
    _deleteTree('${files.staged}${layout.separator}${ready.build}');
    return null;
  }

  /// After an update (or a failed one): the old copy goes, the helper's report is read, leftovers are cleared.
  void _tidy() {
    _deleteTree(layout.oldDirectory);
    final result = File(files.result);
    if (result.existsSync()) {
      try {
        final json = jsonDecode(result.readAsStringSync());
        if (json is Map && json['ok'] == true) {
          if (json['build'] == currentBuild || json['version'] == currentVersion) _updatedTo = currentVersion;
        } else if (json is Map) {
          final version = json['version'];
          final error = json['error'];
          _problem =
              "The update${version is String ? ' to Mochi $version' : ''} couldn't be installed"
              '${error is String ? ': $error' : '.'} Mochi stayed on $currentVersion and will try again.';
          _phase = UpdatePhase.failed;
        }
      } on Object {
        // An unreadable report: nothing to say.
      }
      _delete(files.result);
    } else if (File(files.applying).existsSync()) {
      _problem = "The last update didn't finish, so Mochi stayed on $currentVersion. It will try again.";
      _phase = UpdatePhase.failed;
    }
    _delete(files.applying);
    // Unpacked copies that aren't the one waiting, and finished downloads (kept only while they're being checked).
    final ready = ReadyUpdate.read(files.ready);
    try {
      final staged = Directory(files.staged);
      if (staged.existsSync()) {
        for (final folder in staged.listSync().whereType<Directory>()) {
          if (ready == null || !ready.root.startsWith(folder.path)) _deleteTree(folder.path);
        }
      }
      final downloads = Directory(files.downloads);
      if (downloads.existsSync()) {
        for (final file in downloads.listSync().whereType<File>()) {
          if (!file.path.endsWith('.part')) _delete(file.path);
        }
      }
    } on FileSystemException {
      // Next launch.
    }
  }

  /// Asks the relay for the newest version, and downloads it when automatic downloads are on.
  Future<void> check() async {
    if (_busy || !canCheck || _phase == UpdatePhase.applying) return;
    _busy = true;
    final hadReady = _ready != null;
    _problem = null;
    if (!hadReady) _set(UpdatePhase.checking);
    try {
      final signed = await feed!.manifest();
      final signature = signed.signature;
      if (signature == null || !await UpdateSigning.verify(signed.bytes, signature, publicKey)) {
        _couldNotVerify('Its manifest isn’t signed with Mochi’s release key, so it was thrown away.');
        return;
      }
      final manifest = UpdateManifest.parse(signed.bytes);
      _checkedAt = _clock();
      final ready = _ready;
      if (ready != null && ready.build != manifest.build) {
        // An even newer one, or the release was taken back: the waiting copy makes way.
        _deleteTree('${files.staged}${layout.separator}${ready.build}');
        _delete(files.ready);
        _ready = null;
      }
      if (manifest.build <= currentBuild) {
        _manifest = null;
        return _set(UpdatePhase.upToDate);
      }
      _manifest = manifest;
      if (_ready != null) return _set(UpdatePhase.ready);
      if (!manifest.runsOn(windowsVersion)) {
        _problem = 'Mochi ${manifest.version} needs Windows ${manifest.minWindows} or newer.';
        return _set(UpdatePhase.failed);
      }
      _set(UpdatePhase.available);
      if (_autoDownload()) await _download(manifest);
    } on UpdateFeedException catch (error) {
      _checkedAt = error.nothingPublished ? _clock() : _checkedAt;
      if (_ready != null) return _set(UpdatePhase.ready);
      if (error.nothingPublished) return _set(UpdatePhase.upToDate);
      _problem = error.message;
      _set(error.offline ? UpdatePhase.offline : UpdatePhase.failed);
    } on ManifestException catch (error) {
      _problem = 'The update’s manifest isn’t usable (${error.message})';
      _set(_ready != null ? UpdatePhase.ready : UpdatePhase.failed);
    } finally {
      _busy = false;
      if (hadReady && _phase == UpdatePhase.checking) _set(UpdatePhase.ready);
    }
  }

  /// "Download Update" (when automatic downloads are off).
  Future<void> download() async {
    final manifest = _manifest;
    if (_busy || manifest == null || _phase != UpdatePhase.available) return;
    _busy = true;
    try {
      await _download(manifest);
    } finally {
      _busy = false;
    }
  }

  Future<void> _download(UpdateManifest manifest) async {
    final sep = layout.separator;
    final zip = '${files.downloads}$sep${manifest.file}';
    _progress = 0;
    _set(UpdatePhase.downloading);
    var shown = 0;
    try {
      await feed!.download(
        manifest.file,
        zip,
        size: manifest.size,
        progress: (received) {
          final percent = received * 100 ~/ manifest.size;
          _progress = received / manifest.size;
          if (percent != shown) {
            shown = percent;
            notifyListeners();
          }
        },
      );
      _set(UpdatePhase.verifying);
      final digest = _hashInBackground ? await Isolate.run(() => UpdateSigning.sha256OfFile(zip)) : await UpdateSigning.sha256OfFile(zip);
      if (!UpdateSigning.sameDigest(digest, manifest.sha256)) {
        _delete(zip);
        _couldNotVerify('The download didn’t match the checksum in the signed manifest, so it was thrown away.');
        return;
      }
      final destination = '${files.staged}$sep${manifest.build}';
      _deleteTree(destination);
      await _unzip.extract(zip, destination);
      _delete(zip);
      final root = _findRoot(destination);
      if (root == null) {
        _deleteTree(destination);
        _problem = 'The update has no ${InstallLayout.exeName} in it.';
        return _set(UpdatePhase.failed);
      }
      final ready = ReadyUpdate(version: manifest.version, build: manifest.build, root: root, notes: manifest.notes);
      final file = File(files.ready);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(ready.toJson()), flush: true);
      _ready = ready;
      _progress = null;
      _set(UpdatePhase.ready);
      onReady?.call(ready);
      unawaited(_warmRunner(ready));
    } on UpdateFeedException catch (error) {
      _problem = error.message;
      _set(error.offline ? UpdatePhase.offline : UpdatePhase.failed);
    } on FileSystemException catch (error) {
      _problem = "The update couldn't be saved on this PC (${error.osError?.message ?? error.message}).";
      _set(UpdatePhase.failed);
    } on Object catch (error) {
      _problem = "The update couldn't be unpacked (${error.runtimeType}).";
      _set(UpdatePhase.failed);
    } finally {
      if (_phase != UpdatePhase.downloading) _progress = null;
    }
  }

  /// The folder with Mochi.exe: the zip's top level, or its one folder (`Mochi\`).
  String? _findRoot(String destination) {
    final sep = layout.separator;
    if (File('$destination$sep${InstallLayout.exeName}').existsSync()) return destination;
    final folders = Directory(destination).listSync().whereType<Directory>().toList();
    if (folders.length == 1 && File('${folders.single.path}$sep${InstallLayout.exeName}').existsSync()) return folders.single.path;
    return null;
  }

  void _couldNotVerify(String detail) {
    _problem = detail;
    _set(UpdatePhase.couldNotVerify);
  }

  /// Hands the waiting copy to the helper, which installs it once Mochi has quit and starts Mochi again. Returns what
  /// went wrong, in words, or null: then the caller quits Mochi.
  Future<String?> restartToUpdate() async {
    final ready = _ready ?? _readReady();
    if (ready == null) return 'No update is ready.';
    final failure = await _handOff(ready);
    if (failure == null) {
      _set(UpdatePhase.applying);
    } else {
      _problem = failure;
      notifyListeners();
    }
    return failure;
  }

  /// At launch, before any window: a verified copy is waiting, so Mochi installs it now (the helper starts the new
  /// Mochi). True when the caller should quit at once.
  Future<bool> applyPendingAtLaunch() async {
    if (!supported || !installed || File(files.applying).existsSync() || File(files.result).existsSync()) return false;
    final ready = _readReady();
    if (ready == null) return false;
    return await _handOff(ready) == null;
  }

  /// The helper that installs the update, copied out of the app folder it replaces (update\runner). Throws
  /// [FileSystemException]; returns null when the app has no helper.
  String? _copyRunner(ReadyUpdate ready) {
    final sep = layout.separator;
    final name = '${HelperInfo.executableName}${layout.windows ? '.exe' : ''}';
    final source = _helper?.call() ?? '${ready.root}$sep$name';
    if (!File(source).existsSync()) return null;
    final runner = '${files.runnerDirectory}$sep$name';
    Directory(files.runnerDirectory).createSync(recursive: true);
    UpdateCli.replaceFile(source: source, target: runner);
    return runner;
  }

  /// Once an update is ready: the helper is put in place and started once (`warm`, which does nothing), so it starts
  /// at once when Mochi restarts. Windows looks a new program over the first time it runs, which can take seconds (on
  /// an ARM PC, many: x64 programs are translated then).
  Future<void> _warmRunner(ReadyUpdate ready) async {
    try {
      final runner = _copyRunner(ready);
      if (runner != null) await (_processes ?? systemProcessControl()).launch(runner, const ['warm'], workingDirectory: files.runnerDirectory);
    } on Object {
      // Only a head start.
    }
  }

  Future<String?> _handOff(ReadyUpdate ready) async {
    final String? runner;
    try {
      runner = _copyRunner(ready);
      if (runner == null) return "Mochi's helper is missing, so the update can't be installed. Reinstall Mochi.";
      File(files.ready).renameSync(files.applying);
    } on FileSystemException catch (error) {
      return "The update couldn't be started (${error.osError?.message ?? error.message}).";
    }
    try {
      await (_processes ?? systemProcessControl()).launch(runner, [
        'update',
        '--staged',
        ready.root,
        '--app',
        layout.installDirectory,
        '--pid',
        '${_processId()}',
        '--version',
        ready.version,
        '--build',
        '${ready.build}',
      ], workingDirectory: files.runnerDirectory);
      return null;
    } on Object catch (error) {
      try {
        File(files.applying).renameSync(files.ready);
      } on FileSystemException {
        // Read again at the next check.
      }
      return "The update couldn't be started (${error.runtimeType}).";
    }
  }

  void _set(UpdatePhase phase) {
    _phase = phase;
    notifyListeners();
  }

  static void _delete(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Next time.
    }
  }

  static void _deleteTree(String path) {
    try {
      final folder = Directory(path);
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    } on FileSystemException {
      // Next launch.
    }
  }

  /// No more checks (Mochi is quitting). The status stays readable.
  void stop() {
    _first?.cancel();
    _every?.cancel();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
