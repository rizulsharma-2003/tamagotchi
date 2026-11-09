// Docs/SPRINT_2.md W23b: the pure parts of the agent's last features. The mark-read command allows exactly one Gmail tool and
// no check ever does; the Mochi Watcher's text is the Mac's (a rendered example from MochiWatcher.swift, and the Swift
// source itself when this checkout has it); the Fire URL rule; and the token's vault has its own file and entropy.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/agent/agent_cloud.dart';
import 'package:mochi_desktop/src/core/agent/agent_command.dart';
import 'package:mochi_desktop/src/core/agent/agent_settings.dart';
import 'package:mochi_desktop/src/core/agent/cloud_token_vault.dart';
import 'package:mochi_desktop/src/platform/cloud_token_vault.dart';
import 'package:mochi_link/mochi_link.dart' show AgentSource;
import 'package:mochi_wire/mochi_wire.dart' show BridgePaths;

const String fire = 'https://api.anthropic.com/v1/claude_code/routines/trig_012eNQcMDqqHfiWcYGoXKjts/fire';

void main() {
  group('The mark-read command', () {
    test('allows ToolSearch and exactly one Gmail tool: unlabel_thread', () {
      final arguments = AgentCommand.markReadArguments;
      expect(AgentCommand.markReadTool, 'mcp__claude_ai_Gmail__unlabel_thread');
      final at = arguments.indexOf('--allowedTools');
      expect(arguments.sublist(at), ['--allowedTools', 'ToolSearch', 'mcp__claude_ai_Gmail__unlabel_thread']);
      // Everything after --allowedTools is allowed: nothing but those two, and nothing after them.
      expect(arguments.where((each) => each.startsWith('mcp__')).toList(), ['mcp__claude_ai_Gmail__unlabel_thread']);
      expect(arguments, containsAllInOrder(['-p', '--model', 'haiku', '--output-format', 'json', '--setting-sources', 'project']));
      expect(arguments, containsAllInOrder(['--no-session-persistence', '--permission-mode', 'dontAsk', '--tools', 'ToolSearch']));
      expect(arguments, isNot(contains('--json-schema')));
    });

    test('no check, briefing or probe ever allows it, with any sources', () {
      for (final sources in [
        AgentSource.values,
        [AgentSource.gmail],
        <AgentSource>[],
      ]) {
        final arguments = AgentCommand.arguments(sources);
        expect(arguments.any((each) => each.contains('unlabel')), isFalse);
        expect(arguments, isNot(contains(AgentCommand.markReadTool)));
      }
      expect(AgentConnections.probeArguments, isNot(contains(AgentCommand.markReadTool)));
      for (final source in AgentSource.values) {
        expect(source.readTools, isNot(contains(AgentCommand.markReadTool)));
        expect(source.readTools.where((tool) => tool.contains('send') || tool.contains('delete') || tool.contains('trash') || tool.contains('label')),
            source == AgentSource.gmail ? ['mcp__claude_ai_Gmail__list_labels'] : isEmpty);
      }
      final prompt = AgentCommand.prompt(mode: const AgentBriefing(), sources: AgentSource.values, now: DateTime(2026, 11, 9, 9));
      expect(prompt, contains('Read only: never send, change or delete anything.'));
    });

    test('the prompt is the Mac\'s, and carries the thread ids only', () {
      expect(
        AgentCommand.markReadPrompt(['abc', 'def']),
        'Mark these Gmail threads as read: for each thread id, call unlabel_thread with labelIds ["UNREAD"]. Do nothing else; '
        'if the tool isn\'t loaded yet, use tool search to load it. Thread ids: abc, def. Finish with one line saying how many you marked.',
      );
    });

    test('succeeded: a result without an error; not an error, not empty, not a list of events without a result', () {
      expect(AgentCommand.markReadSucceeded(jsonEncode({'type': 'result', 'is_error': false, 'result': 'Marked 2.'})), isTrue);
      expect(AgentCommand.markReadSucceeded(jsonEncode({'type': 'result', 'result': ''})), isTrue, reason: 'the Mac only needs a result');
      expect(AgentCommand.markReadSucceeded(jsonEncode({'type': 'result', 'is_error': true, 'result': 'No'})), isFalse);
      expect(AgentCommand.markReadSucceeded(jsonEncode({'type': 'result', 'is_error': false})), isFalse);
      expect(AgentCommand.markReadSucceeded(''), isFalse);
      expect(AgentCommand.markReadSucceeded('not json'), isFalse);
      expect(
        AgentCommand.markReadSucceeded(
          jsonEncode([
            {'type': 'system'},
            {'type': 'result', 'is_error': false, 'result': 'ok'},
          ]),
        ),
        isTrue,
      );
    });
  });

  group('The Fire URL', () {
    test('on Anthropic\'s API host, under the routines path, ending in /fire', () {
      expect(AgentCloud.isFireURL(fire), isTrue);
      expect(AgentCloud.isFireURL('https://example.com/fire'), isFalse);
      expect(AgentCloud.isFireURL('https://api.anthropic.com/v1/claude_code/routines/trig_1'), isFalse);
      expect(AgentCloud.isFireURL('https://api.anthropic.com.evil.test/v1/claude_code/routines/x/fire'), isFalse);
      expect(AgentCloud.isFireURL('http://api.anthropic.com/v1/claude_code/routines/x/fire'), isFalse);
      expect(AgentCloud.isFireURL('https://api.anthropic.com/v1/claude_code/routines/x/fire?x=1'), isFalse);
      expect(AgentCloud.isFireURL(''), isFalse);
    });
  });

  group('The Mochi Watcher', () {
    String? script({String token = 'sk-ant-oat01-abc_DEF-123', List<String> vips = const ['Amogh', '@insideedge.club'], String zone = 'Asia/Kolkata'}) =>
        AgentCloud.watcherScript(fireURL: fire, token: token, vips: vips, timeZone: zone);

    test('for the same trigger, zone and VIPs it is the Mac\'s script, character for character', () {
      final fixture = File('test/fixtures/watcher_from_mac.js').readAsStringSync();
      expect(script(), fixture);
    });

    test('the template is the one in the Mac\'s MochiWatcher.swift (when this checkout has it)', () {
      final swift = File('../../../Sources/TamagotchiCore/Agent/MochiWatcher.swift');
      if (!swift.existsSync()) return;
      final source = swift.readAsStringSync();
      final start = source.indexOf('#"""\n') + 5, end = source.indexOf('"""#');
      // Swift drops the newline before the closing delimiter.
      expect(AgentCloud.watcherTemplate, source.substring(start, end - 1));
    });

    test('fills in the trigger and time zone, with no placeholder left, and the wake lines the cloud understands', () {
      final text = script(vips: const [])!;
      expect(text, contains("fireUrl: '$fire'"));
      expect(text, contains("token: 'sk-ant-oat01-abc_DEF-123'"));
      expect(text, contains("timeZone: 'Asia/Kolkata'"));
      expect(text, isNot(contains('__')));
      expect(text, contains("fire_('new ' + since"));
      expect(text, contains("fire_('soon ' + "));
      expect(text, contains('headsUpMinutes: 10'));
      expect(text, contains('vips: [],'));
      expect(text, contains('onEventUpdated()'));
      expect(text, contains('-category:promotions'));
      expect(text, contains("fire_('new ' + since + ' ' + ids"));
    });

    test('VIPs become a JavaScript list: trimmed, control characters gone, quotes escaped', () {
      final text = script(vips: const ['Amogh', ' @insideedge.club ', '', 'a"b\'</script>\n@x.com'])!;
      expect(text, contains(r'vips: ["Amogh","@insideedge.club","a\"b'"'"r'</script>@x.com"],'));
      expect(AgentCloud.vipList([]), '[]');
      expect(AgentCloud.vipList(['x${String.fromCharCode(0x2028)}y']), r'["x\u2028y"]');
      expect(AgentCloud.vipList([for (var i = 0; i < 50; i++) 'v$i']), contains('"v39"'));
      expect(AgentCloud.vipList([for (var i = 0; i < 50; i++) 'v$i']), isNot(contains('"v40"')));
      expect(AgentCloud.vipList(['a' * 100]), '["${'a' * 80}"]');
    });

    test('refuses what could break the script, or isn\'t a Fire URL', () {
      expect(script(token: "abc'; alert(1); '"), isNull);
      expect(script(token: ''), isNull);
      expect(script(token: 'has space'), isNull);
      expect(AgentCloud.watcherScript(fireURL: 'https://example.com/fire', token: 'abc', timeZone: 'UTC'), isNull);
      expect(AgentCloud.watcherScript(fireURL: '', token: 'abc', timeZone: 'UTC'), isNull);
    });
  });

  group('The token\'s vault', () {
    test('is its own file and its own entropy, apart from the link\'s', () {
      final paths = BridgePaths(r'C:\Users\x\AppData\Local\Mochi', windows: true);
      final vault = DpapiCloudTokenVault(paths.join(paths.linkDirectory, 'cloud-trigger.dpapi'));
      expect(vault.path, r'C:\Users\x\AppData\Local\Mochi\Link\cloud-trigger.dpapi');
      expect(vault.path, isNot(endsWith('credentials.dpapi')));
      expect(utf8.decode(DpapiCloudTokenVault.entropy), 'mochi-cloud/v1 trigger token');
      expect(DpapiCloudTokenVault.entropy, isNot(utf8.encode('mochi-link/v1 credentials')));
      expect(vault.description, contains('Windows Data Protection'));
    });

    test('off Windows nothing is written: the token stays in memory', () {
      final directory = Directory.systemTemp.createTempSync('cloud_vault');
      addTearDown(() => directory.deleteSync(recursive: true));
      final vault = platformCloudTokenVault(BridgePaths(directory.path, windows: false));
      expect(vault, isA<MemoryCloudTokenVault>());
      expect(vault.save('x' * 30), isTrue);
      expect(vault.load(), 'x' * 30);
      vault.delete();
      expect(vault.load(), isNull);
      expect(directory.listSync(recursive: true), isEmpty);
    }, skip: Platform.isWindows ? 'Windows uses DPAPI (the next test)' : false);

    test('on Windows the token is sealed with DPAPI: saved, read back, not in the clear, removed', () {
      final directory = Directory.systemTemp.createTempSync('cloud_vault');
      addTearDown(() => directory.deleteSync(recursive: true));
      final vault = platformCloudTokenVault(BridgePaths(directory.path, windows: true));
      expect(vault, isA<DpapiCloudTokenVault>());
      final token = 'mochi-test-token-${'z' * 24}';
      expect(vault.save(token), isTrue);
      final file = File((vault as DpapiCloudTokenVault).path);
      expect(file.existsSync(), isTrue);
      expect(utf8.decode(file.readAsBytesSync(), allowMalformed: true), isNot(contains('mochi-test-token')), reason: 'sealed, not in the clear');
      expect(DpapiCloudTokenVault(file.path).load(), token, reason: 'a fresh vault (as after a restart) opens it');
      vault.delete();
      expect(file.existsSync(), isFalse);
      expect(vault.load(), isNull);
    }, skip: Platform.isWindows ? false : 'DPAPI exists only on Windows');

    test('a vault that has nothing (or can\'t be opened) says null', () {
      final directory = Directory.systemTemp.createTempSync('cloud_vault');
      addTearDown(() => directory.deleteSync(recursive: true));
      final vault = DpapiCloudTokenVault('${directory.path}/none.dpapi');
      expect(vault.load(), isNull);
      vault.delete();
    });
  });
}
