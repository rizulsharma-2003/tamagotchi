// Ask Mochi on Windows: quick commands on the spot; everything else to Mochi's brain (ask_brain.dart), a long-lived
// helper Claude session with a few tools that can message the user's other Claude sessions, each message only after an
// approval card says Send. When the brain can't start, the v1 path answers instead: a one-off `claude -p` that can only
// search the web. The Mac's PC actions (open apps, media keys, volume, windows) are not here yet (W9).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ask_brain.dart';
import 'claude_cli.dart';
import 'paws_server.dart';
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

  /// What the brain is doing for this request (empty for quick commands and the one-off path).
  List<AskStep> steps = const [];
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

  /// One line without quotes or shell metacharacters, so it survives npm's `claude.cmd` shim on Windows too (the pet's
  /// name is one you typed, so it goes through [safeName]).
  static String systemPrompt(String petName) =>
      'You are ${safeName(petName)}, a small cat who lives on the user\'s computer next to Claude Code and keeps them company. '
      '${safeName(petName) == 'Mochi' ? 'People may spell your name Motchi. ' : ''}Answer in one or two short, friendly sentences (at most 40 words, no markdown, '
      'no lists). You can search the web with WebSearch when a question needs current facts. You have no other tools: '
      'you can\'t open apps, change settings, read files or message the user\'s Claude Code sessions from here, so if '
      'asked, say that comes to Windows later. Each request starts with a [Context] line about the computer right now '
      '(the time and the Claude sessions you know): use it, don\'t repeat it. Never claim you did something you didn\'t.';

  /// [name] with only letters, digits, spaces, hyphens, apostrophes and full stops (nothing cmd.exe treats
  /// specially), at most 24 characters; "Mochi" when nothing is left.
  static String safeName(String name) {
    final kept = name.replaceAll(RegExp(r"[^\p{L}\p{N} '.-]", unicode: true), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (kept.isEmpty) return 'Mochi';
    return kept.length > 24 ? kept.substring(0, 24).trim() : kept;
  }

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
    String Function()? petName,
    this.timeout = const Duration(seconds: 90),
    DateTime Function()? clock,
    BrainSetup? Function()? brainSetup,
    bool Function()? messagingAllowed,
    void Function(String message)? log,
    @visibleForTesting AskBrain Function(AskMochi ask)? brainFactory,
  }) : _runner = runner,
       _cue = cue,
       _opener = opener,
       _model = model ?? (() => 'haiku'),
       _petName = petName ?? (() => 'Mochi'),
       _clock = clock ?? DateTime.now {
    if (brainFactory != null) {
      brain = brainFactory(this);
    } else if (brainSetup != null) {
      brain = AskBrain(
        sessions: sessions,
        setup: brainSetup,
        model: _model,
        petName: _petName,
        context: context,
        tools: brainTool,
        messagingAllowed: messagingAllowed ?? () => true,
        clock: clock,
        log: log,
      );
    }
    brain?.addListener(_brainChanged);
  }

  final SessionStore sessions;

  /// Mochi's brain (null: v1 only).
  AskBrain? brain;

  /// The message waiting for Send or Don't send, if any.
  AskApproval? get approval => brain?.approval;

  /// Send (the card's button).
  void approve() => brain?.approve();

  /// Don't send.
  void decline() => brain?.decline();

  /// Stops the brain's request (a pending card is declined).
  void cancel() => brain?.cancel();

  /// The app is quitting: a pending card is a denial and the brain goes.
  void shutdown() => brain?.shutdown();

  AskExchange? _brainExchange;

  void _brainChanged() {
    _brainExchange?.steps = brain?.steps ?? const [];
    notifyListeners();
  }

  final ClaudeRunner? Function() _runner;
  final void Function(PetCue cue) _cue;
  final UrlOpener? _opener;
  final String Function() _model;
  final DateTime Function() _clock;
  final String Function() _petName;

  /// The pet's name (Settings › General), in Ask Mochi's words and its instructions to Claude.
  String get petName => _petName();
  final Duration timeout;

  /// Mochi's desktop adventures (W19), set by the app: "go explore" and "come home" (null: not here, as in tests of
  /// everything else).
  AskOutcome Function()? explore;
  AskOutcome Function()? comeHome;

  /// The rest of Mochi's tricks, set by the app: `games`, `recap`, `decorate`, `focus_start` (with minutes), `focus_stop`.
  final Map<String, AskOutcome Function(int? minutes)> tricks = {};

  final List<AskExchange> _exchanges = [];
  int _counter = 0;

  /// Oldest first; at most eight.
  List<AskExchange> get exchanges => List.unmodifiable(_exchanges);

  bool get working => _exchanges.any((exchange) => exchange.state == AskState.working);

  /// Answers [text]. Never throws: problems come back as a failed outcome in words.
  Future<AskOutcome> ask(String text, {bool spoken = false, bool fromPhone = false, String? commandId, AskTarget? target}) async {
    final words = text.trim();
    if (words.isEmpty) return const AskOutcome('Say something first.', ok: false);
    final exchange = AskExchange(id: 'ask-${++_counter}', text: words, fromPhone: fromPhone, at: _clock());
    _exchanges.add(exchange);
    if (_exchanges.length > 8) _exchanges.removeRange(0, _exchanges.length - 8);
    _cue(PetCue.sending);
    notifyListeners();
    AskOutcome outcome;
    try {
      final quick = target == null ? QuickCommands.parse(words) : null;
      outcome = quick == null
          ? await _askClaude(words, spoken: spoken, exchange: exchange, commandId: commandId, target: target)
          : await perform(quick);
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
        return _interact(kind);
      case SimpleCommand.agentNews:
        return const AskOutcome("My agent (mail, calendar and Notion) isn't on Windows yet.", ok: false);
      case SiteCommand(:final url):
        final opener = _opener;
        if (opener == null || url.scheme != 'https') return const AskOutcome("I can't open links here yet.", ok: false);
        final opened = await opener.open(url);
        return opened ? AskOutcome('Opening ${url.host}.') : AskOutcome("I couldn't open ${url.host}.", ok: false);
      case MediaCommand() || VolumeCommand() || AppCommand():
        return const AskOutcome("I can't do that on Windows yet.", ok: false);
      case SimpleCommand.explore:
        return explore?.call() ?? const AskOutcome("That trick isn't on Windows yet.", ok: false);
      case SimpleCommand.comeHome:
        return comeHome?.call() ?? const AskOutcome("That trick isn't on Windows yet.", ok: false);
      case FocusCommand() ||
          SimpleCommand.stopFocus ||
          SimpleCommand.games ||
          SimpleCommand.recap ||
          SimpleCommand.decorate:
        return const AskOutcome("That trick isn't on Windows yet.", ok: false);
    }
  }

  AskOutcome _interact(String kind) {
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
  }

  /// The brain's tools other than `approve`: Mochi's tricks, the Claude sessions, and https links.
  Future<PawsResult> brainTool(String name, Map<String, Object?> arguments) async {
    switch (name) {
      case 'claude_sessions':
        return PawsResult(sessions.statusSummary());
      case 'open_url':
        final url = arguments['url'];
        final uri = url is String ? Uri.tryParse(url.trim()) : null;
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return const PawsResult('I only open https links.', isError: true);
        final opener = _opener;
        if (opener == null) return const PawsResult("I can't open links here.", isError: true);
        return await opener.open(uri) ? PawsResult('Opening ${uri.host}.') : PawsResult("I couldn't open ${uri.host}.", isError: true);
      case 'mochi':
        final minutes = arguments['minutes'];
        final outcome = trick(arguments['action'] is String ? arguments['action'] as String : '', minutes is num ? minutes.round() : null);
        return PawsResult(outcome.text, isError: !outcome.ok);
      default:
        return const PawsResult('Unknown tool.', isError: true);
    }
  }

  /// One of Mochi's tricks, for the brain's `mochi` tool.
  AskOutcome trick(String action, int? minutes) {
    switch (action) {
      case 'explore':
        return explore?.call() ?? const AskOutcome("That trick isn't on Windows yet.", ok: false);
      case 'come_home':
        return comeHome?.call() ?? const AskOutcome("That trick isn't on Windows yet.", ok: false);
      case 'pet':
        return _interact('pet');
      case 'play':
        return _interact('play');
      case 'treat':
        return _interact('treat');
      default:
        final run = tricks[action];
        return run == null ? const AskOutcome("I don't know that trick.", ok: false) : run(minutes);
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

  Future<AskOutcome> _askClaude(
    String text, {
    required bool spoken,
    required AskExchange exchange,
    String? commandId,
    AskTarget? target,
  }) async {
    final brain = this.brain;
    if (brain != null) {
      _cue(PetCue.working);
      _brainExchange = exchange;
      BrainAnswer? answer;
      try {
        answer = await brain.ask(text, spoken: spoken, commandId: commandId, target: target);
      } finally {
        if (identical(_brainExchange, exchange)) _brainExchange = null;
      }
      if (answer != null) return AskOutcome(answer.text, ok: answer.ok);
    }
    // A message for one session can't go through the one-off path, which has no way to send it.
    if (target != null) return const AskOutcome("I couldn't start my helper Claude, so I didn't send it.", ok: false);
    return _askOnce(text, spoken: spoken);
  }

  /// v1: a one-off `claude -p` that can only search the web.
  Future<AskOutcome> _askOnce(String text, {required bool spoken}) async {
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
