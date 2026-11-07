// "Install Mochi" against Windows itself (it runs on Windows only; elsewhere these are skipped): a real Start-menu
// shortcut carrying Mochi's AppUserModelID, and the Settings › Apps entry under a scratch key (or the test layout's own
// `Mochi.Test` key), everything in a temporary folder and removed again. Plus a check that runs everywhere: the
// version in pubspec.yaml is the one the app reports.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/desktop.dart';
import 'package:mochi_desktop/src/platform/win32_install.dart';
import 'package:mochi_desktop/src/update/self_install.dart';
import 'package:mochi_wire/mochi_wire.dart';

void main() {
  test("pubspec.yaml's version is the app's (scripts/release-windows.sh sets both)", () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((line) => line.startsWith('version: '));
    expect(line, 'version: $appVersion+$appBuild');
  });

  final skip = Platform.isWindows ? false : 'the Start menu and the registry are on Windows only';

  test('a shortcut carries Mochi’s AppUserModelID', () {
    final temp = Directory.systemTemp.createTempSync('mochi_shortcut');
    addTearDown(() => temp.deleteSync(recursive: true));
    final system = Win32InstallSystem();
    final path = '${temp.path}\\Mochi (test).lnk';
    system.createShortcut(
      path: path,
      target: Platform.resolvedExecutable,
      workingDirectory: temp.path,
      description: 'Mochi, your Claude Code companion',
      appUserModelId: InstallLayout.appUserModelId,
    );
    expect(File(path).existsSync(), isTrue);
    expect(system.shortcutAppId(path), 'InsideEdge.Mochi');
  }, skip: skip);

  test('the Settings › Apps entry is written, read and removed (a scratch key)', () {
    final key = 'Software\\MochiTests\\Uninstall-${DateTime.now().microsecondsSinceEpoch}';
    final system = Win32InstallSystem();
    addTearDown(() {
      system.deleteUninstallEntry(key);
      system.deleteUninstallEntry('Software\\MochiTests');
    });
    system.writeUninstallEntry(key, {'DisplayName': 'Mochi (test)', 'DisplayVersion': '0.2.0', 'NoModify': 1, 'EstimatedSize': 36000});
    expect(system.readUninstallValue(key, 'DisplayName'), 'Mochi (test)');
    expect(system.readUninstallValue(key, 'DisplayVersion'), '0.2.0');
    final dword = Process.runSync('reg', ['query', 'HKCU\\$key', '/v', 'EstimatedSize']);
    expect(dword.stdout as String, contains('REG_DWORD'));
    expect(dword.stdout as String, contains('0x8ca0'));
    system.deleteUninstallEntry(key);
    expect(system.readUninstallValue(key, 'DisplayName'), isNull);
  }, skip: skip);

  test('Install Mochi into a test layout, for real, then the uninstall entry is cleared', () async {
    final temp = Directory.systemTemp.createTempSync('mochi_install');
    final layout = InstallLayout.resolve(environment: {InstallLayout.rootEnvironmentKey: '${temp.path}\\root'});
    final system = Win32InstallSystem();
    addTearDown(() {
      system.deleteUninstallEntry(layout.uninstallKey);
      temp.deleteSync(recursive: true);
    });
    final from = '${temp.path}\\Downloads\\Mochi';
    Directory('$from\\data').createSync(recursive: true);
    File('$from\\Mochi.exe').writeAsStringSync('Mochi');
    File('$from\\mochi_hook.exe').writeAsStringSync('helper');
    File('$from\\data\\app.so').writeAsStringSync('app');
    final installer = SelfInstaller(layout: layout, executable: '$from\\Mochi.exe', version: '0.2.0', system: system, copyInBackground: false);
    expect(installer.installed, isFalse);
    expect(await installer.install(), isTrue, reason: installer.problem);
    expect(File(layout.exe).readAsStringSync(), 'Mochi');
    expect(system.shortcutAppId(layout.shortcut), 'InsideEdge.Mochi');
    expect(layout.uninstallKey, endsWith('Mochi.Test'), reason: 'never the real entry');
    expect(system.readUninstallValue(layout.uninstallKey, 'UninstallString'), layout.uninstallCommand);
    expect(system.readUninstallValue(layout.uninstallKey, 'DisplayVersion'), '0.2.0');
    expect(SelfInstaller(layout: layout, executable: layout.exe, version: '0.2.0', system: system).installed, isTrue);
  }, skip: skip);
}
