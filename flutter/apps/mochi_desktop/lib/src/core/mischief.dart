// Mischief (docs/SPRINT_2.md, "Windows extras: crazier than the Mac"): what Mochi gets up to on Windows beyond the Mac,
// out on the native stage (N1). Every extra is opt-in, behind one master switch (off at first) and a switch of its own
// (Settings › Mischief), and they all keep the same rules:
//
// - Mochi never takes your keyboard or pointer, never closes or minimises anything, and never types into apps.
// - Everything it moves is put back.
// - It keeps still while a full-screen app, a game or a presentation has the screen (W2), during quiet hours and quiet
//   mode (W1), while reactions are paused, while you focus (W15), and while nobody can see the screen (W30).
// - Moving extras rest while Windows' animation effects are off.
//
// [MischiefGate] is the one place that decides whether an extra may run now ([MischiefGate.why]); every extra asks it
// before it does anything and listens to it to stop.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/system.dart' show SystemMotion;
import 'desktop_settings.dart';
import 'notifications.dart' show NotificationPolicy;
import 'pc_rhythm.dart';

/// The extras, in Settings' order.
enum MischiefExtra {
  /// X10: confetti for big wins and fireworks for streaks, over the whole screen.
  celebrations(
    'Full-screen celebrations',
    'Confetti across your screen for big wins (graduation, green tests) and fireworks for streaks.',
    moves: true,
  ),

  /// X4: Mochi keeps your pointer company on the taskbar.
  cursorBuddy('Cursor buddy', 'When your pointer is on the taskbar, Mochi trots over and sits beside it.', moves: true),

  /// X9: little notes on the desktop.
  stickyNotes('Sticky notes', 'Mochi leaves little notes on your desktop, like “Claude finished the tests ✓”.', moves: false),

  /// X8: Mochi walks between your displays.
  roamScreens('Roams your screens', 'Mochi walks from one display to the next and follows you to the one you’re using.', moves: true),

  /// X1: Mochi rides your windows' title bars (on top of the adventures, W19).
  titleBars(
    'Title-bar walker',
    'Mochi rides your windows’ title bars: it holds on when you drag a window and hops off when you snap or minimise it.',
    moves: true,
  ),

  /// X3: Mochi hides behind the window you're using (out on the desktop) and in the taskbar while you're away.
  peekaboo(
    'Peekaboo',
    'Mochi hides behind the window you’re using and peeks out, and hides in the taskbar while you’re away, popping up when you’re back.',
    moves: true,
  );

  const MischiefExtra(this.title, this.detail, {required this.moves});

  /// The extras that are built (Settings lists only these: no dead switches). All of them are.
  static List<MischiefExtra> get available => values;

  final String title;

  /// One line on what it does (Settings).
  final String detail;

  /// It animates: it rests while Windows' animation effects are off.
  final bool moves;
}

/// The master switch and each extra's (Settings › Mischief), saved under `mischief`.
@immutable
class MischiefSettings {
  const MischiefSettings({this.enabled = false, this.extras = const {}});

  /// The master switch: off at first.
  final bool enabled;

  /// Each extra's own switch (missing: on, so turning Mischief on turns on everything you haven't turned off).
  final Map<MischiefExtra, bool> extras;

  bool on(MischiefExtra extra) => extras[extra] ?? true;

  /// [extra] may run as far as the switches go.
  bool allows(MischiefExtra extra) => enabled && on(extra);

  MischiefSettings copyWith({bool? enabled}) => MischiefSettings(enabled: enabled ?? this.enabled, extras: extras);

  MischiefSettings withExtra(MischiefExtra extra, bool on) => MischiefSettings(enabled: enabled, extras: {...extras, extra: on});

  Map<String, Object?> toJson() => {'enabled': enabled, for (final extra in MischiefExtra.values) extra.name: on(extra)};

  static MischiefSettings fromJson(Object? json) {
    if (json is! Map) return const MischiefSettings();
    return MischiefSettings(
      enabled: json['enabled'] == true,
      extras: {
        for (final extra in MischiefExtra.values)
          if (json[extra.name] is bool) extra: json[extra.name] as bool,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MischiefSettings && other.enabled == enabled && MischiefExtra.values.every((extra) => other.on(extra) == on(extra));

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll([for (final extra in MischiefExtra.values) on(extra)]));
}

/// Why an extra isn't running right now, in the order the gate asks.
enum MischiefPause {
  /// No native stage here (the macOS development build).
  unsupported,

  /// The master switch is off.
  off,

  /// This extra's switch is off.
  extraOff,

  /// Nobody can see the screen (the display off, the PC locked or asleep).
  unseen,

  /// A full-screen app, a game or a presentation has the screen.
  fullScreen,

  /// Quiet hours or quiet mode.
  quiet,

  /// Settings › General › Pause reactions.
  paused,

  /// A focus session is running.
  focusing,

  /// Windows' animation effects are off (moving extras only).
  calm;

  /// What Settings says about it ([pet]'s name).
  String note(String pet) => switch (this) {
    unsupported => 'Mischief needs Mochi for Windows. Here the switches are kept, but nothing runs.',
    off => 'Off.',
    extraOff => 'Off.',
    unseen => 'Waiting until someone can see the screen.',
    fullScreen => 'Keeping still while a full-screen app, a game or a presentation has the screen.',
    quiet => 'Keeping still for quiet hours.',
    paused => 'Keeping still while reactions are paused (General).',
    focusing => '$pet keeps still while you focus.',
    calm => 'Resting while Windows’ animation effects are off.',
  };
}

/// Decides whether each extra may run now, and tells its listeners when that changes. It looks again whenever the
/// PC's rhythm, the settings or the animation setting change, and every [checkEvery] while Mischief is on and the screen
/// can be seen (for a full-screen app coming and going, and the edges of quiet hours); not at all otherwise.
class MischiefGate extends ChangeNotifier {
  MischiefGate({
    required this.settings,
    required this.rhythm,
    required this.motion,
    this.supported = false,
    bool Function()? fullScreen,
    bool Function()? focusing,
    DateTime Function()? clock,
    this.checkEvery = const Duration(seconds: 2),
  }) : _fullScreen = fullScreen ?? _never,
       _focusing = focusing ?? _never,
       _clock = clock ?? DateTime.now;

  final DesktopSettings settings;
  final PcRhythm rhythm;
  final SystemMotion motion;

  /// There's a native stage (Windows).
  final bool supported;
  final bool Function() _fullScreen;
  final bool Function() _focusing;
  final DateTime Function() _clock;
  final Duration checkEvery;

  static bool _never() => false;

  Timer? _timer;
  bool _started = false;
  bool _fullScreenNow = false;
  Map<MischiefExtra, MischiefPause?> _verdicts = const {};

  /// Watching ([start]ed and not disposed).
  bool get started => _started;

  /// The check is running (tests: not while Mischief is off or nobody can see the screen).
  bool get checking => _timer != null;

  /// A full-screen app, a game or a presentation had the screen at the last look.
  bool get fullScreen => _fullScreenNow;

  /// Why [extra] can't run now, or null: it may.
  MischiefPause? why(MischiefExtra extra) {
    if (!_started) return _decide(extra, fullScreen: _fullScreen());
    return _verdicts[extra];
  }

  /// [extra] may run now.
  bool may(MischiefExtra extra) => why(extra) == null;

  /// What pauses every extra now (null: nothing does; each may still be off on its own).
  MischiefPause? get whyAll {
    final first = why(MischiefExtra.stickyNotes);
    return first == MischiefPause.extraOff ? _decide(MischiefExtra.stickyNotes, fullScreen: _fullScreenNow, ignoreSwitch: true) : first;
  }

  MischiefPause? _decide(MischiefExtra extra, {required bool fullScreen, bool ignoreSwitch = false}) {
    final mischief = settings.mischief;
    if (!supported) return MischiefPause.unsupported;
    if (!mischief.enabled) return MischiefPause.off;
    if (!ignoreSwitch && !mischief.on(extra)) return MischiefPause.extraOff;
    return _rules(fullScreen: fullScreen, moves: extra.moves);
  }

  /// The rules every extra keeps, in the order they're asked.
  MischiefPause? _rules({required bool fullScreen, required bool moves}) {
    if (rhythm.unseen) return MischiefPause.unseen;
    if (fullScreen) return MischiefPause.fullScreen;
    if (NotificationPolicy.isQuiet(settings, _clock())) return MischiefPause.quiet;
    if (settings.pauseReactions) return MischiefPause.paused;
    if (moves && _focusing()) return MischiefPause.focusing;
    if (moves && motion.reduced) return MischiefPause.calm;
    return null;
  }

  /// Why Mochi's desktop adventures (W19: a Mac feature, on by default, so not behind the Mischief switches) can't go out
  /// now: the same rules as every extra, asked afresh (a full-screen app is looked for now, not at the last look).
  MischiefPause? whyAdventure() {
    if (!supported) return MischiefPause.unsupported;
    return _rules(fullScreen: !rhythm.unseen && _fullScreen(), moves: true);
  }

  /// Starts watching.
  void start() {
    if (_started) return;
    _started = true;
    settings.addListener(check);
    rhythm.addListener(check);
    motion.addListener(check);
    check();
  }

  /// Looks again now (and starts or stops the regular look).
  void check() {
    if (!_started) return;
    final mischief = settings.mischief;
    final watching = supported && mischief.enabled && !rhythm.unseen;
    _fullScreenNow = watching && _fullScreen();
    final verdicts = {for (final extra in MischiefExtra.values) extra: _decide(extra, fullScreen: _fullScreenNow)};
    if (watching) {
      _timer ??= Timer.periodic(checkEvery, (_) => check());
    } else {
      _timer?.cancel();
      _timer = null;
    }
    if (mapEquals(verdicts, _verdicts)) return;
    _verdicts = verdicts;
    notifyListeners();
  }

  /// Stops watching (the verdicts are worked out on asking again).
  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_started) {
      settings.removeListener(check);
      rhythm.removeListener(check);
      motion.removeListener(check);
    }
    _started = false;
    _verdicts = const {};
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
