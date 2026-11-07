// Patch, Mochi's coding companion (the little pixel Claude at the desk), as the Mac's CompanionWorld runs him
// (Sources/TamagotchiCore/World/CompanionWorld.swift: `updatePresence`, `updateBases`; Mapping/EventToAnimationMapper;
// Interactions/InteractionScheduler.swift):
//
// - He's around while a Claude Code session is open and for a while after the last one ends (Settings › Characters:
//   "Show Patch", "Stays … after the last session ends"), always, or never. He arrives with a welcome for Mochi, packs
//   up when a session ends, and leaves when his time is up.
// - At his desk he does what Claude does: thinks, types, reads, searches, watches a command, browses, hands work to
//   helpers, waits with you when Claude needs you, idles between turns, and naps after a quiet while (Settings ›
//   Characters: "Naps after…").
// - Claude's moments: a finished turn is a high five with Mochi (a victory dance after a long one, a tiny trophy when a
//   build or test passed) and a burst of confetti; a turn that ends with an error worries him.
// - Now and then, with nothing urgent going on, he and Mochi do something together: a coffee delivery, show and tell,
//   a ball, rock-paper-scissors, keeping watch while Mochi naps… (the Mac's ambient interactions, with their weights,
//   cooldowns and daily caps), played from the recordings in assets/pose_tracks.json.deflate.
//
// One director serves both of Patch's places, the taskbar (beside Mochi, ui/pet/taskbar_stroll.dart) and the room in
// Mochi's window (ui/pet/room_view.dart); only one shows at a time. Times are seconds on the director's clock.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';

import '../../core/desktop_settings.dart';
import '../../core/pet_cues.dart';
import '../../core/session_store.dart';
import '../../core/sessions.dart';

/// An ambient interaction's rules (the Mac's `InteractionDefinition.ambient`).
@immutable
class AmbientInteraction {
  const AmbientInteraction(this.id, {required this.weight, required this.cooldown, required this.dailyCap, required this.whileWorking, this.minimumIdle = 0});

  final InteractionID id;
  final double weight;

  /// Seconds before it may play again.
  final double cooldown;
  final int dailyCap;

  /// It may play while Claude works (otherwise only while Claude is idle).
  final bool whileWorking;

  /// Seconds since the last real news or a pet it needs.
  final double minimumIdle;

  static const List<AmbientInteraction> all = [
    AmbientInteraction(InteractionID.coffeeDelivery, weight: 3, cooldown: 25 * 60, dailyCap: 6, whileWorking: true),
    AmbientInteraction(InteractionID.showCode, weight: 2.5, cooldown: 18 * 60, dailyCap: 6, whileWorking: true),
    AmbientInteraction(InteractionID.ballDistraction, weight: 2, cooldown: 15 * 60, dailyCap: 6, whileWorking: true, minimumIdle: 30),
    AmbientInteraction(InteractionID.rockPaperScissors, weight: 2, cooldown: 20 * 60, dailyCap: 5, whileWorking: false, minimumIdle: 60),
    AmbientInteraction(InteractionID.sleepWatch, weight: 1.4, cooldown: 50 * 60, dailyCap: 3, whileWorking: false, minimumIdle: 4 * 60),
    AmbientInteraction(InteractionID.chairSteal, weight: 0.35, cooldown: 3 * 3600, dailyCap: 1, whileWorking: false, minimumIdle: 90),
    AmbientInteraction(InteractionID.keyboardNap, weight: 0.35, cooldown: 3 * 3600, dailyCap: 1, whileWorking: false, minimumIdle: 3 * 60),
    AmbientInteraction(InteractionID.mysteryOrb, weight: 0.3, cooldown: 4 * 3600, dailyCap: 1, whileWorking: false, minimumIdle: 60),
  ];
}

/// What Claude is doing, for the ambient interactions (the Mac's `AmbientActivity`).
enum ClaudeActivity { idle, working, waiting }

class CompanionDirector extends ChangeNotifier {
  CompanionDirector({
    required this.sessions,
    required this.settings,
    required Stream<PetCue> cues,
    DateTime Function()? lastActivity,
    double Function()? clock,
    math.Random? random,
    bool Function()? reducedMotion,
    bool Function()? petAsleep,
    this.tick = const Duration(seconds: 5),
  }) : _lastActivity = lastActivity,
       _petAsleep = petAsleep,
       _clock = clock ?? _monotonic(),
       _random = random ?? math.Random(),
       _reducedMotion = reducedMotion ?? (() => false) {
    _hadLive = sessions.live.isNotEmpty;
    // Already around at launch (a session open, or "Always"): no arrival, as on the Mac.
    _present = _wanted(sessions.now);
    _base = _loop(sessions.now);
    _nextAmbientAt = time + 45;
    sessions.addListener(_update);
    settings.addListener(_settingsChanged);
    _subscriptions
      ..add(cues.listen(_cue))
      ..add(sessions.transitions.listen(_transition));
    _timer = Timer.periodic(tick, (_) => _update());
  }

  final SessionStore sessions;
  final DesktopSettings settings;

  /// How often presence, naps and the ambient interactions are looked at again.
  final Duration tick;

  final DateTime Function()? _lastActivity;

  /// Whether Mochi is napping now (the PC's rhythm); null: after 30 quiet minutes.
  final bool Function()? _petAsleep;
  final double Function() _clock;
  final math.Random _random;
  final bool Function() _reducedMotion;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _timer;
  Timer? _departTimer;

  /// The recorded animations (lengths of the one-shots and the interactions); set once they've loaded.
  PoseLibrary? library;

  static double Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds / 1e6;
  }

  /// Seconds on the director's clock.
  double get time => _clock();

  bool _present = false;
  bool _departing = false;
  bool _hadLive = false;
  DateTime? _lastSessionEndedAt;
  CompanionAnimation _base = CompanionAnimation.idleAtDesk;
  bool _disposed = false;

  /// A one-shot over Patch's loop (arriving, packing up, celebrating, a worried look…).
  ({CompanionAnimation animation, double start})? shot;

  /// The interaction Mochi and Patch are playing, and the one waiting for Mochi to come over.
  ({InteractionID id, double start})? interaction;
  InteractionID? pending;
  double? _pendingSince;

  /// A burst of confetti (Claude finished).
  ({double start, bool big})? burst;

  // The finished turn the next "finished" cue is about.
  ({bool primary, Duration? duration, bool passed})? _lastTurn;
  final Set<String> _passedThisTurn = {};

  // The ambient schedule.
  late double _nextAmbientAt;
  final Map<InteractionID, double> _lastStarted = {};
  final List<InteractionID> _recent = [];
  final Map<InteractionID, int> _dailyCounts = {};
  int _countsDay = -1;

  /// Patch is around (settled in, not on his way out).
  bool get present => _present && !_departing;

  /// Patch is on his way out (packing up and leaving): still drawn until he's gone.
  bool get departing => _departing;

  /// Patch is drawn: around, or leaving.
  bool get visible => _present;

  /// Patch's loop right now.
  CompanionAnimation get loop => _base;

  /// What Claude is doing in the primary session.
  ClaudeActivity get activity {
    final session = sessions.primary;
    final now = sessions.now;
    if (session == null || !session.isLive || session.isStale(now)) return ClaudeActivity.idle;
    if (session.phase == SessionPhase.waitingForUser) return ClaudeActivity.waiting;
    return session.phase.isWorking ? ClaudeActivity.working : ClaudeActivity.idle;
  }

  // MARK: Presence

  /// Settings › Characters › "Show Patch": while Claude Code is active (and a while after), always, or never.
  bool _wanted(DateTime now) => switch (settings.companionVisibility) {
    CompanionVisibility.always => true,
    CompanionVisibility.never => false,
    CompanionVisibility.duringSessions =>
      sessions.live.isNotEmpty ||
          (_lastSessionEndedAt != null && now.difference(_lastSessionEndedAt!) < Duration(minutes: settings.companionLingerMinutes)),
  };

  /// Patch's loop for the primary session (`EventToAnimationMapper.companionLoop`).
  CompanionAnimation _loop(DateTime now) {
    final session = sessions.primary;
    if (session == null) return CompanionAnimation.idleAtDesk;
    final sleepy = now.difference(session.lastEventAt) > Duration(minutes: settings.companionSleepAfterMinutes);
    if (session.isStale(now)) return ClaudeLoops.companionLoop('idle', sleepy: sleepy);
    return switch (session.phase) {
      SessionPhase.promptSubmitted || SessionPhase.thinking => ClaudeLoops.companionLoop(
        'working',
        category: 'think',
        helpers: session.activeSubagents.isNotEmpty && session.phase == SessionPhase.thinking,
      ),
      SessionPhase.runningTool => ClaudeLoops.companionLoop('working', category: session.currentTool?.category),
      SessionPhase.waitingForUser => ClaudeLoops.companionLoop('waiting'),
      SessionPhase.ended => ClaudeLoops.companionLoop('ended', sleepy: sleepy),
      _ => ClaudeLoops.companionLoop('idle', sleepy: sleepy),
    };
  }

  void _settingsChanged() {
    if (settings.pauseReactions) {
      shot = null;
      interaction = null;
      pending = null;
      burst = null;
    }
    _update();
  }

  /// Looks at the sessions, the settings and the time again: who's around, Patch's loop, the ambient schedule.
  void _update() {
    if (_disposed) return;
    final now = sessions.now;
    final t = time;
    var changed = false;
    final live = sessions.live.isNotEmpty;
    if (_hadLive && !live) _lastSessionEndedAt = now;
    _hadLive = live;
    final wanted = _wanted(now);
    final quiet = settings.pauseReactions;
    if (wanted && (!_present || _departing)) {
      _present = true;
      _departing = false;
      _departTimer?.cancel();
      _base = _loop(now);
      if (_base == CompanionAnimation.sleep) _base = CompanionAnimation.idleAtDesk;
      shot = null;
      // He arrives with a hello for Mochi (the welcome), or on his own if that can't play.
      if (!quiet) {
        if (library?.interactionTrack(InteractionID.welcome) != null) {
          _request(InteractionID.welcome, t);
        } else {
          shot = (animation: CompanionAnimation.arrive, start: t);
        }
      }
      changed = true;
    } else if (!wanted && _present && !_departing) {
      if (quiet) {
        _gone();
      } else {
        _departing = true;
        interaction = null;
        pending = null;
        shot = (animation: CompanionAnimation.depart, start: t);
        _departTimer?.cancel();
        _departTimer = Timer(Duration(microseconds: (_length(CompanionAnimation.depart) * 1e6).round()), () {
          if (_departing) {
            _gone();
            _notify();
          }
        });
      }
      changed = true;
    }
    if (_present && !_departing) {
      final loop = _loop(now);
      if (loop != _base) {
        // Waking from a nap: a stretch and a blink first.
        if (_base == CompanionAnimation.sleep && !_playingShot(t) && !quiet) {
          shot = (animation: CompanionAnimation.wakeUp, start: t);
        }
        _base = loop;
        changed = true;
      }
      if (_ambient(t, now)) changed = true;
    }
    if (_endFinished(t)) changed = true;
    if (changed) _notify();
  }

  void _gone() {
    _present = false;
    _departing = false;
    _departTimer?.cancel();
    shot = null;
    interaction = null;
    pending = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  double _length(CompanionAnimation animation) =>
      library?.companionTrack(animation)?.length ??
      switch (animation) {
        CompanionAnimation.depart => 1.4,
        CompanionAnimation.packUp => 2.0,
        CompanionAnimation.arrive => 1.8,
        _ => 1.5,
      };

  /// Mochi and Patch are in the middle of a moment together (or Mochi is on its way over for one).
  bool _together(double t) => pending != null || scene(t) != null;

  bool _playingShot(double t) {
    final current = shot;
    return current != null && t - current.start < _length(current.animation);
  }

  /// Drops a one-shot or an interaction that has played out.
  bool _endFinished(double t) {
    var changed = false;
    final current = interaction;
    if (current != null) {
      final length = library?.interactionTrack(current.id)?.length ?? 0;
      if (t - current.start >= length) {
        interaction = null;
        changed = true;
      }
    }
    if (shot != null && !_playingShot(t)) shot = null;
    final b = burst;
    if (b != null && t - b.start >= CelebrationArt.length) burst = null;
    // A visit Mochi never came to (it couldn't get over): let it go.
    if (pending != null && _pendingSince != null && t - _pendingSince! > 12) {
      pending = null;
      changed = true;
    }
    return changed;
  }

  // MARK: Claude's moments

  void _transition(SessionTransition transition) {
    if (transition.delivery == Delivery.late) return;
    final session = transition.session;
    switch (transition.kind) {
      case EventKind.promptSubmitted:
        _passedThisTurn.remove(session.id);
      case EventKind.toolSucceeded || EventKind.report:
        final result = session.lastBuildTest?.toLowerCase() ?? '';
        if (result.contains('passed') || result.contains('succeeded')) _passedThisTurn.add(session.id);
      case EventKind.turnCompleted:
        _lastTurn = (
          primary: identical(session, sessions.primary),
          duration: transition.turnDuration,
          passed: _passedThisTurn.remove(session.id),
        );
      case EventKind.sessionEnded:
        // Packing up (and he stays a while, resting, unless that was the last session and he's leaving now).
        if (present && !settings.pauseReactions && identical(session, sessions.primary)) {
          shot = (animation: CompanionAnimation.packUp, start: time);
        }
      default:
        break;
    }
    // Real news pushes the ambient interactions back (`postpone`).
    _nextAmbientAt = math.max(_nextAmbientAt, time + 30);
  }

  void _cue(PetCue cue) {
    if (_disposed || settings.pauseReactions) return;
    final t = time;
    switch (cue) {
      case PetCue.finished:
        final turn = _lastTurn;
        _lastTurn = null;
        final long = (turn?.duration ?? Duration.zero) >= const Duration(minutes: 10);
        final passed = turn?.passed ?? false;
        burst = (start: t, big: long || passed);
        if (present && (turn?.primary ?? true)) {
          _request(
            passed
                ? InteractionID.trophyCelebration
                : long
                ? InteractionID.victoryDance
                : InteractionID.highFive,
            t,
          );
        }
      case PetCue.snag || PetCue.worry:
        if (present && !_together(t)) shot = (animation: CompanionAnimation.concerned, start: t);
      case PetCue.cheer:
        if (present && !_together(t)) shot = (animation: CompanionAnimation.nod, start: t);
      case PetCue.greet:
        if (present && !_together(t)) shot = (animation: CompanionAnimation.greet, start: t);
      case PetCue.needsYou:
        // He looks up from the laptop and waves, then waits with you.
        if (present && !_together(t)) shot = (animation: CompanionAnimation.greet, start: t);
      case PetCue.pet:
        if (present && !_together(t)) shot = (animation: CompanionAnimation.pat, start: t);
      case PetCue.replied:
        if (present && !_together(t)) shot = (animation: CompanionAnimation.nod, start: t);
      default:
        break;
    }
    if (cue == PetCue.pet || cue == PetCue.play || cue == PetCue.treat) _nextAmbientAt = math.max(_nextAmbientAt, t + 30);
    _notify();
  }

  /// You clicked Patch: he waves back.
  void greet() {
    final t = time;
    if (!present || _together(t) || settings.pauseReactions) return;
    shot = (animation: CompanionAnimation.greet, start: t);
    _notify();
  }

  // MARK: Interactions

  /// Asks for [id]: it waits for Mochi to come over ([startPending]).
  void _request(InteractionID id, double t) {
    if (library != null && library!.interactionTrack(id) == null) return;
    pending = id;
    _pendingSince = t;
    interaction = null;
    shot = null;
  }

  /// Mochi is beside Patch: the waiting interaction starts now.
  void startPending([double? at]) {
    final id = pending;
    if (id == null) return;
    pending = null;
    _pendingSince = null;
    interaction = (id: id, start: at ?? time);
    _lastStarted[id] = interaction!.start;
    _remember(id);
    _nextAmbientAt = math.max(_nextAmbientAt, interaction!.start + 60);
    _notify();
  }

  /// How long [id] lasts (seconds; 0 when it wasn't recorded).
  double lengthOf(InteractionID id) => library?.interactionTrack(id)?.length ?? 0;

  /// The interaction's frame at [t] (Mochi's and Patch's poses, their `x` in path units, and the props), while one
  /// plays.
  SceneFrame? scene(double t) {
    final current = interaction;
    final track = current == null ? null : library?.interactionTrack(current.id);
    if (current == null || track == null) return null;
    final elapsed = t - current.start;
    if (elapsed < 0 || elapsed >= track.length) return null;
    return track.at(elapsed);
  }

  /// Seconds into the confetti burst at [t], while it lasts.
  double? burstAt(double t) {
    final b = burst;
    if (b == null) return null;
    final elapsed = t - b.start;
    return elapsed >= 0 && elapsed < CelebrationArt.length ? elapsed : null;
  }

  /// The Mac's ambient scheduler (`InteractionScheduler.nextInteraction`): every couple of minutes or so, when nothing
  /// else is going on, maybe something together.
  bool _ambient(double t, DateTime now) {
    if (t < _nextAmbientAt || settings.pauseReactions) return false;
    final activity = this.activity;
    final busy = interaction != null || pending != null || _playingShot(t);
    final idleFor = now.difference(_lastActivity?.call() ?? sessions.lastEventAt ?? now).inMilliseconds / 1000;
    // Mochi naps while the PC rests (or after 30 quiet minutes): no games then.
    final asleep = _petAsleep?.call() ?? idleFor >= 30 * 60;
    if (activity == ClaudeActivity.waiting || busy || asleep) return false;
    final day = DateTime(now.year, now.month, now.day).difference(DateTime(2000)).inDays;
    if (day != _countsDay) {
      _countsDay = day;
      _dailyCounts.clear();
    }
    final eligible = [
      for (final rule in AmbientInteraction.all)
        if ((activity == ClaudeActivity.idle || rule.whileWorking) &&
            idleFor >= rule.minimumIdle &&
            (_lastStarted[rule.id] == null || t - _lastStarted[rule.id]! >= rule.cooldown) &&
            (_dailyCounts[rule.id] ?? 0) < rule.dailyCap &&
            !_recent.reversed.take(2).contains(rule.id) &&
            (library == null || library!.interactionTrack(rule.id) != null))
          rule,
    ];
    final gap = 150 * (_reducedMotion() ? 1.5 : 1.0) * (0.7 + 0.6 * _random.nextDouble());
    _nextAmbientAt = t + gap;
    final total = eligible.fold<double>(0, (sum, rule) => sum + rule.weight);
    if (total <= 0) return false;
    var roll = _random.nextDouble() * total;
    var chosen = eligible.last;
    for (final rule in eligible) {
      roll -= rule.weight;
      if (roll <= 0) {
        chosen = rule;
        break;
      }
    }
    _dailyCounts[chosen.id] = (_dailyCounts[chosen.id] ?? 0) + 1;
    _request(chosen.id, t);
    return true;
  }

  void _remember(InteractionID id) {
    _recent.add(id);
    if (_recent.length > 4) _recent.removeAt(0);
  }

  // MARK: Drawing

  /// Patch's pose at [t]: the interaction's, a one-shot's, or his loop's (calmer with animations off).
  CompanionPose pose(PoseLibrary? library, double t, {bool calm = false}) {
    final frame = scene(t);
    if (frame != null) return frame.companion;
    if (library == null) return CompanionPose();
    final current = shot;
    if (current != null) {
      final track = library.companionTrack(current.animation);
      if (track != null && t - current.start < track.length) return track.calmed(t - current.start, calm: calm, oneShot: true);
    }
    // Leaving: the last frame of the depart holds (he's off the desk) until he's gone.
    if (_departing) return library.companionTrack(CompanionAnimation.depart)?.at(double.infinity) ?? CompanionPose();
    final loop = library.companionTrack(_base);
    return loop == null ? CompanionPose() : loop.calmed(t, calm: calm);
  }

  /// He's waiting with you (Claude needs you).
  bool get waiting => _present && !_departing && _base == CompanionAnimation.waiting;

  /// Something is playing that needs smooth frames (a one-shot, an interaction, the burst).
  bool busyAt(double t) => scene(t) != null || _playingShot(t) || burstAt(t) != null || pending != null;

  /// Frames a second Patch needs at [t]: 24 for a moment, 12 at work (the screen scrolls), 10 idle (blinks), 6 asleep.
  double frameRate(double t) {
    if (!visible) return 0;
    if (busyAt(t)) return 24;
    return switch (_base) {
      CompanionAnimation.sleep || CompanionAnimation.rest || CompanionAnimation.offline => 6,
      CompanionAnimation.idleAtDesk || CompanionAnimation.waiting => 10,
      _ => 12,
    };
  }

  /// What a screen reader says about him ("Patch is typing at his desk").
  String describe(String name) {
    if (!visible) return '$name is away';
    if (_departing) return '$name is heading off';
    final current = interaction;
    if (current != null) return '$name and Mochi: ${current.id.title.toLowerCase()}';
    return switch (_base) {
      CompanionAnimation.idleAtDesk => '$name is at his desk',
      CompanionAnimation.thinking => '$name is thinking',
      CompanionAnimation.typing => '$name is typing at his desk',
      CompanionAnimation.reading => '$name is reading',
      CompanionAnimation.searching => '$name is searching',
      CompanionAnimation.runningCommand => '$name is watching a command run',
      CompanionAnimation.browsing => '$name is browsing the web',
      CompanionAnimation.delegating => '$name is handing work to helpers',
      CompanionAnimation.waiting => '$name is waiting for you',
      CompanionAnimation.rest => '$name is resting',
      CompanionAnimation.sleep => '$name is napping at his desk',
      final other => '$name is ${other.title.toLowerCase()}',
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _departTimer?.cancel();
    sessions.removeListener(_update);
    settings.removeListener(_settingsChanged);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
