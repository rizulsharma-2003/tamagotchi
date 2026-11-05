// Mochi Link on Windows: the room this PC hosts on the relay (docs/MOCHI_LINK_PLAN.md 4.2), the pairing code a phone
// scans, and who's connected. The Dart counterpart of the Mac's LinkController (Sources/App/Features/Phone).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';

import '../platform/credential_vault.dart';

/// The relay's HTTP calls the host makes. Tests pass a fake.
abstract interface class LinkApi {
  Future<LinkCredentials> createRoom({required String relay, required String platform, required String name});

  Future<PairingCode> invite(LinkCredentials credentials, {required String hostName});

  Future<void> deleteRoom(LinkCredentials credentials);
}

/// The real relay (mochi_link's [LinkPairing]).
class RelayLinkApi implements LinkApi {
  const RelayLinkApi();

  @override
  Future<LinkCredentials> createRoom({required String relay, required String platform, required String name}) =>
      LinkPairing.createRoom(relay: relay, platform: platform, name: name);

  @override
  Future<PairingCode> invite(LinkCredentials credentials, {required String hostName}) =>
      LinkPairing.invite(credentials, hostName: hostName);

  @override
  Future<void> deleteRoom(LinkCredentials credentials) => LinkPairing.deleteRoom(credentials);
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
  bool get paired => _credentials != null;
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
    if (saved != null && saved.roomKey != null && saved.role == 'host') _use(saved);
    _loaded = true;
    notifyListeners();
  }

  /// Shows a fresh pairing code, making the room first if this PC doesn't have one yet.
  Future<void> showCode() async {
    if (_working) return;
    _working = true;
    _problem = null;
    notifyListeners();
    try {
      var credentials = _credentials;
      if (credentials == null || _status == LinkStatus.removed) {
        if (credentials != null) await _forget();
        final made = await _api.createRoom(relay: relay, platform: platform, name: hostName);
        try {
          await _vault.save(made);
        } on Object {
          // A room nobody can get back into: delete it again.
          unawaited(_api.deleteRoom(made).catchError((Object _) {}));
          throw const LinkPairingException("Couldn't save the link on this PC.");
        }
        _use(made);
        credentials = made;
      }
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
    _status = presence.status;
    _peers = presence.peers;
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
    if (presence.status == LinkStatus.online && !wasOnline && !_connected.isClosed) _connected.add(null);
    if (presence.status == LinkStatus.removed) _say('the relay ended this room');
    notifyListeners();
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
