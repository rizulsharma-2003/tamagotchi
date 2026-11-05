import 'dart:convert';

import 'package:mochi_wire/mochi_wire.dart';
import 'package:test/test.dart';

List<int> payload(Map<String, Object?> json) => utf8.encode(jsonEncode(json));

void main() {
  final now = DateTime.utc(2026, 11, 5, 12);

  WireEvent sanitize(Map<String, Object?> json, {bool summary = false, Map<String, String> environment = const {}, String? argument}) =>
      HookPayloadSanitizer.sanitize(payload(json), includeSummary: summary, environment: environment, now: now, argumentEvent: argument);

  group('HookPayloadSanitizer', () {
    test('keeps tool names and kinds of commands, never the command or the prompt', () {
      final event = sanitize({
        'hook_event_name': 'PreToolUse',
        'session_id': 'abc-123',
        'cwd': '/Users/me/code/mac-Tamagotchi',
        'tool_name': 'Bash',
        'tool_use_id': 'toolu_01',
        'tool_input': {'command': 'swift test --filter Secret && echo done', 'description': 'run the tests'},
        'permission_mode': 'default',
        'prompt': 'my secret prompt',
        'transcript_path': '/Users/me/.claude/projects/x.jsonl',
      });
      expect(event.event, 'PreToolUse');
      expect(event.origin, WireOrigin.hook);
      expect(event.session, 'abc-123');
      expect(event.tool, 'Bash');
      expect(event.toolCategory, 'shell');
      expect(event.toolUseId, 'toolu_01');
      expect(event.commandKind, 'test');
      expect(event.commandReliable, isTrue);
      expect(event.permissionMode, 'default');
      expect(event.project, 'mac-Tamagotchi');
      expect(event.projectPath, '/Users/me/code/mac-Tamagotchi');
      expect(event.projectKey, hasLength(12));
      expect(event.helperVersion, HelperInfo.version);
      final line = event.encodeLine();
      for (final secret in ['Secret', 'my secret prompt', 'transcript', 'run the tests', 'echo done']) {
        expect(line, isNot(contains(secret)));
      }
    });

    test("Claude's closing message and changed files only while summaries are shared", () {
      final stop = {'hook_event_name': 'Stop', 'session_id': 's1', 'last_assistant_message': 'Fixed the bug.\n\n\n\nAll tests pass.'};
      expect(sanitize(stop).summary, isNull);
      expect(sanitize(stop, summary: true).summary, 'Fixed the bug.\n\nAll tests pass.');
      expect(sanitize(stop, summary: true).withoutSummary.summary, isNull);

      final edit = {
        'hook_event_name': 'PostToolUse',
        'session_id': 's1',
        'tool_name': 'Edit',
        'tool_input': {'file_path': r'C:\Users\Jane Doe\code\app\lib\main.dart', 'old_string': 'a', 'new_string': 'b'},
      };
      expect(sanitize(edit).file, isNull);
      expect(sanitize(edit, summary: true).file, 'main.dart');
      expect(sanitize(edit, summary: true).encodeLine(), isNot(contains('Jane')));
    });

    test('Windows project folders: CLAUDE_PROJECT_DIR wins over cwd and is standardized', () {
      final event = sanitize(
        {'hook_event_name': 'SessionStart', 'session_id': 's2', 'cwd': r'C:\Users\Jane Doe\code\shop\src', 'source': 'startup'},
        environment: {'CLAUDE_PROJECT_DIR': r'c:\Users\Jane Doe\code\shop\', 'TERM_PROGRAM': 'vscode'},
      );
      expect(event.project, 'shop');
      expect(event.projectPath, r'C:\Users\Jane Doe\code\shop');
      expect(event.projectKey, ProjectIdentity.key(r'C:/Users/Jane Doe/code/shop'));
      expect(event.source, 'startup');
      expect(event.host, 'vscode');
    });

    test('a relative cwd is not a project', () {
      final event = sanitize({'hook_event_name': 'Stop', 'session_id': 's', 'cwd': 'code/app'});
      expect(event.project, isNull);
      expect(event.projectPath, isNull);
    });

    test('notifications, failures, session ends and batches', () {
      final notification = sanitize({
        'hook_event_name': 'Notification',
        'session_id': 's',
        'notification_type': 'permission_prompt',
        'message': 'Claude needs your\npermission to use Bash',
      });
      expect(notification.notificationType, 'permission_prompt');
      expect(notification.message, 'Claude needs your permission to use Bash');

      final failure = sanitize({
        'hook_event_name': 'PostToolUseFailure',
        'session_id': 's',
        'tool_name': 'PowerShell',
        'tool_input': {'command': 'dotnet test', 'run_in_background': true},
        'error': 'Exit code 3\nsome output',
        'is_interrupt': false,
        'duration_ms': 1200,
      });
      expect(failure.exitCode, 3);
      expect(failure.commandKind, 'test');
      expect(failure.backgrounded, isTrue);
      expect(failure.commandReliable, isFalse);
      expect(failure.durationMs, 1200);
      expect(failure.isInterrupt, isFalse);

      expect(sanitize({'hook_event_name': 'SessionEnd', 'session_id': 's', 'reason': 'prompt_input_exit'}).reason, 'prompt_input_exit');
      expect(sanitize({'hook_event_name': 'StopFailure', 'session_id': 's', 'error': 'rate_limit'}).reason, 'rate_limit');

      final batch = sanitize({
        'hook_event_name': 'PostToolBatch',
        'session_id': 's',
        'tool_calls': [
          {'tool_name': 'Read'},
          {'tool_name': 'Read'},
          {'tool_name': 'Grep'},
        ],
      });
      expect(batch.batchCount, 3);
      expect(batch.batchTools, ['Read', 'Grep']);
    });

    test('subagents are marked; ids are stable per payload', () {
      final inside = sanitize({
        'hook_event_name': 'PreToolUse',
        'session_id': 's',
        'tool_name': 'Read',
        'agent_id': 'a1',
        'agent_type': 'Explore',
      });
      expect(inside.inSubagent, isTrue);
      expect(inside.agentType, 'Explore');
      final start = sanitize({'hook_event_name': 'SubagentStart', 'session_id': 's', 'agent_id': 'a1'});
      expect(start.inSubagent, isNull);
      final again = sanitize({
        'hook_event_name': 'PreToolUse',
        'session_id': 's',
        'tool_name': 'Read',
        'agent_id': 'a1',
        'agent_type': 'Explore',
      });
      expect(again.id, inside.id);
      expect(start.id, isNot(inside.id));
      expect(inside.id, hasLength(32));
    });

    test('unparseable input still reports what a bounded scan finds', () {
      final raw = utf8.encode('{"hook_event_name": "Stop", "session_id": "s9", "cwd": "/tmp/p", "broken": ');
      final event = HookPayloadSanitizer.sanitize(raw, argumentEvent: 'Stop', now: now);
      expect(event.event, 'Stop');
      expect(event.session, 's9');
      expect(event.project, 'p');
      final empty = HookPayloadSanitizer.sanitize(const [], argumentEvent: 'SessionEnd', now: now);
      expect(empty.event, 'SessionEnd');
      final nothing = HookPayloadSanitizer.sanitize(const [], now: now);
      expect(nothing.event, 'Unknown');
    });

    test('identifiers with odd characters are dropped', () {
      final event = sanitize({'hook_event_name': 'PreToolUse', 'session_id': 'bad id/../', 'tool_name': 'Bash; rm'});
      expect(event.session, isNull);
      expect(event.tool, isNull);
    });
  });

  group('Classifiers', () {
    test('tool categories', () {
      expect(ToolCategoryClassifier.category('Read'), 'read');
      expect(ToolCategoryClassifier.category('PowerShell'), 'shell');
      expect(ToolCategoryClassifier.category('mcp__github__create_issue'), 'mcp');
      expect(ToolCategoryClassifier.category('Something'), 'other');
    });

    test('builds and tests, and when their exit status can be trusted', () {
      expect(CommandClassifier.classify('npm test'), const CommandKindResult('test', reliable: true));
      expect(CommandClassifier.classify('npm run build && npm test'), const CommandKindResult('test', reliable: true));
      expect(CommandClassifier.classify('swift build | tee log'), const CommandKindResult('build', reliable: false));
      expect(CommandClassifier.classify('flutter test; echo done'), const CommandKindResult('test', reliable: false));
      expect(CommandClassifier.classify(r'.\gradlew.bat assembleDebug'), const CommandKindResult('build', reliable: true));
      expect(CommandClassifier.classify('dotnet test 2>&1'), const CommandKindResult('test', reliable: true));
      expect(CommandClassifier.classify('echo "npm test && x"'), const CommandKindResult(null, reliable: false));
      expect(CommandClassifier.classify('ls -la'), const CommandKindResult(null, reliable: false));
      expect(CommandClassifier.classify('FOO=1 env -i pytest -q'), const CommandKindResult('test', reliable: true));
    });
  });

  group('WireText and paths', () {
    test('clean, paragraphs, identifier', () {
      expect(WireText.clean('  a\tb\n\nc  ', maxLength: 10), 'a b c');
      expect(WireText.clean('abcdef', maxLength: 4), 'abc…');
      expect(WireText.clean('\u0000\u0007', maxLength: 4), isNull);
      expect(WireText.identifier('ok-1_2.3:4', maxLength: 20), 'ok-1_2.3:4');
      expect(WireText.identifier('no spaces', maxLength: 20), isNull);
      expect(WireText.paragraphs('a\n\n\n\nb\n\n', maxLength: 100), 'a\n\nb');
    });

    test('standardize POSIX and Windows paths', () {
      expect(WirePath.standardize('/Users/me/./code//app/../web/'), '/Users/me/code/web');
      expect(WirePath.standardize(r'c:/Users/me\code\..\web\'), r'C:\Users\me\web');
      expect(WirePath.standardize(r'\\server\share\team\app'), r'\\server\share\team\app');
      expect(WirePath.lastComponent(r'C:\Users\me\web'), 'web');
      expect(WirePath.lastComponent('/'), '/');
      expect(WirePath.isAbsolute(r'D:\x'), isTrue);
      expect(WirePath.isAbsolute('x/y'), isFalse);
      // The same key as Swift's ProjectIdentity for the same POSIX path (SHA-256 prefix of the path).
      expect(ProjectIdentity.key('/Users/me/code/web'), 'c86611bd7712');
      expect(ProjectIdentity.key('/Users/me/code/web/'), 'c86611bd7712');
    });
  });
}
