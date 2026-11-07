// Mochi for Android (docs/MOCHI_LINK_PLAN.md 5.4): the Android twin of the iPhone's Mochi Pocket. It joins your Mochi
// Link room as a `pocket` device and talks to Mochi on your Mac through the relay, end-to-end encrypted.
//
// Build and install (the Gradle daemon needs JDK 17; Android Studio's bundled JDK 25 is too new for Gradle 8.12):
//
//   cd flutter/apps/mochi_pocket
//   GRADLE_OPTS="-Dorg.gradle.java.home=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
//     flutter run            # or: flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_link/mochi_link.dart';

import 'src/app.dart';
import 'src/live/live_notifier.dart';
import 'src/live/live_updates.dart';
import 'src/model/app_settings.dart';
import 'src/model/pocket_model.dart';
import 'src/screens/settings_screen.dart' show appVersion;
import 'src/services/alert_notifier.dart';
import 'src/services/credential_store.dart';
import 'src/services/link_opener.dart';
import 'src/services/local_file.dart';
import 'src/services/notify/app_actions.dart';
import 'src/services/notify/debug_room.dart';
import 'src/services/platform_bridge.dart';
import 'src/services/push/push_service.dart';
import 'src/talk/speech_listener.dart';
import 'src/voice/speech_engine.dart';
import 'src/voice/updates_reader.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw under the status and navigation bars; every screen keeps its content inside the safe areas.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final bridge = MethodChannelBridge();
  // Taps and the buttons that open the app (Join, Open in Gmail) come here; Reply and Mark done start in a
  // background isolate and are handed to [actions] while the app runs.
  late final AppNotificationActions actions;
  final notifier = LocalAlertNotifier(onResponse: (response) => unawaited(actions.respond(response)));
  final files = await bridge.filesDir();
  final push = FirebasePushService();
  // Appearance, voice and the lock screen, loaded before the first frame so the chosen theme shows straight away.
  final settings = AppSettings(AppFiles.document(files, AppFiles.settings));
  await settings.load();
  // Mochi on the lock screen while Claude works (the iPhone's Live Activity), shared with the push handler.
  final live = LiveUpdates(
    notifier: const PluginLiveNotifier(),
    record: AppFiles.document(files, LiveUpdates.file),
    enabled: () async => settings.showOnLockScreen,
  );
  final model = PocketModel(
    credentialStore: SecureCredentialStore(),
    doneDocument: AppFiles.document(files, AppFiles.done),
    hostDocument: AppFiles.document(files, AppFiles.host),
    historyDocument: AppFiles.document(files, AppFiles.history),
    outboxDocument: AppFiles.document(files, AppFiles.outbox),
    notifier: notifier,
    connect: (credentials) => RelayLink(
      credentials,
      platform: 'android',
      app: appVersion,
      // Connection events only: the client never logs values or secrets.
      onLog: kDebugMode ? (message) => debugPrint('Mochi Link: $message') : null,
    ),
    // FCM: alerts reach the phone while the app is closed (google-services.json at build time; see the Gradle file).
    push: push,
    live: live,
    shown: await openShownAlerts(),
    deviceName: await bridge.deviceName(),
  );
  actions = AppNotificationActions(model: model, opener: const UrlLinkOpener(), notifier: notifier)..start();
  // Development builds with a throwaway test room (DebugActionRoom): its pushes reach this phone too, and its Live
  // Activities while the app is open.
  PocketModel? debugRoom;
  if (kDebugMode) {
    unawaited(DebugActionRoom.registerPush(files, push));
    final debugLive = LiveUpdates(
      notifier: const PluginLiveNotifier(),
      record: AppFiles.document(files, LiveUpdates.debugFile),
      enabled: () async => settings.showOnLockScreen,
    );
    debugRoom = await DebugActionRoom.model(files, live: debugLive);
  }
  await notifier.start();
  final reader = UpdatesReader(
    engine: FlutterTtsEngine(),
    focus: bridge,
    settings: settings,
    // With TalkBack on, TalkBack reads it in the user's own screen-reader voice.
    announce: (text) => SemanticsService.announce(text, TextDirection.ltr),
  );
  // Mochi's in-scene lettering (the sleepy z, ? and !) in the app's rounded face, as the Mac draws it in SF Rounded.
  MochiArtText.family = 'Nunito';
  runApp(
    MochiApp(
      model: model,
      bridge: bridge,
      notifier: notifier,
      settings: settings,
      reader: reader,
      live: live,
      // Hold to talk (A3): Android's speech recognizer, on the phone when it can be. A development build with a test
      // room talks to that room's fake Mac instead of the real computer.
      speech: PlatformSpeechListener(),
      talkTo: debugRoom,
    ),
  );
  // A tap on a meeting heads-up (or its Join) that started the app opens the meeting, as on the iPhone.
  final launched = await notifier.launchResponse();
  if (launched != null) await actions.respond(launched);
}
