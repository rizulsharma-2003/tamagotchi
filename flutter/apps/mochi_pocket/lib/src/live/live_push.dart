import 'package:mochi_link/mochi_link.dart';

import '../model/app_settings.dart';
import '../services/credential_store.dart';
import '../services/local_file.dart';
import '../services/notify/debug_room.dart';
import '../widget/home_widget.dart';
import 'live_notifier.dart';
import 'live_updates.dart';

/// A Live Activity push (relay 1.4.0's FCM data message: `kind: "liveActivity"`, `room`, `id`, `from`, `apns`), in
/// the app or in the push handler's background isolate. No network: the title and detail open with K_la, derived from
/// the room key on this phone.
abstract final class LivePush {
  static bool isLiveActivity(Map<String, Object?> data) => data['kind'] == LinkLiveActivity.key;

  /// Opens [data] with the room key [credentials] gives and hands it to [live] (and to [opened], with its room: the
  /// home-screen widget). Null when it isn't a Live Activity, this phone isn't paired, or it's from another room.
  static Future<LiveOutcome?> handle(
    Map<String, Object?> data, {
    required Future<LinkCredentials?> Function() credentials,
    required LiveUpdates live,
    required LinkHostName Function(LinkCredentials credentials) host,
    Future<void> Function(LinkLiveActivity activity, String room)? opened,
  }) async {
    if (!isLiveActivity(data)) return null;
    LinkCredentials? saved;
    try {
      saved = await credentials();
    } on Object {
      return null;
    }
    final key = saved?.roomKey;
    if (saved == null || key == null) return null;
    final room = LinkLiveActivity.pushRoom(data);
    if (room != null && room != saved.room) return null;
    final activity = LinkLiveActivity.fromPushData(data, liveActivityKey: LinkCrypto.liveActivityKey(key));
    if (activity == null) return null;
    if (opened != null) {
      try {
        await opened(activity, saved.room);
      } on Object {
        // The widget is a nicety: the lock screen is what matters here.
      }
    }
    return live.handle(activity, host: host(saved));
  }

  /// The background isolate's side: the pairing from secure storage (or a development build's test room), the
  /// setting from the app's settings file, and the computer's name from what the app last saw. The home-screen widget
  /// hears it too, even with the lock screen's turned off.
  static Future<LiveOutcome?> inBackground(Map<String, Object?> data, {required String? folder}) async {
    final debugRoom = await DebugActionRoom.load(folder);
    final testing = debugRoom != null && LinkLiveActivity.pushRoom(data) == debugRoom.room;
    final settings = AppSettings(AppFiles.document(folder, AppFiles.settings));
    await settings.load();
    final live = LiveUpdates(
      notifier: const PluginLiveNotifier(),
      record: AppFiles.document(folder, testing ? LiveUpdates.debugFile : LiveUpdates.file),
      enabled: () async => settings.showOnLockScreen,
    );
    final hostDocument = await AppFiles.document(folder, AppFiles.host).read().catchError((Object _) => null);
    return handle(
      data,
      credentials: testing ? () async => debugRoom : SecureCredentialStore().load,
      live: live,
      opened: (activity, room) => HomeWidget.inFolder(
        folder,
      ).liveActivityArrived(room, activity, done: AppFiles.document(folder, testing ? DebugActionRoom.doneFile : AppFiles.done)),
      host: (credentials) => LinkPeerNames.host(
        const [],
        me: credentials.device,
        pairedName: credentials.peerName,
        knownPlatform: hostDocument?['room'] == credentials.room ? LinkPlatform.parse(hostDocument?['platform'] as String?) : null,
      ),
    );
  }
}
