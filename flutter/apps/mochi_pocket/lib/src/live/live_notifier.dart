import 'package:mochi_live_update/mochi_live_update.dart';

import 'live_update_view.dart';

export 'package:mochi_live_update/mochi_live_update.dart' show LiveUpdatePosted, LiveUpdateStatus;

/// Posts Mochi's ongoing notification (the app's side of plugins/mochi_live_update), from the app or the push
/// handler's background isolate.
abstract interface class LiveNotifier {
  Future<LiveUpdatePosted> show(LiveUpdateView view);

  /// Takes it away, unless [timestamp] is older than the last one shown ([force]: always).
  Future<void> cancel({int? timestamp, bool force = false});

  /// Whether it's in the shade right now: it isn't once the user swiped it away.
  Future<bool> isShowing();

  Future<LiveUpdateStatus> status();

  /// Forgets the last timestamp shown (after unpairing).
  Future<void> reset();
}

class PluginLiveNotifier implements LiveNotifier {
  const PluginLiveNotifier();

  @override
  Future<LiveUpdatePosted> show(LiveUpdateView view) => MochiLiveUpdate.show(view.toMap());

  @override
  Future<void> cancel({int? timestamp, bool force = false}) => MochiLiveUpdate.cancel(timestamp: timestamp, force: force);

  @override
  Future<bool> isShowing() => MochiLiveUpdate.isShowing();

  @override
  Future<LiveUpdateStatus> status() => MochiLiveUpdate.status();

  @override
  Future<void> reset() => MochiLiveUpdate.reset();
}
