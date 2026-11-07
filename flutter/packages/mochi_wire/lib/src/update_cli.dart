import 'dart:convert';
import 'dart:io';

import 'bridge.dart';
import 'bridge_paths.dart';
import 'claude_hooks.dart';
import 'folder_swap.dart';
import 'install_layout.dart';
import 'process_control.dart';
import 'wire_event.dart';

/// The helper's install and update commands (docs/SPRINT_2.md W29), next to its hook commands:
///
///     mochi_hook update --staged <dir> --app <dir> --pid <pid> [--version V] [--build N]
///         waits for Mochi (pid) to quit, swaps the app folder for the verified copy in <dir> (rolling back on any
///         failure), refreshes the hook helper Claude Code runs, writes update\result.json and starts Mochi again
///     mochi_hook launch --after <pid> --exe <path> [-- arguments…]
///         waits for <pid> to quit, then starts <path> ("Install Mochi" relaunches the installed copy this way: only
///         one Mochi runs at a time)
///     mochi_hook warm
///         does nothing: the app starts the helper once while an update waits, so Windows has looked the new program
///         over before it's needed (that can take seconds the first time)
///     mochi_hook uninstall [--install-root <dir>] [--quiet]
///         what Settings › Apps runs: stops the installed Mochi, removes its folder, Start-menu shortcut, Settings ›
///         Apps entry and startup entry; keeps your settings and Mochi's link in %LOCALAPPDATA%\Mochi
///
/// The app starts `update` from a copy of the helper outside the app folder (update\runner), so nothing it replaces
/// is running. `update` runs without a console and writes only to update\update.log; `uninstall` talks in its window.
class UpdateCli {
  UpdateCli({
    required this.environment,
    required this.out,
    BridgePaths? paths,
    InstallLayout? layout,
    ProcessControl? processes,
    UninstallSystem? system,
    FolderSwap? swap,
    this.exitTimeout = const Duration(seconds: 45),
    this.pause = const Duration(seconds: 4),
    DateTime Function()? clock,
  }) : paths = paths ?? BridgePaths.resolve(environment: environment),
       _layout = layout,
       _processes = processes,
       _system = system,
       _swap = swap,
       _clock = clock ?? DateTime.now;

  static const List<String> commands = ['update', 'launch', 'warm', 'uninstall'];

  final Map<String, String> environment;
  final StringSink out;
  final BridgePaths paths;
  final InstallLayout? _layout;
  final ProcessControl? _processes;
  final UninstallSystem? _system;
  final FolderSwap? _swap;
  final DateTime Function() _clock;

  /// How long `update` and `launch` wait for Mochi to quit.
  final Duration exitTimeout;

  /// How long `uninstall` leaves its last words on screen.
  final Duration pause;

  late final UpdateFiles files = UpdateFiles(paths);

  ProcessControl get processes => _processes ?? systemProcessControl();

  Future<int> run(List<String> arguments) async {
    final rest = arguments.sublist(1);
    switch (arguments.first) {
      case 'update':
        return update(rest);
      case 'launch':
        return launch(rest);
      case 'warm':
        return 0;
      case 'uninstall':
        return uninstall(rest);
    }
    return 64;
  }

  // MARK: update

  Future<int> update(List<String> args) async {
    final options = _options(args);
    final staged = options['--staged'], app = options['--app'], pid = int.tryParse(options['--pid'] ?? '');
    if (staged == null || app == null || pid == null) {
      _log('update: missing --staged, --app or --pid');
      return 64;
    }
    final version = options['--version'] ?? '?';
    final build = int.tryParse(options['--build'] ?? '');
    final sep = paths.separator;
    _log('update to $version ($build): waiting for Mochi ($pid) to quit');
    if (!processes.waitForExit(pid, exitTimeout)) {
      // Mochi is still running: it keeps the verified copy for its next launch.
      _restoreReady();
      _writeResult(ok: false, version: version, build: build, error: "Mochi didn't quit, so the update waits for its next launch.");
      _log('update: Mochi is still running; nothing changed');
      return 1;
    }

    final swap = (_swap ?? FolderSwap(log: (message) => _log('swap: $message'))).swap(
      incoming: staged,
      target: app,
      requiredFile: InstallLayout.exeName,
      separator: sep,
    );
    if (swap.ok) {
      final helper = '$app$sep${HelperInfo.executableName}${paths.windows ? '.exe' : ''}';
      final refreshed = refreshInstalledHelper(source: helper, target: paths.installedHelper);
      _log('hook helper: $refreshed');
    }
    _writeResult(ok: swap.ok, version: version, build: build, error: swap.error);
    _delete(files.applying);
    _log(swap.ok ? 'update: installed $version' : 'update: failed (${swap.error})');

    // Mochi again, whichever copy is in place now.
    final exe = '$app$sep${InstallLayout.exeName}';
    if (options.containsKey('--no-relaunch')) return swap.ok ? 0 : 1;
    try {
      await processes.launch(exe, const [], workingDirectory: app);
      _log('update: started $exe');
    } on Object catch (error) {
      _log("update: couldn't start Mochi again (${error.runtimeType})");
    }
    return swap.ok ? 0 : 1;
  }

  /// The helper Claude Code's hooks run lives in Mochi's folder ([BridgePaths.installedHelper]); an update brings a
  /// new one in the app folder, so the hooks must get it too. Only when Claude Code is connected (the copy exists).
  static String refreshInstalledHelper({required String source, required String target}) {
    final installed = File(target);
    if (!installed.existsSync()) return 'not connected to Claude Code; nothing to refresh';
    final fresh = File(source);
    if (!fresh.existsSync()) return 'the new copy has no hook helper; kept the old one';
    try {
      replaceFile(source: source, target: target);
      return 'refreshed';
    } on FileSystemException catch (error) {
      return "couldn't refresh it (${error.osError?.errorCode ?? error.message}); Mochi refreshes it at its next launch";
    }
  }

  /// Puts a copy of [source] at [target] without ever leaving [target] missing or half-written: a copy beside it, then
  /// a rename over it. If [target] is running (a hook this very moment), it's renamed aside first (Windows lets a
  /// running program be renamed, not replaced) and the leftover deleted when it can be.
  static void replaceFile({required String source, required String target}) {
    final bytes = File(source).readAsBytesSync();
    final current = File(target);
    if (current.existsSync() && _same(current.readAsBytesSync(), bytes)) return;
    final temporary = File('$target.new');
    temporary.writeAsBytesSync(bytes, flush: true);
    if (!Platform.isWindows) Process.runSync('/bin/chmod', ['755', temporary.path]);
    for (var attempt = 0; ; attempt++) {
      try {
        temporary.renameSync(target);
        break;
      } on FileSystemException {
        if (attempt < 8) {
          sleep(const Duration(milliseconds: 150));
          continue;
        }
        // Busy: move it aside, then put the new one in its place.
        current.renameSync('$target.old-${DateTime.now().millisecondsSinceEpoch}');
        temporary.renameSync(target);
        break;
      }
    }
    // Old ones from earlier refreshes, once nothing runs them.
    try {
      final folder = current.parent;
      final name = current.uri.pathSegments.last;
      for (final leftover in folder.listSync().whereType<File>()) {
        if (leftover.uri.pathSegments.last.startsWith('$name.old-')) {
          try {
            leftover.deleteSync();
          } on FileSystemException {
            // Still running: next time.
          }
        }
      }
    } on FileSystemException {
      // Best effort.
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _restoreReady() {
    final applying = File(files.applying);
    if (!applying.existsSync()) return;
    try {
      applying.renameSync(files.ready);
    } on FileSystemException {
      // The app sees the result and checks again.
    }
  }

  void _writeResult({required bool ok, required String version, int? build, String? error}) {
    try {
      final file = File(files.result);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({'ok': ok, 'version': version, 'build': ?build, 'error': ?error, 'at': _clock().toUtc().toIso8601String()}),
        flush: true,
      );
    } on FileSystemException catch (error) {
      _log("update: couldn't write the result (${error.message})");
    }
  }

  // MARK: launch

  Future<int> launch(List<String> args) async {
    final split = args.indexOf('--');
    final options = _options(split < 0 ? args : args.sublist(0, split));
    final passed = split < 0 ? const <String>[] : args.sublist(split + 1);
    final exe = options['--exe'], after = int.tryParse(options['--after'] ?? '');
    if (exe == null) return 64;
    if (after != null && !processes.waitForExit(after, exitTimeout)) {
      _log('launch: process $after is still running; not starting a second Mochi');
      return 1;
    }
    try {
      await processes.launch(exe, passed, workingDirectory: File(exe).parent.path);
      return 0;
    } on Object catch (error) {
      _log("launch: couldn't start $exe (${error.runtimeType})");
      return 1;
    }
  }

  // MARK: uninstall

  Future<int> uninstall(List<String> args) async {
    final options = _options(args);
    final root = options['--install-root'];
    final layout =
        _layout ??
        InstallLayout.resolve(environment: {...environment, if (root != null) InstallLayout.rootEnvironmentKey: root}, windows: paths.windows);
    final system = _system ?? (Platform.isWindows ? Win32UninstallSystem() : null);
    out.writeln('Uninstalling Mochi from ${layout.installDirectory}…');

    // 1. Mochi itself, if the installed copy is running (never another copy, say one you're developing).
    final endpoint = BridgeEndpoint.read(paths.bridgeFile);
    final pid = endpoint?.pid;
    if (pid != null) {
      final running = processes.executablePath(pid);
      if (running != null && layout.contains(running)) {
        out.writeln('Quitting Mochi…');
        processes.terminate(pid);
      }
    }

    // 2. Settings › Apps, the startup entry (only if it starts this copy), and the Start-menu shortcut.
    final problems = <String>[];
    if (system != null) {
      try {
        system.deleteKey(layout.uninstallKey);
        // What Mochi's notifications registered (a test layout never registers them).
        if (!layout.test) {
          system.deleteKey(InstallLayout.toastActivatorKey);
          system.deleteKey(InstallLayout.appUserModelIdKey);
        }
        final run = system.readString(_runKey, _runValue);
        if (run != null && layout.contains(_commandPath(run))) {
          system.deleteValue(_runKey, _runValue);
          system.deleteValue(_approvedKey, _runValue);
        }
      } on Object catch (error) {
        problems.add('the registry (${error.runtimeType})');
      }
    }
    _deleteFile(layout.shortcut, problems);

    // 3. Downloaded updates (Mochi's cache, not your data).
    _deleteTree(files.directory, problems);
    _deleteTree(layout.oldDirectory, problems);

    // 4. The app folder: every file now, the folder itself (with this helper in it) once the helper has quit.
    final folder = Directory(layout.installDirectory);
    if (folder.existsSync()) {
      for (final entity in folder.listSync()) {
        try {
          entity.deleteSync(recursive: true);
        } on FileSystemException {
          // This helper, while it runs: the folder goes after it quits.
        }
      }
      if (system != null) {
        await system.deleteAfterExit(layout.installDirectory);
      } else {
        try {
          folder.deleteSync(recursive: true);
        } on FileSystemException catch (error) {
          problems.add('${folder.path} (${error.osError?.message ?? error.message})');
        }
      }
    }

    out.writeln(problems.isEmpty ? 'Mochi is uninstalled.' : "Mochi is uninstalled, but these couldn't be removed: ${problems.join(', ')}.");
    out.writeln('Your settings and Mochi\'s link stay in ${paths.home}. Delete that folder too if you like.');
    if (_hooksConnected()) {
      out.writeln(
        "Claude Code still has Mochi's hooks in its settings; they do nothing without Mochi. To take them out, remove "
        'the entries that run mochi_hook from ${ClaudeHookInstaller.defaultSettingsFile(environment: environment, windows: paths.windows)}.',
      );
    }
    if (!options.containsKey('--quiet') && pause > Duration.zero) await Future<void>.delayed(pause);
    return problems.isEmpty ? 0 : 1;
  }

  static const String _runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _approvedKey = r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  static const String _runValue = 'Mochi';

  /// The exe in a Run value: the quoted part, or everything up to `.exe`.
  static String _commandPath(String value) {
    final text = value.trim();
    if (text.startsWith('"')) {
      final end = text.indexOf('"', 1);
      return end > 0 ? text.substring(1, end) : text.substring(1);
    }
    final exe = text.toLowerCase().indexOf('.exe');
    return exe > 0 ? text.substring(0, exe + 4) : text;
  }

  bool _hooksConnected() {
    try {
      final status = ClaudeHookInstaller(
        settingsFile: ClaudeHookInstaller.defaultSettingsFile(environment: environment, windows: paths.windows),
        backupDirectory: paths.backupsDirectory,
        helperPath: paths.installedHelper,
        style: paths.windows ? HookCommandStyle.exec : HookCommandStyle.shell,
      ).inspect().status;
      return status == HookStatus.installed || status == HookStatus.needsUpdate;
    } on Object {
      return false;
    }
  }

  void _deleteFile(String path, List<String> problems) {
    final file = File(path);
    if (!file.existsSync()) return;
    try {
      file.deleteSync();
    } on FileSystemException catch (error) {
      problems.add('$path (${error.osError?.message ?? error.message})');
    }
  }

  void _deleteTree(String path, List<String> problems) {
    final directory = Directory(path);
    if (!directory.existsSync()) return;
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException catch (error) {
      problems.add('$path (${error.osError?.message ?? error.message})');
    }
  }

  // MARK: helpers

  /// `--name value` pairs (and bare `--flag`s, as empty strings).
  static Map<String, String> _options(List<String> args) {
    final options = <String, String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) continue;
      if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        options[arg] = args[++i];
      } else {
        options[arg] = '';
      }
    }
    return options;
  }

  void _delete(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // The app tidies up.
    }
  }

  /// One line in update\update.log (kept short: the last 200 lines).
  void _log(String message) {
    try {
      final file = File(files.log);
      file.parent.createSync(recursive: true);
      final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
      lines.add('${_clock().toIso8601String()} $message');
      file.writeAsStringSync('${lines.skip(lines.length > 200 ? lines.length - 200 : 0).join('\n')}\n');
    } on FileSystemException {
      // Diagnostics only.
    }
  }
}
