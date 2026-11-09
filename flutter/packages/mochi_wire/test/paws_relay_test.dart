import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mochi_wire/mochi_wire.dart';
import 'package:test/test.dart';

/// `mochi_hook paws`: MCP over stdio to the app's loopback tool server, opening with the one-time token.
void main() {
  const token = 'abcdef0123456789abcdef0123456789abcdef0123456789';
  late ServerSocket server;
  late StreamController<List<int>> stdinController;
  late StreamController<List<int>> stdoutController;
  late List<int> stdoutBytes;
  late StringBuffer err;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    stdinController = StreamController<List<int>>();
    stdoutController = StreamController<List<int>>();
    stdoutBytes = [];
    stdoutController.stream.listen(stdoutBytes.addAll);
    err = StringBuffer();
  });

  tearDown(() async {
    await server.close();
    if (!stdinController.isClosed) unawaited(stdinController.close());
    if (!stdoutController.isClosed) unawaited(stdoutController.close());
  });

  PawsRelay relay(Map<String, String> environment) =>
      PawsRelay(environment: environment, input: stdinController.stream, output: IOSink(stdoutController.sink), err: err);

  Map<String, String> good() => {PawsRelay.portKey: '${server.port}', PawsRelay.tokenKey: token};

  test('refuses to run unless Mochi started it: a missing, short or non-hex token, or a bad port', () async {
    for (final environment in [
      <String, String>{},
      {PawsRelay.portKey: '${server.port}'},
      {PawsRelay.portKey: '${server.port}', PawsRelay.tokenKey: 'abc'},
      {PawsRelay.portKey: '${server.port}', PawsRelay.tokenKey: 'zz${token.substring(2)}'},
      {PawsRelay.portKey: '0', PawsRelay.tokenKey: token},
      {PawsRelay.portKey: 'http', PawsRelay.tokenKey: token},
      {PawsRelay.portKey: '70000', PawsRelay.tokenKey: token},
    ]) {
      expect(await relay(environment).run(), 64, reason: '$environment');
    }
    expect(err.toString(), contains('started by Mochi itself'));
    expect(err.toString(), isNot(contains(token)));
  });

  test('says so, and exits 69, when the app is not listening', () async {
    final port = server.port;
    await server.close();
    expect(await relay({PawsRelay.portKey: '$port', PawsRelay.tokenKey: token}).run(), 69);
    expect(err.toString(), contains('not listening'));
    expect(err.toString(), isNot(contains(token)));
  });

  test('opens with {"auth":token}, then copies stdin to the app and the app to stdout, byte for byte', () async {
    final received = StringBuffer();
    final connection = Completer<Socket>();
    server.listen((socket) {
      connection.complete(socket);
      socket.listen((data) => received.write(utf8.decode(data)));
    });
    final running = relay(good()).run();
    final socket = await connection.future;
    stdinController.add(utf8.encode('{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'));
    await _until(() => received.toString().contains('tools/list'));
    expect(received.toString().split('\n').first, '{"auth":"$token"}');
    expect(received.toString().split('\n')[1], '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
    socket.add(utf8.encode('{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}\n'));
    await _until(() => stdoutBytes.isNotEmpty);
    expect(utf8.decode(stdoutBytes), '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}\n');
    // The app hangs up: the relay ends.
    await socket.close();
    socket.destroy();
    expect(await running.timeout(const Duration(seconds: 5)), 0);
    expect(err.toString(), isEmpty);
  });

  test('stdin closing ends the conversation: the app sees the end of its input', () async {
    final done = Completer<void>();
    server.listen((socket) {
      socket.listen(
        (_) {},
        onDone: () {
          done.complete();
          socket.destroy();
        },
      );
    });
    final running = relay(good()).run();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await stdinController.close();
    await done.future.timeout(const Duration(seconds: 5));
    expect(await running.timeout(const Duration(seconds: 5)), 0);
  });

  test('is a subcommand of the helper that prints nothing about the token', () {
    // The relay's own text never includes the token or the environment.
    expect(PawsRelay.validToken(token), isTrue);
    expect(PawsRelay.validToken(null), isFalse);
    expect(PawsRelay.validToken('a' * 129), isFalse);
    expect(PawsRelay.validPort(65535), isTrue);
    expect(PawsRelay.validPort(65536), isFalse);
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
