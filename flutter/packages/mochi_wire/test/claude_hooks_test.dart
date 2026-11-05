import 'dart:convert';
import 'dart:io';

import 'package:mochi_wire/mochi_wire.dart';
import 'package:test/test.dart';

/// Every test works in its own temporary home: never the real ~/.claude.
void main() {
  late Directory temp;
  late String settings;
  late String helper;
  late String backups;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mochi_wire_hooks');
    settings = '${temp.path}/home/.claude/settings.json';
    backups = '${temp.path}/mochi/Backups';
    helper = '${temp.path}/mochi/bin/mochi_hook';
    File(helper)
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  ClaudeHookInstaller installer({HookCommandStyle style = HookCommandStyle.shell, String? helperPath}) =>
      ClaudeHookInstaller(settingsFile: settings, backupDirectory: backups, helperPath: helperPath ?? helper, style: style);

  Map<String, Object?> read() => (jsonDecode(File(settings).readAsStringSync()) as Map).cast<String, Object?>();

  void write(Object json) => File(settings)
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

  final userSettings = {
    'model': 'opus',
    'permissions': {
      'allow': ['Bash(npm test)'],
      'deny': <Object?>[],
    },
    'hooks': {
      'Stop': [
        {
          'matcher': '',
          'hooks': [
            {'type': 'command', 'command': '/usr/local/bin/notify-me'},
          ],
        },
      ],
      'PreToolUse': [
        {
          'hooks': [
            {
              'type': 'command',
              'command':
                  "'/Users/me/Library/Application Support/MacTamagotchi/bin/mactamagotchi-hook' claude-hook PreToolUse 2>/dev/null || true",
              'timeout': 5,
            },
          ],
        },
      ],
    },
    'statusLine': {'type': 'command', 'command': 'echo hi'},
  };

  test('installs into a missing settings.json, idempotently', () {
    final first = installer().install();
    expect(first.changed, isTrue);
    expect(first.backup, isNull, reason: 'nothing to back up');
    final hooks = read()['hooks']! as Map;
    expect(hooks.keys, containsAll(ClaudeHookEvent.values.map((event) => event.wireName)));
    final stop = ((hooks['Stop'] as List).single as Map)['hooks'] as List;
    expect(stop.single, {'type': 'command', 'command': "'$helper' claude-hook Stop 2>/dev/null || true", 'timeout': 5});
    final end = ((hooks['SessionEnd'] as List).single as Map)['hooks'] as List;
    expect((end.single as Map).containsKey('timeout'), isFalse);
    expect(installer().inspect().status, HookStatus.installed);

    final before = File(settings).readAsStringSync();
    final second = installer().install();
    expect(second.changed, isFalse);
    expect(File(settings).readAsStringSync(), before);
  });

  test("keeps the user's other settings and hooks (and the Mac app's), and backs up first", () {
    write(userSettings);
    final change = installer().install(now: DateTime(2026, 11, 5, 9, 30));
    expect(change.backup, isNotNull);
    expect(jsonDecode(File(change.backup!).readAsStringSync()), userSettings);
    final after = read();
    expect(after['model'], 'opus');
    expect(after['permissions'], userSettings['permissions']);
    expect(after['statusLine'], userSettings['statusLine']);
    final stop = (after['hooks']! as Map)['Stop'] as List;
    expect(stop.first, (userSettings['hooks']! as Map)['Stop'][0], reason: 'the existing group comes first, untouched');
    expect(((stop.last as Map)['hooks'] as List).single, isA<Map<String, Object?>>());
    final pre = (after['hooks']! as Map)['PreToolUse'] as List;
    expect(jsonEncode(pre.first), contains('mactamagotchi-hook'));
    expect(after.keys.toList(), ['model', 'permissions', 'hooks', 'statusLine'], reason: 'key order is kept');
    final inspection = installer().inspect();
    expect(inspection.otherHookCount, 2);
    expect(inspection.status, HookStatus.installed);
  });

  test('removal takes out only our handlers', () {
    write(userSettings);
    installer().install();
    final removed = installer().uninstall();
    expect(removed.changed, isTrue);
    expect(read(), userSettings);
    expect(installer().inspect().status, HookStatus.notInstalled);
    expect(installer().uninstall().changed, isFalse);
  });

  test('removing from a file that had no hooks before leaves no hooks key', () {
    write({'model': 'sonnet'});
    installer().install();
    installer().uninstall();
    expect(read(), {'model': 'sonnet'});
  });

  test('a moved helper shows as needing an update, and installing again replaces the old entries', () {
    installer().install();
    final moved = '${temp.path}/elsewhere/mochi_hook';
    File(moved)
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    final inspection = installer(helperPath: moved).inspect();
    expect(inspection.status, HookStatus.needsUpdate);
    expect(inspection.outdated, contains('Stop'));
    installer(helperPath: moved).install();
    final text = File(settings).readAsStringSync();
    expect(text, contains(moved));
    expect(text, isNot(contains("'$helper'")));
    expect(installer(helperPath: moved).inspect().status, HookStatus.installed);
  });

  test('Windows exec form: no shell, so paths with spaces need no quoting', () {
    const windowsHelper = r'C:\Users\Jane Doe\AppData\Local\Mochi\bin\mochi_hook.exe';
    final handler = HookSettingsMerger.handler(helperPath: windowsHelper, event: ClaudeHookEvent.stop, style: HookCommandStyle.exec);
    expect(handler, {
      'type': 'command',
      'command': windowsHelper,
      'args': ['claude-hook', 'Stop'],
      'timeout': 5,
    });
    expect(HookSettingsMerger.isOurs(handler), isTrue);
    expect(
      HookSettingsMerger.isOurs({
        'type': 'command',
        'command': r'C:\tools\mochi_hook_backup.exe',
        'args': ['other'],
      }),
      isFalse,
    );
    expect(HookSettingsMerger.isOurs({'type': 'command', 'command': "'/x/mactamagotchi-hook' claude-hook Stop"}), isFalse);

    installer(style: HookCommandStyle.exec).install();
    expect(installer(style: HookCommandStyle.exec).inspect().status, HookStatus.installed);
    // Switching styles counts as outdated and is cleaned up on the next install.
    expect(installer().inspect().status, HookStatus.needsUpdate);
    installer().install();
    expect(HookSettingsMerger.installed(read()).values.every((handlers) => handlers.length == 1), isTrue);
  });

  test('refuses invalid JSON and odd shapes, and changes nothing', () {
    File(settings)
      ..createSync(recursive: true)
      ..writeAsStringSync('{"model": "opus",');
    expect(() => installer().install(), throwsA(isA<HookInstallException>()));
    expect(File(settings).readAsStringSync(), '{"model": "opus",');
    expect(installer().inspect().status, HookStatus.unreadable);

    write({'hooks': 'nope'});
    expect(() => installer().install(), throwsA(isA<HookInstallException>()));
    write({
      'hooks': {'Stop': 'nope'},
    });
    expect(() => installer().install(), throwsA(isA<HookInstallException>()));
    write(['not', 'an', 'object']);
    expect(() => installer().install(), throwsA(isA<HookInstallException>()));
  });

  test('a missing helper is refused', () {
    File(helper).deleteSync();
    expect(() => installer().install(), throwsA(isA<HookInstallException>()));
    expect(File(settings).existsSync(), isFalse);
  });

  test('flags disableAllHooks and managed-hooks-only', () {
    write({'disableAllHooks': true});
    final managed = File('${temp.path}/managed-settings.json')..writeAsStringSync('{"allowManagedHooksOnly": true}');
    final inspection = ClaudeHookInstaller(
      settingsFile: settings,
      backupDirectory: backups,
      helperPath: helper,
      style: HookCommandStyle.shell,
      managedSettingsFile: managed.path,
    ).inspect();
    expect(inspection.hooksDisabled, isTrue);
    expect(inspection.managedHooksOnly, isTrue);
  });

  test('follows a symlinked settings.json and keeps the link', () {
    final real = File('${temp.path}/dotfiles/claude-settings.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"model": "opus"}\n');
    Directory('${temp.path}/home/.claude').createSync(recursive: true);
    Link(settings).createSync(real.path);
    installer().install();
    expect(FileSystemEntity.isLinkSync(settings), isTrue);
    expect(jsonDecode(real.readAsStringSync())['hooks'], isNotNull);
  });

  test('where settings.json is', () {
    expect(ClaudeHookInstaller.defaultSettingsFile(environment: {'HOME': '/Users/me'}, windows: false), '/Users/me/.claude/settings.json');
    expect(
      ClaudeHookInstaller.defaultSettingsFile(environment: {'USERPROFILE': r'C:\Users\Jane Doe'}, windows: true),
      r'C:\Users\Jane Doe\.claude\settings.json',
    );
    expect(
      ClaudeHookInstaller.defaultSettingsFile(environment: {'HOME': '/Users/me', 'CLAUDE_CONFIG_DIR': '/tmp/cc'}, windows: false),
      '/tmp/cc/settings.json',
    );
    expect(
      BridgePaths.resolve(environment: {'LOCALAPPDATA': r'C:\Users\J\AppData\Local'}, windows: true).installedHelper,
      r'C:\Users\J\AppData\Local\Mochi\bin\mochi_hook.exe',
    );
  });
}
