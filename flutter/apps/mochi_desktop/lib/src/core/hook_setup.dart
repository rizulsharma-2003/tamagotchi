import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mochi_wire/mochi_wire.dart';

/// Settings › Claude Code: puts the hook helper somewhere stable and adds Mochi's hooks to Claude Code's settings.json
/// (and takes them out again). Idempotent; never touches anything that isn't Mochi's; backs the file up first.
class HookSetup extends ChangeNotifier {
  HookSetup({required this.paths, required this.settingsFile, required this.style, required this.bundledHelper, this.managedSettingsFile});

  /// Where the helper comes with the app: `MOCHI_HOOK_HELPER`, else next to the executable (Windows: `mochi_hook.exe`
  /// beside `Mochi.exe`; macOS: `Contents/MacOS/mochi_hook`). Null when it isn't there.
  static String? findBundledHelper({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final pinned = env['MOCHI_HOOK_HELPER'];
    if (pinned != null && pinned.isNotEmpty) return File(pinned).existsSync() ? pinned : null;
    final name = Platform.isWindows ? '${HelperInfo.executableName}.exe' : HelperInfo.executableName;
    final beside = '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$name';
    return File(beside).existsSync() ? beside : null;
  }

  final BridgePaths paths;
  final String settingsFile;
  final HookCommandStyle style;

  /// The helper shipped with the app (copied to [BridgePaths.installedHelper] on Connect).
  final String? bundledHelper;
  final String? managedSettingsFile;

  HookInspection? _inspection;
  String? _problem;
  String? _lastBackup;
  bool _busy = false;

  HookInspection? get inspection => _inspection;
  String? get problem => _problem;
  String? get lastBackup => _lastBackup;
  bool get busy => _busy;
  bool get connected => _inspection?.status == HookStatus.installed;

  /// Mochi's hooks are there, but some point elsewhere or are missing: Connect again fixes it.
  bool get needsUpdate => _inspection?.status == HookStatus.needsUpdate;

  ClaudeHookInstaller get _installer => ClaudeHookInstaller(
    settingsFile: settingsFile,
    backupDirectory: paths.backupsDirectory,
    helperPath: paths.installedHelper,
    style: style,
    managedSettingsFile: managedSettingsFile,
  );

  void refresh() {
    _inspection = _installer.inspect();
    notifyListeners();
  }

  /// Claude Code's settings.json as Connect would leave it (Settings › Claude Code › Preview Changes); null when the
  /// file can't be read.
  String? preview() {
    try {
      return _installer.preview();
    } on Object {
      return null;
    }
  }

  /// Whether the hook helper is in Mochi's folder, where the hooks run it.
  bool get helperInstalled => File(paths.installedHelper).existsSync();

  /// Copies the helper into place and adds the hooks.
  Future<void> connect() => _change(() {
    _installHelper();
    return _installer.install();
  });

  /// Takes Mochi's hooks out of settings.json (the helper file stays; it's harmless without them).
  Future<void> disconnect() => _change(_installer.uninstall);

  Future<void> _change(HookChange Function() action) async {
    if (_busy) return;
    _busy = true;
    _problem = null;
    notifyListeners();
    try {
      final change = action();
      if (change.backup != null) _lastBackup = change.backup;
    } on HookInstallException catch (error) {
      _problem = error.message;
    } on FileSystemException catch (error) {
      _problem = "Couldn't put the hook helper in place (${error.message}). Close Claude Code sessions and try again.";
    } finally {
      _busy = false;
      refresh();
    }
  }

  void _installHelper() {
    final source = bundledHelper;
    final target = File(paths.installedHelper);
    if (source == null) {
      if (target.existsSync()) return;
      throw const HookInstallException("Mochi's hook helper isn't next to the app. Reinstalling Mochi fixes it.");
    }
    if (source == target.path) return;
    final bytes = File(source).readAsBytesSync();
    if (target.existsSync() && listEquals(target.readAsBytesSync(), bytes)) return;
    BridgePaths.ensurePrivateDirectory(paths.binDirectory);
    // A copy beside it, then a rename: Claude Code may be running the old one this very moment.
    final temporary = File('${target.path}.new');
    temporary.writeAsBytesSync(bytes, flush: true);
    if (!Platform.isWindows) Process.runSync('/bin/chmod', ['755', temporary.path]);
    temporary.renameSync(target.path);
  }
}
