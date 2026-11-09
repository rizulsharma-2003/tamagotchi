// Fakes for Ask Mochi's brain: the claude process, the clock (timers fired by hand) and the loopback connection.

import 'dart:async';
import 'dart:convert';

import 'package:mochi_desktop/src/core/ask_brain.dart';
import 'package:mochi_desktop/src/core/brain_session.dart';
import 'package:mochi_desktop/src/core/paws_server.dart';
import 'package:mochi_desktop/src/core/session_store.dart';

/// A `claude -p` that isn't one: what it is sent is recorded, what it prints is up to the test.
class FakeBrainProcess implements BrainProcess {
  final StreamController<String> _out = StreamController<String>();
  final StreamController<String> _err = StreamController<String>();
  final Completer<int> _exit = Completer<int>();
  final List<String> written = [];
  bool stopped = false;
  bool killed = false;

  @override
  Stream<String> get output => _out.stream;

  @override
  Stream<String> get errors => _err.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool write(String text) {
    if (stopped || _exit.isCompleted) return false;
    written.add(text);
    return true;
  }

  @override
  void stop() {
    stopped = true;
    if (!_exit.isCompleted) _exit.complete(0);
  }

  @override
  void kill() {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-1);
  }

  /// One line of the brain's output.
  void print(Map<String, Object?> event) => _out.add('${jsonEncode(event)}\n');

  void printRaw(String text) => _out.add(text);

  void printError(String text) => _err.add(text);

  /// It ends by itself.
  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  /// The user messages it was sent, as text.
  List<String> get requests => [for (final line in written) ((jsonDecode(line) as Map)['message'] as Map)['content'] as String];

  static Map<String, Object?> init({bool connected = true}) => {
    'type': 'system',
    'subtype': 'init',
    'model': 'claude-haiku',
    'mcp_servers': [
      {'name': 'mochi', 'status': connected ? 'connected' : 'failed'},
    ],
  };

  static Map<String, Object?> toolUse(String id, String name, Map<String, Object?> input) => {
    'type': 'assistant',
    'message': {
      'content': [
        {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
      ],
    },
  };

  static Map<String, Object?> toolResult(String id, String text, {bool error = false}) => {
    'type': 'user',
    'message': {
      'content': [
        {'type': 'tool_result', 'tool_use_id': id, 'is_error': error, 'content': text},
      ],
    },
  };

  static Map<String, Object?> result(String text, {bool error = false}) => {
    'type': 'result',
    'subtype': error ? 'error' : 'success',
    'is_error': error,
    'result': text,
  };
}

/// Timers that only fire when the test says so.
class ManualClock {
  final List<({Duration after, void Function() action, _ManualTimer timer})> _timers = [];
  DateTime now = DateTime(2026, 11, 9, 10, 0);

  Timer schedule(Duration after, void Function() action) {
    final timer = _ManualTimer();
    _timers.add((after: after, action: action, timer: timer));
    return timer;
  }

  /// Timers still waiting, by their delay.
  List<Duration> get pending => [
    for (final timer in _timers)
      if (timer.timer.isActive) timer.after,
  ];

  /// Fires the oldest waiting timer with this delay.
  void fire(Duration after) {
    for (final timer in _timers) {
      if (timer.timer.isActive && timer.after == after) {
        timer.timer.cancel();
        timer.action();
        return;
      }
    }
    throw StateError('no waiting timer for $after (waiting: $pending)');
  }
}

class _ManualTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// One connection, held by the test: bytes the relay would send go in, what the app answers comes out.
class FakeChannel implements PawsChannel {
  final StreamController<List<int>> _in = StreamController<List<int>>();
  final List<String> answers = [];
  bool closed = false;

  @override
  Stream<List<int>> get input => _in.stream;

  @override
  bool write(List<int> data) {
    if (closed) return false;
    answers.add(utf8.decode(data));
    return true;
  }

  @override
  void close() {
    closed = true;
  }

  void send(String line) => _in.add(utf8.encode('$line\n'));

  void sendBytes(List<int> bytes) => _in.add(bytes);

  /// The answers, decoded.
  List<Map<String, Object?>> get replies => [for (final answer in answers) jsonDecode(answer) as Map<String, Object?>];
}

/// An [AskBrain] with everything faked but the paws server's logic.
class BrainRig {
  BrainRig({bool setup = true, bool messaging = true, this.spawnFails = false, String? workingDirectory}) {
    sessions = SessionStore(clock: () => clock.now);
    brain = AskBrain(
      sessions: sessions,
      setup: () => setup
          ? BrainSetup(
              executable: r'C:\Users\Jane\.local\bin\claude.exe',
              helper: r'C:\Mochi\bin\mochi_hook.exe',
              environment: const {'PATH': 'x'},
              workingDirectory: workingDirectory ?? 'unused',
            )
          : null,
      model: () => 'haiku',
      petName: () => 'Mochi',
      context: () => 'Time Mon 10:00. Mochi sees no Claude sessions right now.',
      tools: (name, arguments) async => PawsResult('ran $name'),
      messagingAllowed: () => messaging,
      spawn: (launch, environment) async {
        launches.add(launch);
        environments.add(environment);
        if (spawnFails) throw StateError('no claude');
        final process = FakeBrainProcess();
        processes.add(process);
        return process;
      },
      schedule: clock.schedule,
      clock: () => clock.now,
      log: logs.add,
    );
    brain.announce = announced.add;
    brain.phones = phones;
  }

  final ManualClock clock = ManualClock();
  late final SessionStore sessions;
  late final AskBrain brain;
  final bool spawnFails;
  final List<BrainLaunch> launches = [];
  final List<Map<String, String>> environments = [];
  final List<FakeBrainProcess> processes = [];
  final List<String> logs = [];
  final List<String> announced = [];
  final FakePhones phones = FakePhones();

  FakeBrainProcess get process => processes.last;

  /// Runs [action] and lets the event loop turn.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The token the helper session was given (read from its MCP configuration, as the relay would).
  String get token => _env['MOCHI_PAWS_TOKEN']!;

  int get port => int.parse(_env['MOCHI_PAWS_PORT']!);

  Map<String, String> get _env {
    final config = jsonDecode(launches.last.mcpConfig) as Map;
    final server = (config['mcpServers'] as Map)['mochi'] as Map;
    return {for (final entry in (server['env'] as Map).entries) entry.key as String: entry.value as String};
  }

  /// Starts a request and lets the brain come up: [answer] is its eventual result.
  Future<Future<BrainAnswer?>> ask(String text, {String? commandId, AskTarget? target}) async {
    final answer = brain.ask(text, commandId: commandId, target: target);
    await settle();
    return answer;
  }

  /// A connection the relay would make, already past the token.
  FakeChannel connect({String? withToken}) {
    final channel = FakeChannel();
    brain.server.accept(channel);
    channel.send(jsonEncode({'auth': withToken ?? token}));
    return channel;
  }

  /// The brain calls `approve` for a SendMessage and the card goes up; returns the connection waiting for the verdict.
  Future<FakeChannel> askToSend({String to = 'web-ab [123456]', String message = 'Please run the tests.', String toolUse = 't1'}) async {
    process.print(FakeBrainProcess.toolUse(toolUse, 'SendMessage', {'to': to, 'message': message}));
    await settle();
    final channel = connect();
    channel.send(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'tools/call',
        'params': {
          'name': 'approve',
          'arguments': {
            'tool_name': 'SendMessage',
            'tool_use_id': toolUse,
            'input': {'to': to, 'message': message},
          },
        },
      }),
    );
    await settle();
    return channel;
  }

  /// The permission prompt tool's answer on [channel] (the JSON the brain reads).
  Map<String, Object?> verdict(FakeChannel channel) {
    final reply = channel.replies.last;
    final text = (((reply['result'] as Map)['content'] as List).single as Map)['text'] as String;
    return jsonDecode(text) as Map<String, Object?>;
  }
}

/// Whether the permission prompt tool's connection ended without ever being told "allow" (the answer was deny, or the
/// connection was closed first, which Claude Code also takes as no).
bool neverAllowed(FakeChannel channel) => !channel.answers.any((answer) => answer.contains(r'\"behavior\":\"allow\"'));

class FakePhones implements PhoneApprovals {
  final List<({String id, String commandId, String target, String? project, String message})> mirrored = [];
  int cleared = 0;

  @override
  void mirror({required String id, required String commandId, required String target, String? project, required String message}) {
    mirrored.add((id: id, commandId: commandId, target: target, project: project, message: message));
  }

  @override
  void clear() => cleared++;
}
