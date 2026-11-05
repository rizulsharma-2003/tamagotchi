import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mochi_wire/mochi_wire.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late BridgePaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mochi_wire_bridge');
    paths = BridgePaths('${temp.path}/home', windows: false);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  WireEvent event(String name, {String session = 's1', double? ts}) =>
      WireEvent(id: 'id-$name-$session', ts: ts ?? DateTime.now().millisecondsSinceEpoch / 1000, origin: WireOrigin.hook, event: name)
        ..session = session
        ..project = 'web';

  group('WireEvent', () {
    test('sorted keys, no nulls, round trip', () {
      final e = event('Stop', ts: 1762243200)
        ..summary = 'Done.'
        ..batchTools = ['Read'];
      final json = jsonEncode(e.toJson());
      expect(
        json,
        '{"batchTools":["Read"],"event":"Stop","id":"id-Stop-s1","origin":"hook","project":"web","session":"s1","summary":"Done.","ts":1762243200,"v":1}',
      );
      expect(WireEvent.decode(json), e);
      expect(WireEvent.decode('{"v":1,"id":"x","ts":1,"origin":"hook"}'), isNull, reason: 'event is required');
      expect(WireEvent.decode('{"v":1,"id":"x","ts":1,"origin":"hook","event":"Stop","exitCode":"3"}'), isNull, reason: 'wrong type');
    });
  });

  group('EventValidator', () {
    test('accepts good events, including Windows paths; refuses bad ones', () {
      final good = event('PreToolUse')..projectPath = r'C:\Users\me\web';
      expect(EventValidator.decode(good.encodeLine().trim()).event, 'PreToolUse');
      expect(() => EventValidator.decode('nope'), throwsA(isA<WireRejection>().having((r) => r.code, 'code', 'malformed')));
      expect(
        () => EventValidator.decode(jsonEncode((event('X')..projectPath = 'relative/web').toJson())),
        throwsA(isA<WireRejection>().having((r) => r.code, 'code', 'invalid-field')),
      );
      expect(
        () => EventValidator.decode(jsonEncode(event('Stop', ts: 1000).toJson())),
        throwsA(isA<WireRejection>().having((r) => r.code, 'code', 'bad-timestamp')),
      );
      expect(
        () => EventValidator.decode(jsonEncode((event('Stop')..session = 'has space').toJson())),
        throwsA(isA<WireRejection>().having((r) => r.code, 'code', 'invalid-field')),
      );
      expect(
        () => EventValidator.decode(jsonEncode((event('Stop')..v = 2).toJson())),
        throwsA(isA<WireRejection>().having((r) => r.code, 'code', 'unsupported-version')),
      );
      final report = WireEvent(id: 'r', ts: DateTime.now().millisecondsSinceEpoch / 1000, origin: WireOrigin.report, event: 'Report')
        ..report = const WireReport(kind: 'deploy', status: 'passed');
      expect(() => EventValidator.decode(jsonEncode(report.toJson())), throwsA(isA<WireRejection>()));
    });
  });

  group('EventSpool', () {
    test('appends and drains', () {
      final spool = '${temp.path}/spool/pending.jsonl';
      expect(EventSpool.append(event('Stop').encodeLine(), spool), isTrue);
      expect(EventSpool.append(event('SessionEnd').encodeLine(), spool), isTrue);
      final drained = EventSpool.drain(spool);
      expect(drained.lines.map((line) => WireEvent.decode(line)!.event), ['Stop', 'SessionEnd']);
      expect(drained.dropped, 0);
      expect(EventSpool.drain(spool).lines, isEmpty);
    });

    test('when full, drops the oldest half and counts them', () {
      final spool = '${temp.path}/spool/pending.jsonl';
      final line = event('PreToolUse').encodeLine();
      final max = line.length * 10;
      for (var i = 0; i < 25; i++) {
        expect(EventSpool.append(line, spool, maxBytes: max), isTrue);
      }
      final drained = EventSpool.drain(spool);
      expect(drained.dropped, greaterThan(0));
      expect(drained.lines.length + drained.dropped, 25);
      expect(File(spool).lengthSync(), 0);
    });
  });

  group('Bridge', () {
    test('a helper delivers to the running app, with the token', () async {
      final server = BridgeServer(paths);
      final received = <WireEvent>[];
      server.events.listen(received.add);
      await server.start();
      addTearDown(server.dispose);
      final endpoint = BridgeEndpoint.read(paths.bridgeFile)!;
      expect(endpoint.token, hasLength(64));
      expect(endpoint.port, server.endpoint!.port);

      final outcome = await BridgeClient.send(event('Stop').encodeLine(), paths.bridgeFile);
      expect(outcome, isA<BridgeAccepted>());
      await pumpEventQueue();
      expect(received.single.event, 'Stop');
      expect(server.accepted, 1);
    });

    test('a wrong token or an invalid event is refused and never delivered', () async {
      final server = BridgeServer(paths);
      final received = <WireEvent>[];
      server.events.listen(received.add);
      await server.start();
      addTearDown(server.dispose);

      final forged = File('${temp.path}/forged.json')
        ..writeAsStringSync(jsonEncode(BridgeEndpoint(port: server.endpoint!.port, token: 'f' * 64).toJson()));
      expect(await BridgeClient.send(event('Stop').encodeLine(), forged.path), isA<BridgeRejected>());
      final invalid = await BridgeClient.send('{"v":1}', paths.bridgeFile);
      expect(invalid, isA<BridgeRejected>().having((r) => r.reason, 'reason', 'malformed'));

      // A raw connection that sends nothing is cut off by the deadline.
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.endpoint!.port);
      final answer = await utf8.decoder.bind(socket).join().timeout(const Duration(seconds: 5));
      expect(answer.trim(), 'rejected timeout');
      socket.destroy();

      await pumpEventQueue();
      expect(received, isEmpty);
      expect(server.rejected, 3);
    });

    test('nothing listening: unavailable; pings are accepted but not delivered', () async {
      expect(await BridgeClient.send(event('Stop').encodeLine(), paths.bridgeFile), isA<BridgeUnavailable>());
      final server = BridgeServer(paths);
      final received = <WireEvent>[];
      server.events.listen(received.add);
      await server.start();
      final ping = WireEvent(id: 'ping-1', ts: DateTime.now().millisecondsSinceEpoch / 1000, origin: WireOrigin.ping, event: 'Ping');
      expect(await BridgeClient.send(ping.encodeLine(), paths.bridgeFile), isA<BridgeAccepted>());
      await pumpEventQueue();
      expect(received, isEmpty);

      // A second copy of the app doesn't steal the bridge.
      await expectLater(BridgeServer(paths).start(), throwsStateError);
      await server.dispose();
      expect(File(paths.bridgeFile).existsSync(), isFalse);
      // A stale file from a crashed app doesn't block the next start.
      File(paths.bridgeFile).writeAsStringSync(
        jsonEncode(const BridgeEndpoint(port: 1, token: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa').toJson()),
      );
      final next = BridgeServer(paths);
      await next.start();
      await next.dispose();
    });
  });

  group('HookCli', () {
    HookCli cli(List<int> input, StringBuffer out, StringBuffer err) => HookCli(
      environment: {'CLAUDE_PROJECT_DIR': '/Users/me/code/web'},
      stdinBytes: Stream.value(input),
      out: out,
      err: err,
      paths: paths,
    );

    List<int> stop() => utf8.encode(jsonEncode({'hook_event_name': 'Stop', 'session_id': 's1', 'last_assistant_message': 'All done.'}));

    test('claude-hook delivers to the app and prints nothing', () async {
      final server = BridgeServer(paths);
      final received = <WireEvent>[];
      server.events.listen(received.add);
      await server.start();
      addTearDown(server.dispose);
      final out = StringBuffer(), err = StringBuffer();
      expect(await cli(stop(), out, err).run(['claude-hook', 'Stop']), 0);
      await pumpEventQueue();
      expect(out.toString(), isEmpty);
      expect(err.toString(), isEmpty);
      expect(received.single.event, 'Stop');
      expect(received.single.project, 'web');
      expect(received.single.summary, isNull, reason: 'summaries are off');
    });

    test('with summaries shared, the closing message goes to the running app', () async {
      final server = BridgeServer(paths);
      final received = <WireEvent>[];
      server.events.listen(received.add);
      await server.start();
      addTearDown(server.dispose);
      File(paths.summariesFlagFile).writeAsStringSync('');
      expect(await cli(stop(), StringBuffer(), StringBuffer()).run(['claude-hook', 'Stop']), 0);
      await pumpEventQueue();
      expect(received.single.summary, 'All done.');
    });

    test("app not running: the event is spooled without Claude's words, and the exit code is still 0", () async {
      Directory(paths.home).createSync(recursive: true);
      File(paths.summariesFlagFile).writeAsStringSync('');
      final out = StringBuffer();
      final hook = cli(stop(), out, StringBuffer());
      expect(await hook.run(['claude-hook', 'Stop']), 0);
      expect(hook.lastOutcome, isA<BridgeUnavailable>());
      expect(out.toString(), isEmpty);
      final drained = EventSpool.drain(paths.spoolFile);
      final spooled = WireEvent.decode(drained.lines.single)!;
      expect(spooled.event, 'Stop');
      expect(spooled.summary, isNull);
      expect(drained.lines.single, isNot(contains('All done')));
    });

    test('report and ping', () async {
      final out = StringBuffer(), err = StringBuffer();
      expect(await cli(const [], out, err).run(['report', 'deploy', 'passed']), 64);
      expect(await cli(const [], out, err).run(['report', 'test', 'passed', '--label', 'unit']), 0);
      expect(err.toString(), contains('not running'));
      expect(
        WireEvent.decode(EventSpool.drain(paths.spoolFile).lines.single)!.report,
        const WireReport(kind: 'test', status: 'passed', label: 'unit'),
      );
      expect(await cli(const [], out, err).run(['ping']), 1);
      expect(EventSpool.drain(paths.spoolFile).lines, isEmpty, reason: 'pings are never spooled');
      expect(await cli(const [], out, err).run(['--version']), 0);
      expect(out.toString(), contains('mochi_hook ${HelperInfo.version}'));
    });

    test(
      'the real helper (dart run) exits 0 with nothing on stdout, and spools while the app is away',
      () async {
        final process = await Process.start(
          Platform.resolvedExecutable,
          ['run', 'bin/mochi_hook.dart', 'claude-hook', 'SessionStart'],
          // These tests may themselves run inside Claude Code: its project folder mustn't leak in.
          environment: {'MOCHI_DESKTOP_HOME': paths.home, 'CLAUDE_PROJECT_DIR': ''},
        );
        process.stdin.add(utf8.encode(jsonEncode({'hook_event_name': 'SessionStart', 'session_id': 'real', 'cwd': '/tmp/demo'})));
        await process.stdin.close();
        final stdoutText = await utf8.decoder.bind(process.stdout).join();
        await process.stderr.drain<void>();
        expect(await process.exitCode, 0);
        expect(stdoutText, isEmpty);
        final spooled = WireEvent.decode(EventSpool.drain(paths.spoolFile).lines.single)!;
        expect(spooled.session, 'real');
        expect(spooled.project, 'demo');
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );
  });
}
