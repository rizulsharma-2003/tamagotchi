// Ask Mochi on Windows, v1: quick commands on the spot, everything else to a one-off `claude -p` that can only search
// the web. The Mac's Ask Mochi (Sources/App/Features/Assistant) runs a long-lived helper session with tools that act
// on the Mac and can message other Claude sessions after an approval card; on Windows that comes in v2 (see
// docs/MOCHI_LINK_PLAN.md phase 11). Here nothing can change the PC or reach another Claude session.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'claude_cli.dart';
import 'pet_cues.dart';
import 'quick_commands.dart';
import 'session_store.dart';
import 'turn_summaries.dart';

/// Opens an https link in the default browser.
abstract interface class UrlOpener {
  Future<bool> open(Uri url);
}

/// How a request ended.
class AskOutcome {
  const AskOutcome(this.text, {this.ok = true});

  final String text;
  final bool ok;

  @override
  String toString() => 'AskOutcome(${ok ? 'ok' : 'failed'}: $text)';
}

enum AskState { working, done, failed }

/// One request and its answer, for the main window's list.
class AskExchange {
  AskExchange({required this.id, required this.text, required this.fromPhone, required this.at});

  final String id;
  final String text;

  /// It came from a paired phone rather than this PC.
  final bool fromPhone;
  final DateTime at;
  AskState state = AskState.working;
  String? reply;
}

/// The safe `claude -p` Ask Mochi runs on Windows: the web search tool only, no user settings, no MCP servers, nothing
/// saved, in an empty private folder.
abstract final class AskLaunch {
  static List<String> arguments({required String model, required String petName}) => [
    '-p',
    '--model',
    model,
    '--output-format',
    'json',
    '--setting-sources',
    'project',
    '--strict-mcp-config',
    '--no-session-persistence',
    '--permission-mode',
    'default',
    '--tools',
    'WebSearch',
    '--allowedTools',
    'WebSearch',
    '--system-prompt',
    systemPrompt(petName),
  ];

  /// One line without quotes or shell metacharacters, so it survives npm's `claude.cmd` shim on Windows too.
  static String systemPrompt(String petName) =>
      'You are $petName, a small cat who lives on the user\'s computer next to Claude Code and keeps them company. '
      'People may spell your name Motchi. Answer in one or two short, friendly sentences (at most 40 words, no markdown, '
      'no lists). You can search the web with WebSearch when a question needs current facts. You have no other tools: '
      'you can\'t open apps, change settings, read files or message the user\'s Claude Code sessions from here, so if '
      'asked, say that comes to Windows later. Each request starts with a [Context] line about the computer right now '
      '(the time and the Claude sessions you know): use it, don\'t repeat it. Never claim you did something you didn\'t.';

  /// `[Context] …` then the request (Swift `BrainLaunch.message`).
  static String message({required String request, required String context, bool spoken = false}) =>
      '[Context] $context\n[Request${spoken ? ', spoken: names may be misheard' : ''}] $request';

  /// The reply, without markdown and at most 400 characters (Swift `AssistantController.cleanReply`).
  static String? cleanReply(String? text) {
    var reply = text?.trim();
    if (reply == null || reply.isEmpty) return null;
    reply = reply.replaceAll('**', '').replaceAll('`', '');
    return reply.length > 400 ? '${reply.substring(0, 399)}…' : reply;
  }
}

class AskMochi extends ChangeNotifier {
  AskMochi({
    required this.sessions,
    required ClaudeRunner? Function() runner,
    required void Function(PetCue cue) cue,
    UrlOpener? opener,
    String Function()? model,
    this.petName = 'Mochi',
    this.timeout = const Duration(seconds: 90),
    DateTime Function()? clock,
  }) : _runner = runner,
       _cue = cue,
       _opener = opener,
       _model = model ?? (() => 'haiku'),
       _clock = clock ?? DateTime.now;

  final SessionStore sessions;
  final ClaudeRunner? Function() _runner;
  final void Function(PetCue cue) _cue;
  final UrlOpener? _opener;
  final String Function() _model;
  final DateTime Function() _clock;
  final String petName;
  final Duration timeout;

  final List<AskExchange> _exchanges = [];
  int _counter = 0;

  /// Oldest first; at most eight.
  List<AskExchange> get exchanges => List.unmodifiable(_exchanges);

  bool get working => _exchanges.any((exchange) => exchange.state == AskState.working);

  /// Answers [text]. Never throws: problems come back as a failed outcome in words.
  Future<AskOutcome> ask(String text, {bool spoken = false, bool fromPhone = false}) async {
    final words = text.trim();
    if (words.isEmpty) return const AskOutcome('Say something first.', ok: false);
    final exchange = AskExchange(id: 'ask-${++_counter}', text: words, fromPhone: fromPhone, at: _clock());
    _exchanges.add(exchange);
    if (_exchanges.length > 8) _exchanges.removeRange(0, _exchanges.length - 8);
    _cue(PetCue.sending);
    notifyListeners();
    AskOutcome outcome;
    try {
      final quick = QuickCommands.parse(words);
      outcome = quick == null ? await _askClaude(words, spoken: spoken) : await perform(quick);
    } on Object catch (error) {
      outcome = AskOutcome('Something went wrong (${error.runtimeType}).', ok: false);
    }
    exchange
      ..state = outcome.ok ? AskState.done : AskState.failed
      ..reply = outcome.text;
    _cue(outcome.ok ? PetCue.replied : PetCue.failed);
    notifyListeners();
    return outcome;
  }

  /// A quick command, on the spot.
  Future<AskOutcome> perform(QuickCommand command) async {
    switch (command) {
      case SimpleCommand.sessionsStatus:
        return AskOutcome(sessions.statusSummary());
      case InteractCommand(:final kind):
        _cue(switch (kind) {
          'pet' => PetCue.pet,
          'play' => PetCue.play,
          _ => PetCue.treat,
        });
        return AskOutcome(switch (kind) {
          'pet' => 'Purr…',
          'play' => 'Pounce!',
          _ => 'Yum, thank you!',
        });
      case SimpleCommand.agentNews:
        return const AskOutcome("My agent (mail, calendar and Notion) isn't on Windows yet.", ok: false);
      case SiteCommand(:final url):
        final opener = _opener;
        if (opener == null || url.scheme != 'https') return const AskOutcome("I can't open links here yet.", ok: false);
        final opened = await opener.open(url);
        return opened ? AskOutcome('Opening ${url.host}.') : AskOutcome("I couldn't open ${url.host}.", ok: false);
      case MediaCommand() || VolumeCommand() || AppCommand():
        return const AskOutcome("I can't do that on Windows yet.", ok: false);
      case FocusCommand() ||
          SimpleCommand.stopFocus ||
          SimpleCommand.explore ||
          SimpleCommand.comeHome ||
          SimpleCommand.games ||
          SimpleCommand.recap ||
          SimpleCommand.decorate:
        return const AskOutcome("That trick isn't on Windows yet.", ok: false);
    }
  }

  /// What `claude -p` is told about this computer: the time and the sessions (names and states only).
  String context() {
    final now = _clock();
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final time = '${days[now.weekday - 1]} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final live = sessions.live.where((session) => session.project != null).take(8).toList();
    final list = live.isEmpty
        ? '$petName sees no Claude sessions right now.'
        : 'Claude sessions $petName knows: ${live.map((s) => '${s.project} — ${sessions.stateText(s)}').join('; ')}.';
    return 'Time $time. $list';
  }

  Future<AskOutcome> _askClaude(String text, {required bool spoken}) async {
    final runner = _runner();
    if (runner == null) {
      return const AskOutcome('I need Claude Code for that: install it from claude.com/claude-code, then ask again.', ok: false);
    }
    _cue(PetCue.working);
    final run = await runner.run(
      AskLaunch.arguments(model: _model(), petName: petName),
      input: AskLaunch.message(request: text, context: context(), spoken: spoken),
      timeout: timeout,
    );
    if (run.timedOut) return const AskOutcome('That took too long, so I stopped.', ok: false);
    final result = TurnSummarizer.result(run.output);
    if (run.exitCode == 0 && result != null) {
      return AskOutcome(AskLaunch.cleanReply(result) ?? 'Done!');
    }
    final lowered = '${run.errorTail} ${run.output}'.toLowerCase();
    if (lowered.contains('login') || lowered.contains('log in') || lowered.contains('authenticat')) {
      return const AskOutcome('Claude Code needs you to sign in: run `claude` once in a terminal, then ask again.', ok: false);
    }
    return AskOutcome('My helper Claude stopped unexpectedly (code ${run.exitCode}).', ok: false);
  }
}
