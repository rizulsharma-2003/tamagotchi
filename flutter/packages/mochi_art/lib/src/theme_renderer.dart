// Port of Sources/App/Rendering/ThemeRenderer.swift.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'accessory_renderer.dart';
import 'drawing.dart';
import 'model/ease.dart';
import 'model/world.dart';

/// Lightweight procedural backdrops and desks for the tiny office.
abstract final class ThemeRenderer {
  static void background(OfficeTheme theme, GContext g, Size size, double ground, {bool dark = false, double time = 0, int hour = 14}) {
    final rect = Offset.zero & size;
    switch (theme) {
      case OfficeTheme.cozyDesk:
        cozy(g, rect, ground, dark, time, hour);
      case OfficeTheme.cyberpunk:
        cyber(g, rect, ground, dark, time);
      case OfficeTheme.spaceStation:
        space(g, rect, ground, dark, time);
      case OfficeTheme.gardenOffice:
        garden(g, rect, ground, dark, time);
    }
  }

  // MARK: Cozy desk

  static void cozy(GContext g, Rect r, double ground, bool dark, double time, int hour) {
    g.fillLinear(Shapes.rect(r), dark ? [hex(0x2E2523), hex(0x241D1B)] : [hex(0xFCF1E5), hex(0xF4DFCA)], Offset.zero, Offset(0, r.height));
    // Window with the real time of day.
    final window = Rect.fromLTWH(r.width * 0.07, r.height * 0.13, r.width * 0.2, r.height * 0.38);
    final night = hour < 7 || hour >= 19;
    final sky = night ? [hex(0x27335F), hex(0x3D4C7D)] : [hex(0xBFE0FF), hex(0xEAF5FF)];
    final pane = Shapes.roundedRect(window, 6);
    g.fillLinear(pane, sky, Offset(0, window.top), Offset(0, window.bottom));
    final inside = g.copy()..clip(pane);
    if (night) {
      inside.fill(Shapes.ellipse(Offset(window.right - 12, window.top + 12), 9, 9), hex(0xFFF1C9));
      inside.fill(Shapes.ellipse(Offset(window.right - 9, window.top + 10), 8, 8), hex(0x27335F));
      for (var index = 0; index < 5; index++) {
        final x = window.left + Ease.hash(index, 3) * window.width;
        final y = window.top + Ease.hash(index + 9, 3) * window.height * 0.7;
        inside.fill(Shapes.sparkle(Offset(x, y), 1.6 + math.sin(time * 2 + index) * 0.4), white.fade(0.8));
      }
    } else {
      final drift = Ease.fract(time / 80) * (window.width + 30) - 15;
      for (final (dx, w) in const [(0.0, 16.0), (8.0, 12.0), (-7.0, 11.0)]) {
        inside.fill(Shapes.ellipse(Offset(window.left + drift + dx, window.top + window.height * 0.4), w, w * 0.6), white.fade(0.9));
      }
    }
    g.stroke(pane, dark ? hex(0x54453E) : hex(0xE4CDB3), 3);
    g.stroke(
      Shapes.line(Offset(window.center.dx, window.top), Offset(window.center.dx, window.bottom)),
      dark ? hex(0x54453E) : hex(0xE4CDB3),
      2,
    );

    // A little framed heart.
    final frame = Rect.fromLTWH(r.width * 0.44, r.height * 0.16, 22, 18);
    g.fill(Shapes.roundedRect(frame, 2), dark ? hex(0x3B302C) : white);
    g.stroke(Shapes.roundedRect(frame, 2), dark ? hex(0x6A574E) : hex(0xD9B994), 2);
    g.fill(Shapes.heart(frame.center, 9), hex(0xFF8FA3));

    // Hanging lamp over the desk.
    final lampX = r.width * 0.8;
    g.stroke(Shapes.line(Offset(lampX, 0), Offset(lampX, r.height * 0.18)), dark ? hex(0x6A574E) : hex(0xC7A98A), 1.2);
    final lampGlow = Offset(lampX, r.height * 0.3);
    g.fillRadial(Shapes.ellipse(lampGlow, 110, 80), [hex(0xFFD38A).fade(dark ? 0.3 : 0.2), hex(0xFFD38A).fade(0)], lampGlow, 4, 52);
    final shade = Path()
      ..moveTo(lampX - 11, r.height * 0.24)
      ..lineTo(lampX - 5, r.height * 0.17)
      ..lineTo(lampX + 5, r.height * 0.17)
      ..lineTo(lampX + 11, r.height * 0.24)
      ..close();
    g.fill(shade, hex(0xF0A36B));

    final floor = Rect.fromLTWH(0, ground, r.width, r.height - ground);
    g.fill(Shapes.rect(floor), dark ? hex(0x3B2F2A) : hex(0xE9CBA7));
    for (var index = 0; index < 6; index++) {
      final x = index * r.width / 5 + 18;
      g.stroke(Shapes.line(Offset(x, ground), Offset(x - 10, r.height)), (dark ? black : hex(0xC9A47F)).fade(0.25), 1);
    }
    g.fill(Shapes.rect(Rect.fromLTWH(0, ground - 1, r.width, 2)), dark ? hex(0x4D3E37) : hex(0xDDBA93));
  }

  // MARK: Cyberpunk

  static void cyber(GContext g, Rect r, double ground, bool dark, double time) {
    g.fillLinear(Shapes.rect(r), dark ? [hex(0x1A1338), hex(0x0D0A1F)] : [hex(0x2E2458), hex(0x181232)], Offset.zero, Offset(0, ground));
    for (var index = 0; index < 11; index++) {
      final width = 18 + Ease.hash(index, 5) * 22;
      final height = r.height * (0.22 + Ease.hash(index + 30, 5) * 0.4);
      final x = index * r.width / 10 - 10;
      final building = Rect.fromLTWH(x, ground - height, width, height);
      g.fill(Shapes.rect(building), hex(0x261D4D));
      for (var window = 0; window < 6; window++) {
        final lit = Ease.hash(index * 10 + window, (time / 4).truncate()) > 0.55;
        if (!lit) continue;
        final wx = building.left + 4 + (window % 2) * (width / 2);
        final wy = building.top + 6 + (window ~/ 2) * 9;
        g.fill(Shapes.rect(Rect.fromLTWH(wx, wy, 3, 3)), hex(window % 3 == 0 ? 0xFF6FD8 : 0x67E8F9).fade(0.75));
      }
    }
    final neon = g;
    final pulse = 0.75 + 0.25 * math.sin(time * 2.4);
    final heart = Shapes.heart(Offset(r.width * 0.46, r.height * 0.26), 20);
    neon.stroke(heart, hex(0xFF6FD8).fade(0.25 * pulse), 6);
    neon.stroke(heart, hex(0xFF6FD8).fade(pulse), 2);
    final sign = Rect.fromLTWH(r.width * 0.06, r.height * 0.12, 42, 14);
    neon.stroke(Shapes.roundedRect(sign, 4), hex(0x67E8F9).fade(pulse), 1.6);
    const signColors = [0xFF6FD8, 0xFFD166, 0x67E8F9];
    const signWidths = [9.0, 6.0, 11.0];
    for (var index = 0; index < 3; index++) {
      neon.fill(
        Shapes.roundedRect(Rect.fromLTWH(sign.left + 5 + index * 12, sign.center.dy - 1.2, signWidths[index], 2.4), 1.2),
        hex(signColors[index]).fade(pulse),
      );
    }

    final floor = Rect.fromLTWH(0, ground, r.width, r.height - ground);
    g.fill(Shapes.rect(floor), hex(0x120D26));
    final grid = g.copy()..clip(Shapes.rect(floor));
    final vanishing = Offset(r.width / 2, ground - 40);
    for (var index = -8; index <= 8; index++) {
      grid.stroke(
        Shapes.line(Offset(vanishing.dx + index * 8, ground), Offset(vanishing.dx + index * 60, r.height)),
        hex(0xFF6FD8).fade(0.35),
        0.8,
      );
    }
    for (var index = 0; index < 4; index++) {
      final p = Ease.fract(index / 4 + time / 6);
      final y = ground + p * p * (r.height - ground);
      grid.stroke(Shapes.line(Offset(0, y), Offset(r.width, y)), hex(0x67E8F9).fade(0.3), 0.8);
    }
  }

  // MARK: Space station

  static void space(GContext g, Rect r, double ground, bool dark, double time) {
    final wall = dark ? [hex(0x1C2238), hex(0x141A2E)] : [hex(0xE9EDF5), hex(0xD6DCE8)];
    g.fillLinear(Shapes.rect(r), wall, Offset.zero, Offset(0, ground));
    for (var index = 0; index < 4; index++) {
      final x = index * r.width / 3.5;
      g.fill(Shapes.rect(Rect.fromLTWH(x, 0, 1.5, ground)), (dark ? white : hex(0x9AA4BC)).fade(0.12));
    }
    final center = Offset(r.width * 0.2, r.height * 0.36);
    final radius = math.min(r.height * 0.27, 40.0);
    final porthole = Shapes.ellipse(center, radius * 2, radius * 2);
    g.fill(porthole, hex(0x070B1D));
    final view = g.copy()..clip(porthole);
    for (var index = 0; index < 16; index++) {
      final x = center.dx - radius + Ease.hash(index, 7) * radius * 2;
      final y = center.dy - radius + Ease.hash(index + 50, 7) * radius * 2;
      final twinkle = 0.5 + 0.5 * math.sin(time * 1.5 + index);
      view.fill(Shapes.ellipse(Offset(x, y), 1.6, 1.6), white.fade(0.4 + 0.5 * twinkle));
    }
    final planet = Offset(center.dx + radius * 0.35, center.dy + radius * 0.3);
    view.fillLinear(
      Shapes.ellipse(planet, radius * 0.9, radius * 0.9),
      [hex(0x9C8CFF), hex(0x5E4FC9)],
      planet - const Offset(10, 10),
      planet,
    );
    final ring = view.copy()
      ..translateBy(planet.dx, planet.dy)
      ..rotate(degrees(-18));
    ring.stroke(Shapes.ellipse(Offset.zero, radius * 1.5, radius * 0.4), hex(0xFFD166).fade(0.8), 1.4);
    g.stroke(porthole, dark ? hex(0x495272) : hex(0xAAB3C8), 4);
    for (var index = 0; index < 8; index++) {
      final angle = index * math.pi / 4;
      g.fill(
        Shapes.ellipse(Offset(center.dx + math.cos(angle) * (radius + 0.5), center.dy + math.sin(angle) * (radius + 0.5)), 2.4, 2.4),
        dark ? hex(0x7B85A6) : hex(0x8792AD),
      );
    }
    final blink = math.sin(time * 3) > 0 ? 1.0 : 0.35;
    g.fill(Shapes.ellipse(Offset(r.width * 0.5, r.height * 0.18), 5, 5), hex(0x7FE3CB).fade(blink));
    g.fill(Shapes.ellipse(Offset(r.width * 0.53, r.height * 0.18), 5, 5), hex(0xFFB24A).fade(1.35 - blink));

    final floor = Rect.fromLTWH(0, ground, r.width, r.height - ground);
    g.fill(Shapes.rect(floor), dark ? hex(0x2A3150) : hex(0xC3CADB));
    for (var index = 0; index < 8; index++) {
      g.fill(Shapes.rect(Rect.fromLTWH(index * r.width / 7, ground, 1, r.height - ground)), black.fade(0.12));
    }
  }

  // MARK: Garden office

  static void garden(GContext g, Rect r, double ground, bool dark, double time) {
    final sky = dark ? [hex(0x1C2C24), hex(0x15211B)] : [hex(0xEAF7E4), hex(0xD4EECB)];
    g.fillLinear(Shapes.rect(r), sky, Offset.zero, Offset(0, ground));
    for (var index = 0; index < 7; index++) {
      final x = index * r.width / 6;
      g.fill(Shapes.ellipse(Offset(x, ground - 6), 64, 44), (dark ? hex(0x2B4535) : hex(0xB5DFA6)).fade(0.9));
    }
    // Vines from the top.
    for (var index = 0; index < 5; index++) {
      final x = r.width * (0.1 + index * 0.2);
      final length = r.height * (0.2 + Ease.hash(index, 9) * 0.18);
      final vine = Path()
        ..moveTo(x, 0)
        ..quadraticBezierTo(x - 8, length / 2, x + 6, length);
      g.stroke(vine, dark ? hex(0x3F6A4C) : hex(0x7CBF6A), 1.4);
      for (var leaf = 0; leaf < 3; leaf++) {
        final t = (leaf + 1) / 4;
        final l = g.copy()
          ..translateBy(x - 2 + t * 6, length * t)
          ..rotate(leaf.isEven ? 0.7 : -0.7);
        l.fill(Shapes.ellipse(Offset.zero, 5, 9), dark ? hex(0x4D8A5E) : hex(0x8ED07A));
      }
    }
    if (dark) {
      for (var index = 0; index < 6; index++) {
        final phase = time * 0.6 + index * 1.7;
        final x = r.width * Ease.hash(index, 4) + math.sin(phase) * 10;
        final y = r.height * (0.25 + 0.4 * Ease.hash(index + 4, 4)) + math.cos(phase * 1.3) * 6;
        final point = Offset(x, y);
        final alpha = 0.5 + 0.4 * math.sin(phase * 3);
        g.fillRadial(Shapes.ellipse(point, 10, 10), [hex(0xE9FF9E).fade(alpha), hex(0xE9FF9E).fade(0)], point, 0.5, 5);
      }
    }
    final floor = Rect.fromLTWH(0, ground, r.width, r.height - ground);
    g.fill(Shapes.rect(floor), dark ? hex(0x2E4A35) : hex(0xA6D893));
    for (var index = 0; index < 14; index++) {
      final x = index * r.width / 13 + 4;
      final tuft = Path()
        ..moveTo(x - 3, ground + 2)
        ..lineTo(x, ground - 4)
        ..lineTo(x + 3, ground + 2);
      g.stroke(tuft, dark ? hex(0x3F6A4C) : hex(0x7CBF6A), 1.2);
      if (index % 4 == 1) {
        g.fill(Shapes.ellipse(Offset(x + 6, ground + 8), 4, 4), hex(index % 8 == 1 ? 0xFF8FB1 : 0xFFD166));
      }
    }
  }

  // MARK: Desks (companion local units: desk top at y -21)

  static void deskFront(OfficeTheme theme, GContext g, {bool dark = false, Accessory? accessory}) {
    final (top, front, edge) = switch (theme) {
      OfficeTheme.cozyDesk => (hex(0xDCA472), hex(0xBA8053), hex(0x95633F)),
      OfficeTheme.cyberpunk => (hex(0x3A3460), hex(0x272246), hex(0x67E8F9)),
      OfficeTheme.spaceStation => (hex(0xF4F6FA), hex(0xD9DEE8), hex(0x9AA4BC)),
      OfficeTheme.gardenOffice => (hex(0xE8C796), hex(0xCFA770), hex(0xA9824F)),
    };
    // Wide enough for the mascot, its laptop and one decoration (see CompanionRenderer).
    g.fill(Shapes.ellipse(const Offset(1, 1.5), 126, 8), black.fade(dark ? 0.3 : 0.12));
    const frontRect = Rect.fromLTWH(-56, -18, 114, 18);
    g.fill(Shapes.roundedRect(frontRect, 3), front);
    g.stroke(Shapes.roundedRect(const Rect.fromLTWH(20, -14, 30, 10), 2), edge.fade(0.6), 1);
    g.fill(Shapes.ellipse(const Offset(35, -9), 3, 3), edge);
    g.stroke(Shapes.roundedRect(const Rect.fromLTWH(-50, -14, 30, 10), 2), edge.fade(0.6), 1);
    g.fill(Shapes.ellipse(const Offset(-35, -9), 3, 3), edge);
    const topRect = Rect.fromLTWH(-60, -22.5, 122, 5);
    g.fill(Shapes.roundedRect(topRect, 2.5), top);
    if (theme == OfficeTheme.cyberpunk) {
      g.fill(Shapes.rect(const Rect.fromLTWH(-59, -19.2, 120, 3)), edge.fade(0.25));
      g.fill(Shapes.rect(const Rect.fromLTWH(-59, -18.2, 120, 1)), edge);
    } else if (theme == OfficeTheme.spaceStation) {
      g.fill(Shapes.ellipse(const Offset(0, -9), 4, 4), hex(0x7FE3CB));
    } else {
      g.stroke(Shapes.roundedRect(topRect, 2.5), edge.fade(0.5), 0.8);
    }
    if (accessory != null && accessory.slot == AccessorySlot.desk) {
      AccessoryRenderer.desk(accessory, g);
    }
  }
}
