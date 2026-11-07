// Port of Sources/TamagotchiCore/Animation/CharacterAnimator.swift: the animation state machine for one character.

import '../model/animations.dart';
import '../model/json.dart';

/// What is playing now.
class Playing<A extends CharacterAnimationKind> {
  const Playing({
    required this.animation,
    required this.priority,
    required this.startedAt,
    this.duration,
    required this.token,
    this.scriptID,
  });

  final A animation;
  final AnimationPriority priority;
  final double startedAt;

  /// null for loops.
  final double? duration;
  final int token;

  /// Set when an interaction script drives this animation.
  final String? scriptID;

  bool isFinished(double now) {
    final duration = this.duration;
    if (duration == null) return false;
    return now >= startedAt + duration;
  }

  double elapsed(double now) => now - startedAt < 0 ? 0 : now - startedAt;

  @override
  bool operator ==(Object other) =>
      other is Playing<A> &&
      other.animation == animation &&
      other.priority == priority &&
      other.startedAt == startedAt &&
      other.duration == duration &&
      other.token == token &&
      other.scriptID == scriptID;

  @override
  int get hashCode => Object.hash(animation, priority, startedAt, duration, token, scriptID);
}

/// The outcome of [CharacterAnimator.play].
sealed class PlayResult {
  const PlayResult();
}

class PlayStarted extends PlayResult {
  const PlayStarted(this.token, this.interrupted);
  final int token;
  final int? interrupted;
}

class PlayBusy extends PlayResult {
  const PlayBusy();
}

class PlayCoolingDown extends PlayResult {
  const PlayCoolingDown();
}

class Completion<A> {
  const Completion({required this.animation, required this.token, this.scriptID, required this.finished});
  final A animation;
  final int token;
  final String? scriptID;

  /// False when the animation was replaced or cancelled before finishing.
  final bool finished;
}

/// The animation state machine for one character.
///
/// There is always exactly one thing playing: either the current base loop or a one-shot on top of it. One-shots end on
/// their own and fall back to whatever the base is at that moment, so a character can never get stuck in an old pose.
/// Each start gets a token; completions report it so obsolete callbacks can be ignored.
class CharacterAnimator<A extends CharacterAnimationKind> {
  CharacterAnimator({required A base, required double at})
    : _base = base,
      _current = Playing(animation: base, priority: AnimationPriority.base, startedAt: at, token: 1),
      _nextToken = 2;

  Playing<A> _current;
  A _base;
  int _nextToken;
  final Map<A, double> _lastStarted = {};

  Playing<A> get current => _current;
  A get base => _base;

  bool get isPlayingOneShot => _current.duration != null;

  /// Starts a one-shot (or a scripted segment) on top of the base.
  PlayResult play(
    A animation, {
    required AnimationPriority priority,
    required double at,
    double? duration,
    String? scriptID,
    bool ignoreCooldown = false,
  }) {
    final now = at;
    if (!ignoreCooldown && animation.cooldown > 0) {
      final last = _lastStarted[animation];
      if (last != null && now - last < animation.cooldown) return const PlayCoolingDown();
    }
    if (isPlayingOneShot && !_current.isFinished(now) && priority < _current.priority) return const PlayBusy();
    final interrupted = isPlayingOneShot && !_current.isFinished(now) ? _current.token : null;
    final token = _nextToken;
    _nextToken += 1;
    final d = duration ?? animation.defaultDuration;
    _current = Playing(
      animation: animation,
      priority: priority,
      startedAt: now,
      duration: d < 0.05 ? 0.05 : d,
      token: token,
      scriptID: scriptID,
    );
    _lastStarted[animation] = now;
    return PlayStarted(token, interrupted);
  }

  /// Changes the loop to return to. If the base is what is playing now, the switch happens immediately.
  void setBase(A animation, {required double at}) {
    if (animation == _base) return;
    _base = animation;
    if (!isPlayingOneShot) {
      _current = Playing(animation: animation, priority: AnimationPriority.base, startedAt: at, token: _nextToken);
      _nextToken += 1;
    }
  }

  /// Advances time. Returns a completion if a one-shot just ended.
  Completion<A>? update(double now) {
    if (!(isPlayingOneShot && _current.isFinished(now))) return null;
    final finished = Completion(animation: _current.animation, token: _current.token, scriptID: _current.scriptID, finished: true);
    _current = Playing(animation: _base, priority: AnimationPriority.base, startedAt: now, token: _nextToken);
    _nextToken += 1;
    return finished;
  }

  /// Cancels the given one-shot if it is still playing.
  Completion<A>? cancel(int token, {required double at}) {
    if (!(isPlayingOneShot && _current.token == token)) return null;
    final cancelled = Completion(animation: _current.animation, token: token, scriptID: _current.scriptID, finished: false);
    _current = Playing(animation: _base, priority: AnimationPriority.base, startedAt: at, token: _nextToken);
    _nextToken += 1;
    return cancelled;
  }

  /// Cancels whatever one-shot is playing (e.g. when reactions are paused).
  Completion<A>? cancelOneShot({required double at}) => cancel(_current.token, at: at);

  // MARK: Persistence

  Map<String, Object?> toJson() => {
    'base': (_base as Enum).name,
    'current': {
      'animation': (_current.animation as Enum).name,
      'priority': _current.priority.name,
      'startedAt': _current.startedAt,
      'duration': ?_current.duration,
      'token': _current.token,
      'scriptID': ?_current.scriptID,
    },
    'nextToken': _nextToken,
    'lastStarted': {for (final e in _lastStarted.entries) (e.key as Enum).name: e.value},
  };

  /// Restores an animator written by [toJson]; `values` is the animation enum's `values`.
  static CharacterAnimator<A>? fromJson<A extends CharacterAnimationKind>(Object? json, List<A> values) {
    final j = asMap(json);
    A? named(Object? name) {
      for (final v in values) {
        if ((v as Enum).name == name) return v;
      }
      return null;
    }

    final base = named(j['base']);
    final c = asMap(j['current']);
    final animation = named(c['animation']);
    final priority = enumByName(AnimationPriority.values, c['priority']);
    if (base == null || animation == null || priority == null) return null;
    final animator = CharacterAnimator<A>(base: base, at: 0);
    animator._current = Playing(
      animation: animation,
      priority: priority,
      startedAt: dbl(c, 'startedAt', 0),
      duration: c['duration'] is num ? (c['duration'] as num).toDouble() : null,
      token: integer(c, 'token', 1),
      scriptID: string(c, 'scriptID'),
    );
    animator._nextToken = integer(j, 'nextToken', animator._current.token + 1);
    for (final e in asMap(j['lastStarted']).entries) {
      final key = named(e.key);
      if (key != null && e.value is num) animator._lastStarted[key] = (e.value as num).toDouble();
    }
    return animator;
  }
}
