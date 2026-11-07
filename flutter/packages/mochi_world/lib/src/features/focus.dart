// W15, the focus buddy. Port of Sources/TamagotchiCore/Features/FocusModels.swift (settings, phases, the clock text),
// FocusTimer.swift (the Pomodoro phase machine), FocusLog.swift (completed blocks for the recap, without the file) and
// the rules of Sources/App/Features/Focus/FocusController.swift (what Mochi and Patch say and do at each transition,
// the break choreography and the optional chime and banner), as `FocusBuddy`.

import 'dart:math' as math;

import '../model/animations.dart';
import '../model/json.dart';
import '../world/reactions.dart';
import '../world/world.dart';
import 'moment.dart';

/// Settings for the focus buddy (the Mac's `focus` setting: same keys and defaults).
class FocusSettings {
  const FocusSettings({
    this.workMinutes = 25,
    this.breakMinutes = 5,
    this.longBreakMinutes = 15,
    this.cyclesBeforeLongBreak = 4,
    this.napsDuringFocus = true,
    this.chimeAtBreak = true,
    this.bannerAtBreak = false,
  });

  final int workMinutes;
  final int breakMinutes;
  final int longBreakMinutes;
  final int cyclesBeforeLongBreak;
  final bool napsDuringFocus;
  final bool chimeAtBreak;

  /// Also post a notification banner when a break starts (off by default, like every banner).
  final bool bannerAtBreak;

  FocusSettings copyWith({
    int? workMinutes,
    int? breakMinutes,
    int? longBreakMinutes,
    int? cyclesBeforeLongBreak,
    bool? napsDuringFocus,
    bool? chimeAtBreak,
    bool? bannerAtBreak,
  }) => FocusSettings(
    workMinutes: workMinutes ?? this.workMinutes,
    breakMinutes: breakMinutes ?? this.breakMinutes,
    longBreakMinutes: longBreakMinutes ?? this.longBreakMinutes,
    cyclesBeforeLongBreak: cyclesBeforeLongBreak ?? this.cyclesBeforeLongBreak,
    napsDuringFocus: napsDuringFocus ?? this.napsDuringFocus,
    chimeAtBreak: chimeAtBreak ?? this.chimeAtBreak,
    bannerAtBreak: bannerAtBreak ?? this.bannerAtBreak,
  );

  Map<String, Object?> toJson() => {
    'workMinutes': workMinutes,
    'breakMinutes': breakMinutes,
    'longBreakMinutes': longBreakMinutes,
    'cyclesBeforeLongBreak': cyclesBeforeLongBreak,
    'napsDuringFocus': napsDuringFocus,
    'chimeAtBreak': chimeAtBreak,
    'bannerAtBreak': bannerAtBreak,
  };

  static FocusSettings fromJson(Object? json) {
    final j = asMap(json);
    return FocusSettings(
      workMinutes: integer(j, 'workMinutes', 25),
      breakMinutes: integer(j, 'breakMinutes', 5),
      longBreakMinutes: integer(j, 'longBreakMinutes', 15),
      cyclesBeforeLongBreak: integer(j, 'cyclesBeforeLongBreak', 4),
      napsDuringFocus: boolean(j, 'napsDuringFocus', true),
      chimeAtBreak: boolean(j, 'chimeAtBreak', true),
      bannerAtBreak: boolean(j, 'bannerAtBreak', false),
    );
  }

  @override
  bool operator ==(Object other) => other is FocusSettings && _same(toJson(), other.toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);
}

bool _same(Map<String, Object?> a, Map<String, Object?> b) => a.length == b.length && a.keys.every((k) => a[k] == b[k]);

extension FocusPhaseText on FocusPhase {
  String get title => switch (this) {
    FocusPhase.focus => 'Focus',
    FocusPhase.shortBreak => 'Break',
    FocusPhase.longBreak => 'Long break',
  };

  bool get isBreak => this != FocusPhase.focus;
}

/// "18:42" (or "1:05:00" past an hour), rounded up so it never shows 0:00 early.
String focusClock(double seconds) {
  final total = math.max(0, seconds.ceil());
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final secs = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${two(minutes)}:${two(secs)}' : '$minutes:${two(secs)}';
}

/// A focus block that ran to the end. Only these go into the focus log and the recap.
class FocusBlock {
  const FocusBlock({required this.endedAt, required this.minutes});
  final DateTime endedAt;
  final double minutes;

  /// The Mac's focus-log.json entry: seconds since 1970.
  Map<String, Object?> toJson() => {'endedAt': endedAt.toUtc().microsecondsSinceEpoch / 1e6, 'minutes': minutes};

  static FocusBlock? fromJson(Object? json) {
    final j = asMap(json);
    final ended = j['endedAt'];
    final minutes = j['minutes'];
    if (ended is! num || minutes is! num) return null;
    return FocusBlock(endedAt: DateTime.fromMicrosecondsSinceEpoch((ended * 1e6).round(), isUtc: true), minutes: minutes.toDouble());
  }

  @override
  bool operator ==(Object other) => other is FocusBlock && other.endedAt == endedAt && other.minutes == minutes;

  @override
  int get hashCode => Object.hash(endedAt, minutes);

  @override
  String toString() => 'FocusBlock(${endedAt.toUtc().toIso8601String()}, $minutes min)';
}

/// Phase lengths in seconds.
class FocusDurations {
  FocusDurations({required double focus, required double shortBreak, required double longBreak, required int cyclesBeforeLongBreak})
    : focus = math.max(1, focus),
      shortBreak = math.max(1, shortBreak),
      longBreak = math.max(1, longBreak),
      cyclesBeforeLongBreak = math.max(1, cyclesBeforeLongBreak);

  /// From the user's settings (minutes), within sensible bounds.
  factory FocusDurations.fromSettings(FocusSettings settings) => FocusDurations(
    focus: settings.workMinutes.clamp(1, 180) * 60.0,
    shortBreak: settings.breakMinutes.clamp(1, 60) * 60.0,
    longBreak: settings.longBreakMinutes.clamp(1, 90) * 60.0,
    cyclesBeforeLongBreak: settings.cyclesBeforeLongBreak.clamp(1, 12),
  );

  final double focus;
  final double shortBreak;
  final double longBreak;
  final int cyclesBeforeLongBreak;

  double length(FocusPhase phase) => switch (phase) {
    FocusPhase.focus => focus,
    FocusPhase.shortBreak => shortBreak,
    FocusPhase.longBreak => longBreak,
  };
}

/// The phase that's running.
class FocusRun {
  const FocusRun({required this.phase, required this.startedAt, required this.duration, required this.cycle});
  final FocusPhase phase;
  final DateTime startedAt;
  final double duration;

  /// 1-based focus block number.
  final int cycle;

  DateTime get endsAt => startedAt.add(Duration(microseconds: (duration * 1e6).round()));
}

sealed class FocusTransition {
  const FocusTransition();
}

/// A phase began (the first focus block, a break, the next focus block).
class FocusStarted extends FocusTransition {
  const FocusStarted(this.phase, this.cycle);
  final FocusPhase phase;
  final int cycle;

  @override
  bool operator ==(Object other) => other is FocusStarted && other.phase == phase && other.cycle == cycle;

  @override
  int get hashCode => Object.hash(phase, cycle);

  @override
  String toString() => 'started(${phase.name}, $cycle)';
}

/// A focus block ran to its end.
class FocusCompleted extends FocusTransition {
  const FocusCompleted(this.block);
  final FocusBlock block;

  @override
  bool operator ==(Object other) => other is FocusCompleted && other.block == block;

  @override
  int get hashCode => block.hashCode;

  @override
  String toString() => 'completed($block)';
}

/// The long break ended: the whole set is done.
class FocusFinished extends FocusTransition {
  const FocusFinished(this.blocks);
  final int blocks;

  @override
  bool operator ==(Object other) => other is FocusFinished && other.blocks == blocks;

  @override
  int get hashCode => blocks.hashCode;

  @override
  String toString() => 'finished($blocks)';
}

/// The user stopped the session.
class FocusStopped extends FocusTransition {
  const FocusStopped();

  @override
  bool operator ==(Object other) => other is FocusStopped;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'stopped';
}

/// The current phase ended long ago (the computer was asleep): the session ends quietly and nothing is counted for
/// the unseen time.
class FocusExpired extends FocusTransition {
  const FocusExpired();

  @override
  bool operator ==(Object other) => other is FocusExpired;

  @override
  int get hashCode => 2;

  @override
  String toString() => 'expired';
}

/// The focus buddy's phase machine: focus → short break → focus … with a long break after every
/// `cyclesBeforeLongBreak` focus blocks; the set is done when the long break ends. Pure: the app feeds it the time and
/// acts on the transitions it returns.
class FocusTimer {
  FocusTimer(this.durations);

  /// A phase whose end is noticed later than this (seconds) is treated as slept through.
  static const double staleAfter = 10 * 60;

  FocusDurations durations;
  FocusRun? _running;
  int _completedBlocks = 0;

  FocusRun? get running => _running;

  /// Focus blocks completed in this session (skipped ones don't count).
  int get completedBlocks => _completedBlocks;

  bool get isRunning => _running != null;

  /// The world's view of the session; Mochi naps through focus blocks when [naps] is on.
  FocusStatus? status({required bool naps}) {
    final r = _running;
    if (r == null) return null;
    return FocusStatus(
      phase: r.phase,
      petNaps: naps && r.phase == FocusPhase.focus,
      startedAt: r.startedAt,
      duration: r.duration,
      cycle: r.cycle,
    );
  }

  /// Starts a new session with the first focus block (restarts a running one).
  List<FocusTransition> start(DateTime date) {
    _completedBlocks = 0;
    _running = FocusRun(phase: FocusPhase.focus, startedAt: date, duration: durations.focus, cycle: 1);
    return const [FocusStarted(FocusPhase.focus, 1)];
  }

  List<FocusTransition> stop(DateTime date) {
    if (_running == null) return const [];
    _running = null;
    return const [FocusStopped()];
  }

  /// Ends the current phase now: a skipped focus block is not counted as completed.
  List<FocusTransition> skip(DateTime date) {
    final current = _running;
    if (current == null) return const [];
    return _next(current, date, completed: false);
  }

  /// Moves on when the current phase is over. Call about once a second.
  List<FocusTransition> advance(DateTime now) {
    final current = _running;
    if (current == null || now.isBefore(current.endsAt)) return const [];
    final late = now.difference(current.endsAt).inMicroseconds / 1e6;
    if (late > staleAfter) {
      _running = null;
      return const [FocusExpired()];
    }
    // Chain exactly when noticed on time, so the schedule doesn't drift; otherwise from now.
    final start = late < 2 ? current.endsAt : now;
    return _next(current, start, completed: true);
  }

  List<FocusTransition> _next(FocusRun current, DateTime date, {required bool completed}) {
    final transitions = <FocusTransition>[];
    switch (current.phase) {
      case FocusPhase.focus:
        if (completed) {
          _completedBlocks += 1;
          transitions.add(FocusCompleted(FocusBlock(endedAt: current.endsAt, minutes: current.duration / 60)));
        }
        final phase = current.cycle % durations.cyclesBeforeLongBreak == 0 ? FocusPhase.longBreak : FocusPhase.shortBreak;
        _running = FocusRun(phase: phase, startedAt: date, duration: durations.length(phase), cycle: current.cycle);
        transitions.add(FocusStarted(phase, current.cycle));
      case FocusPhase.shortBreak:
        _running = FocusRun(phase: FocusPhase.focus, startedAt: date, duration: durations.focus, cycle: current.cycle + 1);
        transitions.add(FocusStarted(FocusPhase.focus, current.cycle + 1));
      case FocusPhase.longBreak:
        _running = null;
        transitions.add(FocusFinished(_completedBlocks));
    }
    return transitions;
  }

  /// The notification for a break, if the user asked for banners.
  static BannerContent breakBanner(FocusPhase phase, {required String petName}) => BannerContent(
    title: phase == FocusPhase.longBreak ? 'Long break!' : 'Stretch break!',
    body: '$petName is awake. Stand up, stretch and rest your eyes.',
  );
}

/// The completed focus blocks, for the daily recap (the Mac's focus-log.json without the file: the host saves
/// [toJson] when it changes and loads it with [load]). Only blocks that ran to the end are recorded. It follows the
/// history retention: older blocks are dropped, and with 0 days it lives in memory only.
class FocusLog {
  FocusLog({this.retentionDays = 7});

  /// Days to keep; 0 keeps blocks for this run only (don't save then).
  int retentionDays;
  final List<FocusBlock> _blocks = [];

  List<FocusBlock> get blocks => List.unmodifiable(_blocks);

  /// Whether the host should keep the log on disk.
  bool get persists => retentionDays > 0;

  /// Replaces the blocks with saved ones (unusable entries and old blocks dropped).
  void load(Object? json, {required DateTime now}) {
    _blocks.clear();
    if (retentionDays <= 0 || json is! List) return;
    for (final entry in json) {
      final block = FocusBlock.fromJson(entry);
      if (block != null && block.minutes > 0 && block.minutes.isFinite) _blocks.add(block);
    }
    _sort();
    _prune(now);
  }

  void append(FocusBlock block, {required DateTime now}) {
    if (!(block.minutes > 0) || !block.minutes.isFinite) return;
    _blocks.add(block);
    _sort();
    _prune(now);
  }

  /// Blocks that ended from [start] to [end], both included (Swift's `DateInterval.contains`).
  List<FocusBlock> blocksIn(DateTime start, DateTime end) =>
      _blocks.where((b) => !b.endedAt.isBefore(start) && !b.endedAt.isAfter(end)).toList();

  void clear() => _blocks.clear();

  /// Re-applies retention now (e.g. after the user changes it).
  void enforceRetention(DateTime now) => _prune(now);

  List<Object?> toJson() => [for (final b in _blocks) b.toJson()];

  void _sort() {
    // Stable, like Swift's sort for these keys.
    final indexed = _blocks.indexed.toList()
      ..sort((a, b) {
        final c = a.$2.endedAt.compareTo(b.$2.endedAt);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    _blocks
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
  }

  void _prune(DateTime now) {
    if (retentionDays > 0) {
      final cutoff = now.subtract(Duration(days: retentionDays));
      _blocks.removeWhere((b) => b.endedAt.isBefore(cutoff));
    }
    if (_blocks.length > 2000) _blocks.removeRange(0, _blocks.length - 2000);
  }
}

/// The focus buddy (the Mac's FocusController without its window and menus): runs a [FocusTimer], tells the world
/// when Mochi naps, logs completed blocks for the recap, and shows each transition the way the Mac does. Call [tick]
/// about once a second while it runs (the world's 4 Hz tick is fine; it's cheap).
class FocusBuddy {
  FocusBuddy(this.world, {FocusSettings settings = const FocusSettings(), FocusLog? log, this.computer = 'Mac'})
    : _settings = settings,
      log = log ?? FocusLog(),
      timer = FocusTimer(FocusDurations.fromSettings(settings));

  final MochiWorld world;
  final FocusTimer timer;

  /// Completed blocks, for the daily recap.
  final FocusLog log;

  /// How the toasts name this computer ("Mac" or "PC").
  String computer;

  FocusSettings _settings;
  FocusSettings get settings => _settings;

  /// New settings apply to the next session (naps and sounds at once).
  set settings(FocusSettings value) {
    _settings = value;
    if (timer.isRunning) _publish();
  }

  /// Bumped on every transition so follow-up beats of an old one never play.
  int _beat = 0;
  final List<({double at, int beat, PetAnimation animation})> _later = [];

  /// What the last transition showed (for tests and logs).
  FeatureMoment? lastMoment;

  bool get isRunning => timer.isRunning;

  /// Starts a focus session, or stops the running one.
  void toggle() => isRunning ? stop() : begin();

  /// [durations] defaults to the settings (a development shortcut can pass seconds instead).
  void begin({FocusDurations? durations}) {
    timer.durations = durations ?? FocusDurations.fromSettings(_settings);
    _apply(timer.start(world.date));
  }

  void stop() => _apply(timer.stop(world.date));

  void skip() => _apply(timer.skip(world.date));

  /// For a menu item: "Start Focus" or "Stop Focus (Break 4:12 left)".
  String get menuTitle {
    final status = world.focus;
    if (status == null) return 'Start Focus';
    return 'Stop Focus (${status.phase.title} ${focusClock(status.remaining(world.date))} left)';
  }

  void tick() {
    final now = world.now;
    if (_later.isNotEmpty) {
      final due = _later.where((l) => l.at <= now).toList();
      _later.removeWhere((l) => l.at <= now);
      for (final l in due) {
        if (l.beat == _beat && (timer.running?.phase.isBreak ?? false)) world.playPet(l.animation);
      }
    }
    if (!timer.isRunning) return;
    final transitions = timer.advance(world.date);
    if (transitions.isEmpty) {
      _publish();
    } else {
      _apply(transitions);
    }
  }

  void _apply(List<FocusTransition> transitions) {
    final wasNapping = world.focus?.petNaps ?? false;
    for (final t in transitions) {
      if (t is FocusCompleted) log.append(t.block, now: world.date);
    }
    _publish();
    _beat += 1;
    _later.clear();
    final moment = momentFor(
      transitions,
      settings: _settings,
      durations: timer.durations,
      running: timer.running,
      wasNapping: wasNapping,
      petName: world.settings.petName,
      computer: computer,
    );
    lastMoment = moment;
    moment?.applyTo(world);
    final last = transitions.isEmpty ? null : transitions.last;
    if (last is FocusStarted && last.phase.isBreak) {
      // Mochi wakes, stretches, then gets playful for the break.
      final now = world.now;
      _later.add((at: now + 1.3, beat: _beat, animation: PetAnimation.stretch));
      _later.add((at: now + 4.2, beat: _beat, animation: PetAnimation.play));
    }
  }

  /// The world sees the phase; Mochi's base loop sleeps through focus blocks when naps are on.
  void _publish() => world.updateFocus(timer.status(naps: _settings.napsDuringFocus));

  /// "5 minutes" (or seconds, for very short test durations).
  static String length(double seconds) {
    final minutes = (seconds / 60).round();
    if (minutes >= 1) return minutes == 1 ? '1 minute' : '$minutes minutes';
    return '${seconds.round()} seconds';
  }

  /// What the Mac shows for a step's transitions (null when there's nothing to show). A break's wake-up is the pet
  /// animation here; [FocusBuddy] adds the stretch (1.3 s) and play (4.2 s) after it.
  static FeatureMoment? momentFor(
    List<FocusTransition> transitions, {
    required FocusSettings settings,
    required FocusDurations durations,
    required FocusRun? running,
    required bool wasNapping,
    required String petName,
    String computer = 'Mac',
  }) {
    if (transitions.contains(const FocusStopped())) {
      return FeatureMoment(line: const FeatureLine('Okay! Back to playing.', duration: 3.5), pet: wasNapping ? PetAnimation.wakeUp : null);
    }
    if (transitions.contains(const FocusExpired())) {
      return FeatureMoment(
        toast: FeatureToast('Focus session ended', "Your $computer was asleep when the block ended, so it wasn't counted.", seconds: 8),
        pet: wasNapping ? PetAnimation.wakeUp : null,
      );
    }
    if (transitions.isEmpty) return null;
    final last = transitions.last;
    if (last is FocusFinished) {
      final blocks = last.blocks;
      final minutes = (blocks * durations.focus / 60).round();
      return FeatureMoment(
        toast: FeatureToast(
          'Focus set complete!',
          '$blocks focus ${blocks == 1 ? 'block' : 'blocks'} · $minutes minutes. Well done!',
          seconds: 8,
        ),
        line: const FeatureLine('We did it! Time for a proper rest.'),
        pet: PetAnimation.excitedJump,
        companion: CompanionAnimation.celebrate,
        sound: settings.chimeAtBreak ? SoundCue.celebration : null,
      );
    }
    if (last is! FocusStarted) return null;
    final cycle = last.cycle;
    final naps = settings.napsDuringFocus;
    switch (last.phase) {
      case FocusPhase.focus when cycle == 1:
        return FeatureMoment(
          toast: FeatureToast('Focus · ${length(durations.focus)}', '$petName wakes you for a stretch break.'),
          line: FeatureLine(naps ? "Focus time. I'll nap right here." : "Focus time. I'll keep you company."),
          pet: naps ? PetAnimation.yawn : PetAnimation.nod,
          companion: CompanionAnimation.nod,
        );
      case FocusPhase.focus:
        return FeatureMoment(
          toast: FeatureToast('Back to focus', 'Block $cycle of ${durations.cyclesBeforeLongBreak}.'),
          line: FeatureLine(naps ? 'Back to it! Wake me at the break.' : "Back to it! You've got this."),
          pet: naps ? PetAnimation.yawn : null,
          sound: settings.chimeAtBreak ? SoundCue.greeting : null,
        );
      case FocusPhase.shortBreak || FocusPhase.longBreak:
        final long = last.phase == FocusPhase.longBreak;
        final breakLength = length(running?.duration ?? 300);
        return FeatureMoment(
          toast: FeatureToast(
            long ? 'Long break!' : 'Stretch break!',
            long ? '$cycle focus blocks done · $breakLength to recharge.' : 'Focus block $cycle done · $breakLength break.',
            seconds: 8,
          ),
          line: FeatureLine(long ? 'Long break! Get some water and look outside.' : 'Stretch break! Stand up and wiggle with me.'),
          pet: PetAnimation.wakeUp,
          companion: CompanionAnimation.greet,
          sound: settings.chimeAtBreak ? SoundCue.success : null,
          banner: settings.bannerAtBreak ? FocusTimer.breakBanner(last.phase, petName: petName) : null,
        );
    }
  }
}
