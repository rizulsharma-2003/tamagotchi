// "Connect Claude Code" in a temporary home (never the real ~/.claude), the credential vaults, the settings file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/hook_setup.dart';
import 'package:mochi_desktop/src/link/link_host.dart';
import 'package:mochi_desktop/src/platform/credential_vault.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'support/fakes.dart';

class _BrokenVault implements CredentialVault {
  @override
  String get description => 'broken';

  @override
  Future<LinkCredentials?> load() async => null;

  @override
  Future<void> save(LinkCredentials credentials) async => throw StateError('no keychain');

  @override
  Future<void> delete() async {}
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('mochi_desktop_platform'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('Connect Claude Code', () {
    late BridgePaths paths;
    late String settingsFile;
    late File bundled;

    HookSetup setup({String? helper, HookCommandStyle style = HookCommandStyle.shell}) =>
        HookSetup(paths: paths, settingsFile: settingsFile, style: style, bundledHelper: helper ?? bundled.path);

    setUp(() {
      paths = BridgePaths('${temp.path}/mochi', windows: false);
      settingsFile = '${temp.path}/home/.claude/settings.json';
      bundled = File('${temp.path}/app/mochi_hook')
        ..createSync(recursive: true)
        ..writeAsStringSync('helper v1');
      File(settingsFile)
        ..createSync(recursive: true)
        ..writeAsStringSync('{\n  "model": "opus",\n  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}\n}\n');
    });

    test("copies the helper into Mochi's folder, adds the hooks, and is idempotent", () async {
      final hooks = setup();
      hooks.refresh();
      expect(hooks.connected, isFalse);
      expect(hooks.inspection!.otherHookCount, 1);

      await hooks.connect();
      expect(hooks.problem, isNull);
      expect(hooks.connected, isTrue);
      expect(File(paths.installedHelper).readAsStringSync(), 'helper v1');
      expect(hooks.lastBackup, isNotNull);
      final settings = jsonDecode(File(settingsFile).readAsStringSync()) as Map;
      expect(settings['model'], 'opus');
      expect(jsonEncode(settings['hooks']['Stop']), contains('say done'));
      expect(jsonEncode(settings['hooks']['Stop']), contains(paths.installedHelper));

      final text = File(settingsFile).readAsStringSync();
      await hooks.connect();
      expect(File(settingsFile).readAsStringSync(), text, reason: 'connecting again changes nothing');
    });

    test('a newer helper replaces the installed one; removal leaves only the user\'s hooks', () async {
      final hooks = setup();
      await hooks.connect();
      bundled.writeAsStringSync('helper v2');
      await hooks.connect();
      expect(File(paths.installedHelper).readAsStringSync(), 'helper v2');

      await hooks.disconnect();
      expect(hooks.connected, isFalse);
      expect(hooks.inspection!.status, HookStatus.notInstalled);
      final settings = jsonDecode(File(settingsFile).readAsStringSync());
      expect(settings, {
        'model': 'opus',
        'hooks': {
          'Stop': [
            {
              'hooks': [
                {'type': 'command', 'command': 'say done'},
              ],
            },
          ],
        },
      });
    });

    test('problems are shown and nothing is written', () async {
      File(settingsFile).writeAsStringSync('{ not json');
      final hooks = setup();
      await hooks.connect();
      expect(hooks.problem, contains('valid JSON'));
      expect(File(settingsFile).readAsStringSync(), '{ not json');

      // A fresh folder with no helper in it, and none next to the app.
      final elsewhere = BridgePaths('${temp.path}/other', windows: false);
      final missing = HookSetup(paths: elsewhere, settingsFile: settingsFile, style: HookCommandStyle.shell, bundledHelper: null);
      File(settingsFile).writeAsStringSync('{}');
      await missing.connect();
      expect(missing.problem, contains("isn't next to the app"));
    });

    test('Windows writes the exec form (no shell)', () async {
      final hooks = setup(style: HookCommandStyle.exec);
      await hooks.connect();
      final stop = (jsonDecode(File(settingsFile).readAsStringSync())['hooks']['Stop'] as List).last['hooks'][0] as Map;
      expect(stop['command'], paths.installedHelper);
      expect(stop['args'], ['claude-hook', 'Stop']);
    });
  });

  group('Credential vaults', () {
    test('Keychain: the secret goes in on stdin, never on the command line', () async {
      final calls = <({List<String> arguments, String? input})>[];
      String? stored;
      Future<({int exitCode, String output})> security(List<String> arguments, {String? input}) async {
        calls.add((arguments: arguments, input: input));
        if (arguments.first == '-i') {
          stored = RegExp(r'-w (\S+)').firstMatch(input!)!.group(1);
          return (exitCode: 0, output: '');
        }
        if (arguments.first == 'find-generic-password') {
          return stored == null ? (exitCode: 44, output: '') : (exitCode: 0, output: '$stored\n');
        }
        stored = null;
        return (exitCode: 0, output: '');
      }

      final vault = KeychainVault(account: 'link:test', security: security);
      expect(await vault.load(), isNull);
      await vault.save(hostCredentials);
      expect(await vault.load(), hostCredentials);
      for (final call in calls) {
        expect(call.arguments.join(' '), isNot(contains(hostCredentials.secret)));
        expect(call.arguments.join(' '), isNot(contains(hostCredentials.key)));
      }
      expect(calls.firstWhere((call) => call.arguments.first == '-i').input, contains('-s "Mochi Desktop (development)" -a "link:test"'));
      await vault.delete();
      expect(await vault.load(), isNull);
    });

    test('DPAPI round trip (Windows only)', () async {
      final vault = DpapiVault('${temp.path}\\credentials.dpapi');
      await vault.save(hostCredentials);
      expect(File('${temp.path}\\credentials.dpapi').readAsStringSync(encoding: latin1), isNot(contains(hostCredentials.secret)));
      expect(await vault.load(), hostCredentials);
      await vault.delete();
      expect(await vault.load(), isNull);
    }, skip: !Platform.isWindows ? 'DPAPI runs on Windows only' : false);

    test("a room whose link can't be saved is deleted again", () async {
      final api = FakeLinkApi();
      final host = LinkHost(
        vault: _BrokenVault(),
        api: api,
        connect: (credentials) => throw StateError('never connects'),
        hostName: 'TEST-PC',
      );
      await host.showCode();
      await Future<void>.delayed(Duration.zero);
      expect(host.paired, isFalse);
      expect(host.problem, "Couldn't save the link on this PC.");
      expect(api.deleted.single, hostCredentials);
      host.dispose();
    });
  });

  group('Settings', () {
    test('saved as they change, read back, with safe defaults', () {
      final document = FileSettingsDocument('${temp.path}/mochi/settings.json');
      final settings = DesktopSettings(document);
      expect(settings.themeMode, ThemeMode.system);
      expect(settings.shareSummaries, isFalse, reason: 'off by default, as on the Mac');
      expect(settings.acceptCommands, isTrue);
      expect(settings.showPet, isTrue);
      settings
        ..themeMode = ThemeMode.dark
        ..shareSummaries = true
        ..petPosition = const Offset(12, 34)
        ..model = 'something else';
      for (var i = 0; i < 40; i++) {
        settings.markHandled('c$i');
      }
      final again = DesktopSettings(FileSettingsDocument('${temp.path}/mochi/settings.json'));
      expect(again.themeMode, ThemeMode.dark);
      expect(again.shareSummaries, isTrue);
      expect(again.petPosition, const Offset(12, 34));
      expect(again.model, 'haiku');
      expect(again.wasHandled('c39'), isTrue);
      expect(again.wasHandled('c5'), isFalse, reason: 'only the newest 30 are kept');
      expect(DesktopSettings(FileSettingsDocument('${temp.path}/missing.json')).themeMode, ThemeMode.system);
    });
  });
}
