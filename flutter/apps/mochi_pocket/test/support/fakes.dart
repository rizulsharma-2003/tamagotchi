// Test doubles: a relay socket the test drives as the Mac (frames sealed with the room key for real, so the app's
// RelayLink runs unchanged), and fakes for the platform, notifications and links.

import 'dart:async';
import 'dart:convert';

import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/live/live_notifier.dart';
import 'package:mochi_pocket/src/live/live_update_view.dart';
import 'package:mochi_pocket/src/services/alert_notifier.dart';
import 'package:mochi_pocket/src/services/link_opener.dart';
import 'package:mochi_pocket/src/services/notify/action_dispatcher.dart';
import 'package:mochi_pocket/src/services/notify/notification_plan.dart';
import 'package:mochi_pocket/src/services/platform_bridge.dart';
import 'package:mochi_pocket/src/services/push/push_service.dart';
import 'package:mochi_pocket/src/talk/speech_listener.dart';
import 'package:mochi_pocket/src/voice/mochi_voice.dart';
import 'package:mochi_pocket/src/voice/speech_engine.dart';

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

  /// A Live Activity update as relay 1.4.0 hands it to an Android phone's socket (no box; the apns object).
  void liveActivity(Map<String, Object?> apns, {required String id}) =>
      socket.deliver({'v': 1, 'op': 'send', 'key': 'liveActivity', 'id': id, 'from': macCredentials.device, 'ttl': 600, 'apns': apns});

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

  /// The room's devices as the relay lists them, with names and platforms: the computer (a Mac by default, or
  /// `windows`), this phone and an iPhone.
  void devices({String platform = 'macOS', String name = 'Test Mac', bool online = false, double? lastSeen}) => socket.deliver({
    'v': 1,
    'op': 'devices',
    'devices': [
      {'id': macCredentials.device, 'role': 'host', 'platform': platform, 'name': name, 'online': online, 'lastSeen': ?lastSeen},
      {'id': phoneCredentials.device, 'role': 'pocket', 'platform': 'android', 'name': 'realme RMX3242', 'online': true},
      {'id': 'dev_iphone', 'role': 'pocket', 'platform': 'iOS', 'name': 'iPhone', 'online': false},
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

  /// The plan each shown alert had (its buttons and payload), in the same order as [shown].
  final List<NotificationPlan?> plans = [];

  /// Confirmations shown after a button.
  final List<ActionReceipt> receipts = [];
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
  Future<void> show(LinkAlert alert, {NotificationPlan? plan}) async {
    shown.add(alert);
    plans.add(plan);
  }

  @override
  Future<void> receipt(ActionReceipt receipt) async => receipts.add(receipt);
}

class FakeBridge implements PlatformBridge, AudioFocus {
  FakeBridge({this.initial});

  String? initial;
  final StreamController<String> controller = StreamController.broadcast();

  /// Audio focus: granted unless a "call" is on.
  bool grant = true;
  int requests = 0;
  int abandons = 0;
  final StreamController<void> focusLost = StreamController.broadcast();

  @override
  Future<bool> request() async {
    requests++;
    return grant;
  }

  @override
  Future<void> abandon() async => abandons++;

  @override
  Stream<void> get lost => focusLost.stream;

  @override
  Future<String?> initialLink() async {
    final link = initial;
    initial = null;
    return link;
  }

  @override
  Stream<String> get links => controller.stream;

  /// The place the app was started to (a widget tap, a notification's button).
  String? startPlace;
  final StreamController<String> placeController = StreamController.broadcast();

  @override
  Future<String?> initialPlace() async {
    final place = startPlace;
    startPlace = null;
    return place;
  }

  @override
  Stream<String> get places => placeController.stream;

  @override
  Future<String> deviceName() async => 'Test Phone';

  @override
  Future<String?> filesDir() async => null;

  /// "Talk to Mochi" in Quick Settings, and what Android answers when asked to add it.
  TalkTileState tile = const TalkTileState();
  String tileAnswer = 'added';
  int tileRequests = 0;

  @override
  Future<TalkTileState> talkTile() async => tile;

  @override
  Future<String> addTalkTile() async {
    tileRequests++;
    if (tileAnswer == 'added' || tileAnswer == 'already') tile = TalkTileState(added: true, canAsk: tile.canAsk);
    return tileAnswer;
  }
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

  @override
  Future<bool> openLink(String link) async {
    opened.add(link);
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

/// Text-to-speech without a phone: records what's said; with [hold], each sentence lasts until [finish] or [stop].
class FakeSpeechEngine implements SpeechEngine {
  FakeSpeechEngine({List<VoiceInfo>? installed, this.hold = false})
    : installed =
          installed ??
          const [
            VoiceInfo(name: 'en-us-x-sfg-network', locale: 'en-US', quality: 400, network: true),
            VoiceInfo(name: 'en-us-x-tpf-local', locale: 'en-US', quality: 400),
            VoiceInfo(name: 'en-in-x-ena-local', locale: 'en-IN', quality: 400),
            VoiceInfo(name: 'en-gb-x-gbb-local', locale: 'en-GB', quality: 300),
            VoiceInfo(name: 'en-au-x-aub-local', locale: 'en-AU', quality: 400, installed: false),
            VoiceInfo(name: 'hi-in-x-hia-local', locale: 'hi-IN', quality: 500),
          ];

  final List<VoiceInfo> installed;
  bool hold;
  final List<({String text, VoiceInfo? voice, double pitch, double pace})> spoken = [];
  int stops = 0;
  Completer<void>? _current;

  @override
  Future<List<VoiceInfo>> voices() async => installed;

  @override
  Future<void> speak(String text, {VoiceInfo? voice, double pitch = 1, double pace = 1}) async {
    spoken.add((text: text, voice: voice, pitch: pitch, pace: pace));
    if (!hold) return;
    final current = _current = Completer<void>();
    await current.future;
  }

  /// The sentence being said ends.
  void finish() => _current?.complete();

  @override
  Future<void> stop() async {
    stops++;
    final current = _current;
    if (current != null && !current.isCompleted) current.complete();
  }
}

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

/// The room's K_la (what the Mac seals Live Activity titles with).
final List<int> liveActivityKey = LinkCrypto.liveActivityKey(roomKey);

/// The Mac's Live Activity `apns` object (LiveActivityPayload + LinkPush.liveActivity), sealed with [liveActivityKey].
Map<String, Object?> macLiveActivity(
  String event,
  String phase, {
  required int timestamp,
  String? title,
  String? detail,
  num? since,
  int frame = 0,
  bool alert = false,
  num? dismissalDate,
  List<int>? key,
}) => LinkLiveActivity.apns(
  event: event,
  timestamp: timestamp,
  phase: phase,
  title:
      title ??
      switch (phase) {
        'working' => 'Claude is working',
        'waiting' => 'Claude needs you',
        'done' => 'Claude finished!',
        _ => 'Claude is idle',
      },
  detail: detail,
  since: (since ?? timestamp - 30).toDouble(),
  frame: frame,
  liveActivityKey: key ?? liveActivityKey,
  alert: alert,
  dismissalDate: dismissalDate?.toDouble(),
);

/// The relay's FCM data message for a Live Activity (1.4.0's `liveActivityData`).
Map<String, Object?> livePush(String id, Map<String, Object?> apns, {String room = 'room_1'}) => {
  'kind': 'liveActivity',
  'room': room,
  'id': id,
  'from': macCredentials.device,
  'apns': jsonEncode(apns),
};

/// Mochi's ongoing notification without a phone: what was shown and cancelled, and whether it's still up (set
/// [showing] false to swipe it away).
class FakeLiveNotifier implements LiveNotifier {
  final List<LiveUpdateView> shown = [];
  final List<({int? timestamp, bool force})> cancels = [];
  bool showing = false;
  bool allowed = true;
  bool? promotable;
  int resets = 0;
  int _last = -1 << 52;

  LiveUpdateView? get last => shown.lastOrNull;

  @override
  Future<LiveUpdatePosted> show(LiveUpdateView view) async {
    if (!view.force && view.timestamp <= _last) return LiveUpdatePosted.older;
    if (!view.force) _last = view.timestamp;
    if (!allowed) return LiveUpdatePosted.blocked;
    shown.add(view);
    showing = true;
    return LiveUpdatePosted.shown;
  }

  @override
  Future<void> cancel({int? timestamp, bool force = false}) async {
    cancels.add((timestamp: timestamp, force: force));
    if (!force && timestamp != null) {
      if (timestamp <= _last) return;
      _last = timestamp;
    }
    showing = false;
  }

  @override
  Future<bool> isShowing() async => showing;

  @override
  Future<LiveUpdateStatus> status() async => LiveUpdateStatus(enabled: allowed, promotable: promotable, sdk: 33);

  @override
  Future<void> reset() async {
    resets++;
    _last = -1 << 52;
  }
}

/// A speech recognizer the test speaks into: [say] streams words while Mochi listens, and [stop] answers with
/// [finalWords] (or what was heard). The microphone permission is [access]; [requestAccess] answers [afterAsking].
class FakeSpeechListener implements SpeechListener {
  MicAccess access_ = MicAccess.granted;
  MicAccess afterAsking = MicAccess.granted;
  SpeechProblem? startProblem;
  String? finalWords;

  /// Hold the answer to Android's question until [answerAccess] (the dialog is up).
  Completer<MicAccess>? asking;
  int requests = 0;
  int starts = 0;
  int stops = 0;
  int cancels = 0;
  int settings = 0;
  bool listening = false;
  String _heard = '';
  void Function(String text)? _onHeard;
  final StreamController<SpeechProblem> problemController = StreamController.broadcast();

  void say(String words) {
    _heard = words;
    _onHeard?.call(words);
  }

  void answerAccess(MicAccess access) {
    access_ = access;
    asking?.complete(access);
  }

  @override
  Future<MicAccess> access() async => access_;

  @override
  Future<MicAccess> requestAccess() async {
    requests++;
    final asking = this.asking;
    if (asking != null) return asking.future;
    access_ = afterAsking;
    return afterAsking;
  }

  @override
  Future<void> start({required void Function(String text) heard}) async {
    starts++;
    final problem = startProblem;
    if (problem != null) throw problem;
    _heard = '';
    _onHeard = heard;
    listening = true;
  }

  @override
  Future<String?> stop() async {
    stops++;
    listening = false;
    _onHeard = null;
    final words = finalWords ?? _heard;
    return words.isEmpty ? null : words;
  }

  @override
  void cancel() {
    cancels++;
    listening = false;
    _onHeard = null;
  }

  @override
  Stream<SpeechProblem> get problems => problemController.stream;

  @override
  Future<void> openSettings() async => settings++;
}
