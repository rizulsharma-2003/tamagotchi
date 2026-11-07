// Port of `Ease` (Sources/TamagotchiCore/Animation/Poses.swift) and `Keys` (PetPoseEvaluator.swift), plus the few
// numeric helpers Swift gets from Foundation that Dart spells differently.

import 'dart:math' as math;

/// 2^53, for turning the top 53 bits of a 64-bit value into a double in [0, 1).
const double twoTo53 = 9007199254740992.0;

/// IEEE 754 remainder (Swift's `remainder(x, y)` / C `remainder`): `x − n·y` with `n` the integer nearest `x / y`
/// (ties to even). Dart's `double.remainder` is C `fmod` (truncated), so this builds the IEEE one from it exactly.
double ieeeRemainder(double x, double y) {
  if (x.isNaN || y.isNaN || x.isInfinite || y == 0) return double.nan;
  if (y.isInfinite) return x;
  final ay = y.abs();
  var r = x.remainder(ay); // exact; same sign as x, |r| < |y|
  final half = ay / 2;
  if (r.abs() > half) {
    r -= r.isNegative ? -ay : ay;
  } else if (r.abs() == half) {
    // A tie: the quotient must be even.
    final q = ((x - r) / ay).round();
    if (q.isOdd) r -= r.isNegative ? -ay : ay;
  }
  return r;
}

/// Swift's `Int(x)` for a finite double: truncation toward zero.
int truncate(double x) => x.toInt();

abstract final class Ease {
  static double clamp(double x, [double lo = 0, double hi = 1]) => math.min(hi, math.max(lo, x));

  /// Local 0…1 progress of `t` within [start, end].
  static double segment(double t, double start, double end) {
    if (!(end > start)) return t >= end ? 1 : 0;
    return clamp((t - start) / (end - start));
  }

  static double smooth(double x) {
    final c = clamp(x);
    return c * c * (3 - 2 * c);
  }

  static double outBack(double x, [double overshoot = 1.70158]) {
    final c = clamp(x) - 1;
    return 1 + c * c * ((overshoot + 1) * c + overshoot);
  }

  static double outCubic(double x) {
    final c = 1 - clamp(x);
    return 1 - c * c * c;
  }

  /// 0 → 1 → 0 parabola (a hop).
  static double hop(double x) {
    final c = clamp(x);
    return 4 * c * (1 - c);
  }

  /// Smooth bump: 0 outside [start, end], 1 in the middle.
  static double bump(double t, double start, double end) {
    if (!(t > start && t < end)) return 0;
    return math.sin(math.pi * (t - start) / (end - start));
  }

  /// Fades in over `fadeIn` and out over `fadeOut` within [0, duration].
  static double envelope(double t, {required double duration, double fadeIn = 0.2, double fadeOut = 0.3}) =>
      math.min(segment(t, 0, fadeIn), 1 - segment(t, duration - fadeOut, duration));

  static double lerp(double a, double b, double x) => a + (b - a) * x;

  static double fract(double x) => x - x.floorToDouble();

  /// Deterministic pseudo-random 0…1 from an integer and a seed (SplitMix64's mix, as in Swift). `seed` is the
  /// UInt64's bit pattern; Dart's 64-bit integers wrap exactly like Swift's `&+` and `&*`.
  static double hash(int n, int seed) {
    var z = n + seed * 0x9E3779B97F4A7C15;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    z ^= z >>> 31;
    return (z >>> 11) / twoTo53;
  }

  /// Natural blinking: eye openness (0…1) for a global time.
  static double blink(double time, {required int seed, double period = 4.2}) {
    final cycle = (time / period).floor();
    final offset = hash(cycle, seed) * (period - 0.6);
    final local = time - cycle * period - offset;
    const duration = 0.16;
    var openness = 1.0;
    if (local >= 0 && local < duration) {
      openness = 1 - math.sin(math.pi * local / duration) * 0.95;
    }
    // Occasional double blink.
    if (hash(cycle + 7919, seed) > 0.82) {
      final second = local - 0.28;
      if (second >= 0 && second < duration) {
        openness = math.min(openness, 1 - math.sin(math.pi * second / duration) * 0.95);
      }
    }
    return openness;
  }
}

/// Keyframe interpolation with smoothstep between keys (Swift `Keys`).
abstract final class Keys {
  static double value(double t, List<(double, double)> keys) {
    if (keys.isEmpty) return 0;
    final first = keys.first;
    if (t <= first.$1) return first.$2;
    for (var index = 1; index < keys.length; index++) {
      final (t1, v1) = keys[index];
      if (t <= t1) {
        final (t0, v0) = keys[index - 1];
        return Ease.lerp(v0, v1, Ease.smooth(Ease.segment(t, t0, t1)));
      }
    }
    return keys[keys.length - 1].$2;
  }
}
