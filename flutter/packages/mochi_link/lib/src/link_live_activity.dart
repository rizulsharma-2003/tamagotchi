import 'dart:convert';

import 'json.dart';
import 'link_crypto.dart';

/// Mochi's Live Activity (docs/MOCHI_LINK_PLAN.md 4.6.1): what Claude is doing on the computer, for the phone's Lock
/// Screen. The iPhone shows it as a Live Activity (`MochiActivityAttributes`); Android as an ongoing notification.
///
/// The host sends a `liveActivity` message with a clear `apns` object, the ActivityKit payload (Swift
/// `LiveActivityPayload` turned by `LinkPush.liveActivity`): `event`, `timestamp`, `content-state` (`phase`, `since`,
/// `frame`, a placeholder `title` and `sealed`), and `attributes`, `dismissal-date` and `alert` when they apply. The
/// title and detail are sealed with K_la ([LinkCrypto.liveActivityKey]) in `content-state.sealed` = "nonce.box", with
/// the associated data [associatedData] (`link-spec/live-activity.json`). The relay (1.4.0) pushes it to an Android
/// phone as an FCM data message ([fromPushData]) and hands it to an Android phone's open socket as it is
/// ([RelayLink.liveActivities]).
class LinkLiveActivity {
  const LinkLiveActivity({
    this.id = '',
    this.from,
    this.room,
    required this.event,
    required this.timestamp,
    required this.phase,
    required this.title,
    this.detail,
    this.opened = true,
    required this.since,
    this.frame,
    this.dismissalDate,
    this.staleDate,
    this.alert = false,
    this.sound = false,
    this.petName,
    this.companionName,
  });

  /// The message key on the wire. Not a [LinkKey]: never state, never queued.
  static const String key = 'liveActivity';

  /// Swift `LinkPush.liveActivityAD`.
  static const String associatedData = 'mochi-link/v1|live-activity|detail';

  /// The phases the iPhone has art for (`MochiActivityAttributes.ContentState.phases`).
  static const Set<String> phases = {'working', 'waiting', 'done', 'idle', 'error', 'asleep'};

  /// The message id ('' when it isn't known): a second copy (socket and push) has the same one.
  final String id;

  /// The host that sent it (set by the relay).
  final String? from;
  final String? room;

  /// start · update · end
  final String event;

  /// The host's clock, seconds; every update is newer than the last (Swift `nextTimestamp`), so an older or equal one
  /// is a repeat or arrived out of order.
  final int timestamp;

  /// working · waiting · done · idle · error · asleep
  final String phase;

  /// "Claude is working", out of `sealed`; the placeholder (the pet's name) when it couldn't be opened.
  final String title;

  /// The project and tool count, when the Mac shares them.
  final String? detail;

  /// The title and detail are the real ones: `sealed` opened, or there was nothing sealed.
  final bool opened;

  /// Unix time the turn or wait began: the elapsed timer counts from it.
  final double since;

  /// Which of the phase's ten poses to show (each update moves it on).
  final int? frame;

  /// `end` only: when it leaves the Lock Screen (Unix time).
  final double? dismissalDate;
  final double? staleDate;

  /// An urgent update: the phone lights up ("Claude needs you", finished, a snag).
  final bool alert;

  /// The alert has a sound (Claude needs you).
  final bool sound;

  /// `start` only: the names the activity was started with.
  final String? petName;
  final String? companionName;

  bool get isStart => event == 'start';
  bool get isEnd => event == 'end';

  /// The phase to draw: an unknown one draws as idle (Swift `art`).
  String get art => phases.contains(phase) ? phase : 'idle';

  /// Working or waiting: the elapsed time counts up from [since].
  bool get showsTimer => phase == 'working' || phase == 'waiting';

  // MARK: Reading

  /// From the host's `apns` object, opening `content-state.sealed` with [liveActivityKey]. Null when it isn't a Live
  /// Activity (no known event, no timestamp or content-state).
  static LinkLiveActivity? fromApns(
    Map<String, Object?> apns, {
    required List<int>? liveActivityKey,
    String id = '',
    String? from,
    String? room,
  }) {
    final event = jsonString(apns['event']);
    final timestamp = jsonDouble(apns['timestamp']);
    final state = asJsonMap(apns['content-state']);
    if (event != 'start' && event != 'update' && event != 'end' || timestamp == null || state == null) return null;
    final sealed = jsonString(state['sealed']);
    final text = sealed == null || liveActivityKey == null ? null : open(sealed, liveActivityKey);
    final attributes = asJsonMap(apns['attributes']);
    final alert = asJsonMap(apns['alert']);
    final placeholder = jsonString(state['title']) ?? 'Mochi';
    return LinkLiveActivity(
      id: id,
      from: from,
      room: room,
      event: event!,
      timestamp: timestamp.floor(),
      phase: jsonString(state['phase']) ?? 'idle',
      // Nothing sealed (an older host): the clear title and detail are the real ones.
      title: sealed == null ? placeholder : (text?.title ?? placeholder),
      detail: sealed == null ? jsonString(state['detail']) : text?.detail,
      opened: sealed == null || text != null,
      since: jsonDouble(state['since']) ?? timestamp,
      frame: jsonInt(state['frame']),
      dismissalDate: jsonDouble(apns['dismissal-date']),
      staleDate: jsonDouble(apns['stale-date']),
      alert: alert != null,
      sound: alert?['sound'] != null,
      petName: jsonString(attributes?['petName']),
      companionName: jsonString(attributes?['companionName']),
    );
  }

  /// A `liveActivity` frame as the relay hands it to an Android phone's socket: `{op: "send", key, id, from, apns}`.
  static LinkLiveActivity? fromEnvelope(Map<String, Object?> envelope, {required List<int>? liveActivityKey, String? room}) {
    final apns = asJsonMap(envelope['apns']);
    if (envelope['key'] != key || apns == null) return null;
    return fromApns(
      apns,
      liveActivityKey: liveActivityKey,
      id: jsonString(envelope['id']) ?? '',
      from: jsonString(envelope['from']),
      room: room,
    );
  }

  /// The relay's FCM data message (1.4.0): `{kind: "liveActivity", room, id, from, apns: <JSON string>}`. Null when
  /// [data] isn't one.
  static LinkLiveActivity? fromPushData(Map<String, Object?> data, {required List<int>? liveActivityKey}) {
    if (data['kind'] != key) return null;
    final raw = data['apns'];
    final apns = asJsonMap(raw is String ? tryJsonDecode(raw) : raw);
    if (apns == null) return null;
    return fromApns(
      apns,
      liveActivityKey: liveActivityKey,
      id: jsonString(data['id']) ?? '',
      from: jsonString(data['from']),
      room: jsonString(data['room']),
    );
  }

  /// The room an FCM Live Activity push says it's from, to pick the key it opens with.
  static String? pushRoom(Map<String, Object?> data) => data['kind'] == key ? jsonString(data['room']) : null;

  // MARK: Sealing

  /// The title and detail out of `content-state.sealed` ("nonce.box"), or null when it doesn't open with
  /// [liveActivityKey] (Swift `LinkPush.openLiveActivity`).
  static ({String? title, String? detail})? open(String sealed, List<int> liveActivityKey) {
    final dot = sealed.indexOf('.');
    if (dot <= 0 || dot == sealed.length - 1) return null;
    final plain = LinkCrypto.open(
      LinkSealed(nonce: sealed.substring(0, dot), box: sealed.substring(dot + 1)),
      ad: associatedData,
      key: liveActivityKey,
    );
    final json = plain == null ? null : asJsonMap(tryJsonDecode(utf8.decode(plain, allowMalformed: true)));
    if (json == null) return null;
    return (title: jsonString(json['title']), detail: jsonString(json['detail']));
  }

  /// `content-state.sealed` for [title] and [detail], as the host seals them. [nonce] is for tests only.
  static String seal({required String title, String? detail, required List<int> liveActivityKey, List<int>? nonce}) {
    final sealed = LinkCrypto.seal(
      utf8.encode(jsonEncode({'title': title, 'detail': ?detail})),
      ad: associatedData,
      key: liveActivityKey,
      nonce: nonce,
    );
    return '${sealed.nonce}.${sealed.box}';
  }

  /// The host's `apns` object, as the Mac builds it (Swift `LiveActivityPayload` then `LinkPush.liveActivity`): the
  /// title and detail sealed with [liveActivityKey], [petName] as the placeholder title, generic alert text. For hosts
  /// and test tools.
  static Map<String, Object?> apns({
    required String event,
    required int timestamp,
    required String phase,
    required String title,
    String? detail,
    required double since,
    int? frame,
    required List<int> liveActivityKey,
    String petName = 'Mochi',
    String companionName = 'Patch',
    bool alert = false,
    double? dismissalDate,
  }) {
    final apns = <String, Object?>{
      'timestamp': timestamp,
      'event': event,
      'content-state': {
        'phase': phase,
        'title': petName,
        'since': jsonNumber(since),
        'frame': ?frame,
        'sealed': seal(title: title, detail: detail, liveActivityKey: liveActivityKey),
      },
    };
    if (event == 'start') {
      apns['attributes-type'] = 'MochiActivityAttributes';
      apns['attributes'] = {'petName': petName, 'companionName': companionName};
      apns['alert'] = {'title': petName, 'body': '$petName is watching Claude work'};
      apns['input-push-token'] = 1;
    } else if (alert) {
      apns['alert'] = {'title': petName, 'body': 'Claude needs you', if (phase == 'waiting') 'sound': 'default'};
    }
    if (event == 'end') apns['dismissal-date'] = jsonNumber(dismissalDate ?? timestamp + 15 * 60);
    return apns;
  }

  /// A host's `liveActivity` frame, the same shape as Swift `RelayLinkStore.sendLiveActivity`: to every pocket, ten
  /// minutes to live, a `liveactivity` push hint.
  static String hostFrame(Map<String, Object?> apns, {required String id, required int priority, num? at}) => jsonEncode({
    'v': 1,
    'op': 'send',
    'key': key,
    'id': id,
    'to': ['pocket'],
    'ttl': 600,
    'at': (at ?? DateTime.now().millisecondsSinceEpoch / 1000).round(),
    'push': {'kind': 'liveactivity', 'priority': priority, 'collapse': 'live-activity'},
    'apns': apns,
  });

  @override
  String toString() => 'LinkLiveActivity($event $phase at $timestamp${opened ? '' : ', unopened'})';
}
