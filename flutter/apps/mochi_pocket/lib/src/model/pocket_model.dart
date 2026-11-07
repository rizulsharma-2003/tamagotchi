import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';

import '../live/live_push.dart';
import '../live/live_updates.dart';
import '../services/alert_notifier.dart';
import '../services/credential_store.dart';
import '../services/local_file.dart';
import '../services/notify/action_outbox.dart';
import '../services/notify/notification_plan.dart';
import '../services/push/push_messages.dart';
import '../services/push/push_service.dart';
import '../services/push/shown_alerts.dart';
import 'done_marks.dart';
import 'updates_history.dart';

enum ExchangeState { sending, working, done, failed }

/// Whether Mochi's alerts can reach this phone while the app is closed.
enum PushStatus {
  /// Not paired: nothing to receive.
  off,

  /// Getting a push address.
  starting,

  /// The relay has this phone's FCM address.
  registered,

  /// Push doesn't work here ([PocketModel.pushProblem] says why); alerts arrive only while the app runs.
  unavailable,
}

/// Something you asked your Mac, and how it's going (Swift `MacLink.Exchange`).
class Exchange {
  Exchange({required this.id, required this.text, this.project, this.state = ExchangeState.sending, this.reply, required this.sentAt});

  final String id;
  final String text;

  /// The Claude session it was for, when it was a reply to one.
  final String? project;
  ExchangeState state;
  String? reply;
  final DateTime sentAt;
}

/// Moments the room reacts to: a pet, play or treat (from here or the Mac), and how a request is going.
enum PetCue { pet, play, treat, sending, working, replied, failed }

enum PairingPhase { loading, unpaired, paired }

/// How this phone is connected, for the header pill and Settings.
enum MacConnection { macOnline, macAway, connecting, noConnection, removed }

typedef LinkConnector = RelayLink Function(LinkCredentials credentials);
typedef LinkJoiner = Future<LinkCredentials> Function(PairingCode code, String deviceName);
typedef LinkLeaver = Future<void> Function(LinkCredentials credentials);

/// Mochi for Android's state: pairing (Swift `PocketLink`), what the Mac shares and what you send it (`MacLink`,
/// `PhoneWorld`'s look and interactions), and your done marks and the week of updates (`UpdatesStore`), all over one
/// [RelayLink].
class PocketModel extends ChangeNotifier {
  PocketModel({
    required CredentialStore credentialStore,
    required LocalDocument doneDocument,
    required AlertNotifier notifier,
    required LinkConnector connect,
    LinkJoiner? join,
    LinkLeaver? leave,
    PushService? push,
    ShownAlerts? shown,
    LiveUpdates? live,
    LocalDocument? hostDocument,
    LocalDocument? historyDocument,
    LocalDocument? outboxDocument,
    this.deviceName = 'Android phone',
    DateTime Function()? clock,
  }) : _push = push,
       _live = live,
       _shown = shown ?? MemoryShownAlerts(),
       _store = credentialStore,
       _doneDocument = doneDocument,
       _hostDocument = hostDocument ?? MemoryDocument(),
       _historyDocument = historyDocument ?? MemoryDocument(),
       _outboxDocument = outboxDocument ?? MemoryDocument(),
       _notifier = notifier,
       _connect = connect,
       _join = join ?? _relayJoin,
       _leave = leave ?? _relayLeave,
       _clock = clock ?? DateTime.now;

  final PushService? _push;

  /// Mochi on the lock screen while Claude works: the computer's Live Activity updates, by push and on the socket.
  final LiveUpdates? _live;

  /// Alerts already shown, shared with the push handler: each alert shows once, however it arrives.
  final ShownAlerts _shown;
  final CredentialStore _store;
  final LocalDocument _doneDocument;

  /// The platform of the computer last seen in this phone's room (`{"room", "platform"}`), so its name doesn't
  /// change while the relay's device list loads.
  final LocalDocument _hostDocument;

  /// The week of "Waiting for you" (`updates.json`).
  final LocalDocument _historyDocument;

  /// What notification buttons pressed while the app was closed left for it.
  final LocalDocument _outboxDocument;
  final AlertNotifier _notifier;
  final LinkConnector _connect;
  final LinkJoiner _join;
  final LinkLeaver _leave;
  final DateTime Function() _clock;

  /// How the Mac lists this phone ("realme RMX3242").
  final String deviceName;

  static Future<LinkCredentials> _relayJoin(PairingCode code, String name) =>
      LinkPairing.join(code, role: 'pocket', platform: 'android', name: name);

  static Future<void> _relayLeave(LinkCredentials credentials) => LinkPairing.remove(credentials.device, from: credentials);

  // MARK: State

  PairingPhase _phase = PairingPhase.loading;
  LinkCredentials? _credentials;
  RelayLink? _link;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  bool _pairing = false;
  String? _pairingWith;
  String? _problem;

  LinkStatus _status = LinkStatus.offline;
  List<LinkPeer> _peers = const [];
  LinkPlatform? _knownHostPlatform;

  PetLook? _look;
  ClaudeMirror? _claude;
  PhoneSessions? _sessions;
  AgentPending? _agent;
  ApprovalRequest? _approval;
  final Set<String> _answered = {};
  final List<Exchange> _exchanges = [];
  final Set<String> _seenInteractions = {};
  DoneMarks _done = DoneMarks();
  UpdatesHistory _history = UpdatesHistory();
  final Completer<void> _loaded = Completer();
  DateTime? _lastAlertAt;
  PushStatus _pushStatus = PushStatus.off;
  String? _pushProblem;
  String? _registerId;

  /// The address last registered, and on which link: Firebase also announces a new install's first address through
  /// onTokenRefresh, which needn't go twice.
  (RelayLink, String)? _registered;
  final List<StreamSubscription<Object?>> _pushSubscriptions = [];

  final StreamController<PetCue> _cues = StreamController.broadcast();

  PairingPhase get phase => _phase;
  bool get paired => _phase == PairingPhase.paired;
  LinkCredentials? get credentials => _credentials;

  /// Joining a room right now, and whose ([pairingWith]).
  bool get pairing => _pairing;
  String? get pairingWith => _pairingWith;

  /// Why the last pairing didn't work.
  String? get problem => _problem;

  LinkStatus get status => _status;
  List<LinkPeer> get peers => _peers;

  /// The computer this phone talks to, named for the screens: "your Mac", "your PC", "BELPL-LT-636 (Mac)". Until the
  /// relay lists the room, the name from the pairing code and the platform last seen here.
  LinkHostName get host =>
      LinkPeerNames.host(_peers, me: _credentials?.device, pairedName: _credentials?.peerName, knownPlatform: _knownHostPlatform);

  /// Every computer in the room, labeled: "BELPL-LT-636 (Mac)", or two joined with "and".
  String get hostList =>
      LinkPeerNames.hostList(_peers, me: _credentials?.device, pairedName: _credentials?.peerName, knownPlatform: _knownHostPlatform);

  /// The computer in the room (an online one first, then the one seen last).
  LinkPeer? get mac => LinkPeerNames.hosts(_peers, me: _credentials?.device).firstOrNull;

  bool get macOnline => _status == LinkStatus.online && (mac?.online ?? false);

  MacConnection get connection => switch (_status) {
    LinkStatus.removed => MacConnection.removed,
    LinkStatus.online => macOnline ? MacConnection.macOnline : MacConnection.macAway,
    LinkStatus.connecting => MacConnection.connecting,
    LinkStatus.offline => MacConnection.noConnection,
  };

  /// The relay wants a newer app.
  bool get updateRequired => _link?.updateRequired ?? false;

  PetLook? get look => _look;
  String get petName => _look?.petName ?? 'Mochi';
  String get companionName => _look?.companionName ?? 'Patch';
  int get friendshipLevel => _look?.friendshipLevel ?? 0;
  ClaudeMirror? get claude => _claude;

  /// Claude's sessions on the Mac, when it shares summaries (at most six, as on the iPhone).
  List<PhoneSessionCard> get sessions => (_sessions?.enabled ?? false) ? _sessions!.sessions.take(6).toList() : const [];

  /// Null until the Mac has said whether it shares summaries.
  bool? get summariesShared => _sessions?.enabled;
  AgentPending? get agent => _agent;
  ApprovalRequest? get approval => _approval;

  /// Oldest first; at most six.
  List<Exchange> get exchanges => List.unmodifiable(_exchanges);
  DateTime? get lastAlertAt => _lastAlertAt;
  PushStatus get pushStatus => _pushStatus;

  /// Why push doesn't work, when [pushStatus] is [PushStatus.unavailable].
  String? get pushProblem => _pushProblem;

  /// The room's reactions, as they happen.
  Stream<PetCue> get cues => _cues.stream;

  bool isDone(String id) => _done.isDone(id);

  /// When [id] was marked done (Unix time), if it is.
  double? doneAt(String id) => _done.doneAt(id);

  /// Where [id] was marked done, for the history: "here", "on your Mac", "on iPhone"; null when not known.
  String? doneWhere(String id) {
    final by = _done.doneBy(id);
    if (by == null) return null;
    if (by == DoneMarks.here || by == _credentials?.device) return 'here';
    if (by == DoneMarks.computer) return 'on ${host.yours}';
    final peer = _peers.where((peer) => peer.device == by).firstOrNull;
    if (peer == null) return 'on your other phone';
    final name = peer.name?.trim();
    return 'on ${name == null || name.isEmpty ? LinkPeerNames.label(peer) : name}';
  }

  /// The agent's items you haven't marked done.
  List<AgentNote> get waiting => (_agent?.items ?? const <AgentNote>[]).where((note) => !_done.isDone(note.id)).toList();

  /// Every update of the last week on this phone, newest first.
  UpdatesHistory get history => _history;

  /// The earlier updates by day, leaving out what's waiting now (the Updates screen, under "Waiting for you").
  List<HistoryDay> get historyDays => _history.days(excluding: {for (final note in waiting) note.id});

  /// Completes once [load] has read the saved pairing.
  Future<void> get loaded => _loaded.future;

  double get _now => _clock().millisecondsSinceEpoch / 1000;

  // MARK: Pairing

  /// At launch: the saved pairing, if there is one, and the link to the relay.
  Future<void> load() async {
    LinkCredentials? saved;
    final watch = Stopwatch()..start();
    try {
      saved = await _store.load();
    } on Object catch (error) {
      _log('the saved pairing could not be read (${error.runtimeType})');
    }
    _done = DoneMarks.fromJson(await _doneDocument.read())..prune(now: _now);
    _history = UpdatesHistory.fromJson(await _readSafely(_historyDocument))..prune(now: _now);
    _knownHostPlatform = await _savedHostPlatform(saved?.room);
    _log('loaded ${saved == null ? 'no pairing' : 'the pairing'} in ${watch.elapsedMilliseconds} ms');
    if (saved != null && saved.roomKey != null) {
      _use(saved);
      _phase = PairingPhase.paired;
      unawaited(_startPush());
      await _takeOutbox();
    } else {
      _phase = PairingPhase.unpaired;
    }
    if (!_loaded.isCompleted) _loaded.complete();
    notifyListeners();
  }

  /// Joins the room in a `mochi://pair?…` link (scanned, pasted or opened). True when this phone is paired with it.
  Future<bool> pair(String text) async {
    final code = PairingCode.parse(text);
    if (text.trim().isEmpty) {
      _problem = 'Nothing to paste. Copy the pairing link on your Mac or PC first, or scan its code.';
      notifyListeners();
      return false;
    }
    if (code == null) {
      _problem = "That isn't a Mochi pairing link. On your Mac or PC: open Mochi's Settings › Phones › Pair a Phone.";
      notifyListeners();
      return false;
    }
    if (_pairing) return false;
    // Opened again with the code this phone already used (Android redelivers the link after a restart).
    if (_credentials?.room == code.room && _status != LinkStatus.removed) return true;
    _pairing = true;
    _pairingWith = code.name;
    _problem = null;
    notifyListeners();
    try {
      final joined = await _join(code, deviceName);
      await _store.save(joined);
      await _disconnect();
      _clearRoom();
      _knownHostPlatform = await _savedHostPlatform(joined.room);
      _use(joined);
      _phase = PairingPhase.paired;
      _log('paired with ${code.name}');
      unawaited(_startPush());
      return true;
    } on LinkPairingException catch (error) {
      _problem = _explain(error);
      return false;
    } on Object catch (error) {
      _problem = "Couldn't pair (${error.runtimeType}). Check the phone's connection and try again.";
      return false;
    } finally {
      _pairing = false;
      notifyListeners();
    }
  }

  static String _explain(LinkPairingException error) => switch (error.code) {
    'invite_used' => 'That code was already used. On your Mac or PC, make a new one (Pair a Phone…) and scan it again.',
    'invite_expired' ||
    'invite_not_found' ||
    'invite_invalid' => 'That code has expired (they last 10 minutes). On your Mac or PC, make a new one and scan it again.',
    'room_full' => 'That room is full (8 devices). Remove one on your Mac or PC first.',
    _ => error.message,
  };

  void clearProblem() {
    if (_problem == null) return;
    _problem = null;
    notifyListeners();
  }

  /// Forgets the pairing: this phone leaves the room (when the relay can still be told) and starts clean.
  Future<void> unpair() async {
    final credentials = _credentials;
    final stillInRoom = _status != LinkStatus.removed;
    await _disconnect();
    _credentials = null;
    _clearRoom();
    _done = DoneMarks();
    _history = UpdatesHistory();
    _knownHostPlatform = null;
    _phase = PairingPhase.unpaired;
    _problem = null;
    notifyListeners();
    try {
      await _store.delete();
      await _doneDocument.delete();
      await _hostDocument.delete();
      await _historyDocument.delete();
      await _outboxDocument.delete();
    } on Object catch (error) {
      _log('unpairing could not clear everything (${error.runtimeType})');
    }
    if (credentials != null && stillInRoom) {
      unawaited(_leave(credentials).catchError((Object error) => _log('the relay was not told (${error.runtimeType})')));
    }
    // Nothing from that room stays on the lock screen.
    unawaited(_live?.forget().catchError((Object error) => _log('the live update was not cleared (${error.runtimeType})')));
    // A stale push address must not receive pushes for a room this phone left: Firebase forgets it.
    _pushStatus = PushStatus.off;
    _pushProblem = null;
    _registerId = null;
    _registered = null;
    final push = _push;
    if (push != null) {
      unawaited(push.deleteToken().catchError((Object error) => _log('the push address was not deleted (${error.runtimeType})')));
    }
  }

  // MARK: Push

  /// Gets push going (once per launch), then tells the relay this phone's FCM address: at launch, after pairing, and
  /// whenever Firebase rotates it.
  Future<void> _startPush() async {
    final push = _push;
    if (push == null) {
      _setPush(PushStatus.unavailable, 'push is not part of this build');
      return;
    }
    _setPush(PushStatus.starting, null);
    final problem = await push.start();
    if (problem != null) {
      _setPush(PushStatus.unavailable, problem);
      return;
    }
    if (_pushSubscriptions.isEmpty) {
      _pushSubscriptions.addAll([push.tokenRefresh.listen(_registerPush), push.messages.listen(_pushed)]);
    }
    try {
      final token = await push.token();
      if (token == null || token.isEmpty) {
        _setPush(PushStatus.unavailable, "Firebase hasn't given this phone a push address yet");
      } else {
        _registerPush(token);
      }
    } on PushException catch (error) {
      _setPush(PushStatus.unavailable, error.reason);
    } on Object catch (error) {
      _log('no push address (${error.runtimeType})');
      _setPush(PushStatus.unavailable, "Firebase couldn't give this phone a push address");
    }
  }

  /// Sends `register {tokens: {fcm}}` (the address itself is never logged).
  void _registerPush(String token) {
    final link = _link;
    if (link == null || token.isEmpty) return;
    final last = _registered;
    if (last != null && identical(last.$1, link) && last.$2 == token) return;
    _registered = (link, token);
    _registerId = link.register({'fcm': token});
    _log('register frame for push ${link.status == LinkStatus.online ? 'sent' : 'queued until connected'}');
    _setPush(PushStatus.registered, null);
  }

  /// A push that arrived while the app is open (the background isolate handles the rest).
  Future<void> _pushed(Map<String, Object?> data) async {
    if (LivePush.isLiveActivity(data)) {
      final live = _live;
      if (live == null) return;
      final outcome = await LivePush.handle(data, credentials: () async => _credentials, live: live, host: (_) => host);
      _log('live activity push while open: ${outcome?.name ?? 'ignored'}');
      return;
    }
    final outcome = await PushMessages.handle(
      data,
      credentials: () async => _credentials,
      notifier: _notifier,
      shown: _shown,
      isDone: _done.isDone,
      record: (notes) async => _record(notes),
    );
    if (outcome == PushOutcome.shown || outcome == PushOutcome.fallback) _lastAlertAt = _clock();
    _log('push while open: ${outcome.name}');
  }

  void _setPush(PushStatus status, String? problem) {
    if (_pushStatus == status && _pushProblem == problem) return;
    _pushStatus = status;
    _pushProblem = problem;
    notifyListeners();
  }

  // MARK: The link

  void _use(LinkCredentials credentials) {
    _credentials = credentials;
    final link = _connect(credentials);
    _link = link;
    _status = link.status;
    _subscriptions.addAll([
      link.changes.listen((_) => _read()),
      link.incoming.listen(_received),
      link.presence.listen(_presenceChanged),
      link.alerts.listen(_alerted),
      link.liveActivities.listen(_liveActivity),
      link.errors.listen(_refused),
    ]);
    link.start();
    _read();
  }

  Future<void> _disconnect() async {
    // Cancelling a broadcast subscription takes effect at once; nothing to wait for.
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

  void _clearRoom() {
    _look = null;
    _claude = null;
    _sessions = null;
    _agent = null;
    _approval = null;
    _answered.clear();
    _exchanges.clear();
    _seenInteractions.clear();
  }

  /// Back in the foreground: reconnect right away if the socket went while the app was away, and take in what the
  /// background handlers wrote meanwhile (news cards for the history, notification buttons).
  void resume() {
    _link?.reconnectNow();
    unawaited(_catchUp());
  }

  Future<void> _catchUp() async {
    if (!paired) return;
    final saved = UpdatesHistory.fromJson(await _readSafely(_historyDocument));
    if (_history.merge(saved, now: _now)) notifyListeners();
    await _takeOutbox();
  }

  void _presenceChanged(LinkPresence presence) {
    _status = presence.status;
    _peers = presence.peers;
    if (presence.status == LinkStatus.removed) _log('the relay ended this pairing');
    _rememberHostPlatform();
    notifyListeners();
  }

  /// The host platform saved for [room], if this phone has seen one there.
  Future<LinkPlatform?> _savedHostPlatform(String? room) async {
    if (room == null) return null;
    try {
      final json = await _hostDocument.read();
      return json?['room'] == room ? LinkPlatform.parse(json?['platform'] as String?) : null;
    } on Object {
      return null;
    }
  }

  void _rememberHostPlatform() {
    final room = _credentials?.room;
    final platform = LinkPeerNames.hosts(_peers, me: _credentials?.device).map((peer) => peer.linkPlatform).nonNulls.firstOrNull;
    if (room == null || platform == null || platform == _knownHostPlatform) return;
    _knownHostPlatform = platform;
    unawaited(
      _hostDocument
          .write({'room': room, 'platform': platform.name})
          .catchError((Object error) => _log('the host platform was not saved (${error.runtimeType})')),
    );
  }

  /// Reads every state value the Mac shares.
  void _read() {
    final link = _link;
    if (link == null) return;
    _look = PetLook.fromValue(link.value(LinkKey.look)) ?? _look;
    _claude = ClaudeMirror.fromValue(link.value(LinkKey.claude));
    final sessions = PhoneSessions.fromValue(link.value(LinkKey.sessions));
    if (sessions != null) _sessions = sessions;
    final agent = AgentPending.fromValue(link.value(LinkKey.agent));
    if (agent != null) {
      _agent = agent;
      if (agent.enabled) _record(agent.items);
    }
    final request = ApprovalRequest.fromValue(link.value(LinkKey.approval));
    if (request != null && !_answered.contains(request.id) && _now - request.at < 120) {
      _approval = request;
    } else if (_approval != null && request?.id != _approval!.id) {
      _approval = null;
    }
    notifyListeners();
  }

  void _received(LinkIncoming message) {
    switch (message.key) {
      // Done marks from the computer and the other phones, each kept with where it was made (for the history).
      case LinkKey.macDone || LinkKey.phoneDone:
        final list = AgentDoneList.fromValue(message.value);
        if (list == null) return;
        final from = message.key == LinkKey.macDone
            ? DoneMarks.computer
            : (message.from == _credentials?.device ? DoneMarks.here : message.from);
        if (_done.takeIn(list, now: _now, from: from)) {
          unawaited(_saveDone());
          notifyListeners();
        }
      case LinkKey.reply:
        final reply = LinkReply.fromValue(message.value);
        final exchange = reply == null ? null : _exchanges.where((exchange) => exchange.id == reply.id).firstOrNull;
        if (reply == null || exchange == null) return;
        _log('reply ${reply.state} ${_clock().difference(exchange.sentAt).inMilliseconds} ms after sending');
        switch (reply.state) {
          case 'working':
            if (exchange.state == ExchangeState.sending) exchange.state = ExchangeState.working;
            _cue(PetCue.working);
          case 'done':
            exchange.state = ExchangeState.done;
            _cue(PetCue.replied);
          case 'failed':
            exchange.state = ExchangeState.failed;
            _cue(PetCue.failed);
        }
        final text = reply.text;
        if (text != null && text.isNotEmpty) exchange.reply = text;
        notifyListeners();
      case LinkKey.activityEnded:
        final ended = ActivityEnded.fromValue(message.value);
        final live = _live;
        if (ended == null || live == null) return;
        unawaited(
          live.macEnded(ended).then((outcome) => _log('the computer ended its live activity: ${outcome?.name ?? 'nothing showing'}')),
        );
      case LinkKey.macInteraction:
        final interaction = LinkInteraction.fromValue(message.value);
        if (interaction == null || !_seenInteractions.add(interaction.id) || _now - interaction.at >= 90) return;
        final cue = switch (interaction.kind) {
          'pet' => PetCue.pet,
          'play' => PetCue.play,
          'treat' => PetCue.treat,
          _ => null,
        };
        if (cue != null) _cue(cue);
      default:
        break;
    }
  }

  /// The relay turned a frame down (rate limit, size, role rules). A refused command says so in Recently instead of
  /// waiting forever; other refusals are only logged.
  void _refused(LinkRelayError error) {
    _log('relay refused ${error.key ?? 'a frame'}: ${error.code}');
    if (error.id != null && error.id == _registerId) {
      _setPush(PushStatus.unavailable, "the relay didn't take this phone's push address (${error.code})");
      return;
    }
    if (error.key != LinkKey.command.name) return;
    final exchange = _exchanges.where((exchange) => exchange.state == ExchangeState.sending).lastOrNull;
    if (exchange == null) return;
    exchange
      ..state = ExchangeState.failed
      ..reply = error.code == 'rate_limited'
          ? 'Too many messages at once. Wait a moment and send it again.'
          : "Mochi Link didn't accept this (${error.code}). Send it again in a moment.";
    _cue(PetCue.failed);
    notifyListeners();
  }

  /// An alert over the relay socket. The same alert also comes as an FCM push: whichever arrives first is shown.
  Future<void> _alerted(LinkAlert alert) async {
    if (!await _shown.claim(alert.id)) return;
    _lastAlertAt = _clock();
    await _notifier.show(
      alert,
      plan: NotificationPlan.forAlert(alert, room: _credentials?.room, isDone: _done.isDone),
    );
    final card = AgentPending.fromJson(alert.userInfo['pending']);
    if (card != null && card.enabled) _record(card.items);
  }

  /// A Live Activity update on the socket (relay 1.4.0 hands them to Android phones as well as pushing them): the same
  /// update by push is dropped as a repeat.
  Future<void> _liveActivity(LinkLiveActivity activity) async {
    final outcome = await _live?.handle(activity, host: host);
    _log('live activity on the socket: ${outcome?.name ?? 'no live updates here'}');
  }

  // MARK: The week of updates

  /// A card's items join the history (new ones) or bring their latest words (known ones).
  void _record(List<AgentNote> notes) {
    if (_history.record(notes, now: _now)) unawaited(_saveHistory());
  }

  /// Read, merged and written back: the push handler may have added to the file while the app ran.
  Future<void> _saveHistory() async {
    try {
      _history.merge(UpdatesHistory.fromJson(await _historyDocument.read()), now: _now);
      await _historyDocument.write(_history.toJson());
    } on Object catch (error) {
      _log('the updates history could not be saved (${error.runtimeType})');
    }
  }

  // MARK: Notification buttons

  /// What buttons pressed while the app was closed left: replies the relay took (so Recently shows them and the
  /// computer's answer lands), replies it couldn't take (sent now, if they're under ten minutes old), and done marks.
  Future<void> _takeOutbox() async {
    NotificationOutbox? outbox;
    try {
      outbox = await NotificationOutbox.take(_outboxDocument);
    } on Object catch (error) {
      _log('the notification outbox could not be read (${error.runtimeType})');
    }
    if (outbox == null) return;
    if (outbox.doneChanged) {
      final saved = DoneMarks.fromJson(await _readSafely(_doneDocument));
      saved.done.forEach((id, at) => _done.done.putIfAbsent(id, () => at));
      saved.takenIn.forEach((id, at) => _done.takenIn.putIfAbsent(id, () => at));
      saved.by.forEach((id, by) => _done.by.putIfAbsent(id, () => by));
    }
    for (final command in outbox.sent) {
      _addExchange(command);
    }
    for (final command in outbox.queued) {
      if (_now - command.at < NotificationOutbox.replyLifetime) {
        queueReply(command);
      } else {
        _addExchange(command)
          ..state = ExchangeState.failed
          ..reply = 'Not sent: there was no connection when you replied from the notification. Send it again.';
      }
    }
    if (outbox.shareDone || outbox.doneChanged) {
      _shareDone();
    } else {
      notifyListeners();
    }
  }

  /// A reply from a notification that the relay already has: Recently shows it, and the computer's answer finds it.
  void addSentReply(LinkCommand command) {
    _addExchange(command);
    _cue(PetCue.sending);
    notifyListeners();
  }

  /// A reply from a notification that couldn't go straight away: it waits in the link's outbox like a typed one.
  void queueReply(LinkCommand command) {
    _addExchange(command);
    _link?.set(command.toValue(), LinkKey.command);
    notifyListeners();
  }

  Exchange _addExchange(LinkCommand command) {
    final known = _exchanges.where((exchange) => exchange.id == command.id).firstOrNull;
    if (known != null) return known;
    final exchange = Exchange(
      id: command.id,
      text: command.text,
      project: command.project,
      sentAt: DateTime.fromMillisecondsSinceEpoch((command.at * 1000).round()),
    );
    _exchanges.add(exchange);
    if (_exchanges.length > 6) _exchanges.removeRange(0, _exchanges.length - 6);
    return exchange;
  }

  /// Marks [ids] done here (from a notification) without sending: returns the list this phone shares, for the
  /// caller to deliver.
  AgentDoneList markDoneHere(List<String> ids) {
    if (_done.mark(ids, now: _now)) {
      unawaited(_saveDone());
      notifyListeners();
    }
    return _done.shared(now: _now);
  }

  /// Shares this phone's done list through the link (now, or when it reconnects).
  void shareDone() => _shareDone();

  static Future<Map<String, Object?>?> _readSafely(LocalDocument document) async {
    try {
      return await document.read();
    } on Object {
      return null;
    }
  }

  // MARK: Things you do

  /// Pet, play or treat here; Mochi on the Mac does the same a moment later.
  void interact(String kind) {
    final link = _link;
    final cue = switch (kind) {
      'pet' => PetCue.pet,
      'play' => PetCue.play,
      _ => PetCue.treat,
    };
    _cue(cue);
    if (link == null) return;
    final id = RelayLink.newId();
    _seenInteractions.add(id);
    link.set(LinkInteraction(id: id, kind: kind, at: _now).toValue(), LinkKey.phoneInteraction);
  }

  /// Sends a typed request to the Mac: for Mochi, or (with [project] and [session]) for that Claude session. The id,
  /// or null when there's nothing to send. While the Mac is away it waits on the relay for 10 minutes.
  String? send(String text, {String? project, String? session}) {
    final words = text.trim();
    final link = _link;
    if (words.isEmpty || link == null) return null;
    final id = RelayLink.newId();
    _exchanges.add(Exchange(id: id, text: words, project: project, sentAt: _clock()));
    if (_exchanges.length > 6) _exchanges.removeRange(0, _exchanges.length - 6);
    link.set(LinkCommand(id: id, text: words, at: _now, typed: true, project: project, session: session).toValue(), LinkKey.command);
    _cue(PetCue.sending);
    notifyListeners();
    return id;
  }

  /// Answers the Mac's "Send to Claude?".
  void answer(ApprovalRequest request, {required bool allow}) {
    _answered.add(request.id);
    if (_approval?.id == request.id) _approval = null;
    _link?.set(LinkVerdict(id: request.id, allow: allow, at: _now).toValue(), LinkKey.verdict);
    notifyListeners();
  }

  /// Marks items done here, on the Mac and on your other phones.
  void markDone(Iterable<String> ids) {
    _done.mark(ids, now: _now);
    _shareDone();
  }

  /// Puts an item back in "Waiting for you".
  void markNotDone(String id) {
    _done.unmark(id);
    _shareDone();
  }

  void _shareDone() {
    _link?.set(_done.shared(now: _now).toValue(), LinkKey.phoneDone);
    unawaited(_saveDone());
    notifyListeners();
  }

  Future<void> _saveDone() async {
    try {
      await _doneDocument.write(_done.toJson());
    } on Object catch (error) {
      _log('done marks could not be saved (${error.runtimeType})');
    }
  }

  void _cue(PetCue cue) {
    if (!_cues.isClosed) _cues.add(cue);
  }

  /// Development builds only, and never values or secrets.
  void _log(String message) {
    if (kDebugMode) debugPrint('Mochi: $message');
  }

  @override
  void dispose() {
    for (final subscription in _pushSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_disconnect());
    unawaited(_cues.close());
    super.dispose();
  }
}
