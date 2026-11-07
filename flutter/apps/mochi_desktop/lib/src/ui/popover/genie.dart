// The popover's genie (macOS' minimise effect, run backwards to open): the panel flows out of Mochi's spot on the
// taskbar, a thin neck at Mochi widening and rising into the whole panel, and funnels back down into it to close.
//
// It's a mesh warp of one picture of the panel: horizontal strips whose top and bottom follow the panel as it rises,
// and whose left and right edges ease from Mochi's x out to the panel's edges, the rows nearest Mochi last. Pure maths
// here (tested), drawn with Canvas.drawVertices and an ImageShader by the popover's stage.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// Where a genie runs: the panel's rect and Mochi's spot (the neck), in the same coordinates.
class Genie {
  const Genie({required this.panel, required this.spot, this.strips = 48});

  /// The panel when it's all the way out.
  final Rect panel;

  /// Mochi's spot on the taskbar: where the neck narrows to (its x) and where the panel comes from (its y).
  final Offset spot;

  /// How many horizontal strips the warp has.
  final int strips;

  static double _clamp(double x) => x.clamp(0.0, 1.0).toDouble();
  static double _smooth(double x) {
    final c = _clamp(x);
    return c * c * (3 - 2 * c);
  }

  static double _easeOut(double x) {
    final c = 1 - _clamp(x);
    return 1 - c * c * c;
  }

  /// How far the funnel's bend reaches up the panel: 1 means the neck's narrowing spans the whole height.
  static const double spread = 1.1;

  /// The top and bottom of the panel's picture at [t] (0: folded into Mochi's spot; 1: all the way out). The top
  /// leads and the bottom follows, so the panel stretches up out of the spot.
  (double top, double bottom) span(double t) {
    final top = _lerp(spot.dy, panel.top, _easeOut(_clamp(t / 0.85)));
    final bottom = _lerp(spot.dy, panel.bottom, _easeOut(_clamp((t - 0.15) / 0.85)));
    return (top, bottom);
  }

  /// How wide the picture's row [v] (0 at the panel's top, 1 at its bottom) is at [t], from 0 (narrowed to Mochi's x)
  /// to 1 (the panel's full width). The rows nearest Mochi open last: a neck.
  static double widening(double v, double t) => _smooth(t * (1 + spread) - v * spread);

  /// Row [v]'s place at [t]: its y, and its left and right edges.
  ({double y, double left, double right}) row(double v, double t) {
    final (top, bottom) = span(t);
    final w = widening(v, t);
    return (y: _lerp(top, bottom, v), left: _lerp(spot.dx, panel.left, w), right: _lerp(spot.dx, panel.right, w));
  }

  /// How opaque the picture is at [t] (it fades in over the first part).
  static double opacity(double t) => _smooth(t * 4);

  /// The warp's triangles at [t]: positions on the canvas, and where each samples the picture ([image] pixels: the
  /// panel's size times the picture's pixel ratio).
  Vertices vertices(double t, Size image) {
    final positions = Float32List((strips + 1) * 4);
    final texture = Float32List((strips + 1) * 4);
    for (var i = 0; i <= strips; i++) {
      final v = i / strips;
      final (:y, :left, :right) = row(v, t);
      positions
        ..[i * 4] = left
        ..[i * 4 + 1] = y
        ..[i * 4 + 2] = right
        ..[i * 4 + 3] = y;
      texture
        ..[i * 4] = 0
        ..[i * 4 + 1] = v * image.height
        ..[i * 4 + 2] = image.width
        ..[i * 4 + 3] = v * image.height;
    }
    final indices = Uint16List(strips * 6);
    for (var i = 0; i < strips; i++) {
      final a = i * 2, b = i * 2 + 1, c = i * 2 + 2, d = i * 2 + 3;
      indices.setAll(i * 6, [a, b, c, b, d, c]);
    }
    return Vertices.raw(VertexMode.triangles, positions, textureCoordinates: texture, indices: indices);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// The smallest rect the warp covers at [t] (for click-through and repaint bounds).
  Rect bounds(double t) {
    var left = double.infinity, right = double.negativeInfinity;
    for (var i = 0; i <= strips; i++) {
      final r = row(i / strips, t);
      left = math.min(left, r.left);
      right = math.max(right, r.right);
    }
    final (top, bottom) = span(t);
    return Rect.fromLTRB(left, top, right, bottom);
  }
}

/// Mochi's leap between its spot on the taskbar and its place in the popover's room: an arc, squashed on take-off,
/// stretched in the air, squashed again on landing (with a puff of dust), growing or shrinking between the taskbar's
/// size and the room's.
class Leap {
  const Leap({required this.from, required this.to, required this.fromScale, required this.toScale, this.height = 46});

  final Offset from;
  final Offset to;
  final double fromScale;
  final double toScale;

  /// How far above the higher end the arc peaks.
  final double height;

  /// The part of the leap spent crouching before take-off, and squashing after landing.
  static const double crouch = 0.14;
  static const double land = 0.18;

  /// Where Mochi's feet are at [p] (0…1 through the leap).
  Offset feet(double p) {
    final air = Genie._clamp((p - crouch) / (1 - crouch - land));
    final x = Genie._lerp(from.dx, to.dx, Genie._smooth(air));
    final straight = Genie._lerp(from.dy, to.dy, air);
    final peak = math.min(from.dy, to.dy) - height;
    final lift = (straight - peak) * 4 * air * (1 - air);
    return Offset(x, straight - lift);
  }

  /// Mochi's size at [p].
  double scale(double p) => Genie._lerp(fromScale, toScale, Genie._smooth((p - crouch) / (1 - crouch - land)));

  /// The squash (scaleX, scaleY) at [p]: down and wide while crouching and landing, tall and thin in the air.
  (double, double) squash(double p) {
    if (p < crouch) {
      final s = math.sin(math.pi * p / crouch);
      return (1 + 0.12 * s, 1 - 0.16 * s);
    }
    if (p > 1 - land) {
      final s = math.sin(math.pi * (p - (1 - land)) / land);
      return (1 + 0.14 * s, 1 - 0.2 * s);
    }
    final air = (p - crouch) / (1 - crouch - land);
    final s = math.sin(math.pi * air);
    return (1 - 0.06 * s, 1 + 0.1 * s);
  }

  /// The dust puff after landing: 0 before, rising to 1 and fading.
  double dust(double p) => p <= 1 - land ? 0 : Genie._clamp((p - (1 - land)) / land);
}
