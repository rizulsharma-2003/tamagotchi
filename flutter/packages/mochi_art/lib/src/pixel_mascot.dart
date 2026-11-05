// Port of Sources/App/Rendering/PixelMascot.swift.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'drawing.dart';
import 'item_renderer.dart';
import 'model/ease.dart';
import 'model/poses.dart';
import 'model/world.dart';
import 'palettes.dart';

/// `PixelMascot.Options`.
class MascotOptions {
  MascotOptions({
    this.accessory,
    this.laptopOnLeft = false,
    this.reduced = false,
    this.speed = 0,
    this.snap,
    this.showsSpark = true,
    this.shadow = true,
    this.headroom,
  });

  Accessory? accessory;

  /// A laptop stands to the mascot's left: typing reaches for it and the eyes follow.
  bool laptopOnLeft;
  bool reduced;

  /// Horizontal speed in art pixels per second; the legs step while it moves.
  double speed;

  /// Snap bobbing to this many art pixels (half a pixel keeps a 1-pt sprite crisp).
  double? snap;
  bool showsSpark;
  bool shadow;

  /// Art pixels free above the head: the spinner moves beside the head when it wouldn't fit.
  double? headroom;
}

/// Where the body is this frame, in art pixels.
class _Frame {
  const _Frame(this.lift, this.rise, this.leanTop);

  final double lift;
  final double rise;
  final double leanTop;

  double get top => -(PixelMascot.legRows + rise + PixelMascot.bodyRows);
  double get bottom => -(PixelMascot.legRows + rise);

  double shift(double y) => (leanTop * -y / 15).roundToDouble();
}

typedef _Arms = ({List<Rect> left, List<Rect> right, Offset leftHand, Offset rightHand});

/// The Claude Code mascot in pixel art: an 18×12 terracotta body with two tall slit eyes, stubby
/// arms and four legs. Jumps, bobs and squash stay smooth; eyes, arms and legs change in whole
/// pixels, like hand-drawn frames. Local units are art pixels: origin between the feet, y down.
abstract final class PixelMascot {
  static final Color body = hex(0xCC7A5D);
  static final Color ink = hex(0x1D1719);
  static const double halfWidth = 9;
  static const double bodyRows = 12;
  static const double legRows = 3;

  /// Companion pose units (`CompanionPose.y`) in art pixels.
  static const double pixelsPerUnit = 21.6;

  /// Draws the mascot with its feet centred on `feet` (context units), `pixel` context units per art pixel.
  static void draw(CompanionPose pose, GContext context, Offset feet, double pixel, double time, [MascotOptions? options]) {
    final o = options ?? MascotOptions();
    if (pose.opacity <= 0.01) return;
    final g = context.copy()
      ..opacity = pose.opacity
      ..translateBy(feet.dx, feet.dy)
      ..scaleBy(pixel, pixel);

    final frame = _frameFor(pose, o);
    final spin = pose.rotation.abs() > 0.6 ? math.cos(pose.rotation) : 1.0;
    final squashX = pose.scaleX * spin;
    final squashY = pose.scaleY;

    if (o.shadow && pose.shadow > 0.05) {
      final fade = 1 - math.min(1.0, frame.lift / 22);
      g.fill(Shapes.ellipse(const Offset(0, 0.35), 21 * squashX.abs() + 1, 2.6), black.fade(0.16 * pose.shadow * fade));
    }

    final sprite = g.copy()
      ..translateBy(0, -frame.lift)
      ..scaleBy(squashX, squashY);
    final flipped = squashX < 0;

    // Body, arms and legs share one fill so their edges never seam.
    final shape = Path();
    for (var row = 0; row < bodyRows; row++) {
      final y = frame.top + row;
      shape.addRect(Rect.fromLTWH(-halfWidth + frame.shift(y + 0.5), y, 2 * halfWidth, 1));
    }
    final arms = _armRects(pose, o, time);
    for (final rect in [...arms.left, ...arms.right]) {
      shape.addRect(_placed(rect, frame));
    }
    for (final rect in _legRects(frame, o.speed, time, o.reduced)) {
      shape.addRect(rect);
    }
    final hoodie = o.accessory == Accessory.hoodie;
    sprite.fill(shape, body);

    if (hoodie) _drawHoodie(sprite, frame, [...arms.left, ...arms.right]);
    if (o.accessory == Accessory.scarf) _drawScarf(sprite, frame);
    _drawFace(pose, sprite, frame, o, flipped);
    _drawHeadwear(pose, o.accessory, sprite, frame);

    final index = o.showsSpark ? sparkFrame(pose, time, o.reduced) : null;
    if (index != null) {
      final spark = g.copy()..translateBy(0, -frame.lift);
      final hatLift = _wearsHat(pose, o.accessory) ? 5.0 : 0.0;
      var center = Offset(7 + pose.antennaBend * 4, frame.top - 5.5 - hatLift);
      final headroom = o.headroom;
      if (headroom != null && 8 + hatLift > headroom) {
        center = Offset(halfWidth + 5, frame.top + 1.5);
      }
      drawSpark(index, pose.antennaGlow, pose.antennaTint, center, spark);
    }

    final held = pose.held;
    if (held != null) {
      final left = held.heldInLeftHand;
      final hand = left ? arms.leftHand : arms.rightHand;
      var point = _placed(Rect.fromLTWH(hand.dx, hand.dy, 0, 0), frame).topLeft;
      var px = point.dx * squashX;
      var py = point.dy * squashY - frame.lift;
      px += left ? -1 : 0.5;
      py -= left ? 3.6 : 2.8;
      point = Offset(px, py);
      final item = context.copy()
        ..opacity = pose.opacity
        ..translateBy(feet.dx, feet.dy);
      ItemRenderer.draw(held, item, Offset(point.dx * pixel, point.dy * pixel), (left ? 7.2 : 6.4) * pixel);
    }
  }

  /// The top of the head above the feet, in art pixels (for placing marks over it).
  static double headTop(CompanionPose pose, [MascotOptions? options]) {
    final frame = _frameFor(pose, options ?? MascotOptions());
    return -(frame.top - frame.lift);
  }

  static _Frame _frameFor(CompanionPose pose, MascotOptions o) {
    final hover = pose.y * pixelsPerUnit;
    var bob = math.min(1.0, math.max(-1.0, hover));
    var lift = math.max(0.0, hover - 1);
    final snap = o.snap;
    if (snap != null && snap > 0) {
      bob = (bob / snap).roundToDouble() * snap;
      lift = (lift / snap).roundToDouble() * snap;
    }
    // Asleep or powered down it settles low, legs tucked under.
    final squat = (pose.eyes == VisorEyes.sleepy || pose.eyes == VisorEyes.off) ? 2.0 : 0.0;
    final lean = pose.rotation.abs() <= 0.6 ? pose.rotation * 15 : 0.0;
    return _Frame(lift, bob - squat, o.reduced ? 0 : lean);
  }

  static Rect _placed(Rect rect, _Frame frame, {double? shiftAt}) {
    final y = frame.top + rect.top;
    final shift = frame.shift(shiftAt != null ? frame.top + shiftAt : y + rect.height / 2);
    return Rect.fromLTWH(rect.left + shift, y, rect.width, rect.height);
  }

  // MARK: Limbs

  /// Arm rectangles relative to the body top, and the hands' positions.
  static _Arms _armRects(CompanionPose pose, MascotOptions o, double time) {
    final reach = pose.reach >= 0.75;
    (List<Rect>, Offset) arm(double side, double raise, double tapValue) {
      List<Rect> rects;
      Offset hand;
      if (raise >= 0.72) {
        final wave = raise >= 0.9 ? 1.0 : 0.0;
        rects = [const Rect.fromLTWH(9, -1, 2, 3), Rect.fromLTWH(9 + wave, -4, 2, 3)];
        hand = Offset(10 + wave, -4);
      } else if (raise >= 0.45) {
        rects = [const Rect.fromLTWH(9, 3, 3, 3), const Rect.fromLTWH(11, 1, 2, 2)];
        hand = const Offset(12, 1);
      } else if (raise >= 0.2) {
        rects = [const Rect.fromLTWH(9, 4, 3, 4)];
        hand = const Offset(12, 5);
      } else if (reach) {
        final tap = tapValue - 0.1 > 0.05 ? 1.0 : 0.0;
        final extra = o.laptopOnLeft && side < 0 ? 2.0 : 0.0;
        rects = [Rect.fromLTWH(9, 7 - tap, 2 + extra, 3)];
        hand = Offset(11 + extra, 8.5 - tap);
      } else {
        rects = [const Rect.fromLTWH(9, 6, 3, 4)];
        hand = const Offset(12, 8);
      }
      if (side < 0) {
        rects = rects.map((r) => Rect.fromLTWH(-r.right, r.top, r.width, r.height)).toList();
        hand = Offset(-hand.dx, hand.dy);
      }
      return (rects, hand);
    }

    final left = arm(-1, pose.leftArm, pose.leftArm);
    final right = arm(1, pose.rightArm, pose.rightArm);
    return (left: left.$1, right: right.$1, leftHand: left.$2, rightHand: right.$2);
  }

  /// Four legs; while moving, diagonal pairs take turns lifting.
  static List<Rect> _legRects(_Frame frame, double speed, double time, bool reduced) {
    final height = legRows + frame.rise;
    if (height <= 0.4) return const [];
    var lifted = -1;
    var tapping = -1;
    if (!reduced && speed.abs() > 2) {
      lifted = (time * 9).floor() % 2;
    } else if (!reduced) {
      // Idle: every so often one foot taps twice.
      final cycle = Ease.fract(time / 6.7) * 6.7;
      if (cycle < 0.5 && (cycle / 0.125).floor() % 2 == 0) tapping = 3;
    }
    const xs = [-8.0, -5.0, 3.0, 6.0];
    return [
      for (var index = 0; index < xs.length; index++)
        Rect.fromLTWH(xs[index], frame.bottom - 0.25, 2, height + 0.25 - ((index % 2 == lifted || index == tapping) ? 1 : 0)),
    ];
  }

  // MARK: Face

  static void _drawFace(CompanionPose pose, GContext g, _Frame frame, MascotOptions o, bool flipped) {
    var lookX = (Ease.clamp(pose.lookX, -1, 1) * 1.5).round();
    final lookY = (Ease.clamp(pose.lookY, -1, 1) * 1.5).round();
    if (o.laptopOnLeft && pose.reach >= 0.75 && pose.leftArm < 0.45 && pose.rightArm < 0.45) lookX = -1;
    if (flipped) lookX = -lookX;
    for (final side in const [-1, 1]) {
      var kind = pose.eyes;
      if (kind == VisorEyes.wink) kind = side < 0 ? VisorEyes.normal : VisorEyes.happy;
      final inner = side < 0 ? 1 : -1;
      final column = (side < 0 ? -6 : 5) + lookX;
      final color = switch (kind) {
        VisorEyes.star => hex(0xFFD166),
        VisorEyes.heart => hex(0xFF6F91),
        VisorEyes.off => hex(0x7B6A66),
        _ => ink,
      };
      // Each eye leans as one piece, so a lean never breaks it into a slash.
      final eye = Path();
      for (final (dx, dy) in eyeCells(kind, pose.eyeOpenness, inner)) {
        final rect = Rect.fromLTWH((column + dx).toDouble(), (3 + lookY + dy).toDouble(), 1, 1);
        eye.addRect(_placed(rect, frame, shiftAt: 4.5 + lookY));
      }
      g.fill(eye, color);
    }
    final cells = mouthCells(pose.mouth);
    if (cells != null) {
      final mouth = Path();
      for (final (dx, dy) in cells) {
        mouth.addRect(_placed(Rect.fromLTWH((dx + lookX ~/ 2).toDouble(), (8 + dy).toDouble(), 1, 1), frame, shiftAt: 9));
      }
      g.fill(mouth, ink);
    }
  }

  /// Eye pixels relative to the eye's top cell; `inner` points towards the middle of the face.
  static List<(int, int)> eyeCells(VisorEyes kind, double openness, int inner) {
    final closedLine = [(0, 2), (inner, 2)];
    switch (kind) {
      case VisorEyes.normal || VisorEyes.wink:
        if (openness > 0.62) return const [(0, 0), (0, 1), (0, 2)];
        return openness > 0.28 ? const [(0, 1), (0, 2)] : closedLine;
      case VisorEyes.happy:
        return const [(-1, 1), (0, 0), (1, 1)];
      case VisorEyes.focused:
        return [(0, 1), (inner, 1)];
      case VisorEyes.worried:
        return openness < 0.3 ? closedLine : [(inner, 0), (0, 1), (0, 2)];
      case VisorEyes.sleepy:
        return closedLine;
      case VisorEyes.wide:
        if (openness < 0.3) return closedLine;
        return [(0, -1), (0, 0), (0, 1), (0, 2), (inner, -1), (inner, 0), (inner, 1), (inner, 2)];
      case VisorEyes.closed:
        return const [(-1, 1), (0, 2), (1, 1)];
      case VisorEyes.star:
        return const [(0, 0), (-1, 1), (0, 1), (1, 1), (0, 2)];
      case VisorEyes.heart:
        return const [(-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1), (0, 2)];
      case VisorEyes.off:
        return const [(0, 1)];
    }
  }

  /// The mascot has no mouth; big feelings borrow one for a moment.
  static List<(int, int)>? mouthCells(VisorMouth mouth) => switch (mouth) {
    VisorMouth.grin => const [(-2, 0), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1)],
    VisorMouth.o => const [(-1, 0), (0, 0), (-1, 1), (0, 1)],
    VisorMouth.wavy => const [(-3, 1), (-2, 0), (-1, 1), (0, 0), (1, 1), (2, 0)],
    VisorMouth.none || VisorMouth.smile || VisorMouth.flat => null,
  };

  // MARK: The working spark

  /// Claude Code's spinner glyphs (· ✢ ✳ ✶ ✻ ✽) as 5×5 pixel frames.
  static final List<List<(int, int)>> sparkFrames = () {
    const dot = [(2, 2)];
    const small = [(2, 1), (1, 2), (2, 2), (3, 2), (2, 3)];
    const plus = [(2, 0), (2, 1), (0, 2), (1, 2), (2, 2), (3, 2), (4, 2), (2, 3), (2, 4)];
    final star = [...plus, (1, 1), (3, 1), (1, 3), (3, 3)];
    final cross = [(0, 0), (4, 0), (1, 1), (3, 1), (2, 2), (1, 3), (3, 3), (0, 4), (4, 4), ...small];
    final full = [...star, (0, 0), (4, 0), (0, 4), (4, 4)];
    return <List<(int, int)>>[dot, small, plus, star, cross, full];
  }();

  /// Which spinner frame shows now: it spins while Claude works and holds steady while it waits.
  static int? sparkFrame(CompanionPose pose, double time, bool reduced) {
    switch (pose.antennaTint) {
      case AntennaTint.working:
        if (pose.antennaGlow <= 0.3) return null;
        if (reduced) return 3;
        final step = (time / 0.1).floor() % 10;
        return step < 6 ? step : 10 - step;
      case AntennaTint.attention || AntennaTint.alert:
        return 4;
      case AntennaTint.calm || AntennaTint.off:
        return null;
    }
  }

  /// Claude orange while working, like the CLI's spinner; amber or red when it needs you.
  static Color sparkColor(AntennaTint tint) => tint == AntennaTint.working ? hex(0xE2805A) : CompanionPalette.antenna(tint);

  static void drawSpark(int index, double glow, AntennaTint tint, Offset center, GContext g) {
    final color = sparkColor(tint);
    final strength = Ease.clamp(glow);
    g.fillRadial(Shapes.ellipse(center, 11, 11), [color.fade(0.32 * strength), color.fade(0)], center, 0.5, 5.5);
    final cells = Path();
    for (final (x, y) in sparkFrames[index.clamp(0, sparkFrames.length - 1)]) {
      cells.addRect(Rect.fromLTWH(center.dx - 2.5 + x, center.dy - 2.5 + y, 1, 1));
    }
    g.fill(cells, color.fade(0.45 + 0.55 * strength));
  }

  // MARK: Wearables

  static bool _wearsHat(CompanionPose pose, Accessory? accessory) {
    if (pose.hat != null) return true;
    return switch (accessory) {
      Accessory.partyHat ||
      Accessory.beanie ||
      Accessory.graduationCap ||
      Accessory.detectiveHat ||
      Accessory.santaHat ||
      Accessory.witchHat ||
      Accessory.flowerCrown => true,
      _ => false,
    };
  }

  static void _fill(GContext g, _Frame frame, Color color, List<(double, double, double, double)> rects) {
    final path = Path();
    for (final (x, y, w, h) in rects) {
      path.addRect(_placed(Rect.fromLTWH(x, y, w, h), frame));
    }
    g.fill(path, color);
  }

  static void _drawHeadwear(CompanionPose pose, Accessory? accessory, GContext g, _Frame frame) {
    var worn = accessory;
    switch (pose.hat) {
      case HeldItem.detectiveHat:
        worn = Accessory.detectiveHat;
      case HeldItem.gradCap:
        worn = Accessory.graduationCap;
      default:
        break;
    }
    switch (worn) {
      case Accessory.partyHat:
        _fill(g, frame, hex(0xFF8FA3), [(-1, -1, 6, 1), (0, -3, 4, 1), (1, -5, 2, 1)]);
        _fill(g, frame, hex(0x7FD6C2), [(0, -2, 4, 1), (1, -4, 2, 1)]);
        _fill(g, frame, hex(0xFFD166), [(1, -7, 2, 2)]);
      case Accessory.beanie:
        _fill(g, frame, hex(0x3F7F9A), [(-9, -1, 18, 2)]);
        _fill(g, frame, hex(0x5BA3C0), [(-8, -2, 16, 1), (-6, -3, 12, 1), (-3, -4, 6, 1)]);
        _fill(g, frame, hex(0xF4EDE4), [(-1, -6, 2, 2)]);
      case Accessory.graduationCap:
        _fill(g, frame, hex(0x2E2A3A), [(-6, -2, 12, 2), (-10, -3, 20, 1)]);
        _fill(g, frame, hex(0xFFD166), [(-1, -4, 2, 1), (9, -2, 1, 4)]);
      case Accessory.detectiveHat:
        _fill(g, frame, hex(0x7A5A3E), [(-10, -1, 20, 1), (-8, -4, 16, 3)]);
        _fill(g, frame, hex(0x9C7A55), [
          (-6, -4, 2, 1), (-2, -4, 2, 1), (2, -4, 2, 1), (6, -4, 2, 1), //
          (-4, -3, 2, 1), (0, -3, 2, 1), (4, -3, 2, 1),
        ]);
      case Accessory.santaHat:
        _fill(g, frame, hex(0xE04B5A), [(-8, -2, 15, 1), (-6, -3, 12, 1), (-3, -4, 10, 1), (4, -5, 5, 1)]);
        _fill(g, frame, white, [(-9, -1, 18, 2), (9, -6, 2, 2)]);
      case Accessory.witchHat:
        _fill(g, frame, hex(0x40296A), [(-12, -1, 24, 1)]);
        _fill(g, frame, hex(0x5B3F8C), [
          (-5, -3, 10, 1), (-4, -4, 8, 1), (-3, -5, 6, 1), (-2, -6, 5, 1), //
          (0, -7, 3, 1), (2, -8, 2, 1), (3, -9, 2, 1),
        ]);
        _fill(g, frame, hex(0xFF9C3F), [(-5, -2, 10, 1)]);
        _fill(g, frame, hex(0xFFD166), [(-1, -2, 2, 1)]);
      case Accessory.flowerCrown:
        _fill(g, frame, hex(0x6FB794), [(-9, -1, 18, 1)]);
        final colors = [hex(0xFF8FB1), hex(0xFFD166), hex(0xB9A7FF), hex(0xFF9F80), hex(0x7FD6C2)];
        const xs = [-9.0, -5.0, -1.0, 3.0, 7.0];
        for (var index = 0; index < xs.length; index++) {
          _fill(g, frame, colors[index], [(xs[index], -3, 2, 2)]);
        }
      case Accessory.roundGlasses:
        final frameColor = hex(0x3A3340);
        _fill(g, frame, white.fade(0.18), [(-7, 3, 3, 4), (4, 3, 3, 4)]);
        _fill(g, frame, frameColor, [
          (-8, 2, 5, 1), (-8, 7, 5, 1), (-8, 3, 1, 4), (-4, 3, 1, 4), //
          (3, 2, 5, 1), (3, 7, 5, 1), (3, 3, 1, 4), (7, 3, 1, 4), (-3, 3, 6, 1),
        ]);
      case Accessory.headphones:
        final dark = hex(0x3A3340);
        _fill(g, frame, dark, [(-10, -2, 20, 1), (-10, -1, 1, 3), (9, -1, 1, 3)]);
        _fill(g, frame, hex(0xFF8FA3), [(-11, 2, 3, 4), (8, 2, 3, 4)]);
      default:
        break;
    }
  }

  static void _drawHoodie(GContext g, _Frame frame, List<Rect> arms) {
    final blue = hex(0x7C8CF2);
    final cloth = Path();
    for (var row = 6; row < bodyRows; row++) {
      final y = frame.top + row;
      cloth.addRect(Rect.fromLTWH(-halfWidth + frame.shift(y + 0.5), y, 2 * halfWidth, 1));
    }
    for (final rect in arms) {
      if (rect.top >= 5) cloth.addRect(_placed(rect, frame));
    }
    g.fill(cloth, blue);
    _fill(g, frame, hex(0x5E6BD0), [(-9, 6, 18, 1), (-4, 9, 8, 1), (-4, 10, 1, 1), (3, 10, 1, 1)]);
  }

  static void _drawScarf(GContext g, _Frame frame) {
    _fill(g, frame, hex(0xE04B5A), [(-9, 6, 18, 2), (3, 8, 2, 3)]);
    _fill(g, frame, white.fade(0.85), [(-6, 6, 1, 2), (-2, 6, 1, 2), (2, 6, 1, 2), (6, 6, 1, 2), (3, 11, 2, 1)]);
  }
}
