// Mochi's stroll along the taskbar: where it is and what it's doing, as a timeline of segments that are pure
// functions of time (so it can be drawn at any frame rate). It follows the Mac's MenuBarRoamer
// (Sources/TamagotchiCore/Roaming/MenuBarRoamer.swift), cut down to a strip with no bed: Patch's desk is home.
//
// The taskbar's empty stretches (zones) are where Mochi lingers; the buttons between them it only crosses, as the Mac's Mochi
// runs, leaps and plays across other apps' status items but rests, naps, sniffs and fidgets only where the bar is free
// (`RoamZone.canLinger`, `freeSpot`). Getting to another stretch is a real walk, or a trot when it's far, over the buttons
// (`StrollSegment.crosses`); it fades out and back in there (`hop`) only with animation effects off, as the Mac's Mochi does
// with Reduce Motion on. Every stop, hold and rest is over free room: a walk always ends in a stretch, and a plan cut in the
// middle of a trip (a reaction, a drag) first walks on to the nearest free spot. Beside Patch or in "Plays in its spot" there
// is only the one stretch, and Mochi keeps to it as ever.
//
// - Nothing going on (free): it wanders (to somewhere free anywhere on the taskbar, each stretch as likely as it is long, over
//   the buttons to get there), trots, goes over to another stretch for a look round, sniffs about, fidgets, sits and rests
//   (10–35 s between outings, with a glance or a scratch in the middle of long rests) and sometimes naps, more the longer
//   Claude has been quiet. And it plays
//   on its own as the Mac's menu-bar Mochi does (`chooseFreeActivity`, `RoamBuilder.zoomies`, `ballPlay`,
//   `chaseButterfly`, `leafPlay` with the Mac's weights, motions, poses and timings, scaled up to the taskbar): zoomies
//   (sprints along the taskbar, over the buttons if they're in the way, each dash skidding to a stop over free room, and
//   doubling back), a ball or yarn to bat and chase, a butterfly to stalk and leap at, a leaf to watch land and bat away.
//   The toys are props on the plan ([StrollPropTrack]; the view draws them with mochi_art's EffectRenderer.drawProp), and the
//   window grows around Mochi for them ([StrollPropTrack.reachX]). A toy's play stays inside the free stretch Mochi is in
//   (so never over a button, and in "Plays in its spot" inside its room) and is skipped when the stretch is too short for it.
// - Peekaboo (Mischief's X3, only with Mochi free to wander alone): after two minutes without input Mochi walks to a
//   free spot and sinks down into the taskbar until only its ears and eyes show above the bottom of its window
//   (`StrollSample.sink`; the view draws it lower and the window's edge cuts it off), looking around now and then. When
//   you're back it pops up with a happy bounce (`popUp`), at most once per away stretch (the caller counts those);
//   anything else (Claude needing you, a reaction, a nap, a drag, the switch going off) brings it up normally first
//   (every cut of the plan rises before it carries on).
// - Landmarks (Mischief's X6, only while Mochi is free to wander alone and the caller says which landmarks are known and
//   allowed, `setLandmarks`): about as often as a toy, Mochi visits a landmark of the taskbar. The clock: it walks (over the
//   buttons, if that spot is in another stretch) to the free spot nearest it, leaps up and hangs from the clock button's top edge for 6–10 seconds (PetAnimation.idle with the
//   `StrollStyle.hang` accent: both arms up holding on, a gentle swing, drawn lifted `StrollSample.lift`), then drops back
//   down. Start: it goes to the free spot right beside the button, faces it, bats at it three or four times with a pounce
//   (PetAnimation.bat, .pounce) and wanders off. The widgets tile: it leaps onto the taskbar's top edge above the tile and
//   sits there looking out (PetAnimation.sit, a look around) for a few seconds, then hops down. The clock and the
//   tile aren't in a free stretch, so the leaps are the only moments Mochi is off one; the window makes room above for
//   them (`playRoom`, as for a toy). Anything that cuts the plan (the pointer's company, Claude's news, a reaction, a
//   hide, a mode change) first drops Mochi back to the free spot, so it never stays on a landmark.
// - Reactions paused (Settings › General): it sits where it is, as the Mac's paused Mochi rests, and never plays.
// - Claude working: it mostly sits and watches, with a short potter now and then.
// - Claude needs you: it stops where it is and faces you, waves, then sits watching you with a reminder wave a minute
//   (at most ten), as on the Mac.
// - A long quiet stretch (Mochi's napping mood): a yawn, and it sleeps where it is.
// - Animation effects off: it stays where it is, expressions only.
// - A pet, a game, a finished turn: it holds still while that plays (facing you for news), then carries on.
// - The cursor buddy (Mischief's X4, only with Mochi free to wander): while the pointer is on the taskbar Mochi turns
//   to it, trots (or runs, if far) to the free spot nearest it, over the buttons if need be, and sits beside it, never under
//   it (at least a body away, so whatever is under the pointer stays clickable). When the pointer
//   stops, a pounce or a sit facing it. A pointer coming to Mochi (within a body and a half) stops it at once, facing
//   you, holding still: it never moves away from one that's coming to it, so it can be clicked. The pointer leaving the
//   taskbar, Mochi watches a moment and carries on strolling (`follow`).
// - Patch around (a home: his desk is to the right of it, ui/pet/companion_director.dart): Mochi keeps him company as
//   on the Mac (`RoamMode.companion`, `.working`): it sits with him, potters a little way off and comes back, watches
//   him work, waves from beside him when Claude needs you and naps there. For a moment together (a high five, a coffee
//   delivery) it holds still where it is while the moment plays (it goes over to him and back in the moment itself).
//
// - Drawn by the native stage while Mochi's window is open (`useView(false)`; ui/pet/taskbar_stroll.dart): the toys, the
//   landmark visits and Peekaboo are left out, since the pet's own view draws their props, lifts and sink; the rest
//   (walking, resting, napping, attending, reactions, zoomies, the cursor buddy) goes on as ever.
//
// Positions are Mochi's centre in logical pixels along the taskbar; times are seconds on the caller's clock. The plan
// reaches a couple of seconds ahead and is extended as time passes (`update`). Every choice comes from the `Random`
// it's given, so tests can seed it.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mochi_art/mochi_art.dart' show Ease, PetAnimation, ScenePropKind;

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

  /// Reactions are paused (Settings › General): Mochi sits where it is.
  paused,

  /// Animation effects are off: Mochi stays where it is.
  still;

  static StrollMode of(PetMood mood, {required bool reducedMotion, bool paused = false}) => switch (mood) {
    PetMood.needsYou => attending,
    PetMood.napping => asleep,
    _ when paused => StrollMode.paused,
    _ when reducedMotion => still,
    PetMood.watching => working,
    _ => free,
  };
}

/// What Mochi is up to.
enum StrollActivity { settle, rest, wander, sniff, fidget, nap, trot, cross, hop, potter, watch, attend, sleep, still, react, company, follow, zoomies, butterfly, ball, yarn, leaf, hide, swing, batStart, perch }

/// Small accents the pose gets on top of its animation.
enum StrollStyle {
  plain,

  /// Ears up, looking the way it's about to go: a turn.
  notice,

  /// Facing you, eyes open, ears up: Claude needs you, or a turn just finished.
  attentive,

  /// Hanging by both paws from the clock's edge (X6): arms up, a gentle swing.
  hang,
}

/// The taskbar's landmarks Mochi may visit (X6).
enum StrollVisit {
  clock(StrollActivity.swing),
  start(StrollActivity.batStart),
  widgets(StrollActivity.perch);

  const StrollVisit(this.activity);

  final StrollActivity activity;
}

/// A landmark as the stroll needs it (logical pixels along the taskbar and up from Mochi's feet), worked out by the caller
/// from where UI Automation put it.
class StrollLandmark {
  const StrollLandmark(this.kind, {required this.x, this.lift = 0, this.up = 0, this.reach = 300});

  final StrollVisit kind;

  /// Where Mochi goes for the visit: its centre while it hangs or perches there; the button's own centre for Start (Mochi
  /// stands in the free spot beside it).
  final double x;

  /// How far Mochi's feet are raised while it's there (a hang: so its paws reach the top edge; a perch: its feet on the
  /// edge).
  final double lift;

  /// How high above its feet the window must reach for the visit (the leap's arc, the raised body), with a margin.
  final double up;

  /// The farthest the free spot nearest the landmark may be from [x]: a landmark with no free stretch near it isn't
  /// visited.
  final double reach;

  @override
  bool operator ==(Object other) =>
      other is StrollLandmark && other.kind == kind && other.x == x && other.lift == lift && other.up == up && other.reach == reach;

  @override
  int get hashCode => Object.hash(kind, x, lift, up, reach);
}

/// The window's extra room for a stretch of the plan that has none of a toy's props (a landmark visit).
class _Room {
  const _Room(this.start, this.end, this.up);

  final double start;
  final double end;
  final double up;
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
    this.playScale = 2.1,
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

  /// How much bigger the taskbar's Mochi plays than the Mac's menu-bar one (the Mac's points of distance, height and
  /// speed times this: its 24 and 44 points a second walk and trot are about this much slower than 46 and 96 here).
  final double playScale;
}

/// How the Mac's play moves (points a second; `MenuBarRoamer.Speed`), before [StrollTuning.playScale].
abstract final class _MacSpeed {
  static const double run = 84;
  static const double zoom = 110;
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

double _length(PetAnimation animation) => strollOneShotLengths[animation] ?? animation.defaultDuration;

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
    this.crosses = false,
    this.sinkFrom = 0,
    this.sinkTo = 0,
    this.liftFrom = 0,
    this.liftTo = 0,
    this.arc = 0,
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

  /// Mochi fades out at [fromX] and back in at [toX] (to another stretch of the taskbar, with animation effects off).
  final bool hop;

  /// Mochi walks over the taskbar's buttons on this walk (it may start and end in different stretches).
  final bool crosses;

  /// How far down into the taskbar Mochi is at the start and the end of the segment (0 standing, 1 hidden: Peekaboo).
  final double sinkFrom;
  final double sinkTo;

  /// How far Mochi is raised off the taskbar's floor at the start and the end (logical pixels: perched or hanging on a
  /// landmark, X6), and how much higher a leap's arc takes it in between.
  final double liftFrom;
  final double liftTo;
  final double arc;

  bool get travels => toX != fromX;

  /// How high Mochi is at [t]: eases from [liftFrom] to [liftTo], with the arc of a leap on top.
  double liftAt(double t) {
    if (liftFrom == liftTo && arc == 0) return liftFrom;
    if (t <= start) return liftFrom;
    if (t >= end) return liftTo;
    final p = (t - start) / (end - start);
    return liftFrom + (liftTo - liftFrom) * Ease.smooth(p) + arc * Ease.hop(p);
  }

  /// How far down Mochi is at [t]: eases from [sinkFrom] to [sinkTo] over the segment.
  double sinkAt(double t) {
    if (sinkFrom == sinkTo || t <= start) return sinkFrom;
    if (t >= end) return sinkTo;
    return sinkFrom + (sinkTo - sinkFrom) * Ease.smooth((t - start) / (end - start));
  }
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
    this.props = const [],
    this.sink = 0,
    this.lift = 0,
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

  /// The toys in play right now (a ball, a butterfly…), where they are on the taskbar.
  final List<StrollPropSample> props;

  /// How far Mochi has sunk down into the taskbar: 0 standing, 1 with only its ears and eyes showing (Peekaboo).
  final double sink;

  /// How far Mochi is raised off the taskbar's floor (logical pixels): on a landmark, or leaping to one (X6).
  final double lift;
}

/// Where a toy is at one moment (x along the taskbar and y up from Mochi's feet, logical pixels).
class StrollPropSample {
  const StrollPropSample({
    required this.kind,
    required this.x,
    required this.y,
    required this.rotation,
    required this.opacity,
    required this.scale,
    required this.variant,
  });

  final ScenePropKind kind;
  final double x;
  final double y;

  /// A ball's or yarn's spin, a butterfly's wing-beat phase, a leaf's tilt (as the Mac's `RoamPropSample`).
  final double rotation;
  final double opacity;

  /// The art's scale for this toy (times the art's own unit).
  final double scale;
  final int variant;
}

/// How a toy gets from one key to the next (`RoamPropKey.Path`).
enum StrollPropPath { linear, easeOut, easeInOut, drop, arc, flutter, drift }

/// Where a toy is at [t], and how it gets there from the key before.
class StrollPropKey {
  const StrollPropKey(this.t, this.x, this.y, {this.opacity = 1, this.path = StrollPropPath.linear, this.arc = 0});

  final double t;
  final double x;
  final double y;
  final double opacity;
  final StrollPropPath path;
  final double arc;
}

/// A toy's whole track in the plan (`RoamPropTrack`): where it is from its first key to its last. [reachX] and [reachUp]
/// are how far it gets from Mochi sideways and how high above its feet over that time (with a margin), which is the room
/// the window must make for it.
class StrollPropTrack {
  StrollPropTrack(this.kind, this.keys, {required this.scale, this.variant = 0, this.rollRadius = 6.7, this.pixel = 2.1, this.reachX = 0, this.reachUp = 0});

  final ScenePropKind kind;
  final List<StrollPropKey> keys;
  final double scale;
  final int variant;

  /// A ball's rolling radius, and the pixels per Mac point the keys were scaled by (the wobbles scale with it).
  final double rollRadius;
  final double pixel;
  double reachX;
  double reachUp;

  /// The window grows this long before the first key and stays this long after the last.
  static const double lead = 0.3;

  /// A butterfly's wing-beat phase a second.
  static const double flapRate = 2.35;

  double get start => keys.first.t;
  double get end => keys.last.t;

  /// The toy at [t], or null before its first key and after its last.
  StrollPropSample? sample(double t) {
    if (t < start || t > end) return null;
    var index = 1;
    while (index < keys.length - 1 && keys[index].t < t) {
      index++;
    }
    final a = keys[math.max(0, index - 1)];
    final b = keys[math.min(keys.length - 1, index)];
    final p = b.t > a.t ? Ease.clamp((t - a.t) / (b.t - a.t)) : 1.0;
    double x, y;
    switch (b.path) {
      case StrollPropPath.linear:
        x = Ease.lerp(a.x, b.x, p);
        y = Ease.lerp(a.y, b.y, p);
      case StrollPropPath.easeOut:
        final e = Ease.outCubic(p);
        x = Ease.lerp(a.x, b.x, e);
        y = Ease.lerp(a.y, b.y, e);
      case StrollPropPath.easeInOut:
        final e = Ease.smooth(p);
        x = Ease.lerp(a.x, b.x, e);
        y = Ease.lerp(a.y, b.y, e);
      case StrollPropPath.drop:
        x = Ease.lerp(a.x, b.x, p);
        y = Ease.lerp(a.y, b.y, p * p);
      case StrollPropPath.arc:
        x = Ease.lerp(a.x, b.x, p);
        y = Ease.lerp(a.y, b.y, p) + b.arc * Ease.hop(p);
      case StrollPropPath.flutter:
        // The wobble fades in and out with the leg, so every key is passed exactly.
        final e = Ease.smooth(p);
        final wobble = math.sin(math.pi * p);
        x = Ease.lerp(a.x, b.x, e) + 1.6 * pixel * math.sin(t * 3.3) * wobble;
        y = Ease.lerp(a.y, b.y, e) + 2.4 * pixel * math.sin(t * 6.1) * wobble;
      case StrollPropPath.drift:
        // Sways side to side on the way down, passing exactly through both keys.
        x = Ease.lerp(a.x, b.x, p) + b.arc * math.sin((t - a.t) * 2.6) * math.sin(math.pi * p);
        y = Ease.lerp(a.y, b.y, p);
    }
    final rotation = switch (kind) {
      ScenePropKind.ball || ScenePropKind.yarn => x / rollRadius,
      ScenePropKind.butterfly => (t - start) * flapRate,
      ScenePropKind.leaf => 0.6 * math.sin(t * 2.6),
      _ => 0.0,
    };
    return StrollPropSample(
      kind: kind,
      x: x,
      y: y,
      rotation: rotation,
      opacity: Ease.lerp(a.opacity, b.opacity, p),
      scale: scale,
      variant: variant,
    );
  }
}

/// The Mac's toy sizes (`RoamToys`) and resting heights (points above the baseline).
abstract final class _Toys {
  static const double ballScale = 1.8, ballRest = 3.3;
  static const double yarnScale = 1.75, yarnRest = 3.4;
  static const double butterflyScale = 1.5;
  static const double leafScale = 2.2, leafRest = 2.0;
}

enum _BuddyHold { none, attentive, sit }

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

  /// The toys in play, in the plan (pruned once they're long gone).
  final List<StrollPropTrack> _props = [];
  double _idle = 0;

  /// A reaction (or a drag) holds Mochi still until then; a mode change waits for it.
  double _holdUntil = double.negativeInfinity;
  bool _replan = false;

  // The cursor buddy: whether the plan is Mochi keeping the pointer company, where it's going (null: it's holding still
  // there) and what it does there.
  bool _buddy = false;
  double? _buddyTarget;
  _BuddyHold _buddyHold = _BuddyHold.none;
  double? _lastPointer;
  double _pointerMovedAt = 0;
  double? _offSince;
  double _lastRetarget = double.negativeInfinity;

  // Peekaboo: the plan is Mochi hiding (walking to its spot, sunk down, looking around).
  bool _hiding = false;

  // Whether the pet's own view draws Mochi. It draws what a plain picture of a pose can't show: a toy's props, the lift of a
  // landmark visit, Peekaboo's sink. Drawn by the native stage while Mochi's window is open (`useView(false)`), Mochi keeps
  // to what a plain picture shows.
  bool _view = true;

  // Landmarks (X6): the ones that are known and allowed now, the visit in the plan (until when), and the room the window
  // makes for the visits in the plan.
  List<StrollLandmark> _landmarks = const [];
  StrollVisit? _visitKind;
  double _visitUntil = double.negativeInfinity;
  final List<_Room> _rooms = [];

  /// How high a leap onto a landmark (or back) arcs (logical pixels).
  static const double leapArc = 16;

  // The planner's pen: where the plan being written has got to.
  double _t = 0;
  double _sink = 0;
  double _lift = 0;
  double _x = 0;
  double _facing = 1;
  double _odometer = 0;
  StrollActivity _activity = StrollActivity.settle;

  StrollLine? get line => _line;
  double? get home => _home;
  List<StrollLine> get zones => _zones;
  StrollMode get mode => _mode;
  bool get isPlaced => _line != null && _segments.isNotEmpty;

  /// The plan is Mochi hiding in the taskbar (Peekaboo), sunk down or on its way there.
  bool get hiding => _hiding;

  /// The pet's own view draws Mochi (the taskbar window), rather than the native stage.
  bool get view => _view;

  /// Whether the pet's own view draws Mochi from now on. Without it (Mochi's window is open and the native stage draws Mochi on
  /// the taskbar) the toys, the landmark visits and Peekaboo aren't chosen, since their props, lifts and sink are drawn by the
  /// view alone: one already under way ends now (Mochi stands back up where it is), and the rest of the plan carries on.
  void useView(bool view, double now) {
    if (view == _view) return;
    _view = view;
    if (view || !isPlaced) return;
    if (_hiding || _props.any((track) => track.end > now) || visiting(now)) {
      _restart(now);
      _extend(now);
    }
  }
  List<StrollSegment> get segments => List.unmodifiable(_segments);

  /// Starts the stroll in [zones] at [x] (or carries on from where Mochi is), in [mode]. Carrying on from a spot
  /// that's no longer in a free stretch (the buttons moved), Mochi walks to the nearest free one. With a [home] (Patch's
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
    _props.clear();
    _rooms.clear();
    _visitUntil = double.negativeInfinity;
    _buddy = false;
    _hiding = false;
    _holdUntil = double.negativeInfinity;
    _replan = false;
    final from = x ?? state?.x ?? _zones.first.minX;
    final to = nearest(from);
    _pen(now, state == null || x != null ? to : from, facing ?? state?.facing ?? 1, state?.odometer ?? 0);
    if (_x != to) _goTo(to);
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
      // A walk that doesn't cross the buttons keeps to one stretch: both ends in the same one.
      if (segment.travels && !segment.hop && !segment.crosses) {
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
    _buddy = false;
    _hiding = false;
    _segments.clear();
    _props.clear();
    _rooms.clear();
    _visitUntil = double.negativeInfinity;
  }

  /// Follows [mode] (re-planning from where Mochi is when it changes) and keeps the plan reaching ahead.
  void update(double now, {required StrollMode mode, double idleSeconds = 0}) {
    if (!isPlaced) return;
    _idle = idleSeconds;
    if (mode != _mode) {
      _mode = mode;
      _replan = true;
      _buddy = false;
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
    _buddy = false;
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
    _buddy = false;
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
      props: _propsAt(t),
      sink: segment.sinkAt(local),
      lift: segment.liftAt(local),
    );
  }

  /// How far Mochi is raised off the taskbar's floor at [t] (0 standing): what the window's clicks go by.
  double liftAt(double t) {
    final segment = _segmentAt(t);
    return segment == null ? 0 : segment.liftAt(math.min(math.max(t, segment.start), segment.end));
  }

  /// Mochi is on a landmark, or leaping to or from one, at [now].
  bool visiting(double now) => now < _visitUntil || liftAt(now) > 0;

  /// The landmark visit in the plan (tests), if any.
  StrollVisit? get visit => _visitKind;

  /// The landmarks that are known and allowed now (X6; the caller gives the same list while nothing changes, so asking
  /// each time the pointer is read costs nothing). Mochi visits only these, only while it's free to wander alone. One it's
  /// visiting that isn't among them any more (the switch went off, a rule says to keep still) ends the visit now: back
  /// down and on with the stroll. Returns whether the plan changed.
  bool setLandmarks(List<StrollLandmark> landmarks, double now) {
    if (identical(landmarks, _landmarks)) return false;
    _landmarks = landmarks;
    final kind = _visitKind;
    if (!isPlaced || kind == null || now >= _visitUntil || landmarks.any((mark) => mark.kind == kind)) return false;
    _restart(now);
    _extend(now);
    return true;
  }

  /// How far down Mochi is at [t] (0 standing; 1 hidden): what the window's clicks go by.
  double sinkAt(double t) {
    final segment = _segmentAt(t);
    return segment == null ? 0 : segment.sinkAt(math.min(math.max(t, segment.start), segment.end));
  }

  /// How far Mochi sinks once it has gone right down: its feet go `1 - peekShows` of `PetRenderer.bodyHeight` below the
  /// window's bottom edge. Mochi's drawn body is only about [artTop] of that height, so this leaves its ears and eyes
  /// showing (0.5 showed only the ear tips on the Windows VM, 2026-11-08).
  static const double peekShows = 0.75;

  /// Where the top of Mochi's ears is, as a part of `PetRenderer.bodyHeight` above its feet (measured on screen).
  static const double artTop = 0.7;

  /// The part of `PetRenderer.bodyHeight` that still shows once Mochi has sunk right down (its clickable slice).
  static double get peekVisible => artTop - (1 - peekShows);

  /// Peekaboo's hide: Mochi (free to wander alone) walks to a free spot and sinks down into the taskbar, looking around
  /// now and then, until [popUp] or anything else cuts the plan. False when it can't (it isn't free, is beside Patch, is
  /// keeping the pointer company or holds still for a moment, or is hiding already).
  bool hide(double now) {
    if (!isPlaced || !_view || _mode != StrollMode.free || _home != null || _buddy || _hiding || now < _holdUntil) return false;
    _cut(now);
    _hiding = true;
    _activity = StrollActivity.hide;
    final room = _roomyDirection();
    _walk(_x + room * _uniform(30, 120));
    _add(PetAnimation.sit, 1.4, sinkTo: 1);
    _extend(now);
    return true;
  }

  /// Peekaboo's return: up from the taskbar with a happy bounce, then the usual stroll. False when it wasn't hiding.
  bool popUp(double now) {
    if (!_hiding) return false;
    _cut(now);
    _activity = StrollActivity.settle;
    _act(PetAnimation.happyBounce);
    _open();
    _extend(now);
    return true;
  }

  List<StrollPropSample> _propsAt(double t) {
    if (_props.isEmpty) return const [];
    final samples = <StrollPropSample>[];
    for (final track in _props) {
      final at = track.sample(t);
      if (at != null) samples.add(at);
    }
    return samples.isEmpty ? const [] : samples;
  }

  /// The room the window must make around Mochi at [now] for the toy in play (how far it gets from Mochi sideways, and
  /// how high above its feet; logical pixels, with a margin), or null when there's none. The window grows a moment
  /// before the first toy shows and shrinks a moment after the last has gone ([StrollPropTrack.lead]).
  ({double x, double up})? playRoom(double now) {
    double? x;
    var up = 0.0;
    for (final track in _props) {
      if (now < track.start - StrollPropTrack.lead || now > track.end + StrollPropTrack.lead) continue;
      x = math.max(x ?? 0, track.reachX);
      up = math.max(up, track.reachUp);
    }
    // Hanging from the clock, perched on the widgets tile: no toy, but room above Mochi's feet for it raised.
    for (final room in _rooms) {
      if (now < room.start - StrollPropTrack.lead || now > room.end + StrollPropTrack.lead) continue;
      x ??= 0;
      up = math.max(up, room.up);
    }
    return x == null ? null : (x: x, up: up);
  }

  bool travellingAt(double t) => sample(t).travelling;

  /// A one-shot (a sniff, a stretch, a yawn…) is playing at [t] while Mochi stands where it is.
  bool playingAt(double t) {
    final segment = _segmentAt(t);
    return segment != null && segment.oneShot && !segment.travels && t >= segment.start && t < segment.end;
  }

  /// When the caller should look again after [now] while Mochi isn't travelling: when it next sets off, when the plan
  /// needs extending, or when a hold that a mode change waits for ends; with [pictures], also when the next piece of the plan
  /// begins (a picture drawn by the native stage is drawn again then; the pet's own view follows the plan by itself). Null:
  /// nothing will happen on its own.
  double? nextChange(double now, {bool pictures = false}) {
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
    // A hidden Mochi looks around now and then: the view draws nothing in between, so it wakes for each change.
    for (final segment in _segments) {
      if ((segment.sinkFrom > 0 || segment.sinkTo > 0 || segment.activity == StrollActivity.hide) && segment.start > now) {
        next = math.min(next, segment.start);
      }
    }
    // The window makes room for a toy a moment before it shows, and gives it back a moment after it has gone (and for a
    // landmark visit).
    for (final track in _props) {
      for (final edge in [track.start - StrollPropTrack.lead, track.end + StrollPropTrack.lead]) {
        if (edge > now) next = math.min(next, edge);
      }
    }
    for (final room in _rooms) {
      for (final edge in [room.start - StrollPropTrack.lead, room.end + StrollPropTrack.lead]) {
        if (edge > now) next = math.min(next, edge);
      }
    }
    if (pictures) {
      for (final segment in _segments) {
        if (segment.start > now) {
          next = math.min(next, segment.start);
          break;
        }
      }
    }
    return next.isFinite ? next : null;
  }

  // MARK: The cursor buddy

  /// The pointer is this close to Mochi (body widths) and it holds still, facing you.
  static const double buddyNear = 1.5;

  /// Where Mochi sits beside the pointer (body widths from it), and the least it ever stands from it.
  static const double buddyBeside = 1.25;
  static const double buddyLeast = 1.0;

  /// The pointer is still after this long (seconds): a pounce or a sit; and Mochi watches this long after the pointer
  /// left the taskbar before it carries on strolling.
  static const double buddyStill = 0.6;
  static const double buddyWatch = 1.5;

  /// The pace of a run to the pointer when it's far (more than [buddyFar] body widths); a trot otherwise.
  static const double buddyRun = 160;
  static const double buddyFar = 8;

  /// The pointer's company (called each time the pointer is read, about 10 times a second): [pointerX] is the pointer's
  /// x on the taskbar in logical pixels (null: it isn't on the taskbar), [bodyWidth] Mochi's, [allowed] whether Mischief
  /// lets the cursor buddy run now. Only while Mochi is free to wander alone (not reacting, attending, asleep, still,
  /// working or beside Patch). Returns whether the plan changed (the caller then moves the window and times its frames).
  bool follow(double now, {required double? pointerX, required double bodyWidth, required bool allowed}) {
    // Hidden in the taskbar (Peekaboo), Mochi comes up when you're back (`popUp`), not as the pointer's company.
    if (!isPlaced || _hiding) return false;
    final free = _mode == StrollMode.free && _home == null && now >= _holdUntil;
    if (!free || !allowed) {
      final was = _buddy;
      _buddy = false;
      // Mischief said no while Mochi was keeping the pointer company: back to the stroll at once.
      return was && free && _endBuddy(now);
    }
    if (pointerX == null) {
      if (!_buddy) return false;
      _offSince ??= now;
      return now - _offSince! >= buddyWatch && _endBuddy(now);
    }
    _offSince = null;
    final last = _lastPointer;
    if (last == null || (pointerX - last).abs() > 1.5) {
      _lastPointer = pointerX;
      _pointerMovedAt = now;
    }
    final here = _state(now).x;
    final still = now - _pointerMovedAt >= buddyStill;
    // A pointer coming to Mochi: stop at once, never move away from it.
    if ((pointerX - here).abs() <= buddyNear * bodyWidth) return _settle(now, pointerX, still);
    final spot = _buddySpot(pointerX, bodyWidth, here);
    if (spot == null) return false;
    if ((spot - here).abs() < 2) return _settle(now, pointerX, still);
    final target = _buddyTarget;
    if (_buddy && target != null && ((spot - target).abs() < bodyWidth * 0.5 || now - _lastRetarget < 0.4)) return false;
    // Off to the spot beside the pointer: turn to it, trot (run if far), over the buttons if need be, and sit there.
    _cut(now, settle: false);
    _buddy = true;
    _buddyTarget = spot;
    _buddyHold = _BuddyHold.none;
    _lastRetarget = now;
    _activity = StrollActivity.follow;
    final far = (spot - _x).abs() > buddyFar * bodyWidth;
    // A re-aim on the move doesn't start from a standstill again.
    _walk(spot, speed: far ? buddyRun : tuning.trotSpeed, easeIn: target == null ? null : 0.12, cross: true);
    _facing = pointerX >= _x ? 1.0 : -1.0;
    _holdForever(PetAnimation.sit);
    _extend(now);
    return true;
  }

  /// Holds still beside (or near) the pointer: facing you while it moves about close by, a pounce or a sit facing it
  /// once it stops.
  bool _settle(double now, double pointerX, bool still) {
    final want = still ? _BuddyHold.sit : _BuddyHold.attentive;
    if (_buddy && _buddyTarget == null && _buddyHold == want) return false;
    _cut(now);
    _buddy = true;
    _buddyTarget = null;
    _buddyHold = want;
    _activity = StrollActivity.follow;
    if (want == _BuddyHold.attentive) {
      _holdForever(PetAnimation.idle, style: StrollStyle.attentive);
    } else {
      final direction = pointerX >= _x ? 1.0 : -1.0;
      if (direction != _facing) _turn(direction);
      if (_chance(0.5)) _act(PetAnimation.pounce);
      _holdForever(PetAnimation.sit);
    }
    _extend(now);
    return true;
  }

  /// The free spot nearest the pointer on the side Mochi is on, at least a body from it: never under the pointer, never
  /// outside the free stretches. Null: no such spot (Mochi stays where it is).
  double? _buddySpot(double pointerX, double bodyWidth, double here) {
    final side = here <= pointerX ? -1.0 : 1.0;
    for (final away in const [buddyBeside, 2.5, 5.0]) {
      for (final direction in [side, -side]) {
        final spot = nearest(pointerX + direction * away * bodyWidth);
        if ((spot - pointerX).abs() >= buddyLeast * bodyWidth) return spot;
      }
    }
    return null;
  }

  /// Back to the usual stroll from where Mochi is.
  bool _endBuddy(double now) {
    _buddy = false;
    _buddyTarget = null;
    _buddyHold = _BuddyHold.none;
    _offSince = null;
    _restart(now);
    _extend(now);
    return true;
  }

  /// Mochi is keeping the pointer company (tests).
  bool get buddying => _buddy;

  // MARK: The plan

  void _pen(double t, double x, double facing, double odometer, {double sink = 0, double lift = 0}) {
    _t = t;
    _sink = sink;
    _lift = lift;
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

  ({double x, double facing, double odometer, double sink, double lift}) _state(double t) {
    final segment = _segmentAt(t);
    if (segment == null) return (x: _line?.minX ?? 0, facing: 1, odometer: 0, sink: 0, lift: 0);
    final at = math.min(math.max(t, segment.start), segment.end);
    final x = segment.xAt(at);
    return (
      x: x,
      facing: segment.facing,
      odometer: segment.odometer + (x - segment.fromX).abs(),
      sink: segment.sinkAt(at),
      lift: segment.liftAt(at),
    );
  }

  /// Drops the plan from [now] on; the pen starts where Mochi is. A Mochi that is sunk down (hiding) comes up first, so
  /// whatever cuts the plan finds it standing; one over a button (crossing the taskbar) walks on to the nearest free spot,
  /// unless it's about to go somewhere else ([settle] false).
  void _cut(double now, {bool settle = true}) {
    final state = _state(now);
    _segments.clear();
    _hiding = false;
    // A toy still in play goes with the plan.
    _props.removeWhere((track) => track.end > now);
    _rooms.removeWhere((room) => room.end > now);
    _visitUntil = double.negativeInfinity;
    _pen(now, state.x, state.facing, state.odometer, sink: state.sink, lift: state.lift);
    if (state.sink > 0) _add(PetAnimation.sit, 0.3 + 0.5 * state.sink, sinkTo: 0);
    // On a landmark (or leaping to one): drops back to the free spot nearest it first, so whatever cut the plan finds Mochi
    // in free room; over a button: walks on to it.
    final spot = nearest(state.x);
    if (state.lift > 0) {
      final from = _t;
      _leap(spot, lift: 0);
      _rooms.add(_Room(from, _t, _dropRoom(state.lift)));
    } else if (settle && (spot - state.x).abs() > 0.5) {
      _walk(spot, speed: tuning.trotSpeed, cross: true);
    }
  }

  /// The room above Mochi's feet the window keeps while it drops back from [lift]: the visit's own (what the caller said
  /// it needs), else the lift, the arc and a body's height.
  double _dropRoom(double lift) {
    final mark = _visitKind == null ? null : _landmark(_visitKind!);
    return mark?.up ?? lift + leapArc + 40;
  }


  void _restart(double now) {
    _cut(now);
    _open();
  }

  void _prune(double now) {
    _props.removeWhere((track) => track.end + StrollPropTrack.lead < now - 1);
    _rooms.removeWhere((room) => room.end + StrollPropTrack.lead < now - 1);
    while (_segments.length > 1 && _segments.first.end <= now) {
      _segments.removeAt(0);
    }
  }

  void _extend(double now) {
    for (var guard = 0; guard < 16 && _segments.isNotEmpty; guard++) {
      final last = _segments.last;
      if (!last.end.isFinite || last.end >= now + lookahead) break;
      _pen(last.end, last.toX, last.facing, last.odometerAtEnd, sink: last.sinkTo, lift: last.liftTo);
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
    bool crosses = false,
    double? sinkTo,
    double? liftTo,
    double arc = 0,
  }) {
    final to = toX ?? _x;
    final end = _t + duration;
    final sunk = sinkTo ?? _sink;
    final raised = liftTo ?? _lift;
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
        crosses: crosses,
        sinkFrom: _sink,
        sinkTo: sunk,
        liftFrom: _lift,
        liftTo: raised,
        arc: arc,
      ),
    );
    if (!hop) _odometer += (to - _x).abs();
    _x = to;
    _t = end;
    _sink = sunk;
    _lift = raised;
  }

  void _hold(PetAnimation animation, double duration, {StrollStyle style = StrollStyle.plain}) {
    if (duration > 0) _add(animation, duration, style: style);
  }

  void _holdForever(PetAnimation animation, {StrollStyle style = StrollStyle.plain}) => _add(animation, double.infinity, style: style);

  /// A one-shot, moving [travel] pixels the way Mochi faces while it plays (never out of the stretch).
  void _act(PetAnimation animation, {double? duration, double travel = 0, StrollStyle style = StrollStyle.plain}) {
    final goal = travel == 0 ? _x : _line!.clamp(_x + travel * _facing);
    _add(animation, duration ?? _length(animation), toX: goal, oneShot: true, style: style);
  }

  /// Turns to face [direction], with a beat to notice the way it's going.
  void _turn(double direction) {
    _facing = direction;
    _hold(PetAnimation.idle, 0.35, style: StrollStyle.notice);
  }

  /// Walks (or trots) to [target], kept on the line (or, with [cross], anywhere on the taskbar, over its buttons: [target]
  /// is then a free spot); turns round first if it's behind.
  void _walk(double target, {double? speed, double? easeIn, double atLeast = 0, bool cross = false}) {
    final goal = (cross ? _bar! : _line!).clamp(target);
    final distance = (goal - _x).abs();
    if (distance < 1) return;
    final direction = goal > _x ? 1.0 : -1.0;
    if (direction != _facing) {
      // Over a button (a trip cut short) there's no stopping to notice the way: it turns on the move.
      if (_free(_x)) {
        _turn(direction);
      } else {
        _facing = direction;
      }
    }
    var pace = speed ?? tuning.walkSpeed;
    final ease = math.min(easeIn ?? tuning.ease, distance / pace);
    // Not before [atLeast] seconds: slower, to arrive as something else finishes.
    if (distance / pace + ease < atLeast && atLeast > ease + 0.1) pace = distance / (atLeast - ease);
    _add(
      pace >= tuning.trotSpeed ? PetAnimation.run : PetAnimation.walk,
      distance / pace + ease,
      toX: goal,
      speed: pace,
      ease: ease,
      crosses: cross,
    );
    if (cross) _line = _zoneAt(goal);
    // At the screen's edge: turn round.
    if (_room(direction) < 1) _turn(-direction);
  }

  /// [x] is over free room (a free stretch), not over a button.
  bool _free(double x) => _zones.any((zone) => x >= zone.minX - 0.5 && x <= zone.maxX + 0.5);

  /// How far Mochi can go in [direction] within [within] (the stretch it's in, by default).
  double _room(double direction, [StrollLine? within]) {
    final span = within ?? _line!;
    return direction > 0 ? span.maxX - _x : _x - span.minX;
  }

  /// Everything Mochi may walk across: the taskbar from the first free stretch to the last, buttons and all, when there's
  /// more than one stretch and it isn't beside Patch (as the Mac's Mochi walks past other apps' status items; it lingers only
  /// where the bar is free, `RoamZone.canLinger`); otherwise just the stretch it's in.
  StrollLine? get _bar => _crossing ? StrollLine(_zones.first.minX, _zones.last.maxX) : _line;

  bool get _crossing => _zones.length > 1 && _home == null;

  /// To the free spot [target] anywhere on the taskbar: a walk over the buttons in between (a trot when it's far), or, with
  /// animation effects off, a fade, as the Mac's Mochi fades with Reduce Motion on.
  void _goTo(double target, {double? speed, double? easeIn}) {
    if (_mode == StrollMode.still) {
      if ((target - _x).abs() >= 1) _hopTo(target);
      return;
    }
    _walk(target, speed: speed ?? ((target - _x).abs() > farWalk ? tuning.trotSpeed : null), easeIn: easeIn, cross: true);
  }

  /// A trip longer than this (logical pixels) is a trot.
  static const double farWalk = 400;

  /// A free spot chosen at random on the taskbar, each stretch as likely as it is long, and at least [atLeast] from Mochi
  /// when the dice allow.
  double _randomSpot({double atLeast = 0}) {
    final total = _zones.fold<double>(0, (sum, zone) => sum + zone.maxX - zone.minX);
    double pick() {
      var roll = _uniform(0, total);
      for (final zone in _zones) {
        if (roll <= zone.maxX - zone.minX) return zone.minX + roll;
        roll -= zone.maxX - zone.minX;
      }
      return _zones.last.maxX;
    }

    var spot = pick();
    for (var tries = 0; tries < 8 && (spot - _x).abs() < atLeast; tries++) {
      spot = pick();
    }
    return spot;
  }

  /// Fades out here and back in at [target] (animation effects off: Mochi doesn't walk then).
  void _hopTo(double target) {
    final activity = _activity;
    _activity = StrollActivity.hop;
    _add(PetAnimation.idle, 0.9, toX: target, hop: true);
    _line = _zoneAt(target);
    _activity = activity;
  }

  /// Mostly towards the side with more room (within [within]: the stretch Mochi is in, by default).
  double _roomyDirection([StrollLine? within]) {
    final right = _room(1, within);
    final total = right + _room(-1, within);
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
      case StrollMode.paused:
        // Reactions paused: it sits where it is (the Mac's paused Mochi rests at home).
        _activity = StrollActivity.still;
        _holdForever(PetAnimation.sit);
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
      case StrollMode.paused:
        _activity = StrollActivity.still;
        _goHome();
        _holdForever(PetAnimation.sit);
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
    if (_hiding) return _chunkHidden();
    if (_home != null) return _chunkBesidePatch();
    _chunkAlone();
  }

  /// Hidden: a long still hold (one picture), then a look around (ears and eyes), again and again.
  void _chunkHidden() {
    _activity = StrollActivity.hide;
    _add(PetAnimation.sit, _uniform(8, 20));
    _act(PetAnimation.lookAround);
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
      case StrollMode.attending || StrollMode.asleep || StrollMode.paused:
        // Their holds last for ever; if one ever ran out, start it again.
        _open();
    }
  }

  /// What Mochi does next when it's free ([_chooseFree]; public for the tests of the weights).
  @visibleForTesting
  StrollActivity chooseFreeActivity() => _chooseFree();

  /// The Mac's weights (`chooseFreeActivity`): wander 3, sniff 2, fidget 1.8, nap 0.45, and the play: zoomies 1,
  /// butterfly 1.2, ball 1, yarn 0.5, leaf 0.6 (its normal intensity: there's no calm or lively setting here, and no
  /// quiet-hours reshuffle). The play only when the stretch Mochi is in is long enough for it.
  StrollActivity _chooseFree() {
    // The longer Claude has been quiet, the sleepier Mochi gets.
    final naps = 0.45 * (_idle > 900 ? 3 : (_idle > 300 ? 2 : 1));
    var options = <(StrollActivity, double)>[
      (StrollActivity.wander, 3),
      (StrollActivity.sniff, 2),
      (StrollActivity.fidget, 1.8),
      (StrollActivity.nap, naps),
      (StrollActivity.trot, 0.5),
      if (_crossing) (StrollActivity.cross, 0.6),
      if (_playFits(StrollActivity.zoomies)) (StrollActivity.zoomies, 1.0),
      // The toys are drawn by the pet's view.
      if (_view && _playFits(StrollActivity.butterfly)) (StrollActivity.butterfly, 1.2),
      if (_view && _playFits(StrollActivity.ball)) (StrollActivity.ball, 1.0),
      if (_view && _playFits(StrollActivity.yarn)) (StrollActivity.yarn, 0.5),
      if (_view && _playFits(StrollActivity.leaf)) (StrollActivity.leaf, 0.6),
      // The taskbar's landmarks (X6), when they're known and allowed and there's a free spot beside them.
      for (final visit in StrollVisit.values)
        if (_visitSpot(visit) != null) (visit.activity, 0.6),
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
      case StrollActivity.cross:
        _crossOver();
      case StrollActivity.zoomies:
        _zoomies();
      case StrollActivity.butterfly:
        _chaseButterfly();
      case StrollActivity.ball:
        _ballPlay(yarn: false);
      case StrollActivity.yarn:
        _ballPlay(yarn: true);
      case StrollActivity.leaf:
        _leafPlay();
      case StrollActivity.swing:
        _swingOnClock();
      case StrollActivity.batStart:
        _batAtStart();
      case StrollActivity.perch:
        _perchOnWidgets();
      default:
        _hold(PetAnimation.idle, _uniform(2, 4));
    }
  }

  // MARK: Landmarks (X6)

  StrollLandmark? _landmark(StrollVisit kind) {
    for (final mark in _landmarks) {
      if (mark.kind == kind) return mark;
    }
    return null;
  }

  /// The free spot nearest [kind]'s landmark, if it's known and allowed and that spot is within its reach (null: no
  /// visit).
  double? _visitSpot(StrollVisit kind) {
    final mark = _landmark(kind);
    if (!_view || mark == null || _zones.isEmpty || _line == null) return null;
    final spot = nearest(mark.x);
    return (spot - mark.x).abs() <= mark.reach ? spot : null;
  }

  /// A leap (with an arc) from where Mochi is to [target], ending [lift] above the taskbar's floor: onto a landmark, or
  /// back down from one.
  void _leap(double target, {required double lift}) {
    final distance = (target - _x).abs();
    if (distance < 0.5 && lift == _lift) return;
    if (distance >= 0.5) _facing = target >= _x ? 1.0 : -1.0;
    // A leap is the recorded one-shot's length (a longer one holds its landing pose).
    _add(PetAnimation.leapCatch, math.max(_length(PetAnimation.leapCatch), distance / 260), toX: target, oneShot: true, liftTo: lift, arc: leapArc);
  }

  /// Starts a visit: the room the window makes for it (the lift, the arc and Mochi's body above its feet) runs from the
  /// leap's start to Mochi's landing back down.
  void _visiting(StrollVisit kind, double from) {
    final mark = _landmark(kind)!;
    _visitKind = kind;
    _visitUntil = _t;
    if (mark.up > 0) _rooms.add(_Room(from, _t, mark.up));
  }

  /// Starts [kind]'s visit now, from where Mochi is (tests): false when it can't (not placed, not free to wander alone,
  /// or the landmark isn't known or has no free spot beside it).
  bool visitNow(StrollVisit kind, double now) {
    if (!isPlaced || _mode != StrollMode.free || _home != null || _buddy || _hiding || now < _holdUntil || _visitSpot(kind) == null) {
      return false;
    }
    _cut(now);
    _perform(kind.activity);
    _activity = StrollActivity.rest;
    _rest(PetAnimation.idle, _uniform(10, 20));
    _extend(now);
    return true;
  }

  /// The clock: walks to the free spot nearest it, leaps up, hangs from the button's top edge swinging for 6–10 seconds,
  /// and drops back.
  void _swingOnClock() {
    final spot = _visitSpot(StrollVisit.clock);
    if (spot == null) return _hold(PetAnimation.idle, _uniform(2, 4));
    final mark = _landmark(StrollVisit.clock)!;
    _activity = StrollActivity.swing;
    _goTo(spot);
    _visitKind = StrollVisit.clock;
    final from = _t;
    _leap(mark.x, lift: mark.lift);
    _activity = StrollActivity.swing;
    _add(PetAnimation.idle, _uniform(6, 10), style: StrollStyle.hang);
    _leap(spot, lift: 0);
    _visiting(StrollVisit.clock, from);
  }

  /// Start: goes to the free spot right beside the button, faces it and bats at it three or four times, with a pounce
  /// in the middle, then steps back.
  void _batAtStart() {
    final spot = _visitSpot(StrollVisit.start);
    if (spot == null) return _hold(PetAnimation.idle, _uniform(2, 4));
    final mark = _landmark(StrollVisit.start)!;
    _activity = StrollActivity.batStart;
    _goTo(spot);
    _visitKind = StrollVisit.start;
    final from = _t;
    final direction = mark.x >= _x ? 1.0 : -1.0;
    if (direction != _facing) _turn(direction);
    _hold(PetAnimation.watch, 0.4);
    final swipes = 3 + _random.nextInt(2);
    for (var i = 0; i < swipes; i++) {
      _act(PetAnimation.bat);
      if (i == 1 || (i == swipes - 1 && _chance(0.4))) {
        _act(PetAnimation.pounce, travel: 3 * _k);
        _hold(PetAnimation.idle, 0.2);
      } else if (_chance(0.4)) {
        _hold(PetAnimation.idle, 0.25);
      }
    }
    _act(_chance(0.5) ? PetAnimation.happyBounce : PetAnimation.blep);
    _visiting(StrollVisit.start, from);
  }

  /// The widgets tile: walks to the free spot nearest it, hops up onto the taskbar's top edge above the tile, sits there
  /// looking out for a few seconds (with a look around), and hops down.
  void _perchOnWidgets() {
    final spot = _visitSpot(StrollVisit.widgets);
    if (spot == null) return _hold(PetAnimation.idle, _uniform(2, 4));
    final mark = _landmark(StrollVisit.widgets)!;
    _activity = StrollActivity.perch;
    _goTo(spot);
    _visitKind = StrollVisit.widgets;
    final from = _t;
    _leap(mark.x, lift: mark.lift);
    _activity = StrollActivity.perch;
    _add(PetAnimation.sit, _uniform(1.2, 2.2));
    _act(PetAnimation.lookAround);
    _add(PetAnimation.sit, _uniform(1, 2));
    _leap(spot, lift: 0);
    _visiting(StrollVisit.widgets, from);
  }

  // MARK: Play (the Mac's RoamBuilder: zoomies, ballPlay, chaseButterfly, leafPlay)

  double get _k => tuning.playScale;

  /// The room each play needs on one side of Mochi (logical pixels): the Mac's, times [StrollTuning.playScale].
  double _playNeed(StrollActivity activity) => _k * switch (activity) {
    StrollActivity.zoomies => 40 + 20 + _MacSpeed.zoom * 0.1 + 2,
    StrollActivity.butterfly => 80,
    StrollActivity.ball || StrollActivity.yarn => 70,
    _ => 60,
  };

  /// What [activity] plays across: the stretch Mochi is in, or, for the zoomies, which may cross the buttons as on the Mac,
  /// the whole taskbar. (The toys stay in a free stretch.)
  StrollLine? _span(StrollActivity activity) => activity == StrollActivity.zoomies ? _bar : _line;

  /// The stretch Mochi is in (the taskbar, for the zoomies) is long enough for [activity]: room for it on each side of the
  /// middle.
  bool _playFits(StrollActivity activity) {
    final span = _span(activity);
    return span != null && span.maxX - span.minX >= 2 * _playNeed(activity);
  }

  double _roomFrom(double x, double direction) => direction > 0 ? _line!.maxX - x : x - _line!.minX;

  /// Where Mochi stands to play: where it is if there's room for [activity] on one side, else the middle of the stretch.
  double _toPlaySpot(StrollActivity activity) {
    final need = _playNeed(activity);
    final span = _span(activity)!;
    if (math.max(_room(1, span), _room(-1, span)) < need) _walk(nearest((span.minX + span.maxX) / 2), cross: true);
    var direction = _roomyDirection(span);
    if (_room(direction, span) < need) direction = -direction;
    if (direction != _facing) _turn(direction);
    return direction;
  }

  StrollPropKey _key(double t, double x, double y, {double opacity = 1, StrollPropPath path = StrollPropPath.linear, double arc = 0}) =>
      StrollPropKey(t, x, y * _k, opacity: opacity, path: path, arc: arc * _k);

  /// Mochi's centre in the plan at [t] (as far as it's been written).
  double _planX(double t) {
    for (final segment in _segments.reversed) {
      if (t >= segment.start) return segment.xAt(math.min(t, segment.end));
    }
    return _x;
  }

  /// Puts a toy's track in the plan, with the room the window needs for it.
  void _prop(ScenePropKind kind, List<StrollPropKey> keys, {required double scale, int variant = 0}) {
    keys.sort((a, b) => a.t.compareTo(b.t));
    if (keys.length < 2) return;
    final track = StrollPropTrack(kind, keys, scale: scale, variant: variant, rollRadius: 3.2 * _k, pixel: _k);
    var reachX = 0.0, reachUp = 0.0;
    for (var t = track.start; t < track.end + 0.1; t += 0.1) {
      final at = track.sample(math.min(t, track.end));
      if (at == null) continue;
      reachX = math.max(reachX, (at.x - _planX(t)).abs());
      reachUp = math.max(reachUp, at.y);
    }
    track.reachX = reachX + propMargin;
    track.reachUp = reachUp + propMargin;
    _props.add(track);
  }

  /// Room around a toy beyond its centre (logical pixels): its own size, and the wobble.
  static const double propMargin = 16;

  /// Sprints along the taskbar, over the buttons if they're in the way, and skids back (`zoomies`): a bounce or a shake,
  /// three to five dashes that each end over a free spot, a tumble or a bounce, a blep.
  void _zoomies() {
    _activity = StrollActivity.zoomies;
    final span = _span(StrollActivity.zoomies)!;
    var direction = _toPlaySpot(StrollActivity.zoomies);
    _act(_chance(0.5) ? PetAnimation.happyBounce : PetAnimation.shake);
    final legs = 3 + _random.nextInt(3);
    final zoom = _MacSpeed.zoom * _k;
    final skidRoom = zoom * 0.1 + 2;
    for (var leg = 0; leg < legs; leg++) {
      if (_room(direction, span) < 40 * _k + skidRoom) direction = -direction;
      final room = _room(direction, span);
      if (leg < legs - 1) {
        final distance = math.min(_uniform(70, 230) * _k, room - skidRoom);
        if (distance <= 20 * _k) break;
        // Sprint, skid to a stop (over free room), hop around, go again.
        final stop = nearest(_x + direction * distance);
        if ((stop - _x) * direction <= 20 * _k) break;
        _walk(stop, speed: zoom, easeIn: 0.18, cross: true);
        direction = -direction;
      } else {
        // The last dash ends with room to spare, where the finale plays.
        final stop = nearest(_x + direction * math.min(_uniform(50, math.max(50, math.min(230, room / _k))) * _k, room));
        if ((stop - _x) * direction > 0) _walk(stop, speed: zoom, easeIn: 0.18, cross: true);
      }
    }
    if (_chance(0.5) && _room(_facing) > 15 * _k) {
      _act(PetAnimation.tumble, travel: 14 * _k);
    } else {
      _act(PetAnimation.happyBounce);
    }
    _act(PetAnimation.blep);
  }

  /// A ball or yarn tossed in from above: Mochi bats it, chases it, pounces, bats again, then catches it (the ball) or
  /// tumbles with it (the yarn) (`ballPlay`).
  void _ballPlay({required bool yarn}) {
    final activity = yarn ? StrollActivity.yarn : StrollActivity.ball;
    _activity = activity;
    final direction = _toPlaySpot(activity);
    final resting = yarn ? _Toys.yarnRest : _Toys.ballRest;
    final bx = _line!.clamp(_x + direction * 15 * _k);
    final side = direction * 6 * _k;
    final keys = [
      _key(_t, bx + side, 21, opacity: 0),
      _key(_t + 0.16, bx + direction * 5 * _k, 18),
      _key(_t + 0.5, bx, resting, path: StrollPropPath.drop),
      _key(_t + 0.8, bx, resting, path: StrollPropPath.arc, arc: 3.4),
      _key(_t + 0.98, bx, resting, path: StrollPropPath.arc, arc: 0.9),
    ];
    _hold(PetAnimation.watch, 1.05);
    _rally(keys, ball: bx, direction: direction, resting: resting, swipes: yarn ? 2 : 2 + _random.nextInt(2), yarn: yarn);
    _prop(yarn ? ScenePropKind.yarn : ScenePropKind.ball, keys, scale: yarn ? _Toys.yarnScale : _Toys.ballScale);
  }

  /// A rally with a toy that's on the taskbar at [ball]: bat, chase, pounce, then the finish (`rally`).
  void _rally(
    List<StrollPropKey> keys, {
    required double ball,
    required double direction,
    required double resting,
    required int swipes,
    required bool yarn,
  }) {
    var bx = ball;
    var way = direction;
    final swipe = PetAnimation.bat.defaultDuration;
    for (var i = 0; i < swipes; i++) {
      if (_roomFrom(bx, way) < 24 * _k) {
        way = -way;
        if (way != _facing) _turn(way);
      }
      final contact = _t + swipe * 0.5;
      _act(PetAnimation.bat, duration: swipe);
      keys.add(_key(contact, bx, resting));
      final room = math.max(0.0, _roomFrom(bx, way) - 6 * _k);
      final distance = math.min(room, (yarn ? _uniform(28, 55) : _uniform(45, 95)) * _k);
      final roll = 0.5 + distance / ((yarn ? 42 : 58) * _k);
      bx += way * distance;
      keys.add(_key(contact + roll, bx, resting, path: StrollPropPath.easeOut));
      // Chase, arriving just behind it as it settles (never overtaking a rolling ball).
      _walk(bx - way * 14 * _k, speed: _MacSpeed.run * _k, atLeast: math.max(0, contact + roll - 0.05 - _t));
      if (_t < contact + roll) _hold(PetAnimation.watch, contact + roll - _t);
      if (i < swipes - 1) {
        _act(PetAnimation.pounce, travel: 5 * _k);
        keys.add(_key(_t, bx, resting));
        // Back off a step to line up the next swipe.
        _hold(PetAnimation.idle, 0.2);
        if ((bx - _x).abs() < 13 * _k) _act(PetAnimation.idle, duration: 0.3, travel: -(13 * _k - (bx - _x).abs()));
      }
    }
    if (yarn) {
      _act(PetAnimation.pounce, travel: 6 * _k);
      final tumbling = _t;
      _act(PetAnimation.tumble, travel: math.min(18 * _k, math.max(0.0, _roomFrom(_x, _facing) - 2)));
      keys.add(_key(tumbling, bx, resting));
      bx = _line!.clamp(_x + way * 13 * _k);
      keys.add(_key(_t, bx, resting, path: StrollPropPath.easeInOut));
      _act(PetAnimation.happyBounce);
      keys.add(_key(_t, bx, resting));
      keys.add(_key(_t + 0.6, bx, resting, opacity: 0));
    } else {
      // Leap and catch it: it pops up into Mochi's paws, and it drops it to roll off a little and go.
      final leap = PetAnimation.leapCatch.defaultDuration;
      final leaping = _t;
      _act(PetAnimation.leapCatch, duration: leap, travel: 10 * _k);
      keys.add(_key(leaping + leap * 0.28, bx, resting));
      keys.add(_key(leaping + leap * 0.5, _x - way * 2 * _k, 9, opacity: 0, path: StrollPropPath.arc, arc: 4));
      _act(PetAnimation.happyBounce);
      _hold(PetAnimation.idle, 0.35);
      final out = _room(_facing) > 30 * _k ? _facing : -_facing;
      keys.add(_key(_t, _x + out * 8 * _k, resting, opacity: 0));
      keys.add(_key(_t + 0.05, _x + out * 8 * _k, resting));
      keys.add(_key(_t + 1.2, _line!.clamp(_x + out * 26 * _k), resting, opacity: 0, path: StrollPropPath.easeOut));
      _act(PetAnimation.blep);
    }
  }

  /// A butterfly drifts in; Mochi spots it, stalks it and leaps for it a few times, and ends up puzzled or delighted as
  /// it flutters off (`chaseButterfly`).
  void _chaseButterfly() {
    _activity = StrollActivity.butterfly;
    var direction = _toPlaySpot(StrollActivity.butterfly);
    var bx = _line!.clamp(_x + direction * _uniform(34, 52) * _k);
    var by = _uniform(11, 15);
    final keys = [
      _key(_t, _line!.clamp(bx + direction * 18 * _k), 24, opacity: 0),
      _key(_t + 1.3, bx, by, path: StrollPropPath.flutter),
    ];
    _act(PetAnimation.leanForward);
    final rounds = 3 + _random.nextInt(2);
    final leap = PetAnimation.leapCatch.defaultDuration;
    for (var round = 0; round < rounds; round++) {
      _walk(bx - direction * 7 * _k, speed: round == 0 ? tuning.trotSpeed : _MacSpeed.run * _k);
      if (_t < keys.last.t) _hold(PetAnimation.watch, keys.last.t - _t + 0.1);
      keys.add(_key(_t + 0.25, bx, by, path: StrollPropPath.flutter));
      final leaping = _t;
      _act(PetAnimation.leapCatch, duration: leap, travel: 8 * _k);
      // It dodges up and flutters on ahead.
      var next = bx + direction * _uniform(26, 52) * _k;
      if (next > _line!.maxX - 4 * _k || next < _line!.minX + 4 * _k) {
        direction = -direction;
        next = bx + direction * _uniform(26, 52) * _k;
      }
      next = _line!.clamp(next);
      by = _uniform(9, 16);
      keys.add(_key(leaping + leap * 0.9, bx + (next - bx) * 0.3, by + 7, path: StrollPropPath.flutter));
      keys.add(_key(leaping + _uniform(1.7, 2.2), next, by, path: StrollPropPath.flutter));
      bx = next;
      final way = bx > _x ? 1.0 : -1.0;
      if (way != _facing) _turn(way);
      direction = _facing;
      if (_chance(0.3)) _hold(PetAnimation.watch, 0.5);
    }
    if (_t < keys.last.t) _hold(PetAnimation.watch, keys.last.t - _t);
    keys.add(_key(_t + 0.4, bx, by, path: StrollPropPath.flutter));
    keys.add(_key(_t + 2.0, _line!.clamp(bx + direction * 30 * _k), 27, opacity: 0, path: StrollPropPath.flutter));
    _hold(PetAnimation.watch, 1.0);
    _act(_chance(0.55) ? PetAnimation.confusedTilt : PetAnimation.happyBounce);
    _prop(ScenePropKind.butterfly, keys, scale: _Toys.butterflyScale, variant: _random.nextInt(2));
  }

  /// A leaf drifts down; Mochi watches it land, sniffs it and bats it away (`leafPlay`).
  void _leafPlay() {
    _activity = StrollActivity.leaf;
    final direction = _toPlaySpot(StrollActivity.leaf);
    final lx = _line!.clamp(_x + direction * _uniform(24, 44) * _k);
    final landing = _t + 2.8;
    final keys = [
      _key(_t, lx - direction * 8 * _k, 26, opacity: 0),
      _key(_t + 0.4, lx - direction * 7 * _k, 22),
      _key(landing, lx, _Toys.leafRest, path: StrollPropPath.drift, arc: 4),
    ];
    _hold(PetAnimation.watch, 1.6);
    _walk(lx - direction * 12 * _k, atLeast: math.max(0, landing - _t));
    if (_t < landing - 0.2) _hold(PetAnimation.watch, landing - _t);
    _act(PetAnimation.sniff);
    final contact = _t + PetAnimation.bat.defaultDuration * 0.5;
    _act(PetAnimation.bat);
    keys.add(_key(contact, lx, _Toys.leafRest));
    final flyTo = _line!.clamp(lx + direction * 26 * _k);
    keys.add(_key(contact + 0.8, lx + (flyTo - lx) * 0.6, 10, path: StrollPropPath.arc, arc: 5));
    keys.add(_key(contact + 2.0, flyTo, _Toys.leafRest, opacity: 0, path: StrollPropPath.drift, arc: 3));
    _act(_chance(0.5) ? PetAnimation.happyBounce : PetAnimation.blep);
    _prop(ScenePropKind.leaf, keys, scale: _Toys.leafScale, variant: _random.nextInt(3));
  }

  /// Wanders off to somewhere free on the taskbar (any stretch, over the buttons to get there), or, in a stretch of its own,
  /// a way along it.
  void _wander() {
    if (_crossing) {
      _goTo(_randomSpot(atLeast: 120));
    } else {
      var direction = _roomyDirection();
      if (_room(direction) < 120) direction = -direction;
      _walk(_x + direction * _uniform(120, 700));
    }
    final direction = _facing;
    _hold(PetAnimation.idle, _uniform(0.6, 1.4));
    if (_chance(0.45)) _act(PetAnimation.lookAround);
    if (_chance(0.25)) _walk(_x - direction * _uniform(30, 90));
  }

  void _trot() {
    if (_crossing) {
      final spot = _randomSpot(atLeast: 250);
      final direction = spot >= _x ? 1.0 : -1.0;
      if (direction != _facing) _turn(direction);
      _hold(PetAnimation.idle, 0.3, style: StrollStyle.notice);
      _walk(spot, speed: tuning.trotSpeed, cross: true);
    } else {
      var direction = _roomyDirection();
      if (_room(direction) < 250) direction = -direction;
      if (direction != _facing) _turn(direction);
      _hold(PetAnimation.idle, 0.3, style: StrollStyle.notice);
      _walk(_x + direction * _uniform(250, 700), speed: tuning.trotSpeed);
    }
    _act(_chance(0.5) ? PetAnimation.happyBounce : PetAnimation.blep);
  }

  /// Over to another free stretch, a walk (a trot when it's far) over the buttons in between, and a look around there.
  void _crossOver() {
    final others = [for (final zone in _zones) if (zone != _line) zone];
    if (others.isEmpty) return _hold(PetAnimation.idle, _uniform(2, 4));
    final zone = others[_random.nextInt(others.length)];
    _hold(PetAnimation.idle, 0.4, style: StrollStyle.notice);
    _goTo(zone.minX + (zone.maxX - zone.minX) * _uniform(0.2, 0.8));
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
