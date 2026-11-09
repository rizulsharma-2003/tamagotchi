import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// `mochi_hook paws` (Swift `mactamagotchi-hook paws`): started by Mochi itself, as the MCP server command of Mochi's
/// helper Claude session. It relays MCP over stdio to the app's tool server ("paws"), which listens on 127.0.0.1 only.
///
/// - The app hands it the port and a one-time token through the MCP configuration it passes to Claude Code on the
///   command line (the `env` of the server entry): nothing is written to a file.
/// - The first line it sends the app is `{"auth":"<token>"}`; the app closes any connection that doesn't open with the
///   token of the helper session it started.
/// - Then it copies stdin to the app and the app's answers to stdout, byte for byte, until either side closes. It
///   never prints or logs the token, the port's answers or anything a tool call carried.
class PawsRelay {
  PawsRelay({
    required this.environment,
    required this.input,
    required this.output,
    required this.err,
    Future<Socket> Function(int port)? connect,
    this.connectTimeout = const Duration(seconds: 3),
  }) : _connect = connect ?? ((port) => Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 3)));

  /// Where the app listens (decimal port).
  static const String portKey = 'MOCHI_PAWS_PORT';

  /// The helper session's one-time token (hex, 16 to 128 characters).
  static const String tokenKey = 'MOCHI_PAWS_TOKEN';

  final Map<String, String> environment;

  /// What Claude Code writes (MCP requests, one JSON-RPC message per line).
  final Stream<List<int>> input;

  /// What Claude Code reads.
  final IOSink output;
  final StringSink err;
  final Duration connectTimeout;
  final Future<Socket> Function(int port) _connect;

  static bool validToken(String? token) =>
      token != null && token.length >= 16 && token.length <= 128 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(token);

  static bool validPort(int? port) => port != null && port > 0 && port <= 65535;

  /// Runs until either side closes: 0 when the relay ended normally, 64 when it wasn't started by Mochi, 69 when the app
  /// isn't listening.
  Future<int> run() async {
    final token = environment[tokenKey];
    final port = int.tryParse(environment[portKey] ?? '');
    if (!validToken(token) || !validPort(port)) {
      err.writeln('mochi: paws is started by Mochi itself');
      return 64;
    }
    final Socket socket;
    try {
      socket = await _connect(port!).timeout(connectTimeout);
    } on Object {
      err.writeln('mochi: the app is not listening');
      return 69;
    }
    final finished = Completer<void>();
    void finish() {
      if (!finished.isCompleted) finished.complete();
    }

    try {
      socket.add(utf8.encode('${jsonEncode({'auth': token})}\n'));
      await socket.flush();
    } on Object {
      socket.destroy();
      err.writeln('mochi: the app is not listening');
      return 69;
    }
    // The app's answers to stdout.
    socket.listen(
      (data) {
        try {
          output.add(data);
        } on Object {
          finish();
        }
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    // stdin to the app; stdin closing half-closes the socket, and the app ends the conversation.
    final reading = input.listen(
      (data) {
        try {
          socket.add(data);
        } on Object {
          finish();
        }
      },
      onDone: () {
        unawaited(socket.close().then((_) {}, onError: (Object _) {}));
      },
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    await finished.future;
    unawaited(reading.cancel());
    socket.destroy();
    try {
      await output.flush();
    } on Object {
      // Claude Code closed its end already.
    }
    return 0;
  }
}
