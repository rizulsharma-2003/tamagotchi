// Docs/SPRINT_2.md W23a: the agent's real launch (the Mac-side check of what the Windows app starts): a stand-in `claude`
// script records its arguments, environment, folder and input; a timeout ends the process; stopping ends it; and the
// agent's controller stops it when it is turned off. POSIX only (the script is `sh`).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/agent/agent_command.dart';
import 'package:mochi_desktop/src/core/agent/agent_controller.dart';
import 'package:mochi_desktop/src/core/agent/agent_settings.dart';
import 'package:mochi_desktop/src/core/claude_cli.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/json_store.dart';
import 'package:mochi_link/mochi_link.dart';

import 'support/agent_fakes.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('agent_process'));
  tearDown(() => directory.deleteSync(recursive: true));

  String script(String body) {
    final file = File('${directory.path}/claude')..writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('chmod', ['+x', file.path]);
    return file.path;
  }

  Map<String, String> base() => {
    'HOME': directory.path,
    'ANTHROPIC_API_KEY': 'sk-secret',
    'ANTHROPIC_AUTH_TOKEN': 'token',
    'CLAUDE_CODE_SESSION': 'other-session',
    'MOCHI_CLAUDE_BIN': '/x',
    'MCP_CONNECTION_NONBLOCKING': 'true',
    'LANG': 'en_US.UTF-8',
  };

  ProcessClaudeRunner runner(String executable) => AgentClaude.runner(
    executable: executable,
    workingDirectory: '${directory.path}/Assistant',
    baseEnvironment: base(),
    windows: false,
  );

  Future<bool> alive(int pid) async => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  Future<int> pidOf(String name) async {
    for (var i = 0; i < 100; i++) {
      final file = File('${directory.path}/$name');
      if (file.existsSync() && file.readAsStringSync().trim().isNotEmpty) return int.parse(file.readAsStringSync().trim());
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('$name never appeared');
  }

  group('The launch', () {
    test('the exact arguments, the exact environment, the empty folder, the prompt on stdin', () async {
      final claude = script(
        'printf "%s\\n" "\$@" > "${directory.path}/args.txt"\n'
        'env > "${directory.path}/env.txt"\n'
        'pwd > "${directory.path}/cwd.txt"\n'
        'cat > "${directory.path}/stdin.txt"\n'
        'echo \'{"type":"result","is_error":false,"structured_output":{"headline":"h","emails":[],"events":[],"tasks":[]}}\'',
      );
      final run = await runner(claude).run(
        AgentCommand.arguments(AgentSource.values),
        input: AgentCommand.prompt(mode: const AgentBriefing(), sources: AgentSource.values, now: DateTime.utc(2026, 11, 3, 9)),
        timeout: const Duration(seconds: 20),
      );
      expect(run.ok, isTrue);
      expect(AgentDigest.parse(run.output)?.headline, 'h');
      // `printf "%s\n" "$@"`: one line per argument.
      expect(File('${directory.path}/args.txt').readAsLinesSync(), AgentCommand.arguments(AgentSource.values));
      final env = {
        for (final line in File('${directory.path}/env.txt').readAsLinesSync())
          if (line.contains('=')) line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
      };
      expect(env['ENABLE_CLAUDEAI_MCP_SERVERS'], 'true');
      expect(env['MCP_CONNECTION_NONBLOCKING'], 'false');
      expect(env.keys.where((key) => key.startsWith('ANTHROPIC_')), isEmpty, reason: 'never an API key: the run bills your subscription');
      expect(env.keys.where((key) => key.startsWith('CLAUDE') || key.startsWith('MOCHI_')), isEmpty, reason: 'not tied to another Claude session');
      expect(env['NO_COLOR'], '1');
      expect(File('${directory.path}/cwd.txt').readAsStringSync().trim(), endsWith('/Assistant'), reason: 'an empty folder: it sees none of your projects');
      expect(File('${directory.path}/stdin.txt').readAsStringSync(), contains('Read only: never send, change or delete anything.'));
    }, skip: Platform.isWindows);

    test('the runner is built with those arguments’ environment and no more', () {
      final made = runner('/bin/claude');
      expect(made.environment['ENABLE_CLAUDEAI_MCP_SERVERS'], 'true');
      expect(made.environment['MCP_CONNECTION_NONBLOCKING'], 'false');
      expect(made.environment.containsKey('ANTHROPIC_API_KEY'), isFalse);
      expect(made.executable, '/bin/claude');
      expect(made.workingDirectory, endsWith('/Assistant'));
    });
  });

  group('Ending a run', () {
    test('a timeout kills the process', () async {
      final claude = script('echo \$\$ > "${directory.path}/pid"\nexec sleep 30');
      final watch = Stopwatch()..start();
      final run = await runner(claude).run(AgentConnections.probeArguments, input: AgentConnections.probePrompt, timeout: const Duration(milliseconds: 400));
      expect(run.timedOut, isTrue);
      expect(run.ok, isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      final pid = await pidOf('pid');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await alive(pid), isFalse, reason: 'the run is gone, not left sleeping');
    }, skip: Platform.isWindows);

    test('stop ends it at once', () async {
      final claude = script('echo \$\$ > "${directory.path}/pid"\nexec sleep 30');
      final made = runner(claude);
      final running = made.run(AgentConnections.probeArguments, input: '', timeout: const Duration(minutes: 5));
      final pid = await pidOf('pid');
      expect(await alive(pid), isTrue);
      made.stop();
      final run = await running.timeout(const Duration(seconds: 10));
      expect(run.ok, isFalse);
      expect(run.timedOut, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await alive(pid), isFalse);
    }, skip: Platform.isWindows);

    test('the agent stops it when it is turned off, and when Mochi quits', () async {
      final claude = script('echo \$\$ > "${directory.path}/pid"\nexec sleep 30');
      final settings = DesktopSettings(MemorySettingsDocument());
      final controller = AgentController(
        settings: settings,
        store: MemoryJsonStore(),
        runner: () => runner(claude),
        phone: AgentPhoneFake(),
        say: (line, seconds) {},
        zone: () => AgentZone.utc,
        firstTickAfter: const Duration(hours: 1),
        tickEvery: const Duration(hours: 1),
      );
      addTearDown(controller.dispose);
      controller.start();
      settings.agent = const AgentSettings(enabled: true);
      final looking = controller.refreshConnections();
      final pid = await pidOf('pid');
      expect(await alive(pid), isTrue);
      expect(controller.checkingConnections, isTrue);
      settings.agent = const AgentSettings(enabled: false);
      await looking.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await alive(pid), isFalse, reason: 'turned off: the run is gone');
      expect(controller.checkingConnections, isFalse);

      File('${directory.path}/pid').deleteSync();
      settings.agent = const AgentSettings(enabled: true);
      final again = controller.refreshConnections();
      final second = await pidOf('pid');
      controller.stop();
      await again.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await alive(second), isFalse, reason: 'quitting: the run is gone');
    }, skip: Platform.isWindows);
  });
}
