import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mochi_link/mochi_link.dart';

import '../theme.dart';
import 'notify/action_dispatcher.dart';
import 'notify/background_actions.dart';
import 'notify/notification_plan.dart';
import 'push/shown_alerts.dart';

/// Shows the Mac's alerts ([LinkAlert]) as notifications.
abstract interface class AlertNotifier {
  Future<void> start();

  /// Whether notifications are allowed for the app.
  Future<bool> enabled();

  /// Asks for permission to post notifications (Android 13+); true when they are allowed.
  Future<bool> requestPermission();

  /// Shows [alert], with [plan]'s buttons (Reply, Join, Mark done, Open in Gmail) when it has any.
  Future<void> show(LinkAlert alert, {NotificationPlan? plan});

  /// After a button: what happened, in place of the notification it was pressed in.
  Future<void> receipt(ActionReceipt receipt);
}

/// Android notifications through flutter_local_notifications: alerts from the relay socket while the app runs, and
/// from FCM pushes (in the app, or in the background isolate when it's closed). One channel and one style for both.
/// An alert's notification id comes from its id, so a second copy replaces the first instead of stacking.
///
/// Buttons (iOS/MochiPocket/PhoneNotifications.swift): Reply (with a text field) and Mark done run in the background
/// ([mochiNotificationAction]); Join and Open in Gmail, and a tap on the notification, open the app, which gets them
/// through [onResponse] (or [launchResponse] when the tap started it).
class LocalAlertNotifier implements AlertNotifier {
  LocalAlertNotifier({this.onResponse});

  /// The app's handler for taps and the buttons that open it. Null in background isolates.
  final void Function(NotificationResponse response)? onResponse;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _started = false;

  static const String _channel = 'mochi_alerts';
  static const String _receiptChannel = 'mochi_receipts';

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_mochi')),
      onDidReceiveNotificationResponse: onResponse,
      onDidReceiveBackgroundNotificationResponse: mochiNotificationAction,
    );
  }

  /// The tap that started the app, if a notification did (once).
  Future<NotificationResponse?> launchResponse() async {
    await start();
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      return details?.didNotificationLaunchApp == true ? details?.notificationResponse : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> enabled() async {
    await start();
    return await _android?.areNotificationsEnabled() ?? false;
  }

  @override
  Future<bool> requestPermission() async {
    await start();
    final android = _android;
    if (android == null) return false;
    if (await android.areNotificationsEnabled() ?? false) return true;
    return await android.requestNotificationsPermission() ?? false;
  }

  @override
  Future<void> show(LinkAlert alert, {NotificationPlan? plan}) async {
    await start();
    final title = alert.title ?? 'Mochi';
    final text = [alert.subtitle, alert.body].whereType<String>().where((part) => part.isNotEmpty).join('\n');
    try {
      await _plugin.show(
        id: notificationIdFor(alert.id),
        title: title,
        body: text.isEmpty ? 'Mochi has news' : text,
        payload: plan?.payload.encode(),
        notificationDetails: NotificationDetails(
          android: _alertDetails(
            text.isEmpty ? 'Mochi has news' : text,
            actions: [for (final action in plan?.actions ?? const <AlertAction>[]) _button(action, plan!.payload)],
          ),
        ),
      );
    } on Object catch (error) {
      // Never the alert's text: just that it couldn't be shown.
      debugPrint('Mochi: an alert could not be shown (${error.runtimeType})');
    }
  }

  @override
  Future<void> receipt(ActionReceipt receipt) async {
    await start();
    try {
      await _plugin.show(
        id: receipt.notificationId,
        title: receipt.title,
        body: receipt.body,
        notificationDetails: NotificationDetails(
          android: receipt.failed
              // Something didn't go: an alert that stays until it's seen.
              ? _alertDetails(receipt.body)
              // It went: a quiet note that leaves by itself.
              : AndroidNotificationDetails(
                  _receiptChannel,
                  'Replies and buttons',
                  channelDescription: 'Whether a reply or a button you pressed in a notification reached your computer.',
                  importance: Importance.low,
                  priority: Priority.low,
                  color: MochiPalette.light.tint,
                  styleInformation: BigTextStyleInformation(receipt.body),
                  timeoutAfter: 8000,
                  category: AndroidNotificationCategory.status,
                ),
        ),
      );
    } on Object catch (error) {
      debugPrint('Mochi: a confirmation could not be shown (${error.runtimeType})');
    }
  }

  AndroidNotificationDetails _alertDetails(String text, {List<AndroidNotificationAction>? actions}) => AndroidNotificationDetails(
    _channel,
    'From your computer',
    channelDescription: "Claude's finished turns, approvals and what's waiting for you, from Mochi on your Mac or PC.",
    importance: Importance.high,
    priority: Priority.high,
    color: MochiPalette.light.tint,
    styleInformation: BigTextStyleInformation(text),
    category: AndroidNotificationCategory.message,
    actions: actions,
  );

  /// Reply and Mark done stay in the notification shade; Join and Open in Gmail open the app, then their link.
  static AndroidNotificationAction _button(AlertAction action, NotificationPayload payload) => switch (action) {
    AlertAction.reply => const AndroidNotificationAction(
      'reply',
      'Reply',
      inputs: [AndroidNotificationActionInput(label: 'What should Claude do next?')],
      semanticAction: SemanticAction.reply,
    ),
    AlertAction.join => const AndroidNotificationAction('join', 'Join', showsUserInterface: true),
    AlertAction.openDraft => const AndroidNotificationAction('open-draft', 'Open in Gmail', showsUserInterface: true),
    AlertAction.markDone => AndroidNotificationAction('done', NotificationPlan.markDoneTitle(payload.ids.length)),
  };
}
