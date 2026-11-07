import 'dart:convert';

import 'json.dart';
import 'link_credentials.dart';
import 'link_crypto.dart';

/// A notification for the phones (docs/MOCHI_LINK_PLAN.md 4.6.1): a `send` with key `alert` from a host or Mochi
/// Cloud to every `pocket`, sealed with the room key like any message (Swift `RelayLinkStore.sendAlert`).
///
/// Unlike other values, the sealed inner JSON is the notification itself, not wrapped in `{"v": …}`:
/// `{"title", "subtitle"?, "body", "userInfo": {…}}`. The relay pushes it to iPhones (whose notification extension
/// opens it) and also delivers it on the socket, which is how the Android app gets it while it runs.
class LinkAlert {
  const LinkAlert({
    required this.id,
    required this.from,
    this.title,
    this.subtitle,
    this.body,
    this.userInfo = const {},
    this.at,
    this.category,
    this.threadId,
  });

  /// The key on the wire. Not a [LinkKey]: alerts aren't state or a stored value, and the apps never `set` them.
  static const String key = 'alert';

  final String id;

  /// The sender's device id (authenticated: it's part of the associated data).
  final String from;
  final String? title;
  final String? subtitle;
  final String? body;

  /// What the Mac's APNs payload carried outside `aps` (`card`, `pending`, `quietIfKnown`, …).
  final Map<String, Object?> userInfo;

  /// The sender's clock, seconds.
  final double? at;

  /// The notification's kind from the sender's push hint, in the clear (`claude-turn`, `mochi-agent`,
  /// `mochi-meeting`, `mochi-draft`): which actions it gets. FCM pushes carry it as `data.category`.
  final String? category;

  /// Notifications with the same thread belong together (a Claude session's id, `mochi-agent`).
  final String? threadId;

  /// The sealed inner JSON.
  Map<String, Object?> toJson() => {'title': ?title, 'subtitle': ?subtitle, 'body': ?body, 'userInfo': userInfo};

  /// Opens an `alert` envelope as the relay delivers it (with `from`, and the sender's `push` hint on the socket).
  /// Null when it isn't a sealed alert or doesn't open with [roomKey] for [room] (another room, a changed field, a
  /// forged sender). [category] and [threadId] stand in for a hint the envelope doesn't carry (an FCM push's data).
  static LinkAlert? open(
    Map<String, Object?> envelope, {
    required String room,
    required List<int> roomKey,
    String? category,
    String? threadId,
  }) {
    final id = jsonString(envelope['id']), from = jsonString(envelope['from']);
    final nonce = jsonString(envelope['nonce']), box = jsonString(envelope['box']);
    if (envelope['key'] != key || id == null || from == null || nonce == null || box == null) return null;
    final plain = LinkCrypto.open(
      LinkSealed(nonce: nonce, box: box),
      ad: LinkCrypto.associatedData(room: room, key: key, id: id, from: from),
      key: roomKey,
    );
    final inner = plain == null ? null : asJsonMap(tryJsonDecode(utf8.decode(plain, allowMalformed: true)));
    if (inner == null) return null;
    final hint = asJsonMap(envelope['push']);
    return LinkAlert(
      id: id,
      from: from,
      title: jsonString(inner['title']),
      subtitle: jsonString(inner['subtitle']),
      body: jsonString(inner['body']),
      userInfo: asJsonMap(inner['userInfo']) ?? const {},
      at: jsonDouble(envelope['at']),
      category: jsonString(hint?['category']) ?? category,
      threadId: jsonString(hint?['threadId']) ?? threadId,
    );
  }

  /// A sealed alert `send` frame, the same shape as Swift `RelayLinkStore.sendAlert`: to every `pocket`, kept by the
  /// relay for [ttl] seconds, with an `alert` push hint (category and thread in the clear, for the push only).
  /// [nonce] is for tests only.
  static String frame(
    Map<String, Object?> inner,
    LinkCredentials credentials,
    List<int> roomKey, {
    required String id,
    int priority = 10,
    String? collapse,
    String? category,
    String? threadId,
    int ttl = 3600,
    num? at,
    List<int>? nonce,
  }) {
    final sealed = LinkCrypto.seal(
      utf8.encode(jsonEncode(inner)),
      ad: LinkCrypto.associatedData(room: credentials.room, key: key, id: id, from: credentials.device),
      key: roomKey,
      nonce: nonce,
    );
    return jsonEncode({
      'v': 1,
      'op': 'send',
      'key': key,
      'id': id,
      'to': ['pocket'],
      'ttl': ttl,
      'at': (at ?? DateTime.now().millisecondsSinceEpoch / 1000).round(),
      'push': {'kind': 'alert', 'priority': priority, 'collapse': ?collapse, 'category': ?category, 'threadId': ?threadId},
      'nonce': sealed.nonce,
      'box': sealed.box,
    });
  }

  @override
  String toString() => 'LinkAlert($id from $from)';
}
