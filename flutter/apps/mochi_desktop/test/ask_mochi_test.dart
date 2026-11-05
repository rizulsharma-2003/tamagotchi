import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/ask_mochi.dart';
import 'package:mochi_desktop/src/core/claude_cli.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/core/quick_commands.dart';
import 'package:mochi_desktop/src/core/session_store.dart';
import 'package:mochi_desktop/src/core/turn_summaries.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'support/fakes.dart';

class _Opener implements UrlOpener {
  final List<Uri> opened = [];

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return true;
  }
}

void main() {
  group('QuickCommands (the same phrases as the Mac)', () {
    test('recognises short commands, with wake words and politeness', () {
      expect(QuickCommands.parse('Hey Mochi, status please'), SimpleCommand.sessionsStatus);
      expect(QuickCommands.parse("what's Claude doing?"), SimpleCommand.sessionsStatus);
      expect(QuickCommands.parse('pet'), const InteractCommand('pet'));
      expect(QuickCommands.parse("Let's play!"), const InteractCommand('play'));
      expect(QuickCommands.parse('volume to 30%'), const VolumeCommand(level: 30));
      expect(QuickCommands.parse('25 minute focus'), const FocusCommand(25));
      expect(QuickCommands.parse('open youtube'), SiteCommand(Uri.parse('https://www.youtube.com')));
      expect(QuickCommands.parse('open example.org'), SiteCommand(Uri.parse('https://example.org')));
      expect(QuickCommands.parse('open vs code', installedApps: ['Visual Studio Code']), const AppCommand('Visual Studio Code'));
      expect(QuickCommands.parse("what's pending"), SimpleCommand.agentNews);
      expect(QuickCommands.parse('Write me a haiku about cats'), isNull);
      expect(QuickCommands.parse('open the pod bay doors'), isNull);
    });
  });

  group('TurnSummarizer', () {
    final report = TurnReport(
      sessionId: 's',
      project: 'web',
      message:
          '## Done\nI fixed the **login** bug in [auth.ts](src/auth.ts).\n\n```ts\nconst x = 1;\n```\n- Added a test\n- Ran `npm test`',
      files: ['auth.ts', 'auth.test.ts', 'a.ts', 'b.ts'],
      at: DateTime(2026, 11, 5),
    );

    test('without the summarizer: plain sentences, or the files', () {
      expect(TurnSummarizer.fallback(report).done, 'Done. I fixed the login bug in auth.ts. Added a test. Ran npm test.');
      final quiet = TurnReport(sessionId: 's', project: 'web', message: null, files: report.files, at: report.at);
      expect(TurnSummarizer.fallback(quiet).done, 'Changed auth.ts, auth.test.ts, a.ts and 1 more.');
      final nothing = TurnReport(sessionId: 's', project: 'web', message: '', files: const [], at: report.at);
      expect(TurnSummarizer.fallback(nothing).done, 'Claude finished.');
      expect(TurnSummarizer.firstSentences('One. Two is longer. Three.', maxLength: 12), 'One.');
    });

    test('reads the model reply, tolerating a fence; the prompt carries earlier notes', () {
      final parsed = TurnSummarizer.parse(
        '```json\n{"done": "Fixed login.", "session": "Auth work", "next": ["Run tests", "Ship it", "More"]}\n```',
      );
      expect(parsed!.done, 'Fixed login.');
      expect(parsed.session, 'Auth work');
      expect(parsed.next, ['Run tests', 'Ship it']);
      expect(TurnSummarizer.parse('no json here'), isNull);
      expect(TurnSummarizer.result(FakeClaude.result('{"done": "x"}')), '{"done": "x"}');
      expect(TurnSummarizer.result(FakeClaude.result('oops', error: true)), isNull);
      final prompt = TurnSummarizer.prompt(report, earlier: ['a', 'b', 'c', 'd']);
      expect(prompt, contains('Project: web'));
      expect(prompt, contains('- b\n- c\n- d'));
      expect(prompt, isNot(contains('- a\n')));
      // Haiku, no tools, none of the user's settings, nothing saved.
      final args = TurnSummarizer.arguments;
      expect(args.sublist(0, 3), ['-p', '--model', 'haiku']);
      expect(args[args.indexOf('--tools') + 1], '');
      expect(args, containsAll(['--strict-mcp-config', '--no-session-persistence', '--setting-sources']));
    });

    test('SessionReports collects changed files per turn', () {
      final reports = SessionReports();
      reports.record(hook('UserPromptSubmit'));
      reports.record(hook('PostToolUse', tool: 'Edit', file: 'a.dart'));
      reports.record(hook('PostToolUse', tool: 'Edit', file: 'a.dart'));
      reports.record(hook('PostToolUse', tool: 'Write', file: 'b.dart'));
      final turn = reports.record(hook('Stop', summary: 'Done.'))!;
      expect(turn.files, ['a.dart', 'b.dart']);
      expect(turn.message, 'Done.');
      expect(turn.project, 'web');
    });
  });

  group('AskMochi', () {
    late SessionStore sessions;
    late FakeClaude claude;
    late List<PetCue> cues;
    late _Opener opener;
    AskMochi make({bool installed = true}) => AskMochi(
      sessions: sessions,
      runner: () => installed ? claude : null,
      cue: cues.add,
      opener: opener,
      clock: () => DateTime(2026, 11, 5, 14, 30),
    );

    setUp(() {
      sessions = SessionStore(clock: () => DateTime(2026, 11, 5, 14, 30));
      claude = FakeClaude(output: FakeClaude.result('**Hello** from `Mochi`!'));
      cues = [];
      opener = _Opener();
    });

    test('quick commands answer on the spot, without Claude', () async {
      sessions.apply(hook('UserPromptSubmit', project: 'web', at: DateTime(2026, 11, 5, 14, 27)));
      final ask = make();
      expect((await ask.ask('status')).text, 'web is working (3 min).');
      final pet = await ask.ask('good kitty');
      expect(pet.text, 'Purr…');
      expect(cues, contains(PetCue.pet));
      expect((await ask.ask('open github')).text, 'Opening github.com.');
      expect(opener.opened.single, Uri.parse('https://github.com'));
      final notYet = await ask.ask('volume up');
      expect(notYet.ok, isFalse);
      expect(claude.runs, isEmpty);
      expect(ask.exchanges.map((exchange) => exchange.state), everyElement(isNot(AskState.working)));
    });

    test('anything else goes to a safe claude -p: web search only, no settings, no MCP, nothing saved', () async {
      sessions.apply(hook('Notification', project: 'api', notificationType: 'permission_prompt', at: DateTime(2026, 11, 5, 14, 29)));
      final ask = make();
      final outcome = await ask.ask('What is the capital of Peru?', fromPhone: true);
      expect(outcome.ok, isTrue);
      expect(outcome.text, 'Hello from Mochi!');
      final run = claude.runs.single;
      final args = run.arguments;
      expect(args.first, '-p');
      expect(args[args.indexOf('--tools') + 1], 'WebSearch');
      expect(args[args.indexOf('--allowedTools') + 1], 'WebSearch');
      expect(args[args.indexOf('--permission-mode') + 1], 'default');
      expect(args, containsAll(['--strict-mcp-config', '--no-session-persistence']));
      expect(args[args.indexOf('--setting-sources') + 1], 'project');
      expect(args.join(' '), isNot(contains('SendMessage')));
      expect(args.join(' '), isNot(contains('--mcp-config')));
      expect(args.join(' '), isNot(contains('--dangerously')));
      // The system prompt survives npm's claude.cmd shim: one line, no quotes or cmd metacharacters.
      final prompt = args[args.indexOf('--system-prompt') + 1];
      expect(prompt, isNot(contains('\n')));
      expect(prompt, isNot(matches(RegExp(r'["&|<>^%]'))));
      expect(run.input, startsWith('[Context] Time Thu 14:30. Claude sessions Mochi knows: api — waiting for you.\n[Request] '));
      expect(run.input, endsWith('What is the capital of Peru?'));
      expect(ask.exchanges.last.fromPhone, isTrue);
      expect(cues, containsAllInOrder([PetCue.sending, PetCue.working, PetCue.replied]));
    });

    test('says what went wrong: no Claude Code, not signed in, too slow, a crash', () async {
      expect((await make(installed: false).ask('hi there friend')).text, contains('install it from claude.com/claude-code'));
      claude
        ..exitCode = 1
        ..output = ''
        ..errorTail = 'Invalid API key · Please run /login';
      expect((await make().ask('hi there friend')).text, contains('sign in'));
      claude
        ..errorTail = 'boom'
        ..exitCode = 3;
      expect((await make().ask('hi there friend')).text, 'My helper Claude stopped unexpectedly (code 3).');
      claude.timedOut = true;
      final slow = await make().ask('hi there friend');
      expect(slow.text, 'That took too long, so I stopped.');
      expect(slow.ok, isFalse);
      expect(cues.last, PetCue.failed);
    });
  });

  group('ClaudeLocator', () {
    test('Windows: the native installer, npm, then PATH with PATHEXT', () {
      final env = {
        'USERPROFILE': r'C:\Users\Jane',
        'APPDATA': r'C:\Users\Jane\AppData\Roaming',
        'LOCALAPPDATA': r'C:\Users\Jane\AppData\Local',
        'PATH': r'C:\tools;C:\Windows',
        'PATHEXT': '.COM;.EXE;.BAT;.CMD',
      };
      final candidates = ClaudeLocator.candidates(env, windows: true);
      expect(candidates.first, r'C:\Users\Jane\.local\bin\claude.exe');
      expect(candidates, contains(r'C:\Users\Jane\AppData\Roaming\npm\claude.cmd'));
      expect(candidates, contains(r'C:\tools\claude.cmd'));
      expect(
        ClaudeLocator.locate(environment: env, windows: true, exists: (path) => path == r'C:\tools\claude.exe'),
        r'C:\tools\claude.exe',
      );
      expect(
        ClaudeLocator.locate(environment: {...env, ClaudeLocator.pinKey: r'D:\claude.exe'}, windows: true, exists: (_) => false),
        isNull,
      );
    });

    test('the helper runs without the Claude session or Mochi variables of the app', () {
      final clean = ClaudeLocator.cleanEnvironment({
        'HOME': '/Users/me',
        'CLAUDECODE': '1',
        'CLAUDE_PROJECT_DIR': '/x',
        'MOCHI_DESKTOP_HOME': '/y',
        'VSCODE_PID': '1',
        'TERM_PROGRAM': 'vscode',
        'LANG': 'en_US.UTF-8',
      }, windows: false);
      expect(clean.keys, unorderedEquals(['HOME', 'LANG', 'PATH', 'NO_COLOR']));
      expect(clean['PATH'], startsWith('/Users/me/.local/bin:'));
      expect(WireText.identifier('ok', maxLength: 4), 'ok');
    });
  });
}
