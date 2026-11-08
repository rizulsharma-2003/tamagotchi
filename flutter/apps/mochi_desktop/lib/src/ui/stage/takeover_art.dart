// The pictures of the holiday takeover (docs/SPRINT_2.md X11), drawn from the same seasonal art as the room's and the
// taskbar's accents (packages/mochi_art season_art.dart: the fairy lights' colours and swag, the jack-o'-lantern, the
// snow's white). Each is drawn once, by the stage's sprites (stage_sprites.dart), and reused.
//
// All are in logical pixels with the origin where the decoration meets the window's top edge: the lights and the snow sit
// above it (negative y) and dip at most [dip] into the frame; a pumpkin's origin is its feet.

import 'dart:math' as math;
import 'dart:ui';

import 'package:mochi_art/mochi_art.dart';

abstract final class TakeoverArt {
  /// How far a decoration dips into the window's frame (logical pixels).
  static const double dip = 6;

  /// How far above the edge the lights' wire and the snow reach.
  static const double rise = 16;

  /// Twinkle frames of the lights in one cycle (the takeover steps through them at 3 a second, under the 4 a second limit).
  static const int twinkleFrames = 4;

  /// What a picture of the strip [width] wide holds (logical pixels around the origin).
  static Rect stripBounds(double width) => Rect.fromLTRB(-6, -rise - 10, width + 6, dip + 6);

  /// A pumpkin on the taskbar: its glow spills a little around it.
  static const Rect pumpkinBounds = Rect.fromLTRB(-26, -34, 26, 6);

  /// A string of little lights draped along the top edge, [width] wide: the fairy lights' colours, [frame] of
  /// [twinkleFrames] (-1: steady, with animation effects off).
  static void lights(Canvas canvas, double width, {required int frame, bool dark = false}) {
    final g = GContext(canvas);
    const colors = [0xFFD166, 0xFF8FA3, 0x7FE3CB, 0xFFB347, 0xB9A7FF];
    final swags = math.max(1, (width / 150).round());
    final wire = dark ? hex(0x8A7A5A).fade(0.7) : hex(0x6E5A3A).fade(0.6);
    const sag = 9.0;
    var index = 0;
    for (var i = 0; i < swags; i++) {
      final a = Offset(width * i / swags, -rise + 3), b = Offset(width * (i + 1) / swags, -rise + 3);
      g.stroke(SeasonArt.swagPath(a, b, sag), wire, 0.9);
      final bulbs = math.max(2, ((b.dx - a.dx) / 20).floor());
      for (var step = 1; step <= bulbs; step++) {
        final p = SeasonArt.swagPoint(a, b, sag, step / (bulbs + 1));
        final twinkle = frame < 0
            ? 0.85
            : 0.55 + 0.45 * (0.5 + 0.5 * math.sin(2 * math.pi * frame / twinkleFrames + index * 1.7));
        final color = hex(colors[index % colors.length]);
        SeasonArt.glow(g, Offset(p.dx, p.dy + 2), 6, color, (dark ? 0.6 : 0.42) * twinkle);
        g.fill(Shapes.ellipse(Offset(p.dx, p.dy + 1.8), 2.6, 3.4), color.fade(0.6 + 0.4 * twinkle));
        index++;
      }
    }
  }

  /// A thin cap of snow resting on the top edge, [width] wide, with a few drips over the edge.
  static void snow(Canvas canvas, double width, {bool dark = false}) {
    final g = GContext(canvas);
    final cap = Path()..moveTo(0, 1);
    var x = 0.0;
    var lump = 0;
    while (x < width - 1) {
      final step = math.min(13 + Ease.hash(lump, 51) * 11, width - x);
      final peak = 3 + Ease.hash(lump, 52) * 3.5;
      cap.quadraticBezierTo(x + step / 2, 1 - peak * 2, x + step, 1);
      x += step;
      lump++;
    }
    // Back along the underside, a few drips dipping over the edge.
    x = width;
    cap.lineTo(width, dip - 2);
    var drip = 0;
    while (x > 0) {
      final step = math.min(15 + Ease.hash(drip, 53) * 14, x);
      final depth = Ease.hash(drip, 54) > 0.55 ? dip : dip - 3;
      cap.quadraticBezierTo(x - step / 2, depth * 1.6 - 1, x - step, dip - 2);
      x -= step;
      drip++;
    }
    cap.close();
    g.fill(cap.shift(const Offset(0, 1)), black.fade(dark ? 0.2 : 0.1));
    g.fill(cap, dark ? hex(0xE9F0FA) : hex(0xFAFCFF));
    g.stroke(cap, hex(0xBFD0E6).fade(0.8), 0.6);
  }

  /// A small jack-o'-lantern standing on the taskbar, its feet at the origin ([face] picks its carving).
  static void pumpkin(Canvas canvas, {required int face, bool dark = false}) {
    SeasonArt.jackOLantern(GContext(canvas), Offset.zero, 22, 0, face * 2.1, dark, face: face % 3);
  }
}
