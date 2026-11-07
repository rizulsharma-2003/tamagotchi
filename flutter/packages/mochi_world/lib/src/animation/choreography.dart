// Port of Sources/TamagotchiCore/Animation/PetChoreography.swift: timing helpers, keyframe tracks, the pet's
// particle builders and the turn on the spot. (The `extension PetPose` helpers live on PetPose in model/poses.dart.)

import 'dart:math' as math;

import '../model/ease.dart';
import '../model/poses.dart';

/// Allocation-free timing helpers for Mochi's choreography. Everything is a pure function of time so poses can be
/// sampled at any moment (and at several moments per frame for secondary motion).
abstract final class Choreo {
  /// Local 0…1 progress of `t` within [a, b].
  static double seg(double t, double a, double b) => Ease.segment(t, a, b);

  static double smooth(double x) => Ease.smooth(x);

  /// Smoothly moves from `from` to `to` while `t` crosses [a, b].
  static double ramp(double t, double a, double b, double from, double to) =>
      from + (to - from) * Ease.smooth(Ease.segment(t, a, b));

  /// Ease-in (accelerating) ramp.
  static double rampIn(double t, double a, double b, double from, double to) {
    final s = Ease.segment(t, a, b);
    return from + (to - from) * s * s;
  }

  /// Ease-out (decelerating) ramp.
  static double rampOut(double t, double a, double b, double from, double to) {
    final s = 1 - Ease.segment(t, a, b);
    return from + (to - from) * (1 - s * s);
  }

  /// Ramp with a springy overshoot at the end.
  static double rampBack(double t, double a, double b, double from, double to, {double overshoot = 1.70158}) =>
      from + (to - from) * Ease.outBack(Ease.segment(t, a, b), overshoot);

  /// A quick "perk up" with a gentle overshoot (ears, a startled look): fast but never a snap.
  static double perk(double t, double a, double b, double from, double to) =>
      from + (to - from) * Ease.outBack(Ease.segment(t, a, b), 1.0);

  /// 0 outside [a, b], 1 inside, with smooth fades of `fade` seconds at both ends.
  static double window(double t, double a, double b, {required double fade}) {
    if (!(t > a && t < b)) return 0;
    final f = math.max(0.0001, math.min(fade, (b - a) / 2));
    return Ease.smooth(math.min(math.min((t - a) / f, (b - t) / f), 1));
  }

  /// Sine bump: 0 outside [a, b], 1 in the middle.
  static double bump(double t, double a, double b) => Ease.bump(t, a, b);

  /// Parabolic hop height (0 → 1 → 0) for a jump spanning [a, b].
  static double hop(double t, double a, double b) {
    if (!(t > a && t < b)) return 0;
    return Ease.hop((t - a) / (b - a));
  }

  /// A damped oscillation that starts at 1 when `age` = 0 (0 before).
  static double ring(double age, {required double frequency, required double decay}) {
    if (!(age >= 0)) return 0;
    return math.exp(-decay * age) * math.cos(2 * math.pi * frequency * age);
  }

  /// Smooth value noise in -1…1 (deterministic for a seed).
  static double noise(double x, int seed) {
    final i = x.floorToDouble();
    final f = x - i;
    final n = i.toInt();
    final a = Ease.hash(n, seed) * 2 - 1;
    final b = Ease.hash(n + 1, seed) * 2 - 1;
    return a + (b - a) * Ease.smooth(f);
  }

  /// Lift (body heights) that keeps Mochi's silhouette on the floor while rotated about the body centre: rotating a
  /// bean shape dips its lower edge into the ground.
  static double floorLift(double rotation, {double scaleX = 1, double scaleY = 1}) {
    final r = ieeeRemainder(rotation, 2 * math.pi);
    if (!(r.abs() > 0.02)) return 0;
    final s = math.sin(r), c = math.cos(r);
    // Silhouette points relative to the pivot (0, -27), y down, including feet and ears; the body is scaled about the
    // feet before it rotates.
    var lowest = double.negativeInfinity;
    for (final (x, y) in floorProbe) {
      final px = x * scaleX;
      final py = (y - 27) * scaleY + 27;
      lowest = math.max(lowest, px * s + py * c);
    }
    return math.max(0, lowest - 29.2) / 54;
  }

  static const List<(double, double)> floorProbe = [
    (-19, 29.2),
    (-5, 29.2),
    (5, 29.2),
    (19, 29.2),
    (-27, 22),
    (27, 22),
    (-31, 8),
    (31, 8),
    (-31, -8),
    (31, -8),
    (-22, -24),
    (22, -24),
    (0, -27),
    (-16, -33),
    (16, -33),
  ];

  /// A 0…1 pulse train of `count` taps starting at `start`, `spacing` apart, each `width` long.
  static ({int index, double amount}) taps(
    double t, {
    required double start,
    required double spacing,
    required int count,
    required double width,
  }) {
    if (!(t >= start)) return (index: -1, amount: 0);
    final k = ((t - start) / spacing).toInt();
    if (!(k < count)) return (index: -1, amount: 0);
    final local = t - start - k * spacing;
    return (index: k, amount: Ease.bump(local, 0, width));
  }
}

enum Curve { linear, smooth, easeIn, easeOut, back, hold }

/// A keyframe channel with per-segment easing (Swift `Track`; call it like a function).
class Track {
  /// `keys`: (time, value, curve used to arrive at this key).
  Track(List<(double, double, Curve)> keys)
    : _times = [for (final k in keys) k.$1],
      _values = [for (final k in keys) k.$2],
      _curves = [for (final k in keys) k.$3];

  final List<double> _times;
  final List<double> _values;
  final List<Curve> _curves;

  double call(double t) {
    if (_times.isEmpty) return 0;
    if (t <= _times.first) return _values[0];
    var index = 1;
    while (index < _times.length && t > _times[index]) {
      index += 1;
    }
    if (!(index < _times.length)) return _values[_values.length - 1];
    final t0 = _times[index - 1], t1 = _times[index];
    final s = t1 > t0 ? (t - t0) / (t1 - t0) : 1.0;
    final v0 = _values[index - 1], v1 = _values[index];
    final shaped = switch (_curves[index]) {
      Curve.linear => s,
      Curve.smooth => Ease.smooth(s),
      Curve.easeIn => s * s,
      Curve.easeOut => 1 - (1 - s) * (1 - s),
      Curve.back => Ease.outBack(s, 1.6),
      Curve.hold => s < 1 ? 0.0 : 1.0,
    };
    return v0 + (v1 - v0) * shaped;
  }
}

/// Reusable particle choreography for the pet. Each builder appends into a pose.
abstract final class PetFX {
  static void zParticles(PetPose p, {required double g, required double x, required double y, required bool reduced, double slow = 1}) {
    for (var index = 0; index < 3; index++) {
      final f = Ease.fract(g / (3.2 * slow) + index / 3);
      if (reduced) {
        p.add(Effect(EffectKind.z, x: x + 0.12 * index, y: y + 0.2 * index, scale: 0.6 + 0.2 * index, opacity: 0.85));
      } else {
        final sway = 0.05 * math.sin(f * 2 * math.pi + index);
        p.add(
          Effect(
            EffectKind.z,
            x: x + 0.22 * f + sway,
            y: y + 0.55 * f,
            scale: 0.5 + 0.55 * f,
            opacity: math.sin(math.pi * f) * 0.95,
            rotation: -0.25 + 0.35 * f,
          ),
        );
      }
    }
  }

  /// `variant` 0 = gold (reserved for real-event reactions), 1 = pastel (play and care).
  static void sparkles(
    PetPose p, {
    required double t,
    required (double, double) around,
    required int count,
    required double spread,
    required int seed,
    double life = 0.7,
    int variant = 0,
  }) {
    for (var index = 0; index < count; index++) {
      final angle = Ease.hash(index, seed) * 2 * math.pi;
      final radius = spread * (0.7 + 0.3 * Ease.hash(index + 11, seed));
      final delay = index * 0.18;
      final amount = Ease.bump(t - delay, 0, life);
      if (!(amount > 0.01)) continue;
      p.add(
        Effect(
          EffectKind.sparkle,
          x: around.$1 + math.cos(angle) * radius,
          y: around.$2 + math.sin(angle) * radius * 0.6 + 0.1,
          scale: 0.45 + 0.6 * amount,
          opacity: amount,
          rotation: t * 2,
          variant: variant,
        ),
      );
    }
  }

  /// Hearts that rise, sway and (optionally) burst into tiny hearts at the end.
  static void hearts(
    PetPose p, {
    required double t,
    required double x,
    required double y,
    required int count,
    double spacing = 0.35,
    double rise = 0.5,
    required bool reduced,
    bool pop = false,
    double life = 1.3,
  }) {
    for (var index = 0; index < count; index++) {
      final local = t - index * spacing;
      if (!(local > 0 && local < life + (pop ? 0.3 : 0))) continue;
      final side = index % 2 == 0 ? -1.0 : 1.0;
      final baseX = x + side * 0.1 * ((index + 1) ~/ 2) + (index == 0 ? 0 : 0.02);
      if (pop && local >= life) {
        final age = (local - life) / 0.3;
        p.add(Effect(EffectKind.heartPop, x: baseX, y: y + (reduced ? 0.15 : rise), scale: 0.8, opacity: 1 - age, phase: age));
        continue;
      }
      final f = local / life;
      final sway = reduced ? 0.0 : 0.06 * math.sin(local * 6 + index);
      p.add(
        Effect(
          EffectKind.heart,
          x: baseX + sway,
          y: y + (reduced ? 0.15 : rise * Ease.outCubic(f)),
          scale: 0.5 + 0.35 * Ease.outBack(math.min(1, f * 3)),
          opacity: pop ? math.min(1, f * 6) : math.sin(math.pi * f),
          rotation: reduced ? 0 : 0.18 * math.sin(local * 4 + index),
        ),
      );
    }
  }

  static void notes(PetPose p, {required double t, required double x, required double y, required bool reduced}) {
    for (var index = 0; index < 2; index++) {
      final f = Ease.fract(t / 1.6 + index * 0.5);
      p.add(
        Effect(
          EffectKind.note,
          x: x + (reduced ? 0 : 0.15 * math.sin(f * 6)) + 0.12 * index,
          y: y + (reduced ? 0.1 : 0.45 * f),
          scale: 0.7,
          opacity: math.sin(math.pi * f),
          rotation: 0.2 * math.sin(f * 5),
          variant: index,
        ),
      );
    }
  }

  /// Lavender "dizzy" stars circling the head (gold stars are reserved for real events).
  static void dizzyStars(PetPose p, {required double t, required double amount, double y = 1.08}) {
    if (!(amount > 0.01)) return;
    for (var index = 0; index < 3; index++) {
      final angle = t * 6 + index * 2.09;
      p.add(
        Effect(
          EffectKind.star,
          x: 0.3 * math.cos(angle),
          y: y + 0.08 * math.sin(angle),
          scale: 0.42 + 0.06 * math.sin(angle),
          opacity: amount,
          variant: 1,
        ),
      );
    }
  }

  static void confetti(PetPose p, {required double t, required double originY, required int count, required int seed, required bool reduced}) {
    if (!(t > 0 && t < 1.9)) return;
    for (var index = 0; index < count; index++) {
      final angle = Ease.lerp(-2.4, -0.7, Ease.hash(index, seed)) * -1;
      final speed = 0.6 + 0.5 * Ease.hash(index + 5, seed);
      final fall = t * t * 0.55;
      final x = math.cos(angle) * speed * math.min(t, 0.9) * (Ease.hash(index + 9, seed) > 0.5 ? 1 : -1);
      final y = originY + math.sin(angle) * speed * math.min(t, 0.6) - fall;
      final opacity = 1 - Ease.segment(t, 1.3, 1.9);
      if (reduced) {
        p.add(
          Effect(
            EffectKind.confetti,
            x: math.cos(index.toDouble()) * 0.5,
            y: originY + 0.1 * (index % 3),
            scale: 0.6,
            opacity: opacity,
            variant: index % 4,
          ),
        );
      } else {
        p.add(Effect(EffectKind.confetti, x: x, y: y, scale: 0.6, opacity: opacity, rotation: t * 8 + index, variant: index % 4));
      }
    }
  }

  /// A pair of dust puffs spreading from a point on the floor (world space).
  static void dustPuff(PetPose p, {required double age, required double worldX, required double strength, double life = 0.38}) {
    if (!(age >= 0 && age < life && strength > 0.02)) return;
    final f = age / life;
    final spread = Ease.outCubic(f);
    final fade = math.pow(1 - f, 1.4).toDouble() * (0.45 + 0.55 * strength);
    for (var index = 0; index < 2; index++) {
      final side = index == 0 ? -1.0 : 1.0;
      p.addWorld(
        Effect(
          EffectKind.dust,
          x: worldX + side * (0.3 + 0.32 * spread * (0.6 + 0.4 * strength)),
          y: 0.03 + 0.06 * f,
          scale: (0.5 + 0.6 * spread) * (0.65 + 0.5 * strength),
          opacity: fade,
          rotation: side * 0.2,
          variant: side < 0 ? 0 : 1,
          phase: f,
        ),
      );
    }
  }

  /// A small dust kick at the feet; `side` -1 = behind a right-facing Mochi (screen space).
  static void dustKick(PetPose p, {required double age, double life = 0.36, double strength = 0.6, double side = -1}) {
    if (!(age >= 0 && age < life)) return;
    final f = age / life;
    p.add(
      Effect(
        EffectKind.dust,
        x: side * (0.22 + 0.35 * Ease.outCubic(f)),
        y: 0.04 + 0.12 * f,
        scale: (0.35 + 0.45 * Ease.outCubic(f)) * strength + 0.1,
        opacity: (1 - f) * 0.85,
        rotation: 0,
        variant: side < 0 ? 0 : 1,
        phase: f,
      ),
    );
  }

  /// Crumbs (or droplets) thrown from a point on ballistic arcs: they fly out, land on the floor, bounce once and fade
  /// (world space). `born` is when this one leaves.
  static void ballistic(
    PetPose p, {
    required EffectKind kind,
    required double t,
    required double born,
    required double fromX,
    required double fromY,
    required double side,
    required double speed,
    required double up,
    required int seed,
    double scale = 0.8,
    double life = 0.85,
    double spin = 9,
  }) {
    final age = t - born;
    if (!(age >= 0 && age < life)) return;
    const gravity = 4.2;
    // Flight until it meets the floor, then a small bounce and a rest.
    final land = (up + math.sqrt(up * up + 2 * gravity * math.max(0, fromY - 0.03))) / gravity;
    double x;
    double y;
    if (age < land) {
      x = fromX + side * speed * age;
      y = fromY + up * age - 0.5 * gravity * age * age;
    } else {
      final after = age - land;
      final bounceUp = 0.35 * (gravity * land - up);
      final bounce = math.max(0.0, bounceUp * after - 0.5 * gravity * after * after);
      x = fromX + side * (speed * land + 0.35 * speed * math.min(after, 2 * bounceUp / gravity));
      y = 0.03 + bounce;
    }
    y = math.max(0.03, y);
    final fade = 1 - Choreo.seg(age, life - 0.25, life);
    p.addWorld(
      Effect(
        kind,
        x: x,
        y: y,
        scale: scale,
        opacity: fade,
        rotation: spin == 0 ? side * 0.6 : side * math.min(age, land) * spin,
        variant: seed.abs() % 3,
      ),
    );
  }

  /// A swipe streak along an arc (body space).
  static void streak(
    PetPose p, {
    required double x,
    required double y,
    required double angle,
    required double length,
    required double amount,
    int side = 0,
  }) {
    if (!(amount > 0.02)) return;
    p.add(Effect(EffectKind.streak, x: x, y: y, scale: length, opacity: amount, rotation: angle, variant: side));
  }
}

/// A turn on the spot: the body squeezes thin, the tail sweeps to the middle and the eyes lead; `facing` flips at the
/// narrowest frame, so the change of side is hidden.
abstract final class PetTurn {
  /// Squeeze amount 0…1 for a turn centred at `at` lasting `width` seconds.
  static double squeeze(double t, {required double at, double width = 0.2}) => Choreo.bump(t, at - width / 2, at + width / 2);

  static void apply(PetPose p, {required double t, required double at, double width = 0.2, required double motion}) {
    final m = motion;
    final s = squeeze(t, at: at, width: width);
    if (!(s > 0)) return;
    p.scaleX *= 1 - 0.2 * s * math.max(m, 0.5);
    p.scaleY *= 1 + 0.03 * s * m;
    p.tailLift = Ease.lerp(p.tailLift, -0.55, s);
    p.tailCurl = Ease.lerp(p.tailCurl, 0.9, s);
    p.tailWag *= 1 - s;
    p.lean *= 1 - s;
    p.earPerk += 0.15 * s;
  }
}
