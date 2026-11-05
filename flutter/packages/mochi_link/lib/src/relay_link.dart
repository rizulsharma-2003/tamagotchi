import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'json.dart';
import 'link_credentials.dart';
import 'link_crypto.dart';
import 'link_envelope.dart';
import 'link_key.dart';
import 'link_pairing.dart';
import 'link_socket.dart';

/// This client's Link protocol version, compared with the relay's `minClientVersion`.
const int linkClientVersion = 1;

enum LinkStatus {
  connecting,
  online,
  offline,

  /// The relay revoked this device (close 4001, HTTP 401) or the room is gone (4004, 404). It won't reconnect:
  /// pair again.
  removed,
}

/// Another device in the room (or this one), merged from the relay's `devices` and `presence` frames.
class LinkPeer {
  const LinkPeer({required this.device, this.role = '', this.name, this.platform, this.app, this.online = false, this.lastSeen});

  final String device;

  /// host · pocket · cloud
  final String role;
  final String? name;
  final String? platform;

  /// The app version it said in its `hello`.
  final String? app;
  final bool online;

  /// Seconds: when it last connected, disconnected or sent something (for an offline host, "asleep since").
  final double? lastSeen;

  LinkPeer _merged(Map<String, Object?> j) => LinkPeer(
    device: device,
    role: jsonString(j['role']) ?? role,
    name: jsonString(j['name']) ?? name,
    platform: jsonString(j['platform']) ?? platform,
    app: jsonString(j['app']) ?? app,
    online: jsonBool(j['online']) ?? online,
    lastSeen: jsonDouble(j['lastSeen']) ?? lastSeen,
  );

  @override
  bool operator ==(Object other) =>
      other is LinkPeer &&
      other.device == device &&
      other.role == role &&
      other.name == name &&
      other.platform == platform &&
      other.app == app &&
      other.online == online &&
      other.lastSeen == lastSeen;

  @override
  int get hashCode => Object.hash(device, role, name, platform, app, online, lastSeen);

  @override
  String toString() => 'LinkPeer($device, $role, ${online ? 'online' : 'offline'}${name == null ? '' : ', $name'})';
}

/// The connection and who's in the room, as of one moment.
class LinkPresence {
  const LinkPresence({required this.status, required this.peers, required this.device});

  final LinkStatus status;

  /// Every device in the room, this one included.
  final List<LinkPeer> peers;

  /// This device's id.
  final String device;

  /// The other devices that are connected right now.
  List<LinkPeer> get onlinePeers => peers.where((peer) => peer.online && peer.device != device).toList();
}

/// A value another device put or sent, opened and checked.
class LinkIncoming {
  const LinkIncoming({required this.key, required this.id, required this.from, required this.isMessage, this.at, this.value});

  final LinkKey key;
  final String id;

  /// The sender's device id (authenticated: it's part of the associated data).
  final String from;

  /// A message (handled once) rather than state.
  final bool isMessage;

  /// The sender's clock, seconds.
  final num? at;

  /// Null when state was cleared.
  final Object? value;
}

/// The relay refused a frame (`error`): role rules, size, rate limits.
class LinkRelayError {
  const LinkRelayError({required this.code, this.message, this.id, this.key});

  final String code;
  final String? message;
  final String? id;
  final String? key;

  @override
  String toString() => 'LinkRelayError($code${key == null ? '' : ' for $key'}: ${message ?? ''})';
}

class _Outgoing {
  const _Outgoing(this.id, this.stateKey, this.frame);

  final String id;

  /// Null for messages.
  final LinkKey? stateKey;
  final String frame;
}

/// Mochi Link over the relay (docs/MOCHI_LINK_PLAN.md 4.4), the Dart twin of Swift `RelayLinkStore`: one WebSocket
/// to the room; every value sealed with the room key before it leaves this device, and opened (and checked against
/// its room, key, id and sender) when it arrives. The relay only routes ciphertext.
///
/// Reads behave like iCloud's: the latest value per key, including this device's own writes. While offline, writes
/// wait in an outbox; frames the relay hasn't acknowledged go again after a reconnect (the relay drops repeats);
/// the socket reconnects with exponential backoff and pings every 25 s.
///
/// ```dart
/// final link = RelayLink(credentials, app: '1.0')..start();
/// link.changes.listen((keys) { if (keys.contains(LinkKey.look)) print(PetLook.fromValue(link.value(LinkKey.look))); });
/// link.set(LinkCommand(id: id, text: 'What's pending?', at: now, typed: true).toValue(), LinkKey.command);
/// ```
class RelayLink {
  /// Throws [ArgumentError] when the credentials' key isn't a 32-byte base64url room key.
  RelayLink(
    this.credentials, {
    String? platform,
    String app = 'dev',
    LinkSocketConnector? connect,
    Duration Function(int attempt)? backoff,
    this.onLog,
  }) : _key = credentials.roomKey ?? (throw ArgumentError.value(credentials, 'credentials', 'The room key must be 32 bytes')),
       platform = platform ?? Platform.operatingSystem,
       app = app.length > 32 ? app.substring(0, 32) : app,
       _connect = connect ?? ((url, headers) => IoLinkSocket.connect(url, headers)),
       _backoff = backoff ?? defaultBackoff;

  final LinkCredentials credentials;

  /// Sent in `hello` (the relay ignores it today; Swift sends `macOS`/`iOS`).
  final String platform;

  /// This app's version, shown in Settings › Devices on the other devices (at most 32 characters).
  final String app;

  /// Diagnostics: connection events and refusals, never values or secrets.
  final void Function(String message)? onLog;

  final Uint8List _key;
  final LinkSocketConnector _connect;
  final Duration Function(int attempt) _backoff;

  final Map<LinkKey, Object> _values = {};

  /// Frames waiting for a connection: messages in order, state only its newest value.
  final List<_Outgoing> _outbox = [];

  /// Frames sent but not yet acknowledged by the relay, oldest first; sent again after a reconnect.
  final LinkedHashMap<String, _Outgoing> _unacked = LinkedHashMap();

  /// Ids already applied (newest last), so a redelivery isn't applied twice.
  final LinkedHashSet<String> _applied = LinkedHashSet();

  LinkSocket? _socket;
  Timer? _retry;
  bool _running = false;
  int _attempt = 0;
  LinkStatus _status = LinkStatus.offline;
  List<LinkPeer> _peers = const [];
  int? _minClientVersion;
  DateTime? _lastSync;

  final StreamController<List<LinkKey>> _changes = StreamController.broadcast();
  final StreamController<LinkPresence> _presence = StreamController.broadcast();
  final StreamController<LinkIncoming> _incoming = StreamController.broadcast();
  final StreamController<LinkRelayError> _errors = StreamController.broadcast();

  static const int _maxOutbox = 64;
  static const int _maxUnacked = 128;
  static const int _maxApplied = 300;

  /// `min(60, 2^min(attempt, 6))` seconds plus up to one second of jitter, as in Swift.
  static Duration defaultBackoff(int attempt) {
    final seconds = min(60, pow(2, min(attempt, 6))) + Random().nextDouble();
    return Duration(milliseconds: (seconds * 1000).round());
  }

  // MARK: State

  LinkStatus get status => _status;

  /// Every device in the room, this one included.
  List<LinkPeer> get peers => _peers;

  /// The other devices that are connected right now.
  List<LinkPeer> get onlinePeers => presenceNow.onlinePeers;

  LinkPresence get presenceNow => LinkPresence(status: _status, peers: _peers, device: credentials.device);

  /// The relay's `minClientVersion` from the last `sync`.
  int? get minClientVersion => _minClientVersion;

  /// The relay wants a newer client: ask the user to update.
  bool get updateRequired => (_minClientVersion ?? 0) > linkClientVersion;

  /// When the last `sync` arrived.
  DateTime? get lastSync => _lastSync;

  /// Keys another device changed (or a `sync` cleared). Not fired for this device's own [set].
  Stream<List<LinkKey>> get changes => _changes.stream;

  /// The connection status or the room's devices changed.
  Stream<LinkPresence> get presence => _presence.stream;

  /// Every value another device put or sent, once each: use this to handle messages, which [value] only keeps the
  /// latest of.
  Stream<LinkIncoming> get incoming => _incoming.stream;

  /// Frames the relay refused.
  Stream<LinkRelayError> get errors => _errors.stream;

  /// The latest value of [key]: JSON-compatible (String, num, bool, `Map<String, dynamic>`, List), in the shapes the
  /// Swift apps write (see the models).
  Object? value(LinkKey key) => _values[key];

  String? string(LinkKey key) => jsonString(_values[key]);

  Map<String, Object?>? map(LinkKey key) => asJsonMap(_values[key]);

  double? number(LinkKey key) => jsonDouble(_values[key]);

  bool get hasAnyValue => _values.isNotEmpty;

  /// Replaces state or sends a message; null clears state. [value] must be JSON-encodable (throws otherwise, before
  /// anything changes).
  void set(Object? value, LinkKey key) {
    final id = newId();
    final frame = RelayLink.frame(value, key, credentials, _key, id: id);
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    _remember(id);
    _send(_Outgoing(id, key.kind == LinkKeyKind.message ? null : key, frame));
  }

  // MARK: Connection

  void start() {
    if (_running && _socket != null) return;
    _running = true;
    _attempt = 0;
    _open();
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    final socket = _socket;
    _socket = null;
    if (_status != LinkStatus.removed) _setStatus(LinkStatus.offline);
    await socket?.close(1000, 'bye');
  }

  /// Asks the relay for the room's device list (Settings › Devices): [peers] and [presence] update when it answers.
  /// The relay sends one by itself only when a device joins or is removed.
  void requestDevices() {
    if (_status == LinkStatus.online) _socket?.send(jsonEncode({'v': 1, 'op': 'devices'}));
  }

  /// Reconnects right away (after waking, or when the network comes back).
  void reconnectNow() {
    if (!_running || _status == LinkStatus.online) return;
    _attempt = 0;
    _open();
  }

  /// Stops and closes the streams.
  Future<void> dispose() async {
    await stop();
    await Future.wait([_changes.close(), _presence.close(), _incoming.close(), _errors.close()]);
  }

  void _open() {
    if (!_running) return;
    _retry?.cancel();
    final url = LinkPairing.url(credentials.relay, '/v1/rooms/${credentials.room}/socket', scheme: 'wss');
    final socket = _connect(url, {'authorization': 'Bearer ${credentials.bearer}'});
    final old = _socket;
    _socket = socket;
    unawaited(old?.close(1000, 'reconnecting'));
    _setStatus(LinkStatus.connecting);
    socket.stream.listen(
      (data) => _received(socket, data),
      onError: (Object error) => _dropped(socket, error),
      onDone: () => _dropped(socket, null),
      cancelOnError: false,
    );
    socket.ready.then((_) => _opened(socket), onError: (Object error) => _dropped(socket, error));
  }

  void _opened(LinkSocket socket) {
    if (!identical(_socket, socket)) return;
    _attempt = 0;
    _setStatus(LinkStatus.online);
    socket.send(jsonEncode({'v': 1, 'op': 'hello', 'platform': platform, 'app': app, 'client': linkClientVersion}));
    // Whatever the relay never confirmed goes again (oldest first), then what waited offline (now awaiting its ack).
    for (final waiting in [..._unacked.values]) {
      socket.send(waiting.frame);
    }
    final outbox = [..._outbox];
    _outbox.clear();
    for (final waiting in outbox) {
      _track(waiting);
      socket.send(waiting.frame);
    }
    _log('connected');
  }

  void _dropped(LinkSocket socket, Object? error) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    final code = socket.closeCode, http = upgradeStatus(error);
    if (code == 4001 || code == 4004 || http == 401 || http == 404) {
      _running = false;
      _retry?.cancel();
      _log('the relay ended this device (${code ?? 'HTTP $http'}): pair again');
      _setStatus(LinkStatus.removed);
      unawaited(socket.close());
      return;
    }
    _setStatus(LinkStatus.offline);
    unawaited(socket.close());
    if (!_running) return;
    _attempt += 1;
    final delay = _backoff(_attempt);
    _log(
      'connection lost (${code != null ? 'closed $code' : (http != null ? 'HTTP $http' : (error == null ? 'ended' : error.runtimeType))}); '
      'retrying in ${delay.inMilliseconds} ms',
    );
    _retry = Timer(delay, _open);
  }

  void _send(_Outgoing outgoing) {
    final socket = _socket;
    if (_status == LinkStatus.online && socket != null) {
      _track(outgoing);
      socket.send(outgoing.frame);
      return;
    }
    final stateKey = outgoing.stateKey;
    if (stateKey != null) _outbox.removeWhere((waiting) => waiting.stateKey == stateKey);
    _outbox.add(outgoing);
    if (_outbox.length > _maxOutbox) _outbox.removeRange(0, _outbox.length - _maxOutbox);
  }

  void _track(_Outgoing outgoing) {
    _unacked[outgoing.id] = outgoing;
    while (_unacked.length > _maxUnacked) {
      _unacked.remove(_unacked.keys.first);
    }
  }

  /// State keys this device has written that the relay hasn't confirmed yet: a `sync` or another device's older
  /// put mustn't overwrite or clear them (the relay processes them after the frames it answered with).
  Set<LinkKey> get _pendingStateKeys => {
    for (final waiting in _outbox) ?waiting.stateKey,
    for (final waiting in _unacked.values) ?waiting.stateKey,
  };

  // MARK: Receiving

  void _received(LinkSocket socket, Object? data) {
    if (!identical(_socket, socket)) return;
    final text = data is String ? data : (data is List<int> ? utf8.decode(data, allowMalformed: true) : null);
    final frame = text == null ? null : asJsonMap(tryJsonDecode(text)); // "pong" and other non-JSON are ignored
    if (frame == null) return;
    switch (frame['op']) {
      case 'put' || 'send':
        _apply(frame, socket);
      case 'sync':
        _sync(frame, socket);
      case 'devices':
        _updatePeers(frame['devices'], names: true);
        _emitPresence();
      case 'presence':
        _updatePeers(frame['presence'], names: false);
        _emitPresence();
      case 'ack':
        // The relay has this frame: it no longer needs sending again.
        final id = jsonString(frame['id']);
        if (id != null) _unacked.remove(id);
      case 'error':
        final error = LinkRelayError(
          code: jsonString(frame['code']) ?? '?',
          message: jsonString(frame['message']),
          id: jsonString(frame['id']),
          key: jsonString(frame['key']),
        );
        _log('relay refused ${error.key ?? 'a frame'}: ${error.code} ${error.message ?? ''}');
        // A refusal is final: don't keep sending it.
        if (error.id != null) _unacked.remove(error.id);
        _errors.add(error);
    }
  }

  /// The room's whole state (a key that's missing was cleared), then what was queued for this device.
  void _sync(Map<String, Object?> frame, LinkSocket socket) {
    final state = _envelopes(frame['state']);
    _clearState(except: {for (final envelope in state) ?LinkKey.tryParse(envelope['key'])});
    for (final envelope in state) {
      _apply(envelope, socket);
    }
    for (final envelope in _envelopes(frame['queue'])) {
      _apply(envelope, socket);
    }
    if (frame['devices'] != null) _updatePeers(frame['devices'], names: true);
    if (frame['presence'] != null) _updatePeers(frame['presence'], names: false);
    _minClientVersion = jsonInt(frame['minClientVersion']) ?? _minClientVersion;
    if (updateRequired) _log('the relay wants Link client version $_minClientVersion; this is $linkClientVersion');
    _lastSync = DateTime.now();
    _emitPresence();
  }

  /// Opens one envelope from another device and makes it the current value of its key.
  void _apply(Map<String, Object?> envelope, LinkSocket socket) {
    final name = jsonString(envelope['key']), id = jsonString(envelope['id']), from = jsonString(envelope['from']);
    if (name == null || id == null || from == null) return;
    final key = LinkKey.tryParse(name);
    final isMessage = envelope['op'] == 'send' || key?.kind == LinkKeyKind.message;
    // Acked on arrival (as in Swift), so one that can't be opened or used isn't delivered again and again.
    if (isMessage) socket.send(jsonEncode({'v': 1, 'op': 'ack', 'id': id}));
    if (key == null || _applied.contains(id)) return;
    _remember(id);
    final nonce = jsonString(envelope['nonce']), box = jsonString(envelope['box']);
    Object? value;
    if (nonce == null || box == null) {
      // A put without a box is the relay clearing the key (it's missing from every later sync too).
      if (isMessage) return;
    } else {
      final ad = LinkCrypto.associatedData(room: credentials.room, key: name, id: id, from: from);
      final plain = LinkCrypto.open(
        LinkSealed(nonce: nonce, box: box),
        ad: ad,
        key: _key,
      );
      final wrapper = plain == null ? null : asJsonMap(tryJsonDecode(utf8.decode(plain, allowMalformed: true)));
      if (wrapper == null) {
        _log("couldn't open a $name from the relay");
        return;
      }
      value = wrapper['v'];
    }
    if (!isMessage && _pendingStateKeys.contains(key)) return;
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    _changes.add([key]);
    _incoming.add(LinkIncoming(key: key, id: id, from: from, isMessage: isMessage, at: jsonDouble(envelope['at']), value: value));
    return;
  }

  void _remember(String id) {
    _applied.add(id);
    while (_applied.length > _maxApplied) {
      _applied.remove(_applied.first);
    }
  }

  /// `devices` frames list everyone with their names; `presence` frames only who's online. Merged by device id.
  void _updatePeers(Object? raw, {required bool names}) {
    final merged = names ? <LinkPeer>[] : [..._peers];
    for (final item in raw is List ? raw : const []) {
      final j = asJsonMap(item);
      final device = j == null ? null : (jsonString(j['id']) ?? jsonString(j['device']));
      if (j == null || device == null) continue;
      final index = merged.indexWhere((peer) => peer.device == device);
      final known = index >= 0 ? merged[index] : _peers.where((peer) => peer.device == device).firstOrNull;
      final peer = (known ?? LinkPeer(device: device))._merged(j);
      if (index >= 0) {
        merged[index] = peer;
      } else {
        merged.add(peer);
      }
    }
    _peers = List.unmodifiable(merged);
  }

  /// After a `sync`: state keys the room no longer has were cleared while this device was away.
  void _clearState({required Set<LinkKey> except}) {
    final waiting = _pendingStateKeys;
    final gone = _values.keys.where((key) => key.kind != LinkKeyKind.message && !except.contains(key) && !waiting.contains(key)).toList();
    if (gone.isEmpty) return;
    gone.forEach(_values.remove);
    _changes.add(gone);
  }

  void _setStatus(LinkStatus status) {
    if (_status == status) return;
    _status = status;
    _emitPresence();
  }

  void _emitPresence() {
    if (!_presence.isClosed) _presence.add(presenceNow);
  }

  void _log(String message) => onLog?.call(message);

  static List<Map<String, Object?>> _envelopes(Object? raw) {
    if (raw is List) return raw.map(asJsonMap).whereType<Map<String, Object?>>().toList();
    if (raw is Map) return raw.values.map(asJsonMap).whereType<Map<String, Object?>>().toList();
    return const [];
  }

  // MARK: Frames

  /// A new message id: a random UUID, lowercased (as Swift `UUID().uuidString.lowercased()`).
  static String newId() {
    final bytes = LinkCrypto.randomBytes(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// A sealed `put` (state, registration) or `send` (message) frame for [value] (null clears a state key): the same
  /// shape as Swift `RelayLinkStore.frame`. The sealed inner JSON is `{"v": value}`; `to` and `ttl` come from
  /// [LinkKey.relayTargets] and [LinkKey.relayTtl]. [nonce] is for tests only.
  static String frame(Object? value, LinkKey key, LinkCredentials credentials, List<int> roomKey, {String? id, num? at, List<int>? nonce}) {
    final frameId = id ?? newId();
    final plain = utf8.encode(jsonEncode({'v': value}));
    final ad = LinkCrypto.associatedData(room: credentials.room, key: key.name, id: frameId, from: credentials.device);
    final sealed = LinkCrypto.seal(plain, ad: ad, key: roomKey, nonce: nonce);
    return LinkEnvelope(
      op: key.kind == LinkKeyKind.message ? LinkOp.send : LinkOp.put,
      key: key.name,
      id: frameId,
      to: key.relayTargets,
      at: (at ?? DateTime.now().millisecondsSinceEpoch / 1000).round(),
      ttl: key.relayTtl,
      nonce: sealed.nonce,
      box: sealed.box,
    ).encode();
  }

  /// Opens a frame made by [frame] as if it came from [from] (Swift `RelayLinkStore.open`). Null when it doesn't
  /// open; otherwise the value, which may itself be null (cleared state).
  static ({Object? value})? open(String frame, LinkCredentials credentials, {required String from, required List<int> roomKey}) {
    final envelope = LinkEnvelope.decode(frame);
    final key = envelope?.key, id = envelope?.id, sealed = envelope?.sealed;
    if (key == null || id == null || sealed == null) return null;
    final ad = LinkCrypto.associatedData(room: credentials.room, key: key, id: id, from: from);
    final plain = LinkCrypto.open(sealed, ad: ad, key: roomKey);
    final wrapper = plain == null ? null : asJsonMap(tryJsonDecode(utf8.decode(plain, allowMalformed: true)));
    return wrapper == null ? null : (value: wrapper['v']);
  }
}
