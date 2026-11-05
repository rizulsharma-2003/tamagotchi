import 'dart:io';

import 'wire_event.dart';

/// Where the desktop app and the hook helper keep their files (Swift `BridgePaths`): one private folder.
///
/// - Windows: `%LOCALAPPDATA%\Mochi` (per user, not roamed).
/// - macOS (the development build): `~/Library/Application Support/Mochi Desktop`, apart from the Mac app's own folder.
/// - Linux: `$XDG_DATA_HOME/mochi` or `~/.local/share/mochi`.
///
/// `MOCHI_DESKTOP_HOME` points both the app and the helper somewhere else (tests and isolated development runs).
class BridgePaths {
  BridgePaths(this.home, {bool? windows}) : windows = windows ?? Platform.isWindows;

  static const String homeEnvironmentKey = 'MOCHI_DESKTOP_HOME';

  final String home;

  /// Windows file names (`mochi_hook.exe`) and separators.
  final bool windows;

  static BridgePaths resolve({Map<String, String>? environment, bool? windows}) {
    final env = environment ?? Platform.environment;
    final isWindows = windows ?? Platform.isWindows;
    final override = env[homeEnvironmentKey];
    if (override != null && override.isNotEmpty) return BridgePaths(override, windows: isWindows);
    if (isWindows) {
      final local = env['LOCALAPPDATA'];
      final base = local != null && local.isNotEmpty ? local : '${env['USERPROFILE'] ?? r'C:\'}\\AppData\\Local';
      return BridgePaths('$base\\Mochi', windows: true);
    }
    final userHome = env['HOME'] ?? '/tmp';
    if (Platform.isMacOS) return BridgePaths('$userHome/Library/Application Support/Mochi Desktop', windows: false);
    final data = env['XDG_DATA_HOME'];
    return BridgePaths('${data != null && data.isNotEmpty ? data : '$userHome/.local/share'}/mochi', windows: false);
  }

  String get separator => windows ? r'\' : '/';

  String join(String a, [String? b, String? c]) => [a, ?b, ?c].join(separator);

  String get runDirectory => join(home, 'run');

  /// `{"v":1,"port":…,"token":"…","pid":…}`: where the app listens and the token a helper must show. Rewritten with
  /// a new token every time the app starts.
  String get bridgeFile => join(runDirectory, 'bridge.json');
  String get spoolDirectory => join(home, 'spool');
  String get spoolFile => join(spoolDirectory, 'pending.jsonl');
  String get binDirectory => join(home, 'bin');

  /// Where "Connect Claude Code" installs the helper, so the hook commands keep working when the app moves.
  String get installedHelper => join(binDirectory, windows ? '${HelperInfo.executableName}.exe' : HelperInfo.executableName);
  String get backupsDirectory => join(home, 'Backups');
  String get settingsFile => join(home, 'settings.json');

  /// Present while the user shares Claude's summaries with their phones; only then does the helper include Claude's
  /// closing message and the names of changed files.
  String get summariesFlagFile => join(home, 'share-summaries');

  /// The working folder of `claude -p` runs (Ask Mochi, summaries): empty, so they see none of your projects.
  String get assistantDirectory => join(home, 'Assistant');

  /// This PC's Mochi Link credentials, sealed for this user (DPAPI on Windows).
  String get linkDirectory => join(home, 'Link');

  /// Creates [path] (and its parents) readable only by this user where the platform has modes (POSIX 0700). On
  /// Windows the per-user profile folder's ACL already does that.
  static bool ensurePrivateDirectory(String path) {
    try {
      final directory = Directory(path);
      if (directory.existsSync()) return true;
      directory.createSync(recursive: true);
      restrict(path, directory: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// `chmod 700` a folder or `chmod 600` a file (POSIX only; dart:io has no chmod).
  static void restrict(String path, {bool directory = false}) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('/bin/chmod', [if (directory) '700' else '600', path]);
    } on ProcessException {
      // Best effort: the parent folder is private anyway.
    }
  }
}
