import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocketException;

import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A socket the test drives as if it were the relay.
class FakeSocket implements LinkSocket {
  FakeSocket(this.url, this.headers);

  final Uri url;
  final Map<String, String> headers;
  final Completer<void> _ready = Completer();
  final StreamController<Object?> _frames = StreamController();
  final List<Map<String, Object?>> sent = [];
  int? _closeCode;
  bool closed = false;

  void open() => _ready.complete();

  void refuse(Object error) {
    _ready.completeError(error);
    _frames.addError(error);
    unawaited(_frames.close());
  }

  void deliver(Map<String, Object?> frame) => _frames.add(jsonEncode(frame));

  void deliverRaw(Object data) => _frames.add(data);

  /// The relay (or the network) closes the socket.
  void drop([int? code]) {
    _closeCode = code;
    unawaited(_frames.close());
  }

  List<String?> get ops => [for (final frame in sent) frame['op'] as String?];

  List<Map<String, Object?>> sentOp(String op) => sent.where((frame) => frame['op'] == op).toList();

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<Object?> get stream => _frames.stream;

  @override
  void send(String text) {
    if (!closed) sent.add((jsonDecode(text) as Map).cast<String, Object?>());
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    if (!_frames.isClosed) await _frames.close();
  }

  @override
  int? get closeCode => _closeCode;
}

void main() {
  final roomKey = List.filled(32, 3);
  final host = LinkCredentials(
    relay: 'link.example.com',
    room: 'room_1',
    device: 'dev_mac',
    secret: 's1',
    key: LinkCrypto.base64url(roomKey),
    role: 'host',
  );
  final phone = LinkCredentials.fromJson({...host.toJson(), 'device': 'dev_phone', 'secret': 's2', 'role': 'pocket'})!;

  late List<FakeSocket> sockets;
  late RelayLink link;
  late List<List<LinkKey>> changes;
  late List<LinkIncoming> incoming;
  late List<LinkRelayError> errors;

  RelayLink makeLink(LinkCredentials credentials) {
    final made = RelayLink(
      credentials,
      platform: 'android',
      app: '0.1.0',
      connect: (url, headers) {
        final socket = FakeSocket(url, headers);
        sockets.add(socket);
        return socket;
      },
      backoff: (_) => const Duration(milliseconds: 1),
    );
    made.changes.listen(changes.add);
    made.incoming.listen(incoming.add);
    made.errors.listen(errors.add);
    return made;
  }

  /// A frame another device sealed, as the relay forwards it (with `from`).
  Map<String, Object?> fromPhone(Object? value, LinkKey key, {String? id, String from = 'dev_phone'}) => {
    ...(jsonDecode(RelayLink.frame(value, key, phone, roomKey, id: id)) as Map).cast<String, Object?>(),
    'from': from,
  };

  Future<FakeSocket> connected() async {
    link.start();
    await pumpEventQueue();
    final socket = sockets.last..open();
    await pumpEventQueue();
    return socket;
  }

  setUp(() {
    sockets = [];
    changes = [];
    incoming = [];
    errors = [];
    link = makeLink(host);
  });

  tearDown(() => link.dispose());

  test('connects to the room socket with the bearer credential and says hello', () async {
    final socket = await connected();
    expect(socket.url.toString(), 'wss://link.example.com/v1/rooms/room_1/socket');
    expect(socket.headers, {'authorization': 'Bearer dev_mac.s1'});
    expect(link.status, LinkStatus.online);
    expect(socket.sent.first, {'v': 1, 'op': 'hello', 'platform': 'android', 'app': '0.1.0', 'client': 1});
  });

  test('reads its own writes; offline writes wait in an outbox (state only its newest) and go after hello', () async {
    link.set('{"petName":"A"}', LinkKey.look);
    link.set({'id': 'c1', 'text': 'one', 'at': 1, 'typed': true}, LinkKey.command);
    link.set('{"petName":"B"}', LinkKey.look);
    link.set({'id': 'c2', 'text': 'two', 'at': 2, 'typed': true}, LinkKey.command);
    expect(link.string(LinkKey.look), '{"petName":"B"}');
    expect(link.map(LinkKey.command)?['id'], 'c2');
    expect(link.hasAnyValue, isTrue);
    final socket = await connected();
    expect(socket.ops, ['hello', 'send', 'put', 'send']);
    expect(
      [for (final frame in socket.sent.skip(1)) RelayLink.open(jsonEncode(frame), host, from: 'dev_mac', roomKey: roomKey)!.value],
      [
        {'id': 'c1', 'text': 'one', 'at': 1, 'typed': true},
        '{"petName":"B"}',
        {'id': 'c2', 'text': 'two', 'at': 2, 'typed': true},
      ],
    );
    expect(changes, isEmpty, reason: 'own writes are not changes');
    link.set(null, LinkKey.look);
    expect(link.value(LinkKey.look), isNull);
  });

  test('frames the relay never acknowledged go again after a reconnect; acknowledged ones don\'t', () async {
    var socket = await connected();
    link.set({'id': 'c1', 'text': 'one', 'at': 1}, LinkKey.command);
    link.set('{"petName":"A"}', LinkKey.look);
    final command = socket.sentOp('send').single, look = socket.sentOp('put').single;
    socket.deliver({'v': 1, 'op': 'ack', 'id': look['id'], 'key': 'look', 'at': 1});
    await pumpEventQueue();
    socket.drop();
    await pumpEventQueue();
    expect(link.status, isNot(LinkStatus.online));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sockets.length, 2, reason: 'reconnected after the backoff');
    socket = sockets.last..open();
    await pumpEventQueue();
    expect(link.status, LinkStatus.online);
    expect(socket.ops, ['hello', 'send']);
    expect(socket.sent[1]['id'], command['id']);
    // Acknowledged now: the next connection has nothing to resend.
    socket.deliver({'v': 1, 'op': 'ack', 'id': command['id'], 'key': 'command', 'at': 2, 'duplicate': true});
    await pumpEventQueue();
    socket.drop(1006);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sockets.last.open();
    await pumpEventQueue();
    expect(sockets.last.ops, ['hello']);
  });

  test('what waited offline is sent again if the connection drops before the relay acknowledged it', () async {
    link.set({'id': 'c1', 'text': 'offline', 'at': 1}, LinkKey.command);
    var socket = await connected();
    final id = socket.sentOp('send').single['id'];
    socket.drop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    socket = sockets.last..open();
    await pumpEventQueue();
    expect(socket.ops, ['hello', 'send']);
    expect(socket.sent[1]['id'], id);
  });

  test('another device\'s state and messages are opened, applied, announced, acked and deduplicated', () async {
    final socket = await connected();
    socket.deliver(fromPhone('{"ids":{"mail:1":5}}', LinkKey.phoneDone, id: 'p1'));
    socket.deliver(fromPhone({'id': 'c1', 'text': 'hi', 'at': 1.5, 'typed': false}, LinkKey.command, id: 'm1'));
    socket.deliver(fromPhone({'id': 'c1', 'text': 'hi', 'at': 1.5, 'typed': false}, LinkKey.command, id: 'm1'));
    await pumpEventQueue();
    expect(AgentDoneList.fromValue(link.value(LinkKey.phoneDone))?.ids, {'mail:1': 5});
    expect(LinkCommand.fromValue(link.value(LinkKey.command))?.text, 'hi');
    expect(changes, [
      [LinkKey.phoneDone],
      [LinkKey.command],
    ]);
    expect(incoming.map((item) => (item.key, item.id, item.from, item.isMessage)), [
      (LinkKey.phoneDone, 'p1', 'dev_phone', false),
      (LinkKey.command, 'm1', 'dev_phone', true),
    ]);
    // Messages are acked every time they arrive (the relay keeps them queued until then); state isn't.
    expect(socket.sentOp('ack'), [
      {'v': 1, 'op': 'ack', 'id': 'm1'},
      {'v': 1, 'op': 'ack', 'id': 'm1'},
    ]);
  });

  test('a frame that doesn\'t open (claims another sender, wrong room key) is ignored, and a message still acked', () async {
    final socket = await connected();
    socket.deliver(fromPhone({'id': 'c1', 'text': 'forged'}, LinkKey.command, id: 'm1', from: 'dev_cloud'));
    socket.deliver({...fromPhone('{}', LinkKey.look, id: 'p1'), 'key': 'claude'});
    socket.deliverRaw('pong');
    socket.deliverRaw('[1, 2]');
    socket.deliver(fromPhone('x', LinkKey.look)..['key'] = 'agentNews');
    await pumpEventQueue();
    expect(link.value(LinkKey.command), isNull);
    expect(link.value(LinkKey.claude), isNull);
    expect(changes, isEmpty);
    expect(socket.sentOp('ack').map((ack) => ack['id']), ['m1']);
  });

  test('sync brings the room\'s state (clearing what\'s gone), then the queue, devices and presence', () async {
    link.set('{"mine":true}', LinkKey.sessions);
    final socket = await connected();
    // The relay has the sessions put now.
    socket.deliver({'v': 1, 'op': 'ack', 'id': socket.sentOp('put').single['id'], 'key': 'sessions', 'at': 1});
    // Something from an earlier connection that the room has since cleared.
    socket.deliver(fromPhone({'phase': 'idle'}, LinkKey.claude, id: 'old'));
    await pumpEventQueue();
    changes.clear();
    incoming.clear();
    socket.deliver({
      'v': 1,
      'op': 'sync',
      'at': 10,
      'room': 'room_1',
      'device': 'dev_mac',
      'role': 'host',
      'minClientVersion': 1,
      'state': [fromPhone('{"ids":{}}', LinkKey.phoneDone, id: 's1')],
      'queue': [
        fromPhone({'id': 'c1', 'text': 'while away', 'at': 3}, LinkKey.command, id: 'q1'),
        fromPhone({'id': 'v1', 'allow': true, 'at': 4}, LinkKey.verdict, id: 'q2'),
      ],
      'devices': [
        {'id': 'dev_mac', 'role': 'host', 'platform': 'windows', 'name': 'PC', 'app': '0.1.0', 'online': true, 'lastSeen': 9},
        {'id': 'dev_phone', 'role': 'pocket', 'platform': 'ios', 'name': 'iPhone', 'online': false, 'lastSeen': 5},
      ],
      'presence': [
        {'id': 'dev_mac', 'role': 'host', 'online': true, 'lastSeen': 9},
        {'id': 'dev_phone', 'role': 'pocket', 'online': true, 'lastSeen': 10},
      ],
    });
    await pumpEventQueue();
    expect(link.value(LinkKey.claude), isNull, reason: 'not in the sync: cleared while away');
    expect(link.value(LinkKey.sessions), isNull, reason: 'acknowledged and then cleared by the room');
    expect(link.value(LinkKey.phoneDone), '{"ids":{}}');
    expect(link.map(LinkKey.command)?['text'], 'while away');
    expect(link.map(LinkKey.verdict)?['allow'], true);
    expect(incoming.map((item) => item.id), ['s1', 'q1', 'q2']);
    expect(changes.first.toSet(), {LinkKey.claude, LinkKey.sessions});
    expect(socket.sentOp('ack').map((ack) => ack['id']), ['q1', 'q2']);
    expect(link.peers.map((peer) => (peer.device, peer.role, peer.name, peer.platform, peer.online)), [
      ('dev_mac', 'host', 'PC', 'windows', true),
      ('dev_phone', 'pocket', 'iPhone', 'ios', true),
    ]);
    expect(link.onlinePeers.map((peer) => peer.device), ['dev_phone']);
    expect(link.lastSync, isNotNull);
    expect(link.updateRequired, isFalse);
  });

  test('a state key this device is still writing survives an older sync', () async {
    final socket = await connected();
    link.set('{"petName":"new"}', LinkKey.look);
    link.set('{"ids":{"a":1}}', LinkKey.macDone);
    socket.deliver({
      'v': 1,
      'op': 'sync',
      'state': [fromPhone('{"petName":"old"}', LinkKey.look, id: 'older')],
      'queue': <Object?>[],
    });
    await pumpEventQueue();
    expect(link.string(LinkKey.look), '{"petName":"new"}');
    expect(link.string(LinkKey.macDone), '{"ids":{"a":1}}');
  });

  test('presence updates who is online and keeps the names from devices; devices replaces the list', () async {
    final socket = await connected();
    final presence = <LinkPresence>[];
    link.presence.listen(presence.add);
    link.requestDevices();
    expect(socket.sent.last, {'v': 1, 'op': 'devices'});
    socket.deliver({
      'v': 1,
      'op': 'devices',
      'change': 'joined',
      'device': 'dev_phone',
      'devices': [
        {'id': 'dev_mac', 'role': 'host', 'name': 'PC', 'online': true},
        {'id': 'dev_phone', 'role': 'pocket', 'name': 'Pixel', 'online': false},
      ],
    });
    socket.deliver({
      'v': 1,
      'op': 'presence',
      'presence': [
        {'id': 'dev_phone', 'role': 'pocket', 'online': true, 'lastSeen': 12},
      ],
    });
    await pumpEventQueue();
    expect(link.onlinePeers.single.name, 'Pixel');
    expect(link.onlinePeers.single.lastSeen, 12);
    expect(presence.last.onlinePeers.single.device, 'dev_phone');
    socket.deliver({
      'v': 1,
      'op': 'devices',
      'change': 'removed',
      'device': 'dev_phone',
      'devices': [
        {'id': 'dev_mac', 'role': 'host', 'name': 'PC', 'online': true},
      ],
    });
    await pumpEventQueue();
    expect(link.peers.map((peer) => peer.device), ['dev_mac']);
    expect(link.onlinePeers, isEmpty);
  });

  test('a refusal is final: reported, and not sent again', () async {
    var socket = await connected();
    link.set({'id': 'r1', 'state': 'done', 'at': 1}, LinkKey.reply);
    final id = socket.sentOp('send').single['id'];
    socket.deliver({'v': 1, 'op': 'error', 'code': 'forbidden', 'message': 'A pocket may not send `reply`.', 'id': id, 'key': 'reply'});
    await pumpEventQueue();
    expect(errors.single.code, 'forbidden');
    expect(errors.single.key, 'reply');
    socket.drop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    socket = sockets.last..open();
    await pumpEventQueue();
    expect(socket.ops, ['hello']);
  });

  test('a put without a box is the relay clearing that key', () async {
    final socket = await connected();
    socket.deliver(fromPhone('{"ids":{}}', LinkKey.phoneDone, id: 'p1'));
    socket.deliver({'v': 1, 'op': 'put', 'key': 'phoneDone', 'id': 'p2', 'from': 'dev_phone', 'at': 2});
    await pumpEventQueue();
    expect(link.value(LinkKey.phoneDone), isNull);
    expect(changes, [
      [LinkKey.phoneDone],
      [LinkKey.phoneDone],
    ]);
  });

  test('revoked (4001) or a deleted room (4004) ends the link instead of retrying', () async {
    for (final code in [4001, 4004]) {
      final socket = await connected();
      socket.drop(code);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(link.status, LinkStatus.removed, reason: '$code');
      expect(sockets.last, same(socket), reason: 'no reconnect after $code');
    }
  });

  test('a refused upgrade (401) ends the link; other failures retry with backoff', () async {
    link.start();
    await pumpEventQueue();
    sockets.last.refuse(WebSocketChannelException.from(const WebSocketException('not upgraded', 503)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sockets.length, 2);
    sockets.last.refuse(WebSocketChannelException.from(const WebSocketException('not upgraded', 401)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(link.status, LinkStatus.removed);
    expect(sockets.length, 2);
  });

  test('stop goes offline and stays there; reconnectNow skips the wait', () async {
    final socket = await connected();
    await link.stop();
    expect(link.status, LinkStatus.offline);
    expect(socket.closed, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sockets.length, 1);
    final patient = RelayLink(
      host,
      connect: (url, headers) {
        final socket = FakeSocket(url, headers);
        sockets.add(socket);
        return socket;
      },
      backoff: (_) => const Duration(hours: 1),
    );
    patient.start();
    await pumpEventQueue();
    sockets.last.drop();
    await pumpEventQueue();
    expect(sockets.length, 2);
    patient.reconnectNow();
    await pumpEventQueue();
    expect(sockets.length, 3);
    await patient.dispose();
  });

  test('an old relay says it wants a newer client', () async {
    final socket = await connected();
    socket.deliver({'v': 1, 'op': 'sync', 'minClientVersion': 2, 'state': <Object?>[], 'queue': <Object?>[]});
    await pumpEventQueue();
    expect(link.updateRequired, isTrue);
  });

  test('credentials without a 32-byte key are refused', () {
    expect(() => RelayLink(LinkCredentials.fromJson({...host.toJson(), 'key': 'short'})!), throwsArgumentError);
  });

  test('backoff doubles up to a minute, with up to a second of jitter', () {
    expect(RelayLink.defaultBackoff(1).inMilliseconds, inInclusiveRange(2000, 3000));
    expect(RelayLink.defaultBackoff(3).inMilliseconds, inInclusiveRange(8000, 9000));
    expect(RelayLink.defaultBackoff(20).inMilliseconds, inInclusiveRange(60000, 61000));
  });

  group('alerts', () {
    const inner = {
      'title': 'Claude finished',
      'body': 'mac-Tamagotchi: tests pass.',
      'userInfo': {'card': 'session-1'},
    };

    /// An alert the Mac sealed, as the relay forwards it.
    Map<String, Object?> fromMac(String id, {Map<String, Object?> body = inner, String from = 'dev_mac'}) => {
      ...(jsonDecode(LinkAlert.frame(body, host, roomKey, id: id, category: 'turn', threadId: 'session-1')) as Map).cast<String, Object?>(),
      'from': from,
    };

    test('a sealed alert reaches a phone once, acked, without touching state or messages', () async {
      await link.dispose();
      link = makeLink(phone);
      final alerts = <LinkAlert>[];
      link.alerts.listen(alerts.add);
      final socket = await connected();
      socket.deliver(fromMac('a1'));
      socket.deliver(fromMac('a1'));
      socket.deliver({
        'v': 1,
        'op': 'sync',
        'state': <Object?>[],
        'queue': [
          fromMac('a2', body: {'body': 'Queued while away'}),
        ],
      });
      await pumpEventQueue();
      expect(alerts.map((alert) => alert.id), ['a1', 'a2']);
      expect(alerts.first.from, 'dev_mac');
      expect(alerts.first.title, 'Claude finished');
      expect(alerts.first.body, 'mac-Tamagotchi: tests pass.');
      expect(alerts.first.userInfo, {'card': 'session-1'});
      expect(alerts.last.title, isNull);
      expect(alerts.last.body, 'Queued while away');
      expect([for (final ack in socket.sentOp('ack')) ack['id']], ['a1', 'a1', 'a2']);
      expect(changes, isEmpty);
      expect(incoming, isEmpty);
    });

    test("an alert that doesn't open (another sender in the associated data) is dropped, but acked", () async {
      await link.dispose();
      link = makeLink(phone);
      final alerts = <LinkAlert>[];
      link.alerts.listen(alerts.add);
      final socket = await connected();
      socket.deliver(fromMac('a1', from: 'dev_mallory'));
      await pumpEventQueue();
      expect(alerts, isEmpty);
      expect(socket.sentOp('ack').single['id'], 'a1');
    });

    test('sendAlert writes the Swift frame: to the pockets, an alert push hint, the inner JSON sealed unwrapped', () async {
      final socket = await connected();
      link.sendAlert(inner, category: 'turn', threadId: 'session-1', collapse: 'turn-1');
      final frame = socket.sentOp('send').single;
      expect(frame['key'], 'alert');
      expect(frame['to'], ['pocket']);
      expect(frame['ttl'], 3600);
      expect(frame['push'], {'kind': 'alert', 'priority': 10, 'collapse': 'turn-1', 'category': 'turn', 'threadId': 'session-1'});
      final opened = LinkAlert.open({...frame, 'from': 'dev_mac'}, room: 'room_1', roomKey: roomKey)!;
      expect(opened.toJson(), inner);
      // The notification extension's associated data: mochi-link/v1|<room>|alert|<id>|<from>.
      final plain = LinkCrypto.open(
        LinkSealed(nonce: frame['nonce']! as String, box: frame['box']! as String),
        ad: 'mochi-link/v1|room_1|alert|${frame['id']}|dev_mac',
        key: roomKey,
      );
      expect(jsonDecode(utf8.decode(plain!)), inner);
    });
  });
}
