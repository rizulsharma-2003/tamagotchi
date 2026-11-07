// Port of Sources/App/Features/Seasons/SeasonalTreats.swift.

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:mochi_world/mochi_world.dart' show TreatStyle;

import 'drawing.dart';
import 'item_renderer.dart';

// `TreatStyle` (which treat for which holiday) lives in mochi_world with the seasons; the art for each is here.
export 'package:mochi_world/mochi_world.dart' show TreatStyle;

/// Drawn in place of the cookie, centred on the origin.
abstract final class SeasonalTreats {
  /// The current season's treat (the Swift season controller keeps it up to date).
  static TreatStyle style = TreatStyle.cookie;

  static void draw(GContext g, double size, double spin) => drawStyle(style, g, size, spin);

  static void drawStyle(TreatStyle style, GContext g, double size, double spin) {
    final k = size / 12;
    final t = g.copy()..scaleBy(k, k);
    switch (style) {
      case TreatStyle.cookie:
        ItemRenderer.cookie(g, size, spin: spin, seasonal: false);
      case TreatStyle.candy:
        candy(t, spin);
      case TreatStyle.laddoo:
        laddoo(t, spin);
      case TreatStyle.gingerbread:
        gingerbread(t, spin);
      case TreatStyle.cakeSlice:
        cakeSlice(t);
      case TreatStyle.heartCookie:
        heartCookie(t, spin);
    }
  }

  /// A wrapped sweet: a striped orange-and-purple candy with twisted ends. Rolls with `spin`.
  static void candy(GContext g, double spin) {
    final c = g.copy()..rotate(spin * 0.6);
    final wrapper = hex(0xFF9C3F);
    final edge = hex(0xB9531A);
    for (final side in [-1.0, 1.0]) {
      final twist = Path()
        ..moveTo(side * 3.6, 0)
        ..lineTo(side * 7.2, -3.2)
        ..quadraticBezierTo(side * 6.2, 0, side * 7.2, 3.2)
        ..close();
      c.fill(twist, hex(0x9A6BE0));
      c.stroke(twist, hex(0x5E3E9C), 0.7);
    }
    final body = Shapes.ellipse(Offset.zero, 9, 7.4);
    c.fill(body, wrapper);
    final stripes = c.copy()..clip(body);
    for (final x in [-3.0, 0.4, 3.8]) {
      stripes.fill(Shapes.rect(Rect.fromLTWH(x - 0.8, -4, 1.6, 8)).applying(const Affine(1, 0, -0.45, 1, 0, 0)), hex(0x9A6BE0));
    }
    c.stroke(body, edge, 0.8);
    c.fill(Shapes.ellipse(const Offset(-1.6, -1.8), 3, 1.6), white.fade(0.6));
  }

  /// A round, golden laddoo with a grainy texture and a fleck of pistachio.
  static void laddoo(GContext g, double spin) {
    final ball = Shapes.ellipse(Offset.zero, 11, 11);
    g.fillRadial(ball, [hex(0xFFC65C), hex(0xE8901F)], const Offset(-1.8, -2), 0, 7.5);
    final grains = g.copy()
      ..clip(ball)
      ..rotate(spin);
    for (var index = 0; index < 14; index++) {
      final angle = index * 2.4;
      final r = 1.3 + (index % 4) * 1.05;
      grains.fill(
        Shapes.ellipse(Offset(math.cos(angle) * r, math.sin(angle) * r), 1.1, 0.9),
        index % 3 == 0 ? hex(0xFFE3A3) : hex(0xC97416).fade(0.7),
      );
    }
    grains.fill(Shapes.ellipse(const Offset(1.6, -2.6), 1.8, 1.2), hex(0x8CC152));
    g.stroke(ball, hex(0xB86B12), 0.8);
    g.fill(Shapes.ellipse(const Offset(-2, -2.6), 2.6, 1.6), white.fade(0.5));
  }

  /// A little gingerbread person with icing trim and buttons.
  static void gingerbread(GContext g, double spin) {
    final c = g.copy()..rotate(math.sin(spin) * 0.35);
    const limbs = [
      (Offset(-2.4, -1.4), Offset(-5.8, 0.8)),
      (Offset(2.4, -1.4), Offset(5.8, 0.8)),
      (Offset(-1.7, 3), Offset(-2.8, 6.2)),
      (Offset(1.7, 3), Offset(2.8, 6.2)),
    ];
    final head = Shapes.ellipse(const Offset(0, -4.2), 6, 6);
    final torso = Shapes.roundedRect(const Rect.fromLTWH(-3.4, -2.6, 6.8, 6.6), 2.4);
    // Outline first, then each part filled on its own so overlaps stay solid.
    final edge = hex(0x8A4F22);
    for (final (a, b) in limbs) {
      c.stroke(Shapes.line(a, b), edge, 4.4);
    }
    c.stroke(head, edge, 1.4);
    c.stroke(torso, edge, 1.4);
    final dough = hex(0xC27A3E);
    for (final (a, b) in limbs) {
      c.stroke(Shapes.line(a, b), dough, 3);
    }
    c.fill(head, dough);
    c.fill(torso, dough);
    for (final (a, b) in limbs) {
      final tip = Offset(a.dx + (b.dx - a.dx) * 0.8, a.dy + (b.dy - a.dy) * 0.8);
      final dx = (b.dy - a.dy) * 0.18;
      final dy = -(b.dx - a.dx) * 0.18;
      c.stroke(Shapes.line(Offset(tip.dx - dx, tip.dy - dy), Offset(tip.dx + dx, tip.dy + dy)), white.fade(0.9), 0.5);
    }
    c.fill(Shapes.ellipse(const Offset(-1.1, -4.6), 0.9, 0.9), hex(0x3B2416));
    c.fill(Shapes.ellipse(const Offset(1.1, -4.6), 0.9, 0.9), hex(0x3B2416));
    final smile = Path()
      ..moveTo(-1.1, -3)
      ..quadraticBezierTo(0, -2.1, 1.1, -3);
    c.stroke(smile, white, 0.6);
    c.fill(Shapes.ellipse(const Offset(0, -0.6), 1.2, 1.2), hex(0xFF6B6B));
    c.fill(Shapes.ellipse(const Offset(0, 1.8), 1.2, 1.2), hex(0x7FD6C2));
  }

  /// A wedge of birthday cake with a strawberry on top. Cake doesn't roll, so `spin` is ignored.
  static void cakeSlice(GContext g) {
    final wedge = Path()
      ..moveTo(-6.5, 4.5)
      ..lineTo(6.5, 4.5)
      ..lineTo(6.5, -2.5)
      ..lineTo(-6.5, 0.5)
      ..close();
    g.fill(wedge, hex(0xFFE7B8));
    final layer = g.copy()..clip(wedge);
    layer.fill(Shapes.rect(const Rect.fromLTWH(-7, 1.4, 14, 1.3)), hex(0xFF8FB1));
    layer.fill(Shapes.rect(const Rect.fromLTWH(-7, -1.6, 14, 1.1)).applying(const Affine(1, -0.2, 0, 1, 0, 0)), hex(0xFF8FB1));
    g.stroke(wedge, hex(0xC99A5B), 0.8);
    final icing = Path()
      ..moveTo(-6.8, 0.6)
      ..lineTo(6.8, -2.6)
      ..lineTo(6.8, -4.2)
      ..lineTo(-6.8, -0.9)
      ..close();
    g.fill(icing, hex(0xFFF4F7));
    g.stroke(icing, hex(0xF2B5C8), 0.6);
    g.fill(Shapes.heart(const Offset(3.4, -5.6), 4.4), hex(0xF0525A));
    g.fill(Shapes.rect(const Rect.fromLTWH(3.1, -8.2, 0.7, 1.2)), hex(0x6B8E3A));
  }

  /// A heart-shaped sugar cookie with pink icing.
  static void heartCookie(GContext g, double spin) {
    final c = g.copy()..rotate(math.sin(spin) * 0.3);
    final cookie = Shapes.heart(const Offset(0, 0.4), 13);
    c.fill(cookie, hex(0xE9B36F));
    c.stroke(cookie, hex(0xB07B3C), 0.8);
    c.fill(Shapes.heart(const Offset(0, 0.2), 9.6), hex(0xFF8FB1));
    for (final (x, y) in const [(-2.2, -1.2), (1.8, -0.4), (0.0, 1.6), (-0.6, -2.4)]) {
      c.fill(Shapes.ellipse(Offset(x, y), 0.9, 0.9), white.fade(0.9));
    }
  }
}
