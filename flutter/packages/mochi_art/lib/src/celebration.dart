// Port of `MenuBarPetCanvas.drawCelebration` (Sources/App/MenuBar/MenuBarPetCanvas.swift): the little burst of confetti
// and sparkles near home when Claude finishes, sized for a strip (the Mac's menu bar, Windows' taskbar).

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'drawing.dart';
import 'model/ease.dart';
import 'palettes.dart';

abstract final class Celebration {
  /// How long a burst lasts (seconds).
  static const double length = 2.6;

  /// Draws a burst [elapsed] seconds in, around [center] on the strip's baseline (y down from the strip's top).
  /// [unit] scales the Mac's menu-bar points (1 at the Mac's size; the taskbar's strip is about twice as tall);
  /// [spread] is how far the confetti reaches either side, [petHeight] how tall Mochi stands (the sparkles twinkle
  /// around its head). [big] for the larger moments (16 pieces instead of 10); [reduced] keeps the pieces still.
  static void draw(
    GContext g,
    double elapsed, {
    required Offset center,
    required double petHeight,
    double spread = 40,
    double unit = 1,
    bool big = false,
    bool reduced = false,
  }) {
    if (elapsed < 0 || elapsed >= length) return;
    final fade = 1 - Ease.segment(elapsed, 1.9, length);
    final count = big ? 16 : 10;
    const seed = 0xC0FE;
    final baseline = center.dy;
    for (var index = 0; index < count; index++) {
      final x0 = center.dx + (Ease.hash(index, seed) - 0.5) * 2 * spread;
      final drift = math.sin(elapsed * 3 + index) * (reduced ? 0 : 1.8) * unit;
      final speed = (8 + 6 * Ease.hash(index + 5, seed)) * unit;
      final start = (1 + 5 * Ease.hash(index + 9, seed)) * unit;
      final y = reduced ? start + 6 * unit : start + speed * elapsed;
      if (y >= baseline + unit) continue;
      final piece = g.copy()
        ..opacity = g.opacity * fade
        ..translateBy(x0 + drift, y)
        ..rotate(reduced ? index.toDouble() : elapsed * 7 + index)
        ..scaleBy(unit, unit);
      final color = ConfettiPalette.colors[index % ConfettiPalette.colors.length];
      piece.fill(Shapes.roundedRect(const Rect.fromLTWH(-1.6, -0.9, 3.2, 1.8), 0.5), color);
    }
    const offsets = [-14.0, 12.0, 1.0];
    const heights = [0.95, 1.1, 1.3];
    for (var index = 0; index < 3; index++) {
      final local = elapsed - index * 0.28;
      final life = Ease.bump(local, 0, 0.75);
      if (life <= 0) continue;
      final x = center.dx + offsets[index] * unit;
      final y = math.max(3 * unit, baseline - petHeight * heights[index]);
      g.fill(Shapes.sparkle(Offset(x, y), (2.2 + 1.6 * life) * unit), hex(0xFFD166).fade(life));
    }
  }
}
