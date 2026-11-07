// Your PC's rhythm (docs/SPRINT_2.md W2): Mochi naps while the PC rests and wakes with a stretch when you're back, the
// Mac's MacUsageMonitor (Sources/App/Features/Rest) and CompanionWorld.updateSystem/updateNap. Every few seconds the
// platform reports how long since the last keyboard or mouse input (only the time, never what it was), whether the
// display is off or the session locked, whether something keeps the screen on (a video, a call, a presentation, a
// full-screen app) and how busy the processor is. Nothing is stored or sent.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'desktop_settings.dart';

/// How the PC is used right now (the Mac's `SystemActivity`).
@immutable
class SystemActivity {
  const SystemActivity({required this.idleSeconds, this.displaysAsleep = false, this.keepsDisplayAwake = false, this.cpuLoad = 0});

  /// Seconds since the last keyboard, mouse, touch or pen input.
  final double idleSeconds;

  /// The display is off, or the PC is locked, asleep or switched to another user: nobody is here.
  final bool displaysAsleep;

  /// A video, a call, a presentation or a full-screen app keeps the screen on.
  final bool keepsDisplayAwake;

  /// 0–1 across all cores, smoothed over about a minute.
  final double cpuLoad;

  /// Above this the PC counts as busy, even with nobody at it (a build, an export).
  static const double busyLoad = 0.6;

  /// You're away after this long without input (the Mac's "only notify me when I'm away": 3 minutes).
  static const double awayAfterSeconds = 180;

  /// Someone is at the PC right now.
  bool get userActive => !displaysAsleep && idleSeconds < 30;

  /// The PC is resting: its display is off (or it's locked), or nobody has touched it for [restAfter] while nothing
  /// keeps the screen on and the processor is calm.
  bool isResting(Duration restAfter) =>
      displaysAsleep || (idleSeconds >= restAfter.inSeconds && !keepsDisplayAwake && cpuLoad < busyLoad);

  /// You've stepped away: locked, display off, or no input for [awayAfterSeconds].
  bool get away => displaysAsleep || idleSeconds >= awayAfterSeconds;

  @override
  bool operator ==(Object other) =>
      other is SystemActivity &&
      other.idleSeconds == idleSeconds &&
      other.displaysAsleep == displaysAsleep &&
      other.keepsDisplayAwake == keepsDisplayAwake &&
      other.cpuLoad == cpuLoad;

  @override
  int get hashCode => Object.hash(idleSeconds, displaysAsleep, keepsDisplayAwake, cpuLoad);

  @override
  String toString() =>
      'SystemActivity(idle ${idleSeconds.toStringAsFixed(0)} s, display ${displaysAsleep ? 'asleep' : 'on'}, '
      '${keepsDisplayAwake ? 'kept awake' : 'not held'}, cpu ${(cpuLoad * 100).round()}%)';
}

/// Reads the PC's state (Win32 on Windows; nothing on the macOS development build, a fake in tests).
abstract interface class UsageSampler {
  bool get supported;

  /// Now; null when it can't be read.
  SystemActivity? sample();

  /// Something changed between samples (the display went off, the PC was locked): sample again now.
  Stream<void> get changes;

  void dispose();
}

class UnsupportedUsage implements UsageSampler {
  const UnsupportedUsage();

  @override
  bool get supported => false;

  @override
  SystemActivity? sample() => null;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  void dispose() {}
}

/// Mochi's nap, the Mac's `updateNap` as a small state machine: with "Sleep while my PC rests" on, Mochi falls asleep
/// once the PC rests, Claude is idle and nothing happened for a minute, and wakes (with a stretch) when you're back at
/// the PC or something happens. Without the PC's state (or with the switch off), Mochi naps after 30 quiet minutes, as
/// before.
class NapState {
  bool _asleep = false;

  bool get asleep => _asleep;

  /// The nap with quiet time measured from [lastActivity] (the last hook event, pet or launch). Only asked while no
  /// Claude session works or waits for you.
  bool update({
    required DateTime now,
    required DateTime lastActivity,
    required SystemActivity? system,
    required bool followSystem,
    required Duration restAfter,
    bool paused = false,
    Duration fallback = const Duration(minutes: 30),
  }) {
    final quiet = now.difference(lastActivity);
    if (!followSystem || system == null) return _asleep = quiet >= fallback;
    if (paused) return _asleep;
    final resting = system.isResting(restAfter);
    if (_asleep) {
      // Back at the PC, or something just happened (a hook event, a pet): awake.
      if ((!resting && system.userActive) || quiet <= const Duration(minutes: 1)) _asleep = false;
    } else if (resting && quiet > const Duration(minutes: 1)) {
      _asleep = true;
    }
    return _asleep;
  }
}

/// The PC's rhythm, sampled every [interval] (5 s, as on the Mac) and right away when the display or the session
/// changes. Listeners hear about a change in resting, being here or being away, not every sample.
class PcRhythm extends ChangeNotifier {
  PcRhythm({required this.settings, UsageSampler? sampler, this.interval = const Duration(seconds: 5)})
    : sampler = sampler ?? const UnsupportedUsage();

  final DesktopSettings settings;
  final UsageSampler sampler;
  final Duration interval;
  final NapState nap = NapState();
  Timer? _timer;
  StreamSubscription<void>? _changes;

  SystemActivity? _activity;

  /// The latest reading (null: unknown, as on the macOS development build).
  SystemActivity? get activity => _activity;

  bool get available => _activity != null;

  Duration get restAfter => Duration(minutes: settings.restAfterMinutes);

  /// The PC is resting (the phones' Mochi sleeps too, as with a Mac).
  bool get resting => _activity?.isResting(restAfter) ?? false;

  /// You're away from the PC; null when Mochi can't tell.
  bool? get away => _activity?.away;

  void start() {
    if (!sampler.supported || _timer != null) return;
    _changes = sampler.changes.listen((_) => sample());
    _timer = Timer.periodic(interval, (_) => sample());
    sample();
  }

  void sample() {
    final next = sampler.sample();
    if (next != null) report(next);
  }

  /// A new reading (the sampler's, or a test's).
  void report(SystemActivity activity) {
    final before = _activity;
    _activity = activity;
    final changed =
        before == null ||
        before.isResting(restAfter) != activity.isResting(restAfter) ||
        before.userActive != activity.userActive ||
        before.away != activity.away;
    if (changed) notifyListeners();
  }

  /// Whether Mochi is asleep now ([NapState]), for its mood.
  bool asleep({required DateTime now, required DateTime lastActivity}) => nap.update(
    now: now,
    lastActivity: lastActivity,
    system: _activity,
    followSystem: settings.followSystem,
    restAfter: restAfter,
    paused: settings.pauseReactions,
  );

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _changes?.cancel();
    sampler.dispose();
    super.dispose();
  }
}
