// W19, desktop adventures. Port of Sources/TamagotchiCore/Features/AdventureModels.swift (the settings),
// Adventure/AdventureScheduler.swift (when Mochi sets off by itself), Adventure/AdventureTerrain.swift (what it can walk
// on) and Adventure/AdventurePlanner.swift (the route: segments, plans, samples, adapting to moved windows, hurrying
// home, a moment to be petted), as pure Dart.
//
// Coordinates and units are the Mac's: global points, y up, as AppKit reports them; Mochi's feet are the point. The Mac
// walks along the menu bar's windows and the Dock and hops back up into the menu bar; an app of another platform maps its
// own screen onto these numbers (Mochi for Windows: one display's logical pixels, y up from its bottom edge, the
// taskbar's top as the floor) and says where its "menu bar" is by the `bounds` it gives the terrain. Everything here is
// deterministic for a seed and a time: no clocks, no screens.

import 'dart:math' as math;

import '../model/animations.dart';
import '../model/ease.dart';
import '../model/random.dart';

// MARK: - Settings

/// How often Mochi sets off by itself (the Mac's `AdventureFrequency`).
enum AdventureFrequency {
  never,
  rarely,
  sometimes;

  /// "Never", "Rarely", "Sometimes".
  String get title => name[0].toUpperCase() + name.substring(1);
}

/// Settings for desktop adventures, saved under `adventure` (the Mac's keys and defaults).
class AdventureSettings {
  const AdventureSettings({this.enabled = true, this.spontaneous = AdventureFrequency.sometimes});

  final bool enabled;
  final AdventureFrequency spontaneous;

  AdventureSettings copyWith({bool? enabled, AdventureFrequency? spontaneous}) =>
      AdventureSettings(enabled: enabled ?? this.enabled, spontaneous: spontaneous ?? this.spontaneous);

  Map<String, Object?> toJson() => {'enabled': enabled, 'spontaneous': spontaneous.name};

  static AdventureSettings fromJson(Object? json) {
    if (json is! Map) return const AdventureSettings();
    final frequency = AdventureFrequency.values.where((f) => f.name == json['spontaneous']).firstOrNull;
    return AdventureSettings(enabled: json['enabled'] is bool ? json['enabled'] as bool : true, spontaneous: frequency ?? AdventureFrequency.sometimes);
  }

  @override
  bool operator ==(Object other) => other is AdventureSettings && other.enabled == enabled && other.spontaneous == spontaneous;

  @override
  int get hashCode => Object.hash(enabled, spontaneous);
}

// MARK: - Scheduler

/// When Mochi sets off on an adventure by itself: after a seeded stretch of eligible time (about 45–60 min "sometimes",
/// 2–3 h "rarely"), counted only while nothing needs anyone.
class AdventureScheduler {
  AdventureScheduler({required int seed, required AdventureFrequency frequency})
    : _frequency = frequency,
      _rng = SplitMix64(seed ^ 0x5350_4F4E_5441_4E45) {
    threshold = _drawThreshold();
  }

  AdventureFrequency _frequency;
  final SplitMix64 _rng;
  double? _lastTick;

  AdventureFrequency get frequency => _frequency;

  /// Eligible time counted towards the next adventure.
  double accumulated = 0;

  /// Eligible time the next adventure waits for (infinite for "never").
  double threshold = double.infinity;

  /// Gaps between ticks longer than this (sleep, a stalled clock) count as this much.
  static const double maxStep = 5;

  /// The stretch of eligible time between two adventures (lower, upper), or null for "never".
  static (double, double)? interval(AdventureFrequency frequency) => switch (frequency) {
    AdventureFrequency.never => null,
    AdventureFrequency.rarely => (2 * 3600.0, 3 * 3600.0),
    AdventureFrequency.sometimes => (45 * 60.0, 60 * 60.0),
  };

  /// Counts the time since the last tick if [eligible]; true when an adventure should start now.
  bool tick({required double now, required bool eligible, required AdventureFrequency frequency}) {
    if (frequency != _frequency) {
      _frequency = frequency;
      accumulated = 0;
      threshold = _drawThreshold();
    }
    final last = _lastTick;
    _lastTick = now;
    if (last == null || !eligible) return false;
    accumulated += math.min(maxStep, math.max(0, now - last));
    if (accumulated < threshold) return false;
    reset();
    return true;
  }

  /// An adventure happened (by itself or because you asked): the next one is a whole stretch away.
  void reset() {
    accumulated = 0;
    threshold = _drawThreshold();
  }

  double _drawThreshold() {
    final range = interval(_frequency);
    if (range == null) return double.infinity;
    return _rng.nextIn(range.$1, range.$2);
  }
}

// MARK: - Geometry

/// A point in screen points (y up). During an adventure it is where Mochi's feet are.
class AdventurePoint {
  const AdventurePoint(this.x, this.y);

  final double x;
  final double y;

  double distanceTo(AdventurePoint other) => math.sqrt((other.x - x) * (other.x - x) + (other.y - y) * (other.y - y));

  @override
  bool operator ==(Object other) => other is AdventurePoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'AdventurePoint($x, $y)';
}

/// A rectangle as CoreGraphics has it: its origin is the bottom left (y up).
class AdventureRect {
  const AdventureRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  double get minX => x;
  double get maxX => x + width;
  double get minY => y;
  double get maxY => y + height;
  double get midX => x + width / 2;
  double get midY => y + height / 2;

  AdventureRect inset(double dx, double dy) => AdventureRect(x + dx, y + dy, width - 2 * dx, height - 2 * dy);

  /// [other] lies wholly inside this.
  bool contains(AdventureRect other) => other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY;

  @override
  bool operator ==(Object other) => other is AdventureRect && other.x == x && other.y == y && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'AdventureRect($x, $y, $width×$height)';
}

/// A closed stretch of x (the Dock's, the menu bar's: `ClosedRange<Double>`).
class AdventureSpan {
  const AdventureSpan(this.lower, this.upper);

  final double lower;
  final double upper;

  bool contains(double x) => x >= lower && x <= upper;

  @override
  bool operator ==(Object other) => other is AdventureSpan && other.lower == lower && other.upper == upper;

  @override
  int get hashCode => Object.hash(lower, upper);

  @override
  String toString() => 'AdventureSpan($lower…$upper)';
}

/// A stretch of window top Mochi can walk along.
class AdventureLedge {
  const AdventureLedge({required this.minX, required this.maxX, required this.y, required this.window});

  final double minX;
  final double maxX;
  final double y;

  /// The window it belongs to (its index, front to back).
  final int window;

  double get width => maxX - minX;
  double get midX => (minX + maxX) / 2;

  /// [x] kept [margin] inside the ledge (its middle when it is too short for that).
  double clamp(double x, {required double margin}) {
    final lo = minX + margin;
    final hi = maxX - margin;
    if (lo > hi) return midX;
    return math.min(hi, math.max(lo, x));
  }

  @override
  bool operator ==(Object other) => other is AdventureLedge && other.minX == minX && other.maxX == maxX && other.y == y && other.window == window;

  @override
  int get hashCode => Object.hash(minX, maxX, y, window);

  @override
  String toString() => 'AdventureLedge($minX…$maxX at $y, window $window)';
}

// MARK: - Terrain

/// What Mochi can walk on during a desktop adventure: the floor (the top of the Dock or taskbar, or the bottom of the
/// screen), the screen's side edges, and the tops of other apps' windows where nothing in front of them hides them. Only
/// window frames are known, never what they show.
class AdventureTerrain {
  /// [bounds]: where Mochi may be (the screen's visible frame). [floorY]: the top of the Dock (the bottom of [bounds]
  /// when null). [dock]: its stretch of floor, when it sits at the bottom. [windows]: other apps' window frames, front to
  /// back. [headroom]: Mochi's height plus a margin: window tops with less room above are skipped.
  AdventureTerrain({required this.bounds, double? floorY, this.dock, List<AdventureRect> windows = const [], double headroom = 52})
    : floorY = floorY ?? bounds.minY {
    ledges = _ledges(windows, bounds, this.floorY, headroom);
  }

  /// Where Mochi may be.
  final AdventureRect bounds;

  /// The floor.
  final double floorY;

  /// The stretch of floor the Dock covers, when it sits at the bottom of the screen.
  final AdventureSpan? dock;

  /// Visible window tops, highest first.
  late final List<AdventureLedge> ledges;

  /// Windows smaller than this are not worth climbing on (palettes, popovers, tooltips).
  static const double minimumWindowWidth = 160;
  static const double minimumWindowHeight = 90;

  /// The shortest stretch of window top Mochi walks along.
  static const double minimumLedge = 56;

  /// At most this many windows (front to back) are looked at.
  static const int maximumWindows = 16;

  static List<AdventureLedge> _ledges(List<AdventureRect> windows, AdventureRect bounds, double floorY, double headroom) {
    final considered = windows.take(maximumWindows).toList();
    final result = <AdventureLedge>[];
    for (final (index, window) in considered.indexed) {
      if (window.width < minimumWindowWidth || window.height < minimumWindowHeight) continue;
      final top = window.maxY;
      // Room above it for Mochi (a maximised window's top is right under the menu bar), and off the floor.
      if (!(top <= bounds.maxY - headroom && top >= floorY + headroom)) continue;
      final lo = math.max(window.minX, bounds.minX);
      final hi = math.min(window.maxX, bounds.maxX);
      if (hi - lo < minimumLedge) continue;
      var spans = [AdventureSpan(lo, hi)];
      // Windows in front take away what they cover: Mochi would be standing inside them.
      for (final front in considered.take(index)) {
        if (front.minY < top + headroom && front.maxY > top - 2) {
          spans = _subtract(AdventureSpan(front.minX - 4, front.maxX + 4), spans);
        }
      }
      for (final span in spans) {
        if (span.upper - span.lower >= minimumLedge) {
          result.add(AdventureLedge(minX: span.lower, maxX: span.upper, y: top, window: index));
        }
      }
    }
    // A stable sort: highest first, then leftmost (Swift's sort here has no ties to keep).
    result.sort((a, b) => a.y != b.y ? b.y.compareTo(a.y) : a.minX.compareTo(b.minX));
    return result;
  }

  static List<AdventureSpan> _subtract(AdventureSpan cut, List<AdventureSpan> spans) {
    final result = <AdventureSpan>[];
    for (final span in spans) {
      if (cut.upper <= span.lower || cut.lower >= span.upper) {
        result.add(span);
        continue;
      }
      if (cut.lower > span.lower) result.add(AdventureSpan(span.lower, cut.lower));
      if (cut.upper < span.upper) result.add(AdventureSpan(cut.upper, span.upper));
    }
    return result;
  }

  /// A window covering the whole screen, menu bar and all: a full-screen app is showing.
  static bool looksFullScreen({required List<AdventureRect> windows, required AdventureRect screen}) =>
      windows.any((window) => window.inset(-1, -1).contains(screen));

  /// The highest thing to land on at [point]'s x, at or below its y (the floor when there is nothing else).
  ({double y, AdventureLedge? ledge}) surface({required AdventurePoint below}) {
    for (final ledge in ledges) {
      if (ledge.y <= below.y + 0.001 && below.x >= ledge.minX && below.x <= ledge.maxX) return (y: ledge.y, ledge: ledge);
    }
    return (y: floorY, ledge: null);
  }

  /// The ledge Mochi stands on at [point] (null on the floor or in the air).
  AdventureLedge? ledge(AdventurePoint point, {double tolerance = 0}) {
    for (final ledge in ledges) {
      if ((ledge.y - point.y).abs() < 1.5 && point.x >= ledge.minX - tolerance && point.x <= ledge.maxX + tolerance) return ledge;
    }
    return null;
  }

  /// Something holds Mochi up at [point]: the floor, or a window top.
  bool supports(AdventurePoint point, {double tolerance = 0}) => (point.y - floorY).abs() < 1.5 || ledge(point, tolerance: tolerance) != null;

  @override
  bool operator ==(Object other) {
    if (other is! AdventureTerrain || other.bounds != bounds || other.floorY != floorY || other.dock != dock) return false;
    if (other.ledges.length != ledges.length) return false;
    for (var i = 0; i < ledges.length; i++) {
      if (other.ledges[i] != ledges[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(bounds, floorY, dock, Object.hashAll(ledges));
}

// MARK: - Segments

/// Body-language accents the renderer adds on top of the pose (the subset of the Mac's `RoamSegment.Style` the
/// adventures use).
enum AdventureStyle {
  plain,

  /// Gathering for a jump: squashed low.
  crouch,

  /// Pushing off: a quick stretch out of the crouch.
  launch,

  /// Dropping in from the top, or in the air.
  drop,

  /// Landing squash.
  land,

  /// Ears up, looking towards where it is about to go ("huh?").
  notice,
}

/// What a segment does.
enum AdventureMove {
  /// In place: standing, sitting, sniffing, landing.
  hold,

  /// Along a window top or the floor (eased in and out).
  walk,

  /// A jump in an arc above the straight line.
  hop,

  /// Dropping, faster and faster.
  fall,

  /// Up a screen edge.
  climb,
}

/// Where in the trip a segment is.
enum AdventurePhase implements Comparable<AdventurePhase> {
  /// Dropping in from the menu bar (or out of your hand).
  arriving,

  /// Along window tops, hopping between them.
  exploring,

  /// Down to the floor.
  descending,

  /// A sit on the Dock.
  dock,

  /// Over to a screen edge.
  toEdge,

  /// Up the screen edge.
  climbing,

  /// The hop back up into the menu bar.
  returning;

  @override
  int compareTo(AdventurePhase other) => index - other.index;

  bool operator <(AdventurePhase other) => index < other.index;
  bool operator <=(AdventurePhase other) => index <= other.index;
  bool operator >(AdventurePhase other) => index > other.index;
  bool operator >=(AdventurePhase other) => index >= other.index;

  /// "arriving", "exploring", "descending", "dock", "toEdge", "climbing", "returning".
  String get title => name;
}

/// Fraction of the distance covered after [t] seconds of a trapezoid profile lasting [d] seconds that ramps up over [a0]
/// and down over [b0] (linear changes of speed): the Mac's `RoamSegment.trapezoid`.
double trapezoid(double t, double d, double a0, double b0) {
  if (!(d > 0)) return 1;
  var a = math.max(0.0, a0);
  var b = math.max(0.0, b0);
  if (a + b > d) {
    final k = d / (a + b);
    a *= k;
    b *= k;
  }
  final cruise = d - a - b;
  final total = a / 2 + cruise + b / 2;
  if (!(total > 0)) return t >= d ? 1 : 0;
  final tt = math.min(math.max(t, 0.0), d);
  final double s;
  if (tt < a) {
    s = tt * tt / (2 * a);
  } else if (tt <= a + cruise || b <= 0) {
    s = a / 2 + (tt - a);
  } else {
    final r = d - tt;
    s = total - r * r / (2 * b);
  }
  return Ease.clamp(s / total);
}

/// One continuous piece of a desktop adventure, a pure function of time. Each one starts where (and when) the previous
/// one ended.
class AdventureSegment {
  AdventureSegment({
    required this.start,
    required this.end,
    required this.from,
    required this.to,
    required this.move,
    required this.animation,
    required this.facing,
    required this.arc,
    required this.turn,
    required this.turnTo,
    required this.phase,
    required this.style,
    required this.odometer,
    this.line,
  });

  double start;
  double end;
  AdventurePoint from;
  AdventurePoint to;
  final AdventureMove move;
  final PetAnimation animation;

  /// +1 facing right, -1 facing left (climbing: towards the edge).
  final double facing;

  /// How high a hop rises above the straight line between its ends.
  final double arc;

  /// Body rotation in radians (clockwise on screen) at the start and at the end: a lean into the edge while climbing.
  final double turn;
  double turnTo;
  final AdventurePhase phase;
  final AdventureStyle style;

  /// Distance travelled before this segment (gaits are locked to it).
  double odometer;

  /// Something Mochi says as the segment starts.
  String? line;

  double get duration => end - start;

  double progress(double t) {
    if (!(end > start)) return t >= end ? 1 : 0;
    return Ease.clamp((t - start) / (end - start));
  }

  /// Ease in and out of walks and climbs, in seconds.
  static const double ease = 0.15;

  AdventurePoint point(double t) {
    final p = progress(t);
    switch (move) {
      case AdventureMove.hold:
        return from;
      case AdventureMove.walk || AdventureMove.climb:
        final f = trapezoid(math.min(math.max(t, start), end) - start, duration, ease, ease);
        return AdventurePoint(Ease.lerp(from.x, to.x, f), Ease.lerp(from.y, to.y, f));
      case AdventureMove.hop:
        return AdventurePoint(Ease.lerp(from.x, to.x, p), Ease.lerp(from.y, to.y, p) + arc * Ease.hop(p));
      case AdventureMove.fall:
        return AdventurePoint(Ease.lerp(from.x, to.x, p), from.y + (to.y - from.y) * p * p);
    }
  }

  double rotation(double t) {
    if ((turnTo - turn).abs() <= 0.0001) return turn;
    return Ease.lerp(turn, turnTo, Ease.smooth(Ease.segment(progress(t), 0, move == AdventureMove.hop ? 0.6 : 1)));
  }

  /// The segment cut short at [t]: from where it started to where Mochi is then.
  AdventureSegment cut(double t) {
    final copy = copyWith();
    copy.to = point(t);
    copy.turnTo = rotation(t);
    copy.end = math.max(start, t);
    return copy;
  }

  AdventureSegment copyWith({double? start, double? end, AdventurePoint? from, double? odometer, bool clearLine = false}) => AdventureSegment(
    start: start ?? this.start,
    end: end ?? this.end,
    from: from ?? this.from,
    to: to,
    move: move,
    animation: animation,
    facing: facing,
    arc: arc,
    turn: turn,
    turnTo: turnTo,
    phase: phase,
    style: style,
    odometer: odometer ?? this.odometer,
    line: clearLine ? null : line,
  );

  @override
  bool operator ==(Object other) =>
      other is AdventureSegment &&
      other.start == start &&
      other.end == end &&
      other.from == from &&
      other.to == to &&
      other.move == move &&
      other.animation == animation &&
      other.facing == facing &&
      other.arc == arc &&
      other.turn == turn &&
      other.turnTo == turnTo &&
      other.phase == phase &&
      other.style == style &&
      other.odometer == odometer &&
      other.line == line;

  @override
  int get hashCode => Object.hash(start, end, from, to, move, animation, facing, arc, turn, turnTo, phase, style, odometer, line);

  @override
  String toString() => 'AdventureSegment(${move.name} ${phase.name} ${animation.name} $start–$end $from→$to)';
}

/// Where Mochi is and what it does at one instant of an adventure.
class AdventureSample {
  const AdventureSample({
    required this.point,
    required this.facing,
    required this.rotation,
    required this.animation,
    required this.elapsed,
    required this.duration,
    required this.move,
    required this.phase,
    required this.style,
    required this.progress,
    required this.speed,
    required this.odometer,
    required this.finished,
  });

  final AdventurePoint point;
  final double facing;

  /// Body rotation in radians, clockwise on screen.
  final double rotation;
  final PetAnimation animation;

  /// Time into the segment.
  final double elapsed;

  /// The segment length for one-shots; null for loops.
  final double? duration;
  final AdventureMove move;
  final AdventurePhase phase;
  final AdventureStyle style;

  /// 0…1 through the segment.
  final double progress;

  /// Points per second.
  final double speed;

  /// Distance travelled so far (gaits are locked to it).
  final double odometer;

  /// The plan has run out: Mochi is back in the menu bar.
  final bool finished;

  bool get isAirborne => move == AdventureMove.hop || move == AdventureMove.fall;
}

// MARK: - Plan

/// A whole adventure, from the drop out of the menu bar to the hop back up into it.
class AdventurePlan {
  AdventurePlan({
    required this.segments,
    required this.homeX,
    required this.bar,
    required this.wall,
    required this.exploreUntil,
    required this.seed,
    this.homeY,
  });

  List<AdventureSegment> segments;

  /// Where on the menu bar (screen x) the last hop lands.
  double homeX;

  /// The stretch of menu bar Mochi may come back to.
  final AdventureSpan bar;

  /// The screen edge Mochi climbs: +1 right, -1 left.
  final double wall;

  /// Exploring window tops stops then; the way home takes the rest.
  double exploreUntil;
  final int seed;

  /// Where Mochi's feet land when home is below rather than above (Windows: the taskbar at the bottom of the screen).
  /// Null: home is the Mac's menu bar, out of the top of the screen.
  final double? homeY;

  double get start => segments.isEmpty ? 0 : segments.first.start;
  double get end => segments.isEmpty ? 0 : segments.last.end;

  AdventurePlan copy() =>
      AdventurePlan(segments: List.of(segments), homeX: homeX, bar: bar, wall: wall, exploreUntil: exploreUntil, seed: seed, homeY: homeY);

  AdventureSegment? segment(double t) {
    if (segments.isEmpty) return null;
    if (t < segments.first.start) return segments.first;
    for (var i = segments.length - 1; i >= 0; i--) {
      if (segments[i].start <= t) return segments[i];
    }
    return null;
  }

  AdventureSample sample(double t) {
    final segment = this.segment(t);
    if (segment == null) {
      return AdventureSample(
        point: AdventurePoint(homeX, 0),
        facing: 1,
        rotation: 0,
        animation: PetAnimation.idle,
        elapsed: 0,
        duration: null,
        move: AdventureMove.hold,
        phase: AdventurePhase.returning,
        style: AdventureStyle.plain,
        progress: 1,
        speed: 0,
        odometer: 0,
        finished: true,
      );
    }
    final time = math.min(math.max(t, segment.start), segment.end);
    final point = segment.point(time);
    final travelled = segment.move == AdventureMove.hold ? 0.0 : point.distanceTo(segment.from);
    var speed = 0.0;
    if (segment.move != AdventureMove.hold && t < segment.end) {
      final nextTime = math.min(segment.end, time + 0.01);
      final next = segment.point(nextTime);
      speed = point.distanceTo(next) / math.max(0.0001, nextTime - time);
    }
    final ended = t >= segment.end;
    final loops = segment.animation.isLoop;
    return AdventureSample(
      point: point,
      facing: segment.facing,
      rotation: segment.rotation(time),
      animation: ended && !loops ? PetAnimation.idle : segment.animation,
      elapsed: time - segment.start,
      duration: loops ? null : segment.duration,
      move: ended ? AdventureMove.hold : segment.move,
      phase: segment.phase,
      style: ended ? AdventureStyle.plain : segment.style,
      progress: segment.progress(time),
      speed: speed,
      odometer: segment.odometer + travelled,
      finished: t >= end,
    );
  }
}

// MARK: - Planner

/// Mochi's size and speeds at adventure scale (points, points per second).
class AdventureMetrics {
  AdventureMetrics({this.halfWidth = 26, this.height = 47})
    : walk = halfWidth * 2.6,
      run = halfWidth * 6.5,
      climb = halfWidth * 4.5;

  final double halfWidth;
  final double height;
  final double walk;
  final double run;
  final double climb;

  @override
  bool operator ==(Object other) => other is AdventureMetrics && other.halfWidth == halfWidth && other.height == height;

  @override
  int get hashCode => Object.hash(halfWidth, height);
}

/// Plans Mochi's desktop adventures: a drop onto whatever is below, a stroll along window tops hopping from one to the
/// next, down to the Dock (taskbar) for a sit, over to the screen edge nearest home, up it, and one hop back up out of
/// the screen's top. Deterministic per seed; sampled purely by time; re-routed from where Mochi is when windows move.
abstract final class AdventurePlanner {
  /// Hops reach at most this high, and this far across a gap.
  static const double maxRise = 230;
  static const double maxGap = 300;

  /// Falls accelerate like this (points per second², cartoon gravity).
  static const double gravity = 2400;

  /// Climbing, Mochi leans this far into the screen edge (radians).
  static const double climbLean = 0.14;

  /// [start]: where Mochi's feet are as it drops in. [bar]: the stretch it may come back to (its roaming zone). [length]:
  /// how long the adventure should take, roughly (seconds). [facing]: which way Mochi faces as it drops in.
  static AdventurePlan plan({
    required AdventurePoint from,
    required double at,
    required AdventureTerrain terrain,
    required AdventureSpan bar,
    required int seed,
    AdventureMetrics? metrics,
    (double, double) length = (40, 75),
    double facing = 1,
    double? homeY,
  }) {
    final m = metrics ?? AdventureMetrics();
    final rng = SplitMix64(seed ^ 0x4144_5645_4E54_5552);
    final wall = (bar.lower + bar.upper) / 2 >= terrain.bounds.midX ? 1.0 : -1.0;
    final total = rng.nextIn(length.$1, length.$2);
    final builder = _Builder(t: at, at: from, terrain: terrain, metrics: m, rng: rng)..homeY = homeY;
    builder.facing = facing >= 0 ? 1 : -1;
    builder.arrive(from);
    final exploreUntil = at + math.max(4, total - builder.estimateWayHome(wall));
    builder.explore(exploreUntil);
    builder.goHome(wall: wall, bar: bar, strollUntil: exploreUntil);
    return AdventurePlan(
      segments: builder.segments,
      homeX: builder.homeX,
      bar: bar,
      wall: wall,
      exploreUntil: exploreUntil,
      seed: seed,
      homeY: homeY,
    );
  }

  /// The windows changed. When that takes the ground from under Mochi (or from where it is about to land), it falls from
  /// where it is and carries on from wherever it ends up; when it only spoils the way ahead, the rest is re-routed from
  /// the current spot. Null when the plan still holds.
  static AdventurePlan? adapt(AdventurePlan plan, {required double at, required AdventureTerrain to, AdventureMetrics? metrics}) {
    final m = metrics ?? AdventureMetrics();
    final t = at;
    if (!(t < plan.end)) return null;
    final current = plan.segment(t);
    if (current == null || !(current.phase <= AdventurePhase.descending)) return null;
    final tolerance = m.halfWidth * 0.3;
    final sample = plan.sample(t);
    bool holds(AdventurePoint point) => to.supports(point, tolerance: tolerance);
    // Only where Mochi stands counts (a hop's mid-air waypoints never do).
    final standing = plan.segments
        .where((s) => s.end > t && s.phase <= AdventurePhase.descending && (s.move == AdventureMove.hold || s.move == AdventureMove.walk))
        .toList();
    final grounded = !sample.isAirborne && current.move != AdventureMove.climb;
    final groundGone = grounded && !holds(sample.point);
    final nextStanding = standing.where((s) => s.start >= t).firstOrNull;
    final landingGone = sample.isAirborne && !(nextStanding == null ? true : holds(nextStanding.from));
    final aheadGone = standing.any((s) => s.start > t && (!holds(s.from) || !holds(s.to)));
    if (!(groundGone || landingGone || aheadGone)) return null;

    final kept = plan.segments.where((s) => s.end <= t).toList();
    var resumeAt = t;
    var from = sample.point;
    if (!groundGone && !landingGone && t < current.end) {
      // Only the way ahead changed: finish what Mochi is doing first (a hop never stops mid-air).
      kept.add(current);
      resumeAt = current.end;
      from = current.to;
    } else if (current.start < t) {
      kept.add(current.cut(t));
    }
    final mixed = plan.seed ^ (resumeAt * 1000).round();
    final builder = _Builder(t: resumeAt, at: from, terrain: to, metrics: m, rng: SplitMix64(mixed))..homeY = plan.homeY;
    builder.facing = sample.facing;
    builder.odometer = sample.odometer;
    builder.phase = current.phase;
    if (!holds(from)) builder.dropToSurface();
    if (builder.phase <= AdventurePhase.exploring) builder.explore(math.max(plan.exploreUntil, resumeAt + 2));
    builder.goHome(wall: plan.wall, bar: plan.bar, strollUntil: plan.exploreUntil);
    final adapted = plan.copy();
    adapted.segments = kept + builder.segments;
    adapted.homeX = builder.homeX;
    return adapted;
  }

  /// Called home early (Claude needs you, a window opened, adventures were turned off): one big leap from wherever Mochi
  /// is straight back up out of the screen.
  static AdventurePlan hurryHome(AdventurePlan plan, {required double at, required AdventureTerrain terrain, AdventureMetrics? metrics}) {
    final m = metrics ?? AdventureMetrics();
    final t = at;
    final sample = plan.sample(t);
    if (sample.finished || (sample.phase == AdventurePhase.returning && sample.isAirborne)) return plan;
    final kept = plan.segments.where((s) => s.end <= t).toList();
    final current = plan.segment(t);
    if (current != null && current.start < t && t < current.end) kept.add(current.cut(t));
    final builder = _Builder(
      t: t,
      at: sample.point,
      terrain: terrain,
      metrics: m,
      rng: SplitMix64(plan.seed ^ (t * 1000).round()),
    );
    builder.facing = sample.facing;
    builder.angle = sample.rotation;
    builder.odometer = sample.odometer;
    builder.phase = AdventurePhase.returning;
    builder.homeY = plan.homeY;
    final home = math.min(plan.bar.upper, math.max(plan.bar.lower, sample.point.x));
    if (!sample.isAirborne) builder.hold(PetAnimation.idle, 0.15, style: AdventureStyle.crouch);
    builder.leapHome(home);
    final hurried = plan.copy();
    hurried.segments = kept + builder.segments;
    hurried.homeX = home;
    return hurried;
  }

  /// A moment in place where Mochi stands (a happy bounce when you pet it); everything after waits for it. Null while it
  /// is in the air, crouching for a jump, on a wall or on its way home.
  static AdventurePlan? interject(PetAnimation animation, {required AdventurePlan into, required double at}) {
    final plan = into;
    final t = at;
    var index = -1;
    for (var i = plan.segments.length - 1; i >= 0; i--) {
      if (plan.segments[i].start <= t) {
        index = i;
        break;
      }
    }
    if (index < 0 || !(t < plan.segments[index].end)) return null;
    final current = plan.segments[index];
    if (!((current.move == AdventureMove.hold || current.move == AdventureMove.walk) &&
        current.phase < AdventurePhase.climbing &&
        current.turn.abs() < 0.01 &&
        current.style == AdventureStyle.plain)) {
      return null;
    }
    final point = current.point(t);
    final duration = animation.defaultDuration;
    final odometer = current.odometer + (current.move == AdventureMove.hold ? 0 : point.distanceTo(current.from));
    final segments = plan.segments.sublist(0, index);
    if (t > current.start) segments.add(current.cut(t));
    segments.add(
      AdventureSegment(
        start: t,
        end: t + duration,
        from: point,
        to: point,
        move: AdventureMove.hold,
        animation: animation,
        facing: current.facing,
        arc: 0,
        turn: 0,
        turnTo: 0,
        phase: current.phase,
        style: AdventureStyle.plain,
        odometer: odometer,
      ),
    );
    // Then the rest of what it was doing, from here.
    segments.add(current.copyWith(start: t + duration, end: current.end + duration, from: point, odometer: odometer, clearLine: true));
    for (final later in plan.segments.skip(index + 1)) {
      segments.add(later.copyWith(start: later.start + duration, end: later.end + duration));
    }
    final result = plan.copy();
    result.segments = segments;
    if (result.exploreUntil > t) result.exploreUntil += duration;
    return result;
  }
}

class _Builder {
  _Builder({required this.t, required this.at, required this.terrain, required this.metrics, required this.rng}) : homeX = at.x;

  double t;
  AdventurePoint at;
  double facing = 1;

  /// Current body rotation (on a wall).
  double angle = 0;
  double odometer = 0;
  AdventurePhase phase = AdventurePhase.arriving;
  final AdventureTerrain terrain;
  final AdventureMetrics metrics;
  final SplitMix64 rng;
  final List<AdventureSegment> segments = [];
  double homeX;

  /// Where Mochi's feet land at home when home is below (see [AdventurePlan.homeY]).
  double? homeY;
  final List<int> visited = [];
  int lines = 0;
  bool strolled = false;

  AdventureRect get bounds => terrain.bounds;
  double get lowX => bounds.minX + metrics.halfWidth;
  double get highX => bounds.maxX - metrics.halfWidth;

  double uniform(double lower, double upper) => rng.nextIn(lower, upper);
  bool chance(double p) => rng.nextUnit() < p;

  /// A line now and then (never more than three an adventure).
  String? say(String text, {double odds = 1}) {
    if (lines >= 3 || !chance(odds)) return null;
    lines++;
    return text;
  }

  // MARK: Primitives

  void append(
    AdventureMove move,
    AdventurePoint target, {
    required double duration,
    required PetAnimation animation,
    double arc = 0,
    double? turnTo,
    AdventureStyle style = AdventureStyle.plain,
    String? line,
  }) {
    final end = turnTo ?? angle;
    segments.add(
      AdventureSegment(
        start: t,
        end: t + duration,
        from: at,
        to: target,
        move: move,
        animation: animation,
        facing: facing,
        arc: arc,
        turn: angle,
        turnTo: end,
        phase: phase,
        style: style,
        odometer: odometer,
        line: line,
      ),
    );
    if (move != AdventureMove.hold) odometer += at.distanceTo(target);
    t += duration;
    at = target;
    angle = end;
  }

  void hold(PetAnimation animation, double duration, {AdventureStyle style = AdventureStyle.plain, String? line}) {
    if (!(duration > 0.01)) return;
    append(AdventureMove.hold, at, duration: duration, animation: animation, style: style, line: line);
  }

  void act(PetAnimation animation) => hold(animation, animation.defaultDuration);

  /// Turns to face [direction] (a beat to swap sides).
  void face(double direction) {
    final wanted = direction >= 0 ? 1.0 : -1.0;
    if (wanted == facing) return;
    facing = wanted;
    hold(PetAnimation.idle, 0.1);
  }

  void walk(double x, {bool run = false}) {
    final goal = math.min(highX, math.max(lowX, x));
    final distance = (goal - at.x).abs();
    if (!(distance > 0.5)) return;
    face(goal > at.x ? 1 : -1);
    final speed = run ? metrics.run : metrics.walk;
    append(
      AdventureMove.walk,
      AdventurePoint(goal, at.y),
      duration: distance / speed + AdventureSegment.ease,
      animation: run ? PetAnimation.run : PetAnimation.walk,
    );
  }

  void land() => hold(PetAnimation.idle, 0.24, style: AdventureStyle.land);

  /// A jump onto [target]; one well below becomes a little hop off and a drop.
  void hop(AdventurePoint target, {String? line}) {
    if ((target.x - at.x).abs() > 2) face(target.x > at.x ? 1 : -1);
    hold(PetAnimation.idle, 0.16, style: AdventureStyle.crouch);
    final rise = target.y - at.y;
    if (rise < -70) {
      final off = AdventurePoint(at.x + (target.x - at.x) * 0.3, at.y);
      append(AdventureMove.hop, off, duration: 0.3, animation: PetAnimation.idle, arc: 14, style: AdventureStyle.drop, line: line);
      fall(target);
      return;
    }
    final arc = rise > 0 ? rise / 2 + 24 : 18.0;
    final duration = math.min(1.0, math.max(0.42, 0.36 + (target.x - at.x).abs() / 900 + arc / 500));
    append(AdventureMove.hop, target, duration: duration, animation: PetAnimation.idle, arc: arc, style: AdventureStyle.drop, line: line);
    land();
  }

  void fall(AdventurePoint target, {String? line}) {
    final height = math.max(1.0, at.y - target.y);
    append(
      AdventureMove.fall,
      target,
      duration: math.max(0.22, math.sqrt(2 * height / AdventurePlanner.gravity)),
      animation: PetAnimation.idle,
      style: AdventureStyle.drop,
      line: line,
    );
    land();
  }

  /// Down onto whatever is right below.
  void dropToSurface() {
    final below = terrain.surface(below: AdventurePoint(at.x, at.y - 0.5));
    if (at.y - below.y > 0.5) fall(AdventurePoint(at.x, below.y));
  }

  // MARK: Itinerary

  /// Out of the menu bar (or a hand): down onto the first thing below.
  void arrive(AdventurePoint start) {
    phase = AdventurePhase.arriving;
    at = AdventurePoint(math.min(highX, math.max(lowX, start.x)), math.max(terrain.floorY, start.y));
    final below = terrain.surface(below: at);
    fall(AdventurePoint(at.x, below.y), line: say('Wheee!', odds: 0.7));
  }

  /// Roughly how long the way home takes from here: down, the Dock, the edge, the climb, the hop.
  double estimateWayHome(double wall) {
    final dock = terrain.dock;
    final dockX = dock == null ? bounds.midX : (dock.lower + dock.upper) / 2;
    final wallX = wall > 0 ? highX : lowX;
    final down = at.y > terrain.floorY + 1 ? 3.5 : 0.0;
    final toDock = (dockX - at.x).abs() / metrics.walk;
    const sit = 7.5;
    final toWall = (wallX - dockX).abs() / metrics.run + 0.5;
    final climb = (bounds.maxY - terrain.floorY) / metrics.climb + 1.2;
    return down + toDock + sit + toWall + climb + 1.0;
  }

  /// Along window tops and from one to the next, until [deadline].
  void explore(double deadline) {
    phase = AdventurePhase.exploring;
    var hops = 0;
    var lingers = 0;
    while (t < deadline && hops < 8) {
      final current = terrain.ledge(at, tolerance: 2);
      if (current != null) {
        if (!visited.contains(current.window)) visited.add(current.window);
        beat(current);
      }
      if (!(t < deadline)) break;
      final next = pickLedge(current);
      if (next == null) {
        // Nowhere to hop to from here: a little longer up here, then down.
        if (current != null && lingers < 2) {
          lingers++;
          continue;
        }
        break;
      }
      travel(current, next, first: hops == 0);
      hops++;
    }
    // Nothing within reach to climb on: a stroll along the floor with the time left.
    if (at.y <= terrain.floorY + 0.5) stroll(deadline);
  }

  /// A few steps and sniffs along the floor (once an adventure).
  void stroll(double deadline) {
    if (strolled) return;
    strolled = true;
    var beats = 0;
    while (t < deadline - 3 && beats < 3) {
      beats++;
      walk(at.x + (chance(0.5) ? 1 : -1) * uniform(80, 260));
      act(chance(0.6) ? PetAnimation.sniff : PetAnimation.lookAround);
    }
  }

  /// A moment on a window top: a sniff, a look around, a sit or a few steps.
  void beat(AdventureLedge ledge) {
    final roll = rng.nextUnit();
    if (roll < 0.28) {
      act(PetAnimation.sniff);
    } else if (roll < 0.48) {
      act(PetAnimation.lookAround);
    } else if (roll < 0.62) {
      hold(PetAnimation.sit, uniform(1.4, 2.6));
    } else {
      final direction = chance(0.5) ? 1.0 : -1.0;
      walk(ledge.clamp(at.x + direction * uniform(50, 200), margin: metrics.halfWidth * 0.7));
      if (chance(0.4)) act(PetAnimation.sniff);
    }
  }

  /// The next window top within a hop, preferring new ones and the way up.
  AdventureLedge? pickLedge(AdventureLedge? current) {
    final options = <(AdventureLedge, double)>[];
    for (final ledge in terrain.ledges) {
      if (ledge == current) continue;
      final rise = ledge.y - at.y;
      if (!(rise <= AdventurePlanner.maxRise && rise > -700)) continue;
      final lo = current?.minX ?? at.x;
      final hi = current?.maxX ?? at.x;
      final gap = math.max(0.0, math.max(ledge.minX - hi, lo - ledge.maxX));
      if (!(gap <= AdventurePlanner.maxGap)) continue;
      var weight = 1.0;
      if (visited.contains(ledge.window)) weight *= 0.12;
      if (rise > 20) weight *= 1.6;
      if (ledge.width > 220) weight *= 1.2;
      options.add((ledge, weight));
    }
    if (options.isEmpty) return null;
    final total = options.fold<double>(0, (sum, option) => sum + option.$2);
    var roll = rng.nextUnit() * total;
    for (final (ledge, weight) in options) {
      roll -= weight;
      if (roll <= 0) return ledge;
    }
    return options.last.$1;
  }

  /// Along the current ledge to the best take-off spot, then a hop onto [target].
  void travel(AdventureLedge? current, AdventureLedge target, {required bool first}) {
    final margin = metrics.halfWidth * 0.6;
    var takeoff = at.x;
    if (current != null) {
      final lo = current.minX + margin;
      final hi = current.maxX - margin;
      final targetLo = target.minX + margin;
      final targetHi = target.maxX - margin;
      if (lo > hi) {
        takeoff = current.midX;
      } else if (targetHi < lo) {
        takeoff = lo;
      } else if (targetLo > hi) {
        takeoff = hi;
      } else {
        takeoff = math.min(math.min(hi, targetHi), math.max(math.max(lo, targetLo), at.x));
      }
      walk(takeoff);
    }
    final direction = target.midX >= at.x ? 1.0 : -1.0;
    final landing = target.clamp(at.x + direction * uniform(18, 70), margin: margin);
    final up = target.y > at.y + 20;
    hop(AdventurePoint(landing, target.y), line: up ? say(first ? 'Hup!' : 'Up we go!', odds: 0.35) : null);
  }

  /// Down to the floor: off the nearer end of each window top (one with room to drop past it).
  void descend() {
    phase = AdventurePhase.descending;
    var guardrail = 0;
    while (at.y > terrain.floorY + 0.5 && guardrail < 8) {
      guardrail++;
      final ledge = terrain.ledge(at, tolerance: 2);
      if (ledge == null) {
        dropToSurface();
        continue;
      }
      var side = ledge.maxX - at.x < at.x - ledge.minX ? 1.0 : -1.0;
      if (side > 0 && ledge.maxX >= highX - 1) {
        side = -1;
      } else if (side < 0 && ledge.minX <= lowX + 1) {
        side = 1;
      }
      final edge = side > 0 ? ledge.maxX - 6 : ledge.minX + 6;
      walk(edge);
      final out = math.min(highX, math.max(lowX, edge + side * (metrics.halfWidth + 14)));
      final below = terrain.surface(below: AdventurePoint(out, at.y - 1));
      hop(AdventurePoint(out, below.y));
    }
  }

  /// The rest of the way: down (strolling the floor if there is time left until [strollUntil]), a sit on the Dock, over to
  /// the edge, up it and back out of the screen.
  void goHome({required double wall, required AdventureSpan bar, required double strollUntil}) {
    if (phase <= AdventurePhase.descending) {
      descend();
      stroll(strollUntil);
    }
    if (phase <= AdventurePhase.dock) visitDock();
    if (phase <= AdventurePhase.toEdge) {
      phase = AdventurePhase.toEdge;
      final foot = wall > 0 ? highX - 2 : lowX + 2;
      walk(foot, run: (foot - at.x).abs() > 160);
    }
    if (phase <= AdventurePhase.climbing) climb(wall);
    if (homeY != null) {
      // Home is the taskbar below (Windows): off the wall, down to the floor and over to Mochi's spot, then a hop into it.
      phase = AdventurePhase.toEdge;
      if (at.y > terrain.floorY + 0.5) jumpOffWall(wall);
      final spot = math.min(bar.upper, math.max(bar.lower, at.x));
      walk(spot, run: (spot - at.x).abs() > 260);
      leapHome(spot, line: say('Home time!', odds: 0.4));
      return;
    }
    phase = AdventurePhase.returning;
    hold(PetAnimation.idle, 0.25, style: AdventureStyle.crouch);
    leapHome(wall > 0 ? bar.upper : bar.lower, line: say('Home time!', odds: 0.4));
  }

  void visitDock() {
    phase = AdventurePhase.dock;
    final span = terrain.dock ?? AdventureSpan(bounds.minX + bounds.width * 0.3, bounds.maxX - bounds.width * 0.3);
    final lo = math.max(lowX, span.lower + metrics.halfWidth);
    final hi = math.min(highX, span.upper - metrics.halfWidth);
    final spot = lo < hi ? math.min(hi, math.max(lo, at.x + uniform(-120, 120))) : (span.lower + span.upper) / 2;
    walk(spot, run: (spot - at.x).abs() > 260);
    hold(PetAnimation.idle, 0.3);
    hold(PetAnimation.sit, uniform(3.5, 6), line: say('Comfy!', odds: 0.35));
    act(chance(0.5) ? PetAnimation.lookAround : PetAnimation.yawn);
    hold(PetAnimation.sit, uniform(0.8, 1.6));
  }

  /// Onto the screen edge with a little spring, and up it paw over paw, upright and leaning into it, to just under the
  /// top.
  void climb(double wall) {
    phase = AdventurePhase.climbing;
    face(wall);
    final side = wall >= 0 ? 1.0 : -1.0;
    // The front of the body against the edge.
    final x = (side > 0 ? bounds.maxX : bounds.minX) - side * metrics.halfWidth * 0.8;
    if ((at.x - x).abs() > 1) {
      hold(PetAnimation.idle, 0.18, style: AdventureStyle.crouch);
      append(
        AdventureMove.hop,
        AdventurePoint(x, at.y + 22),
        duration: 0.34,
        animation: PetAnimation.idle,
        arc: 10,
        turnTo: side * AdventurePlanner.climbLean,
        style: AdventureStyle.launch,
      );
    }
    final top = bounds.maxY - metrics.height - 6;
    if (top > at.y + 1) {
      append(
        AdventureMove.climb,
        AdventurePoint(x, top),
        duration: (top - at.y) / metrics.climb + 2 * AdventureSegment.ease,
        animation: PetAnimation.walk,
      );
    }
    hold(PetAnimation.idle, 0.35, style: AdventureStyle.notice);
  }

  /// Windows, where home is below: a push off the screen edge and a drop to the floor.
  void jumpOffWall(double wall) {
    final side = wall >= 0 ? 1.0 : -1.0;
    facing = -side;
    final off = AdventurePoint(math.min(highX, math.max(lowX, at.x - side * (metrics.halfWidth + 48))), at.y);
    append(AdventureMove.hop, off, duration: 0.32, animation: PetAnimation.idle, arc: 16, turnTo: 0, style: AdventureStyle.launch);
    fall(AdventurePoint(off.x, terrain.floorY));
  }

  /// The last hop: up and out of the screen at [x] (the Mac's menu bar), or, when home is below ([homeY]: Windows'
  /// taskbar), down into it at [x], from wherever Mochi is (one big leap when it hurries home from a window top).
  void leapHome(double x, {String? line}) {
    phase = AdventurePhase.returning;
    homeX = x;
    final floorHome = homeY;
    if (floorHome != null) {
      final target = AdventurePoint(x, floorHome);
      final drop = math.max(0.0, at.y - target.y);
      if ((x - at.x).abs() > 2) facing = x > at.x ? 1 : -1;
      append(
        AdventureMove.hop,
        target,
        duration: math.min(1.1, 0.38 + drop / 1600 + (x - at.x).abs() / 2400),
        animation: PetAnimation.idle,
        arc: math.max(18, math.min(90, drop * 0.15 + (x - at.x).abs() * 0.05)),
        turnTo: 0,
        style: AdventureStyle.launch,
        line: line,
      );
      return;
    }
    final target = AdventurePoint(x, bounds.maxY + metrics.height + 12);
    final rise = target.y - at.y;
    final duration = math.min(1.1, 0.45 + rise / 1600 + (x - at.x).abs() / 2400);
    if ((x - at.x).abs() > 2) facing = x > at.x ? 1 : -1;
    append(
      AdventureMove.hop,
      target,
      duration: duration,
      animation: PetAnimation.idle,
      arc: math.max(24, rise * 0.25),
      turnTo: 0,
      style: AdventureStyle.launch,
      line: line,
    );
  }
}
