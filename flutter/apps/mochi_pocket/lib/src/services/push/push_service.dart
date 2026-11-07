import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../live/live_push.dart';
import '../../model/done_marks.dart';
import '../../model/updates_history.dart';
import '../alert_notifier.dart';
import '../credential_store.dart';
import '../local_file.dart';
import '../notify/debug_room.dart';
import 'push_messages.dart';
import 'shown_alerts.dart';

/// Why getting a push address failed, in words for Settings.
class PushException implements Exception {
  const PushException(this.reason);

  final String reason;

  @override
  String toString() => 'PushException: $reason';
}

/// This phone's push address and the pushes that arrive while the app is open (FCM).
abstract interface class PushService {
  /// Gets push ready (once). Null when it works; otherwise why it can't, for Settings.
  Future<String?> start();

  /// The current push address. Throws [PushException].
  Future<String?> token();

  /// A new push address (Firebase rotates them now and then).
  Stream<String> get tokenRefresh;

  /// Data messages that arrive while the app is in the foreground (in the background they go to
  /// [mochiBackgroundMessage] instead).
  Stream<Map<String, Object?>> get messages;

  /// Forgets the push address, so it can't receive pushes for a room this phone left.
  Future<void> deleteToken();
}

/// Firebase Cloud Messaging. The configuration comes from android/app/google-services.json at build time (the
/// google-services Gradle plugin, applied only when that file is there); without it, [start] says so and alerts
/// still arrive over the relay socket while the app runs.
class FirebasePushService implements PushService {
  Future<String?>? _started;

  @override
  Future<String?> start() => _started ??= _start();

  Future<String?> _start() async {
    try {
      await Firebase.initializeApp();
    } on Object catch (error) {
      _log('Firebase is not set up in this build (${error.runtimeType})');
      return 'this build of Mochi has no Firebase setup';
    }
    FirebaseMessaging.onBackgroundMessage(mochiBackgroundMessage);
    return null;
  }

  @override
  Future<String?> token() async {
    if (await start() != null) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } on Object catch (error) {
      final text = '$error';
      _log('no push address (${error.runtimeType})');
      if (text.contains('SERVICE_NOT_AVAILABLE') || text.contains('MISSING_INSTANCEID_SERVICE')) {
        throw const PushException("Google Play services couldn't be reached (no internet, or not on this phone)");
      }
      if (text.contains('AUTHENTICATION_FAILED') || text.contains('INVALID_SENDER')) {
        throw const PushException("Firebase didn't accept this app's setup");
      }
      throw const PushException("Firebase couldn't give this phone a push address");
    }
  }

  @override
  Stream<String> get tokenRefresh => Stream.fromFuture(
    start(),
  ).asyncExpand((problem) => problem == null ? FirebaseMessaging.instance.onTokenRefresh : const Stream<String>.empty());

  @override
  Stream<Map<String, Object?>> get messages => Stream.fromFuture(start()).asyncExpand(
    (problem) => problem == null
        ? FirebaseMessaging.onMessage.map((message) => Map<String, Object?>.from(message.data))
        : const Stream<Map<String, Object?>>.empty(),
  );

  @override
  Future<void> deleteToken() async {
    if (await start() != null) return;
    await FirebaseMessaging.instance.deleteToken();
  }
}

/// The file both isolates use to remember which alerts were shown.
Future<ShownAlerts> openShownAlerts() async {
  try {
    final folder = await getApplicationSupportDirectory();
    return FileShownAlerts(File('${folder.path}/shown_alerts.json'));
  } on Object {
    return MemoryShownAlerts();
  }
}

/// FCM pushes while Mochi is in the background or closed, in their own isolate: open the sealed alert with the room
/// key from secure storage and show it as a notification (or "Mochi has news"), with its buttons. A news card that
/// rides along joins the Updates history in the app's files. A Live Activity update (relay 1.4.0) shows, updates or
/// ends Mochi's ongoing notification ([LivePush]). No network, no relay.
@pragma('vm:entry-point')
Future<void> mochiBackgroundMessage(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  final data = Map<String, Object?>.from(message.data);
  final folder = await AppFiles.folder();
  if (LivePush.isLiveActivity(data)) {
    final outcome = await LivePush.inBackground(data, folder: folder);
    _log('live activity in the background: ${outcome?.name ?? 'ignored'}');
    return;
  }
  // Development builds: a push from the throwaway test room opens with that room's key and keeps to its own files.
  final debugRoom = await DebugActionRoom.load(folder);
  final testing = debugRoom != null && PushMessages.sealedAlert(data)?['room'] == debugRoom.room;
  DoneMarks done;
  try {
    done = DoneMarks.fromJson(await AppFiles.document(folder, testing ? DebugActionRoom.doneFile : AppFiles.done).read());
  } on Object {
    done = DoneMarks();
  }
  final outcome = await PushMessages.handle(
    data,
    credentials: testing ? () async => debugRoom : SecureCredentialStore().load,
    notifier: LocalAlertNotifier(),
    shown: await openShownAlerts(),
    isDone: done.isDone,
    record: testing ? null : (notes) => recordHistory(AppFiles.document(folder, AppFiles.history), notes),
  );
  _log('push in the background: ${outcome.name}');
}

/// Development builds only, and never tokens, keys or alert text.
void _log(String message) {
  if (kDebugMode) debugPrint('Mochi: $message');
}
