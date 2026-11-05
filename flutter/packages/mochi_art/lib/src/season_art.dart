// Port of Sources/App/Features/Seasons/SeasonArt.swift: holiday decorations for the room.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'drawing.dart';
import 'model/ease.dart';
import 'model/world.dart';
import 'scene_layout.dart';
import 'season_decor.dart';

/// Geometry and mood of the room being decorated (`SeasonArt.Scene`).
class SeasonScene {
  const SeasonScene({required this.layout, required this.dark, required this.theme, required this.time, required this.reduced});

  final SceneLayout layout;

  /// A dark wall (dark mode, or the always-dark cyberpunk city).
  final bool dark;
  final OfficeTheme theme;
  final double time;
  final bool reduced;

  double get w => layout.size.width;
  double get h => layout.size.height;
  double get s => layout.scale;
  double get ground => layout.ground;

  /// The window or porthole of the theme, if it has one (matches ThemeRenderer).
  Path? get window => switch (theme) {
    OfficeTheme.cozyDesk => Shapes.roundedRect(Rect.fromLTWH(w * 0.07, h * 0.13, w * 0.2, h * 0.38), 6),
    OfficeTheme.spaceStation => () {
      final radius = math.min(h * 0.27, 40.0);
      return Shapes.ellipse(Offset(w * 0.2, h * 0.36), radius * 2, radius * 2);
    }(),
    OfficeTheme.cyberpunk || OfficeTheme.gardenOffice => null,
  };

  /// Where the faces usually are, so particles in front fade out around them.
  List<(Offset, double)> get faces => [
    (Offset(layout.petHome, ground - 32 * s), 40 * s),
    (Offset(layout.companionHome, ground - 62 * s), 38 * s),
  ];

  /// 0 over a face, 1 well away from it.
  double faceClearance(Offset p) {
    var value = 1.0;
    for (final (center, radius) in faces) {
      final distance = (p - center).distance;
      value = math.min(value, Ease.smooth((distance - radius) / (16 * s)));
    }
    return value;
  }
}

abstract final class SeasonArt {
  static void room(
    SeasonalEvent event,
    GContext g,
    SceneLayout layout, {
    bool dark = false,
    double time = 0,
    OfficeTheme theme = OfficeTheme.cozyDesk,
    bool reduced = false,
  }) {
    final scene = SeasonScene(
      layout: layout,
      dark: dark || theme == OfficeTheme.cyberpunk,
      theme: theme,
      time: reduced ? 0.6 : time,
      reduced: reduced,
    );
    switch (event) {
      case SeasonalEvent.halloween:
        halloween(g, scene);
      case SeasonalEvent.diwali:
        diwali(g, scene);
      case SeasonalEvent.christmas:
        christmas(g, scene);
      case SeasonalEvent.newYear:
        newYear(g, scene);
      case SeasonalEvent.valentines:
        valentines(g, scene);
      case SeasonalEvent.userBirthday || SeasonalEvent.mochiBirthday:
        birthday(g, scene);
    }
  }

  static void foreground(SeasonalEvent event, GContext g, SceneLayout layout, {bool dark = false, double time = 0}) {
    final theme = SeasonRenderContext.theme;
    final scene = SeasonScene(layout: layout, dark: dark || theme == OfficeTheme.cyberpunk, theme: theme, time: time, reduced: false);
    switch (event) {
      case SeasonalEvent.christmas:
        snowfall(g, scene);
      case SeasonalEvent.newYear:
        fireworks(g, scene);
      case SeasonalEvent.diwali:
        floatingLights(g, scene);
      case SeasonalEvent.userBirthday || SeasonalEvent.mochiBirthday:
        confettiFall(g, scene);
      case SeasonalEvent.halloween || SeasonalEvent.valentines:
        break;
    }
  }

  // MARK: - Shared pieces

  /// A point on a garland hanging from `a` to `b` that sags by `sag` in the middle.
  static Offset swagPoint(Offset a, Offset b, double sag, double t) =>
      Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t + sag * 4 * t * (1 - t));

  static Path swagPath(Offset a, Offset b, double sag) => Path()
    ..moveToPoint(a)
    ..quadTo(b, Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2 + sag * 2));

  static void glow(GContext g, Offset p, double radius, Color color, double opacity) {
    if (opacity <= 0.01) return;
    g.fillRadial(Shapes.ellipse(p, radius * 2, radius * 2), [color.fade(opacity), color.fade(0)], p, 0, radius);
  }

  /// Candle flicker, 0.75…1.05, different per `phase`.
  static double flicker(double t, double phase) =>
      0.88 + 0.08 * math.sin(t * 9.3 + phase) + 0.05 * math.sin(t * 14.7 + phase * 2.3) + 0.04 * math.sin(t * 23.1 + phase * 0.7);

  /// A pennant flag hanging from `top`, with an optional letter.
  static void pennant(GContext g, Offset top, double width, double height, Color color, {String? letter, double sway = 0}) {
    final flag = g.copy()
      ..translateBy(top.dx, top.dy)
      ..rotate(sway);
    final path = Path()
      ..moveTo(-width / 2, 0)
      ..lineTo(width / 2, 0)
      ..lineTo(0, height)
      ..close();
    flag.fill(path, color);
    flag.fill(Shapes.rect(Rect.fromLTWH(-width / 2, 0, width, height * 0.12)), black.fade(0.08));
    if (letter != null && letter.isNotEmpty) {
      bunting(flag, letter.substring(0, 1), Offset(0, height * 0.36), width * 0.62, white);
    }
  }

  /// A heavy rounded capital or digit centred on `center` (`BuntingGlyphs`: Swift fills the
  /// glyph outline from SF Rounded Heavy; here the glyph is drawn as text and centred on its
  /// cap height).
  static void bunting(GContext g, String character, Offset center, double size, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: character,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w800,
          fontFamily: MochiArtText.family,
          fontVariations: MochiArtText.variableWeight ? const [FontVariation('wght', 800)] : null,
          color: g.opacity >= 1 ? color : color.fade(g.opacity),
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final baseline = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    // Capitals and digits are about 0.7 em tall: centre that box on the point.
    final origin = Offset(center.dx - painter.width / 2, center.dy + 0.35 * size - baseline);
    g.raw((canvas) => painter.paint(canvas, origin));
    painter.dispose();
  }

  // MARK: - Halloween

  static void halloween(GContext g, SeasonScene sc) {
    final w = sc.w, h = sc.h, s = sc.s, ground = sc.ground, t = sc.time;
    // Dusk purple from the ceiling, pumpkin warmth along the floor.
    g.fillLinear(
      Shapes.rect(Offset.zero & sc.layout.size),
      [hex(0x4B2A7B).fade(sc.dark ? 0.24 : 0.13), hex(0x4B2A7B).fade(0), hex(0xFF8A2A).fade(0), hex(0xFF8A2A).fade(sc.dark ? 0.16 : 0.1)],
      Offset.zero,
      Offset(0, h),
      stops: const [0, 0.55, 0.72, 1],
    );

    bats(g, sc);
    cobweb(g, Offset(w, 0), 40 * s, sc.dark, t, sc.reduced);
    pumpkinLights(g, sc);

    // Jack-o'-lanterns in the corners and a bowl of candy between the friends.
    final floor = ground + 5 * s;
    jackOLantern(g, Offset(w * 0.052, floor), 27 * s, t, 0, sc.dark);
    jackOLantern(g, Offset(w * 0.118, floor + 3 * s), 17 * s, t, 2.1, sc.dark, face: 1);
    jackOLantern(g, Offset(w * 0.93, floor + 1 * s), 23 * s, t, 4.2, sc.dark, face: 2);
    candyBowl(g, Offset(w * 0.465, floor + 3 * s), 29 * s, sc.dark);
    ghost(g, Offset(w * 0.915, h * 0.47), 17 * s, t, sc.reduced, sc.dark);
  }

  /// A small, friendly ghost bobbing on the wall, with rosy cheeks.
  static void ghost(GContext g, Offset center, double size, double time, bool reduced, bool dark) {
    final bob = reduced ? 0.0 : math.sin(time * 1.3) * size * 0.12;
    final k = size / 20;
    final gh = g.copy()
      ..translateBy(center.dx, center.dy + bob)
      ..rotate(reduced ? 0 : math.sin(time * 0.9) * 0.06)
      ..scaleBy(k, k);
    glow(gh, Offset.zero, 18, hex(0xD9CCFF), dark ? 0.35 : 0.2);
    final body = Path()
      ..moveTo(-9, 9)
      ..lineTo(-9, -1)
      ..cubicTo(-9, -13.5, 9, -13.5, 9, -1)
      ..lineTo(9, 9);
    final wave = reduced ? 0.0 : math.sin(time * 4) * 0.8;
    for (var index = 0; index < 3; index++) {
      final x0 = 9 - index * 6.0;
      body
        ..quadraticBezierTo(x0 - 1.5, 11.5 + wave, x0 - 3, 8 + wave)
        ..quadraticBezierTo(x0 - 4.5, 5.5, x0 - 6, 9);
    }
    body.close();
    gh.fill(body, white.fade(0.94));
    gh.stroke(body, hex(0xB9AED0).fade(dark ? 0.5 : 0.9), 0.9);
    gh.fill(Shapes.ellipse(const Offset(-3.2, -2.5), 2.4, 3.2), hex(0x2C2234));
    gh.fill(Shapes.ellipse(const Offset(3.2, -2.5), 2.4, 3.2), hex(0x2C2234));
    gh.fill(Shapes.ellipse(const Offset(-2.8, -3.3), 0.9, 0.9), white);
    gh.fill(Shapes.ellipse(const Offset(3.6, -3.3), 0.9, 0.9), white);
    gh.fill(Shapes.ellipse(const Offset(0, 1.6), 2.4, 2), hex(0x2C2234));
    gh.fill(Shapes.ellipse(const Offset(-5.6, 0.6), 3, 1.8), hex(0xFF9FB2).fade(0.7));
    gh.fill(Shapes.ellipse(const Offset(5.6, 0.6), 3, 1.8), hex(0xFF9FB2).fade(0.7));
  }

  /// A string of little pumpkin lights along the top, warm and slowly breathing.
  static void pumpkinLights(GContext g, SeasonScene sc) {
    final w = sc.w, s = sc.s, t = sc.time;
    final anchors = [Offset(-6, 3 * s), Offset(w * 0.45, 5 * s), Offset(w * 0.87, 2 * s)];
    final wire = sc.dark ? hex(0x120C18) : hex(0x3A2E45);
    var index = 0;
    for (var i = 0; i + 1 < anchors.length; i++) {
      final a = anchors[i], b = anchors[i + 1];
      final sag = 13 * s;
      g.stroke(swagPath(a, b, sag), wire.fade(0.75), 0.9);
      for (var step = 1; step <= 6; step++) {
        final p = swagPoint(a, b, sag, step / 7);
        final pulse = 0.75 + 0.25 * math.sin(t * 1.6 + index * 1.3);
        final bulb = Offset(p.dx, p.dy + 4.5 * s);
        g.stroke(Shapes.line(p, bulb), wire.fade(0.75), 0.7);
        if (index % 3 == 1) {
          glow(g, bulb, 8 * s, hex(0xB98CFF), (sc.dark ? 0.5 : 0.3) * pulse);
          g.fill(Shapes.ellipse(bulb, 4.4 * s, 5 * s), hex(0xB98CFF));
          g.fill(Shapes.ellipse(Offset(bulb.dx - 0.8 * s, bulb.dy - 1 * s), 1.6 * s, 1.6 * s), white.fade(0.7));
        } else {
          glow(g, bulb, 9 * s, hex(0xFFAA45), (sc.dark ? 0.55 : 0.32) * pulse);
          miniPumpkin(g, bulb, 7.4 * s, lit: pulse);
        }
        index += 1;
      }
    }
    // A sleepy bat hangs from the wire when nothing flies.
    if (sc.reduced) {
      hangingBat(g, swagPoint(anchors[1], anchors[2], 13 * s, 0.5), 15 * s, sc.dark);
      hangingBat(g, swagPoint(anchors[0], anchors[1], 13 * s, 0.36), 12 * s, sc.dark);
    }
  }

  static void miniPumpkin(GContext g, Offset c, double wd, {double lit = 1}) {
    final h = wd * 0.8;
    for (final (dx, lw, color) in const [(-0.22, 0.6, 0xE8771F), (0.22, 0.6, 0xE8771F), (0.0, 0.62, 0xFF9C3F)]) {
      g.fill(Shapes.ellipse(Offset(c.dx + dx * wd, c.dy), lw * wd, h), hex(color));
    }
    g.fill(Shapes.ellipse(Offset(c.dx, c.dy + h * 0.05), wd * 0.3, h * 0.45), hex(0xFFE07A).fade(0.35 + 0.35 * lit));
    g.fill(Shapes.roundedRect(Rect.fromLTWH(c.dx - wd * 0.07, c.dy - h * 0.68, wd * 0.16, h * 0.3), wd * 0.05), hex(0x5E7F33));
  }

  /// A carved pumpkin with a candle inside: the face glows and flickers, light spills around it.
  static void jackOLantern(GContext g, Offset foot, double wd, double time, double phase, bool dark, {int face = 0}) {
    final h = wd * 0.76;
    final c = Offset(foot.dx, foot.dy - h / 2);
    final f = flicker(time, phase);
    glow(g, Offset(c.dx, c.dy - h * 0.15), wd * (1.45 + 0.1 * f), hex(0xFFB347), (dark ? 0.5 : 0.32) * f);
    g.fill(Shapes.ellipse(Offset(foot.dx, foot.dy - 0.5), wd * 1.05, wd * 0.18), black.fade(dark ? 0.32 : 0.15));
    const lobes = [(-0.27, 0.5, 0xE06F1C), (0.27, 0.5, 0xE06F1C), (-0.13, 0.56, 0xF5862A), (0.13, 0.56, 0xF5862A), (0.0, 0.52, 0xFF9C3F)];
    for (final (dx, lw, color) in lobes) {
      final lobe = Shapes.ellipse(Offset(c.dx + dx * wd, c.dy), lw * wd, h);
      g.fill(lobe, hex(color));
      g.stroke(lobe, hex(0xB0501A).fade(0.5), math.max(0.6, wd / 34));
    }
    g.fill(Shapes.ellipse(Offset(c.dx - wd * 0.2, c.dy - h * 0.26), wd * 0.16, h * 0.14), white.fade(0.28));
    final stem = Path()
      ..moveTo(c.dx - wd * 0.05, c.dy - h * 0.44)
      ..quadraticBezierTo(c.dx - wd * 0.04, c.dy - h * 0.62, c.dx + wd * 0.1, c.dy - h * 0.68);
    g.stroke(stem, hex(0x5E7F33), math.max(1.6, wd * 0.11));
    final curl = Path()
      ..moveTo(c.dx + wd * 0.04, c.dy - h * 0.5)
      ..quadraticBezierTo(c.dx + wd * 0.18, c.dy - h * 0.38, c.dx + wd * 0.24, c.dy - h * 0.56);
    g.stroke(curl, hex(0x7FA34A), math.max(0.6, wd * 0.03));

    // The carved face, lit from inside.
    final light = hex(0xFFE38A).fade(0.72 + 0.28 * f);
    final deep = hex(0xC4560E);
    final carved = Path();
    final eyeY = c.dy - h * 0.1;
    for (final side in const [-1.0, 1.0]) {
      final ex = c.dx + side * wd * 0.17;
      if (face == 1) {
        carved.addOval(Rect.fromLTWH(ex - wd * 0.06, eyeY - wd * 0.07, wd * 0.12, wd * 0.13));
      } else {
        carved
          ..moveTo(ex - wd * 0.08, eyeY + wd * 0.05)
          ..lineTo(ex + wd * 0.08, eyeY + wd * 0.05)
          ..lineTo(ex + (face == 2 ? side * 0.05 : 0) * wd, eyeY - wd * 0.08)
          ..close();
      }
    }
    carved
      ..moveTo(c.dx - wd * 0.035, c.dy + h * 0.05)
      ..lineTo(c.dx + wd * 0.035, c.dy + h * 0.05)
      ..lineTo(c.dx, c.dy - h * 0.03)
      ..close();
    final mouthY = c.dy + h * 0.15;
    carved
      ..moveTo(c.dx - wd * 0.26, mouthY - h * 0.04)
      ..quadraticBezierTo(c.dx, mouthY + h * 0.32, c.dx + wd * 0.26, mouthY - h * 0.04);
    if (face == 1) {
      carved.close();
    } else {
      // Two square teeth along the top of the grin.
      carved
        ..lineTo(c.dx + wd * 0.14, mouthY + h * 0.0)
        ..lineTo(c.dx + wd * 0.14, mouthY + h * 0.07)
        ..lineTo(c.dx + wd * 0.05, mouthY + h * 0.07)
        ..lineTo(c.dx + wd * 0.05, mouthY + h * 0.02)
        ..lineTo(c.dx - wd * 0.07, mouthY + h * 0.02)
        ..lineTo(c.dx - wd * 0.07, mouthY + h * 0.08)
        ..lineTo(c.dx - wd * 0.16, mouthY + h * 0.08)
        ..lineTo(c.dx - wd * 0.16, mouthY + h * 0.0)
        ..close();
    }
    g.fill(carved, light);
    g.stroke(carved, deep.fade(0.8), math.max(0.5, wd / 40));
  }

  static void candyBowl(GContext g, Offset foot, double wd, bool dark) {
    final rimY = foot.dy - wd * 0.42;
    g.fill(Shapes.ellipse(foot, wd * 0.9, wd * 0.14), black.fade(dark ? 0.3 : 0.13));
    // The heap of sweets behind the rim.
    const sweets = [
      (-0.27, -0.03, 0xFF8FA3, false),
      (0.26, -0.03, 0x7FD6C2, false),
      (-0.05, -0.2, 0xFFD166, true),
      (0.12, -0.14, 0xB98CFF, false),
      (-0.17, -0.13, 0xFF9C3F, true),
      (0.02, -0.04, 0xFF6B6B, false),
      (0.2, -0.24, 0xFF9C3F, true),
    ];
    for (final (dx, dy, color, corn) in sweets) {
      final p = Offset(foot.dx + dx * wd, rimY + dy * wd);
      if (corn) {
        candyCorn(g, p, wd * 0.24);
      } else {
        for (final side in const [-1.0, 1.0]) {
          final twist = Path()
            ..moveTo(p.dx + side * wd * 0.07, p.dy)
            ..lineTo(p.dx + side * wd * 0.15, p.dy - wd * 0.05)
            ..lineTo(p.dx + side * wd * 0.15, p.dy + wd * 0.05)
            ..close();
          g.fill(twist, hex(color).fade(0.85));
        }
        g.fill(Shapes.ellipse(p, wd * 0.17, wd * 0.14), hex(color));
        g.fill(Shapes.ellipse(Offset(p.dx - wd * 0.03, p.dy - wd * 0.025), wd * 0.06, wd * 0.04), white.fade(0.6));
      }
    }
    final bowl = Path()
      ..moveTo(foot.dx - wd / 2, rimY)
      ..quadraticBezierTo(foot.dx, foot.dy + wd * 0.3, foot.dx + wd / 2, rimY)
      ..close();
    g.fill(bowl, hex(0x5E3E9C));
    final band = g.copy()..clip(bowl);
    band.fill(Shapes.rect(Rect.fromLTWH(foot.dx - wd / 2, rimY + wd * 0.1, wd, wd * 0.07)), hex(0xFF9C3F));
    band.fill(Shapes.ellipse(Offset(foot.dx - wd * 0.2, rimY + wd * 0.06), wd * 0.12, wd * 0.05), white.fade(0.25));
    g.fill(Shapes.ellipse(Offset(foot.dx, rimY), wd, wd * 0.12), hex(0x7B55C4));
    g.fill(Shapes.roundedRect(Rect.fromLTWH(foot.dx - wd * 0.16, foot.dy - wd * 0.07, wd * 0.32, wd * 0.08), wd * 0.03), hex(0x4A2F80));
  }

  static void candyCorn(GContext g, Offset p, double size) {
    final corn = Path()
      ..moveTo(p.dx - size * 0.42, p.dy + size * 0.4)
      ..quadraticBezierTo(p.dx, p.dy + size * 0.55, p.dx + size * 0.42, p.dy + size * 0.4)
      ..lineTo(p.dx, p.dy - size * 0.5)
      ..close();
    final bands = g.copy()..clip(corn);
    bands.fill(Shapes.rect(Rect.fromLTWH(p.dx - size, p.dy - size, size * 2, size * 2)), hex(0xFFF6E5));
    bands.fill(Shapes.rect(Rect.fromLTWH(p.dx - size, p.dy - size * 0.18, size * 2, size * 2)), hex(0xFF9C3F));
    bands.fill(Shapes.rect(Rect.fromLTWH(p.dx - size, p.dy + size * 0.18, size * 2, size * 2)), hex(0xFFD166));
  }

  /// A few bats flutter across the top-left (past the window), every dozen seconds.
  static void bats(GContext g, SeasonScene sc) {
    if (sc.reduced) return;
    const cycle = 12.0;
    final local = Ease.fract(sc.time / cycle) * cycle;
    final ink = sc.dark ? hex(0x0E0914) : hex(0x2B2236);
    for (var index = 0; index < 3; index++) {
      final p = (local - index * 0.55) / 4.6;
      if (!(p > 0 && p < 1)) continue;
      final x = -14 + p * (sc.w * 0.62);
      final y = sc.h * (0.2 + 0.07 * index) + math.sin(p * math.pi * 3 + index) * 7 * sc.s - p * 10 * sc.s;
      final flap = math.sin(sc.time * 15 + index * 1.7);
      bat(g, Offset(x, y), (index == 1 ? 15 : 12) * sc.s, flap, ink);
    }
  }

  /// A little bat with yellow eyes; `flap` -1…1 moves the wings.
  static void bat(GContext g, Offset c, double span, double flap, Color color) {
    final b = g.copy()
      ..translateBy(c.dx, c.dy)
      ..scaleBy(span / 20, span / 20);
    final wings = Path();
    for (final side in const [-1.0, 1.0]) {
      wings
        ..moveTo(0, -1)
        ..quadraticBezierTo(side * 5, -6 - 3 * flap, side * 10, -2 - 5 * flap)
        ..quadraticBezierTo(side * 9.4, 1 - 3.5 * flap, side * 6.6, 1 - 2.4 * flap)
        ..quadraticBezierTo(side * 5.6, -0.2 - 1.4 * flap, side * 3.4, 1.6 - 1.2 * flap)
        ..quadraticBezierTo(side * 1.8, 0.4, 0, 2)
        ..close();
    }
    b.fill(wings, color);
    b.fill(Shapes.ellipse(const Offset(0, 0.6), 4.6, 6), color);
    final ears = Path()
      ..moveTo(-2.1, -1.8)
      ..lineTo(-1.5, -4.4)
      ..lineTo(-0.4, -2.3)
      ..moveTo(2.1, -1.8)
      ..lineTo(1.5, -4.4)
      ..lineTo(0.4, -2.3);
    b.fill(ears, color);
    b.fill(Shapes.ellipse(const Offset(-0.9, -0.4), 1.2, 1.2), hex(0xFFD166));
    b.fill(Shapes.ellipse(const Offset(0.9, -0.4), 1.2, 1.2), hex(0xFFD166));
  }

  /// A bat asleep upside down, wings folded.
  static void hangingBat(GContext g, Offset point, double span, bool dark) {
    final b = g.copy()
      ..translateBy(point.dx, point.dy + span * 0.32)
      ..rotate(math.pi);
    bat(b, Offset.zero, span, -0.9, dark ? hex(0x0E0914) : hex(0x2B2236));
  }

  /// A corner cobweb with a small spider bobbing on its thread.
  static void cobweb(GContext g, Offset corner, double length, bool dark, double time, bool reduced) {
    final ink = dark ? white.fade(0.32) : hex(0x6E6280).fade(0.45);
    const angles = [0.0, 0.4, 0.8, 1.17, 1.5707];
    final directions = angles.map((a) => Offset(-math.cos(a), math.sin(a))).toList();
    final web = Path();
    for (var index = 0; index < directions.length; index++) {
      final d = directions[index];
      final reach = length * (index == 0 || index == directions.length - 1 ? 0.95 : 1);
      web
        ..moveToPoint(corner)
        ..lineToPoint(corner + d * reach);
    }
    for (final ring in const [0.3, 0.55, 0.8]) {
      for (var i = 0; i + 1 < directions.length; i++) {
        final a = directions[i], b = directions[i + 1];
        final p1 = corner + a * (length * ring);
        final p2 = corner + b * (length * ring);
        final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
        web
          ..moveToPoint(p1)
          ..quadTo(p2, Offset(corner.dx + (mid.dx - corner.dx) * 0.82, corner.dy + (mid.dy - corner.dy) * 0.82));
      }
    }
    g.stroke(web, ink, 0.7);
    // The spider.
    final anchor = Offset(corner.dx - length * 0.42, corner.dy + length * 0.42);
    final drop = length * 0.5 + (reduced ? 0 : math.sin(time * 0.9) * length * 0.12);
    final spider = Offset(anchor.dx, anchor.dy + drop);
    g.stroke(Shapes.line(anchor, spider), ink, 0.6);
    final k = length / 40;
    final legs = Path();
    for (var index = 0; index < 4; index++) {
      final y = spider.dy - 1.2 * k + index * 1.1 * k;
      for (final side in const [-1.0, 1.0]) {
        legs
          ..moveTo(spider.dx + side * 1.2 * k, y)
          ..quadraticBezierTo(spider.dx + side * 3.4 * k, y - 1.8 * k, spider.dx + side * 4.4 * k, y + 1.6 * k);
      }
    }
    final body = dark ? hex(0x0E0914) : hex(0x2B2236);
    g.stroke(legs, body, 0.7 * k);
    g.fill(Shapes.ellipse(Offset(spider.dx, spider.dy + 0.8 * k), 4.4 * k, 5 * k), body);
    g.fill(Shapes.ellipse(Offset(spider.dx, spider.dy - 1.8 * k), 3 * k, 2.6 * k), body);
    g.fill(Shapes.ellipse(Offset(spider.dx - 0.7 * k, spider.dy - 1.9 * k), 1.1 * k, 1.1 * k), white);
    g.fill(Shapes.ellipse(Offset(spider.dx + 0.7 * k, spider.dy - 1.9 * k), 1.1 * k, 1.1 * k), white);
  }

  // MARK: - Diwali

  static final Color marigoldOrange = hex(0xF77F00);
  static final Color marigoldYellow = hex(0xFCBF49);

  static void diwali(GContext g, SeasonScene sc) {
    final w = sc.w, h = sc.h, s = sc.s, ground = sc.ground, t = sc.time;
    // A warm festive evening: deep indigo up high, golden lamp light along the floor.
    g.fillLinear(
      Shapes.rect(Offset.zero & sc.layout.size),
      [hex(0x3B1F6B).fade(sc.dark ? 0.2 : 0.08), hex(0x3B1F6B).fade(0), hex(0xFFB347).fade(0), hex(0xFFB347).fade(sc.dark ? 0.2 : 0.13)],
      Offset.zero,
      Offset(0, h),
      stops: const [0, 0.45, 0.62, 1],
    );

    fairyLights(g, sc);
    marigoldToran(g, sc);

    // Rangoli on the floor between the friends, with a diya at its heart.
    final rangoliCenter = Offset(w * 0.465, ground + 10 * s);
    rangoli(g, rangoliCenter, 31 * s);
    diya(g, Offset(rangoliCenter.dx, rangoliCenter.dy + 1.5 * s), 12 * s, t, 0.4, sc.dark);

    // Rows of diyas in the corners.
    final floor = ground + 7 * s;
    const xs = [0.035, 0.085, 0.89, 0.94, 0.985];
    for (var index = 0; index < xs.length; index++) {
      diya(g, Offset(w * xs[index], floor + (index % 2) * 3 * s), 12.5 * s, t, index * 1.9, sc.dark);
    }
  }

  /// Marigold garlands across the top, with strands hanging between the swags.
  static void marigoldToran(GContext g, SeasonScene sc) {
    final w = sc.w, s = sc.s;
    final orange = Path();
    final yellow = Path();
    final hearts = Path();
    final leaves = <(Offset, double)>[];
    final r = 3.3 * s;
    void flower(Offset p, int index) {
      final rect = Rect.fromLTWH(p.dx - r, p.dy - r, r * 2, r * 2);
      if (index.isEven) {
        orange.addOval(rect);
      } else {
        yellow.addOval(rect);
      }
      hearts.addOval(Rect.fromLTWH(p.dx - r * 0.32, p.dy - r * 0.32, r * 0.64, r * 0.64));
    }

    final joints = [const Offset(-4, -1), Offset(w / 3, -1), Offset(w * 2 / 3, -1), Offset(w + 4, -1)];
    var index = 0;
    for (var i = 0; i + 1 < joints.length; i++) {
      const count = 17;
      for (var step = 0; step <= count; step++) {
        flower(swagPoint(joints[i], joints[i + 1], 10 * s, step / count), index);
        index += 1;
      }
    }
    // Hanging strands at the inner joints, each ending in a mango leaf.
    for (final joint in joints.sublist(1, joints.length - 1)) {
      for (var step = 1; step <= 4; step++) {
        flower(Offset(joint.dx, joint.dy + step * r * 1.75 + r), step);
      }
      leaves
        ..add((Offset(joint.dx, joint.dy + r * 9.6), 0))
        ..add((Offset(joint.dx - r * 1.6, joint.dy + r * 1.4), 0.9))
        ..add((Offset(joint.dx + r * 1.6, joint.dy + r * 1.4), -0.9));
    }
    for (final (p, angle) in leaves) {
      final leaf = g.copy()
        ..translateBy(p.dx, p.dy)
        ..rotate(angle);
      leaf.fill(Shapes.ellipse(Offset(0, r * 0.9), r * 1.1, r * 2.6), hex(0x3E8E41));
      leaf.stroke(Shapes.line(Offset(0, -r * 0.3), Offset(0, r * 2)), hex(0x2C6B2F), 0.5);
    }
    g.fill(orange, marigoldOrange);
    g.fill(yellow, marigoldYellow);
    // Ruffled petals: a darker ring and a bright centre.
    g.stroke(orange, hex(0xC85A00).fade(0.7), 0.6);
    g.stroke(yellow, hex(0xE0962A).fade(0.7), 0.6);
    g.fill(hearts, hex(0xA34700).fade(0.75));
  }

  /// Twinkling fairy lights in warm colours, swagged below the garland.
  static void fairyLights(GContext g, SeasonScene sc) {
    final w = sc.w, s = sc.s, t = sc.time;
    const colors = [0xFFD166, 0xFF8FA3, 0x7FE3CB, 0xFFB347, 0xB9A7FF];
    final anchors = [for (var i = 0; i <= 4; i++) Offset(w * i / 4, 15 * s)];
    final wire = sc.dark ? hex(0x8A7A5A).fade(0.5) : hex(0x6E5A3A).fade(0.45);
    var index = 0;
    for (var i = 0; i + 1 < anchors.length; i++) {
      final a = anchors[i], b = anchors[i + 1];
      g.stroke(swagPath(a, b, 11 * s), wire, 0.7);
      for (var step = 1; step <= 8; step++) {
        final p = swagPoint(a, b, 11 * s, step / 9);
        final twinkle = sc.reduced ? 0.85 : 0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * 2.3 + index * 1.7));
        final color = hex(colors[index % colors.length]);
        glow(g, Offset(p.dx, p.dy + 2 * s), 6 * s, color, (sc.dark ? 0.6 : 0.4) * twinkle);
        g.fill(Shapes.ellipse(Offset(p.dx, p.dy + 1.8 * s), 2.4 * s, 3.2 * s), color.fade(0.55 + 0.45 * twinkle));
        index += 1;
      }
    }
  }

  /// A clay oil lamp with a flickering flame.
  static void diya(GContext g, Offset foot, double wd, double time, double phase, bool dark, {bool lit = true}) {
    final f = flicker(time, phase);
    final tip = Offset(foot.dx + wd * 0.38, foot.dy - wd * 0.42);
    if (lit) {
      glow(g, Offset(tip.dx, tip.dy - wd * 0.35), wd * (1.7 + 0.12 * f), hex(0xFFC14D), (dark ? 0.6 : 0.38) * f);
      g.fill(Shapes.ellipse(foot, wd * 1.0, wd * 0.18), black.fade(dark ? 0.3 : 0.14));
    }
    // Bowl: rounded underneath, pinched into a spout on the right.
    final bowl = Path()
      ..moveTo(foot.dx - wd * 0.5, foot.dy - wd * 0.36)
      ..quadraticBezierTo(foot.dx - wd * 0.45, foot.dy + wd * 0.02, foot.dx + wd * 0.1, foot.dy)
      ..quadraticBezierTo(foot.dx + wd * 0.42, foot.dy - wd * 0.08, tip.dx, tip.dy)
      ..quadraticBezierTo(foot.dx, foot.dy - wd * 0.28, foot.dx - wd * 0.5, foot.dy - wd * 0.36)
      ..close();
    g.fill(bowl, hex(0xC2512B));
    g.stroke(bowl, hex(0x8C3518), math.max(0.5, wd / 22));
    final oil = Shapes.ellipse(Offset(foot.dx - wd * 0.08, foot.dy - wd * 0.32), wd * 0.72, wd * 0.14);
    g.fill(oil, hex(0x5A2A12));
    g.stroke(oil, hex(0xE58A4E), math.max(0.5, wd / 24));
    const dots = [-0.28, -0.08, 0.12];
    for (var index = 0; index < dots.length; index++) {
      g.fill(
        Shapes.ellipse(Offset(foot.dx + wd * dots[index], foot.dy - wd * 0.14), wd * 0.08, wd * 0.08),
        index == 1 ? white.fade(0.9) : hex(0xFFD166),
      );
    }
    // Flame.
    final height = wd * 0.62 * (0.85 + 0.2 * f);
    final sway = math.sin(time * 3.1 + phase) * wd * 0.04;
    final flame = Path()
      ..moveTo(tip.dx, tip.dy + wd * 0.02)
      ..quadraticBezierTo(tip.dx - wd * 0.2, tip.dy - height * 0.35, tip.dx + sway, tip.dy - height)
      ..quadraticBezierTo(tip.dx + wd * 0.2, tip.dy - height * 0.35, tip.dx, tip.dy + wd * 0.02);
    g.fill(flame, hex(0xFF9A1F));
    final core = Path()
      ..moveTo(tip.dx, tip.dy)
      ..quadraticBezierTo(tip.dx - wd * 0.1, tip.dy - height * 0.22, tip.dx + sway * 0.6, tip.dy - height * 0.6)
      ..quadraticBezierTo(tip.dx + wd * 0.1, tip.dy - height * 0.22, tip.dx, tip.dy);
    g.fill(core, hex(0xFFF3B0));
  }

  /// A colourful rangoli seen on the floor (squashed into perspective).
  static void rangoli(GContext g, Offset center, double radius) {
    final rr = radius;
    final r = g.copy()
      ..translateBy(center.dx, center.dy)
      ..scaleBy(1, 0.3);
    Path petals(int count, double inner, double outer, double width, double offset, {int every = 1, int phase = 0}) {
      final path = Path();
      for (var index = 0; index < count; index++) {
        if ((index + phase) % every != 0) continue;
        final angle = index / count * 2 * math.pi + offset;
        final c = math.cos(angle), s = math.sin(angle);
        final a = Offset(c * inner, s * inner);
        final b = Offset(c * outer, s * outer);
        final mid = (inner + outer) / 2;
        path
          ..moveToPoint(a)
          ..quadTo(b, Offset(c * mid - s * width, s * mid + c * width))
          ..quadTo(a, Offset(c * mid + s * width, s * mid - c * width));
      }
      return path;
    }

    final outline = Path();
    for (var index = 0; index < 36; index++) {
      final angle = index / 36 * 2 * math.pi;
      outline.addOval(
        Rect.fromLTWH(math.cos(angle) * rr * 1.06 - rr * 0.03, math.sin(angle) * rr * 1.06 - rr * 0.03, rr * 0.06, rr * 0.06),
      );
    }
    r.fill(outline, white.fade(0.85));
    r.fill(petals(12, rr * 0.6, rr, rr * 0.17, 0, every: 2), hex(0xD7266B));
    r.fill(petals(12, rr * 0.6, rr, rr * 0.17, 0, every: 2, phase: 1), hex(0xFF8C1A));
    final dots = Path();
    for (var index = 0; index < 24; index++) {
      final angle = index / 24 * 2 * math.pi;
      dots.addOval(Rect.fromLTWH(math.cos(angle) * rr * 0.56 - rr * 0.035, math.sin(angle) * rr * 0.56 - rr * 0.035, rr * 0.07, rr * 0.07));
    }
    r.fill(Shapes.ellipse(Offset.zero, rr * 1.1, rr * 1.1), hex(0x2EC4B6));
    r.fill(dots, white);
    r.fill(petals(8, rr * 0.16, rr * 0.5, rr * 0.13, math.pi / 8), hex(0xFFC93C));
    r.fill(Shapes.ellipse(Offset.zero, rr * 0.34, rr * 0.34), hex(0x6A3FB5));
    r.fill(Shapes.ellipse(Offset.zero, rr * 0.14, rr * 0.14), hex(0xFFE7A3));
  }

  /// Glowing motes drifting up through the room, away from the faces.
  static void floatingLights(GContext g, SeasonScene sc) {
    for (var index = 0; index < 8; index++) {
      final period = 9 + Ease.hash(index, 21) * 5;
      final p = Ease.fract(sc.time / period + Ease.hash(index, 22));
      final x = sc.w * Ease.hash(index, 23) + math.sin(sc.time * 0.7 + index) * 8 * sc.s;
      final y = sc.ground - p * (sc.ground + 10);
      final point = Offset(x, y);
      final alpha = Ease.bump(p, 0, 1) * sc.faceClearance(point) * 0.9;
      if (alpha <= 0.02) continue;
      glow(g, point, 6 * sc.s, hex(0xFFC94D), alpha * 0.55);
      g.fill(Shapes.ellipse(point, 2.2 * sc.s, 2.2 * sc.s), hex(0xFFF1C2).fade(alpha));
    }
    // A couple of marigold petals tumbling down.
    for (var index = 0; index < 3; index++) {
      final period = 11 + Ease.hash(index, 31) * 4;
      final p = Ease.fract(sc.time / period + Ease.hash(index, 32));
      final point = Offset(sc.w * Ease.hash(index, 33) + math.sin(sc.time * 1.1 + index * 2) * 12 * sc.s, -6 + p * (sc.h + 12));
      final alpha = Ease.bump(p, 0, 1) * sc.faceClearance(point);
      if (alpha <= 0.02) continue;
      final petal = g.copy()
        ..translateBy(point.dx, point.dy)
        ..rotate(sc.time * 1.7 + index);
      petal.fill(Shapes.ellipse(Offset.zero, 3.6 * sc.s, 2 * sc.s), (index.isEven ? marigoldOrange : marigoldYellow).fade(alpha));
    }
  }

  // MARK: - Christmas

  static void christmas(GContext g, SeasonScene sc) {
    final w = sc.w, s = sc.s, ground = sc.ground, t = sc.time;
    // Snow outside the window, or a wreath around the porthole in space.
    final window = sc.window;
    if (window != null) {
      if (sc.theme == OfficeTheme.spaceStation) {
        wreath(g, sc);
      } else {
        final outside = g.copy()..clip(window);
        final bounds = window.getBounds();
        snowflakes(outside, bounds, 14, t, sc.reduced, 1.8 * s, white.fade(0.95));
        final drift = Path()
          ..moveTo(bounds.left, bounds.bottom)
          ..cubicTo(
            bounds.left + bounds.width * 0.3,
            bounds.bottom - 12 * s,
            bounds.left + bounds.width * 0.6,
            bounds.bottom - 2 * s,
            bounds.right,
            bounds.bottom - 3 * s,
          )
          ..lineTo(bounds.right, bounds.bottom)
          ..close();
        outside.fill(drift, white.fade(0.92));
      }
    } else {
      // No window: a gentle snowfall over the backdrop.
      snowflakes(g, Rect.fromLTWH(0, 0, w, ground), 16, t * 0.8, sc.reduced, 1.5 * s, white.fade(0.55));
    }
    evergreenGarland(g, sc);
    stocking(g, Offset(w * 0.415, sc.h * 0.34), 21 * s, hex(0xD94B4B), sc.reduced ? 0 : math.sin(t * 0.8) * 0.04);
    stocking(g, Offset(w * 0.478, sc.h * 0.36), 19 * s, hex(0x3C9A5F), sc.reduced ? 0 : math.sin(t * 0.8 + 1) * 0.04);
    presents(g, Offset(w * 0.85, ground + 6 * s), s, sc.dark);
    tree(g, Offset(w * 0.94, ground + 4 * s), 70 * s, t, sc.reduced, sc.dark);
  }

  static void snowflakes(GContext g, Rect rect, int count, double time, bool reduced, double size, Color color) {
    final flakes = Path();
    for (var index = 0; index < count; index++) {
      final speed = 0.08 + Ease.hash(index, 41) * 0.06;
      final p = reduced ? Ease.hash(index, 42) : Ease.fract(time * speed + Ease.hash(index, 42));
      final x = rect.left + Ease.hash(index, 43) * rect.width + math.sin(time * 0.9 + index) * 3;
      final y = rect.top - 3 + p * (rect.height + 6);
      final r = size * (0.7 + Ease.hash(index, 44) * 0.6);
      flakes.addOval(Rect.fromLTWH(x - r / 2, y - r / 2, r, r));
    }
    g.fill(flakes, color);
  }

  static void wreath(GContext g, SeasonScene sc) {
    final radius = math.min(sc.h * 0.27, 40.0) + 5;
    final center = Offset(sc.w * 0.2, sc.h * 0.36);
    final needles = Path();
    final berries = Path();
    for (var index = 0; index < 30; index++) {
      final angle = index / 30 * 2 * math.pi;
      final p = Offset(center.dx + math.cos(angle) * radius, center.dy + math.sin(angle) * radius);
      needles.addOval(Rect.fromLTWH(p.dx - 4.5, p.dy - 4.5, 9, 9));
      if (index % 5 == 2) berries.addOval(Rect.fromLTWH(p.dx + 1, p.dy - 1, 3.4, 3.4));
    }
    g.fill(needles, hex(0x2F7D4F));
    g.stroke(needles, hex(0x3C9A5F), 1);
    g.fill(berries, hex(0xE23D3D));
    bow(g, Offset(center.dx, center.dy + radius + 2), 9);
  }

  static void bow(GContext g, Offset c, double size) {
    final red = hex(0xE23D3D);
    for (final side in const [-1.0, 1.0]) {
      final loop = Path()
        ..moveToPoint(c)
        ..quadraticBezierTo(c.dx + side * size * 0.6, c.dy - size * 0.75, c.dx + side * size, c.dy - size * 0.1)
        ..quadraticBezierTo(c.dx + side * size * 0.6, c.dy + size * 0.5, c.dx, c.dy);
      g.fill(loop, red);
      g.stroke(Shapes.line(c, Offset(c.dx + side * size * 0.45, c.dy + size * 0.95)), red, size * 0.22);
    }
    g.fill(Shapes.ellipse(c, size * 0.4, size * 0.4), hex(0xB82A2A));
  }

  /// Pine swags along the top with red bows and gold baubles.
  static void evergreenGarland(GContext g, SeasonScene sc) {
    final w = sc.w, s = sc.s;
    final anchors = [for (var i = 0; i <= 3; i++) Offset(w * i / 3, 0)];
    for (var i = 0; i + 1 < anchors.length; i++) {
      final a = anchors[i], b = anchors[i + 1];
      final swag = swagPath(a, b, 11 * s);
      g.stroke(swag, hex(0x2F7D4F), 7 * s);
      g.stroke(swag, hex(0x3C9A5F), 5 * s, join: StrokeJoin.miter, dash: [1.4 * s, 2.2 * s]);
      for (final step in const [0.25, 0.5, 0.75]) {
        final p = swagPoint(a, b, 11 * s, step);
        g.fill(Shapes.ellipse(Offset(p.dx, p.dy + 4.5 * s), 4.6 * s, 4.6 * s), hex(step == 0.5 ? 0xFFD166 : 0xE23D3D));
        g.fill(Shapes.ellipse(Offset(p.dx - 0.8 * s, p.dy + 3.7 * s), 1.4 * s, 1.4 * s), white.fade(0.7));
      }
    }
    for (final anchor in anchors.sublist(1, anchors.length - 1)) {
      bow(g, Offset(anchor.dx, 3 * s), 6 * s);
    }
  }

  static void stocking(GContext g, Offset top, double size, Color color, double swing) {
    final st = g.copy()
      ..translateBy(top.dx, top.dy)
      ..rotate(swing);
    final k = size / 20;
    st.stroke(Shapes.line(Offset(0, -4 * k), Offset(0, 1 * k)), hex(0x9C7B4E), 0.8);
    st.fill(Shapes.ellipse(Offset(0, -4.4 * k), 2.2 * k, 2.2 * k), hex(0xC9A15B));
    final sock = Path()
      ..moveTo(-4.5 * k, 2 * k)
      ..lineTo(-4.5 * k, 13 * k)
      ..quadraticBezierTo(-4.5 * k, 19 * k, 1 * k, 19 * k)
      ..lineTo(6 * k, 19 * k)
      ..quadraticBezierTo(9.5 * k, 17 * k, 6.5 * k, 13.5 * k)
      ..lineTo(4.5 * k, 12 * k)
      ..lineTo(4.5 * k, 2 * k)
      ..close();
    st.fill(sock, color);
    st.fill(Shapes.ellipse(Offset(5.6 * k, 16.6 * k), 5 * k, 4.6 * k), white.fade(0.85));
    st.fill(Shapes.roundedRect(Rect.fromLTWH(-5.5 * k, 0, 11 * k, 4.6 * k), 2 * k), white);
    st.fill(Shapes.star(Offset(0, 8.5 * k), 2.4 * k), hex(0xFFD166));
  }

  static void presents(GContext g, Offset foot, double s, bool dark) {
    g.fill(Shapes.ellipse(foot, 30 * s, 4 * s), black.fade(dark ? 0.3 : 0.12));
    for (final (dx, wd, ht, box, ribbon) in const [(-7.0, 13.0, 10.0, 0xE23D3D, 0xFFD166), (6.0, 10.0, 8.0, 0x6FC3DF, 0xFFFFFF)]) {
      final rect = Rect.fromLTWH(foot.dx + dx * s - wd * s / 2, foot.dy - ht * s, wd * s, ht * s);
      g.fill(Shapes.roundedRect(rect, 1.2 * s), hex(box));
      g.fill(Shapes.rect(Rect.fromLTWH(rect.center.dx - 1 * s, rect.top, 2 * s, rect.height)), hex(ribbon));
      g.fill(Shapes.rect(Rect.fromLTWH(rect.left, rect.center.dy - 0.9 * s, rect.width, 1.8 * s)), hex(ribbon));
      for (final side in const [-1.0, 1.0]) {
        g.fill(Shapes.ellipse(Offset(rect.center.dx + side * 1.8 * s, rect.top - 1 * s), 3.4 * s, 2.4 * s), hex(ribbon));
      }
    }
  }

  /// A little decorated tree: blinking lights, baubles and a glowing star.
  static void tree(GContext g, Offset foot, double height, double time, bool reduced, bool dark) {
    final k = height / 70;
    g.fill(Shapes.ellipse(foot, 40 * k, 5 * k), black.fade(dark ? 0.3 : 0.13));
    g.fill(Shapes.roundedRect(Rect.fromLTWH(foot.dx - 3 * k, foot.dy - 10 * k, 6 * k, 8 * k), 1 * k), hex(0x8A5A3C));
    g.fill(Shapes.roundedRect(Rect.fromLTWH(foot.dx - 7 * k, foot.dy - 6 * k, 14 * k, 7 * k), 2 * k), hex(0xC94A3F));
    const tiers = [(-8.0, -34.0, 19.0), (-26.0, -50.0, 15.0), (-42.0, -64.0, 10.5)];
    final lights = <Offset>[];
    for (var index = 0; index < tiers.length; index++) {
      final (base, top, half) = tiers[index];
      final shape = Path()
        ..moveTo(foot.dx - half * k, foot.dy + base * k)
        ..quadraticBezierTo(foot.dx, foot.dy + (base + 4) * k, foot.dx + half * k, foot.dy + base * k)
        ..lineTo(foot.dx, foot.dy + top * k)
        ..close();
      g.fill(shape, hex(index.isEven ? 0x2F7D4F : 0x34885A));
      final shade = g.copy()..clip(shape);
      shade.fill(Shapes.rect(Rect.fromLTWH(foot.dx, foot.dy + top * k, half * k, (base - top + 4) * k)), black.fade(0.12));
      // A garland of lights across the tier.
      for (var step = 0; step < 4; step++) {
        final t = (step + 0.5) / 4;
        lights.add(Offset(foot.dx - half * k * 0.82 + t * half * k * 1.64, foot.dy + (base - 2.5 - 3 * math.sin(t * math.pi)) * k));
      }
    }
    const bulbColors = [0xFFD166, 0xFF6B6B, 0x7FD6F2, 0x9CE37D];
    final beat = (time / 0.7).truncate();
    for (var index = 0; index < lights.length; index++) {
      final p = lights[index];
      final on = reduced || (index + beat) % 3 != 0;
      final color = hex(bulbColors[index % bulbColors.length]);
      if (on) glow(g, p, 5 * k, color, dark ? 0.75 : 0.5);
      g.fill(Shapes.ellipse(p, 3 * k, 3 * k), on ? color : color.fade(0.35));
    }
    for (final (dx, dy, color) in const [
      (-9.0, -14.0, 0xE23D3D),
      (8.0, -20.0, 0xFFD166),
      (-5.0, -37.0, 0x7FD6F2),
      (6.0, -44.0, 0xE23D3D),
    ]) {
      final p = Offset(foot.dx + dx * k, foot.dy + dy * k);
      g.fill(Shapes.ellipse(p, 4.2 * k, 4.2 * k), hex(color));
      g.fill(Shapes.ellipse(Offset(p.dx - 0.7 * k, p.dy - 0.7 * k), 1.3 * k, 1.3 * k), white.fade(0.7));
    }
    final star = Offset(foot.dx, foot.dy - 66 * k);
    final pulse = reduced ? 1.0 : 0.8 + 0.2 * math.sin(time * 2);
    glow(g, star, 12 * k, hex(0xFFE38A), (dark ? 0.7 : 0.5) * pulse);
    g.fill(Shapes.star(star, 5.5 * k), hex(0xFFD166));
    g.stroke(Shapes.star(star, 5.5 * k), hex(0xE0A82E), 0.6);
  }

  /// Gentle snow in front of everything, thinning out around the faces.
  static void snowfall(GContext g, SeasonScene sc) {
    for (var index = 0; index < 26; index++) {
      final speed = 0.06 + Ease.hash(index, 51) * 0.05;
      final p = Ease.fract(sc.time * speed + Ease.hash(index, 52));
      final x = sc.w * Ease.hash(index, 53) + math.sin(sc.time * 0.8 + index * 1.3) * 6 * sc.s;
      final y = -4 + p * (sc.h + 8);
      final point = Offset(x, y);
      final alpha = sc.faceClearance(point) * (0.6 + 0.35 * Ease.hash(index, 54));
      if (alpha <= 0.02) continue;
      final r = (1.4 + Ease.hash(index, 55) * 1.4) * sc.s;
      if (!sc.dark) g.fill(Shapes.ellipse(Offset(x + 0.3, y + 0.4), r * 1.25, r * 1.25), hex(0x9DB2CC).fade(alpha * 0.35));
      g.fill(Shapes.ellipse(point, r, r), white.fade(alpha));
    }
  }

  // MARK: - New Year

  static const List<int> partyColors = [0xFFD166, 0xFF8FB1, 0x7FD6C2, 0xB9A7FF, 0x8FC7FF];

  static void newYear(GContext g, SeasonScene sc) {
    final w = sc.w, s = sc.s, ground = sc.ground, t = sc.time;
    // Curly streamers hanging from the ceiling.
    const xs = [0.03, 0.15, 0.27, 0.72, 0.84, 0.97];
    for (var index = 0; index < xs.length; index++) {
      final length = (24 + Ease.hash(index, 61) * 22) * s;
      final color = hex(partyColors[index % partyColors.length]);
      final x0 = w * xs[index];
      final ribbon = Path()..moveTo(x0, 0);
      for (var step = 1; step <= 16; step++) {
        final y = step / 16 * length;
        final wave = math.sin(y / s * 0.42 + (sc.reduced ? 0 : t * 1.4) + index) * 3 * s;
        ribbon.lineTo(x0 + wave, y);
      }
      g.stroke(ribbon, color, 2.2 * s);
    }
    // "2027" bunting in the middle, plain flags either side.
    final digits = '${SeasonRenderContext.newYear}'.split('');
    final a = Offset(w * 0.33, 2 * s);
    final b = Offset(w * 0.67, 2 * s);
    g.stroke(swagPath(a, b, 7 * s), hex(0x8C7A9E).fade(0.7), 0.8);
    final count = digits.length + 2;
    const flagColors = [0x3B3B98, 0xFF8FB1, 0xFFB000, 0x2EAA9A, 0x7A5CD6, 0xE85D75];
    for (var index = 0; index < count; index++) {
      final tt = (index + 0.5) / count;
      final p = swagPoint(a, b, 7 * s, tt);
      final isDigit = index > 0 && index <= digits.length;
      final sway = sc.reduced ? 0.0 : math.sin(t * 1.3 + index) * 0.05;
      pennant(
        g,
        p,
        (isDigit ? 15 : 11) * s,
        (isDigit ? 19 : 13) * s,
        hex(flagColors[index % 6]),
        letter: isDigit ? digits[index - 1] : null,
        sway: sway,
      );
    }
    // Confetti on the floor.
    final bits = List.generate(partyColors.length, (_) => Path());
    for (var index = 0; index < 26; index++) {
      final x = w * Ease.hash(index, 63);
      final y = ground + 3 * s + Ease.hash(index, 64) * (sc.h - ground - 6 * s);
      bits[index % bits.length].addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, 3 * s, 1.6 * s), const Radius.circular(0.6)));
    }
    for (var index = 0; index < bits.length; index++) {
      g.fill(bits[index], hex(partyColors[index]).fade(0.9));
    }
    // Sparklers in a jar in the corner.
    sparklerJar(g, Offset(w * 0.06, ground + 6 * s), s, t, sc.reduced, sc.dark);
  }

  static void sparklerJar(GContext g, Offset foot, double s, double time, bool reduced, bool dark) {
    const angles = [-0.35, 0.0, 0.3];
    for (var index = 0; index < angles.length; index++) {
      final angle = angles[index];
      final tip = Offset(foot.dx + math.sin(angle) * 22 * s, foot.dy - 10 * s - math.cos(angle) * 18 * s);
      g.stroke(Shapes.line(Offset(foot.dx, foot.dy - 8 * s), tip), hex(0x9AA0AE), 1 * s);
      final f = reduced ? 1.0 : flicker(time * 1.6, index * 2.0);
      glow(g, tip, 9 * s, hex(0xFFE38A), (dark ? 0.8 : 0.55) * f);
      final tick = reduced ? 1 : (math.max(0, (time * 12).truncate()) & 0xFFFF);
      for (var ray = 0; ray < 8; ray++) {
        final a = ray / 8 * 2 * math.pi + (reduced ? 0 : time * 3 + index);
        final length = (3 + 2 * Ease.hash(ray + index * 8, tick)) * s;
        g.stroke(Shapes.line(tip, Offset(tip.dx + math.cos(a) * length, tip.dy + math.sin(a) * length)), hex(0xFFF1B8), 0.6 * s);
      }
    }
    final jar = Rect.fromLTWH(foot.dx - 6 * s, foot.dy - 11 * s, 12 * s, 11 * s);
    g.fill(Shapes.roundedRect(jar, 2.5 * s), hex(0xBFE4F2).fade(0.75));
    g.stroke(Shapes.roundedRect(jar, 2.5 * s), hex(0x7FA9BC), 0.8);
    g.fill(Shapes.roundedRect(Rect.fromLTWH(jar.left + 1 * s, jar.top - 1.5 * s, jar.width - 2 * s, 2.2 * s), 1), hex(0xE0A82E));
  }

  /// Fireworks bursting high up, in the corners and over the middle, never over the faces.
  static void fireworks(GContext g, SeasonScene sc) {
    const slots = [(0.05, 0.22), (0.38, 0.6), (0.84, 0.96)];
    for (var slot = 0; slot < 3; slot++) {
      const period = 3.4;
      final shifted = sc.time + slot * 1.15;
      final cycle = (shifted / period).floor();
      final local = shifted - cycle * period;
      final seed = cycle * 7 + slot * 131;
      final range = slots[slot];
      final center = Offset(sc.w * Ease.lerp(range.$1, range.$2, Ease.hash(slot, seed)), sc.h * (0.1 + 0.14 * Ease.hash(slot + 9, seed)));
      final color = hex(partyColors[(Ease.hash(slot + 3, seed) * partyColors.length).truncate() % partyColors.length]);
      if (local < 0.5) {
        // The rocket climbing to the burst.
        final p = local / 0.5;
        final y = center.dy + (1 - p) * 26 * sc.s;
        g.fill(Shapes.ellipse(Offset(center.dx, y), 2 * sc.s, 3 * sc.s), color.fade(0.9));
        g.stroke(Shapes.line(Offset(center.dx, y + 2 * sc.s), Offset(center.dx, y + 9 * sc.s)), color.fade(0.35), 1 * sc.s);
        continue;
      }
      final p = Ease.segment(local, 0.5, 2.6);
      if (p >= 1) continue;
      final radius = Ease.outCubic(p) * 19 * sc.s;
      final alpha = 1 - p * p;
      glow(g, center, 14 * sc.s, color, 0.4 * (1 - p));
      final sparks = Path();
      for (var index = 0; index < 14; index++) {
        final angle = index / 14 * 2 * math.pi + Ease.hash(slot, seed) * 3;
        final droop = p * p * 6 * sc.s;
        final tip = Offset(center.dx + math.cos(angle) * radius, center.dy + math.sin(angle) * radius + droop);
        final tail = Offset(center.dx + math.cos(angle) * radius * 0.7, center.dy + math.sin(angle) * radius * 0.7 + droop * 0.6);
        sparks
          ..moveToPoint(tail)
          ..lineToPoint(tip);
      }
      g.stroke(sparks, color.fade(alpha), 1.3 * sc.s);
    }
  }

  // MARK: - Valentine's

  static void valentines(GContext g, SeasonScene sc) {
    final w = sc.w, s = sc.s, t = sc.time;
    // Floating hearts drifting up behind the friends.
    if (!sc.reduced) {
      for (var index = 0; index < 7; index++) {
        final period = 10 + Ease.hash(index, 71) * 6;
        final p = Ease.fract(t / period + Ease.hash(index, 72));
        final point = Offset(w * Ease.hash(index, 73) + math.sin(t * 0.9 + index) * 7 * s, sc.ground - p * sc.ground * 0.95);
        final size = (7 + Ease.hash(index, 74) * 6) * s;
        final alpha = Ease.bump(p, 0, 1) * (sc.dark ? 0.9 : 0.7);
        if (sc.dark) glow(g, point, size, hex(0xFF8FB1), alpha * 0.35);
        g.fill(Shapes.heart(point, size), hex(index.isEven ? 0xFF9FBF : 0xFF7A9C).fade(alpha));
      }
    }
    // A garland of hearts across the top.
    final anchors = [Offset(-4, 2 * s), Offset(w / 2, 4 * s), Offset(w + 4, 2 * s)];
    var index = 0;
    const heartColors = [0xFF6F91, 0xFFC2D4, 0xF0525A];
    for (var i = 0; i + 1 < anchors.length; i++) {
      final a = anchors[i], b = anchors[i + 1];
      g.stroke(swagPath(a, b, 12 * s), hex(0xD9A0B4), 0.9);
      for (var step = 1; step <= 7; step++) {
        final p = swagPoint(a, b, 12 * s, step / 8);
        final swing = sc.reduced ? 0.0 : math.sin(t * 1.2 + index) * 1.2 * s;
        final heart = Offset(p.dx + swing, p.dy + 7 * s);
        g.stroke(Shapes.line(p, Offset(heart.dx, heart.dy - 3 * s)), hex(0xD9A0B4), 0.6);
        g.fill(Shapes.heart(heart, (index % 3 == 1 ? 7 : 9) * s), hex(heartColors[index % 3]));
        index += 1;
      }
    }
  }

  // MARK: - Birthdays

  static void birthday(GContext g, SeasonScene sc) {
    final w = sc.w, s = sc.s, ground = sc.ground, t = sc.time;
    // "HAPPY BIRTHDAY" bunting.
    final letters = 'HAPPY BIRTHDAY'.split('');
    final a = Offset(w * 0.14, 2 * s);
    final b = Offset(w * 0.86, 2 * s);
    g.stroke(swagPath(a, b, 12 * s), hex(0x8C7A9E).fade(0.7), 0.8);
    const flagColors = [0xFF8FB1, 0x7FC8F8, 0xFFC94D, 0x9AD99A, 0xB9A7FF];
    for (var index = 0; index < letters.length; index++) {
      if (letters[index] == ' ') continue;
      final p = swagPoint(a, b, 12 * s, (index + 0.5) / letters.length);
      final sway = sc.reduced ? 0.0 : math.sin(t * 1.3 + index * 0.8) * 0.05;
      pennant(g, p, 14 * s, 17 * s, hex(flagColors[index % 5]), letter: letters[index], sway: sway);
    }
    // Balloon bunches tied in the corners.
    balloons(
      g,
      Offset(w * 0.06, ground + 4 * s),
      const [(0.0, -78.0), (12.0, -66.0), (-9.0, -58.0)],
      const [0xFF8FB1, 0x7FC8F8, 0xFFC94D],
      s,
      t,
      sc.reduced,
    );
    balloons(g, Offset(w * 0.965, ground + 4 * s), const [(2.0, -74.0), (-11.0, -62.0)], const [0xB9A7FF, 0x9AD99A], s, t + 2, sc.reduced);
    cake(g, Offset(w * 0.465, ground + 7 * s), s, SeasonRenderContext.candles, t, sc.dark);
  }

  static void balloons(GContext g, Offset tie, List<(double, double)> offsets, List<int> colors, double s, double time, bool reduced) {
    for (var index = 0; index < offsets.length; index++) {
      final offset = offsets[index];
      final bob = reduced ? 0.0 : math.sin(time * 1.1 + index * 1.9) * 2.5 * s;
      final center = Offset(tie.dx + offset.$1 * s + bob * 0.4, tie.dy + offset.$2 * s + bob);
      final knot = Offset(center.dx, center.dy + 11 * s);
      final string = Path()
        ..moveToPoint(knot)
        ..quadTo(tie, Offset((knot.dx + tie.dx) / 2 + 5 * s, (knot.dy + tie.dy) / 2));
      g.stroke(string, hex(0x9C8FA8).fade(0.8), 0.7);
      final color = hex(colors[index % colors.length]);
      g.fill(Shapes.ellipse(center, 17 * s, 21 * s), color);
      g.fill(
        Path()
          ..moveTo(knot.dx - 2 * s, knot.dy + 1.5 * s)
          ..lineTo(knot.dx + 2 * s, knot.dy + 1.5 * s)
          ..lineTo(knot.dx, knot.dy - 1 * s)
          ..close(),
        color,
      );
      g.fill(Shapes.ellipse(Offset(center.dx - 4 * s, center.dy - 5 * s), 4.5 * s, 6 * s), white.fade(0.45));
    }
  }

  static void cake(GContext g, Offset foot, double s, int candles, double time, bool dark) {
    g.fill(Shapes.ellipse(foot, 40 * s, 6 * s), black.fade(dark ? 0.3 : 0.12));
    g.fill(Shapes.ellipse(Offset(foot.dx, foot.dy - 1 * s), 38 * s, 6 * s), hex(0xF4F1F8));
    final bottom = Rect.fromLTWH(foot.dx - 15 * s, foot.dy - 14 * s, 30 * s, 12 * s);
    final top = Rect.fromLTWH(foot.dx - 10 * s, bottom.top - 9 * s, 20 * s, 9 * s);
    for (final (rect, body, icing) in [(bottom, 0xFFB3C7, 0xFFF4F7), (top, 0xFFE7B8, 0xFF8FB1)]) {
      g.fill(Shapes.roundedRect(rect, 2.5 * s), hex(body));
      final drips = Path()..moveTo(rect.left, rect.top);
      final count = (rect.width / (5 * s)).truncate();
      for (var step = 0; step <= count; step++) {
        final x = rect.left + step / math.max(1, count) * rect.width;
        drips.lineTo(x, rect.top + (step.isEven ? 4.2 : 2.2) * s);
      }
      drips
        ..lineTo(rect.right, rect.top)
        ..close();
      g.fill(Shapes.roundedRect(Rect.fromLTWH(rect.left, rect.top, rect.width, 2.6 * s), 1.3 * s), hex(icing));
      g.fill(drips, hex(icing));
    }
    const sprinkles = [-11.0, -5.0, 2.0, 8.0, 12.0];
    for (var index = 0; index < sprinkles.length; index++) {
      g.fill(
        Shapes.roundedRect(Rect.fromLTWH(foot.dx + sprinkles[index] * s, bottom.center.dy + 1 * s, 2 * s, 1 * s), 0.5),
        hex(partyColors[index % partyColors.length]),
      );
    }
    final count = candles.clamp(1, 5);
    for (var index = 0; index < count; index++) {
      final x = top.left + (index + 0.5) / count * top.width;
      final candle = Rect.fromLTWH(x - 1 * s, top.top - 7 * s, 2 * s, 7 * s);
      g.fill(Shapes.roundedRect(candle, 0.6 * s), hex(partyColors[(index + 1) % partyColors.length]));
      final f = flicker(time, index * 1.7);
      final flameTip = Offset(x + math.sin(time * 3 + index) * 0.4 * s, candle.top - 5 * s * (0.85 + 0.2 * f));
      glow(g, Offset(x, candle.top - 2.5 * s), 7 * s, hex(0xFFC14D), (dark ? 0.6 : 0.4) * f);
      final flame = Path()
        ..moveTo(x, candle.top)
        ..quadTo(flameTip, Offset(x - 2 * s, candle.top - 2 * s))
        ..quadTo(Offset(x, candle.top), Offset(x + 2 * s, candle.top - 2 * s));
      g.fill(flame, hex(0xFFB13B));
      g.fill(Shapes.ellipse(Offset(x, candle.top - 1.6 * s), 1.2 * s, 2 * s), hex(0xFFF3B0));
    }
  }

  /// Slow confetti drifting down in front, thinning around the faces.
  static void confettiFall(GContext g, SeasonScene sc) {
    for (var index = 0; index < 12; index++) {
      final speed = 0.05 + Ease.hash(index, 81) * 0.04;
      final p = Ease.fract(sc.time * speed + Ease.hash(index, 82));
      final point = Offset(sc.w * Ease.hash(index, 83) + math.sin(sc.time + index) * 8 * sc.s, -4 + p * (sc.h + 8));
      final alpha = sc.faceClearance(point) * 0.9;
      if (alpha <= 0.02) continue;
      final bit = g.copy()
        ..translateBy(point.dx, point.dy)
        ..rotate(sc.time * 2.4 + index)
        ..scaleBy(math.cos(sc.time * 3 + index), 1);
      bit.fill(
        Shapes.roundedRect(Rect.fromLTWH(-2 * sc.s, -1 * sc.s, 4 * sc.s, 2 * sc.s), 0.5),
        hex(partyColors[index % partyColors.length]).fade(alpha),
      );
    }
  }

  // MARK: - Menu bar

  /// A tiny, static decoration standing on the menu bar beside the bed (≈ 8 pt tall at scale 1).
  static void menuBarAccent(SeasonalEvent event, GContext g, Offset foot, double scale, {bool dark = false}) {
    final a = g.copy()
      ..translateBy(foot.dx, foot.dy)
      ..scaleBy(scale, scale);
    switch (event) {
      case SeasonalEvent.halloween:
        miniPumpkin(a, const Offset(0, -3.2), 8.2);
        a.fill(Shapes.ellipse(const Offset(-1.4, -3.6), 1.2, 1.2), hex(0x6B2E0A));
        a.fill(Shapes.ellipse(const Offset(1.4, -3.6), 1.2, 1.2), hex(0x6B2E0A));
      case SeasonalEvent.diwali:
        glow(a, const Offset(3.2, -5.5), 4, hex(0xFFC14D), dark ? 0.55 : 0.4);
        diya(a, Offset.zero, 8.5, 0, 0, dark, lit: false);
      case SeasonalEvent.christmas:
        tree(a, Offset.zero, 9.5, 0, true, dark);
      case SeasonalEvent.newYear:
        final cone = a.copy()..rotate(degrees(-25));
        final popper = Path()
          ..moveTo(-1.3, 0)
          ..lineTo(1.3, 0)
          ..lineTo(2.4, -6.5)
          ..lineTo(-2.4, -6.5)
          ..close();
        cone.fill(popper, hex(0xFF8FB1));
        cone.fill(Shapes.rect(const Rect.fromLTWH(-2, -4.2, 4, 1.2)), hex(0xFFD166));
        const bits = [(-3.5, -9.0), (0.5, -10.5), (4.0, -8.5), (5.5, -5.5)];
        for (var index = 0; index < bits.length; index++) {
          final (x, y) = bits[index];
          a.fill(Shapes.roundedRect(Rect.fromLTWH(x, y, 1.8, 1.1), 0.3), hex(partyColors[index % partyColors.length]));
        }
      case SeasonalEvent.userBirthday || SeasonalEvent.mochiBirthday:
        final string = Path()
          ..moveTo(0, 0)
          ..quadraticBezierTo(1.4, -2.4, 0, -4.5);
        a.stroke(string, hex(0x9C8FA8), 0.5);
        a.fill(Shapes.ellipse(const Offset(0, -7.6), 5.4, 6.4), hex(0xFF8FB1));
        a.fill(Shapes.ellipse(const Offset(-1.1, -8.8), 1.4, 1.9), white.fade(0.55));
      case SeasonalEvent.valentines:
        a.fill(Shapes.heart(const Offset(0, -3.6), 7), hex(0xFF6F91));
        a.fill(Shapes.ellipse(const Offset(-1.4, -4.6), 1.6, 1.1), white.fade(0.5));
    }
  }
}
