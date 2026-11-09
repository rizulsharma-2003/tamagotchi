// Ask Mochi's brain on Windows (the Mac's AssistantController, brain half): a long-lived helper Claude session that acts
// through a fixed set of tools ("paws") and can message the user's other Claude sessions, each message only after the
// user approves it on an approval card. Nothing is written to disk: the conversation lives in memory until the brain
// is shut down.
//
// - Nothing runs until the first request that needs it: no process, no listening socket, no timer, no stream.
// - The brain stops after [idle] quiet minutes; with it go the paws socket and every timer.
// - Anything the approval card didn't allow is a denial: Don't send, the time running out, a newer request, the helper
//   stopping, the app quitting.
// - Never logged or printed: tokens, message bodies, requests. The log says "brain: started / idle stop / approval shown
//   / sent / denied".

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ask_attach.dart' show HandOverPaths;
import 'brain_session.dart';
import 'mcp_core.dart';
import 'paws_server.dart';
import 'session_store.dart';
import 'sessions.dart';

/// A message the brain wants to send to another Claude session, waiting for Send or Don't send.
class AskApproval {
  const AskApproval({required this.id, required this.target, this.project, required this.message});

  final String id;

  /// The session's name as Claude Code knows it ("mac-tamagotchi-bb").
  final String target;

  /// The project Mochi matched it to (null: Mochi doesn't know it).
  final String? project;

  /// The full text. Never shortened on the card.
  final String message;

  /// "mac-Tamagotchi · mac-tamagotchi-bb".
  String get title => project == null ? target : '$project · $target';
}

enum AskStepState { running, done, failed }

/// One line of progress while the brain works.
class AskStep {
  AskStep({required this.id, required this.text, this.state = AskStepState.running});

  final String id;
  String text;
  AskStepState state;
}

/// A reply for one Claude session, written on a phone's session card.
class AskTarget {
  const AskTarget({required this.project, this.sessionId});

  final String project;
  final String? sessionId;
}

/// How a brain request ended.
class BrainAnswer {
  const BrainAnswer(this.text, {this.ok = true});

  final String text;
  final bool ok;
}

/// Shows an approval card on the phones too (the first answer, here or there, wins).
abstract interface class PhoneApprovals {
  void mirror({required String id, required String commandId, required String target, String? project, required String message});

  void clear();
}

/// What it takes to start the brain: where `claude` and the helper are, and the environment to run in.
class BrainSetup {
  const BrainSetup({required this.executable, required this.helper, required this.environment, required this.workingDirectory});

  final String executable;
  final String helper;
  final Map<String, String> environment;
  final String workingDirectory;
}

class _Request {
  _Request(this.text, {this.commandId, Iterable<String> handOver = const []}) {
    for (final path in handOver) {
      final normal = HandOverPaths.normalise(path);
      if (normal != null) this.handOver.add(normal);
    }
  }

  final String text;
  final String? commandId;
  final Completer<BrainAnswer?> done = Completer();

  /// The files handed over for this request (X13, X17), in [HandOverPaths.normalise]'s form: the only paths the brain's
  /// `Read` may open while this request runs. It belongs to the request: [AskBrain._complete] empties it on every ending
  /// (answer, failure, cancel, time out, a newer request, the app quitting), and `_current` is no longer this request then.
  final Set<String> handOver = {};

  /// The PC actions done for this request so far (AskBrain.maxPcActions at most).
  int pcActions = 0;
}

class _Delegation {
  _Delegation(this.projectKey, this.name, this.sentAt);

  final String? projectKey;
  final String? name;
  final DateTime sentAt;
}

class AskBrain extends ChangeNotifier {
  AskBrain({
    required this.sessions,
    required this.setup,
    required this.model,
    required this.petName,
    required this.context,
    required this.tools,
    required this.messagingAllowed,
    BrainSpawner? spawn,
    PawsServer? server,
    PawsSchedule? schedule,
    DateTime Function()? clock,
    Random? random,
    this.idle = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 120),
    this.approvalTimeout = const Duration(seconds: 120),
    this.log,
  }) : _spawn = spawn ?? ProcessBrain.start,
       _schedule = schedule ?? Timer.new,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure() {
    this.server =
        server ??
        PawsServer(
          core: McpServerCore(
            name: BrainLaunch.serverName,
            version: 'desktop',
            instructions: "Mochi's hands on this PC.",
            tools: AskBrain.toolSpecs,
          ),
          perform: _perform,
          random: random,
        );
  }

  /// Exactly these, and no others: the brain's own (approve, mochi, claude_sessions), links, and the Mac's PC actions as
  /// they are on Windows (W9; `run_task` and `list_tasks` stand in for the Mac's Shortcuts). Nothing types, clicks or closes.
  static const List<McpTool> toolSpecs = [
    McpTool(
      name: BrainLaunch.approvalTool,
      description: "Internal: Mochi's approval card for messages to Claude sessions. Never call this yourself.",
      properties: {'tool_name': ('string', 'Tool waiting for approval'), 'input': ('object', 'Its input')},
      required: ['tool_name', 'input'],
    ),
    McpTool(
      name: 'mochi',
      description: "Mochi's own tricks.",
      properties: {'action': ('string', 'What Mochi should do'), 'minutes': ('number', 'Focus length (focus_start only)')},
      required: ['action'],
      enumValues: {
        'action': ['explore', 'come_home', 'pet', 'play', 'treat', 'games', 'recap', 'decorate', 'focus_start', 'focus_stop'],
      },
    ),
    McpTool(name: 'claude_sessions', description: 'The user\'s Claude sessions Mochi knows about and what each is doing.'),
    McpTool(
      name: 'open_url',
      description: "Open an https link in the user's default browser.",
      properties: {'url': ('string', 'The https URL')},
      required: ['url'],
    ),
    McpTool(
      name: 'open_app',
      description: 'Open an app by name, or switch to it if it is running.',
      properties: {'name': ('string', 'App name, e.g. Slack or Visual Studio Code')},
      required: ['name'],
    ),
    McpTool(name: 'list_apps', description: 'Names of the apps that are running now (the programs with taskbar windows).'),
    McpTool(
      name: 'focus_window',
      description:
          "Bring a window to the front. Give the app and/or words from the window's title; the title is matched on this PC and never shown to you.",
      properties: {'app': ('string', 'App name (optional)'), 'title': ('string', 'Words from the window title (optional)')},
    ),
    McpTool(
      name: 'show_project',
      description: 'Bring forward the window a Claude session works in (its editor or terminal), by project or session name.',
      properties: {'project': ('string', 'Project folder or session name, e.g. mac-Tamagotchi')},
      required: ['project'],
    ),
    McpTool(
      name: 'media',
      description: 'Press a music key: play/pause, next or previous (whatever is playing).',
      properties: {'action': ('string', 'play_pause, next or previous')},
      required: ['action'],
      enumValues: {
        'action': ['play_pause', 'next', 'previous'],
      },
    ),
    McpTool(
      name: 'set_volume',
      description: "Change this PC's volume: a level 0–100, or up/down/mute/unmute.",
      properties: {'level': ('number', '0–100 (optional)'), 'change': ('string', 'up, down, mute or unmute (optional)')},
      enumValues: {
        'change': ['up', 'down', 'mute', 'unmute'],
      },
    ),
    McpTool(
      name: 'run_task',
      description: "Run one of the user's own Task Scheduler tasks from their Mochi folder, by its exact name.",
      properties: {'name': ('string', 'Task name')},
      required: ['name'],
    ),
    McpTool(name: 'list_tasks', description: "Names of the tasks in the user's Mochi folder in Task Scheduler."),
  ];

  /// The tools that do something on the PC, at most [maxPcActions] of them for one request. The lists, `mochi` and
  /// `claude_sessions` don't count.
  static const Set<String> pcActionTools = {'open_app', 'open_url', 'focus_window', 'show_project', 'media', 'set_volume', 'run_task'};

  /// The most PC actions one request may do (W9): a sixth is refused, so a brain that loops or is led astray stops.
  static const int maxPcActions = 5;

  final SessionStore sessions;

  /// Where `claude` and the helper are (null: the brain can't start, and the one-off path answers instead).
  final BrainSetup? Function() setup;
  final String Function() model;
  final String Function() petName;

  /// The `[Context]` line for a request.
  final String Function() context;

  /// The tools other than `approve`.
  final PawsPerform tools;

  /// Settings: Mochi may ask to message the user's Claude sessions at all.
  final bool Function() messagingAllowed;
  final Duration idle;
  final Duration requestTimeout;
  final Duration approvalTimeout;
  final void Function(String line)? log;

  late final PawsServer server;
  final BrainSpawner _spawn;
  final PawsSchedule _schedule;
  final DateTime Function() _clock;
  final Random _random;

  /// The phones' approval mirror (null: no phones).
  PhoneApprovals? phones;

  /// Mochi says a line (a session Mochi sent a prompt to finished).
  void Function(String line)? announce;

  /// An approval card was put up: the window shows it.
  void Function(AskApproval approval)? onApproval;

  AskApproval? _approval;
  Completer<bool>? _verdict;
  Timer? _approvalTimer;
  List<AskStep> _steps = [];
  _Request? _current;
  BrainSession? _session;
  Timer? _requestTimer;
  Timer? _idleTimer;
  StreamSubscription<SessionTransition>? _watching;
  final List<_Delegation> _delegations = [];

  /// Messages the user approved, by tool call, until Claude Code confirms delivery.
  final Map<String, ({String? projectKey, String? name, DateTime at})> _approved = {};
  bool _disposed = false;

  AskApproval? get approval => _approval;
  List<AskStep> get steps => List.unmodifiable(_steps);

  /// A request is being worked on.
  bool get working => _current != null;
  bool get running => _session?.isRunning ?? false;

  /// How many sent prompts Mochi is waiting to hear back about.
  int get delegations => _delegations.length;

  /// Answers [request]. Null when the brain can't start (the one-off path answers instead); never throws.
  ///
  /// [handOver]: the absolute paths of the files the user handed over with this request (dropped files, the screenshot they
  /// approved). Claude Code may `Read` exactly these while this request runs, and nothing else.
  Future<BrainAnswer?> ask(
    String request, {
    bool spoken = false,
    String? commandId,
    AskTarget? target,
    List<String> handOver = const [],
  }) async {
    if (_disposed) return null;
    final previous = _current;
    if (previous != null) {
      _stopCurrent();
      _complete(previous, const BrainAnswer('I switched to your newer request.', ok: false));
    }
    final ready = setup();
    if (ready == null || ready.executable.isEmpty) return null;
    final current = _current = _Request(request, commandId: commandId, handOver: handOver);
    _steps = [];
    _idleTimer?.cancel();
    final message = target != null
        ? BrainLaunch.directRequest(request, project: target.project)
        : BrainLaunch.message(request: request, context: context(), spoken: spoken);
    notifyListeners();
    final session = _session;
    if (session != null && session.isRunning) {
      session.send(message);
      _armTimeout();
    } else {
      unawaited(_launch(ready, message, current));
    }
    return current.done.future;
  }

  Future<void> _launch(BrainSetup ready, String message, _Request request) async {
    try {
      final endpoint = await server.start();
      if (_current != request) {
        await server.stop();
        return;
      }
      final launch = BrainLaunch(
        executable: ready.executable,
        model: model(),
        mcpConfig: BrainLaunch.mcpConfigJson(helper: ready.helper, port: endpoint.port, token: endpoint.token),
        workingDirectory: ready.workingDirectory,
        petName: petName(),
      );
      final session = BrainSession(launch: launch, spawn: _spawn, environment: ready.environment);
      session.onEvent = (event) => _event(session, event);
      session.onExit = (status, tail) => _exited(session, status, tail);
      await session.start();
      if (_current != request) {
        session.terminate();
        await server.stop();
        return;
      }
      _session = session;
      log?.call('brain: started');
      session.send(message);
      _armTimeout();
    } on Object {
      // The brain can't start: the one-off path answers this request.
      await server.stop();
      if (_current == request) {
        _current = null;
        _complete(request, null);
      }
    }
  }

  void _complete(_Request request, BrainAnswer? answer) {
    // Every ending comes through here: the files handed over for this request can't be read after it.
    request.handOver.clear();
    if (!request.done.isCompleted) request.done.complete(answer);
  }

  // MARK: Events

  void _event(BrainSession session, BrainEvent event) {
    final request = _current;
    if (session != _session || request == null) return;
    switch (event) {
      case BrainStarted(:final toolsConnected):
        if (!toolsConnected) {
          // The helper never reached Mochi's tools (an older helper without `paws`): not a brain worth keeping.
          _stopCurrent();
          _current = null;
          _complete(request, null);
          notifyListeners();
        }
      case BrainText():
        break;
      case BrainToolUse(:final id, :final name, :final input):
        final text = BrainStep.describe(name, input);
        if (text == null) return;
        _steps.add(AskStep(id: id, text: text));
        notifyListeners();
      case BrainToolResult(:final id, :final isError, :final text):
        final step = _steps.where((step) => step.id == id).firstOrNull;
        if (step == null) return;
        step.state = isError ? AskStepState.failed : AskStepState.done;
        const asking = 'Asking to send to ';
        if (step.text.startsWith(asking)) {
          final target = step.text.substring(asking.length);
          final approved = _approved.remove(id);
          // Delivered only when Claude Code says so.
          if (!isError && approved != null && delivered(text)) {
            step.text = 'Sent to $target';
            log?.call('brain: sent');
            _delivered(approved.projectKey, approved.name, approved.at);
          } else {
            step.text = 'Not sent to $target';
            step.state = AskStepState.failed;
          }
        }
        notifyListeners();
      case BrainFinished(:final result, :final isError):
        _finish(request, BrainAnswer(cleanReply(result) ?? (isError ? 'Something went wrong.' : 'Done!'), ok: !isError));
    }
  }

  void _exited(BrainSession session, int status, String tail) {
    if (session != _session) return;
    _session = null;
    unawaited(server.stop());
    final request = _current;
    if (request == null) return;
    _resolveApproval(false);
    _requestTimer?.cancel();
    _current = null;
    final lowered = tail.toLowerCase();
    final answer = lowered.contains('login') || lowered.contains('log in') || lowered.contains('authenticat')
        ? const BrainAnswer('Claude Code needs you to sign in: run `claude` once in a terminal, then ask again.', ok: false)
        : BrainAnswer('My helper Claude stopped unexpectedly (code $status).', ok: false);
    _complete(request, answer);
    notifyListeners();
  }

  void _finish(_Request request, BrainAnswer answer) {
    _requestTimer?.cancel();
    for (final step in _steps) {
      if (step.state == AskStepState.running) step.state = answer.ok ? AskStepState.done : AskStepState.failed;
    }
    _current = null;
    _complete(request, answer);
    _scheduleIdle();
    notifyListeners();
  }

  /// Whether Claude Code reported a SendMessage as delivered (`{"success":true,...}`).
  static bool delivered(String result) {
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map && decoded['success'] is bool) return decoded['success'] as bool;
    } on FormatException {
      // Not JSON: look for the words.
    }
    return result.contains('"success":true');
  }

  /// The brain's last sentence, without markdown, at most 400 characters.
  static String? cleanReply(String? text) {
    var reply = text?.trim();
    if (reply == null || reply.isEmpty) return null;
    reply = reply.replaceAll('**', '').replaceAll('`', '');
    return reply.length > 400 ? '${reply.substring(0, 399)}…' : reply;
  }

  // MARK: Stopping

  /// Stops what is running: declines a pending approval and stops the brain.
  void cancel() {
    final request = _current;
    if (request == null) return;
    _stopCurrent();
    _current = null;
    _complete(request, const BrainAnswer('Okay, I stopped.', ok: false));
    notifyListeners();
  }

  void _stopCurrent() {
    _resolveApproval(false);
    _requestTimer?.cancel();
    _stopBrain();
  }

  void _stopBrain() {
    _session?.terminate();
    _session = null;
    unawaited(server.stop());
  }

  void _armTimeout() {
    _requestTimer?.cancel();
    _requestTimer = _schedule(requestTimeout, () {
      final request = _current;
      if (request == null || _approval != null) return;
      _stopCurrent();
      _current = null;
      _complete(request, const BrainAnswer('That took too long, so I stopped.', ok: false));
      notifyListeners();
    });
  }

  void _scheduleIdle() {
    _idleTimer?.cancel();
    if (_session == null) return;
    _idleTimer = _schedule(idle, () {
      if (_current != null || _approval != null) return;
      _stopBrain();
      log?.call('brain: idle stop');
    });
  }

  /// The app is quitting (or Windows ends the session): a pending card is a denial, and the brain goes.
  void shutdown() {
    _resolveApproval(false);
    _requestTimer?.cancel();
    _idleTimer?.cancel();
    final request = _current;
    _current = null;
    if (request != null) _complete(request, const BrainAnswer('Okay, I stopped.', ok: false));
    _stopBrain();
    unawaited(_watching?.cancel());
    _watching = null;
    _delegations.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    shutdown();
    super.dispose();
  }

  // MARK: Tools

  Future<PawsResult> _perform(String name, Map<String, Object?> arguments) async {
    if (name == BrainLaunch.approvalTool) return PawsResult(await _approvalVerdict(arguments));
    if (!pcActionTools.contains(name)) return tools(name, arguments);
    // A PC action is only ever for a request the user is waiting on, and at most five per request.
    final request = _current;
    if (request == null) return const PawsResult('Nothing is being asked right now.', isError: true);
    if (request.pcActions >= maxPcActions) {
      log?.call('brain: action limit reached');
      return const PawsResult("That's a lot at once, so I stopped. Ask me again.", isError: true);
    }
    request.pcActions++;
    PawsResult result;
    try {
      result = await tools(name, arguments);
    } on Object {
      result = const PawsResult("That didn't work.", isError: true);
    }
    // The tool's name and whether it worked, never what it was asked or what it found.
    log?.call('brain: action $name ${result.isError ? 'failed' : 'ok'}');
    return result;
  }

  static String _deny(String message) => jsonEncode({'behavior': 'deny', 'message': message});

  /// Both names of one SendMessage field, with different values.
  static const Object _ambiguous = Object();

  /// [preview] is [full] cut short: its start, maybe ending in a full stop or an ellipsis where it was cut.
  static bool _previewOf(String preview, String full) {
    var start = preview;
    for (final end in const ['…', '...', '.']) {
      if (start.endsWith(end)) {
        start = start.substring(0, start.length - end.length);
        break;
      }
    }
    return start.isNotEmpty && full.startsWith(start);
  }

  /// The answer Claude Code's permission prompt tool expects: only `SendMessage`, only after the card says Send.
  Future<String> _approvalVerdict(Map<String, Object?> arguments) async {
    if (arguments['tool_name'] == 'Read') return _readVerdict(arguments);
    if (arguments['tool_name'] != 'SendMessage') return _deny("Mochi only approves messages to the user's Claude sessions.");
    if (!messagingAllowed()) return _deny('The user turned off messages to their Claude sessions.');
    final input = arguments['input'] is Map ? Map<String, Object?>.from(arguments['input'] as Map) : <String, Object?>{};
    // The card shows exactly what SendMessage sends. Claude Code names the fields `to` and `message` (some versions
    // `recipient` and `content`, as the Mac reads them); both names of one field with different values would leave the
    // card unsure what goes: denied.
    // A session may be named two ways for the same one ("bin-42" and "bin-42 [eb4027]"): compared as shown.
    Object? one(String a, String b, {String Function(String)? same}) {
      final first = input[a], second = input[b];
      if (first == null || second == null) return first ?? second;
      if (first is String && second is String && (first == second || (same != null && same(first) == same(second)))) return first;
      return _ambiguous;
    }

    final to = one('to', 'recipient', same: AgentNames.display);
    // Claude Code adds `content`, a short preview of `message` (its first 49 characters and a full stop); the message is
    // what goes, and the card shows it whole. A `content` that isn't such a preview leaves the card unsure: denied.
    final m = input['message'], c = input['content'];
    final body = m is String && c is String && m != c && !_previewOf(c, m) ? _ambiguous : (m ?? c);
    if (identical(to, _ambiguous)) return _deny('Nothing to send (the message was unclear: to/recipient differ).');
    if (identical(body, _ambiguous)) return _deny('Nothing to send (the message was unclear: message/content differ).');
    final target = to is String ? AgentNames.display(to) : '';
    final message = body is String ? body : '';
    // The field names (never their values) say what didn't fit, should Claude Code's tool change again.
    if (target.isEmpty || message.isEmpty || _current == null) return _deny('Nothing to send (fields: ${input.keys.join(', ')}).');
    final project = AgentNames.project(target, among: _knownProjects());
    final allowed = await _askApproval(AskApproval(id: _newId(), target: target, project: project?.name, message: message));
    if (!allowed) {
      log?.call('brain: denied');
      return _deny('The user chose not to send it.');
    }
    final toolUse = arguments['tool_use_id'];
    if (toolUse is String) _approved[toolUse] = (projectKey: project?.key, name: project?.name, at: _clock());
    return jsonEncode({'behavior': 'allow', 'updatedInput': input});
  }

  /// The only fields of a `Read` that are looked at (the rest only narrow what is read from the file).
  static const Set<String> _readFields = {'file_path', 'offset', 'limit', 'pages'};

  /// `Read`: allowed only for a file handed over with the request now running (X13, X17), and for nothing else: not another
  /// path, a directory, a pattern, another request's file, with no request running, or when nothing was handed over.
  /// Handing the file over was the consent (it was shown and attached before Send), so there is no card.
  String _readVerdict(Map<String, Object?> arguments) {
    final request = _current;
    if (request == null || request.handOver.isEmpty) return _deny('No file was handed over with this request.');
    final raw = arguments['input'];
    if (raw is! Map) return _deny('That file was not handed over.');
    final input = Map<String, Object?>.from(raw);
    if (!input.keys.every(_readFields.contains)) return _deny('That file was not handed over.');
    final path = input['file_path'];
    final offset = input['offset'], limit = input['limit'], pages = input['pages'];
    if (path is! String || (offset != null && offset is! num) || (limit != null && limit is! num) || (pages != null && pages is! String)) {
      return _deny('That file was not handed over.');
    }
    final normal = HandOverPaths.normalise(path);
    if (normal == null || !request.handOver.contains(normal)) return _deny('Only the files the user handed over can be read.');
    log?.call('brain: read a handed-over file');
    return jsonEncode({'behavior': 'allow', 'updatedInput': input});
  }

  List<({String key, String name})> _knownProjects() {
    final seen = <String>{};
    return [
      for (final session in sessions.all)
        if (session.projectKey != null && session.project != null && seen.add(session.projectKey!))
          (key: session.projectKey!, name: session.project!),
    ];
  }

  String _newId() => List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<bool> _askApproval(AskApproval request) async {
    _resolveApproval(false);
    final verdict = _verdict = Completer<bool>();
    _approval = request;
    _requestTimer?.cancel();
    log?.call('brain: approval shown');
    final commandId = _current?.commandId;
    if (commandId != null) {
      phones?.mirror(id: request.id, commandId: commandId, target: request.target, project: request.project, message: request.message);
    }
    _approvalTimer?.cancel();
    _approvalTimer = _schedule(approvalTimeout, () => _resolveApproval(false));
    notifyListeners();
    onApproval?.call(request);
    final allowed = await verdict.future;
    _approvalTimer?.cancel();
    if (identical(_approval, request)) _approval = null;
    phones?.clear();
    if (_current != null) _armTimeout();
    notifyListeners();
    return allowed;
  }

  /// Send.
  void approve() => _resolveApproval(true);

  /// Don't send.
  void decline() => _resolveApproval(false);

  /// The card's answer, given on a phone: only for the card that was mirrored there.
  bool answerFromPhone(String approvalId, {required bool allow}) {
    if (_approval?.id != approvalId || _current?.commandId == null) return false;
    _resolveApproval(allow);
    return true;
  }

  void _resolveApproval(bool allowed) {
    final verdict = _verdict;
    if (verdict == null) return;
    _verdict = null;
    if (!verdict.isCompleted) verdict.complete(allowed);
  }

  // MARK: "Claude finished in X"

  void _delivered(String? projectKey, String? name, DateTime sentAt) {
    final finishedAlready =
        projectKey != null &&
        sessions.all.any((session) => session.projectKey == projectKey && (session.lastTurnCompletedAt?.isBefore(sentAt) == false));
    if (finishedAlready) {
      _say('Claude finished in ${name ?? 'your project'}!');
      return;
    }
    _delegations.add(_Delegation(projectKey, name, sentAt));
    // Listening starts with the first delegation and ends with the last.
    _watching ??= sessions.transitions.listen(_transition);
  }

  void _transition(SessionTransition transition) {
    _delegations.removeWhere((delegation) => _clock().difference(delegation.sentAt) > const Duration(hours: 4));
    if (_delegations.isEmpty) {
      unawaited(_watching?.cancel());
      _watching = null;
      return;
    }
    final key = transition.session.projectKey;
    final event = transition.event;
    final when = event == null ? _clock() : DateTime.fromMicrosecondsSinceEpoch((event.ts * 1e6).round());
    final index = _delegations.indexWhere(
      (delegation) => delegation.projectKey != null && delegation.projectKey == key && !when.isBefore(delegation.sentAt),
    );
    if (index < 0) return;
    final name = _delegations[index].name ?? 'your project';
    final String line;
    switch (transition.kind) {
      case EventKind.turnCompleted:
        _delegations.removeAt(index);
        line = 'Claude finished in $name!';
      case EventKind.turnFailed:
        _delegations.removeAt(index);
        line = 'Claude hit a snag in $name.';
      case EventKind.permissionRequested || EventKind.attentionNeeded:
        line = 'Claude in $name needs you.';
      default:
        return;
    }
    _say(line);
    if (_delegations.isEmpty) {
      unawaited(_watching?.cancel());
      _watching = null;
    }
  }

  /// A follow-up in Mochi's bubble, after Mochi's own answer has had its moment.
  void _say(String line) {
    final wait = _current != null || _approval != null ? const Duration(seconds: 3) : Duration.zero;
    if (wait == Duration.zero) {
      announce?.call(line);
    } else {
      _schedule(wait, () => announce?.call(line));
    }
  }
}
