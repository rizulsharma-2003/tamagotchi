// Mochi for Windows installing itself and its updates (docs/SPRINT_2.md W29): where the install goes, the helper's
// folder swap with its rollback (on real folders in a temporary directory, with failures injected), and the helper's
// update, launch and uninstall commands against fakes for the processes and the registry.

import 'dart:convert';
import 'dart:io';

import 'package:mochi_wire/mochi_wire.dart';
import 'package:test/test.dart';

final String sep = Platform.pathSeparator;

/// The helper's file name on this system (as in [BridgePaths.installedHelper]).
final String helperName = Platform.isWindows ? 'mochi_hook.exe' : 'mochi_hook';

/// The real file system, except where a test makes an operation fail.
class FaultyOps extends IoFolderOps {
  /// Return true to make this rename fail (with [code] as its OS error).
  bool Function(String from, String to)? failRename;
  bool Function(String path)? failDelete;
  int code = 32; // ERROR_SHARING_VIOLATION
  final List<String> renames = [];
  int sleeps = 0;

  @override
  void rename(String from, String to) {
    renames.add('${_name(from)} -> ${_name(to)}');
    if (failRename?.call(from, to) ?? false) throw FileSystemException('busy', from, OSError('in use', code));
    super.rename(from, to);
  }

  @override
  void deleteTree(String path) {
    if (failDelete?.call(path) ?? false) throw FileSystemException('busy', path, OSError('in use', 32));
    super.deleteTree(path);
  }

  @override
  void sleep(Duration duration) => sleeps++;

  static String _name(String path) => path.split(RegExp(r'[\\/]')).last;
}

/// Processes, as the helper sees them: which are still running, their paths, what it started.
class FakeProcesses implements ProcessControl {
  final Map<int, String> running = {};

  /// Processes that never quit when waited for.
  final Set<int> stubborn = {};
  final List<int> waited = [];
  final List<int> terminated = [];
  final List<({String exe, List<String> arguments, String? workingDirectory})> launched = [];

  @override
  bool waitForExit(int pid, Duration timeout) {
    waited.add(pid);
    if (stubborn.contains(pid)) return false;
    running.remove(pid);
    return true;
  }

  @override
  String? executablePath(int pid) => running[pid];

  @override
  bool terminate(int pid) {
    terminated.add(pid);
    running.remove(pid);
    return true;
  }

  @override
  Future<void> launch(String executable, List<String> arguments, {String? workingDirectory}) async =>
      launched.add((exe: executable, arguments: arguments, workingDirectory: workingDirectory));
}

/// HKEY_CURRENT_USER in memory.
class FakeUninstallSystem implements UninstallSystem {
  final Map<String, Map<String, String>> keys = {};
  final List<String> deletedKeys = [];
  final List<String> deleteLater = [];

  @override
  String? readString(String key, String name) => keys[key]?[name];

  @override
  void deleteValue(String key, String name) => keys[key]?.remove(name);

  @override
  void deleteKey(String key) {
    deletedKeys.add(key);
    keys.remove(key);
  }

  @override
  Future<void> deleteAfterExit(String directory) async {
    deleteLater.add(directory);
    final folder = Directory(directory);
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('mochi_wire_update'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// A folder that looks like Mochi's app folder, marked with [version].
  Directory appFolder(String path, String version) {
    final folder = Directory(path)..createSync(recursive: true);
    File('$path${sep}Mochi.exe').writeAsStringSync('Mochi $version');
    File('$path$sep$helperName').writeAsStringSync('helper $version');
    Directory('$path${sep}data${sep}flutter_assets').createSync(recursive: true);
    File('$path${sep}data${sep}app.so').writeAsStringSync('app $version');
    return folder;
  }

  String read(String path) => File(path).readAsStringSync();

  group('InstallLayout', () {
    test(r'a per-user install on Windows: Programs\Mochi, the Start menu, Settings › Apps', () {
      final layout = InstallLayout.resolve(
        environment: {
          'LOCALAPPDATA': r'C:\Users\rizz\AppData\Local',
          'APPDATA': r'C:\Users\rizz\AppData\Roaming',
          'USERPROFILE': r'C:\Users\rizz',
        },
        windows: true,
      );
      expect(layout.installDirectory, r'C:\Users\rizz\AppData\Local\Programs\Mochi');
      expect(layout.exe, r'C:\Users\rizz\AppData\Local\Programs\Mochi\Mochi.exe');
      expect(layout.helper, r'C:\Users\rizz\AppData\Local\Programs\Mochi\mochi_hook.exe');
      expect(layout.oldDirectory, r'C:\Users\rizz\AppData\Local\Programs\Mochi.old');
      expect(layout.shortcut, r'C:\Users\rizz\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Mochi.lnk');
      expect(layout.uninstallKey, r'Software\Microsoft\Windows\CurrentVersion\Uninstall\Mochi');
      expect(layout.uninstallCommand, r'"C:\Users\rizz\AppData\Local\Programs\Mochi\mochi_hook.exe" uninstall');
      expect(layout.test, isFalse);
      expect(InstallLayout.appUserModelId, 'InsideEdge.Mochi');

      // Not where the user's data is.
      final data = BridgePaths.resolve(environment: {'LOCALAPPDATA': r'C:\Users\rizz\AppData\Local'}, windows: true);
      expect(layout.contains(data.home), isFalse);
      expect(layout.contains(data.installedHelper), isFalse);
    });

    test('knows the installed copy from any other, whatever the case of the path', () {
      final layout = InstallLayout.resolve(environment: {'LOCALAPPDATA': r'C:\Users\rizz\AppData\Local'}, windows: true);
      expect(layout.isInstalled(r'C:\Users\rizz\AppData\Local\Programs\Mochi\Mochi.exe'), isTrue);
      expect(layout.isInstalled(r'c:\users\RIZZ\appdata\local\programs\mochi\MOCHI.EXE'), isTrue);
      expect(layout.isInstalled(r'C:\Users\rizz\Downloads\Mochi-0.2.0-windows-x64\Mochi\Mochi.exe'), isFalse);
      expect(layout.isInstalled(r'C:\Users\rizz\AppData\Local\Programs\Mochi.old\Mochi.exe'), isFalse);
      expect(layout.isInstalled(r'C:\src\mochi\flutter\apps\mochi_desktop\build\windows\x64\runner\Release\Mochi.exe'), isFalse);
      expect(layout.contains(r'C:\Users\rizz\AppData\Local\Programs\Mochi\data\app.so'), isTrue);
      expect(layout.contains(r'C:\Users\rizz\AppData\Local\Programs\Mochi2\Mochi.exe'), isFalse);
    });

    test('MOCHI_DESKTOP_INSTALL_ROOT moves everything, with its own Settings › Apps entry', () {
      final layout = InstallLayout.resolve(
        environment: {'MOCHI_DESKTOP_INSTALL_ROOT': r'C:\src\mochi-update\install', 'LOCALAPPDATA': r'C:\Users\rizz\AppData\Local'},
        windows: true,
      );
      expect(layout.test, isTrue);
      expect(layout.installDirectory, r'C:\src\mochi-update\install\Programs\Mochi');
      expect(layout.shortcut, r'C:\src\mochi-update\install\Start Menu\Programs\Mochi (test).lnk');
      expect(layout.uninstallKey, endsWith(r'\Uninstall\Mochi.Test'));
      expect(layout.uninstallCommand, r'"C:\src\mochi-update\install\Programs\Mochi\mochi_hook.exe" uninstall --install-root "C:\src\mochi-update\install"');
    });

    test("the update files live in Mochi's own folder", () {
      final files = UpdateFiles(BridgePaths(r'C:\Users\rizz\AppData\Local\Mochi', windows: true));
      expect(files.directory, r'C:\Users\rizz\AppData\Local\Mochi\update');
      expect(files.ready, r'C:\Users\rizz\AppData\Local\Mochi\update\ready.json');
      expect(files.result, r'C:\Users\rizz\AppData\Local\Mochi\update\result.json');
      expect(files.runnerDirectory, r'C:\Users\rizz\AppData\Local\Mochi\update\runner');
    });
  });

  group('FolderSwap', () {
    late String app, incoming;

    setUp(() {
      app = '${temp.path}${sep}Programs${sep}Mochi';
      incoming = '${temp.path}${sep}staged${sep}2${sep}Mochi';
      appFolder(app, '0.1.0');
      appFolder(incoming, '0.2.0');
    });

    test('moves the old copy aside and the new one in', () {
      final ops = FaultyOps();
      final result = FolderSwap(ops: ops).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isTrue);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.2.0');
      expect(read('$app${sep}data${sep}app.so'), 'app 0.2.0');
      expect(read('$app.old${sep}Mochi.exe'), 'Mochi 0.1.0', reason: 'kept for the app to delete at its next launch');
      expect(Directory(incoming).existsSync(), isFalse);
      expect(ops.renames, ['Mochi -> Mochi.old', 'Mochi -> Mochi']);
    });

    test('a .old left from an earlier update is cleared first', () {
      appFolder('$app.old', '0.0.9');
      final result = FolderSwap(ops: FaultyOps()).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isTrue);
      expect(read('$app.old${sep}Mochi.exe'), 'Mochi 0.1.0');
    });

    test('a .old that cannot be deleted gets a sibling with a timestamp instead', () {
      appFolder('$app.old', '0.0.9');
      final ops = FaultyOps()..failDelete = (path) => path.endsWith('Mochi.old');
      final result = FolderSwap(ops: ops, retryFor: Duration.zero).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isTrue);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.2.0');
      final siblings = Directory('${temp.path}${sep}Programs').listSync().map((e) => e.path.split(sep).last).toList();
      expect(siblings.where((name) => name.startsWith('Mochi.old-')), hasLength(1));
    });

    test('an incomplete copy changes nothing', () {
      File('$incoming${sep}Mochi.exe').deleteSync();
      final ops = FaultyOps();
      final result = FolderSwap(ops: ops).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isFalse);
      expect(result.error, contains('incomplete'));
      expect(ops.renames, isEmpty);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.1.0');
    });

    test('an app folder still in use changes nothing (after retrying for a while)', () {
      final ops = FaultyOps()..failRename = (from, to) => from == app;
      final result = FolderSwap(ops: ops, retryFor: const Duration(milliseconds: 30)).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isFalse);
      expect(result.rolledBack, isFalse);
      expect(result.error, contains('still in use'));
      expect(ops.sleeps, greaterThan(0), reason: 'it retried');
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.1.0');
      expect(read('$incoming${sep}Mochi.exe'), 'Mochi 0.2.0');
    });

    test('a busy moment is waited out', () {
      var failures = 2;
      final ops = FaultyOps()..failRename = (from, to) => from == app && failures-- > 0;
      final result = FolderSwap(ops: ops).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isTrue);
      expect(ops.sleeps, 2);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.2.0');
    });

    test('rolls back when the new copy cannot be moved in: the old copy is back, the new one where it was', () {
      final ops = FaultyOps()..failRename = (from, to) => from == incoming;
      final result = FolderSwap(ops: ops, retryFor: Duration.zero).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isFalse);
      expect(result.rolledBack, isTrue);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.1.0');
      expect(read('$app${sep}data${sep}app.so'), 'app 0.1.0');
      expect(Directory('$app.old').existsSync(), isFalse);
      expect(read('$incoming${sep}Mochi.exe'), 'Mochi 0.2.0');
    });

    test('rolls back when the new copy turns out to have no Mochi.exe in place', () {
      final ops = FaultyOps();
      ops.failRename = (from, to) {
        // Something (an antivirus, say) takes Mochi.exe away as the copy goes in.
        if (from == incoming) File('$incoming${sep}Mochi.exe').deleteSync();
        return false;
      };
      // The check before the swap passes; the one after fails.
      final result = FolderSwap(ops: ops).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isFalse);
      expect(result.rolledBack, isTrue);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.1.0');
    });

    test('says where the old copy is if even the rollback fails', () {
      final ops = FaultyOps()..failRename = (from, to) => from == incoming || from == '$app.old';
      final result = FolderSwap(ops: ops, retryFor: Duration.zero).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isFalse);
      expect(result.rolledBack, isFalse);
      expect(result.error, contains('$app.old'));
      expect(read('$app.old${sep}Mochi.exe'), 'Mochi 0.1.0', reason: 'nothing is lost');
    });

    test('copies instead of renaming when the new copy is on another drive', () {
      final ops = FaultyOps()
        ..code = Platform.isWindows ? 17 : 18
        ..failRename = (from, to) => from == incoming;
      final result = FolderSwap(ops: ops).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isTrue);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.2.0');
      expect(read('$app${sep}data${sep}app.so'), 'app 0.2.0');
      expect(Directory(incoming).existsSync(), isFalse);
    });

    test('installs into an empty place too (no old copy)', () {
      Directory(app).deleteSync(recursive: true);
      final result = FolderSwap(ops: FaultyOps()).swap(incoming: incoming, target: app, requiredFile: 'Mochi.exe');
      expect(result.ok, isTrue);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.2.0');
      expect(Directory('$app.old').existsSync(), isFalse);
    });
  });

  group('copyDirectory and replaceFile', () {
    test('copies a whole folder and counts the bytes', () {
      appFolder('${temp.path}${sep}a', '1');
      final bytes = copyDirectory('${temp.path}${sep}a', '${temp.path}${sep}b');
      expect(read('${temp.path}${sep}b${sep}data${sep}app.so'), 'app 1');
      expect(Directory('${temp.path}${sep}b${sep}data${sep}flutter_assets').existsSync(), isTrue);
      expect(bytes, 'Mochi 1'.length + 'helper 1'.length + 'app 1'.length);
    });

    test('replaceFile puts the new helper in place, leaving nothing behind', () {
      final source = File('${temp.path}${sep}new.exe')..writeAsStringSync('helper 2');
      final target = File('${temp.path}${sep}bin${sep}mochi_hook.exe')
        ..parent.createSync()
        ..writeAsStringSync('helper 1');
      UpdateCli.replaceFile(source: source.path, target: target.path);
      expect(target.readAsStringSync(), 'helper 2');
      expect(target.parent.listSync().map((e) => e.path.split(sep).last), ['mochi_hook.exe']);
      // The same bytes again: nothing to do.
      UpdateCli.replaceFile(source: source.path, target: target.path);
      expect(target.readAsStringSync(), 'helper 2');
    });
  });

  group('mochi_hook update', () {
    late BridgePaths paths;
    late UpdateFiles files;
    late String app, staged;
    late FakeProcesses processes;

    setUp(() {
      paths = BridgePaths('${temp.path}${sep}Mochi', windows: Platform.isWindows);
      files = UpdateFiles(paths);
      app = '${temp.path}${sep}Programs${sep}Mochi';
      staged = '${files.staged}${sep}2${sep}Mochi';
      appFolder(app, '0.1.0');
      appFolder(staged, '0.2.0');
      File(files.applying).writeAsStringSync('{"version":"0.2.0","build":2}');
      processes = FakeProcesses()..running[4242] = '$app${sep}Mochi.exe';
    });

    UpdateCli cli() => UpdateCli(
      environment: const {},
      out: StringBuffer(),
      paths: paths,
      processes: processes,
      swap: FolderSwap(ops: FaultyOps()),
      clock: () => DateTime.utc(2026, 11, 7, 12),
    );

    List<String> args() => ['update', '--staged', staged, '--app', app, '--pid', '4242', '--version', '0.2.0', '--build', '2'];

    test('waits for Mochi to quit, swaps, refreshes the hooks\' helper, says so and starts Mochi again', () async {
      // Claude Code is connected: the hooks run the copy in Mochi's folder.
      File(paths.installedHelper)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('helper 0.1.0');
      final code = await cli().run(args());
      expect(code, 0);
      expect(processes.waited, [4242]);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.2.0');
      expect(read(paths.installedHelper), 'helper 0.2.0');
      expect(jsonDecode(read(files.result)), {'ok': true, 'version': '0.2.0', 'build': 2, 'at': '2026-11-07T12:00:00.000Z'});
      expect(File(files.applying).existsSync(), isFalse);
      expect(processes.launched.single.exe, '$app${sep}Mochi.exe');
      expect(processes.launched.single.workingDirectory, app);
      expect(read(files.log), contains('installed 0.2.0'));
    });

    test("doesn't create the hooks' helper when Claude Code isn't connected", () async {
      expect(await cli().run(args()), 0);
      expect(File(paths.installedHelper).existsSync(), isFalse);
    });

    test("leaves everything for the next launch when Mochi doesn't quit", () async {
      processes.stubborn.add(4242);
      final code = await cli().run(args());
      expect(code, 1);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.1.0');
      expect(read(files.ready), contains('0.2.0'), reason: 'ready again for the next launch');
      expect(jsonDecode(read(files.result))['ok'], isFalse);
      expect(processes.launched, isEmpty, reason: 'Mochi is still running');
    });

    test('a failed swap is rolled back, reported, and the old Mochi starts again', () async {
      final ops = FaultyOps()..failRename = (from, to) => from == staged;
      final code = await UpdateCli(
        environment: const {},
        out: StringBuffer(),
        paths: paths,
        processes: processes,
        swap: FolderSwap(ops: ops, retryFor: Duration.zero),
      ).run(args());
      expect(code, 1);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.1.0');
      final result = jsonDecode(read(files.result)) as Map;
      expect(result['ok'], isFalse);
      expect(result['error'], contains('stayed as it was'));
      expect(processes.launched.single.exe, '$app${sep}Mochi.exe');
    });

    test('refuses to run without its arguments', () async {
      expect(await cli().run(['update', '--app', app]), 64);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.1.0');
    });
  });

  group('mochi_hook launch', () {
    test('waits for the old process, then starts the exe with what follows --', () async {
      final processes = FakeProcesses()..running[77] = 'old';
      final code = await UpdateCli(environment: const {}, out: StringBuffer(), paths: BridgePaths(temp.path), processes: processes)
          .run(['launch', '--after', '77', '--exe', '${temp.path}${sep}Mochi.exe', '--', '--installed']);
      expect(code, 0);
      expect(processes.waited, [77]);
      expect(processes.launched.single.exe, '${temp.path}${sep}Mochi.exe');
      expect(processes.launched.single.arguments, ['--installed']);
    });

    test('warm does nothing at all (the app runs it once so Windows has looked the program over)', () async {
      final processes = FakeProcesses();
      final out = StringBuffer();
      final code = await UpdateCli(environment: const {}, out: out, paths: BridgePaths(temp.path), processes: processes).run(['warm']);
      expect(code, 0);
      expect(out.toString(), isEmpty);
      expect(processes.launched, isEmpty);
      expect(Directory(temp.path).listSync(), isEmpty, reason: 'not even a log line');
    });

    test('never starts a second Mochi while the first is still there', () async {
      final processes = FakeProcesses()..stubborn.add(77);
      final code = await UpdateCli(environment: const {}, out: StringBuffer(), paths: BridgePaths(temp.path), processes: processes)
          .run(['launch', '--after', '77', '--exe', 'Mochi.exe']);
      expect(code, 1);
      expect(processes.launched, isEmpty);
    });
  });

  group('mochi_hook uninstall', () {
    late BridgePaths paths;
    late InstallLayout layout;
    late FakeProcesses processes;
    late FakeUninstallSystem system;
    late StringBuffer out;

    const runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
    const approvedKey = r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';

    setUp(() {
      paths = BridgePaths('${temp.path}${sep}Mochi', windows: Platform.isWindows);
      layout = InstallLayout(
        installDirectory: '${temp.path}${sep}Programs${sep}Mochi',
        startMenuDirectory: '${temp.path}${sep}Start Menu',
        windows: Platform.isWindows,
      );
      appFolder(layout.installDirectory, '0.2.0');
      appFolder(layout.oldDirectory, '0.1.0');
      File(layout.shortcut)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('lnk');
      // The user's data: settings, the link, the hooks' helper, a pending update.
      File(paths.settingsFile)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"petName":"Bao"}');
      File('${paths.linkDirectory}${sep}credentials.dpapi')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('sealed');
      File(paths.installedHelper)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('helper');
      Directory(UpdateFiles(paths).staged).createSync(recursive: true);
      // The installed Mochi is running.
      File(paths.bridgeFile)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(BridgeEndpoint(port: 1, token: 't' * 40, pid: 900).toJson()));
      processes = FakeProcesses()..running[900] = layout.exe;
      system = FakeUninstallSystem()
        ..keys[layout.uninstallKey] = {'DisplayName': 'Mochi'}
        ..keys[runKey] = {'Mochi': '"${layout.exe}"', 'Other': r'"C:\Other\other.exe"'}
        ..keys[approvedKey] = {'Mochi': 'x'};
      out = StringBuffer();
    });

    Future<int> uninstall() => UpdateCli(
      environment: {'CLAUDE_CONFIG_DIR': '${temp.path}${sep}claude'},
      out: out,
      paths: paths,
      layout: layout,
      processes: processes,
      system: system,
      pause: Duration.zero,
    ).run(['uninstall']);

    test('quits Mochi and removes the app, its shortcut and entries; your settings and link stay', () async {
      expect(await uninstall(), 0);
      expect(processes.terminated, [900]);
      expect(Directory(layout.installDirectory).existsSync(), isFalse);
      expect(Directory(layout.oldDirectory).existsSync(), isFalse);
      expect(system.deleteLater, [layout.installDirectory]);
      expect(File(layout.shortcut).existsSync(), isFalse);
      expect(system.keys.containsKey(layout.uninstallKey), isFalse);
      expect(system.keys[runKey], {'Other': r'"C:\Other\other.exe"'});
      expect(system.keys[approvedKey], isEmpty);
      expect(Directory(UpdateFiles(paths).directory).existsSync(), isFalse);
      expect(read(paths.settingsFile), '{"petName":"Bao"}');
      expect(read('${paths.linkDirectory}${sep}credentials.dpapi'), 'sealed');
      expect(read(paths.installedHelper), 'helper');
      expect(out.toString(), contains('Mochi is uninstalled.'));
      expect(out.toString(), contains(paths.home));
    });

    test('never stops a Mochi running from somewhere else, or touches a startup entry for another copy', () async {
      processes.running[900] = r'C:\src\mochi\build\Release\Mochi.exe';
      system.keys[runKey] = {'Mochi': r'"C:\src\mochi\build\Release\Mochi.exe"'};
      expect(await uninstall(), 0);
      expect(processes.terminated, isEmpty);
      expect(system.keys[runKey], {'Mochi': r'"C:\src\mochi\build\Release\Mochi.exe"'});
      expect(Directory(layout.installDirectory).existsSync(), isFalse);
    });

    test("mentions Claude Code's hooks when they're still connected", () async {
      final settings = File('${temp.path}${sep}claude${sep}settings.json')..parent.createSync(recursive: true);
      settings.writeAsStringSync('{}');
      ClaudeHookInstaller(
        settingsFile: settings.path,
        backupDirectory: paths.backupsDirectory,
        helperPath: paths.installedHelper,
        style: Platform.isWindows ? HookCommandStyle.exec : HookCommandStyle.shell,
      ).install();
      expect(await uninstall(), 0);
      expect(out.toString(), contains("Claude Code still has Mochi's hooks"));
      expect(read(settings.path), contains('mochi_hook'), reason: 'Claude Code settings are never changed by the uninstall');
    });
  });

  test(
    'the real helper (dart run) installs a staged copy',
    () async {
      final paths = BridgePaths('${temp.path}${sep}Mochi', windows: Platform.isWindows);
      final app = '${temp.path}${sep}Programs${sep}Mochi';
      final staged = '${temp.path}${sep}Mochi${sep}update${sep}staged${sep}2${sep}Mochi';
      appFolder(app, '0.1.0');
      appFolder(staged, '0.2.0');
      // A process that has already gone, standing in for the Mochi that quit.
      final gone = await Process.start(Platform.resolvedExecutable, ['--version']);
      await gone.exitCode;
      final result = await Process.run(
        _dartExecutable(),
        ['run', 'bin/mochi_hook.dart', 'update', '--staged', staged, '--app', app, '--pid', '${gone.pid}', '--version', '0.2.0', '--build', '2', '--no-relaunch'],
        environment: {'MOCHI_DESKTOP_HOME': paths.home},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, isEmpty);
      expect(read('$app${sep}Mochi.exe'), 'Mochi 0.2.0');
      expect(read('$app.old${sep}Mochi.exe'), 'Mochi 0.1.0');
      expect(jsonDecode(read(UpdateFiles(paths).result))['ok'], isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _dartExecutable() {
  final current = Platform.resolvedExecutable;
  final name = current.split(RegExp(r'[\\/]')).last.toLowerCase();
  if (name == 'dart' || name == 'dart.exe') return current;
  final normalized = current.replaceAll(r'\', '/');
  final cache = normalized.indexOf('/bin/cache/');
  if (cache > 0) return '${normalized.substring(0, cache)}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
  return 'dart';
}
