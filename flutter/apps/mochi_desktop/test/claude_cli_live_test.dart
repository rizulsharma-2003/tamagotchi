// Against the installed Claude Code CLI, opt-in (two short Haiku calls on your account):
//
//   MOCHI_CLAUDE_LIVE=1 flutter test test/claude_cli_live_test.dart
//
// Checks that the exact `claude -p` invocations Mochi uses (Ask Mochi, turn summaries) are accepted by the CLI and
// answer in the shape Mochi reads, from an empty temporary folder with the cleaned environment.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/ask_mochi.dart';
import 'package:mochi_desktop/src/core/claude_cli.dart';
import 'package:mochi_desktop/src/core/session_store.dart';
import 'package:mochi_desktop/src/core/turn_summaries.dart';

void main() {
  final live = Platform.environment['MOCHI_CLAUDE_LIVE'] == '1';

  test(
    'Ask Mochi and the turn summarizer run against the real CLI',
    () async {
      final executable = ClaudeLocator.locate();
      expect(executable, isNotNull, reason: 'Claude Code is installed');
      final temp = Directory.systemTemp.createTempSync('mochi_claude_live');
      addTearDown(() => temp.deleteSync(recursive: true));
      final runner = ProcessClaudeRunner(
        executable: executable!,
        workingDirectory: temp.path,
        environment: ClaudeLocator.cleanEnvironment(Platform.environment, windows: Platform.isWindows),
      );

      final ask = AskMochi(sessions: SessionStore(), runner: () => runner, cue: (_) {});
      final answer = await ask.ask('Reply with exactly the word: meow');
      expect(answer.ok, isTrue, reason: answer.text);
      expect(answer.text.toLowerCase(), contains('meow'));

      final run = await runner.run(
        TurnSummarizer.arguments,
        input: TurnSummarizer.prompt(
          TurnReport(
            sessionId: 's',
            project: 'web',
            message: 'I fixed the date parsing bug in utils.ts and all 48 tests pass now.',
            files: const ['utils.ts'],
            at: DateTime.now(),
          ),
        ),
        timeout: const Duration(seconds: 60),
      );
      expect(run.ok, isTrue);
      final summary = TurnSummarizer.parse(TurnSummarizer.result(run.output)!);
      expect(summary, isNotNull);
      expect(summary!.done, isNotEmpty);
      // ignore: avoid_print
      print('ask: ${answer.text} | summary: ${summary.done}');
    },
    skip: live ? false : 'set MOCHI_CLAUDE_LIVE=1 to run against the installed Claude Code',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
