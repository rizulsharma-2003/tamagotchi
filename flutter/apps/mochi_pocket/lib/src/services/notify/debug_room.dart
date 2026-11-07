import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';

import '../../live/live_updates.dart';
import '../../model/pocket_model.dart';
import '../alert_notifier.dart';
import '../credential_store.dart';
import '../local_file.dart';
import '../push/push_service.dart';
import 'action_dispatcher.dart';
import 'notification_plan.dart';

/// Development builds only: a throwaway room beside the real pairing, for trying notification buttons end to end
/// without touching the room the phone is really paired with.
///
/// `tool/fake_mac.dart --pocket-credentials <file>` makes the room and a `pocket` device in it; that file, copied into
/// the app's files as `debug_action_room.json` (`adb shell run-as`), makes a debug build:
///
/// - register this phone's FCM address in that room too (straight to the relay; the address is never shown), so the
///   fake Mac's alerts arrive as real pushes, with the app closed;
/// - open those pushes with that room's key, and send their buttons' actions to that room;
/// - while the app is open, join that room as a computer of its own ([model]): its Live Activities arrive on that
///   socket, the way the real room's arrive on the app's own, and hold to talk sends what you say there, to the fake
///   Mac, never to your real computer.
///
/// Its done marks and outbox are files of their own, and its cards stay out of the Updates history. Release builds
/// never read the file.
///
/// With [uiFile] there too (`adb shell run-as com.insideedge.mochi touch files/debug_room_ui`), the whole app shows the
/// test room instead of the real one: the home screen, the home-screen widget, shortcuts and the Quick Settings tile,
/// and Mochi Cloud, whose trigger may then be a stand-in on this phone (tool/fake_cloud.dart through `adb reverse`).
/// The real pairing stays as it is, unused until the file goes.
abstract final class DebugActionRoom {
  static const String file = 'debug_action_room.json';
  static const String uiFile = 'debug_room_ui';
  static const String doneFile = 'debug_action_done.json';
  static const String outboxFile = 'debug_action_outbox.json';

  static Future<LinkCredentials?> load(String? folder) async {
    if (!kDebugMode || folder == null) return null;
    try {
      final json = await AppFiles.document(folder, file).read();
      final credentials = json == null ? null : LinkCredentials.fromJson(json);
      return credentials?.roomKey == null ? null : credentials;
    } on Object {
      return null;
    }
  }

  /// The whole app shows the test room ([uiFile]).
  static bool showsUi(String? folder) => kDebugMode && folder != null && File('$folder/$uiFile').existsSync();

  /// The test room as a room of its own: its Live Activities and `activityEnded` go to [live] (its own record,
  /// [LiveUpdates.debugFile]), and hold to talk uses it instead of the real room. Connected now, unless [connect] is
  /// off (the app connects it when it shows it). Null without a test room.
  static Future<PocketModel?> model(String? folder, {required LiveUpdates live, bool connect = true}) async {
    final room = await load(folder);
    if (room == null) return null;
    final model = PocketModel(
      credentialStore: MemoryCredentialStore(room),
      doneDocument: AppFiles.document(folder, doneFile),
      notifier: const _Quiet(),
      connect: (credentials) => RelayLink(credentials, platform: 'android', app: 'debug'),
      live: live,
      deviceName: 'Mochi action test',
      allowLocalCloud: true,
    );
    if (connect) await model.load();
    debugPrint('Mochi: the debug action room is ${connect ? 'connected; hold to talk goes there' : 'what the app shows'}');
    return model;
  }

  /// Tells the test room's relay where to push this phone (over HTTPS, as the room's pocket device).
  static Future<void> registerPush(String? folder, PushService push) async {
    final room = await load(folder);
    if (room == null) return;
    try {
      if (await push.start() != null) return;
      final token = await push.token();
      if (token == null || token.isEmpty) return;
      await LinkPairing.send(RelayLink.registerFrame({'fcm': token}, id: RelayLink.newId()), from: room);
      debugPrint('Mochi: registered for pushes in the debug action room');
    } on Object catch (error) {
      debugPrint('Mochi: the debug action room was not registered (${error.runtimeType})');
    }
  }
}

/// The test room's alerts come as pushes (and the app's own notifier shows those); its socket copies stay quiet.
class _Quiet implements AlertNotifier {
  const _Quiet();

  @override
  Future<void> start() async {}

  @override
  Future<bool> enabled() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(LinkAlert alert, {NotificationPlan? plan}) async {}

  @override
  Future<void> receipt(ActionReceipt receipt) async {}
}
