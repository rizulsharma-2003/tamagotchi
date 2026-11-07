import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mochi_link/mochi_link.dart';

import '../../model/pocket_model.dart';
import '../alert_notifier.dart';
import '../link_opener.dart';
import 'action_dispatcher.dart';
import 'background_actions.dart';
import 'notification_plan.dart';

/// The local side of an action while Mochi runs: the model, so Recently, "Waiting for you" and the history change
/// at once.
class ModelActionState implements ActionState {
  ModelActionState(this.model);

  final PocketModel model;

  @override
  Future<LinkCredentials?> credentials() async {
    // An action can arrive while the app is still starting.
    await model.loaded.timeout(const Duration(seconds: 5), onTimeout: () {});
    return model.credentials;
  }

  @override
  Future<LinkHostName> host(List<LinkPeer>? peers) async {
    if (peers == null) return model.host;
    final credentials = model.credentials;
    return LinkPeerNames.host(peers, me: credentials?.device, pairedName: credentials?.peerName, knownPlatform: model.host.platform);
  }

  @override
  Future<void> sent(LinkCommand command) async => model.addSentReply(command);

  @override
  Future<void> queue(LinkCommand command) async => model.queueReply(command);

  @override
  Future<AgentDoneList> markDone(List<String> ids) async => model.markDoneHere(ids);

  @override
  Future<void> shareDoneLater() async => model.shareDone();
}

/// Notification taps and buttons while Mochi runs (iOS `PhoneNotifications.userNotificationCenter(_:didReceive:)`):
///
/// - Reply and Mark done come from the background isolate that Android starts for them ([ActionInbox]) and run here
///   with the model, so the app's screens show them straight away.
/// - Join opens the meeting, Open in Gmail the draft; a tap on a meeting heads-up or on "Reply drafted" does the same,
///   as on the iPhone. Any other tap just opens the app.
class AppNotificationActions {
  AppNotificationActions({required this.model, required this.opener, required this.notifier, this.relay = const HttpRelayPost()});

  final PocketModel model;
  final LinkOpener opener;
  final AlertNotifier notifier;
  final RelayPost relay;
  ReceivePort? _inbox;

  /// Starts taking Reply and Mark done from the background isolate.
  void start() => _inbox ??= ActionInbox.open((action) => unawaited(run(action)));

  void dispose() {
    final inbox = _inbox;
    _inbox = null;
    if (inbox != null) ActionInbox.close(inbox);
  }

  /// Reply or Mark done, with the model.
  Future<ActionResult> run(NotificationAction action) async {
    final result = await ActionDispatcher(state: ModelActionState(model), relay: relay, receipt: notifier.receipt).run(action);
    if (kDebugMode) debugPrint('Mochi: notification ${action.action?.id}: ${result.name}');
    return result;
  }

  /// A tap, or a button that opens the app (FLN's foreground callback, or the tap that launched the app).
  Future<void> respond(NotificationResponse response) async {
    final action = actionFrom(response);
    if (action != null) await handle(action);
  }

  Future<void> handle(NotificationAction action) async {
    final payload = action.payload;
    final link = switch (action.action) {
      AlertAction.reply || AlertAction.markDone => null,
      AlertAction.join => payload.join,
      AlertAction.openDraft => payload.link,
      // A tap: a meeting heads-up joins, "Reply drafted" opens the draft; anything else just opens the app.
      null => payload.join ?? payload.link,
    };
    if (action.action == AlertAction.reply || action.action == AlertAction.markDone) {
      await run(action);
    } else if (link != null) {
      await opener.openLink(link);
    }
  }
}
