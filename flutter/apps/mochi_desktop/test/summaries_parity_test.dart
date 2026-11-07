// Turn summaries and session cards, checked against the Mac's TurnSummaryRunner and PhoneController (docs/SPRINT_2.md
// W10): the same `claude -p` (Haiku, no tools, none of the user's settings, nothing saved) with the Mac's system prompt
// character for character, the same prompt, the same alert and card on the phones, and Claude's words read only while
// summaries are shared with a paired phone.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/turn_summaries.dart';
import 'package:mochi_link/mochi_link.dart';

import 'support/fakes.dart';

/// TamagotchiCore/Phone/TurnSummaries.swift's `systemPrompt`, as Swift reads its multi-line literal (a trailing `\`
/// joins two lines).
const String macSystemPrompt =
    "You write short notes for a phone about what Claude, a coding assistant, just did in one of the user's projects, so the user can decide what to ask next. Reply with JSON only, no code fence:\n"
    '{"done": "...", "session": "...", "next": ["..."]}\n'
    '- done: at most 160 characters. What Claude did or found this turn, the most important part first. Plain words: no markdown, no file paths.\n'
    '- session: at most 110 characters. What this session is working on overall, using the earlier notes.\n'
    "- next: up to 2 requests of at most 40 characters the user could send next, in the user's voice (\"Run the tests\", \"Yes, do the migration too\"). If Claude asked a question, offer the likely answers.\n"
    "Never invent work the message doesn't mention.";

final DateTime noon = DateTime(2026, 11, 7, 12);

void main() {
  test('the same claude -p as the Mac, with its system prompt to the character', () {
    expect(TurnSummarizer.systemPrompt, macSystemPrompt);
    expect(TurnSummarizer.arguments, [
      '-p',
      '--model',
      'haiku',
      '--output-format',
      'json',
      '--setting-sources',
      'project',
      '--tools',
      '',
      '--strict-mcp-config',
      '--no-session-persistence',
      '--system-prompt',
      macSystemPrompt,
    ]);
  });

  test('the same prompt: the project, the files, the last three notes and Claude’s message', () {
    final report = TurnReport(
      sessionId: 's1',
      project: 'web',
      message: 'Fixed the login bug.',
      files: [for (var i = 0; i < 25; i++) 'f$i.ts'],
      at: noon,
    );
    expect(
      TurnSummarizer.prompt(report, earlier: ['one', 'two', 'three', 'four']),
      'Project: web\n\n'
      'Files changed: ${[for (var i = 0; i < 20; i++) 'f$i.ts'].join(', ')}\n\n'
      'Earlier notes on this session:\n- two\n- three\n- four\n\n'
      "Claude's last message:\nFixed the login bug.",
    );
    expect(
      TurnSummarizer.prompt(TurnReport(sessionId: 's1', project: 'web', message: null, files: const [], at: noon)),
      "Project: web\n\nClaude's last message:\n(none)",
    );
  });

  test('the note in Haiku’s reply, cleaned and cut as the Mac cuts it', () {
    final result = TurnSummarizer.result(
      jsonEncode({'type': 'result', 'is_error': false, 'result': 'Sure:\n```json\n{"done": "Fixed **login**.", "session": "Auth", "next": ["Run the tests", "Ship it", "Third"]}\n```'}),
    )!;
    final summary = TurnSummarizer.parse(result)!;
    expect((summary.done, summary.session), ('Fixed **login**.', 'Auth'));
    expect(summary.next, ['Run the tests', 'Ship it'], reason: 'at most two');
    expect(TurnSummarizer.result(jsonEncode({'is_error': true, 'result': 'x'})), isNull);
  });

  group('On the desktop', () {
    late TestDesktop t;
    setUp(() => t = TestDesktop.make(saved: hostCredentials, clock: () => noon));
    tearDown(() => t.dispose());

    Future<void> room(List<Map<String, Object?>> devices) async {
      await t.desktop.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      t.socket.sync(devices: devices);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      t.desktop.phone.tick();
    }

    const pc = {'id': 'dev_pc', 'role': 'host', 'platform': 'windows', 'name': 'TEST-PC', 'online': true};
    const phone = {'id': 'dev_phone', 'role': 'pocket', 'platform': 'iOS', 'name': "Rizul's iPhone", 'online': true};

    test('Claude’s words are read only while summaries are shared with a paired phone (the Mac’s summary flag)', () async {
      t.desktop.settings.shareSummaries = true;
      await room([pc]);
      expect(t.desktop.link.paired, isFalse, reason: 'a room with nobody in it');
      expect(File(t.desktop.paths.summariesFlagFile).existsSync(), isFalse);
      t.socket.sync(devices: [pc, phone]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      t.desktop.phone.tick();
      expect(File(t.desktop.paths.summariesFlagFile).existsSync(), isTrue);
      t.desktop.settings.shareSummaries = false;
      expect(File(t.desktop.paths.summariesFlagFile).existsSync(), isFalse);
    });

    test('a finished turn: Haiku’s note, the alert and the card the Mac sends', () async {
      t.desktop.settings.shareSummaries = true;
      await room([pc, phone]);
      t.claude.output = FakeClaude.result('{"done": "Fixed the login bug.", "session": "Auth work", "next": ["Run the tests"]}');
      final at = noon;
      t.desktop.phone.record(hook('UserPromptSubmit', at: at));
      t.desktop.phone.record(hook('PostToolUse', tool: 'Edit', file: 'auth.ts', at: at));
      t.desktop.phone.record(hook('Stop', summary: 'I fixed the login bug in auth.ts.', at: at));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final run = t.claude.runs.single;
      expect(run.arguments, TurnSummarizer.arguments);
      expect(run.input, "Project: web\n\nFiles changed: auth.ts\n\nClaude's last message:\nI fixed the login bug in auth.ts.");
      final frame = t.socket.sentFrames('send', 'alert').single;
      expect(frame['push'], {'kind': 'alert', 'priority': 10, 'category': 'claude-turn', 'threadId': 's1'}, reason: 'the Mac’s priority 10');
      final alert = LinkAlert.open({...frame, 'from': hostCredentials.device}, room: hostCredentials.room, roomKey: roomKey)!;
      expect((alert.title, alert.subtitle, alert.body), ('web', 'Claude finished', 'Fixed the login bug.'));
      final info = alert.userInfo;
      expect((info['session'], info['project']), ('s1', 'web'));
      expect(info['card'], {
        'id': 's1',
        'project': 'web',
        'phase': 'done',
        'summary': {'done': 'Fixed the login bug.', 'session': 'Auth work', 'next': ['Run the tests']},
        'files': ['auth.ts'],
        'finishedAt': (noon.millisecondsSinceEpoch / 1000).roundToDouble(),
      });
    });
  });
}
