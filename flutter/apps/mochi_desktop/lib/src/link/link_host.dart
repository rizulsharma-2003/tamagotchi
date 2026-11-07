// Mochi Link on Windows: the room this PC hosts on the relay (docs/MOCHI_LINK_PLAN.md 4.2), the pairing code a phone
// scans, and who's connected. The Dart counterpart of the Mac's LinkController (Sources/App/Features/Phone).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';

import '../platform/credential_vault.dart';

/// The relay's HTTP calls the host makes. Tests pass a fake.
abstract interface class LinkApi {
  Future<LinkCredentials> createRoom({required String relay, required String platform, required String name});

  /// An invitation into the room, for one [role] if given (`pocket`, `cloud`).
  Future<PairingCode> invite(LinkCredentials credentials, {required String hostName, String? role});

  Future<void> deleteRoom(LinkCredentials credentials);

  /// Joins the room with [code] as a new device (Mochi Cloud joins this way: the host joins for it).
  Future<LinkCredentials> join(PairingCode code, {required String role, required String platform, required String name});

  /// Removes [device] from the room (a host may remove any device).
  Future<void> remove(String device, {required LinkCredentials from});

  /// The room's devices, over HTTPS.
  Future<List<LinkPeer>> devices(LinkCredentials credentials);
}

/// The real relay (mochi_link's [LinkPairing]).
class RelayLinkApi implements LinkApi {
  const RelayLinkApi();

  @override
  Future<LinkCredentials> createRoom({required String relay, required String platform, required String name}) =>
      LinkPairing.createRoom(relay: relay, platform: platform, name: name);

  @override
  Future<PairingCode> invite(LinkCredentials credentials, {required String hostName, String? role}) =>
      LinkPairing.invite(credentials, hostName: hostName, role: role);

  @override
  Future<void> deleteRoom(LinkCredentials credentials) => LinkPairing.deleteRoom(credentials);

  @override
  Future<LinkCredentials> join(PairingCode code, {required String role, required String platform, required String name}) =>
      LinkPairing.join(code, role: role, platform: platform, name: name);

  @override
  Future<void> remove(String device, {required LinkCredentials from}) => LinkPairing.remove(device, from: from);

  @override
  Future<List<LinkPeer>> devices(LinkCredentials credentials) => LinkPairing.devices(credentials);
}

/// Mochi Cloud's place in this PC's room (docs/SPRINT_2.md W5, the Mac's AgentController.copyCloudLinkSettings): the
/// new cloud device's credentials, and the cloud devices it replaced (removed from the room).
class CloudJoin {
  const CloudJoin({required this.credentials, required this.replaced});

  final LinkCredentials credentials;
  final List<String> replaced;

  /// What Mochi Cloud's environment needs (the Mac's `AgentCloud.linkEnvironmentBlock`): the relay, the room, its
  /// device and secret, the room key, and the time zone its briefings go by. It holds a key to the link.
  String environment({required String timeZone}) => [
    'MOCHI_LINK_RELAY=${credentials.relay}',
    'MOCHI_LINK_ROOM=${credentials.room}',
    'MOCHI_LINK_DEVICE=${credentials.device}',
    'MOCHI_LINK_SECRET=${credentials.secret}',
    'MOCHI_LINK_KEY=${credentials.key}',
    'MOCHI_TIMEZONE=$timeZone',
  ].join('\n');
}

typedef LinkConnector = RelayLink Function(LinkCredentials credentials);

class LinkHost extends ChangeNotifier {
  LinkHost({
    required CredentialVault vault,
    required LinkApi api,
    required LinkConnector connect,
    required this.hostName,
    this.relay = defaultRelay,
    this.platform = 'windows',
    this.phonesHintFile,
    DateTime Function()? clock,
    void Function(String message)? log,
  }) : _vault = vault,
       _api = api,
       _connect = connect,
       _clock = clock ?? DateTime.now,
       _log = log;

  /// The relay the Mac uses (Sources/App/Features/Phone/LinkController.swift), protocol v1.
  static const String defaultRelay = 'mochi-link.spike01.workers.dev';

  /// How long an invitation lasts on the relay.
  static const Duration codeLifetime = Duration(minutes: 10);

  final CredentialVault _vault;
  final LinkApi _api;
  final LinkConnector _connect;
  final DateTime Function() _clock;
  final void Function(String message)? _log;

  /// This PC's name, shown to the phones ("Pair with DESKTOP-4K2J9?").
  final String hostName;
  final String relay;

  /// What the relay lists this device as.
  final String platform;

  /// Remembers whether another device has joined this PC's room (not a secret: "1" or "0"), so Settings says
  /// "paired" correctly before the relay has answered, or while offline. Null: kept in memory only.
  final String? phonesHintFile;
  bool? _phonesHint;

  LinkCredentials? _credentials;
  RelayLink? _link;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  PairingCode? _code;
  DateTime? _codeExpires;

  /// The devices already in the room when the code was made: only a new one uses it up. Null until the relay has
  /// said who's in the room (the code was made before the first sync).
  Set<String>? _codeKnownDevices;
  bool _working = false;
  bool _loaded = false;
  String? _problem;
  LinkStatus _status = LinkStatus.offline;
  List<LinkPeer> _peers = const [];

  final StreamController<LinkIncoming> _incoming = StreamController.broadcast(sync: true);
  final StreamController<void> _connected = StreamController.broadcast(sync: true);

  bool get loaded => _loaded;

  /// A phone (or Mochi Cloud) is in this PC's room. The room itself may exist without one: Mochi makes it quietly at
  /// first launch so it can check for updates ([ensureRoom]), and pairing then only invites into it.
  bool get paired {
    if (_credentials == null) return false;
    // The relay's word once it has spoken (it always lists this PC too); until then, what it said last time.
    if (_peers.isNotEmpty) return devices.isNotEmpty;
    return _phonesHint ?? true;
  }

  /// This PC has its room on the relay (with or without phones).
  bool get hasRoom => _credentials != null;
  LinkCredentials? get credentials => _credentials;
  RelayLink? get link => _link;

  /// The current invitation (null when none is showing or it expired).
  PairingCode? get code {
    final expires = _codeExpires;
    if (_code != null && expires != null && !_clock().isBefore(expires)) {
      _code = null;
      _codeExpires = null;
    }
    return _code;
  }

  DateTime? get codeExpires => _codeExpires;
  bool get working => _working;
  String? get problem => _problem;
  LinkStatus get status => _status;

  /// Where the credentials are kept, for Settings.
  String get vaultDescription => _vault.description;

  /// Every device in the room, this PC included.
  List<LinkPeer> get peers => _peers;

  /// The other devices in the room.
  List<LinkPeer> get devices => _peers.where((peer) => peer.device != _credentials?.device).toList();

  /// Values another device put or sent, once each (commands, interactions, verdicts).
  Stream<LinkIncoming> get incoming => _incoming.stream;

  /// Fired each time the socket comes online (republish state then).
  Stream<void> get connected => _connected.stream;

  /// At launch: the saved pairing, if any, and the connection to the relay.
  Future<void> start() async {
    LinkCredentials? saved;
    try {
      saved = await _vault.load();
    } on Object catch (error) {
      _say('the saved pairing could not be read (${error.runtimeType})');
    }
    if (saved != null && saved.roomKey != null && saved.role == 'host') {
      _phonesHint = _readHint();
      _use(saved);
    }
    _loaded = true;
    notifyListeners();
  }

  /// This PC's room, made quietly if it has none yet (or the relay ended the old one): the update check needs the
  /// room's credential even before any phone is paired. Null when the relay can't be reached; nothing is shown.
  Future<LinkCredentials?> ensureRoom() async {
    final current = _credentials;
    if (current != null && _status != LinkStatus.removed) return current;
    try {
      return await _makeRoom();
    } on Object catch (error) {
      _say('the room could not be made (${error.runtimeType})');
      return null;
    }
  }

  Future<LinkCredentials>? _making;

  /// Makes the room and keeps its credential (once, however many ask at the same time).
  Future<LinkCredentials> _makeRoom() => _making ??= () async {
    try {
      if (_credentials != null) await _forget();
      final made = await _api.createRoom(relay: relay, platform: platform, name: hostName);
      try {
        await _vault.save(made);
      } on Object {
        // A room nobody can get back into: delete it again.
        unawaited(_api.deleteRoom(made).catchError((Object _) {}));
        throw const LinkPairingException("Couldn't save the link on this PC.");
      }
      _setHint(false);
      _use(made);
      _say('made the room');
      notifyListeners();
      return made;
    } finally {
      _making = null;
    }
  }();
  /// Shows a fresh pairing code, making the room first if this PC doesn't have one yet.
  Future<void> showCode() async {
    if (_working) return;
    _working = true;
    _problem = null;
    notifyListeners();
    try {
      var credentials = _credentials;
      if (credentials == null || _status == LinkStatus.removed) credentials = await _makeRoom();
      _code = await _api.invite(credentials, hostName: hostName);
      _codeExpires = _clock().add(codeLifetime);
      _codeKnownDevices = _peers.isEmpty ? null : {for (final peer in devices) peer.device};
      _say('made a pairing code');
    } on LinkPairingException catch (error) {
      _problem = error.message;
    } on Object catch (error) {
      _problem = "Couldn't reach Mochi Link (${error.runtimeType}). Check this PC's connection and try again.";
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  void hideCode() {
    if (_code == null) return;
    _code = null;
    _codeExpires = null;
    notifyListeners();
  }

  /// Deletes this PC's room on the relay (every device in it is cut off and has to pair again) and forgets it here.
  Future<void> unpair() async {
    final credentials = _credentials;
    await _forget();
    _problem = null;
    notifyListeners();
    if (credentials != null) {
      try {
        await _api.deleteRoom(credentials);
        _say('deleted the room');
      } on Object catch (error) {
        // The relay deletes rooms nobody touches for 90 days anyway.
        _say('the relay could not be told (${error.runtimeType})');
      }
    }
  }

  /// Asks the relay for the room's device list (the pairing screen).
  void requestDevices() => _link?.requestDevices();

  /// Mochi Cloud's devices in the room, as far as this PC knows.
  List<LinkPeer> get clouds => devices.where((peer) => peer.role == 'cloud').toList();

  /// Mochi Cloud joins this PC's room as its `cloud` device, as the Mac's Copy Cloud Settings does (an invitation for
  /// the cloud role, joined as "Mochi Cloud"), and replaces the one it had: the old cloud devices are removed from the
  /// room once the new one is in (first, if the room is full), so there's only ever one. Throws
  /// [LinkPairingException] when there's no room with a phone in it yet, or the relay says no.
  Future<CloudJoin> joinCloud() async {
    final host = _credentials;
    if (host == null || !paired) {
      throw const LinkPairingException('Pair a phone with this PC first (Settings › Phones): Mochi Cloud joins the same link.');
    }
    List<LinkPeer> listed;
    try {
      listed = await _api.devices(host);
    } on Object {
      // Not over HTTPS: what the socket said last.
      listed = devices;
    }
    final old = [for (final peer in listed) if (peer.role == 'cloud' && peer.device != host.device) peer.device];
    final removed = <String>[];
    Future<LinkCredentials> join() async {
      final code = await _api.invite(host, hostName: hostName, role: 'cloud');
      return _api.join(code, role: 'cloud', platform: 'cloud', name: 'Mochi Cloud');
    }

    LinkCredentials cloud;
    try {
      cloud = await join();
    } on LinkPairingException catch (error) {
      // Eight devices at most: the old Mochi Cloud makes room for the new one.
      if (error.code != 'room_full' || old.isEmpty) rethrow;
      for (final device in old) {
        await _api.remove(device, from: host);
        removed.add(device);
      }
      cloud = await join();
    }
    for (final device in old) {
      if (removed.contains(device) || device == cloud.device) continue;
      try {
        await _api.remove(device, from: host);
        removed.add(device);
      } on LinkPairingException catch (error) {
        // Already gone.
        if (error.status != 404) rethrow;
      }
    }
    _say('Mochi Cloud joined${removed.isEmpty ? '' : ', replacing ${removed.length}'}');
    requestDevices();
    return CloudJoin(credentials: cloud, replaced: removed);
  }

  /// Reconnects now (after the PC wakes up, or the network comes back).
  void reconnectNow() => _link?.reconnectNow();

  /// Replaces state or sends a message to the room (sealed with the room key).
  void set(Object? value, LinkKey key) => _link?.set(value, key);

  /// A sealed notification for every phone in the room.
  void sendAlert(Map<String, Object?> inner, {String? category, String? threadId, int priority = 10}) =>
      _link?.sendAlert(inner, category: category, threadId: threadId, priority: priority);

  /// The latest value of [key] in the room.
  Object? value(LinkKey key) => _link?.value(key);

  Future<void> _forget() async {
    await _disconnect();
    _credentials = null;
    _setHint(null);
    _code = null;
    _codeExpires = null;
    try {
      await _vault.delete();
    } on Object catch (error) {
      _say('the saved pairing could not be removed (${error.runtimeType})');
    }
  }

  void _use(LinkCredentials credentials) {
    _credentials = credentials;
    final link = _connect(credentials);
    _link = link;
    _status = link.status;
    _subscriptions.addAll([
      link.presence.listen(_presenceChanged),
      link.incoming.listen(_incoming.add),
      link.errors.listen((error) => _say('relay refused ${error.key ?? 'a frame'}: ${error.code}')),
    ]);
    link.start();
  }

  Future<void> _disconnect() async {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final link = _link;
    _link = null;
    _status = LinkStatus.offline;
    _peers = const [];
    await link?.dispose();
  }

  void _presenceChanged(LinkPresence presence) {
    final wasOnline = _status == LinkStatus.online;
    final wasPaired = paired;
    _status = presence.status;
    _peers = presence.peers;
    if (_peers.isNotEmpty && devices.isNotEmpty != _phonesHint) _setHint(devices.isNotEmpty);
    // A phone that joined used up the code.
    final known = _codeKnownDevices;
    if (_code != null && known == null) {
      // The first word on who's in the room (a status change alone carries no devices).
      if (_peers.isNotEmpty) _codeKnownDevices = {for (final peer in devices) peer.device};
    } else if (_code != null &&
        known != null &&
        devices.any((peer) => peer.role == 'pocket' && peer.online && !known.contains(peer.device))) {
      _code = null;
      _codeExpires = null;
    }
    // Online again, or the first phone just joined a room that had none: everything is published afresh.
    final joined = paired && !wasPaired && presence.status == LinkStatus.online && wasOnline;
    if ((presence.status == LinkStatus.online && !wasOnline || joined) && !_connected.isClosed) _connected.add(null);
    if (presence.status == LinkStatus.removed) _say('the relay ended this room');
    notifyListeners();
  }

  bool? _readHint() {
    final path = phonesHintFile;
    if (path == null) return _phonesHint;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return file.readAsStringSync().trim() == '1';
    } on FileSystemException {
      return null;
    }
  }

  void _setHint(bool? phones) {
    _phonesHint = phones;
    final path = phonesHintFile;
    if (path == null) return;
    try {
      final file = File(path);
      if (phones == null) {
        if (file.existsSync()) file.deleteSync();
      } else {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(phones ? '1' : '0');
      }
    } on FileSystemException {
      // Only a hint.
    }
  }

  /// Connection events only: never values or secrets.
  void _say(String message) => _log?.call(message);

  @override
  void dispose() {
    unawaited(_disconnect());
    unawaited(_incoming.close());
    unawaited(_connected.close());
    super.dispose();
  }
}
