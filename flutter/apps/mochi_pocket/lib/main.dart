// Mochi for Android (docs/MOCHI_LINK_PLAN.md 5.4): the Android twin of the iPhone's Mochi Pocket. It joins your Mochi
// Link room as a `pocket` device and talks to Mochi on your Mac through the relay, end-to-end encrypted.
//
// Build and install (the Gradle daemon needs JDK 17; Android Studio's bundled JDK 25 is too new for Gradle 8.12):
//
//   cd flutter/apps/mochi_pocket
//   GRADLE_OPTS="-Dorg.gradle.java.home=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
//     flutter run            # or: flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_link/mochi_link.dart';

import 'src/app.dart';
import 'src/model/pocket_model.dart';
import 'src/screens/settings_screen.dart' show appVersion;
import 'src/services/alert_notifier.dart';
import 'src/services/credential_store.dart';
import 'src/services/local_file.dart';
import 'src/services/platform_bridge.dart';
import 'src/services/push/push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw under the status and navigation bars; every screen keeps its content inside the safe areas.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final bridge = MethodChannelBridge();
  final notifier = LocalAlertNotifier();
  final files = await bridge.filesDir();
  final model = PocketModel(
    credentialStore: SecureCredentialStore(),
    doneDocument: files == null ? MemoryDocument() : FileDocument(File('$files/done.json')),
    notifier: notifier,
    connect: (credentials) => RelayLink(
      credentials,
      platform: 'android',
      app: appVersion,
      // Connection events only: the client never logs values or secrets.
      onLog: kDebugMode ? (message) => debugPrint('Mochi Link: $message') : null,
    ),
    // FCM: alerts reach the phone while the app is closed (google-services.json at build time; see the Gradle file).
    push: FirebasePushService(),
    shown: await openShownAlerts(),
    deviceName: await bridge.deviceName(),
  );
  await notifier.start();
  // Mochi's in-scene lettering (the sleepy z, ? and !) in the app's rounded face, as the Mac draws it in SF Rounded.
  MochiArtText.family = 'Nunito';
  runApp(MochiApp(model: model, bridge: bridge, notifier: notifier));
}
