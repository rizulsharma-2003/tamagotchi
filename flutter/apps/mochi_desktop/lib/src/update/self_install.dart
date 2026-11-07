// "Install Mochi" (docs/SPRINT_2.md W29): a Mochi started from anywhere but its install folder (Downloads, a build
// folder) offers to install itself for this user, so updates never need admin rights. It copies its own folder to
// %LOCALAPPDATA%\Programs\Mochi, adds a Start-menu shortcut (with Mochi's AppUserModelID, which Windows toasts need)
// and a Settings › Apps entry whose uninstall runs the helper, then starts the installed copy. The user's data in
// %LOCALAPPDATA%\Mochi is never touched.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:mochi_wire/mochi_wire.dart';

import '../platform/startup.dart';

class InstallException implements Exception {
  const InstallException(this.message);

  final String message;

  @override
  String toString() => 'InstallException: $message';
}

/// The Windows calls an install makes (Win32InstallSystem); tests use a fake.
abstract interface class InstallSystem {
  /// A .lnk at [path] that starts [target], carrying [appUserModelId].
  void createShortcut({
    required String path,
    required String target,
    required String workingDirectory,
    required String description,
    required String appUserModelId,
  });

  /// Writes values under [key] in HKEY_CURRENT_USER (a String is REG_SZ, an int REG_DWORD), making the key if needed.
  void writeUninstallEntry(String key, Map<String, Object> values);

  void deleteUninstallEntry(String key);

  String? readUninstallValue(String key, String name);
}

class SelfInstaller extends ChangeNotifier {
  SelfInstaller({
    required this.layout,
    required this.executable,
    required this.version,
    this.system,
    this.startup,
    this.startupFor,
    ProcessControl? processes,
    int Function()? processId,
    DateTime Function()? clock,
    bool copyInBackground = true,
  }) : _processes = processes,
       _processId = processId ?? (() => pid),
       _clock = clock ?? DateTime.now,
       _copyInBackground = copyInBackground;

  /// Anywhere but Windows (the macOS development build, tests that don't care): nothing to install.
  factory SelfInstaller.unsupported() =>
      SelfInstaller(layout: InstallLayout.resolve(windows: false), executable: Platform.resolvedExecutable, version: '');

  final InstallLayout layout;

  /// This running copy's exe.
  final String executable;
  final String version;

  /// Null: installing isn't possible here.
  final InstallSystem? system;

  /// "Start Mochi with Windows" for this copy, and the same for another exe (the installed one).
  final StartupItem? startup;
  final StartupItem Function(String executable)? startupFor;
  final ProcessControl? _processes;
  final int Function() _processId;
  final DateTime Function() _clock;
  final bool _copyInBackground;

  bool _busy = false;
  String? _problem;

  bool get supported => system != null;

  /// This copy runs from the install folder.
  bool get installed => supported && layout.isInstalled(executable);

  /// Where this copy runs from.
  String get runningFrom => File(executable).parent.path;

  bool get busy => _busy;

  /// Why the last install failed, in words.
  String? get problem => _problem;

  /// Copies this copy into the install folder (replacing an older install), and registers it. True when it worked;
  /// then [relaunchInstalled] hands over to the installed copy.
  Future<bool> install() async {
    final system = this.system;
    if (system == null || _busy) return false;
    _busy = true;
    _problem = null;
    notifyListeners();
    try {
      final source = runningFrom;
      final staging = layout.newDirectory;
      final target = layout.installDirectory;
      final copy = _copyInBackground ? _copyInIsolate(source, staging) : Future.value(_copy(source, staging));
      final bytes = await copy;
      final swap = FolderSwap(retryFor: const Duration(seconds: 5)).swap(
        incoming: staging,
        target: target,
        requiredFile: InstallLayout.exeName,
        separator: layout.separator,
      );
      if (!swap.ok) throw InstallException(swap.error ?? "Mochi couldn't be copied into place.");
      // The copy that was there before (an older install) isn't running: Mochi runs only once at a time.
      try {
        final old = Directory(layout.oldDirectory);
        if (old.existsSync()) old.deleteSync(recursive: true);
      } on FileSystemException {
        // The installed copy tidies it at launch.
      }
      register(bytes: bytes);
      // Start with Windows: if it starts this copy, it starts the installed one from now on.
      final runsHere = startup;
      final there = startupFor;
      if (runsHere != null && there != null && runsHere.supported && runsHere.status().enabled) there(layout.exe).setEnabled(true);
      return true;
    } on InstallException catch (error) {
      _problem = error.message;
      return false;
    } on FileSystemException catch (error) {
      _problem = "Mochi couldn't be copied to ${layout.installDirectory} (${error.osError?.message ?? error.message}).";
      return false;
    } on Object catch (error) {
      _problem = "Mochi couldn't be installed (${error.runtimeType}).";
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// A static function, so the closure sent to the isolate holds only the two paths, never `this`.
  static Future<int> _copyInIsolate(String source, String staging) => Isolate.run(() => _copy(source, staging));

  static int _copy(String source, String staging) {
    final folder = Directory(staging);
    if (folder.existsSync()) folder.deleteSync(recursive: true);
    final bytes = copyDirectory(source, staging);
    // Installed files don't say "downloaded from the internet" (or the Start menu would bring SmartScreen back).
    removeDownloadMarks(staging);
    return bytes;
  }

  /// The Start-menu shortcut (made again if it's gone) and the Settings › Apps entry (with this version and size).
  /// At every launch of the installed copy too, so an update shows its version there.
  void register({int? bytes}) {
    final system = this.system;
    if (system == null) return;
    if (!File(layout.shortcut).existsSync()) {
      Directory(layout.startMenuDirectory).createSync(recursive: true);
      system.createShortcut(
        path: layout.shortcut,
        target: layout.exe,
        workingDirectory: layout.installDirectory,
        description: 'Mochi, your Claude Code companion',
        appUserModelId: InstallLayout.appUserModelId,
      );
    }
    final now = _clock();
    final size = bytes ?? _size(layout.installDirectory);
    system.writeUninstallEntry(layout.uninstallKey, {
      'DisplayName': layout.test ? 'Mochi (test)' : InstallLayout.displayName,
      'DisplayVersion': version,
      'Publisher': InstallLayout.publisher,
      'DisplayIcon': '"${layout.exe}",0',
      'InstallLocation': layout.installDirectory,
      'UninstallString': layout.uninstallCommand,
      'QuietUninstallString': '${layout.uninstallCommand} --quiet',
      'InstallDate': '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}',
      'EstimatedSize': (size / 1024).ceil(),
      'NoModify': 1,
      'NoRepair': 1,
    });
  }

  /// At launch of the installed copy: Settings › Apps shows this version; the shortcut is there.
  void refreshAtLaunch() {
    if (!installed) return;
    try {
      if (system!.readUninstallValue(layout.uninstallKey, 'DisplayVersion') == version && File(layout.shortcut).existsSync()) return;
      register();
    } on Object catch (error) {
      debugPrint('Mochi: the install entry could not be refreshed (${error.runtimeType})');
    }
  }

  /// Starts the installed copy once this one has quit (the helper waits: only one Mochi runs at a time). The caller
  /// quits right after.
  Future<String?> relaunchInstalled() async {
    try {
      await (_processes ?? systemProcessControl()).launch(layout.helper, [
        'launch',
        '--after',
        '${_processId()}',
        '--exe',
        layout.exe,
        '--',
        '--installed',
      ], workingDirectory: layout.installDirectory);
      return null;
    } on Object catch (error) {
      _problem = "Mochi is installed, but it couldn't be started (${error.runtimeType}). Start it from the Start menu.";
      notifyListeners();
      return _problem;
    }
  }

  static int _size(String path) {
    var total = 0;
    try {
      for (final entity in Directory(path).listSync(recursive: true)) {
        if (entity is File) total += entity.lengthSync();
      }
    } on FileSystemException {
      // An estimate.
    }
    return total;
  }
}
