// The app's end of Mochi's tools ("paws", Swift `PawsServer`): Mochi's helper Claude session reaches it through
// `mochi_hook paws`, which relays MCP over stdio to this loopback socket.
//
// - It listens on 127.0.0.1 only, and only while a helper session is running (nothing listens while Mochi is idle).
// - A connection must open with the one-time token of the helper session the app started, as `{"auth":"<token>"}`; any
//   other first line, a late one (5 seconds) or an oversized one closes the connection without an answer. The token
//   changes with every helper session and is never printed or logged.
// - Lines are capped; a tool call runs on the app's own isolate, and the replies go back in the order the requests came.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'mcp_core.dart';

/// A tool's answer.
class PawsResult {
  const PawsResult(this.text, {this.isError = false});

  final String text;
  final bool isError;
}

/// Runs one tool call (on the app's isolate).
typedef PawsPerform = Future<PawsResult> Function(String name, Map<String, Object?> arguments);

/// Starts a one-shot timer (tests pass their own clock).
typedef PawsSchedule = Timer Function(Duration after, void Function() action);

/// One connection's bytes in and lines out; the real one wraps a loopback [Socket], tests pass a fake.
abstract interface class PawsChannel {
  Stream<List<int>> get input;

  /// Writes [data]; false when the connection is gone.
  bool write(List<int> data);

  /// Closes the connection now.
  void close();
}

class SocketPawsChannel implements PawsChannel {
  SocketPawsChannel(this._socket);

  final Socket _socket;

  @override
  Stream<List<int>> get input => _socket;

  @override
  bool write(List<int> data) {
    try {
      _socket.add(data);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  void close() => _socket.destroy();
}

/// What one connection does: authenticate, then speak MCP, one request at a time.
class PawsConnection {
  PawsConnection({
    required this.channel,
    required this.core,
    required this.perform,
    required this.token,
    this.maxLineBytes = PawsServer.defaultMaxLineBytes,
    this.authDeadline = const Duration(seconds: 5),
    PawsSchedule? schedule,
    this.onClosed,
  }) : _schedule = schedule ?? Timer.new;

  final PawsChannel channel;
  final McpServerCore core;
  final PawsPerform perform;

  /// The token the first line has to carry (null: nobody is let in).
  final String? Function() token;
  final int maxLineBytes;
  final Duration authDeadline;
  final PawsSchedule _schedule;
  final void Function(PawsConnection connection)? onClosed;

  final BytesBuilder _buffer = BytesBuilder();
  StreamSubscription<List<int>>? _subscription;
  Timer? _deadline;
  bool _authenticated = false;
  bool _closed = false;

  /// Requests are answered one after the other, in the order they arrived.
  Future<void> _turn = Future<void>.value();

  bool get authenticated => _authenticated;
  bool get closed => _closed;

  void start() {
    _deadline = _schedule(authDeadline, () {
      if (!_authenticated) close();
    });
    _subscription = channel.input.listen(_data, onDone: close, onError: (Object _) => close(), cancelOnError: true);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _deadline?.cancel();
    unawaited(_subscription?.cancel());
    channel.close();
    onClosed?.call(this);
  }

  void _data(List<int> data) {
    if (_closed) return;
    _buffer.add(data);
    // Complete lines, oldest first; whatever is left over is one unfinished line.
    var bytes = _buffer.takeBytes();
    while (!_closed) {
      final newline = bytes.indexOf(0x0A);
      if (newline < 0) break;
      if (newline > maxLineBytes) {
        close();
        return;
      }
      final line = Uint8List.sublistView(bytes, 0, newline);
      bytes = Uint8List.sublistView(bytes, newline + 1);
      _line(utf8.decode(line, allowMalformed: true));
    }
    if (_closed) return;
    if (bytes.length > maxLineBytes) {
      close();
      return;
    }
    if (bytes.isNotEmpty) _buffer.add(bytes);
  }

  void _line(String line) {
    if (!_authenticated) {
      final expected = token();
      Object? auth;
      try {
        final decoded = jsonDecode(line);
        auth = decoded is Map ? decoded['auth'] : null;
      } on FormatException {
        auth = null;
      }
      if (expected == null || auth is! String || !PawsServer.sameToken(auth, expected)) {
        close();
        return;
      }
      _authenticated = true;
      _deadline?.cancel();
      return;
    }
    if (line.trim().isEmpty) return;
    _turn = _turn.then((_) => _answer(line));
  }

  Future<void> _answer(String line) async {
    if (_closed) return;
    final McpOutcome outcome;
    try {
      outcome = core.handle(line);
    } on Object {
      return;
    }
    switch (outcome) {
      case McpIgnore():
        return;
      case McpReply(line: final reply):
        _write(reply);
      case McpCall(:final id, :final name, :final arguments):
        PawsResult result;
        try {
          result = await perform(name, arguments);
        } on Object {
          // Nothing about the call is repeated in the answer.
          result = const PawsResult('That tool stopped unexpectedly.', isError: true);
        }
        if (!_closed) _write(McpServerCore.toolResult(id, result.text, isError: result.isError));
    }
  }

  void _write(String line) {
    if (!channel.write(utf8.encode(line))) close();
  }
}

/// Where the helper session's relay connects and what it has to show.
class PawsEndpoint {
  const PawsEndpoint({required this.port, required this.token});

  final int port;

  /// The one-time token (hex). Never printed or logged.
  final String token;

  @override
  String toString() => 'PawsEndpoint(port: $port)';
}

class PawsServer {
  PawsServer({
    required this.core,
    required this.perform,
    this.maxLineBytes = defaultMaxLineBytes,
    this.maxConnections = 4,
    this.authDeadline = const Duration(seconds: 5),
    PawsSchedule? schedule,
    Random? random,
  }) : _schedule = schedule,
       _random = random ?? Random.secure();

  static const int defaultMaxLineBytes = 1 << 20;

  final McpServerCore core;
  final PawsPerform perform;
  final int maxLineBytes;
  final int maxConnections;
  final Duration authDeadline;
  final PawsSchedule? _schedule;
  final Random _random;

  ServerSocket? _server;
  String? _token;
  final List<PawsConnection> _connections = [];

  bool get isListening => _server != null;

  /// How many connections are open (authenticated or still waiting to be).
  int get connections => _connections.length;

  /// Starts listening on a free loopback port with a fresh token. Throws [SocketException] when it can't.
  Future<PawsEndpoint> start() async {
    await stop();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final token = newToken(_random);
    _server = server;
    _token = token;
    server.listen(_accept, onError: (Object _) {});
    return PawsEndpoint(port: server.port, token: token);
  }

  /// Stops listening and closes every connection; the token is void from now on.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    for (final connection in List.of(_connections)) {
      connection.close();
    }
    _connections.clear();
    await server?.close();
  }

  void _accept(Socket socket) {
    if (_token == null || !socket.remoteAddress.isLoopback || _connections.length >= maxConnections) {
      socket.destroy();
      return;
    }
    accept(SocketPawsChannel(socket));
  }

  /// Serves one connection (also how tests give it a fake channel).
  PawsConnection accept(PawsChannel channel) {
    final connection = PawsConnection(
      channel: channel,
      core: core,
      perform: perform,
      token: () => _token,
      maxLineBytes: maxLineBytes,
      authDeadline: authDeadline,
      schedule: _schedule,
      onClosed: _connections.remove,
    );
    _connections.add(connection);
    connection.start();
    return connection;
  }

  /// 24 random bytes in hex.
  static String newToken(Random random) => List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  /// Compares in constant time, so the token can't be guessed a character at a time.
  static bool sameToken(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}
