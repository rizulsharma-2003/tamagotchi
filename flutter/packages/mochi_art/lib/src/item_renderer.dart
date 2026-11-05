// Port of Sources/App/Rendering/ItemRenderer.swift: the props the characters hold
// (`ItemRenderer`) and the particles, symbols and speech bubbles around them (`EffectRenderer`).

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'accessory_renderer.dart';
import 'drawing.dart';
import 'model/ease.dart';
import 'model/poses.dart';
import 'model/world.dart';
import 'palettes.dart';
import 'pet_renderer.dart';
import 'seasonal_treats.dart';

/// Small props the characters hold, drawn centered on a point in local units.
abstract final class ItemRenderer {
  static final Color outline = hex(0x5B4A5E);

  static void draw(HeldItem item, GContext ctx, Offset c, double size) {
    final s = size / 16;
    final g = ctx.copy()
      ..translateBy(c.dx, c.dy)
      ..scaleBy(s, s);
    switch (item) {
      case HeldItem.coffee:
        final cup = Shapes.roundedRect(const Rect.fromLTWH(-5.5, -5, 11, 11), 2.5);
        g.fill(cup, hex(0xFFFFFF));
        g.stroke(cup, outline, 1.1);
        g.fill(Shapes.rect(const Rect.fromLTWH(-5.5, -1, 11, 3)), hex(0xFF8FA3));
        final handle = Path()..arc(const Offset(6, 0.5), 3, degrees(-80), degrees(80));
        g.stroke(handle, outline, 1.4);
        g.fill(Shapes.ellipse(const Offset(0, -5), 9, 2.4), hex(0x8A5A3C));
      case HeldItem.ball:
        ball(g, 6, 0);
      case HeldItem.document:
        final page = Shapes.roundedRect(const Rect.fromLTWH(-6, -8, 12, 16), 1.5);
        g.fill(page, white);
        g.stroke(page, outline, 1);
        for (var row = 0; row < 5; row++) {
          g.fill(Shapes.rect(Rect.fromLTWH(-4, -5.5 + row * 2.6, row == 4 ? 4.5 : 8, 1.1)), hex(0x9C93AE));
        }
      case HeldItem.taskCard:
        final card = Shapes.roundedRect(const Rect.fromLTWH(-8, -6, 16, 12), 1.8);
        g.fill(card, hex(0xFFF6D8));
        g.stroke(card, outline, 1);
        for (var row = 0; row < 3; row++) {
          final y = -3 + row * 3.2;
          g.stroke(Shapes.roundedRect(Rect.fromLTWH(-6, y - 1, 2, 2), 0.4), outline, 0.7);
          g.fill(Shapes.rect(Rect.fromLTWH(-2.5, y - 0.5, 8, 1.1)), hex(0xB59E7A));
        }
      case HeldItem.magnifier:
        g.stroke(Shapes.line(const Offset(2.5, 2.5), const Offset(7, 7)), hex(0x8A5A3C), 2.6);
        final lens = Shapes.ellipse(const Offset(-1, -1), 10, 10);
        g.fill(lens, hex(0xBFE9FF).fade(0.55));
        g.stroke(lens, hex(0x6D6D7E), 1.8);
        g.fill(Shapes.ellipse(const Offset(-2.8, -2.8), 2.6, 1.6), white.fade(0.8));
      case HeldItem.codeCard:
        final card = Shapes.roundedRect(const Rect.fromLTWH(-9, -6.5, 18, 13), 2);
        g.fill(card, hex(0x2A2232));
        g.stroke(card, outline, 1);
        final colors = [hex(0x7FE3CB), hex(0xFFD166), hex(0xB9A7FF), hex(0xFF9FB2)];
        for (var row = 0; row < 4; row++) {
          g.fill(
            Shapes.roundedRect(Rect.fromLTWH(-6.5 + (row % 2) * 2, -4.2 + row * 2.6, (6 + (row * 5) % 7).toDouble(), 1.3), 0.6),
            colors[row],
          );
        }
      case HeldItem.trophy:
        final cup = Path()
          ..moveTo(-5.5, -7)
          ..lineTo(5.5, -7)
          ..quadTo(const Offset(0, 2), const Offset(5.5, 2))
          ..quadTo(const Offset(-5.5, -7), const Offset(-5.5, 2));
        g.fill(cup, hex(0xFFCF4A));
        g.stroke(cup, hex(0xB8862B), 1);
        for (final side in const [-1.0, 1.0]) {
          final handle = Path()..arc(Offset(side * 5.5, -4.2), 2.4, degrees(side < 0 ? 90 : -90), degrees(side < 0 ? 270 : 90));
          g.stroke(handle, hex(0xB8862B), 1.2);
        }
        g.fill(Shapes.rect(const Rect.fromLTWH(-1, 1.5, 2, 3)), hex(0xE0AE35));
        g.fill(Shapes.roundedRect(const Rect.fromLTWH(-4, 4.2, 8, 2.6), 0.8), hex(0x8A5A3C));
        g.fill(Shapes.sparkle(const Offset(-2, -4.5), 1.8), white.fade(0.9));
      case HeldItem.gradCap:
        AccessoryRenderer.graduationCap(g, Offset.zero, 18);
      case HeldItem.rock:
        final rock = Shapes.ellipse(Offset.zero, 11, 9);
        g.fill(rock, hex(0xA59FAE));
        g.stroke(rock, outline, 1);
        g.fill(Shapes.ellipse(const Offset(-2, -1.5), 3, 2), white.fade(0.35));
      case HeldItem.paper:
        final sheet = Shapes.roundedRect(const Rect.fromLTWH(-5.5, -7, 11, 14), 1);
        g.fill(sheet, white);
        g.stroke(sheet, outline, 1);
        g.fill(Shapes.rect(const Rect.fromLTWH(-3.5, -3, 7, 1)), hex(0xC9C2D6));
        g.fill(Shapes.rect(const Rect.fromLTWH(-3.5, 0, 7, 1)), hex(0xC9C2D6));
      case HeldItem.scissors:
        for (final side in const [-1.0, 1.0]) {
          g.stroke(Shapes.ellipse(Offset(side * 3, 4), 4.6, 4.6), hex(0xFF6B6B), 1.6);
          g.stroke(Shapes.line(Offset(side * 2.2, 1.5), Offset(-side * 3.5, -7.5)), hex(0x8C849A), 1.8);
        }
      case HeldItem.errorBoard:
        g.stroke(Shapes.line(const Offset(0, 5), const Offset(0, 9)), hex(0x8A5A3C), 1.6);
        final board = Shapes.roundedRect(const Rect.fromLTWH(-8, -7, 16, 12), 1.8);
        g.fill(board, hex(0x3A3346));
        g.stroke(board, hex(0x8A5A3C), 1.4);
        g.text('!', const Offset(-3, -1), 8, color: hex(0xFF8A7A));
        g.fill(Shapes.rect(const Rect.fromLTWH(0, -3, 5.5, 1.2)), hex(0xFFC2B8));
        g.fill(Shapes.rect(const Rect.fromLTWH(0, 0, 4, 1.2)), hex(0xFFC2B8));
      case HeldItem.treat:
        cookie(g, 12);
      case HeldItem.detectiveHat:
        AccessoryRenderer.deerstalker(g, const Offset(0, 2), 20);
    }
  }

  static void cookie(GContext g, double size, {double spin = 0, bool seasonal = true}) {
    // Holidays swap the cookie for a seasonal treat (candy, a laddoo, gingerbread, cake).
    if (seasonal && SeasonalTreats.style != TreatStyle.cookie) {
      SeasonalTreats.draw(g, size, spin);
      return;
    }
    final shape = Shapes.ellipse(Offset.zero, size, size);
    g.fillRadial(shape, [hex(0xF2C27F), hex(0xDE9F58)], Offset(-size * 0.15, -size * 0.18), 0, size * 0.6);
    g.stroke(shape, hex(0xA8743B), math.max(0.9, size / 12));
    final chips = g.copy()..rotate(spin);
    for (final (x, y) in const [(-2.2, -1.8), (2.4, -0.6), (-0.4, 2.6), (1.6, 3.2), (-3.2, 1.4), (0.6, -3.4)]) {
      chips.fill(Shapes.ellipse(Offset(x * size / 12, y * size / 12), 1.8 * size / 12, 1.6 * size / 12), hex(0x6B3F22));
    }
  }

  /// A shiny red play ball with a white band; the band and stars turn with `spin`,
  /// the highlight stays put so it reads as a sphere.
  static void ball(GContext g, double radius, double spin, {bool tiny = false}) {
    final r = radius;
    final circle = Shapes.ellipse(Offset.zero, r * 2, r * 2);
    g.fillRadial(circle, [hex(0xFF8A80), hex(0xF0525A)], Offset(-r * 0.35, -r * 0.4), 0, r * 1.3);
    final inner = g.copy()
      ..clip(circle)
      ..rotate(spin);
    final band = Path()
      ..moveTo(-r * 1.2, -r * 0.28)
      ..quadTo(Offset(r * 1.2, -r * 0.28), Offset(0, r * 0.32))
      ..lineTo(r * 1.2, r * 0.22)
      ..quadTo(Offset(-r * 1.2, r * 0.22), Offset(0, r * 0.82))
      ..close();
    inner.fill(band, white.fade(0.95));
    inner.fill(Shapes.star(Offset(0, -r * 0.62), r * 0.28), hex(0xFFD166));
    g.fill(Shapes.ellipse(Offset(-r * 0.38, -r * 0.45), r * 0.55, r * 0.36), white.fade(0.65));
    g.stroke(circle, hex(0xB43B45), tiny ? 2 : math.max(0.9, r * 0.16));
  }

  /// A yarn ball with wound strands.
  static void yarn(GContext g, double radius, double spin, {bool tiny = false}) {
    final r = radius;
    final circle = Shapes.ellipse(Offset.zero, r * 2, r * 2);
    final base = hex(0xB79BFF);
    final dark = hex(0x8A6ADF);
    g.fillRadial(circle, [hex(0xD3C2FF), base], Offset(-r * 0.3, -r * 0.35), 0, r * 1.2);
    final inner = g.copy()
      ..clip(circle)
      ..rotate(spin);
    final width = tiny ? 1.4 : math.max(0.7, r * 0.12);
    for (var index = 0; index < 4; index++) {
      final offset = index * r * 0.42 - r * 0.6;
      final strand = Path()
        ..moveTo(-r * 1.1, offset - r * 0.3)
        ..quadTo(Offset(r * 1.1, offset + r * 0.2), Offset(0, offset + r * 0.55));
      inner.stroke(strand, dark.fade(0.75), width);
    }
    final cross = Path()
      ..moveTo(-r * 0.5, -r * 1.1)
      ..quadTo(Offset(-r * 0.2, r * 1.1), Offset(r * 0.5, 0));
    inner.stroke(cross, dark.fade(0.6), width);
    g.fill(Shapes.ellipse(Offset(-r * 0.35, -r * 0.45), r * 0.5, r * 0.32), white.fade(0.45));
    g.stroke(circle, hex(0x6E50C2), tiny ? 2 : math.max(0.9, r * 0.15));
  }

  /// A fish treat facing left. `bites` 0…2 nibbles from the head, 3 = only bones left.
  static void fish(GContext g, int bites, {bool tiny = false}) {
    final line = tiny ? 2.0 : 1.0;
    if (bites >= 3) {
      final bone = hex(0xF4EEE6);
      final edge = hex(0xA8957E);
      final skeleton = Path()
        ..moveTo(-5, 0)
        ..lineTo(6, 0);
      for (var index = 0; index < 3; index++) {
        final x = index * 3 - 2.5;
        skeleton
          ..moveTo(x, -2.8)
          ..lineTo(x + 0.8, 2.8);
      }
      skeleton
        ..addEllipseIn(const Rect.fromLTWH(-9.6, -2.7, 5.2, 5.4))
        ..moveTo(6, 0)
        ..lineTo(9.5, -3)
        ..lineTo(9.5, 3)
        ..close();
      g.stroke(skeleton, edge, tiny ? 3.4 : 2.6);
      g.stroke(skeleton, bone, tiny ? 1.8 : 1.3);
      return;
    }
    final body = g.copy();
    if (bites > 0) {
      final bitten = Path();
      for (var index = 0; index < bites; index++) {
        final x = -9.5 + index * 4.2;
        bitten
          ..addEllipseIn(Rect.fromLTWH(x - 4.2, -4.6, 6, 4.8))
          ..addEllipseIn(Rect.fromLTWH(x - 3.6, -1.2, 5.8, 5.2));
      }
      body.clip(bitten, inverse: true);
    }
    final fishPath = Path()
      ..moveTo(-9, 0)
      ..quadTo(const Offset(5, -0.2), const Offset(-2, -9))
      ..lineTo(10, -4.5)
      ..quadTo(const Offset(10, 4.5), const Offset(8.2, 0))
      ..lineTo(5, 0.2)
      ..quadTo(const Offset(-9, 0), const Offset(-2, 9))
      ..close();
    body.fillLinear(fishPath, [hex(0xFF9F6E), hex(0xFFC49A)], const Offset(0, -5), const Offset(0, 5));
    for (var index = 0; index < 2; index++) {
      final x = index * 3.4 - 1.5;
      final stripe = Path()
        ..moveTo(x, -3.4)
        ..quadTo(Offset(x, 3.4), Offset(x + 1.6, 0));
      body.stroke(stripe, hex(0xE5774A).fade(0.8), 0.9);
    }
    body.fill(Shapes.ellipse(const Offset(-5.4, -1.2), 2.2, 2.2), hex(0x3A2A33));
    body.fill(Shapes.ellipse(const Offset(-5.7, -1.5), 0.8, 0.8), white);
    body.stroke(fishPath, hex(0xC4663F), line);
  }

  /// A strawberry with seeds and a leafy crown.
  static void berry(GContext g, double size, {bool tiny = false}) {
    final s = size;
    final shape = Path()
      ..moveTo(0, 6 * s)
      ..curveTo(Offset(-6 * s, -2.5 * s), Offset(-3 * s, 5 * s), Offset(-6.5 * s, 1 * s))
      ..quadTo(Offset(6 * s, -2.5 * s), Offset(0, -7.5 * s))
      ..curveTo(Offset(0, 6 * s), Offset(6.5 * s, 1 * s), Offset(3 * s, 5 * s))
      ..close();
    g.fillRadial(shape, [hex(0xFF7A8A), hex(0xE83E58)], Offset(-1.5 * s, -1 * s), 0, 7 * s);
    if (!tiny) {
      for (final (x, y) in const [(-2.6, 0.0), (0.0, 1.6), (2.6, 0.0), (-1.3, 3.4), (1.3, 3.4), (-1.4, -1.8), (1.4, -1.8)]) {
        g.fill(Shapes.ellipse(Offset(x * s, y * s), 0.9 * s, 1.2 * s), hex(0xFFE08A));
      }
    }
    g.stroke(shape, hex(0xB12C45), tiny ? 2 : 0.9);
    for (var index = 0; index < 3; index++) {
      final leaf = g.copy()
        ..translateBy(0, -4.2 * s)
        ..rotate((index - 1) * 0.9);
      final path = Shapes.ellipse(Offset(0, -1.8 * s), 2.4 * s, 4.2 * s);
      leaf.fill(path, hex(0x6CCB6A));
      leaf.stroke(path, hex(0x3F8E45), 0.7);
    }
  }

  /// A cupcake: `variant` 0 full, 1 frosting licked, 2 a bite taken, 4 two bites, 3 only the
  /// wrapper. Bites come out of the left side, where Mochi eats from.
  static void cupcake(GContext g, double size, {int variant = 0, bool tiny = false}) {
    final s = size;
    final wrapper = Path()
      ..moveTo(-6 * s, 0)
      ..lineTo(6 * s, 0)
      ..lineTo(4.4 * s, 7 * s)
      ..lineTo(-4.4 * s, 7 * s)
      ..close();
    if (variant == 3) {
      // Just the crumpled wrapper.
      final crumpled = g.copy()
        ..scaleBy(1, 0.75)
        ..translateBy(0, 2.4 * s);
      crumpled.fill(wrapper, hex(0x8FD3FF));
      crumpled.stroke(wrapper, hex(0x4F8FB8), tiny ? 2 : 0.9);
      crumpled.fill(Shapes.ellipse(Offset(-1.5 * s, -0.4 * s), 2.4 * s, 1.6 * s), hex(0xC98A55));
      return;
    }
    g.fill(wrapper, hex(0x8FD3FF));
    if (!tiny) {
      for (var index = 0; index < 4; index++) {
        final x = index * 3 - 4.5;
        g.stroke(Shapes.line(Offset(x * s, 0.4 * s), Offset(x * 0.78 * s, 6.6 * s)), white.fade(0.7), 0.8);
      }
    }
    g.stroke(wrapper, hex(0x4F8FB8), tiny ? 2 : 0.9);
    final top = g.copy();
    if (variant == 2 || variant == 4) {
      // Bites out of the top left (and a second, deeper one).
      final bite = Path()..addEllipseIn(Rect.fromLTWH(-9.5 * s, -9.5 * s, 9 * s, 8 * s));
      if (variant == 4) bite.addEllipseIn(Rect.fromLTWH(-6.5 * s, -7.5 * s, 9.5 * s, 8.5 * s));
      top.clip(bite, inverse: true);
    }
    final frosting = Path()
      ..moveTo(-7 * s, 0.5 * s)
      ..quadTo(Offset(-3 * s, -4.5 * s), Offset(-7.5 * s, -4 * s))
      ..quadTo(Offset(3 * s, -4.5 * s), Offset(0, -8 * s))
      ..quadTo(Offset(7 * s, 0.5 * s), Offset(7.5 * s, -4 * s))
      ..close();
    top.fill(frosting, hex(0xFFB3CF));
    top.stroke(frosting, hex(0xD9708F), tiny ? 2 : 0.9);
    if (variant >= 1) {
      // A lick-shaped dent in the frosting.
      final lick = Path()
        ..moveTo(-3.6 * s, -3 * s)
        ..quadTo(Offset(1.6 * s, -3.4 * s), Offset(-1 * s, -0.8 * s));
      top.stroke(lick, hex(0xE58AAA), tiny ? 1.8 : 1.1);
    } else {
      top.fill(Shapes.ellipse(Offset(0, -6.6 * s), 3.6 * s, 3.6 * s), hex(0xE83E58));
    }
    top.fill(Shapes.ellipse(Offset(-2.5 * s, -2.8 * s), 2.6 * s, 1.4 * s), white.fade(0.6));
    if (!tiny && variant <= 2) {
      for (final (x, y, c) in const [(-4.0, -1.5, 0x7FD6C2), (2.6, -2.2, 0xFFD166), (4.4, -0.6, 0x9C8CFF), (-1.2, -4.6, 0x7FD6C2)]) {
        top.fill(Shapes.roundedRect(Rect.fromLTWH(x * s - 0.7, y * s - 0.35, 1.4, 0.7), 0.3), hex(c));
      }
    }
  }

  static void crumb(GContext g, int variant, double size) {
    final s = size;
    final path = Path();
    switch (variant.remainder(3)) {
      case 0:
        path
          ..moveTo(-1.6 * s, -1 * s)
          ..lineTo(1.4 * s, -1.5 * s)
          ..lineTo(1.7 * s, 1.1 * s)
          ..lineTo(-1.1 * s, 1.5 * s);
      case 1:
        path
          ..moveTo(-1.3 * s, -1.4 * s)
          ..lineTo(1.6 * s, -0.4 * s)
          ..lineTo(-0.4 * s, 1.6 * s);
      default:
        path.addEllipseIn(Rect.fromLTWH(-1.3 * s, -1.1 * s, 2.6 * s, 2.2 * s));
    }
    path.close();
    g.fill(path, hex(0xE0A35E));
    g.stroke(path, hex(0xA8743B), 0.6);
  }
}

/// Particles, symbols and speech bubbles, positioned in body units around a character.
abstract final class EffectRenderer {
  static void draw(
    Effect effect,
    GContext ctx, {
    required double unitX,
    required double unitY,
    required bool dark,
    RenderDetail detail = RenderDetail.standard,
  }) {
    if (!(effect.opacity > 0.01 && effect.scale > 0.01)) return;
    final tiny = detail == RenderDetail.tiny;
    final g = ctx.copy()
      ..opacity = Ease.clamp(effect.opacity)
      ..translateBy(effect.x * unitX, -effect.y * unitY);
    // Props that roll spin their own pattern; everything else rotates as a whole.
    final spins = switch (effect.kind) {
      EffectKind.ball || EffectKind.yarn || EffectKind.berry || EffectKind.treat => true,
      _ => false,
    };
    if (!spins) g.rotate(effect.rotation);
    // Particles grow at menu-bar size so they still read; floor props stay true to size.
    final boost = switch (effect.kind) {
      EffectKind.ball ||
      EffectKind.yarn ||
      EffectKind.fish ||
      EffectKind.berry ||
      EffectKind.cupcake ||
      EffectKind.treat ||
      EffectKind.shadow ||
      EffectKind.butterfly ||
      EffectKind.bubble => tiny ? 1.15 : 1.0,
      _ => tiny ? 1.5 : 1.0,
    };
    g.scaleBy(effect.scale * boost, effect.scale * boost);
    final ink = dark ? hex(0xE9E3F2) : hex(0x6A5C7A);
    final stroke = tiny ? 2.2 : 1.4;
    switch (effect.kind) {
      case EffectKind.z:
        g.text('z', Offset.zero, 13, weight: FontWeight.w800, color: ink.fade(0.85));
      case EffectKind.sparkle:
        // Variant 1 is the pastel play sparkle; gold (0) is kept for real-event reactions.
        final pastel = effect.variant == 1;
        g.fill(Shapes.sparkle(Offset.zero, 6), pastel ? hex(0xFFB8D6) : hex(0xFFD166));
        if (!tiny) g.fill(Shapes.sparkle(Offset.zero, 2.6), pastel ? white : hex(0xFFF6D0));
      case EffectKind.star:
        if (effect.variant == 1) {
          // Lavender "dizzy" star.
          final star = Shapes.star(Offset.zero, 5);
          g.fill(star, hex(0xB9A7FF));
          g.stroke(star, ink.fade(0.7), tiny ? 1.4 : 0.8);
        } else {
          g.fill(Shapes.star(Offset.zero, 5), hex(0xFFD166));
        }
      case EffectKind.heart:
        g.fill(Shapes.heart(Offset.zero, 10), hex(0xFF6F91));
        if (!tiny) g.fill(Shapes.ellipse(const Offset(-2, -1.8), 2.4, 1.6), white.fade(0.55));
      case EffectKind.question:
        g.text('?', Offset.zero, 16, weight: FontWeight.w800, color: hex(0x9C8CFF));
      case EffectKind.exclamation:
        g.text('!', Offset.zero, 16, weight: FontWeight.w800, color: hex(0xFF8A5C));
      case EffectKind.sweat:
        final drop = Path()
          ..moveTo(0, -5)
          ..quadTo(const Offset(0, 4), const Offset(5.5, 2.5))
          ..quadTo(const Offset(0, -5), const Offset(-5.5, 2.5));
        g.fill(drop, hex(0x8FD3FF));
        g.fill(Shapes.ellipse(const Offset(-1, 1), 1.6, 2.2), white.fade(0.8));
      case EffectKind.note:
        // Swift draws "♪" / "♫" in SF Rounded; that font has no music glyphs, so they are paths here.
        musicNote(g, effect.variant.remainder(2) == 0, hex(0x9C8CFF));
      case EffectKind.confetti:
        final color = ConfettiPalette.colors[effect.variant.abs() % ConfettiPalette.colors.length];
        g.fill(Shapes.roundedRect(const Rect.fromLTWH(-2.5, -1.4, 5, 2.8), 0.8), color);
      case EffectKind.steam:
        for (var index = 0; index < 2; index++) {
          final x = index * 4.0 - 2;
          final phase = effect.rotation * 2 + index;
          final wisp = Path()
            ..moveTo(x, 0)
            ..curveTo(Offset(x, -12), Offset(x + 3 * math.sin(phase), -4), Offset(x - 3 * math.sin(phase), -8));
          g.stroke(wisp, ink.fade(0.35), 1.4);
        }
      case EffectKind.speechDots || EffectKind.speechLock || EffectKind.speechQuestion || EffectKind.plug:
        bubble(g, dark, (inner) {
          switch (effect.kind) {
            case EffectKind.speechLock:
              lockSymbol(inner, const Rect.fromLTWH(-4.5, -5, 9, 10), hex(0xE58A2E));
            case EffectKind.speechQuestion:
              inner.text('?', const Offset(0, -0.5), 11, weight: FontWeight.w800, color: hex(0x9C8CFF));
            case EffectKind.plug:
              offlineSymbol(inner, const Rect.fromLTWH(-6, -5, 12, 10), hex(0x8C849A));
            default:
              for (var index = 0; index < 3; index++) {
                inner.fill(Shapes.ellipse(Offset((index - 1) * 4.0, 0), 2.6, 2.6), hex(0x6A5C7A));
              }
          }
        });
      case EffectKind.thinkingDots:
        for (var index = 0; index < 3; index++) {
          final active = effect.variant == 3 || index < effect.variant;
          g.fill(Shapes.ellipse(Offset(index * 5.5 - 5.5, -index * 2.5), 3.6, 3.6), ink.fade(active ? 0.8 : 0.25));
        }
      case EffectKind.clap:
        for (var index = 0; index < 8; index++) {
          final angle = index * math.pi / 4;
          final ray = Shapes.line(Offset(math.cos(angle) * 6, math.sin(angle) * 6), Offset(math.cos(angle) * 11, math.sin(angle) * 11));
          g.stroke(ray, hex(0xFFD166), 1.8);
        }
        g.fill(Shapes.sparkle(Offset.zero, 5), hex(0xFFF1B8));
      case EffectKind.ball:
        squashed(g, effect, (s) => ItemRenderer.ball(s, 6.5, effect.rotation, tiny: tiny));
      case EffectKind.treat:
        squashed(g, effect, (s) => ItemRenderer.cookie(s, 11, spin: effect.rotation));
      case EffectKind.orb:
        orb(g, effect.rotation);
      case EffectKind.yarn:
        // The strand first, so the ball sits on top of it.
        strand(g, Offset(effect.x2 * unitX / (effect.scale * boost), -effect.y2 * unitY / (effect.scale * boost)), tiny: tiny);
        squashed(g, effect, (s) => ItemRenderer.yarn(s, 7, effect.rotation, tiny: tiny));
      case EffectKind.shadow:
        g.fill(Shapes.ellipse(Offset.zero, 15, 4.2), black.fade(dark ? 0.3 : 0.14));
      case EffectKind.dust:
        dust(g, effect.phase, dark: dark, tiny: tiny, flip: effect.variant == 0);
      case EffectKind.streak:
        streak(g, effect.variant, ink, stroke, tiny: tiny);
      case EffectKind.purr:
        purr(g, effect.variant, effect.phase, ink, stroke);
      case EffectKind.crumb:
        ItemRenderer.crumb(g, effect.variant, 1.8);
      case EffectKind.tangle:
        break; // drawn in body space by PetRenderer
      case EffectKind.butterfly:
        butterfly(g, effect.phase, effect.variant, tiny: tiny);
      case EffectKind.bubble:
        soapBubble(g, effect.phase, tiny: tiny);
      case EffectKind.pop:
        pop(g, effect.phase, effect.variant, stroke);
      case EffectKind.fish:
        squashed(g, effect, (s) => ItemRenderer.fish(s, effect.variant, tiny: tiny));
      case EffectKind.berry:
        squashed(g, effect, (context) {
          final rolled = context.copy()..rotate(effect.rotation);
          ItemRenderer.berry(rolled, 1.05, tiny: tiny);
        });
      case EffectKind.cupcake:
        // Squashes onto its base (7 units below its centre).
        final base = g.copy()..translateBy(0, 7);
        squashed(base, effect, (squash) {
          final c = squash.copy()..translateBy(0, -7);
          ItemRenderer.cupcake(c, 1, variant: effect.variant, tiny: tiny);
        });
      case EffectKind.frosting:
        final blob = Path()
          ..moveTo(-4, 1.6)
          ..quadTo(const Offset(-1.6, -2.6), const Offset(-4.4, -2))
          ..quadTo(const Offset(1.8, -2.4), const Offset(0, -4.4))
          ..quadTo(const Offset(4, 1.6), const Offset(4.6, -1.6))
          ..close();
        g.fill(blob, hex(0xFFB3CF));
        g.stroke(blob, hex(0xD9708F), tiny ? 1.6 : 0.8);
        g.fill(Shapes.ellipse(const Offset(-1.2, -1.2), 1.8, 1.1), white.fade(0.75));
      case EffectKind.sniff:
        sniffPuffs(g, effect.phase, effect.variant == 1, ink, stroke, tiny: tiny);
      case EffectKind.sneeze:
        sneeze(g, effect.phase, dark, stroke);
      case EffectKind.noseBubble:
        const r = 7.0;
        final circle = Shapes.ellipse(Offset.zero, r * 2, r * 2);
        g.fill(circle, hex(0xBFE6FF).fade(0.45));
        g.stroke(circle, hex(0x8FC9F0), tiny ? 1.8 : 0.9);
        g.fill(Shapes.ellipse(const Offset(-2.6, -2.8), 3.2, 2.2), white.fade(0.85));
      case EffectKind.shakeLines:
        shakeLines(g, effect.variant, ink, stroke, tiny: tiny);
      case EffectKind.burst:
        burst(g, effect.phase, stroke, pale: effect.variant == 1);
      case EffectKind.notice:
        // Three short strokes fanning out above the head.
        for (var index = 0; index < 3; index++) {
          final angle = -math.pi / 2 + (index - 1) * 0.55;
          final line = Shapes.line(
            Offset(math.cos(angle) * 4.5, math.sin(angle) * 4.5),
            Offset(math.cos(angle) * 10, math.sin(angle) * 10),
          );
          g.stroke(line, ink.fade(0.75), stroke + 0.4);
        }
      case EffectKind.droplet:
        final drop = Path()
          ..moveTo(0, -4)
          ..quadTo(const Offset(0, 3.4), const Offset(4.4, 2))
          ..quadTo(const Offset(0, -4), const Offset(-4.4, 2));
        g.fill(drop, hex(0x9FDBFF));
        g.stroke(drop, hex(0x5FB1E6), 0.6);
      case EffectKind.heartPop:
        heartPop(g, effect.phase);
    }
  }

  /// Applies a prop's squash (negative `stretch`) or stretch, keeping its volume.
  static void squashed(GContext g, Effect effect, void Function(GContext g) draw) {
    final k = Ease.clamp(effect.stretch, -0.6, 0.6);
    final s = g.copy()..scaleBy(1 - 0.7 * k, 1 + k);
    draw(s);
  }

  static void strand(GContext g, Offset end, {required bool tiny}) {
    if (!(end.dx.abs() + end.dy.abs() > 1)) return;
    final start = Offset(end.dx > 0 ? 5 : -5, 3);
    final sag = math.max(4.0, end.dx.abs() * 0.18);
    final path = Path()
      ..moveToPoint(start)
      ..curveTo(
        end,
        Offset(start.dx + (end.dx - start.dx) * 0.3, math.max(start.dy, end.dy) + sag),
        Offset(start.dx + (end.dx - start.dx) * 0.75, end.dy + sag * 0.4),
      );
    g.stroke(path, hex(0x6E50C2).fade(0.5), tiny ? 2.6 : 2.0);
    g.stroke(path, hex(0xB79BFF), tiny ? 1.6 : 1.1);
  }

  /// Yarn loops around the body (body space: origin at the feet, units of the 60×54 body).
  static void tangle(Effect effect, GContext body, PetStyle style) {
    if (!(effect.opacity > 0.01)) return;
    final g = body.copy()
      ..opacity = Ease.clamp(effect.opacity)
      ..translateBy(0, -27)
      ..rotate(effect.rotation)
      ..scaleBy(effect.scale, effect.scale)
      ..translateBy(0, 27);
    final wobble = math.sin(effect.phase * 5) * 1.2;
    // Bands wrap the lower body and stay clear of the face.
    const bands = [(-7.0, 11.0, 0.1), (-12.5, 12.0, -0.2), (-18.0, 10.0, 0.24)];
    final count = math.min(3, math.max(0, effect.variant));
    for (var index = 0; index < count; index++) {
      final (y, h, tilt) = bands[index];
      final band = g.copy()
        ..translateBy(0, y + wobble * (index.isEven ? 1 : -1))
        ..rotate(tilt);
      final front = Path()..arc(Offset.zero, 1, degrees(8), degrees(172));
      final arc = front.applying(Affine.scale(33, h / 2));
      band.stroke(arc, hex(0x6E50C2).fade(0.55), style.tiny ? 4 : 3.0);
      band.stroke(arc, hex(0xB79BFF), style.tiny ? 2.4 : 1.8);
    }
    if (effect.variant >= 2) {
      final dangle = Path()
        ..moveTo(24, -12)
        ..curveTo(const Offset(31, -1), const Offset(32, -11), const Offset(25, -5));
      g.stroke(dangle, hex(0xB79BFF), style.tiny ? 2.4 : 1.6);
    }
  }

  static void dust(GContext g, double phase, {required bool dark, required bool tiny, required bool flip}) {
    final fill = dark ? hex(0xCFC6DA).fade(0.62) : hex(0xE9DCCB);
    final edge = dark ? hex(0xA79DB4).fade(0.7) : hex(0xBFA88E);
    final s = flip ? -1.0 : 1.0;
    final puffs = [(0.0, 0.0, 7.5), (s * 5.5, 1.2, 5.6), (-s * 4.8, 1.6, 4.6)];
    for (final (x, y, r) in puffs) {
      final circle = Shapes.ellipse(Offset(x, y - phase * 2), r, r * 0.86);
      g.fill(circle, fill);
      g.stroke(circle, edge, tiny ? 1.6 : 0.8);
    }
  }

  static void streak(GContext g, int side, Color ink, double width, {bool tiny = false}) {
    if (tiny) {
      // One bold mark reads at menu-bar size; three thin ones blur into a smudge.
      if (side == 2) {
        for (var index = 0; index < 2; index++) {
          final y = index * 7.0 - 3.5;
          g.stroke(Shapes.line(Offset(0, y), Offset(index == 0 ? -14 : -9, y)), ink.fade(0.75), 2.6);
        }
        return;
      }
      final flip = side == 0 ? 1.0 : -1.0;
      final arc = Path()..arc(Offset(0, flip * 7), 12, degrees(flip > 0 ? -150 : 150), degrees(flip > 0 ? -60 : 60), clockwise: flip < 0);
      g.stroke(arc, ink.fade(0.85), 3.2);
      return;
    }
    if (side == 2) {
      // Straight speed lines (drawn behind a runner, pointing back).
      for (var index = 0; index < 3; index++) {
        final y = (index - 1) * 6.0;
        final length = index == 1 ? 15.0 : 10.0;
        g.stroke(Shapes.line(Offset(0, y), Offset(-length, y)), ink.fade(index == 1 ? 0.5 : 0.35), width);
      }
      return;
    }
    final flip = side == 0 ? 1.0 : -1.0;
    for (var index = 0; index < 3; index++) {
      final r = 9 + index * 3.2;
      final arc = Path()
        ..arc(Offset(0, flip * r * 0.6), r, degrees(flip > 0 ? -150 : 150), degrees(flip > 0 ? -60 : 60), clockwise: flip < 0);
      g.stroke(arc, ink.fade(0.55 - 0.13 * index), width);
    }
  }

  static void purr(GContext g, int side, double phase, Color ink, double width) {
    final s = side == 0 ? -1.0 : 1.0;
    for (var index = 0; index < 3; index++) {
      final jitter = math.sin(phase * 47 + index * 2.1) * 0.9;
      final x = s * index * 3.4;
      final arc = Path()..arc(Offset(x - s * 6, jitter), 6, degrees(s > 0 ? -38 : 142), degrees(s > 0 ? 38 : 218));
      g.stroke(arc, ink.fade(0.6 - 0.15 * index), width);
    }
  }

  static void shakeLines(GContext g, int side, Color ink, double width, {bool tiny = false}) {
    final s = side == 0 ? -1.0 : 1.0;
    // Two longer, bolder arcs at menu-bar size.
    final count = tiny ? 2 : 3;
    for (var index = 0; index < count; index++) {
      final y = tiny ? index * 9.0 - 4.5 : (index - 1) * 6.5;
      final half = tiny ? 3.6 : 2.6;
      final arc = Path()
        ..moveTo(0, y - half)
        ..quadTo(Offset(0, y + half), Offset(s * (tiny ? 3.4 : 2.4), y));
      g.stroke(arc, ink.fade(tiny ? 0.8 : 0.6), tiny ? 2.8 : width);
    }
  }

  static void sniffPuffs(GContext g, double phase, bool flip, Color ink, double width, {bool tiny = false}) {
    final p = phase;
    final s = flip ? -1.0 : 1.0;
    if (tiny) {
      // A single round puff at the nose.
      final puff = Shapes.ellipse(Offset(s * (5 + 4 * p), -1), 6 + 3 * p, 5 + 2.5 * p);
      g.stroke(puff, ink.fade(0.8), 2.4);
      return;
    }
    for (var index = 0; index < 2; index++) {
      final y = index * 4.5 - 2;
      final arc = Path()
        ..moveTo(s * (2 + 4 * p), y)
        ..quadTo(Offset(s * (7 + 5 * p), y - 1), Offset(s * (4.5 + 4 * p), y - 3));
      g.stroke(arc, ink.fade(0.55), width * 0.9);
    }
  }

  static void sneeze(GContext g, double phase, bool dark, double width) {
    final p = phase;
    final cloud = dark ? hex(0xEDE7F6).fade(0.75) : white;
    final edge = dark ? hex(0xB9AFC7) : hex(0xC9BFD6);
    const puffs = [(4.0, 0.0, 7.0), (10.0, -3.0, 6.0), (11.0, 3.5, 5.5), (16.0, 0.0, 4.5)];
    for (final (x, y, r) in puffs) {
      final c = Shapes.ellipse(Offset(x * (0.6 + 0.8 * p), y * (0.7 + 0.6 * p)), r * (0.6 + 0.7 * p), r * (0.6 + 0.7 * p));
      g.fill(c, cloud);
      g.stroke(c, edge, 0.8);
    }
    for (var index = 0; index < 4; index++) {
      final angle = index * 0.5 - 0.75;
      final r = 10 + 16 * p;
      g.fill(Shapes.ellipse(Offset(math.cos(angle) * r + 6, math.sin(angle) * r), 2, 2), hex(0x9FDBFF));
    }
    final line = Path()
      ..moveTo(2, -9 - 4 * p)
      ..lineTo(6, -13 - 5 * p)
      ..moveTo(8, -7 - 4 * p)
      ..lineTo(13, -10 - 5 * p);
    g.stroke(line, edge, width);
  }

  static void burst(GContext g, double phase, double width, {bool pale = false}) {
    final p = phase;
    final ray = pale ? hex(0xFFD9B8) : hex(0xFFC94A);
    final core = pale ? white : hex(0xFFF1B8);
    for (var index = 0; index < 8; index++) {
      final angle = index * math.pi / 4 + 0.2;
      final inner = 5 + 9 * p;
      final outer = inner + 5 * (1 - p) + 1.5;
      final line = Shapes.line(
        Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        Offset(math.cos(angle) * outer, math.sin(angle) * outer),
      );
      g.stroke(line, ray, width + 0.4);
    }
    g.fill(Shapes.sparkle(Offset.zero, 6 * (1 - p) + 1.5), core);
  }

  static void pop(GContext g, double phase, int variant, double width) {
    final p = phase;
    final colors = [hex(0xFF8FAB), hex(0x62BDF2), hex(0xFFC23D)];
    final color = colors[variant.abs() % colors.length];
    for (var index = 0; index < 7; index++) {
      final angle = index * 2 * math.pi / 7;
      final r = 4 + 10 * p;
      final point = Offset(math.cos(angle) * r, math.sin(angle) * r);
      if (index.isEven) {
        g.stroke(Shapes.line(point, Offset(point.dx * 1.35, point.dy * 1.35)), color, width);
      } else {
        g.fill(Shapes.ellipse(point, 2.6 * (1 - p) + 0.8, 2.6 * (1 - p) + 0.8), color);
      }
    }
    if (p < 0.5) {
      g.stroke(Shapes.ellipse(Offset.zero, 14 * (0.6 + p), 14 * (0.6 + p)), color.fade(1 - p * 2), width * 0.8);
    }
    g.fill(Shapes.sparkle(Offset.zero, 5 * (1 - p)), white.fade(0.9));
  }

  static void heartPop(GContext g, double phase) {
    final p = phase;
    for (var index = 0; index < 5; index++) {
      final angle = index * 2 * math.pi / 5 - math.pi / 2;
      final r = 3 + 11 * p;
      g.fill(Shapes.heart(Offset(math.cos(angle) * r, math.sin(angle) * r), 4.5 * (1 - 0.5 * p)), hex(0xFF6F91));
    }
    g.fill(Shapes.sparkle(Offset.zero, 5 * (1 - p)), hex(0xFFD6E0));
  }

  static void butterfly(GContext g, double phase, int variant, {required bool tiny}) {
    final open = 0.22 + 0.78 * math.cos(phase).abs();
    const palettes = [(0xFF9F80, 0xFFC36E, 0xC0566F), (0x8FD3FF, 0xB9A7FF, 0x4F74B8)];
    final (a, b, edgeHex) = palettes[variant.abs() % palettes.length];
    final edge = hex(edgeHex);
    for (var index = 0; index < 2; index++) {
      final side = index == 0 ? -1.0 : 1.0;
      final wing = g.copy()..scaleBy(side * open, 1);
      final upper = Shapes.ellipse(const Offset(5.2, -3.2), 10, 9);
      final lower = Shapes.ellipse(const Offset(4, 3.6), 7, 6.4);
      wing.fillLinear(upper, [hex(a), hex(b)], const Offset(0, -7), const Offset(10, 2));
      wing.fill(lower, hex(b));
      wing.stroke(upper, edge, tiny ? 1.6 : 0.8);
      wing.stroke(lower, edge, tiny ? 1.6 : 0.8);
      if (!tiny) {
        wing.fill(Shapes.ellipse(const Offset(6.2, -3.6), 3.2, 3.2), white.fade(0.75));
        wing.fill(Shapes.ellipse(const Offset(4.4, 4), 1.8, 1.8), white.fade(0.6));
      }
    }
    g.fill(Shapes.capsule(const Offset(0, -5), const Offset(0, 6), tiny ? 3 : 2.4), hex(0x5B4A5E));
    for (var index = 0; index < 2; index++) {
      final side = index == 0 ? -1.0 : 1.0;
      final antenna = Path()
        ..moveTo(0, -5)
        ..quadTo(Offset(side * 3.2, -10), Offset(side * 0.6, -9));
      g.stroke(antenna, hex(0x5B4A5E), tiny ? 1.4 : 0.8);
      g.fill(Shapes.ellipse(Offset(side * 3.2, -10), 1.6, 1.6), hex(0x5B4A5E));
    }
  }

  static void soapBubble(GContext g, double phase, {required bool tiny}) {
    final wobble = math.sin(phase * 5) * 0.05;
    final b = g.copy()..scaleBy(1 + wobble, 1 - wobble);
    const r = 8.5;
    final circle = Shapes.ellipse(Offset.zero, r * 2, r * 2);
    b.fillRadial(circle, [hex(0xEAF7FF).fade(0.25), hex(0xA9DDFF).fade(0.55)], Offset.zero, r * 0.3, r);
    b.stroke(circle, hex(0x6CC0F0), tiny ? 1.8 : 1.3);
    final sheen = Path()..arc(Offset.zero, r - 1.6, degrees(20), degrees(110));
    b.stroke(sheen, hex(0xFFB8DD).fade(0.75), tiny ? 1.6 : 1.0);
    final shine = Path()..arc(Offset.zero, r - 2.4, degrees(200), degrees(250));
    b.stroke(shine, white.fade(0.95), tiny ? 2 : 1.4);
    b.fill(Shapes.ellipse(const Offset(-r * 0.42, -r * 0.5), 2.2, 2.2), white.fade(0.9));
  }

  static void bubble(GContext g, bool dark, void Function(GContext g) content) {
    final path = Shapes.roundedRect(const Rect.fromLTWH(-10, -8, 20, 16), 7)
      ..moveTo(3, 7.5)
      ..lineTo(7, 12)
      ..lineTo(7.5, 6);
    g.fill(path.offsetBy(0, 1), black.fade(0.12));
    g.fill(path, dark ? hex(0xF4EFFA) : white);
    g.stroke(path, hex(0xC9BFD6), 0.8);
    content(g);
  }

  static void orb(GContext g, double phase) {
    g.fillRadial(
      Shapes.ellipse(Offset.zero, 26, 26),
      [hex(0xC6FF9E).fade(0.6 + 0.2 * math.sin(phase * 5)), hex(0xC6FF9E).fade(0)],
      Offset.zero,
      2,
      13,
    );
    g.fill(Shapes.ellipse(Offset.zero, 8, 8), hex(0xF4FFD9));
    g.text('?', const Offset(0, -0.5), 6, weight: FontWeight.w800, color: hex(0x6FA84A).fade(0.8));
  }

  /// Scene-level props in scene points. For butterflies and bubbles `rotation`
  /// is read as an animation phase (wing beat, wobble) rather than a spin.
  static void drawProp(SceneProp prop, GContext ctx, Offset point, double scale, bool dark) {
    if (!(prop.opacity > 0.01)) return;
    final g = ctx.copy()
      ..opacity = Ease.clamp(prop.opacity)
      ..translateBy(point.dx, point.dy)
      ..scaleBy(scale * prop.scale, scale * prop.scale);
    switch (prop.kind) {
      case ScenePropKind.ball:
        ItemRenderer.ball(g, 6.5, prop.rotation);
      case ScenePropKind.orb:
        orb(g, prop.rotation);
      case ScenePropKind.clap:
        draw(Effect(EffectKind.clap), g, unitX: 1, unitY: 1, dark: dark);
      case ScenePropKind.confetti:
        g.rotate(prop.rotation);
        final color = ConfettiPalette.colors[prop.variant.abs() % ConfettiPalette.colors.length];
        g.fill(Shapes.roundedRect(const Rect.fromLTWH(-3, -1.6, 6, 3.2), 0.8), color);
      case ScenePropKind.sparkle:
        g.rotate(prop.rotation);
        g.fill(Shapes.sparkle(Offset.zero, 6), hex(0xFFD166));
        g.fill(Shapes.sparkle(Offset.zero, 2.6), hex(0xFFF6D0));
      case ScenePropKind.butterfly:
        g.rotate(0.18 * math.sin(prop.rotation * 3));
        butterfly(g, prop.rotation * 12, prop.variant, tiny: false);
      case ScenePropKind.yarn:
        ItemRenderer.yarn(g, 7, prop.rotation);
      case ScenePropKind.leaf:
        g.rotate(prop.rotation);
        leaf(g, prop.variant);
      case ScenePropKind.dust:
        dust(g, 0, dark: dark, tiny: false, flip: prop.variant.remainder(2) == 0);
      case ScenePropKind.bubble:
        soapBubble(g, prop.rotation, tiny: false);
      case ScenePropKind.treat:
        ItemRenderer.cookie(g, 10, spin: prop.rotation);
      case ScenePropKind.crumb:
        g.rotate(prop.rotation);
        ItemRenderer.crumb(g, prop.variant, 1.3);
    }
  }

  static void leaf(GContext g, int variant) {
    const colors = [(0x8ED07A, 0x4F9A45), (0xFFB463, 0xC9772E), (0xF2865E, 0xB9502E)];
    final (fill, edge) = colors[variant.abs() % colors.length];
    final path = Path()
      ..moveTo(0, -6)
      ..quadTo(const Offset(0, 6), const Offset(6, 0))
      ..quadTo(const Offset(0, -6), const Offset(-6, 0))
      ..close();
    g.fill(path, hex(fill));
    g.stroke(path, hex(edge), 0.8);
    g.stroke(Shapes.line(const Offset(0, -4.5), const Offset(0, 7.5)), hex(edge), 0.7);
  }

  // MARK: Glyphs Swift draws with fonts or SF Symbols

  /// "♪" (eighth note) or "♫" (beamed pair) as paths, sized like a 13 pt glyph centred on the origin.
  static void musicNote(GContext g, bool single, Color color) {
    void head(Offset center) {
      final h = g.copy()
        ..translateBy(center.dx, center.dy)
        ..rotate(-0.38);
      h.fill(Shapes.ellipse(Offset.zero, 4.6, 3.4), color);
    }

    if (single) {
      head(const Offset(-1.6, 3.6));
      g.fill(Shapes.rect(const Rect.fromLTWH(0.15, -6.2, 1.2, 9.6)), color);
      final flag = Path()
        ..moveTo(1.35, -6.2)
        ..curveTo(const Offset(3.6, 0.6), const Offset(1.9, -3.4), const Offset(5.2, -2.6))
        ..curveTo(const Offset(1.35, -3.6), const Offset(4.4, -1.6), const Offset(2.6, -3.2))
        ..close();
      g.fill(flag, color);
    } else {
      head(const Offset(-3.6, 4.2));
      head(const Offset(2.8, 2.8));
      g.fill(Shapes.rect(const Rect.fromLTWH(-1.85, -4.6, 1.15, 8.6)), color);
      g.fill(Shapes.rect(const Rect.fromLTWH(4.55, -6.0, 1.15, 8.6)), color);
      final beam = Path()
        ..moveTo(-1.85, -4.6)
        ..lineTo(5.7, -6.0)
        ..lineTo(5.7, -3.9)
        ..lineTo(-1.85, -2.5)
        ..close();
      g.fill(beam, color);
    }
  }

  /// SF Symbol `lock.fill` in `rect`.
  static void lockSymbol(GContext g, Rect rect, Color color) {
    final w = rect.width;
    final h = rect.height;
    final body = Shapes.roundedRect(Rect.fromLTWH(rect.left, rect.top + h * 0.44, w, h * 0.56), w * 0.16);
    g.fill(body, color);
    final shackle = Path()
      ..moveTo(rect.left + w * 0.24, rect.top + h * 0.46)
      ..lineTo(rect.left + w * 0.24, rect.top + h * 0.3)
      ..arc(Offset(rect.center.dx, rect.top + h * 0.3), w * 0.26, math.pi, 2 * math.pi)
      ..lineTo(rect.right - w * 0.24, rect.top + h * 0.46);
    g.stroke(shackle, color, w * 0.15, cap: StrokeCap.butt);
  }

  /// SF Symbol `antenna.radiowaves.left.and.right.slash` in `rect`.
  static void offlineSymbol(GContext g, Rect rect, Color color) {
    final c = rect.center;
    final w = rect.width;
    final line = w * 0.085;
    g.fill(Shapes.ellipse(c, w * 0.17, w * 0.17), color);
    for (final side in const [-1.0, 1.0]) {
      for (final r in [w * 0.22, w * 0.4]) {
        final arc = Path()..arc(c, r, side < 0 ? degrees(140) : degrees(-40), side < 0 ? degrees(220) : degrees(40));
        g.stroke(arc, color, line);
      }
    }
    g.stroke(Shapes.line(Offset(rect.left + w * 0.1, rect.top), Offset(rect.right - w * 0.1, rect.bottom)), color, line * 1.1);
  }
}
