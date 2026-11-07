// The helper's Windows calls against Windows itself (skipped elsewhere): waiting for a process, its path, ending it,
// the registry values the uninstall removes (a scratch key), and the folder swap when a program in the app folder is
// still running (Windows won't move a folder with a running program in it, which is why the helper waits for Mochi).

@TestOn('windows')
library;

import 'dart:io';

import 'package:mochi_wire/mochi_wire.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('mochi_windows'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// A program that runs until it's ended: Windows' ping, copied in as Mochi.exe.
  Future<Process> fakeMochi(String folder) async {
    Directory(folder).createSync(recursive: true);
    File(r'C:\Windows\System32\PING.EXE').copySync('$folder\\Mochi.exe');
    return Process.start('$folder\\Mochi.exe', ['-n', '60', '127.0.0.1']);
  }

  test('waits for a process, knows its path, ends it', () async {
    final control = Win32ProcessControl();
    final process = await fakeMochi('${temp.path}\\app');
    expect(control.executablePath(process.pid)?.toLowerCase(), '${temp.path}\\app\\Mochi.exe'.toLowerCase());
    expect(control.waitForExit(process.pid, const Duration(milliseconds: 300)), isFalse);
    expect(control.terminate(process.pid), isTrue);
    expect(control.waitForExit(process.pid, const Duration(seconds: 5)), isTrue);
    expect(control.executablePath(process.pid), isNull);
    // A pid that isn't running at all counts as gone.
    expect(control.waitForExit(0x7FFFFFF0, const Duration(milliseconds: 10)), isTrue);
  });

  test('a file held open in the app folder holds the swap back (nothing changes); once closed it goes through', () {
    final app = '${temp.path}\\Programs\\Mochi';
    final staged = '${temp.path}\\staged\\Mochi';
    Directory('$app\\data').createSync(recursive: true);
    File('$app\\Mochi.exe').writeAsStringSync('old');
    final held = File('$app\\data\\app.so')..writeAsStringSync('old');
    Directory(staged).createSync(recursive: true);
    File('$staged\\Mochi.exe').writeAsStringSync('new');

    final handle = held.openSync(mode: FileMode.append);
    final busy = FolderSwap(retryFor: const Duration(milliseconds: 500)).swap(incoming: staged, target: app, requiredFile: 'Mochi.exe');
    handle.closeSync();
    expect(busy.ok, isFalse);
    expect(busy.error, contains('still in use'));
    expect(File('$app\\Mochi.exe').readAsStringSync(), 'old', reason: 'nothing changed');
    expect(File('$staged\\Mochi.exe').readAsStringSync(), 'new');

    final swapped = FolderSwap().swap(incoming: staged, target: app, requiredFile: 'Mochi.exe');
    expect(swapped.ok, isTrue, reason: swapped.error);
    expect(File('$app\\Mochi.exe').readAsStringSync(), 'new');
    expect(File('$app.old\\Mochi.exe').readAsStringSync(), 'old');
  });

  test('Windows lets the folder of a running program move (the helper still waits for Mochi to quit first)', () async {
    final app = '${temp.path}\\Programs\\Mochi';
    final staged = '${temp.path}\\staged\\Mochi';
    final running = await fakeMochi(app);
    try {
      Directory(staged).createSync(recursive: true);
      File('$staged\\Mochi.exe').writeAsStringSync('new');
      final swapped = FolderSwap(retryFor: const Duration(seconds: 2)).swap(incoming: staged, target: app, requiredFile: 'Mochi.exe');
      expect(swapped.ok, isTrue, reason: swapped.error);
      expect(File('$app\\Mochi.exe').readAsStringSync(), 'new');
      expect(File('$app.old\\Mochi.exe').lengthSync(), greaterThan(1000), reason: 'the running copy moved with its folder');
    } finally {
      Win32ProcessControl().terminate(running.pid);
    }
  });

  test("copies keep Windows' downloaded-from-the-internet mark; removeDownloadMarks takes it off", () {
    final downloads = '${temp.path}\\Downloads\\Mochi';
    Directory('$downloads\\data').createSync(recursive: true);
    for (final name in ['Mochi.exe', 'data\\app.so']) {
      File('$downloads\\$name').writeAsStringSync('x');
      File('$downloads\\$name:Zone.Identifier').writeAsStringSync('[ZoneTransfer]\r\nZoneId=3\r\n');
    }
    final copy = '${temp.path}\\Programs\\Mochi.new';
    copyDirectory(downloads, copy);
    expect(File('$copy\\Mochi.exe:Zone.Identifier').existsSync(), isTrue, reason: 'Windows copies the mark along');
    expect(removeDownloadMarks(copy), 2);
    expect(File('$copy\\Mochi.exe:Zone.Identifier').existsSync(), isFalse);
    expect(File('$copy\\data\\app.so:Zone.Identifier').existsSync(), isFalse);
    expect(File('$copy\\Mochi.exe').readAsStringSync(), 'x');
    expect(File('$downloads\\Mochi.exe:Zone.Identifier').existsSync(), isTrue, reason: 'the download itself is left as it is');
  });

  test('the registry values the uninstall reads and removes (a scratch key)', () {
    final key = 'Software\\MochiTests\\Uninstall-${DateTime.now().microsecondsSinceEpoch}';
    addTearDown(() => Process.runSync('reg', ['delete', r'HKCU\Software\MochiTests', '/f']));
    expect(Process.runSync('reg', ['add', 'HKCU\\$key', '/v', 'Mochi', '/t', 'REG_SZ', '/d', r'"C:\Mochi\Mochi.exe"', '/f']).exitCode, 0);
    final system = Win32UninstallSystem();
    expect(system.readString(key, 'Mochi'), r'"C:\Mochi\Mochi.exe"');
    expect(system.readString(key, 'Nothing'), isNull);
    system.deleteValue(key, 'Mochi');
    expect(system.readString(key, 'Mochi'), isNull);
    system.deleteKey(key);
    expect(Process.runSync('reg', ['query', 'HKCU\\$key']).exitCode, isNot(0));
    system.deleteKey(key);
  });

  test('the app folder goes a few seconds after the helper quits', () async {
    final folder = Directory('${temp.path}\\Programs\\Mochi with spaces')..createSync(recursive: true);
    File('${folder.path}\\Mochi.exe').writeAsStringSync('x');
    await Win32UninstallSystem().deleteAfterExit(folder.path);
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (folder.existsSync() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(folder.existsSync(), isFalse);
  });
}
