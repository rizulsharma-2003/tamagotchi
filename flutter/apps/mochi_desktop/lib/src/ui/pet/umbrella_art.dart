// The umbrella Mochi holds when it rains (docs/SPRINT_2.md X12), drawn in the app's clay style with mochi_art's drawing
// helpers (soft fills, a darker rim, a pale highlight) over the pet's own view on the taskbar. It is desktop-local: not
// part of the look or the things Mochi wears that the phones read, not a shared prop kind, and never on the native stage
// (the stage's Mochi goes without one while Mochi's window is open).
//
// It's held out to Mochi's side, leaning away a little, small enough to stay inside the taskbar window (about as wide as Mochi
// and no higher than its ears' top): a coral canopy with a scalloped rim and a lighter middle panel, a wooden pole, a hook.

import 'dart:math' as math;
import 'dart:ui';

import 'package:mochi_art/mochi_art.dart';

abstract final class UmbrellaArt {
  /// Draws it for a Mochi whose feet are at [feet], [height] tall (pixels), [side] 1 to the right of it and -1 to the left.
  static void paint(Canvas canvas, Offset feet, double height, {required double side, bool dark = false}) {
    final h = height;
    final grip = Offset(feet.dx + side * 0.27 * h, feet.dy - 0.34 * h);
    final top = Offset(feet.dx + side * 0.52 * h, feet.dy - 0.78 * h);
    final length = (top - grip).distance;
    final tilt = math.atan2(top.dx - grip.dx, grip.dy - top.dy);
    final g = GContext(canvas)
      ..translateBy(grip.dx, grip.dy)
      ..rotate(tilt);
    final r = 0.34 * h;
    final line = math.max(0.7, h / 36);
    final wood = dark ? hex(0xD8B98F) : hex(0x9A6B3F);

    // The pole and its hooked handle.
    final pole = Path()
      ..moveTo(0, 0)
      ..lineTo(0, -length);
    g.stroke(pole, wood, line * 1.5);
    final hook = Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(0, line * 3, -side * line * 2.4, line * 3)
      ..quadraticBezierTo(-side * line * 4.4, line * 3, -side * line * 4.4, line * 0.8);
    g.stroke(hook, wood, line * 1.5);

    // The canopy: a dome with a scalloped rim, its centre at the pole's top.
    final c = g.copy()..translateBy(0, -length);
    final dome = Path()
      ..moveTo(-r, 0)
      ..quadraticBezierTo(-r, -r * 1.05, 0, -r * 1.05)
      ..quadraticBezierTo(r, -r * 1.05, r, 0)
      ..quadraticBezierTo(r * 0.67, r * 0.26, r * 0.33, 0)
      ..quadraticBezierTo(0, r * 0.26, -r * 0.33, 0)
      ..quadraticBezierTo(-r * 0.67, r * 0.26, -r, 0)
      ..close();
    c.fill(dome.shift(Offset(0, line)), black.fade(dark ? 0.3 : 0.14));
    c.fill(dome, hex(0xFF7A6B));
    // The lighter middle panel and a soft highlight.
    final panel = Path()
      ..moveTo(-r * 0.33, 0)
      ..quadraticBezierTo(-r * 0.3, -r * 0.95, 0, -r * 1.02)
      ..quadraticBezierTo(r * 0.3, -r * 0.95, r * 0.33, 0)
      ..quadraticBezierTo(0, r * 0.26, -r * 0.33, 0)
      ..close();
    c.fill(panel, hex(0xFFB3A6));
    c.fill(Shapes.ellipse(Offset(-r * 0.5, -r * 0.55), r * 0.26, r * 0.16), white.fade(0.4));
    c.stroke(dome, hex(0xC8483F), line * 0.9);
    // The tip.
    c.fill(Shapes.ellipse(Offset(0, -r * 1.08), line * 2.2, line * 2.2), hex(0xC8483F));
  }
}
