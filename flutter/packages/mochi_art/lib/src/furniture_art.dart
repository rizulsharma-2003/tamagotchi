// Port of Sources/App/Features/Room/FurnitureArt.swift.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'drawing.dart';
import 'item_renderer.dart';
import 'model/ease.dart';
import 'model/poses.dart';
import 'palettes.dart';
import 'pet_renderer.dart';
import 'season_decor.dart';

/// Procedural furniture in the scene's style. Each piece draws in its own units (1 unit = 1 pt at
/// scale 1) around its anchor: floor pieces stand on (0, 0), wall pieces and rugs are centred on it.
abstract final class FurnitureArt {
  /// The wall clock's time source (the clock shows the real local time); tests pin it.
  static DateTime Function() now = DateTime.now;

  static void draw(String id, GContext g, {bool dark = false, double time = 0}) {
    switch (id) {
      case 'rug':
        rug(g, dark);
      case 'cushion':
        cushion(g, dark);
      case 'plant':
        plant(g, dark, time);
      case 'poster':
        poster(g, dark);
      case 'lamp':
        lamp(g, dark);
      case 'bookshelf':
        bookshelf(g, dark);
      case 'beanbag':
        beanbag(g, dark);
      case 'catTree':
        catTree(g, dark, time);
      case 'clock':
        clock(g, dark);
      case 'photo':
        photo(g, dark);
      case 'fishBowl':
        fishBowl(g, dark, time);
      case 'toyBox':
        toyBox(g, dark);
      default:
        break;
    }
  }

  static void shadow(GContext g, double width, bool dark) {
    g.fill(Shapes.ellipse(const Offset(0, 0.4), width, math.max(3, width * 0.13)), black.fade(dark ? 0.32 : 0.13));
  }

  static void rug(GContext g, bool dark) {
    final fringe = Path();
    for (var index = 0; index < 7; index++) {
      final y = -4.2 + index * 1.4;
      for (final side in const [-1.0, 1.0]) {
        fringe
          ..moveTo(side * 44.6, y)
          ..lineTo(side * 48.6, y + 0.2);
      }
    }
    g.stroke(fringe, hex(0xF3D9B1), 0.8);
    g.fill(Shapes.ellipse(Offset.zero, 92, 15), hex(0xD9776B));
    g.fill(Shapes.ellipse(Offset.zero, 84, 12.2), hex(0xF3D9B1));
    g.fill(Shapes.ellipse(Offset.zero, 76, 10), hex(0xE38C6E));
    g.stroke(Shapes.ellipse(Offset.zero, 60, 7.2), hex(0xF7E3C4), 0.9, cap: StrokeCap.butt, join: StrokeJoin.miter, dash: const [2.4, 1.6]);
    final diamonds = Path();
    for (final x in const [-18.0, 0.0, 18.0]) {
      diamonds
        ..moveTo(x - 4, 0)
        ..lineTo(x, -1.9)
        ..lineTo(x + 4, 0)
        ..lineTo(x, 1.9)
        ..close();
    }
    g.fill(diamonds, hex(0x5FB3A8));
    if (dark) g.fill(Shapes.ellipse(Offset.zero, 92, 15), black.fade(0.18));
  }

  /// A plump, tufted floor pillow.
  static void cushion(GContext g, bool dark) {
    shadow(g, 30, dark);
    final pillow = Path()
      ..moveTo(-14, -1)
      ..quadraticBezierTo(-16.5, -7, -13, -12.5)
      ..quadraticBezierTo(0, -15.5, 13, -12.5)
      ..quadraticBezierTo(16.5, -7, 14, -1)
      ..quadraticBezierTo(0, 1.5, -14, -1)
      ..close();
    g.fill(pillow, hex(0xE8A0A8));
    g.fill(Shapes.ellipse(const Offset(-4, -10.5), 14, 3.6), white.fade(0.3));
    final creases = Path();
    for (final (from, to) in const [
      (Offset(-6.5, -9.5), Offset(-1.2, -7)),
      (Offset(6.5, -9.5), Offset(1.2, -7)),
      (Offset(-6.5, -3.5), Offset(-1.2, -6)),
      (Offset(6.5, -3.5), Offset(1.2, -6)),
    ]) {
      creases
        ..moveToPoint(from)
        ..lineToPoint(to);
    }
    g.stroke(creases, hex(0xC97B86).fade(0.8), 0.7);
    g.fill(Shapes.ellipse(const Offset(0, -6.5), 2.6, 2.2), hex(0xB8606E));
    for (final corner in const [Offset(-13.6, -12.4), Offset(13.6, -12.4)]) {
      g.fill(Shapes.ellipse(corner, 2.4, 2.4), hex(0xF2C14E));
    }
    g.stroke(pillow, hex(0xC97B86), 0.8);
  }

  static void plant(GContext g, bool dark, double time) {
    shadow(g, 24, dark);
    final foliage = g.copy()
      ..translateBy(0, -17)
      ..rotate(math.sin(time * 0.7) * 0.025);
    const leaves = [
      (-1.15, 19.0, 8.0, 0x3E8E5A),
      (1.1, 19.0, 8.0, 0x3E8E5A),
      (-0.62, 25.0, 9.0, 0x4FA36B),
      (0.6, 24.0, 9.0, 0x4FA36B),
      (-0.18, 30.0, 9.5, 0x5DB477),
      (0.22, 28.0, 9.0, 0x3E8E5A),
    ];
    for (final (angle, length, width, color) in leaves) {
      final leaf = foliage.copy()..rotate(angle);
      final shape = Shapes.ellipse(Offset(0, -length / 2 - 2), width, length);
      leaf.fill(shape, hex(color));
      leaf.stroke(Shapes.line(const Offset(0, -2), Offset(0, -length + 1)), hex(0x2F6E45).fade(0.8), 0.7);
    }
    final pot = Path()
      ..moveTo(-9, -15)
      ..lineTo(9, -15)
      ..lineTo(6.5, 0)
      ..lineTo(-6.5, 0)
      ..close();
    g.fill(pot, hex(0xD9774A));
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-10, -18, 20, 4.5), 1.5), hex(0xE98B5D));
    g.fill(Shapes.rect(const Rect.fromLTWH(-6.5, -9, 13, 1.2)), hex(0xC4643A));
  }

  static void poster(GContext g, bool dark) {
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-14, -18, 30, 38), 1.5), black.fade(dark ? 0.3 : 0.1));
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-15, -19, 30, 38), 1.5), hex(0xFFFBF4));
    const art = Rect.fromLTWH(-12.5, -16.5, 25, 27);
    g.fillLinear(Shapes.rect(art), [hex(0xFFC59E), hex(0xFF8FA3), hex(0x9C7AE0)], Offset(0, art.top), Offset(0, art.bottom));
    final inside = g.copy()..clip(Shapes.rect(art));
    inside.fill(Shapes.ellipse(const Offset(0, -1), 13, 13), hex(0xFFE08A));
    final far = Path()
      ..moveTo(-14, art.bottom)
      ..lineTo(-5, 1)
      ..lineTo(3, art.bottom);
    inside.fill(far, hex(0x7B66B0));
    final near = Path()
      ..moveTo(-4, art.bottom)
      ..lineTo(6, 3)
      ..lineTo(15, art.bottom);
    inside.fill(near, hex(0x5B4A8C));
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-8, 12.8, 16, 1.6), 0.8), hex(0x9C8FA8));
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-5, 15.4, 10, 1.2), 0.6), hex(0xC9C0D4));
    for (final side in const [-1.0, 1.0]) {
      final tape = g.copy()
        ..translateBy(side * 13, -18.5)
        ..rotate(side * 0.6);
      tape.fill(Shapes.rect(const Rect.fromLTWH(-4, -1.6, 8, 3.2)), hex(0xFFF3C4).fade(0.75));
    }
  }

  static void lamp(GContext g, bool dark) {
    const light = Offset(0, -60);
    g.fillRadial(Shapes.ellipse(light, 84, 84), [hex(0xFFD38A).fade(dark ? 0.42 : 0.24), hex(0xFFD38A).fade(0)], light, 2, 42);
    shadow(g, 20, dark);
    g.fill(Shapes.ellipse(const Offset(0, -1.6), 16, 4), hex(0x5B4A5E));
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-1.1, -68, 2.2, 67), 1.1), hex(0x6B5A70));
    final shade = Path()
      ..moveTo(-6, -84)
      ..lineTo(6, -84)
      ..lineTo(11.5, -66)
      ..lineTo(-11.5, -66)
      ..close();
    g.fill(Shapes.ellipse(const Offset(0, -66), 21, 4), hex(0xFFE9B8));
    g.fill(shade, hex(0xF6C98E));
    final stripes = g.copy()..clip(shade);
    for (var x = -12.0; x <= 12; x += 4) {
      stripes.fill(Shapes.rect(Rect.fromLTWH(x, -85, 1.6, 20)).applying(Affine(1, 0, -x / 40, 1, 0, 0)), hex(0xEDB06C));
    }
    g.stroke(shade, hex(0xD99A55), 0.8);
  }

  static void bookshelf(GContext g, bool dark) {
    shadow(g, 42, dark);
    final frame = Shapes.roundedRect(const Rect.fromLTWH(-20, -64, 40, 64), 2);
    g.fill(frame, hex(0xB97F4E));
    g.fill(Shapes.rect(const Rect.fromLTWH(-17, -61, 34, 58)), hex(0x7A4F2E));
    const colors = [0xE76F51, 0x2A9D8F, 0xE9C46A, 0x8AB17D, 0x6D597A, 0xF4A261, 0x457B9D, 0xF1E3D3];
    const bases = [-42.0, -22.0, -3.0];
    for (var row = 0; row < bases.length; row++) {
      final base = bases[row];
      var x = -16.0;
      var index = row * 3;
      while (x < 14) {
        final width = (3 + (index * 7) % 3).toDouble();
        final height = (12 + (index * 5) % 6).toDouble();
        if (row == 1 && index == 5) {
          // A small trinket instead of a book.
          g.fill(Shapes.ellipse(Offset(x + 3, base - 3.5), 6, 6), hex(0xFF8FA3));
          x += 7;
        } else {
          final book = Rect.fromLTWH(x, base - height, width, height);
          g.fill(Shapes.rect(book), hex(colors[index % colors.length]));
          g.fill(Shapes.rect(Rect.fromLTWH(book.left, book.top + 2.5, width, 1)), white.fade(0.35));
          x += width + 0.6;
        }
        index += 1;
      }
      g.fill(Shapes.rect(Rect.fromLTWH(-17, base, 34, 2.4)), hex(0xC98F5C));
    }
    g.stroke(frame, hex(0x8C5A34), 1);
    // A tiny plant on top.
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(6, -70, 7, 6), 1.2), hex(0xD9774A));
    for (final angle in const [-0.6, 0.0, 0.6]) {
      final leaf = g.copy()
        ..translateBy(9.5, -70)
        ..rotate(angle);
      leaf.fill(Shapes.ellipse(const Offset(0, -3.5), 3.2, 7), hex(0x4FA36B));
    }
  }

  static void beanbag(GContext g, bool dark) {
    shadow(g, 40, dark);
    final bag = Path()
      ..moveTo(-19, -1)
      ..cubicTo(-23, -10, -18, -20, -10, -22)
      ..cubicTo(-3, -25, 4, -27, 12, -24)
      ..cubicTo(20, -21, 23, -9, 19, -3)
      ..cubicTo(10, 1.5, -8, 1.5, -19, -1)
      ..close();
    g.fill(bag, hex(0x7FBFC8));
    final dent = Path()
      ..moveTo(-9, -12)
      ..quadraticBezierTo(1, -6, 10, -13);
    g.stroke(dent, hex(0x5E9EA8), 1.2);
    g.fill(Shapes.ellipse(const Offset(-8, -18), 9, 4), white.fade(0.35));
    g.stroke(bag, hex(0x4F8C96), 0.9);
  }

  static void catTree(GContext g, bool dark, double time) {
    shadow(g, 42, dark);
    void post(double x, double top, double bottom) {
      final rect = Rect.fromLTWH(x - 3, top, 6, bottom - top);
      g.fill(Shapes.rect(rect), hex(0xD8BF8F));
      final rope = g.copy()..clip(Shapes.rect(rect));
      final lines = Path();
      for (var y = top; y <= bottom + 6; y += 2.2) {
        lines
          ..moveTo(x - 4, y)
          ..lineTo(x + 4, y - 2);
      }
      rope.stroke(lines, hex(0xB89A66), 0.7);
    }

    post(-9, -44, -5);
    post(8, -80, -5);
    final carpet = hex(0xB9A7D9);
    final edge = hex(0x8F7CB8);
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-20, -6, 40, 6), 2), carpet);
    g.stroke(Shapes.roundedRect(const Rect.fromLTWH(-20, -6, 40, 6), 2), edge, 0.8);
    // Middle platform with a dangling pom-pom.
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-19, -48, 25, 5), 2), carpet);
    g.stroke(Shapes.roundedRect(const Rect.fromLTWH(-19, -48, 25, 5), 2), edge, 0.8);
    final swing = math.sin(time * 1.6) * 3;
    final ball = Offset(-15 + swing, -30);
    g.stroke(Shapes.line(const Offset(-15, -43), ball), hex(0x8C7A9E), 0.7);
    g.fill(Shapes.ellipse(ball, 5.5, 5.5), hex(0xFF8FB1));
    g.fill(Shapes.ellipse(Offset(ball.dx - 1, ball.dy - 1), 1.8, 1.8), white.fade(0.6));
    // Top platform with a round bed.
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-4, -84, 24, 5), 2), carpet);
    g.stroke(Shapes.roundedRect(const Rect.fromLTWH(-4, -84, 24, 5), 2), edge, 0.8);
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-1, -89, 18, 6), 3), hex(0xF4B3C2));
    g.fill(Shapes.ellipse(const Offset(8, -88), 13, 2.6), hex(0xFFDCE5));
  }

  /// A cat-eared wall clock showing the real time.
  static void clock(GContext g, bool dark) {
    for (final side in const [-1.0, 1.0]) {
      final ear = Path()
        ..moveTo(side * 9.5, -6)
        ..lineTo(side * 9, -14)
        ..lineTo(side * 3, -10)
        ..close();
      g.fill(ear, hex(0xC77D4E));
      g.fill(Shapes.ellipse(Offset(side * 7.6, -10.4), 2.4, 3), hex(0xFFB9A6));
    }
    g.fill(Shapes.ellipse(const Offset(0.6, 0.8), 24, 24), black.fade(dark ? 0.3 : 0.1));
    g.fill(Shapes.ellipse(Offset.zero, 24, 24), hex(0xC77D4E));
    g.fill(Shapes.ellipse(Offset.zero, 19.5, 19.5), hex(0xFFF8EE));
    final ticks = Path();
    for (var index = 0; index < 12; index++) {
      final angle = index / 12 * 2 * math.pi;
      final inner = index % 3 == 0 ? 6.6 : 7.6;
      ticks
        ..moveTo(math.sin(angle) * inner, -math.cos(angle) * inner)
        ..lineTo(math.sin(angle) * 8.8, -math.cos(angle) * 8.8);
    }
    g.stroke(ticks, hex(0x8C7A9E), 0.8);
    final date = now();
    final seconds = ((date.hour % 12) * 3600 + date.minute * 60 + date.second + date.millisecond / 1000).toDouble();
    final hourAngle = seconds / 43200 * 2 * math.pi;
    final minuteAngle = (seconds % 3600) / 3600 * 2 * math.pi;
    g.stroke(Shapes.line(Offset.zero, Offset(math.sin(hourAngle) * 4.6, -math.cos(hourAngle) * 4.6)), hex(0x4A3B57), 1.4);
    g.stroke(Shapes.line(Offset.zero, Offset(math.sin(minuteAngle) * 7, -math.cos(minuteAngle) * 7)), hex(0x4A3B57), 0.9);
    g.fill(Shapes.ellipse(Offset.zero, 2, 2), hex(0xFF8FA3));
  }

  /// A framed photo of the two friends.
  static void photo(GContext g, bool dark) {
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-16, -12.5, 34, 27), 2), black.fade(dark ? 0.3 : 0.1));
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-17, -13.5, 34, 27), 2), hex(0xC98F5C));
    g.fill(Shapes.rect(const Rect.fromLTWH(-14.5, -11, 29, 22)), hex(0xFFFBF4));
    const picture = Rect.fromLTWH(-12.5, -9, 25, 18);
    final inside = g.copy()..clip(Shapes.rect(picture));
    inside.fillLinear(Shapes.rect(picture), [hex(0xBFE0FF), hex(0xFDE7F0)], Offset(0, picture.top), Offset(0, picture.bottom));
    inside.fill(Shapes.rect(Rect.fromLTWH(picture.left, 5, picture.width, 4)), hex(0xA6D893));
    final pet = photoPet()..x = 0;
    PetRenderer.draw(pet, inside, const Offset(-5, 7.5), 0.2, PetPalette(SeasonRenderContext.petColor));
    photoCompanion(inside, const Offset(5.8, 8.2), 0.52);
    inside.fill(Shapes.heart(const Offset(0.5, -5.5), 4), hex(0xFF6F91));
    final glare = Path()
      ..moveTo(2, picture.top)
      ..lineTo(8, picture.top)
      ..lineTo(-2, picture.bottom)
      ..lineTo(-8, picture.bottom)
      ..close();
    inside.fill(glare, white.fade(0.18));
    g.stroke(Shapes.roundedRect(const Rect.fromLTWH(-17, -13.5, 34, 27), 2), hex(0x9C6A3E), 0.8);
  }

  /// Mochi smiling at the camera (`FurnitureArt.Photo.pet`: the idle pose at time 0.4 with open
  /// eyes, a glance, blush and a smile — the values exported from Swift).
  static PetPose photoPet() => PetPose()
    ..scaleX = 1.00198
    ..scaleY = 0.996693
    ..tilt = 0.0179266
    ..lookX = 0.35
    ..lookY = 0.0313467
    ..mouth = PetMouth.smile
    ..blush = 0.7
    ..earPerk = -0.0417977
    ..tailWag = -0.123866
    ..lean = 0.0228246
    ..breath = -0.165358
    ..headTurn = 0.246491;

  /// The companion as the Claude Code pixel mascot, waving, drawn as a still for the photo.
  static void photoCompanion(GContext g, Offset feet, double pixel) {
    final p = g.copy()
      ..translateBy(feet.dx, feet.dy)
      ..scaleBy(pixel, pixel);
    final shape = Path()
      ..addRect(const Rect.fromLTWH(-9, -15, 18, 12))
      ..addRect(const Rect.fromLTWH(-12, -10, 3, 2))
      ..addRect(const Rect.fromLTWH(9, -14, 2, 2))
      ..addRect(const Rect.fromLTWH(10, -17, 2, 3));
    for (final x in const [-7.0, -4.0, 2.0, 5.0]) {
      shape.addRect(Rect.fromLTWH(x, -3, 2, 3));
    }
    p.fill(shape, hex(0xCC7A5D));
    p.fill(Shapes.rect(const Rect.fromLTWH(-5, -12, 2, 3)), hex(0x1D1719));
    p.fill(Shapes.rect(const Rect.fromLTWH(3, -12, 2, 3)), hex(0x1D1719));
  }

  static void fishBowl(GContext g, bool dark, double time) {
    shadow(g, 22, dark);
    // A little side table.
    for (final x in const [-8.0, 8.0]) {
      g.fill(Shapes.roundedRect(Rect.fromLTWH(x - 1, -14, 2, 14), 1), hex(0x9C6A3E));
    }
    g.fill(Shapes.roundedRect(const Rect.fromLTWH(-12, -16, 24, 3.2), 1.5), hex(0xC98F5C));
    // The bowl.
    const center = Offset(0, -27);
    final bowl = Shapes.ellipse(center, 23, 21);
    final water = g.copy()..clip(bowl);
    water.fill(Shapes.rect(Rect.fromLTWH(-12, center.dy - 5, 24, 20)), hex(0x8ED3EE).fade(0.75));
    water.stroke(
      Path()
        ..moveTo(-10, -21)
        ..quadraticBezierTo(-11, -26, -7, -30),
      hex(0x4FA36B),
      1.2,
    );
    water.stroke(
      Path()
        ..moveTo(8, -20)
        ..quadraticBezierTo(9.5, -24, 6, -27),
      hex(0x5DB477),
      1,
    );
    // The goldfish swims to and fro.
    final swim = math.sin(time * 0.8);
    final facing = math.cos(time * 0.8) >= 0 ? 1.0 : -1.0;
    final fish = Offset(swim * 5, center.dy + 2 + math.sin(time * 1.7) * 1.2);
    final tail = Path()
      ..moveTo(fish.dx - facing * 2.4, fish.dy)
      ..lineTo(fish.dx - facing * 5.6, fish.dy - 2.2)
      ..lineTo(fish.dx - facing * 5.6, fish.dy + 2.2)
      ..close();
    water.fill(tail, hex(0xFF7A2E));
    water.fill(Shapes.ellipse(fish, 7, 4.4), hex(0xFF9A3D));
    water.fill(Shapes.ellipse(Offset(fish.dx + facing * 1.8, fish.dy - 0.5), 1.1, 1.1), hex(0x2C2234));
    for (var index = 0; index < 2; index++) {
      final p = Ease.fract(time / 2.4 + index * 0.5);
      water.stroke(
        Shapes.ellipse(Offset(fish.dx + facing * 3 + index * 1.5, fish.dy - 2 - p * 8), 1.4, 1.4),
        white.fade(0.8 * (1 - p)),
        0.5,
      );
    }
    g.stroke(bowl, hex(0xA9DDF0).fade(0.9), 0.9);
    g.stroke(Shapes.ellipse(Offset(0, center.dy - 9.6), 13, 2.6), hex(0xA9DDF0), 0.8);
    g.fill(Shapes.ellipse(Offset(-5, center.dy - 3), 3, 6), white.fade(0.4));
  }

  static void toyBox(GContext g, bool dark) {
    shadow(g, 32, dark);
    // The open lid leans back; toys peek out over the front.
    final lid = Path()
      ..moveTo(-15.5, -17)
      ..lineTo(-13, -27)
      ..lineTo(13, -27)
      ..lineTo(15.5, -17)
      ..close();
    g.fill(lid, hex(0xB97F4E));
    g.stroke(lid, hex(0x9C6A3E), 0.8);
    ItemRenderer.yarn(translated(g, 6, -19), 4.6, 0.4);
    ItemRenderer.ball(translated(g, -6, -19.5), 4.8, 0.2);
    final body = Shapes.roundedRect(const Rect.fromLTWH(-15, -17, 30, 17), 2);
    g.fill(body, hex(0xD9A066));
    g.fill(Shapes.rect(const Rect.fromLTWH(-15, -12, 30, 2)), hex(0xB97F4E));
    g.fill(Shapes.rect(const Rect.fromLTWH(-15, -5, 30, 2)), hex(0xB97F4E));
    g.fill(Shapes.heart(const Offset(0, -8.2), 6), hex(0xFF8FA3));
    g.stroke(body, hex(0x9C6A3E), 0.9);
    g.fill(Shapes.ellipse(const Offset(0, -17.4), 31, 2.6), hex(0xB97F4E));
  }

  static GContext translated(GContext g, double x, double y) => g.copy()..translateBy(x, y);
}
