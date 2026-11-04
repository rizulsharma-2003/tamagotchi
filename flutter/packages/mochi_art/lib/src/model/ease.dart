// Port of `Ease` from Sources/TamagotchiCore/Animation/Poses.swift.

import 'dart:math' as math;

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

  static double envelope(double t, {required double duration, double fadeIn = 0.2, double fadeOut = 0.3}) =>
      math.min(segment(t, 0, fadeIn), 1 - segment(t, duration - fadeOut, duration));

  static double lerp(double a, double b, double x) => a + (b - a) * x;

  static double fract(double x) => x - x.floorToDouble();

  /// Deterministic pseudo-random 0…1 from an integer and a seed (SplitMix64, as in Swift).
  /// Uses 64-bit wrapping integer arithmetic, so it runs on the Dart VM (not on the web).
  static double hash(int n, int seed) {
    var z = n + seed * 0x9E3779B97F4A7C15;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    z ^= z >>> 31;
    return (z >>> 11) / 9007199254740992.0; // 2^53
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
