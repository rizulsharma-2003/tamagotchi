import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'bridge_paths.dart';
import 'event_validator.dart';
import 'wire_event.dart';

/// How a delivery to the app went (Swift `BridgeClient.Outcome`).
sealed class BridgeOutcome {
  const BridgeOutcome();
}

/// The app validated and accepted the event.
class BridgeAccepted extends BridgeOutcome {
  const BridgeAccepted();

  @override
  String toString() => 'accepted';
}

/// The app got the event but refused it (invalid, wrong token, …).
class BridgeRejected extends BridgeOutcome {
  const BridgeRejected(this.reason);

  final String reason;

  @override
  String toString() => 'rejected ($reason)';
}

/// Nothing is listening, or the exchange didn't complete.
class BridgeUnavailable extends BridgeOutcome {
  const BridgeUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'unavailable ($reason)';
}

/// Where the app listens: a loopback TCP port and the token a helper has to show. The app writes it to
/// [BridgePaths.bridgeFile] (inside the user's private folder) each time it starts.
class BridgeEndpoint {
  const BridgeEndpoint({required this.port, required this.token, this.pid});

  final int port;

  /// 32 random bytes in hex.
  final String token;
  final int? pid;

  Map<String, Object?> toJson() => {'v': 1, 'port': port, 'token': token, 'pid': ?pid};

  static BridgeEndpoint? fromJson(Object? json) {
    if (json is! Map) return null;
    final port = json['port'], token = json['token'], pid = json['pid'];
    if (port is! int || port <= 0 || port > 65535 || token is! String || token.length < 32) return null;
    return BridgeEndpoint(port: port, token: token, pid: pid is int ? pid : null);
  }

  static BridgeEndpoint? read(String path) {
    try {
      return fromJson(jsonDecode(File(path).readAsStringSync()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'BridgeEndpoint(port: $port)';
}

/// The helper's side of the local bridge (Swift `BridgeClient`), the same on Windows and macOS: one loopback TCP
/// connection per event carrying `{"auth":"<token>"}` and the event, one line each; the app answers `ok` or
/// `rejected <reason>`. Nothing listens on another interface, and without the token (readable only in the user's own
/// profile) the app refuses the event.
abstract final class BridgeClient {
  static Future<BridgeOutcome> send(String line, String bridgeFile, {Duration timeout = const Duration(milliseconds: 900)}) async {
    final endpoint = BridgeEndpoint.read(bridgeFile);
    if (endpoint == null) return const BridgeUnavailable('not running');
    Socket? socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, endpoint.port, timeout: timeout);
      final reply = StringBuffer();
      final answered = Completer<void>();
      socket.listen(
        (data) {
          reply.write(utf8.decode(data, allowMalformed: true));
          if (reply.toString().contains('\n') && !answered.isCompleted) answered.complete();
        },
        onDone: () {
          if (!answered.isCompleted) answered.complete();
        },
        onError: (Object _) {
          if (!answered.isCompleted) answered.complete();
        },
        cancelOnError: true,
      );
      socket.write('${jsonEncode({'auth': endpoint.token})}\n');
      socket.write(line.endsWith('\n') ? line : '$line\n');
      await socket.flush();
      // Half-close: the app reads to the end, then answers.
      unawaited(socket.close().then((_) {}, onError: (Object _) {}));
      await answered.future.timeout(timeout);
      final text = reply.toString().trim();
      if (text == 'ok') return const BridgeAccepted();
      if (text.startsWith('rejected')) return BridgeRejected(text.substring('rejected'.length).trim());
      return const BridgeUnavailable('no acknowledgement');
    } on SocketException catch (error) {
      return BridgeUnavailable('not running (${error.osError?.message ?? error.message})');
    } on TimeoutException {
      return const BridgeUnavailable('no acknowledgement');
    } finally {
      socket?.destroy();
    }
  }
}

/// The app's side of the bridge (Swift `LocalEventBridge`): listens on 127.0.0.1 only, checks the token on every
/// connection, takes one bounded line per connection with a short deadline and a connection cap, and validates every
/// event before [onEvent] sees it.
class BridgeServer {
  BridgeServer(this.paths, {this.maxConnections = 16, this.readTimeout = const Duration(seconds: 2), Random? random})
    : _random = random ?? Random.secure();

  final BridgePaths paths;
  final int maxConnections;
  final Duration readTimeout;
  final Random _random;

  ServerSocket? _server;
  BridgeEndpoint? _endpoint;
  int _active = 0;

  /// Events accepted, refused (bad token or invalid), and the last refusal, for Settings.
  int accepted = 0;
  int rejected = 0;
  String? lastRejection;

  final StreamController<WireEvent> _events = StreamController.broadcast();

  /// Validated events, in the order they arrived.
  Stream<WireEvent> get events => _events.stream;

  bool get listening => _server != null;
  BridgeEndpoint? get endpoint => _endpoint;

  /// Starts listening and publishes the endpoint. Throws [StateError] when another copy of the app already answers
  /// on the published endpoint (it owns the bridge).
  Future<void> start() async {
    if (_server != null) return;
    final existing = BridgeEndpoint.read(paths.bridgeFile);
    if (existing != null && await _answers(existing)) {
      throw StateError('Another copy of Mochi is already listening for Claude Code.');
    }
    if (!BridgePaths.ensurePrivateDirectory(paths.runDirectory)) {
      throw StateError("Can't create ${paths.runDirectory}");
    }
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = BridgeEndpoint(port: server.port, token: _token(), pid: pid);
    _write(endpoint);
    _server = server;
    _endpoint = endpoint;
    server.listen(_accept, onError: (Object _) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close();
    // Only remove the file if it's still ours.
    final published = BridgeEndpoint.read(paths.bridgeFile);
    if (published != null && published.token == _endpoint?.token) {
      try {
        File(paths.bridgeFile).deleteSync();
      } on FileSystemException {
        // Gone already.
      }
    }
    _endpoint = null;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  String _token() => List.generate(32, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  void _write(BridgeEndpoint endpoint) {
    final file = File(paths.bridgeFile);
    final temporary = File('${paths.bridgeFile}.${_random.nextInt(1 << 32)}.tmp');
    temporary.writeAsStringSync(jsonEncode(endpoint.toJson()), flush: true);
    BridgePaths.restrict(temporary.path);
    temporary.renameSync(file.path);
  }

  /// A ping with [endpoint]'s token: does a live app answer there?
  Future<bool> _answers(BridgeEndpoint endpoint) async {
    final ping = WireEvent(
      id: 'ping-probe',
      ts: DateTime.now().millisecondsSinceEpoch / 1000,
      origin: WireOrigin.ping,
      event: 'Ping',
    ).encodeLine();
    final outcome = await BridgeClient.send(ping, paths.bridgeFile, timeout: const Duration(milliseconds: 400));
    return outcome is BridgeAccepted;
  }

  void _accept(Socket socket) {
    if (_active >= maxConnections) {
      socket.destroy();
      return;
    }
    _active++;
    final buffer = BytesBuilder(copy: false);
    final limit = EventValidator.maxLineBytes + 1024;
    var finished = false;
    late final Timer deadline;
    void finish(String answer) {
      if (finished) return;
      finished = true;
      deadline.cancel();
      _active--;
      try {
        socket.write('$answer\n');
        unawaited(socket.flush().then((_) => socket.close()).then((_) {}, onError: (Object _) => socket.destroy()));
      } on Object {
        socket.destroy();
      }
    }

    deadline = Timer(readTimeout, () => finish('rejected timeout'));
    socket.listen(
      (data) {
        if (finished) return;
        buffer.add(data);
        if (buffer.length > limit) {
          _refuse('too-large');
          finish('rejected too-large');
        }
      },
      onDone: () => finish(_handle(buffer.takeBytes())),
      onError: (Object _) => finish('rejected io'),
      cancelOnError: true,
    );
  }

  String _handle(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final newline = text.indexOf('\n');
    if (newline < 0) return _refuse('malformed');
    String? token;
    try {
      final auth = jsonDecode(text.substring(0, newline));
      token = auth is Map && auth['auth'] is String ? auth['auth'] as String : null;
    } on FormatException {
      token = null;
    }
    final expected = _endpoint?.token;
    if (token == null || expected == null || !_sameToken(token, expected)) return _refuse('auth');
    final line = text.substring(newline + 1).trim();
    try {
      final event = EventValidator.decode(line);
      accepted++;
      if (event.origin != WireOrigin.ping && !_events.isClosed) _events.add(event);
      return 'ok';
    } on WireRejection catch (rejection) {
      return _refuse(rejection.code);
    }
  }

  String _refuse(String code) {
    rejected++;
    lastRejection = code;
    return 'rejected $code';
  }

  /// Compares in constant time, so the token can't be guessed a character at a time.
  static bool _sameToken(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}
