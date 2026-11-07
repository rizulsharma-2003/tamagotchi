import 'package:mochi_link/mochi_link.dart';

import 'notification_plan.dart';

/// A tap on one of a notification's buttons (or on the notification), from whichever isolate got it.
class NotificationAction {
  const NotificationAction({required this.notificationId, required this.payload, this.action, this.input});

  /// The notification's id: the confirmation replaces it.
  final int notificationId;

  /// Null when the notification itself was tapped.
  final AlertAction? action;

  /// What was typed into Reply.
  final String? input;
  final NotificationPayload payload;

  /// For the hop from the background isolate to the app's (plain values only).
  Map<String, Object?> toMessage() => {'id': notificationId, 'action': action?.id, 'input': input, 'payload': payload.encode()};

  static NotificationAction? fromMessage(Object? message) {
    if (message is! Map) return null;
    final payload = NotificationPayload.decode(message['payload'] as String?);
    final id = message['id'];
    if (payload == null || id is! int) return null;
    return NotificationAction(
      notificationId: id,
      payload: payload,
      action: AlertAction.parse(message['action'] as String?),
      input: message['input'] as String?,
    );
  }
}

/// How an action went.
enum ActionResult {
  /// The relay has it (and passes it on to the computer now, or when it's back).
  sent,

  /// The relay couldn't be reached: kept for the app to send when it next connects.
  queued,

  /// The relay turned it down.
  refused,

  /// This phone isn't paired with the room the notification came from (any more).
  notPaired,

  /// Nothing to do (an empty reply, or not an action that runs here).
  ignored,
}

/// What the notification says afterwards: it replaces the one that was acted on.
class ActionReceipt {
  const ActionReceipt({required this.notificationId, required this.title, required this.body, this.failed = false});

  final int notificationId;
  final String title;
  final String body;

  /// Something didn't go: shown as an alert (it stays), not as a quiet note that leaves by itself.
  final bool failed;

  @override
  String toString() => 'ActionReceipt(${failed ? 'failed' : 'ok'}: $title / $body)';
}

/// Where an action's local side lives: the app's model while Mochi runs, the app's files while it's closed.
abstract interface class ActionState {
  /// This phone's pairing, or null.
  Future<LinkCredentials?> credentials();

  /// The computer, named for the confirmation ("your Mac", "your PC"); [peers] is the relay's device list when it
  /// answered (it says whether the computer is online).
  Future<LinkHostName> host(List<LinkPeer>? peers);

  /// A reply the relay has: Recently shows it, and the computer's answer finds it.
  Future<void> sent(LinkCommand command);

  /// A reply the relay couldn't take: the app sends it when it connects (for the next ten minutes).
  Future<void> queue(LinkCommand command);

  /// Marks [ids] done on this phone; returns the whole list this phone shares (`phoneDone`).
  Future<AgentDoneList> markDone(List<String> ids);

  /// The list couldn't be shared now: the app shares it when it connects.
  Future<void> shareDoneLater();
}

/// The relay over HTTPS, one request at a time: for actions taken while the socket isn't there.
abstract interface class RelayPost {
  /// Sends one sealed frame; throws [LinkPairingException] when the relay refuses it or can't be reached.
  Future<void> send(String frame, LinkCredentials from);

  /// The room's devices (who's online); throws like [send].
  Future<List<LinkPeer>> devices(LinkCredentials credentials);
}

/// [LinkPairing.send] with a short wait: an action runs while Android lets the app work briefly in the background.
class HttpRelayPost implements RelayPost {
  const HttpRelayPost({this.within = const Duration(seconds: 10)});

  final Duration within;

  @override
  Future<void> send(String frame, LinkCredentials from) => LinkPairing.send(frame, from: from, within: within);

  @override
  Future<List<LinkPeer>> devices(LinkCredentials credentials) => LinkPairing.devices(credentials, within: const Duration(seconds: 4));
}

/// Runs Reply and Mark done from a notification (Swift `PhoneNotifications.userNotificationCenter(_:didReceive:)`),
/// the same way in the app and in the background isolate: the frame goes to the relay over HTTPS straight away (a
/// short-lived connection, so it doesn't wait for the app's socket), the local side is kept in [state], and a
/// confirmation replaces the notification.
///
/// - Reply sends the session the same `command` as the session card's Reply: typed, with its project and session.
/// - Mark done marks the items done here and shares this phone's whole list as `phoneDone`, as the in-app circle does.
/// - No connection: the reply waits for the app (ten minutes, the relay's own limit for commands) and the done marks
///   are shared when it connects; the notification says so.
class ActionDispatcher {
  ActionDispatcher({required this.state, required this.relay, required this.receipt, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final ActionState state;
  final RelayPost relay;

  /// Shows the confirmation (or what went wrong).
  final Future<void> Function(ActionReceipt receipt) receipt;
  final DateTime Function() _clock;

  double get _now => _clock().millisecondsSinceEpoch / 1000;

  Future<ActionResult> run(NotificationAction action) async {
    switch (action.action) {
      case AlertAction.reply:
        return _reply(action);
      case AlertAction.markDone:
        return _markDone(action);
      case AlertAction.join || AlertAction.openDraft || null:
        return ActionResult.ignored;
    }
  }

  Future<ActionResult> _reply(NotificationAction action) async {
    final payload = action.payload;
    final text = (action.input ?? '').trim();
    final project = payload.project, session = payload.session;
    if (text.isEmpty || project == null || session == null) return ActionResult.ignored;
    final quoted = _quote(text);
    final credentials = await _paired(payload);
    final key = credentials?.roomKey;
    if (credentials == null || key == null) {
      await receipt(
        ActionReceipt(
          notificationId: action.notificationId,
          title: 'Reply not sent',
          body: "This phone isn't paired with that computer any more, so $quoted didn't go. Open Mochi to pair again.",
          failed: true,
        ),
      );
      return ActionResult.notPaired;
    }
    final command = LinkCommand(id: RelayLink.newId(), text: text, at: _now, typed: true, project: project, session: session);
    try {
      await relay.send(RelayLink.frame(command.toValue(), LinkKey.command, credentials, key), credentials);
    } on LinkPairingException catch (error) {
      final host = await state.host(null);
      if (_removed(error)) {
        await receipt(
          ActionReceipt(
            notificationId: action.notificationId,
            title: 'Reply not sent',
            body: "This phone isn't in ${host.yours}'s room any more, so $quoted didn't go. Open Mochi to pair again.",
            failed: true,
          ),
        );
        return ActionResult.notPaired;
      }
      await state.queue(command);
      await receipt(
        ActionReceipt(
          notificationId: action.notificationId,
          title: 'Reply not sent yet',
          body: error.code == null
              ? 'No connection to Mochi Link. Open Mochi in the next 10 minutes and it sends $quoted to $project on ${host.yours}.'
              : "Mochi Link didn't take it just now (${error.code}). Open Mochi in the next 10 minutes and it sends $quoted again.",
          failed: true,
        ),
      );
      return ActionResult.queued;
    }
    await state.sent(command);
    final host = await state.host(await _devices(credentials));
    await receipt(
      ActionReceipt(
        notificationId: action.notificationId,
        title: payload.title ?? project,
        body: host.online || host.lastSeen == null
            ? 'Sent to Claude in $project on ${host.yours}: $quoted'
            : '${host.yoursCapitalized} is away. Claude in $project gets $quoted when it’s back (within 10 minutes).',
      ),
    );
    return ActionResult.sent;
  }

  Future<ActionResult> _markDone(NotificationAction action) async {
    final payload = action.payload;
    if (payload.ids.isEmpty) return ActionResult.ignored;
    final what = payload.names.isEmpty ? (payload.ids.length == 1 ? 'It' : 'They') : LinkPeerNames.list(payload.names);
    final credentials = await _paired(payload);
    final key = credentials?.roomKey;
    if (credentials == null || key == null) {
      await receipt(
        ActionReceipt(
          notificationId: action.notificationId,
          title: 'Not marked done',
          body: "This phone isn't paired with that computer any more. Open Mochi to pair again.",
          failed: true,
        ),
      );
      return ActionResult.notPaired;
    }
    final shared = await state.markDone(payload.ids);
    try {
      await relay.send(RelayLink.frame(shared.toValue(), LinkKey.phoneDone, credentials, key), credentials);
    } on LinkPairingException catch (error) {
      final host = await state.host(null);
      if (_removed(error)) {
        await receipt(
          ActionReceipt(
            notificationId: action.notificationId,
            title: 'Marked done on this phone',
            body: "$what. This phone isn't in ${host.yours}'s room any more: open Mochi to pair again.",
            failed: true,
          ),
        );
        return ActionResult.notPaired;
      }
      await state.shareDoneLater();
      await receipt(
        ActionReceipt(
          notificationId: action.notificationId,
          title: 'Marked done on this phone',
          body: '$what. No connection to Mochi Link right now: ${host.yours} hears when Mochi next connects.',
        ),
      );
      return ActionResult.queued;
    }
    final host = await state.host(await _devices(credentials));
    await receipt(
      ActionReceipt(
        notificationId: action.notificationId,
        title: 'Marked done',
        body: host.online || host.lastSeen == null
            ? '$what. Done on ${host.yours} and your other phones too.'
            : '$what. ${host.yoursCapitalized} is away: it sees this when it’s back.',
      ),
    );
    return ActionResult.sent;
  }

  /// The pairing, when the notification came from its room.
  Future<LinkCredentials?> _paired(NotificationPayload payload) async {
    LinkCredentials? credentials;
    try {
      credentials = await state.credentials();
    } on Object {
      return null;
    }
    if (credentials == null) return null;
    final room = payload.room;
    return room == null || room == credentials.room ? credentials : null;
  }

  /// Who's in the room, for the wording; null when the relay doesn't say quickly.
  Future<List<LinkPeer>?> _devices(LinkCredentials credentials) async {
    try {
      return await relay.devices(credentials);
    } on Object {
      return null;
    }
  }

  static bool _removed(LinkPairingException error) =>
      error.status == 401 || error.status == 404 || error.code == 'unauthorized' || error.code == 'room_not_found';

  /// “Run the tests”, cut short when it's long.
  static String _quote(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ');
    return '“${line.length > 80 ? '${line.substring(0, 79)}…' : line}”';
  }
}
