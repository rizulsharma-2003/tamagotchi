import 'package:mochi_link/mochi_link.dart';

/// What Mochi's ongoing notification says for one moment of Claude's turn: the Android twin of the iPhone's Lock Screen
/// banner (iOS/Shared/MochiActivityViews.swift `MochiLockScreenView`), drawn by plugins/mochi_live_update.
///
/// - The title the computer sealed ("Claude is working", "Claude needs you", "Claude finished!") and its detail (the
///   project and tool count, when the computer shares them), else where it's happening ("On your Mac").
/// - Mochi's pose for the phase and frame (the iPhone's art), and the elapsed time while Claude works or waits.
/// - Open, and Open the Session when Claude needs you. Claude needing you also lights the phone up, with a sound.
/// - On Android 16 a short status bar chip when there's no timer: "Needs you", "Done".
/// - It goes by itself if no update comes for a long while (the computer went away mid-turn), and an ended one at the
///   dismissal time the computer chose.
class LiveUpdateView {
  const LiveUpdateView({
    required this.timestamp,
    required this.title,
    required this.text,
    required this.art,
    this.frame,
    this.sinceMs,
    this.chronometer = false,
    this.ongoing = true,
    this.alert = false,
    this.timeoutMs,
    this.chip,
    this.actions = const [openAction],
    this.force = false,
  });

  static const String openAction = 'open';
  static const String sessionAction = 'session';

  /// No update for this long and it goes: the computer moves Mochi along every few seconds while Claude works.
  static const Duration workingTimeout = Duration(minutes: 30);

  /// Claude can wait for you a long time; the iPhone keeps a Live Activity up to eight hours.
  static const Duration waitingTimeout = Duration(hours: 8);

  /// Done, a snag or idle: the computer ends it within minutes.
  static const Duration restingTimeout = Duration(minutes: 15);

  /// The computer's timestamp: an older one never replaces a newer one.
  final int timestamp;
  final String title;
  final String text;

  /// The phase to draw (working · waiting · done · idle · error · asleep).
  final String art;

  /// One of the phase's ten poses.
  final int? frame;

  /// When the turn or wait began (ms): the notification's time, and the timer's start.
  final int? sinceMs;

  /// The time counts up from [sinceMs].
  final bool chronometer;

  /// While Claude works it can't be swiped away; once the turn has ended it can.
  final bool ongoing;

  /// Lights the phone up with a sound (Claude needs you).
  final bool alert;

  /// It leaves by itself after this long.
  final int? timeoutMs;

  /// Android 16's status bar chip text.
  final String? chip;
  final List<String> actions;

  /// Shown whatever the last timestamp was (Settings' sample).
  final bool force;

  /// [activity] as the notification shows it, [now] for the time left until an ended one leaves.
  static LiveUpdateView of(LinkLiveActivity activity, {required LinkHostName host, required DateTime now}) {
    final ongoing = !activity.isEnd;
    final nowSeconds = now.millisecondsSinceEpoch / 1000;
    final detail = activity.detail?.trim();
    final art = activity.art;
    final int timeout;
    if (!ongoing) {
      final dismissAt = activity.dismissalDate ?? activity.timestamp + restingTimeout.inSeconds;
      timeout = ((dismissAt - nowSeconds) * 1000).round();
    } else {
      timeout = switch (art) {
        'working' => workingTimeout,
        'waiting' => waitingTimeout,
        _ => restingTimeout,
      }.inMilliseconds;
    }
    return LiveUpdateView(
      timestamp: activity.timestamp,
      title: activity.title,
      text: detail == null || detail.isEmpty ? 'On ${host.yours}' : detail,
      art: art,
      frame: activity.frame,
      sinceMs: (activity.since * 1000).round(),
      chronometer: ongoing && activity.showsTimer,
      ongoing: ongoing,
      alert: ongoing && activity.sound,
      timeoutMs: timeout,
      chip: ongoing ? chipFor(art) : null,
      actions: [openAction, if (ongoing && art == 'waiting') sessionAction],
    );
  }

  /// The status bar chip on Android 16, where a timer isn't the news.
  static String? chipFor(String art) => switch (art) {
    'waiting' => 'Needs you',
    'done' => 'Done',
    'error' => 'Snag',
    'idle' => 'Idle',
    'asleep' => 'Napping',
    _ => null,
  };

  /// The same, after the computer ended it: it can be swiped away, has no timer, and leaves in [timeout].
  LiveUpdateView ended({required Duration timeout, bool force = false}) => LiveUpdateView(
    timestamp: timestamp,
    title: title,
    text: text,
    art: art,
    frame: frame,
    sinceMs: sinceMs,
    ongoing: false,
    timeoutMs: timeout.inMilliseconds,
    force: force,
  );

  /// Settings' sample for [phase], as the iPhone's "Show on Lock Screen" (`ActivityCoordinator.demoState`).
  static LiveUpdateView sample(String phase, {required LinkHostName host, required DateTime now, int frame = 0}) {
    final title = switch (phase) {
      'working' => 'Claude is working',
      'waiting' => 'Claude needs you',
      'done' => 'Claude finished!',
      'error' => 'Claude hit a snag',
      'idle' => 'Claude is idle',
      'asleep' => 'Mochi is napping',
      _ => 'Mochi',
    };
    final since = now.subtract(const Duration(seconds: 95));
    return LiveUpdateView(
      timestamp: now.millisecondsSinceEpoch ~/ 1000,
      title: title,
      text: 'A sample from this phone',
      art: LinkLiveActivity.phases.contains(phase) ? phase : 'idle',
      frame: frame,
      sinceMs: since.millisecondsSinceEpoch,
      chronometer: phase == 'working' || phase == 'waiting',
      timeoutMs: const Duration(minutes: 2).inMilliseconds,
      chip: chipFor(phase),
      actions: [openAction, if (phase == 'waiting') sessionAction],
      force: true,
    );
  }

  /// For the plugin (plugins/mochi_live_update).
  Map<String, Object?> toMap() => {
    'timestamp': timestamp,
    'title': title,
    'text': text,
    'art': art,
    'frame': ?frame,
    'sinceMs': ?sinceMs,
    'chronometer': chronometer,
    'ongoing': ongoing,
    'alert': alert,
    'timeoutMs': ?timeoutMs,
    'chip': ?chip,
    'actions': actions,
    'force': force,
  };

  static LiveUpdateView? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final timestamp = map['timestamp'], title = map['title'], text = map['text'], art = map['art'];
    if (timestamp is! num || title is! String || text is! String || art is! String) return null;
    return LiveUpdateView(
      timestamp: timestamp.toInt(),
      title: title,
      text: text,
      art: art,
      frame: (map['frame'] as num?)?.toInt(),
      sinceMs: (map['sinceMs'] as num?)?.toInt(),
      chronometer: map['chronometer'] == true,
      ongoing: map['ongoing'] != false,
      alert: map['alert'] == true,
      timeoutMs: (map['timeoutMs'] as num?)?.toInt(),
      chip: map['chip'] as String?,
      actions: (map['actions'] as List?)?.whereType<String>().toList() ?? const [openAction],
    );
  }
}
