// Mochi's stroll along the taskbar: where it is and what it's doing, as a timeline of segments that are pure
// functions of time (so it can be drawn at any frame rate). It follows the Mac's MenuBarRoamer
// (Sources/TamagotchiCore/Roaming/MenuBarRoamer.swift), cut down to a strip with no bed: Patch's desk is home.
//
// Mochi walks only in the taskbar's empty stretches (zones) and never over its buttons: to get to another stretch it
// fades out and back in there (a hop), as the Mac's Mochi does with Reduce Motion on.
//
// - Nothing going on (free): it wanders, sniffs about, fidgets, sits and rests (10–35 s between outings, with a glance
//   or a scratch in the middle of long rests) and sometimes naps, more the longer Claude has been quiet.
// - Claude working: it mostly sits and watches, with a short potter now and then.
// - Claude needs you: it stops where it is and faces you, waves, then sits watching you with a reminder wave a minute
//   (at most ten), as on the Mac.
// - A long quiet stretch (Mochi's napping mood): a yawn, and it sleeps where it is.
// - Animation effects off: it stays where it is, expressions only.
// - A pet, a game, a finished turn: it holds still while that plays (facing you for news), then carries on.
// - Patch around (a home: his desk is to the right of it, ui/pet/companion_director.dart): Mochi keeps him company as
//   on the Mac (`RoamMode.companion`, `.working`): it sits with him, potters a little way off and comes back, watches
//   him work, waves from beside him when Claude needs you and naps there. For a moment together (a high five, a coffee
//   delivery) it trots over and holds still while it plays (`summon`).
//
// Positions are Mochi's centre in logical pixels along the taskbar; times are seconds on the caller's clock. The plan
// reaches a couple of seconds ahead and is extended as time passes (`update`). Every choice comes from the `Random`
// it's given, so tests can seed it.

import 'dart:math' as math;

import 'package:mochi_art/mochi_art.dart' show PetAnimation;

import 'pet_director.dart' show PetMood;

/// How Mochi behaves on the taskbar, from its mood (highest rule first, as `RoamMode.from` on the Mac).
enum StrollMode {
  /// Nothing going on: the whole taskbar is Mochi's.
  free,

  /// Claude is working: Mochi sits and watches, with a short potter now and then.
  working,

  /// Claude needs you: Mochi stops, faces you and waves now and then.
  attending,

  /// A long quiet stretch: Mochi sleeps where it is.
  asleep,

  /// Animation effects are off: Mochi stays where it is.
  still;

  static StrollMode of(PetMood mood, {required bool reducedMotion}) => switch (mood) {
    PetMood.needsYou => attending,
    PetMood.napping => asleep,
    _ when reducedMotion => still,
    PetMood.watching => working,
    _ => free,
  };
}

/// What Mochi is up to.
enum StrollActivity { settle, rest, wander, sniff, fidget, nap, trot, hop, potter, watch, attend, sleep, still, react, company, visit }

/// Small accents the pose gets on top of its animation.
enum StrollStyle {
  plain,

  /// Ears up, looking the way it's about to go: a turn.
  notice,

  /// Facing you, eyes open, ears up: Claude needs you, or a turn just finished.
  attentive,
}

/// Where Mochi's centre may go.
class StrollLine {
  const StrollLine(this.minX, this.maxX);

  final double minX;
  final double maxX;

  double clamp(double x) => x.clamp(minX, math.max(minX, maxX));

  @override
  bool operator ==(Object other) => other is StrollLine && other.minX == minX && other.maxX == maxX;

  @override
  int get hashCode => Object.hash(minX, maxX);

  @override
  String toString() => 'StrollLine($minX…$maxX)';
}

/// Speeds (logical pixels a second) and timings.
class StrollTuning {
  const StrollTuning({
    this.walkSpeed = 46,
    this.trotSpeed = 96,
    this.walkGait = 58,
    this.runGait = 125,
    this.ease = 0.35,
    this.restScale = 1,
  });

  /// An amble: a 1920-pixel-wide screen in about 40 seconds.
  final double walkSpeed;
  final double trotSpeed;

  /// Distance covered per second of the walk (run) track: the legs keep pace with the ground instead of skating.
  final double walkGait;
  final double runGait;

  /// Seconds to get up to speed, and to slow down again.
  final double ease;

  /// Longer (> 1) or shorter rests between outings.
  final double restScale;
}

/// The recorded one-shots' lengths (assets/pose_tracks.json.deflate; test/stroll_test.dart checks they match).
const Map<PetAnimation, double> strollOneShotLengths = {
  PetAnimation.lookAround: 2.6,
  PetAnimation.blep: 1.4,
  PetAnimation.scratch: 2.0,
  PetAnimation.stretch: 2.6,
  PetAnimation.sniff: 1.8,
  PetAnimation.yawn: 1.8,
  PetAnimation.wakeUp: 1.2,
  PetAnimation.shake: 1.1,
  PetAnimation.nod: 0.8,
  PetAnimation.happyBounce: 1.0,
};

double _length(PetAnimation animation) => strollOneShotLengths[animation] ?? 1.5;

/// One piece of the plan: Mochi holding [animation] at [fromX], or travelling from [fromX] to [toX] (speeding up and
/// slowing down over [ease] seconds at each end).
class StrollSegment {
  const StrollSegment({
    required this.start,
    required this.end,
    required this.fromX,
    required this.toX,
    required this.animation,
    required this.facing,
    required this.activity,
    this.style = StrollStyle.plain,
    this.oneShot = false,
    this.odometer = 0,
    this.speed = 0,
    this.ease = 0,
    this.hop = false,
  });

  final double start;

  /// May be infinite: a hold that lasts until something changes.
  final double end;
  final double fromX;
  final double toX;
  final PetAnimation animation;

  /// +1 facing right, -1 facing left.
  final double facing;
  final StrollActivity activity;
  final StrollStyle style;

  /// [animation] plays once from [start] (otherwise it loops).
  final bool oneShot;

  /// Distance walked before this segment: the walk cycle is locked to it.
  final double odometer;
  final double speed;
  final double ease;

  /// Mochi fades out at [fromX] and back in at [toX] (to another stretch of the taskbar, over the buttons).
  final bool hop;

  bool get travels => toX != fromX;
  double get odometerAtEnd => odometer + (toX - fromX).abs();

  /// Mochi's centre at [t].
  double xAt(double t) {
    if (!travels || t <= start) return fromX;
    if (t >= end) return toX;
    if (hop) return t - start < (end - start) / 2 ? fromX : toX;
    final distance = (toX - fromX).abs();
    return fromX + (toX > fromX ? 1 : -1) * _covered(t - start, distance);
  }

  /// How visible Mochi is at [t]: 1, apart from the middle of a hop.
  double opacityAt(double t) {
    if (!hop || t <= start || t >= end) return 1;
    return (1 - 2 * (t - start) / (end - start)).abs();
  }

  /// A trapezoid: up to [speed] over [ease] seconds, cruise, and down again, covering [distance] by [end].
  double _covered(double u, double distance) {
    final total = end - start;
    if (speed <= 0) return distance * u / total;
    if (ease <= 0) return math.min(distance, speed * u);
    if (u < ease) return speed * u * u / (2 * ease);
    if (u <= total - ease) return speed * ease / 2 + speed * (u - ease);
    final w = total - u;
    return distance - speed * w * w / (2 * ease);
  }
}

/// What Mochi looks like at one moment of the stroll.
class StrollSample {
  const StrollSample({
    required this.x,
    required this.facing,
    required this.animation,
    required this.animationTime,
    required this.activity,
    this.oneShot = false,
    this.style = StrollStyle.plain,
    this.travelling = false,
    this.opacity = 1,
  });

  final double x;
  final double facing;
  final PetAnimation animation;

  /// Seconds into [animation]: from the segment's start for a one-shot, from the odometer for a walk (so steps land
  /// where the feet are), on the clock otherwise.
  final double animationTime;
  final bool oneShot;
  final StrollStyle style;
  final StrollActivity activity;
  final bool travelling;

  /// 1, apart from the middle of a hop.
  final double opacity;
}

/// Plans and replays Mochi's stroll.
class Stroller {
  Stroller({math.Random? random, this.tuning = const StrollTuning()}) : _random = random ?? math.Random();

  final StrollTuning tuning;
  final math.Random _random;

  /// The plan always reaches at least this far ahead (seconds).
  static const double lookahead = 2;

  /// Where Mochi keeps Patch company (his desk is to the right), or null while he isn't on the taskbar.
  double? _home;

  /// The stretches Mochi may walk in, left to right, and the one it's in (as far as the plan has got).
  List<StrollLine> _zones = const [];
  StrollLine? _line;
  StrollMode _mode = StrollMode.free;
  final List<StrollSegment> _segments = [];
  final List<StrollActivity> _recent = [];
  double _idle = 0;

  /// A reaction (or a drag) holds Mochi still until then; a mode change waits for it.
  double _holdUntil = double.negativeInfinity;
  bool _replan = false;

  // The planner's pen: where the plan being written has got to.
  double _t = 0;
  double _x = 0;
  double _facing = 1;
  double _odometer = 0;
  StrollActivity _activity = StrollActivity.settle;

  StrollLine? get line => _line;
  double? get home => _home;
  List<StrollLine> get zones => _zones;
  StrollMode get mode => _mode;
  bool get isPlaced => _line != null && _segments.isNotEmpty;
  List<StrollSegment> get segments => List.unmodifiable(_segments);

  /// Starts the stroll in [zones] at [x] (or carries on from where Mochi is), in [mode]. Carrying on from a spot
  /// that's no longer in a free stretch (the buttons moved), Mochi hops to the nearest free one. With a [home] (Patch's
  /// spot: [zones] is then the little stretch beside his desk), Mochi keeps him company.
  void place(
    List<StrollLine> zones, {
    required double now,
    double? x,
    double? facing,
    StrollMode? mode,
    double idleSeconds = 0,
    double? home,
  }) {
    if (zones.isEmpty) return clear();
    final state = _segments.isEmpty ? null : _state(now);
    _home = home;
    _zones = [...zones]..sort((a, b) => a.minX.compareTo(b.minX));
    if (mode != null) _mode = mode;
    _idle = idleSeconds;
    _segments.clear();
    _holdUntil = double.negativeInfinity;
    _replan = false;
    final from = x ?? state?.x ?? _zones.first.minX;
    final to = nearest(from);
    _pen(now, state == null || x != null ? to : from, facing ?? state?.facing ?? 1, state?.odometer ?? 0);
    if (_x != to) _hopTo(to);
    _open();
    _extend(now);
  }

  /// The free stretches changed a little (the buttons moved): Mochi carries on with its plan if all of it is still in
  /// free room, and re-plans from where it is otherwise.
  void rezone(List<StrollLine> zones, {required double now}) {
    if (zones.isEmpty) return clear();
    final sorted = [...zones]..sort((a, b) => a.minX.compareTo(b.minX));
    bool free(double x) => sorted.any((zone) => x >= zone.minX - 0.5 && x <= zone.maxX + 0.5);
    final fits = _segments.where((segment) => segment.end > now).every((segment) {
      if (!free(segment.toX) || (segment.start >= now && !free(segment.fromX))) return false;
      // A walk can't cross a button: both ends in the same stretch.
      if (segment.travels && !segment.hop) {
        return sorted.any((zone) => [segment.fromX, segment.toX].every((x) => x >= zone.minX - 0.5 && x <= zone.maxX + 0.5));
      }
      return true;
    });
    if (fits) {
      _zones = sorted;
      return;
    }
    place(sorted, now: now);
  }

  /// The nearest spot to [x] in a free stretch.
  double nearest(double x) {
    var best = _zones.first.clamp(x);
    for (final zone in _zones) {
      final spot = zone.clamp(x);
      if ((spot - x).abs() < (best - x).abs()) best = spot;
    }
    return best;
  }

  /// Off the taskbar: forgets the plan.
  void clear() {
    _zones = const [];
    _line = null;
    _home = null;
    _segments.clear();
  }

  /// A moment with Patch is about to play for [duration] seconds: Mochi trots over to its place beside him and holds
  /// still there, facing him, while it plays. Returns when Mochi gets there (null: there's no Patch to go to).
  double? summon(double now, double duration) {
    final home = _home;
    if (!isPlaced || home == null) return null;
    _cut(now);
    _activity = StrollActivity.visit;
    if ((_x - home).abs() > 1) {
      final direction = home > _x ? 1.0 : -1.0;
      if (direction != _facing) _turn(direction);
      _walk(home, speed: tuning.trotSpeed);
    }
    if (_facing != 1) _turn(1);
    final arrival = _t;
    _holdUntil = arrival + duration;
    _hold(PetAnimation.idle, duration);
    _open();
    _extend(now);
    return arrival;
  }

  /// Follows [mode] (re-planning from where Mochi is when it changes) and keeps the plan reaching ahead.
  void update(double now, {required StrollMode mode, double idleSeconds = 0}) {
    if (!isPlaced) return;
    _idle = idleSeconds;
    if (mode != _mode) {
      _mode = mode;
      _replan = true;
    }
    if (_replan && now >= _holdUntil) {
      _replan = false;
      _restart(now);
    }
    _prune(now);
    _extend(now);
  }

  /// Holds Mochi still where it is for [duration] seconds (for ever while being dragged, until [resume]), facing you
  /// if [attentive]; then it carries on.
  void react(double now, double duration, {bool attentive = false}) {
    if (!isPlaced) return;
    _cut(now);
    _activity = StrollActivity.react;
    _holdUntil = now + duration;
    final style = attentive ? StrollStyle.attentive : StrollStyle.plain;
    if (duration.isFinite) {
      _hold(PetAnimation.idle, duration, style: style);
      _open();
    } else {
      _holdForever(PetAnimation.idle, style: style);
    }
    _extend(now);
  }

  /// Ends a hold early (a drag that left Mochi where it was).
  void resume(double now) {
    if (!isPlaced) return;
    _holdUntil = double.negativeInfinity;
    _replan = false;
    _restart(now);
    _extend(now);
  }

  /// Mochi at [t].
  StrollSample sample(double t) {
    final segment = _segmentAt(t);
    if (segment == null) {
      return StrollSample(x: _line?.minX ?? 0, facing: 1, animation: PetAnimation.idle, animationTime: t, activity: _activity);
    }
    final local = math.min(math.max(t, segment.start), segment.end);
    final x = segment.xAt(local);
    final gait = switch (segment.animation) {
      PetAnimation.walk => tuning.walkGait,
      PetAnimation.run => tuning.runGait,
      _ => null,
    };
    final time = segment.oneShot
        ? local - segment.start
        : gait != null
        ? (segment.odometer + (x - segment.fromX).abs()) / gait
        : t;
    return StrollSample(
      x: x,
      facing: segment.facing,
      animation: segment.animation,
      animationTime: time,
      oneShot: segment.oneShot,
      style: segment.style,
      activity: segment.activity,
      travelling: segment.travels && t >= segment.start && t < segment.end,
      opacity: segment.opacityAt(t),
    );
  }

  bool travellingAt(double t) => sample(t).travelling;

  /// When the caller should look again after [now] while Mochi isn't travelling: when it next sets off, when the plan
  /// needs extending, or when a hold that a mode change waits for ends. Null: nothing will happen on its own.
  double? nextChange(double now) {
    var next = double.infinity;
    for (final segment in _segments) {
      if (segment.end <= now) continue;
      if (segment.travels) {
        next = math.max(now, segment.start);
        break;
      }
    }
    final last = _segments.isEmpty ? null : _segments.last;
    if (last != null && last.end.isFinite) next = math.min(next, math.max(now, last.end - lookahead / 2));
    if (_replan && _holdUntil.isFinite && _holdUntil > now) next = math.min(next, _holdUntil);
    return next.isFinite ? next : null;
  }

  // MARK: The plan

  void _pen(double t, double x, double facing, double odometer) {
    _t = t;
    _x = x;
    _facing = facing;
    _odometer = odometer;
    _line = _zoneAt(x);
  }

  /// The free stretch [x] is in (or the nearest one).
  StrollLine? _zoneAt(double x) {
    StrollLine? best;
    var distance = double.infinity;
    for (final zone in _zones) {
      final d = (zone.clamp(x) - x).abs();
      if (d < distance) {
        best = zone;
        distance = d;
      }
    }
    return best;
  }

  StrollSegment? _segmentAt(double t) {
    if (_segments.isEmpty) return null;
    for (final segment in _segments) {
      if (t < segment.end) return segment;
    }
    return _segments.last;
  }

  ({double x, double facing, double odometer}) _state(double t) {
    final segment = _segmentAt(t);
    if (segment == null) return (x: _line?.minX ?? 0, facing: 1, odometer: 0);
    final x = segment.xAt(math.min(math.max(t, segment.start), segment.end));
    return (x: x, facing: segment.facing, odometer: segment.odometer + (x - segment.fromX).abs());
  }

  /// Drops the plan from [now] on; the pen starts where Mochi is.
  void _cut(double now) {
    final state = _state(now);
    _segments.clear();
    _pen(now, state.x, state.facing, state.odometer);
  }

  void _restart(double now) {
    _cut(now);
    _open();
  }

  void _prune(double now) {
    while (_segments.length > 1 && _segments.first.end <= now) {
      _segments.removeAt(0);
    }
  }

  void _extend(double now) {
    for (var guard = 0; guard < 16 && _segments.isNotEmpty; guard++) {
      final last = _segments.last;
      if (!last.end.isFinite || last.end >= now + lookahead) break;
      _pen(last.end, last.toX, last.facing, last.odometerAtEnd);
      _chunk();
    }
  }

  void _add(
    PetAnimation animation,
    double duration, {
    double? toX,
    double speed = 0,
    double ease = 0,
    StrollStyle style = StrollStyle.plain,
    bool oneShot = false,
    bool hop = false,
  }) {
    final to = toX ?? _x;
    final end = _t + duration;
    _segments.add(
      StrollSegment(
        start: _t,
        end: end,
        fromX: _x,
        toX: to,
        animation: animation,
        facing: _facing,
        activity: _activity,
        style: style,
        oneShot: oneShot,
        odometer: _odometer,
        speed: speed,
        ease: ease,
        hop: hop,
      ),
    );
    if (!hop) _odometer += (to - _x).abs();
    _x = to;
    _t = end;
  }

  void _hold(PetAnimation animation, double duration, {StrollStyle style = StrollStyle.plain}) {
    if (duration > 0) _add(animation, duration, style: style);
  }

  void _holdForever(PetAnimation animation, {StrollStyle style = StrollStyle.plain}) => _add(animation, double.infinity, style: style);

  void _act(PetAnimation animation, {StrollStyle style = StrollStyle.plain}) =>
      _add(animation, _length(animation), oneShot: true, style: style);

  /// Turns to face [direction], with a beat to notice the way it's going.
  void _turn(double direction) {
    _facing = direction;
    _hold(PetAnimation.idle, 0.35, style: StrollStyle.notice);
  }

  /// Walks (or trots) to [target], kept on the line; turns round first if it's behind.
  void _walk(double target, {double? speed}) {
    final goal = _line!.clamp(target);
    final distance = (goal - _x).abs();
    if (distance < 1) return;
    final direction = goal > _x ? 1.0 : -1.0;
    if (direction != _facing) _turn(direction);
    final pace = speed ?? tuning.walkSpeed;
    final ease = math.min(tuning.ease, distance / pace);
    _add(
      pace >= tuning.trotSpeed ? PetAnimation.run : PetAnimation.walk,
      distance / pace + ease,
      toX: goal,
      speed: pace,
      ease: ease,
    );
    // At the screen's edge: turn round.
    if (_room(direction) < 1) _turn(-direction);
  }

  double _room(double direction) => direction > 0 ? _line!.maxX - _x : _x - _line!.minX;

  /// Fades out here and back in at [target] (another stretch: Mochi never walks over the taskbar's buttons).
  void _hopTo(double target) {
    final activity = _activity;
    _activity = StrollActivity.hop;
    _add(PetAnimation.idle, 0.9, toX: target, hop: true);
    _line = _zoneAt(target);
    _activity = activity;
  }

  /// Mostly towards the side with more room.
  double _roomyDirection() {
    final right = _room(1);
    final total = right + _room(-1);
    if (total <= 0) return 1;
    return _random.nextDouble() < right / total ? 1 : -1;
  }

  /// Back to Mochi's place beside Patch, facing him.
  void _goHome() {
    final home = _home;
    if (home == null) return;
    if ((_x - home).abs() > 0.5) _walk(home);
    if (_facing != 1) _turn(1);
  }

  /// How a mode begins, from where Mochi is.
  void _open() {
    if (_home != null) return _openBesidePatch();
    switch (_mode) {
      case StrollMode.free:
        _activity = StrollActivity.settle;
        _hold(_chance(0.6) ? PetAnimation.idle : PetAnimation.sit, _uniform(2, 5));
      case StrollMode.working:
        _activity = StrollActivity.watch;
        _hold(PetAnimation.watch, _uniform(1.5, 3.5));
      case StrollMode.attending:
        // A wave, then a calm watch facing you with one reminder wave a minute (at most ten), so it never waves for
        // ever in the corner of your eye.
        _activity = StrollActivity.attend;
        _hold(PetAnimation.waveGently, 8.4, style: StrollStyle.attentive);
        for (var i = 0; i < 10; i++) {
          _hold(PetAnimation.sit, 55.8, style: StrollStyle.attentive);
          _hold(PetAnimation.waveGently, 4.2, style: StrollStyle.attentive);
        }
        _holdForever(PetAnimation.sit, style: StrollStyle.attentive);
      case StrollMode.asleep:
        _activity = StrollActivity.sleep;
        _act(PetAnimation.yawn);
        _holdForever(PetAnimation.sleep);
      case StrollMode.still:
        _activity = StrollActivity.still;
        _hold(_chance(0.5) ? PetAnimation.sit : PetAnimation.idle, _uniform(2, 4));
    }
  }

  /// How a mode begins with Patch around (`RoamBuilder.open` for `.companion`, `.working`, `.attending`, `.asleep`,
  /// `.reducedMotion`): from Mochi's place beside his desk.
  void _openBesidePatch() {
    switch (_mode) {
      case StrollMode.free:
        _activity = StrollActivity.company;
        _goHome();
        _hold(_chance(0.55) ? PetAnimation.sit : PetAnimation.idle, _uniform(1.5, 3.5));
      case StrollMode.working:
        _activity = StrollActivity.watch;
        _goHome();
        _hold(PetAnimation.watch, _uniform(1.5, 3.5));
      case StrollMode.attending:
        _activity = StrollActivity.attend;
        _goHome();
        _hold(PetAnimation.waveGently, 8.4, style: StrollStyle.attentive);
        for (var i = 0; i < 10; i++) {
          _hold(PetAnimation.sit, 55.8, style: StrollStyle.attentive);
          _hold(PetAnimation.waveGently, 4.2, style: StrollStyle.attentive);
        }
        _holdForever(PetAnimation.sit, style: StrollStyle.attentive);
      case StrollMode.asleep:
        _activity = StrollActivity.sleep;
        _goHome();
        _act(PetAnimation.yawn);
        _holdForever(PetAnimation.sleep);
      case StrollMode.still:
        // Animation effects off: Mochi fades over to its place, then stays.
        _activity = StrollActivity.still;
        final home = _home!;
        if ((_x - home).abs() > 0.5) _hopTo(home);
        _facing = 1;
        _hold(_chance(0.5) ? PetAnimation.sit : PetAnimation.idle, _uniform(2, 4));
    }
  }

  /// The next stretch with Patch around: sitting with him or watching him work, with a little potter now and then.
  void _chunkBesidePatch() {
    switch (_mode) {
      case StrollMode.free:
        if (_chance(0.45)) _potterNearHome();
        _activity = StrollActivity.company;
        _goHome();
        _rest(_chance(0.55) ? PetAnimation.sit : PetAnimation.idle, _uniform(12, 40) * tuning.restScale);
      case StrollMode.working:
        if (_chance(0.22)) _potterNearHome();
        _activity = StrollActivity.watch;
        _goHome();
        _rest(PetAnimation.watch, _uniform(14, 40) * tuning.restScale);
      default:
        _chunkAlone();
    }
  }

  /// A few steps away from Patch's desk and a sniff or a look round, or a stretch where Mochi is (`potterNearHome`).
  void _potterNearHome() {
    _activity = StrollActivity.potter;
    final room = _room(-1);
    if (room >= 24 && _chance(0.7)) {
      _walk(_x - _uniform(math.min(24, room), room));
      _act(_chance(0.5) ? PetAnimation.sniff : PetAnimation.lookAround);
    } else {
      _act(_chance(0.5) ? PetAnimation.stretch : PetAnimation.scratch);
    }
  }

  /// The next stretch of the mode.
  void _chunk() {
    if (_home != null) return _chunkBesidePatch();
    _chunkAlone();
  }

  void _chunkAlone() {
    switch (_mode) {
      case StrollMode.free:
        final activity = _chooseFree();
        _perform(activity);
        _recent.add(activity);
        if (_recent.length > 4) _recent.removeAt(0);
        _activity = StrollActivity.rest;
        _rest(_chance(0.7) ? PetAnimation.idle : PetAnimation.sit, _uniform(10, 35) * tuning.restScale);
      case StrollMode.working:
        if (_chance(0.25)) _potter();
        _activity = StrollActivity.watch;
        _rest(PetAnimation.watch, _uniform(14, 40) * tuning.restScale);
      case StrollMode.still:
        _activity = StrollActivity.still;
        _hold(_chance(0.5) ? PetAnimation.sit : PetAnimation.idle, _uniform(14, 36));
        _act(
          _pick([
            (PetAnimation.blep, 1.0),
            (PetAnimation.lookAround, 1.2),
            (PetAnimation.nod, 0.4),
            if (_idle > 120) (PetAnimation.yawn, 0.8),
          ]),
        );
      case StrollMode.attending || StrollMode.asleep:
        // Their holds last for ever; if one ever ran out, start it again.
        _open();
    }
  }

  StrollActivity _chooseFree() {
    // The longer Claude has been quiet, the sleepier Mochi gets.
    final naps = 0.45 * (_idle > 900 ? 3 : (_idle > 300 ? 2 : 1));
    var options = <(StrollActivity, double)>[
      (StrollActivity.wander, 3),
      (StrollActivity.sniff, 2),
      (StrollActivity.fidget, 1.8),
      (StrollActivity.nap, naps),
      (StrollActivity.trot, 0.5),
      if (_zones.length > 1) (StrollActivity.hop, 0.6),
    ];
    if (_recent.isNotEmpty) options.removeWhere((option) => option.$1 == _recent.last);
    if (_recent.length > 1) {
      final previous = _recent[_recent.length - 2];
      options = [for (final option in options) option.$1 == previous ? (option.$1, option.$2 * 0.4) : option];
    }
    return _pick(options);
  }

  void _perform(StrollActivity activity) {
    _activity = activity;
    switch (activity) {
      case StrollActivity.wander:
        _wander();
      case StrollActivity.sniff:
        _sniffAround();
      case StrollActivity.fidget:
        _fidget();
      case StrollActivity.nap:
        _nap();
      case StrollActivity.trot:
        _trot();
      case StrollActivity.hop:
        _hopAcross();
      default:
        _hold(PetAnimation.idle, _uniform(2, 4));
    }
  }

  void _wander() {
    var direction = _roomyDirection();
    if (_room(direction) < 120) direction = -direction;
    _walk(_x + direction * _uniform(120, 700));
    _hold(PetAnimation.idle, _uniform(0.6, 1.4));
    if (_chance(0.45)) _act(PetAnimation.lookAround);
    if (_chance(0.25)) _walk(_x - direction * _uniform(30, 90));
  }

  void _trot() {
    var direction = _roomyDirection();
    if (_room(direction) < 250) direction = -direction;
    if (direction != _facing) _turn(direction);
    _hold(PetAnimation.idle, 0.3, style: StrollStyle.notice);
    _walk(_x + direction * _uniform(250, 700), speed: tuning.trotSpeed);
    _act(_chance(0.5) ? PetAnimation.happyBounce : PetAnimation.blep);
  }

  /// Over to another free stretch, and a look around there.
  void _hopAcross() {
    final others = [for (final zone in _zones) if (zone != _line) zone];
    if (others.isEmpty) return _hold(PetAnimation.idle, _uniform(2, 4));
    final zone = others[_random.nextInt(others.length)];
    _hold(PetAnimation.idle, 0.4, style: StrollStyle.notice);
    _hopTo(zone.minX + (zone.maxX - zone.minX) * _uniform(0.2, 0.8));
    _act(PetAnimation.lookAround);
  }

  void _sniffAround() {
    var direction = _roomyDirection();
    final rounds = 2 + _random.nextInt(2);
    for (var i = 0; i < rounds; i++) {
      if (_chance(0.3)) direction = -direction;
      if (_room(direction) < 40) direction = -direction;
      _walk(_x + direction * _uniform(30, 110));
      _act(PetAnimation.sniff);
      final roll = _random.nextDouble();
      if (roll < 0.25) {
        _act(PetAnimation.scratch);
      } else if (roll < 0.4) {
        _act(PetAnimation.blep);
      }
    }
  }

  void _fidget() {
    final options = [
      (PetAnimation.stretch, 1.0),
      (PetAnimation.scratch, 1.0),
      (PetAnimation.shake, 0.7),
      (PetAnimation.lookAround, 1.0),
      (PetAnimation.blep, 0.6),
      if (_idle > 120) (PetAnimation.yawn, 0.7),
    ];
    final count = _chance(0.35) ? 2 : 1;
    for (var i = 0; i < count; i++) {
      final fidget = _pick(options);
      options.removeWhere((option) => option.$1 == fidget);
      _act(fidget);
    }
  }

  void _nap() {
    if (_chance(0.5)) _walk(_x + _roomyDirection() * _uniform(0, 80));
    _act(PetAnimation.yawn);
    _hold(PetAnimation.curl, _uniform(18, 50) * (_idle > 300 ? 1.5 : 1));
    _act(PetAnimation.wakeUp);
    _act(PetAnimation.stretch);
  }

  /// A short walk while Claude works.
  void _potter() {
    _activity = StrollActivity.potter;
    var direction = _chance(0.5) ? 1.0 : -1.0;
    if (_room(direction) < 60) direction = -direction;
    _walk(_x + direction * _uniform(40, 150));
    if (_chance(0.5)) _act(PetAnimation.lookAround);
  }

  /// A rest with a little something in the middle when it's long enough (never frozen, as on the Mac).
  void _rest(PetAnimation base, double duration) {
    if (duration < 14) return _hold(base, duration);
    final options = [
      (PetAnimation.lookAround, 1.0),
      (PetAnimation.blep, 0.6),
      (PetAnimation.scratch, 0.5),
      (PetAnimation.stretch, 0.35),
      (PetAnimation.sniff, 0.3),
      if (_idle > 120) (PetAnimation.yawn, 0.7),
    ];
    final fidgets = duration >= 30 ? 2 : 1;
    var remaining = duration;
    for (var i = 0; i < fidgets; i++) {
      final share = fidgets == 1 ? _uniform(0.3, 0.6) : (i == 0 ? _uniform(0.22, 0.4) : _uniform(0.35, 0.6));
      final first = remaining * share;
      _hold(base, first);
      final fidget = _pick(options);
      options.removeWhere((option) => option.$1 == fidget);
      _act(fidget);
      remaining = math.max(1, remaining - first - _length(fidget));
    }
    _hold(base, remaining);
  }

  // MARK: Randomness

  double _uniform(double low, double high) => low + (high - low) * _random.nextDouble();

  bool _chance(double probability) => _random.nextDouble() < probability;

  T _pick<T>(List<(T, double)> options) {
    final total = options.fold<double>(0, (sum, option) => sum + option.$2);
    var roll = _random.nextDouble() * total;
    for (final (value, weight) in options) {
      roll -= weight;
      if (roll < 0) return value;
    }
    return options.last.$1;
  }
}
