import 'dart:io';

import 'bridge_paths.dart';
import 'wire_event.dart';

/// Where Mochi for Windows installs itself, for this user only and without admin rights (docs/SPRINT_2.md W29):
///
/// - the app folder: `%LOCALAPPDATA%\Programs\Mochi` (Windows' per-user programs folder);
/// - a Start-menu shortcut, `Mochi.lnk`, carrying the AppUserModelID [appUserModelId] (Windows toasts need it);
/// - an entry in Settings › Apps under `HKCU\…\Uninstall\Mochi`, whose uninstall runs the helper's `uninstall`.
///
/// The user's data never lives here: settings, the link and the hook helper copy are in [BridgePaths.home]
/// (`%LOCALAPPDATA%\Mochi`), and an update or an uninstall leaves that alone.
///
/// `MOCHI_DESKTOP_INSTALL_ROOT` puts the whole layout under another folder (tests, and trying an install on a PC that
/// already has Mochi): the app in `<root>\Programs\Mochi`, the shortcut in `<root>\Start Menu\Programs`, and its own
/// Settings › Apps entry (`Mochi.Test`), so a real install is never touched.
class InstallLayout {
  const InstallLayout({required this.installDirectory, required this.startMenuDirectory, this.testRoot, this.windows = true});

  static const String rootEnvironmentKey = 'MOCHI_DESKTOP_INSTALL_ROOT';

  /// Windows' identity for Mochi's notifications and taskbar grouping (the shortcut carries it).
  static const String appUserModelId = 'InsideEdge.Mochi';

  /// The COM class Windows calls when one of Mochi's notifications is clicked (Mochi registers it while it runs; the
  /// installed copy is its LocalServer32, so a click starts Mochi when it isn't running).
  static const String toastActivatorClsid = '{D67AE0D6-41E2-4D4B-961E-FAEC8753952D}';

  /// What Windows keeps about Mochi's notifications in HKEY_CURRENT_USER: the activator's class, and the
  /// AppUserModelID's name, icon and activator (written by the notifications plugin).
  static const String toastActivatorKey = 'Software\\Classes\\CLSID\\$toastActivatorClsid';
  static const String appUserModelIdKey = 'Software\\Classes\\AppUserModelId\\$appUserModelId';
  static const String exeName = 'Mochi.exe';
  static const String displayName = 'Mochi';
  static const String publisher = 'InsideEdge';

  /// The Settings › Apps entries live under this key in HKEY_CURRENT_USER.
  static const String uninstallRoot = r'Software\Microsoft\Windows\CurrentVersion\Uninstall';

  /// Mochi's folder in a per-user install.
  final String installDirectory;

  /// The user's Start menu programs folder.
  final String startMenuDirectory;

  /// Set when the layout was moved with `MOCHI_DESKTOP_INSTALL_ROOT`.
  final String? testRoot;
  final bool windows;

  bool get test => testRoot != null;

  static InstallLayout resolve({Map<String, String>? environment, bool? windows}) {
    final env = environment ?? Platform.environment;
    final isWindows = windows ?? Platform.isWindows;
    final separator = isWindows ? r'\' : '/';
    final root = env[rootEnvironmentKey];
    if (root != null && root.isNotEmpty) {
      return InstallLayout(
        installDirectory: [root, 'Programs', 'Mochi'].join(separator),
        startMenuDirectory: [root, 'Start Menu', 'Programs'].join(separator),
        testRoot: root,
        windows: isWindows,
      );
    }
    if (isWindows) {
      final profile = env['USERPROFILE'] ?? r'C:\';
      final local = _nonEmpty(env['LOCALAPPDATA']) ?? '$profile\\AppData\\Local';
      final roaming = _nonEmpty(env['APPDATA']) ?? '$profile\\AppData\\Roaming';
      return InstallLayout(
        installDirectory: '$local\\Programs\\Mochi',
        startMenuDirectory: '$roaming\\Microsoft\\Windows\\Start Menu\\Programs',
      );
    }
    // The macOS development build doesn't install itself; these are only somewhere harmless to point at.
    final home = env['HOME'] ?? '/tmp';
    return InstallLayout(installDirectory: '$home/Applications/Mochi Desktop', startMenuDirectory: '$home/Applications', windows: false);
  }

  static String? _nonEmpty(String? value) => value == null || value.isEmpty ? null : value;

  String get separator => windows ? r'\' : '/';

  /// The installed app.
  String get exe => '$installDirectory$separator$exeName';

  /// The hook helper that comes with the installed app (it runs updates and the uninstall too).
  String get helper => '$installDirectory$separator${HelperInfo.executableName}${windows ? '.exe' : ''}';

  /// Where the previous copy goes during an update; Mochi deletes it at its next launch.
  String get oldDirectory => '$installDirectory.old';

  /// Where "Install Mochi" copies the app before it's renamed into place.
  String get newDirectory => '$installDirectory.new';

  String get shortcut => '$startMenuDirectory$separator${test ? 'Mochi (test).lnk' : 'Mochi.lnk'}';

  /// Mochi's key in HKEY_CURRENT_USER for Settings › Apps.
  String get uninstallKey => '$uninstallRoot\\${test ? 'Mochi.Test' : 'Mochi'}';

  /// What Settings › Apps runs to uninstall: the helper in the app folder (a test layout names its root).
  String get uninstallCommand => '"$helper" uninstall${test ? ' --install-root "$testRoot"' : ''}';

  /// Whether [executable] is the installed copy (Windows paths compare without case).
  bool isInstalled(String executable) {
    final normal = _normal(executable);
    final cut = normal.lastIndexOf(separator);
    return cut > 0 && normal.substring(0, cut) == _normal(installDirectory);
  }

  /// Whether [path] is the install folder or inside it.
  bool contains(String path) {
    final normal = _normal(path);
    final root = _normal(installDirectory);
    return normal == root || normal.startsWith('$root$separator');
  }

  String _normal(String path) {
    var text = windows ? path.replaceAll('/', r'\') : path;
    while (text.length > 1 && text.endsWith(separator)) {
      text = text.substring(0, text.length - 1);
    }
    return windows ? text.toLowerCase() : text;
  }
}

/// Mochi's own update files, in its private folder ([BridgePaths.home]`\update`): the download, the verified copy
/// waiting to be installed, and what the helper says happened.
class UpdateFiles {
  UpdateFiles(this.paths);

  final BridgePaths paths;

  String get directory => paths.join(paths.home, 'update');

  /// Downloads in progress (`<zip>.part`) and finished.
  String get downloads => paths.join(directory, 'downloads');

  /// Verified, unpacked copies: `staged\<build>`.
  String get staged => paths.join(directory, 'staged');

  /// `{version, build, root, notes}`: a verified copy is ready to replace the app.
  String get ready => paths.join(directory, 'ready.json');

  /// [ready] renamed while the helper installs it, so a failed update isn't tried again at every launch.
  String get applying => paths.join(directory, 'applying.json');

  /// `{ok, version, build, error?, at}`: written by the helper after an update (or a failed one).
  String get result => paths.join(directory, 'result.json');

  /// A copy of the helper that runs the update from outside the app folder it replaces.
  String get runnerDirectory => paths.join(directory, 'runner');

  /// What the helper did, one line per step (paths and outcomes, never secrets).
  String get log => paths.join(directory, 'update.log');
}
