import 'dart:convert';

import 'package:mochi_link/mochi_link.dart';

import '../alert_notifier.dart';
import '../notify/notification_plan.dart';
import 'shown_alerts.dart';

/// What happened to one push.
enum PushOutcome {
  /// Opened and shown.
  shown,

  /// It was for this phone but couldn't be opened: "Mochi has news" was shown instead.
  fallback,

  /// Already shown (it came over the relay socket too, or FCM delivered it twice).
  duplicate,

  /// Not an alert, or not for this phone (no pairing, or a room it left).
  ignored,
}

/// The relay's data-only FCM message for an alert (docs/MOCHI_LINK_PLAN.md 4.6.1, Android):
/// `data.kind = "alert"`, `data.mochi` = a JSON string of `{v: 1, room, key, id, from, nonce, box}` (the APNs `mochi`
/// object), and optionally `data.category` and `data.threadId`. The box opens like an `alert` frame on the socket.
abstract final class PushMessages {
  /// The sealed `mochi` object of an alert push, or null when [data] isn't one.
  static Map<String, Object?>? sealedAlert(Map<String, Object?> data) {
    if (data['kind'] != 'alert') return null;
    final raw = data['mochi'];
    final decoded = raw is String ? _tryDecode(raw) : raw;
    return decoded is Map ? decoded.map((key, value) => MapEntry('$key', value)) : const {};
  }

  /// The notification shown when an alert for this phone can't be opened, like the iPhone's notification extension.
  static LinkAlert fallback(String? id) => LinkAlert(id: id ?? 'mochi-push', from: '', title: 'Mochi', body: 'Mochi has news');

  /// Handles one data message, in the app or in the background isolate. Never touches the network.
  ///
  /// - Not an alert, no pairing, or another room's: ignored.
  /// - Already shown: a duplicate, nothing shown.
  /// - Opens with the room key: shown with its buttons (and recorded, so a second copy is dropped). A card that rides
  ///   along (Mochi's news) goes to [record], for the Updates history.
  /// - For this phone but can't be opened (a damaged message, unreadable credentials): "Mochi" / "Mochi has news",
  ///   under the alert's own notification id, so the real text replaces it if it arrives over the socket later.
  ///
  /// [isDone] keeps Mark done off items already done.
  static Future<PushOutcome> handle(
    Map<String, Object?> data, {
    required Future<LinkCredentials?> Function() credentials,
    required AlertNotifier notifier,
    required ShownAlerts shown,
    bool Function(String id)? isDone,
    Future<void> Function(List<AgentNote> notes)? record,
  }) async {
    final sealed = sealedAlert(data);
    if (sealed == null) return PushOutcome.ignored;
    final id = sealed['id'] is String ? sealed['id']! as String : null;
    if (id != null && await shown.contains(id)) return PushOutcome.duplicate;
    LinkCredentials? saved;
    try {
      saved = await credentials();
    } on Object {
      await notifier.show(fallback(id));
      return PushOutcome.fallback;
    }
    final key = saved?.roomKey;
    if (saved == null || key == null) return PushOutcome.ignored;
    final room = sealed['room'];
    if (room != null && room != saved.room) return PushOutcome.ignored;
    final alert = LinkAlert.open(
      sealed,
      room: saved.room,
      roomKey: key,
      category: data['category'] is String ? data['category']! as String : null,
      threadId: data['threadId'] is String ? data['threadId']! as String : null,
    );
    if (alert == null) {
      await notifier.show(fallback(id));
      return PushOutcome.fallback;
    }
    if (!await shown.claim(alert.id)) return PushOutcome.duplicate;
    await notifier.show(
      alert,
      plan: NotificationPlan.forAlert(alert, room: saved.room, isDone: isDone),
    );
    final card = AgentPending.fromJson(alert.userInfo['pending']);
    if (card != null && card.enabled && record != null) {
      try {
        await record(card.items);
      } on Object {
        // The history is a nicety: the notification is what matters.
      }
    }
    return PushOutcome.shown;
  }

  static Object? _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}
