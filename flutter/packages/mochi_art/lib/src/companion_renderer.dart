// Port of Sources/App/Rendering/CompanionRenderer.swift.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'drawing.dart';
import 'item_renderer.dart';
import 'model/ease.dart';
import 'model/poses.dart';
import 'model/world.dart';
import 'palettes.dart';
import 'pixel_mascot.dart';

/// Draws the companion's workstation: the Claude Code mascot ([PixelMascot]) standing on the
/// desk beside a small laptop whose screen shows what kind of work it is doing.
/// Local units: origin on the floor below the workstation, y up is negative.
abstract final class CompanionRenderer {
  static const double unit = 54;

  /// One art pixel of the mascot, in local units.
  static const double pixel = 2.5;
  static const double deskTop = -22.5;

  /// The mascot's spot on the desk, and the laptop's (towards the pet).
  static const double homeX = 14;
  static const double laptopX = -36;

  /// `origin` is the workstation (desk and laptop stay there); `offsetX` moves only the mascot,
  /// in points. Without a workstation the mascot stands on the floor at `origin`.
  /// `deskFront` draws the desk (e.g. `ThemeRenderer.deskFront`) in the workstation's units.
  static void draw(
    CompanionPose pose,
    GContext context,
    Offset origin,
    double scale, {
    double offsetX = 0,
    Accessory? accessory,
    bool dark = false,
    double time = 0,
    double speed = 0,
    bool reduced = false,
    bool workstation = true,
    void Function(GContext desk)? deskFront,
  }) {
    final base = context.copy()
      ..translateBy(origin.dx, origin.dy)
      ..scaleBy(scale, scale);

    final x = (workstation ? homeX : 0) + offsetX / scale;
    final floor = workstation ? support(x) : 0.0;
    if (workstation) {
      deskFront?.call(base);
      drawLaptop(pose, base, time);
    }
    final options = MascotOptions(accessory: accessory, laptopOnLeft: workstation, reduced: reduced, speed: speed / (pixel * scale));
    PixelMascot.draw(pose, base, Offset(x, -floor), pixel, time, options);

    if (pose.opacity > 0.01 && pose.effects.isNotEmpty) {
      final effects = base.copy()
        ..opacity = pose.opacity
        // Marks are authored around the floor below the desk; follow the mascot down when it hops off.
        ..translateBy(x, -pose.y * unit + (workstation ? -deskTop - floor : -deskTop));
      for (final effect in pose.effects) {
        EffectRenderer.draw(effect, effects, unitX: 60, unitY: unit, dark: dark);
      }
    }
  }

  /// What of [time] shows in [draw] (the screen's blinking cursor, the mascot's legs and spinner), for the same
  /// arguments: two times with the same key draw the same picture of the same pose, so a picture can be reused.
  static String timeKey(
    CompanionPose pose,
    double time, {
    double scale = 1,
    double speed = 0,
    Accessory? accessory,
    bool reduced = false,
    bool workstation = true,
  }) {
    final options = MascotOptions(accessory: accessory, laptopOnLeft: workstation, reduced: reduced, speed: speed / (pixel * scale));
    final cursor = workstation && pose.laptop.visible && pose.laptop.screen == LaptopScreen.idle ? cursorShown(time) : true;
    return '${cursor ? 1 : 0};${PixelMascot.timeKey(pose, time, options)}';
  }

  /// The idle screen's cursor blinks: shown for 0.6 s, hidden for 0.6 s.
  static bool cursorShown(double time) => (time / 0.6).floor() % 2 == 0;

  /// How high the mascot's feet are above the floor at local x: on the desk at home, hopping
  /// down past its right end (the only way it leaves) and back up on the way home.
  static double support(double x) {
    const top = -deskTop;
    const edge = 50.0;
    const landing = 64.0;
    if (x <= edge) return top;
    if (x >= landing) return 0;
    final u = (x - edge) / (landing - edge);
    return top * (1 - u * u) + 6 * Ease.hop(u);
  }

  // MARK: Laptop

  static void drawLaptop(CompanionPose pose, GContext ctx, double time) {
    if (!pose.laptop.visible) return;
    final open = Ease.clamp(pose.laptop.openness);
    const cx = laptopX;
    const top = deskTop;
    final deck = Path()
      ..moveTo(cx - 15, top - 3)
      ..lineTo(cx + 15, top - 3)
      ..lineTo(cx + 17.5, top)
      ..lineTo(cx - 17.5, top)
      ..close();
    ctx.fill(deck, CompanionPalette.laptop);
    ctx.stroke(deck, CompanionPalette.laptopDark, 0.8);
    ctx.fill(Shapes.rect(const Rect.fromLTWH(cx - 11, top - 2.1, 22, 1)), CompanionPalette.laptopDark.fade(0.55));
    if (open <= 0.08) {
      final lid = Shapes.roundedRect(const Rect.fromLTWH(cx - 15, top - 4.6, 30, 1.8), 0.9);
      ctx.fill(lid, hex(0x3A3542));
      return;
    }
    final height = 20 * open;
    final lid = Rect.fromLTWH(cx - 14, top - 3 - height, 28, height);
    ctx.fill(Shapes.roundedRect(lid, 2), hex(0x2B2733));
    final display = lid.deflate(1.6);
    if (display.height <= 2) return;
    drawScreen(pose, ctx, display, time);
  }

  static void drawScreen(CompanionPose pose, GContext ctx, Rect rect, double time) {
    final screen = pose.laptop.screen;
    final shape = Shapes.roundedRect(rect, 1);
    if (screen == LaptopScreen.off) {
      ctx.fill(shape, hex(0x15131A));
      return;
    }
    ctx.fill(shape, hex(0x1B1824));
    final content = ctx.copy()..clip(shape);
    final scroll = pose.laptop.scroll;
    final tint = switch (screen) {
      LaptopScreen.error => hex(0xFF8A7A),
      LaptopScreen.celebrate => hex(0xFFD166),
      _ => hex(0x7FE3CB),
    };
    switch (screen) {
      case LaptopScreen.code || LaptopScreen.error:
        final colors = screen == LaptopScreen.error
            ? [hex(0xFF8A7A), hex(0xFFC2B8), hex(0xFF8A7A)]
            : [hex(0x7FE3CB), hex(0xFFD166), hex(0xB9A7FF), hex(0xFF9FB2)];
        for (var row = 0; row < 6; row++) {
          final y = rect.top + 2 + row * 2.8 - _remainder(scroll * 5, 2.8);
          final indent = ((row * 7) % 3) * 2.4;
          final width = (6 + (row * 13) % 11).toDouble();
          content.fill(
            Shapes.roundedRect(Rect.fromLTWH(rect.left + 2 + indent, y, width, 1.3), 0.6),
            colors[row % colors.length].fade(0.9),
          );
        }
        if (screen == LaptopScreen.error) {
          warning(content, Offset(rect.right - 4.5, rect.top + 4.5), 6, tint);
        }
      case LaptopScreen.terminal:
        for (var row = 0; row < 4; row++) {
          final y = rect.top + 2.5 + row * 3.2;
          prompt(content, Offset(rect.left + 3, y + 0.6), 2.4, tint);
          final width = (5 + ((row + (scroll * 2).truncate()) * 11) % 12).toDouble();
          content.fill(Shapes.roundedRect(Rect.fromLTWH(rect.left + 5.5, y, width, 1.3), 0.6), tint.fade(0.8));
        }
      case LaptopScreen.web:
        final center = rect.center;
        content.stroke(Shapes.ellipse(center, 11, 11), tint, 0.8);
        content.stroke(Shapes.ellipse(center, 4 + 2.5 * math.sin(scroll), 11), tint.fade(0.8), 0.7);
        content.stroke(Shapes.line(Offset(center.dx - 5.5, center.dy), Offset(center.dx + 5.5, center.dy)), tint.fade(0.8), 0.7);
      case LaptopScreen.search:
        final lens = Offset(rect.left + 5.5 + 2.5 * math.sin(scroll * 2), rect.top + 6);
        content.stroke(Shapes.ellipse(lens, 5, 5), tint, 1);
        content.stroke(Shapes.line(Offset(lens.dx + 1.8, lens.dy + 1.8), Offset(lens.dx + 4, lens.dy + 4)), tint, 1.2);
        for (var row = 0; row < 3; row++) {
          content.fill(
            Shapes.roundedRect(Rect.fromLTWH(rect.left + 12, rect.top + 3.5 + row * 3.6, 10, 1.4), 0.7),
            tint.fade(row == 1 ? 1 : 0.5),
          );
        }
      case LaptopScreen.docs:
        final page = Rect.fromLTWH(rect.center.dx - 5, rect.top + 1.5, 10, rect.height - 3);
        content.fill(Shapes.roundedRect(page, 1), white.fade(0.85));
        for (var row = 0; row < 4; row++) {
          content.fill(
            Shapes.rect(Rect.fromLTWH(page.left + 1.5, page.top + 2 + row * 2.6, (7 - row % 2 * 2).toDouble(), 0.9)),
            hex(0x5D5470),
          );
        }
      case LaptopScreen.celebrate:
        for (var index = 0; index < 4; index++) {
          final angle = index * 1.6 + scroll * 2;
          content.fill(Shapes.sparkle(Offset(rect.center.dx + math.cos(angle) * 7, rect.center.dy + math.sin(angle) * 4), 2.6), tint);
        }
      case LaptopScreen.idle:
        // Claude Code's prompt, waiting; amber with a question while Claude waits for you.
        final waiting = pose.antennaTint == AntennaTint.attention;
        final color = waiting ? CompanionPalette.antenna(AntennaTint.attention) : hex(0xF2E6D8);
        prompt(content, Offset(rect.left + 3.2, rect.top + 3.4), 2.8, color.fade(0.85));
        if (waiting) {
          question(content, Offset(rect.center.dx + 1, rect.center.dy + 0.5), 7, color);
        }
        if (cursorShown(time)) {
          content.fill(Shapes.rect(Rect.fromLTWH(rect.left + 5.6, rect.top + 2, 2, 2.8)), color.fade(0.8));
        }
      case LaptopScreen.off:
        break;
    }
    ctx.fillLinear(shape, [white.fade(0.08), white.fade(0)], rect.topLeft, Offset(rect.center.dx, rect.bottom));
  }

  /// Swift's `truncatingRemainder(dividingBy:)`.
  static double _remainder(double a, double b) => a.remainder(b);

  // Screen glyphs as paths.

  /// Claude Code's `>` prompt.
  static void prompt(GContext ctx, Offset center, double size, Color color) {
    final chevron = Path()
      ..moveTo(center.dx - size * 0.35, center.dy - size * 0.5)
      ..lineTo(center.dx + size * 0.35, center.dy)
      ..lineTo(center.dx - size * 0.35, center.dy + size * 0.5);
    ctx.stroke(chevron, color, math.max(0.7, size * 0.28));
  }

  static void question(GContext ctx, Offset center, double size, Color color) {
    final hook = Path()
      ..arc(Offset(center.dx, center.dy - size * 0.18), size * 0.22, degrees(200), degrees(70))
      ..lineTo(center.dx, center.dy + size * 0.16);
    ctx.stroke(hook, color, size * 0.14);
    ctx.fill(Shapes.ellipse(Offset(center.dx, center.dy + size * 0.4), size * 0.15, size * 0.15), color);
  }

  static void warning(GContext ctx, Offset center, double size, Color color) {
    final triangle = Path()
      ..moveTo(center.dx, center.dy - size * 0.5)
      ..lineTo(center.dx + size * 0.55, center.dy + size * 0.45)
      ..lineTo(center.dx - size * 0.55, center.dy + size * 0.45)
      ..close();
    ctx.fill(triangle, color);
    ctx.fill(Shapes.rect(Rect.fromLTWH(center.dx - size * 0.06, center.dy - size * 0.18, size * 0.12, size * 0.36)), hex(0x1B1824));
    ctx.fill(Shapes.rect(Rect.fromLTWH(center.dx - size * 0.06, center.dy + size * 0.24, size * 0.12, size * 0.1)), hex(0x1B1824));
  }
}
