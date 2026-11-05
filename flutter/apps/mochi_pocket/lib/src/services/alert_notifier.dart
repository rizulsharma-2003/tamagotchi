import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mochi_link/mochi_link.dart';

import '../theme.dart';
import 'push/shown_alerts.dart';

/// Shows the Mac's alerts ([LinkAlert]) as notifications.
abstract interface class AlertNotifier {
  Future<void> start();

  /// Whether notifications are allowed for the app.
  Future<bool> enabled();

  /// Asks for permission to post notifications (Android 13+); true when they are allowed.
  Future<bool> requestPermission();

  Future<void> show(LinkAlert alert);
}

/// Android notifications through flutter_local_notifications: alerts from the relay socket while the app runs, and
/// from FCM pushes (in the app, or in the background isolate when it's closed). One channel and one style for both.
/// An alert's notification id comes from its id, so a second copy replaces the first instead of stacking.
class LocalAlertNotifier implements AlertNotifier {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _started = false;

  static const String _channel = 'mochi_alerts';

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_mochi')));
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
  Future<void> show(LinkAlert alert) async {
    await start();
    final title = alert.title ?? 'Mochi';
    final text = [alert.subtitle, alert.body].whereType<String>().where((part) => part.isNotEmpty).join('\n');
    try {
      await _plugin.show(
        id: notificationIdFor(alert.id),
        title: title,
        body: text.isEmpty ? 'Mochi has news' : text,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel,
            'From your Mac',
            channelDescription: "Claude's finished turns, approvals and what's waiting for you, from Mochi on your Mac.",
            importance: Importance.high,
            priority: Priority.high,
            color: MochiPalette.light.tint,
            styleInformation: BigTextStyleInformation(text.isEmpty ? 'Mochi has news' : text),
            category: AndroidNotificationCategory.message,
          ),
        ),
      );
    } on Object catch (error) {
      // Never the alert's text: just that it couldn't be shown.
      debugPrint('Mochi: an alert could not be shown (${error.runtimeType})');
    }
  }
}
