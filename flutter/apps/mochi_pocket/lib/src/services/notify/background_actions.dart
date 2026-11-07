import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mochi_link/mochi_link.dart';

import '../../model/done_marks.dart';
import '../alert_notifier.dart';
import '../credential_store.dart';
import '../local_file.dart';
import 'action_dispatcher.dart';
import 'action_outbox.dart';
import 'debug_room.dart';
import 'notification_plan.dart';

/// The notification's tap or button as an action, or null when it isn't one of Mochi's.
NotificationAction? actionFrom(NotificationResponse response) {
  final payload = NotificationPayload.decode(response.payload);
  if (payload == null) return null;
  return NotificationAction(
    notificationId: response.id ?? 0,
    payload: payload,
    action: AlertAction.parse(response.actionId),
    input: response.input,
  );
}

/// Reply and Mark done, pressed in a notification. Android runs this in a background isolate of its own (a broadcast
/// receiver starts it), whether or not Mochi is open:
///
/// 1. Mochi is running: the action goes to the app ([ActionInbox]), which sends it and updates its screens.
/// 2. It isn't: it's handled here, from the app's files ([FileActionState]), over a short-lived HTTPS connection to
///    the relay, and a confirmation (or what went wrong) replaces the notification.
@pragma('vm:entry-point')
void mochiNotificationAction(NotificationResponse response) => unawaited(handleBackgroundAction(response));

Future<void> handleBackgroundAction(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  final action = actionFrom(response);
  final kind = action?.action;
  if (action == null || kind == null || kind.opensApp) return;
  final folder = await AppFiles.folder();
  // Development builds: a button on the throwaway test room's notification acts on that room, with its own files.
  final debugRoom = await DebugActionRoom.load(folder);
  final testing = debugRoom != null && action.payload.room == debugRoom.room;
  if (!testing && await ActionInbox.forward(action)) {
    _log('notification ${kind.id}: handed to the app');
    return;
  }
  final notifier = LocalAlertNotifier();
  final dispatcher = ActionDispatcher(
    state: testing
        ? FileActionState(
            credentials: MemoryCredentialStore(debugRoom),
            done: AppFiles.document(folder, DebugActionRoom.doneFile),
            outbox: AppFiles.document(folder, DebugActionRoom.outboxFile),
            host: MemoryDocument(),
          )
        : FileActionState(
            credentials: SecureCredentialStore(),
            done: AppFiles.document(folder, AppFiles.done),
            outbox: AppFiles.document(folder, AppFiles.outbox),
            host: AppFiles.document(folder, AppFiles.host),
          ),
    relay: const HttpRelayPost(),
    receipt: notifier.receipt,
  );
  try {
    final result = await dispatcher.run(action);
    _log('notification ${kind.id} in the background${testing ? ' (debug action room)' : ''}: ${result.name}');
  } on Object catch (error) {
    _log('notification ${kind.id} in the background failed (${error.runtimeType})');
  }
}

/// The hop from the background isolate to the app's, while Mochi runs: one port, registered by name (both isolates
/// live in the same process). The app answers at once that it took the action; no answer in time (Mochi isn't
/// running, or is shutting down) and the background isolate does it itself.
abstract final class ActionInbox {
  static const String name = 'com.insideedge.mochi/notification-actions';

  /// The app starts taking actions; close the port when it stops.
  static ReceivePort open(void Function(NotificationAction action) take) {
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(name);
    IsolateNameServer.registerPortWithName(port.sendPort, name);
    port.listen((message) {
      if (message is! List || message.length != 2) return;
      final action = NotificationAction.fromMessage(message.first);
      final answer = message.last;
      if (answer is SendPort) answer.send(action != null);
      if (action != null) take(action);
    });
    return port;
  }

  static void close(ReceivePort port) {
    IsolateNameServer.removePortNameMapping(name);
    port.close();
  }

  /// Hands [action] to the app; true when it took it.
  static Future<bool> forward(NotificationAction action, {Duration wait = const Duration(seconds: 2)}) async {
    final app = IsolateNameServer.lookupPortByName(name);
    if (app == null) return false;
    final answer = ReceivePort();
    try {
      app.send([action.toMessage(), answer.sendPort]);
      return await answer.first.timeout(wait, onTimeout: () => false) == true;
    } on Object {
      return false;
    } finally {
      answer.close();
    }
  }
}

/// The local side of an action while Mochi is closed: the pairing from secure storage, done marks in `done.json`,
/// and what the app should pick up in the outbox.
class FileActionState implements ActionState {
  FileActionState({
    required CredentialStore credentials,
    required LocalDocument done,
    required LocalDocument outbox,
    required LocalDocument host,
    DateTime Function()? clock,
  }) : _credentials = credentials,
       _done = done,
       _outbox = outbox,
       _host = host,
       _clock = clock ?? DateTime.now;

  final CredentialStore _credentials;
  final LocalDocument _done;
  final LocalDocument _outbox;
  final LocalDocument _host;
  final DateTime Function() _clock;
  LinkCredentials? _loaded;

  double get _now => _clock().millisecondsSinceEpoch / 1000;

  @override
  Future<LinkCredentials?> credentials() async => _loaded ??= await _credentials.load();

  @override
  Future<LinkHostName> host(List<LinkPeer>? peers) async {
    final credentials = await this.credentials();
    LinkPlatform? known;
    try {
      final saved = await _host.read();
      if (saved?['room'] == credentials?.room) known = LinkPlatform.parse(saved?['platform'] as String?);
    } on Object {
      known = null;
    }
    return LinkPeerNames.host(peers ?? const [], me: credentials?.device, pairedName: credentials?.peerName, knownPlatform: known);
  }

  @override
  Future<void> sent(LinkCommand command) => NotificationOutbox.update(_outbox, (outbox) => outbox.sent.add(command));

  @override
  Future<void> queue(LinkCommand command) => NotificationOutbox.update(_outbox, (outbox) => outbox.queued.add(command));

  @override
  Future<AgentDoneList> markDone(List<String> ids) async {
    final marks = DoneMarks.fromJson(await _done.read())..prune(now: _now);
    if (marks.mark(ids, now: _now)) {
      await _done.write(marks.toJson());
      await NotificationOutbox.update(_outbox, (outbox) => outbox.doneChanged = true);
    }
    return marks.shared(now: _now);
  }

  @override
  Future<void> shareDoneLater() => NotificationOutbox.update(_outbox, (outbox) => outbox.shareDone = true);
}

/// Development builds only, and never what was typed, tokens or keys.
void _log(String message) {
  if (kDebugMode) debugPrint('Mochi: $message');
}
