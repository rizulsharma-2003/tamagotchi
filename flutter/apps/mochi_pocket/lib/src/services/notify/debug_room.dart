import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';

import '../local_file.dart';
import '../push/push_service.dart';

/// Development builds only: a throwaway room beside the real pairing, for trying notification buttons end to end
/// without touching the room the phone is really paired with.
///
/// `tool/fake_mac.dart --pocket-credentials <file>` makes the room and a `pocket` device in it; that file, copied into
/// the app's files as `debug_action_room.json` (`adb shell run-as`), makes a debug build:
///
/// - register this phone's FCM address in that room too (straight to the relay; the address is never shown), so the
///   fake Mac's alerts arrive as real pushes, with the app closed;
/// - open those pushes with that room's key, and send their buttons' actions to that room.
///
/// Its done marks and outbox are files of their own, and its cards stay out of the Updates history. Release builds
/// never read the file.
abstract final class DebugActionRoom {
  static const String file = 'debug_action_room.json';
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
