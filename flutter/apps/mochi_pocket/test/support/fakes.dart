// Test doubles: a relay socket the test drives as the Mac (frames sealed with the room key for real, so the app's
// RelayLink runs unchanged), and fakes for the platform, notifications and links.

import 'dart:async';
import 'dart:convert';

import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/services/alert_notifier.dart';
import 'package:mochi_pocket/src/services/link_opener.dart';
import 'package:mochi_pocket/src/services/platform_bridge.dart';
import 'package:mochi_pocket/src/services/push/push_service.dart';

final List<int> roomKey = List.filled(32, 7);

final LinkCredentials macCredentials = LinkCredentials(
  relay: 'relay.test',
  room: 'room_1',
  device: 'dev_mac',
  secret: 'mac-secret',
  key: LinkCrypto.base64url(roomKey),
  role: 'host',
);

final LinkCredentials phoneCredentials = LinkCredentials(
  relay: 'relay.test',
  room: 'room_1',
  device: 'dev_phone',
  secret: 'phone-secret',
  key: LinkCrypto.base64url(roomKey),
  role: 'pocket',
  peerName: 'Test Mac',
);

/// The Mac's pairing code for [phoneCredentials]' room.
final PairingCode pairingCode = PairingCode(
  relay: 'relay.test',
  room: 'room_1',
  invite: 'invite-1',
  key: LinkCrypto.base64url(roomKey),
  name: 'Test Mac',
);

/// One socket to the relay, opened as soon as it's made.
class FakeSocket implements LinkSocket {
  FakeSocket(this.url, this.headers) {
    _ready.complete();
  }

  final Uri url;
  final Map<String, String> headers;
  final Completer<void> _ready = Completer();
  final StreamController<Object?> _frames = StreamController();
  final List<Map<String, Object?>> sent = [];
  int? _closeCode;
  bool closed = false;

  void deliver(Map<String, Object?> frame) {
    if (!_frames.isClosed) _frames.add(jsonEncode(frame));
  }

  /// The relay closes the socket (4004: the room was deleted).
  void drop([int? code]) {
    _closeCode = code;
    unawaited(_frames.close());
  }

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

/// The relay and the Mac, as one: makes the phone's [RelayLink] and plays the Mac's side of the room.
class FakeRelay {
  final List<FakeSocket> sockets = [];
  int _ids = 0;

  FakeSocket get socket => sockets.last;

  RelayLink connect(LinkCredentials credentials) => RelayLink(
    credentials,
    platform: 'android',
    app: 'test',
    connect: (url, headers) {
      final socket = FakeSocket(url, headers);
      sockets.add(socket);
      return socket;
    },
    backoff: (_) => const Duration(milliseconds: 1),
  );

  String _id() => 'mac-${_ids++}';

  /// The Mac puts state or sends a message, sealed as the Mac would.
  void fromMac(LinkKey key, Object? value) => socket.deliver({
    ...(jsonDecode(RelayLink.frame(value, key, macCredentials, roomKey, id: _id())) as Map).cast<String, Object?>(),
    'from': macCredentials.device,
  });

  void alert(Map<String, Object?> inner) => socket.deliver({
    ...(jsonDecode(LinkAlert.frame(inner, macCredentials, roomKey, id: _id())) as Map).cast<String, Object?>(),
    'from': macCredentials.device,
  });

  /// Who's connected: the Mac (online or not) and the phone.
  void presence({required bool macOnline, double? lastSeen}) => socket.deliver({
    'v': 1,
    'op': 'presence',
    'presence': [
      {'id': macCredentials.device, 'role': 'host', 'online': macOnline, 'lastSeen': ?lastSeen},
      {'id': phoneCredentials.device, 'role': 'pocket', 'online': true},
    ],
  });

  /// What the phone put or sent, opened: (key, value), oldest first.
  List<(String, Object?)> get fromPhone => [
    for (final socket in sockets)
      for (final frame in socket.sent)
        if (frame['op'] == 'put' || frame['op'] == 'send')
          (
            frame['key']! as String,
            RelayLink.open(jsonEncode(frame), phoneCredentials, from: phoneCredentials.device, roomKey: roomKey)?.value,
          ),
  ];

  List<Object?> sentValues(LinkKey key) => [
    for (final (name, value) in fromPhone)
      if (name == key.name) value,
  ];
}

class FakeNotifier implements AlertNotifier {
  final List<LinkAlert> shown = [];
  bool allowed = true;
  int permissionRequests = 0;

  @override
  Future<void> start() async {}

  @override
  Future<bool> enabled() async => allowed;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return allowed;
  }

  @override
  Future<void> show(LinkAlert alert) async => shown.add(alert);
}

class FakeBridge implements PlatformBridge {
  FakeBridge({this.initial});

  String? initial;
  final StreamController<String> controller = StreamController.broadcast();

  @override
  Future<String?> initialLink() async {
    final link = initial;
    initial = null;
    return link;
  }

  @override
  Stream<String> get links => controller.stream;

  @override
  Future<String> deviceName() async => 'Test Phone';

  @override
  Future<String?> filesDir() async => null;
}

class FakeOpener implements LinkOpener {
  final List<String> opened = [];

  @override
  Future<bool> open(AgentNote note) async {
    opened.add(note.link ?? '');
    return true;
  }

  @override
  Future<bool> openInBrowser(AgentNote note) async {
    opened.add('browser:${note.link}');
    return true;
  }
}

/// Sample state, in the fixtures' shapes.
double now() => DateTime.now().millisecondsSinceEpoch / 1000;

PetLook sampleLook({String petName = 'Mochi'}) =>
    PetLook(petName: petName, companionName: 'Patch', petColor: 'cream', deskAccessory: 'plant', theme: 'cozyDesk', friendshipLevel: 3);

AgentPending sampleAgent() => AgentPending(
  enabled: true,
  headline: 'Priya is waiting on the invoice.',
  lookedAt: now() - 300,
  updatedAt: now() - 300,
  items: [
    AgentNote(
      id: 'mail:18c2',
      source: AgentSource.gmail,
      title: 'Priya Sharma',
      detail: 'Can you send the October invoice?',
      important: true,
      at: now() - 600,
      link: 'https://mail.google.com/mail/u/0/#inbox/18c2',
      subject: 'Invoice for October',
      vip: true,
    ),
    AgentNote(
      id: 'cal:review',
      source: AgentSource.calendar,
      title: 'Design review',
      detail: 'Google Meet',
      important: true,
      at: now(),
      due: now() + 7200,
      link: 'https://meet.google.com/abc-defg-hij',
    ),
  ],
);

PhoneSessions sampleSessions() => PhoneSessions(
  enabled: true,
  updatedAt: now(),
  sessions: [
    PhoneSessionCard(
      id: 'session-1',
      project: 'mac-Tamagotchi',
      phase: 'done',
      summary: const TurnSummary(done: 'Gave Mochi its own voice.', next: ['Push it']),
      files: const ['KokoroVoice.swift'],
      finishedAt: now() - 600,
    ),
  ],
);

/// Push without Firebase: the test sets the address, rotates it, and delivers foreground pushes.
class FakePushService implements PushService {
  FakePushService({this.problem, this.address = 'fcm-token-1', this.failure});

  /// What [start] says (null: push works).
  String? problem;
  String? address;
  PushException? failure;
  int deletes = 0;
  final StreamController<String> refreshes = StreamController.broadcast();
  final StreamController<Map<String, Object?>> pushes = StreamController.broadcast();

  @override
  Future<String?> start() async => problem;

  @override
  Future<String?> token() async {
    final failure = this.failure;
    if (failure != null) throw failure;
    return address;
  }

  @override
  Stream<String> get tokenRefresh => refreshes.stream;

  @override
  Stream<Map<String, Object?>> get messages => pushes.stream;

  @override
  Future<void> deleteToken() async {
    deletes++;
    address = null;
  }
}

/// The relay's data-only FCM message for an alert the Mac sealed: `kind`, and `mochi` as a JSON string of
/// `{v, room, key, id, from, nonce, box}`.
Map<String, Object?> alertPush(String id, Map<String, Object?> inner, {String room = 'room_1'}) {
  final frame = (jsonDecode(LinkAlert.frame(inner, macCredentials, roomKey, id: id)) as Map).cast<String, Object?>();
  return {
    'kind': 'alert',
    'mochi': jsonEncode({
      'v': 1,
      'room': room,
      'key': 'alert',
      'id': id,
      'from': macCredentials.device,
      'nonce': frame['nonce'],
      'box': frame['box'],
    }),
    'category': 'turn',
  };
}
