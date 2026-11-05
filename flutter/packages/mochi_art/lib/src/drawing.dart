// Port of Sources/App/Rendering/Drawing.swift: shapes, colours and a drawing context that
// behaves like SwiftUI's GraphicsContext, so the renderers port line by line.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// `Color(hex:)`: an opaque sRGB colour from 0xRRGGBB, optionally with an alpha.
Color hex(int rgb, [double alpha = 1]) =>
    Color.fromARGB((alpha.clamp(0, 1) * 255).round(), (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

/// SwiftUI's `Color.opacity(_:)`: multiplies the colour's alpha (named `fade` because Flutter's `Color` already has an `opacity` getter).
extension ColorOpacity on Color {
  Color fade(double value) => withValues(alpha: a * value.clamp(0.0, 1.0));
}

/// Shortcuts for the Swift colours `Color.white`, `.black` and `.clear`.
const Color white = Color(0xFFFFFFFF);
const Color black = Color(0xFF000000);
const Color clear = Color(0x00000000);

const double pi = math.pi;

double degrees(double value) => value * math.pi / 180;

// MARK: - Affine transforms

/// A 2D affine transform with CoreGraphics' layout: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
class Affine {
  const Affine(this.a, this.b, this.c, this.d, this.tx, this.ty);

  static const Affine identity = Affine(1, 0, 0, 1, 0, 0);

  factory Affine.translation(double x, double y) => Affine(1, 0, 0, 1, x, y);
  factory Affine.scale(double x, double y) => Affine(x, 0, 0, y, 0, 0);
  factory Affine.rotation(double radians) {
    final cos = math.cos(radians);
    final sin = math.sin(radians);
    return Affine(cos, sin, -sin, cos, 0, 0);
  }

  final double a, b, c, d, tx, ty;

  /// `self` applied after `m` (CoreGraphics' `m.concatenating(self)`; SwiftUI's
  /// `context.concatenate(m)` makes the context's transform `ctm.then(m)` in this notation).
  Affine then(Affine m) => Affine(
    a * m.a + c * m.b,
    b * m.a + d * m.b,
    a * m.c + c * m.d,
    b * m.c + d * m.d,
    a * m.tx + c * m.ty + tx,
    b * m.tx + d * m.ty + ty,
  );

  /// CoreGraphics' `concatenating(other)`: this transform first, then `other`.
  Affine concatenating(Affine other) => other.then(this);

  Offset apply(Offset p) => Offset(a * p.dx + c * p.dy + tx, b * p.dx + d * p.dy + ty);

  Float64List get storage => Float64List.fromList(<double>[a, b, 0, 0, c, d, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1]);
}

extension PathTransform on Path {
  /// `Path.applying(_:)`.
  Path applying(Affine t) => transform(t.storage);

  /// `Path.offsetBy(dx:dy:)`.
  Path offsetBy(double dx, double dy) => shift(Offset(dx, dy));
}

// MARK: - Path building

/// Swift `Path` calls with their CoreGraphics semantics.
extension SwiftPath on Path {
  /// `addArc(center:radius:startAngle:endAngle:clockwise:)` in SwiftUI's flipped space: with
  /// `clockwise: false` the angle increases from `start` to `end` (visually clockwise on screen).
  /// Like CoreGraphics it adds a line from the current point to the start of the arc.
  void arc(Offset center, double radius, double start, double end, {bool clockwise = false}) {
    var sweep = end - start;
    const full = 2 * math.pi;
    if (!clockwise) {
      if (sweep < 0) sweep = full - ((-sweep) % full);
      if (sweep > full) sweep = full;
    } else {
      if (sweep > 0) sweep = -(full - (sweep % full));
      if (sweep < -full) sweep = -full;
    }
    final rect = Rect.fromCircle(center: center, radius: radius);
    if (sweep.abs() >= full - 1e-9) {
      // A full circle: arcTo cannot draw 360° in one go.
      arcTo(rect, start, sweep / 2, false);
      arcTo(rect, start + sweep / 2, sweep / 2, false);
    } else {
      arcTo(rect, start, sweep, false);
    }
  }

  void moveToPoint(Offset p) => moveTo(p.dx, p.dy);
  void lineToPoint(Offset p) => lineTo(p.dx, p.dy);
  void quadTo(Offset to, Offset control) => quadraticBezierTo(control.dx, control.dy, to.dx, to.dy);
  void curveTo(Offset to, Offset c1, Offset c2) => cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, to.dx, to.dy);
  void addEllipseIn(Rect rect) => addOval(rect);
}

/// The `Path` helpers from Drawing.swift.
abstract final class Shapes {
  static Path rect(Rect r) => Path()..addRect(r);

  /// `Path.ellipse(center, width, height)` (CoreGraphics standardizes negative sizes).
  static Path ellipse(Offset center, double width, double height) =>
      Path()..addOval(Rect.fromCenter(center: center, width: width.abs(), height: height.abs()));

  /// `Path(roundedRect:cornerRadius:style: .continuous)`: Apple's continuous ("squircle")
  /// corners where they fit, plain circular corners where the radius is too big for them.
  static Path roundedRect(Rect r, double radius) {
    final rect = Rect.fromLTRB(math.min(r.left, r.right), math.min(r.top, r.bottom), math.max(r.left, r.right), math.max(r.top, r.bottom));
    final limit = math.min(rect.width, rect.height) / 2;
    final radiusClamped = math.max(0.0, math.min(radius, limit));
    if (radiusClamped <= 0) return Path()..addRect(rect);
    if (radiusClamped * 1.52866483 > limit) {
      return Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radiusClamped)));
    }
    return _continuous(rect, radiusClamped);
  }

  static Path _continuous(Rect rect, double r) {
    final path = Path();
    // Corners in order, each as (corner, arrival direction, leaving direction).
    final corners = <(Offset, Offset, Offset)>[
      (rect.topRight, const Offset(1, 0), const Offset(0, 1)),
      (rect.bottomRight, const Offset(0, 1), const Offset(-1, 0)),
      (rect.bottomLeft, const Offset(-1, 0), const Offset(0, -1)),
      (rect.topLeft, const Offset(0, -1), const Offset(1, 0)),
    ];
    var first = true;
    for (final (corner, u, v) in corners) {
      Offset p(double x, double y) => corner - u * (x * r) + v * (y * r);
      final start = p(1.52866483, 0);
      if (first) {
        path.moveToPoint(start);
        first = false;
      } else {
        path.lineToPoint(start);
      }
      path.curveTo(p(0.66993427, 0.06549600), p(1.08849323, 0), p(0.86840689, 0));
      path.lineToPoint(p(0.63149399, 0.07491100));
      path.curveTo(p(0.07491100, 0.63149399), p(0.37282392, 0.16905899), p(0.16906001, 0.37282401));
      path.lineToPoint(p(0.06549600, 0.66993427));
      path.curveTo(p(0, 1.52866483), p(0, 0.86840689), p(0, 1.08849323));
    }
    path.close();
    return path;
  }

  /// `Path.capsule(from:to:width:)`: a line from `a` to `b` stroked with round caps.
  static Path capsule(Offset a, Offset b, double width) {
    final r = width / 2;
    final delta = b - a;
    final length = delta.distance;
    if (length < 1e-9) return Path()..addOval(Rect.fromCircle(center: a, radius: r));
    final angle = math.atan2(delta.dy, delta.dx);
    final path = Path()
      ..arc(a, r, angle + math.pi / 2, angle + 3 * math.pi / 2)
      ..arc(b, r, angle - math.pi / 2, angle + math.pi / 2)
      ..close();
    return path;
  }

  /// Four-pointed sparkle.
  static Path sparkle(Offset center, double radius) {
    final path = Path();
    final inner = radius * 0.28;
    for (var index = 0; index < 8; index++) {
      final angle = index * math.pi / 4 - math.pi / 2;
      final r = index.isEven ? radius : inner;
      final point = Offset(center.dx + math.cos(angle) * r, center.dy + math.sin(angle) * r);
      index == 0 ? path.moveToPoint(point) : path.lineToPoint(point);
    }
    path.close();
    return path;
  }

  static Path star(Offset center, double radius) {
    final path = Path();
    for (var index = 0; index < 10; index++) {
      final angle = index * math.pi / 5 - math.pi / 2;
      final r = index.isEven ? radius : radius * 0.45;
      final point = Offset(center.dx + math.cos(angle) * r, center.dy + math.sin(angle) * r);
      index == 0 ? path.moveToPoint(point) : path.lineToPoint(point);
    }
    path.close();
    return path;
  }

  static Path heart(Offset center, double size) {
    final s = size / 2;
    final x = center.dx;
    final y = center.dy;
    final path = Path()
      ..moveTo(x, y + s * 0.9)
      ..curveTo(Offset(x - s, y - s * 0.2), Offset(x - s * 0.5, y + s * 0.5), Offset(x - s, y + s * 0.25))
      ..arc(Offset(x - s * 0.5, y - s * 0.3), s * 0.52, degrees(170), degrees(-10))
      ..arc(Offset(x + s * 0.5, y - s * 0.3), s * 0.52, degrees(190), degrees(10))
      ..curveTo(Offset(x, y + s * 0.9), Offset(x + s, y + s * 0.25), Offset(x + s * 0.5, y + s * 0.5))
      ..close();
    return path;
  }

  /// A path from a builder, like Swift's `Path { … }`.
  static Path build(void Function(Path path) body) {
    final path = Path();
    body(path);
    return path;
  }

  /// A single straight segment.
  static Path line(Offset a, Offset b) => Path()
    ..moveToPoint(a)
    ..lineToPoint(b);
}

// MARK: - Text

/// How `GContext.text` draws the few glyphs the art uses (z, ?, !, ♪). Swift draws them in
/// SF Pro Rounded; set [family] (and load the font) to match it, or leave it null for the
/// platform's default font.
abstract final class MochiArtText {
  static String? family;

  /// Set when [family] is a variable font, so the weight is applied as a `wght` axis too.
  static bool variableWeight = false;
}

// MARK: - Drawing context

/// A drawing context with SwiftUI `GraphicsContext` semantics: a value you copy (`copy()`),
/// then translate, scale, rotate or clip without affecting the original; `opacity` applies to
/// everything drawn through it (set, not multiplied, as in SwiftUI).
class GContext {
  GContext(this.canvas) : _m = Affine.identity, _clips = const [], opacity = 1;

  GContext._(this.canvas, this._m, this._clips, this.opacity);

  final Canvas canvas;
  Affine _m;
  List<Path> _clips;
  double opacity;

  Affine get transform => _m;

  GContext copy() => GContext._(canvas, _m, _clips, opacity);

  void translateBy(double x, double y) => _m = _m.then(Affine.translation(x, y));
  void scaleBy(double x, double y) => _m = _m.then(Affine.scale(x, y));
  void rotate(double radians) => _m = _m.then(Affine.rotation(radians));
  void concatenate(Affine t) => _m = _m.then(t);

  /// `clip(to:)`, or `clip(to:options: .inverse)` with [inverse].
  void clip(Path path, {bool inverse = false}) {
    var device = path.transform(_m.storage);
    if (inverse) {
      final everything = Path()..addRect(const Rect.fromLTRB(-1e5, -1e5, 1e5, 1e5));
      device = Path.combine(PathOperation.difference, everything, device);
    }
    _clips = [..._clips, device];
  }

  void _draw(void Function() body) {
    canvas.save();
    for (final clip in _clips) {
      canvas.clipPath(clip);
    }
    canvas.transform(_m.storage);
    body();
    canvas.restore();
  }

  Color _c(Color color) => opacity >= 1 ? color : color.fade(opacity);

  void fill(Path path, Color color) {
    if (opacity <= 0) return;
    final paint = Paint()
      ..isAntiAlias = true
      ..color = _c(color);
    _draw(() => canvas.drawPath(path, paint));
  }

  /// `stroke(path, color, width)` from Drawing.swift (round caps and joins by default). For a
  /// plain `StrokeStyle(lineWidth:)` pass `cap: StrokeCap.butt, join: StrokeJoin.miter`.
  void stroke(
    Path path,
    Color color,
    double width, {
    StrokeCap cap = StrokeCap.round,
    StrokeJoin join = StrokeJoin.round,
    List<double>? dash,
  }) {
    if (opacity <= 0) return;
    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = cap
      ..strokeJoin = join
      ..strokeMiterLimit = 10
      ..color = _c(color);
    final shape = dash == null ? path : dashed(path, dash);
    _draw(() => canvas.drawPath(shape, paint));
  }

  /// `fill(path, with: .linearGradient(Gradient(colors:), startPoint:, endPoint:))`.
  void fillLinear(Path path, List<Color> colors, Offset start, Offset end, {List<double>? stops}) {
    if (opacity <= 0) return;
    final shader = ui.Gradient.linear(start, end, colors.map(_c).toList(), stops ?? _even(colors.length));
    _draw(() => canvas.drawPath(path, Paint()..shader = shader));
  }

  /// `fill(path, with: .radialGradient(Gradient(colors:), center:, startRadius:, endRadius:))`.
  void fillRadial(Path path, List<Color> colors, Offset center, double startRadius, double endRadius) {
    if (opacity <= 0 || endRadius <= 0) return;
    final t0 = (startRadius / endRadius).clamp(0.0, 1.0);
    final stops = _even(colors.length).map((t) => t0 + t * (1 - t0)).toList();
    final shader = ui.Gradient.radial(center, endRadius, colors.map(_c).toList(), stops);
    _draw(() => canvas.drawPath(path, Paint()..shader = shader));
  }

  static List<double> _even(int count) => List<double>.generate(count, (i) => count == 1 ? 0 : i / (count - 1));

  /// `text(_:at:size:weight:color:)`: a short string centred on `point`.
  void text(String string, Offset point, double size, {FontWeight weight = FontWeight.w700, required Color color}) {
    if (opacity <= 0) return;
    final painter = TextPainter(
      text: TextSpan(
        text: string,
        style: TextStyle(
          fontSize: size,
          fontWeight: weight,
          fontFamily: MochiArtText.family,
          fontVariations: MochiArtText.variableWeight ? [FontVariation.weight(weight.value.toDouble())] : null,
          color: _c(color),
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _draw(() => painter.paint(canvas, point - Offset(painter.width / 2, painter.height / 2)));
    painter.dispose();
  }

  /// Runs `body` with this context's transform and clips applied to the raw canvas.
  void raw(void Function(Canvas canvas) body) => _draw(() => body(canvas));
}

/// A dashed copy of `path` (`StrokeStyle(dash:)`).
Path dashed(Path path, List<double> pattern) {
  if (pattern.isEmpty) return path;
  final out = Path();
  for (final metric in path.computeMetrics()) {
    var distance = 0.0;
    var index = 0;
    var draw = true;
    while (distance < metric.length) {
      final length = pattern[index % pattern.length];
      final end = math.min(metric.length, distance + length);
      if (draw) out.addPath(metric.extractPath(distance, end), Offset.zero);
      distance = end;
      draw = !draw;
      index++;
    }
  }
  return out;
}
