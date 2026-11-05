// Port of Sources/App/Rendering/AccessoryRenderer.swift: wearables for both characters and
// desk decorations.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'drawing.dart';
import 'item_renderer.dart';
import 'model/poses.dart';
import 'model/world.dart';
import 'pet_renderer.dart';

/// Wearables for both characters and desk decorations.
abstract final class AccessoryRenderer {
  static final Color ink = hex(0x4A3B4F);

  // MARK: Pet (head top ≈ y -54, ears at ±14.5, eyes at ±10.5, -29.5)

  static void petWearable(Accessory accessory, GContext g) {
    switch (accessory) {
      case Accessory.partyHat:
        partyHat(g, const Offset(3, -50), 20, 0.18);
      case Accessory.beanie:
        beanie(g, const Offset(0, -46), 46);
      case Accessory.graduationCap:
        graduationCap(g, const Offset(0, -55), 34);
      case Accessory.detectiveHat:
        deerstalker(g, const Offset(0, -50), 38);
      case Accessory.santaHat:
        festiveHat(g, const Offset(0, -48), 40);
      case Accessory.flowerCrown:
        flowerCrown(g, const Offset(0, -50), 34);
      case Accessory.witchHat:
        witchHat(g, const Offset(0, -49), 44);
      case Accessory.roundGlasses:
        glasses(g, const Offset(-10.5, -29.5), const Offset(10.5, -29.5), 7);
      case Accessory.headphones:
        headphones(g, const Offset(0, -30), 56, -58);
      default:
        break;
    }
  }

  static void petHatItem(HeldItem item, GContext g) {
    switch (item) {
      case HeldItem.gradCap:
        graduationCap(g, const Offset(0, -55), 34);
      case HeldItem.detectiveHat:
        deerstalker(g, const Offset(0, -50), 38);
      default:
        break;
    }
  }

  static void petHoodie(GContext g) {
    final lower = g.copy()..clip(PetRenderer.bodyPath());
    lower.fill(Shapes.rect(const Rect.fromLTWH(-40, -15, 80, 20)), hex(0x7C8CF2));
    lower.stroke(Shapes.line(const Offset(-31, -15), const Offset(31, -15)), hex(0x5D6BD0), 1.4);
    lower.stroke(Shapes.roundedRect(const Rect.fromLTWH(-9, -11, 18, 7), 3), hex(0x5D6BD0), 1.2);
    for (final side in const [-1.0, 1.0]) {
      g.stroke(Shapes.line(Offset(side * 5, -15), Offset(side * 5.5, -9)), white.fade(0.9), 1.2);
    }
  }

  static void petScarf(GContext g) {
    final band = Path()
      ..moveTo(-29, -16)
      ..quadTo(const Offset(29, -16), const Offset(0, -9))
      ..lineTo(28, -10)
      ..quadTo(const Offset(-28, -10), const Offset(0, -3))
      ..close();
    final clipped = g.copy()..clip(PetRenderer.bodyPath());
    clipped.fill(band, hex(0xE85D75));
    final tail = Shapes.roundedRect(const Rect.fromLTWH(12, -11, 7, 13), 2).applying(Affine.rotation(-0.15));
    g.fill(tail, hex(0xD94A63));
    g.stroke(tail, hex(0xB93A52), 0.8);
  }

  // MARK: Companion (head 46×38 centered at (0, -58), top at -77, eyes at ±8, -60)

  static void companionWearable(Accessory accessory, GContext g) {
    switch (accessory) {
      case Accessory.partyHat:
        partyHat(g, const Offset(9, -76), 20, 0.25);
      case Accessory.beanie:
        beanie(g, const Offset(0, -70), 50);
      case Accessory.graduationCap:
        graduationCap(g, const Offset(0, -79), 40);
      case Accessory.detectiveHat:
        deerstalker(g, const Offset(0, -75), 44);
      case Accessory.santaHat:
        festiveHat(g, const Offset(0, -73), 46);
      case Accessory.flowerCrown:
        flowerCrown(g, const Offset(0, -77), 40);
      case Accessory.witchHat:
        witchHat(g, const Offset(0, -74), 50);
      case Accessory.roundGlasses:
        glasses(g, const Offset(-8, -60), const Offset(8, -60), 7.2);
      case Accessory.headphones:
        headphones(g, const Offset(0, -58), 58, -84);
      default:
        break;
    }
  }

  static void companionHatItem(HeldItem item, GContext g) {
    switch (item) {
      case HeldItem.detectiveHat:
        deerstalker(g, const Offset(0, -75), 44);
      case HeldItem.gradCap:
        graduationCap(g, const Offset(0, -79), 40);
      default:
        break;
    }
  }

  static void companionHood(GContext g) {
    final hood = Shapes.roundedRect(const Rect.fromLTWH(-27, -80, 54, 46), 18);
    g.fill(hood, hex(0x6B7BE0));
    g.stroke(hood, hex(0x5160C4), 1.4);
  }

  static void companionScarf(GContext g) {
    final band = Shapes.roundedRect(const Rect.fromLTWH(-17, -43, 34, 7), 3.5);
    g.fill(band, hex(0xE85D75));
    g.stroke(band, hex(0xB93A52), 0.9);
    final tail = Shapes.roundedRect(const Rect.fromLTWH(8, -39, 6.5, 13), 2);
    g.fill(tail, hex(0xD94A63));
  }

  // MARK: Shared shapes

  static void partyHat(GContext g, Offset base, double height, double tilt) {
    final hat = g.copy()
      ..translateBy(base.dx, base.dy)
      ..rotate(tilt);
    final cone = Path()
      ..moveTo(-8, 0)
      ..lineTo(0, -height)
      ..lineTo(8, 0)
      ..close();
    hat.fill(cone, hex(0xFF8FB1));
    final stripes = hat.copy()..clip(cone);
    for (var index = 0; index < 3; index++) {
      final y = -index * height / 3 - 3;
      stripes.fill(Shapes.rect(Rect.fromLTWH(-10, y - 1.8, 20, 2.4)), hex(0xFFE27A));
    }
    hat.stroke(cone, hex(0xD9668A), 1);
    hat.fill(Shapes.ellipse(Offset(0, -height), 5.5, 5.5), hex(0x7FD6C2));
  }

  static void beanie(GContext g, Offset center, double width) {
    final w = width / 2;
    final dome = Path()
      ..moveTo(center.dx - w, center.dy)
      ..curveTo(Offset(center.dx + w, center.dy), Offset(center.dx - w, center.dy - w * 1.05), Offset(center.dx + w, center.dy - w * 1.05))
      ..close();
    g.fill(dome, hex(0x6FA8DC));
    for (var index = -2; index <= 2; index++) {
      final rib = Shapes.line(
        Offset(center.dx + index * w * 0.32, center.dy - 1),
        Offset(center.dx + index * w * 0.22, center.dy - w * 0.65),
      );
      g.stroke(rib, hex(0x5A8FC2), 1);
    }
    final band = Shapes.roundedRect(Rect.fromLTWH(center.dx - w - 1, center.dy - 4.5, width + 2, 7), 3.5);
    g.fill(band, hex(0x4F7FB4));
    g.fill(Shapes.ellipse(Offset(center.dx, center.dy - w * 0.82), 8, 8), hex(0xF4F1EA));
  }

  static void graduationCap(GContext g, Offset center, double width) {
    final w = width / 2;
    g.fill(Shapes.roundedRect(Rect.fromLTWH(center.dx - w * 0.5, center.dy, w, w * 0.42), 2), hex(0x2B2B36));
    final board = Path()
      ..moveTo(center.dx - w, center.dy)
      ..lineTo(center.dx, center.dy - w * 0.34)
      ..lineTo(center.dx + w, center.dy)
      ..lineTo(center.dx, center.dy + w * 0.34)
      ..close();
    g.fill(board, hex(0x34343F));
    g.stroke(board, hex(0x1F1F27), 0.8);
    final tassel = Path()
      ..moveToPoint(center)
      ..lineTo(center.dx + w * 0.72, center.dy + 1)
      ..lineTo(center.dx + w * 0.74, center.dy + w * 0.55);
    g.stroke(tassel, hex(0xF5C451), 1.3);
    g.fill(Shapes.ellipse(Offset(center.dx + w * 0.74, center.dy + w * 0.6), 3, 4), hex(0xF5C451));
    g.fill(Shapes.ellipse(center, 2.4, 2.4), hex(0xF5C451));
  }

  static void deerstalker(GContext g, Offset center, double width) {
    final w = width / 2;
    final brim = Path()
      ..moveTo(center.dx - w, center.dy + 1)
      ..quadTo(Offset(center.dx + w, center.dy + 1), Offset(center.dx, center.dy + 5));
    g.stroke(brim, hex(0x7D5130), 3.4);
    final dome = Path()
      ..moveTo(center.dx - w * 0.78, center.dy)
      ..curveTo(
        Offset(center.dx + w * 0.78, center.dy),
        Offset(center.dx - w * 0.8, center.dy - w * 0.95),
        Offset(center.dx + w * 0.8, center.dy - w * 0.95),
      )
      ..close();
    g.fill(dome, hex(0xA67445));
    final checks = g.copy()..clip(dome);
    for (var index = -3; index <= 3; index++) {
      checks.fill(Shapes.rect(Rect.fromLTWH(center.dx + index * 5 - 0.6, center.dy - w, 1.2, w)), hex(0x7D5130).fade(0.6));
    }
    checks.fill(Shapes.rect(Rect.fromLTWH(center.dx - w, center.dy - w * 0.45, width, 1.2)), hex(0x7D5130).fade(0.6));
    g.stroke(dome, hex(0x6A4426), 1);
    g.fill(Shapes.ellipse(Offset(center.dx, center.dy - w * 0.72), 4, 3), hex(0x7D5130));
  }

  static void festiveHat(GContext g, Offset center, double width) {
    final w = width / 2;
    final hat = Path()
      ..moveTo(center.dx - w * 0.85, center.dy)
      ..quadTo(Offset(center.dx + w * 1.1, center.dy - w * 0.6), Offset(center.dx - w * 0.2, center.dy - w * 1.6))
      ..quadTo(Offset(center.dx + w * 0.85, center.dy), Offset(center.dx + w * 0.5, center.dy - w * 0.5))
      ..close();
    g.fill(hat, hex(0xE04B5A));
    g.fill(Shapes.roundedRect(Rect.fromLTWH(center.dx - w, center.dy - 4, width, 7), 3.5), white);
    g.fill(Shapes.ellipse(Offset(center.dx + w * 1.1, center.dy - w * 0.6), 7, 7), white);
  }

  /// A crooked purple witch hat with an orange band, for Halloween.
  static void witchHat(GContext g, Offset center, double width) {
    final w = width / 2;
    final purple = hex(0x5B3F8C);
    final purpleDark = hex(0x40296A);
    g.fill(Shapes.ellipse(center, width, w * 0.42), purpleDark);
    final cone = Path()
      ..moveTo(center.dx - w * 0.55, center.dy - 1)
      ..quadTo(Offset(center.dx + w * 0.05, center.dy - w * 1.5), Offset(center.dx - w * 0.38, center.dy - w * 0.9))
      ..quadTo(Offset(center.dx + w * 0.62, center.dy - w * 1.2), Offset(center.dx + w * 0.38, center.dy - w * 1.55))
      ..quadTo(Offset(center.dx + w * 0.55, center.dy - 1), Offset(center.dx + w * 0.3, center.dy - w * 0.7))
      ..close();
    g.fill(cone, purple);
    g.fill(Shapes.roundedRect(Rect.fromLTWH(center.dx - w * 0.5, center.dy - w * 0.36, w * 1.0, w * 0.22), 1.5), hex(0xFF9C3F));
    g.fill(Shapes.roundedRect(Rect.fromLTWH(center.dx - w * 0.08, center.dy - w * 0.38, w * 0.2, w * 0.26), 1), hex(0xFFD166));
  }

  static void flowerCrown(GContext g, Offset center, double width) {
    final w = width / 2;
    final colors = [hex(0xFF8FB1), hex(0xFFD166), hex(0xB9A7FF), hex(0xFF9F80), hex(0x7FD6C2)];
    for (var index = 0; index < 5; index++) {
      final t = index / 4;
      final x = center.dx - w + t * width;
      final y = center.dy + math.pow(t - 0.5, 2) * 10 - 2;
      g.fill(Shapes.ellipse(Offset(x + 3.5, y + 1), 4, 2.4), hex(0x6FB794));
      for (var petal = 0; petal < 5; petal++) {
        final angle = petal * 2 * math.pi / 5;
        g.fill(Shapes.ellipse(Offset(x + math.cos(angle) * 2.4, y + math.sin(angle) * 2.4), 3, 3), colors[index]);
      }
      g.fill(Shapes.ellipse(Offset(x, y), 2, 2), hex(0xFFF6D8));
    }
  }

  static void glasses(GContext g, Offset left, Offset right, double radius) {
    for (final center in [left, right]) {
      final lens = Shapes.ellipse(center, radius * 2, radius * 2);
      g.fill(lens, white.fade(0.14));
      g.stroke(lens, hex(0x3B3B48), 1.6);
    }
    final bridge = Path()
      ..moveTo(left.dx + radius, left.dy)
      ..quadTo(Offset(right.dx - radius, right.dy), Offset((left.dx + right.dx) / 2, left.dy - 2.5));
    g.stroke(bridge, hex(0x3B3B48), 1.4);
  }

  static void headphones(GContext g, Offset center, double width, double top) {
    final w = width / 2;
    final band = Path()
      ..moveTo(center.dx - w + 2, center.dy - 2)
      ..curveTo(Offset(center.dx + w - 2, center.dy - 2), Offset(center.dx - w, top), Offset(center.dx + w, top));
    g.stroke(band, hex(0x4A4A5A), 3.4);
    for (final side in const [-1.0, 1.0]) {
      final cup = Shapes.roundedRect(Rect.fromLTWH(center.dx + side * (w - 2) - 5, center.dy - 8, 10, 15), 4.5);
      g.fill(cup, hex(0x5E5E70));
      g.fill(Shapes.roundedRect(Rect.fromLTWH(center.dx + side * (w - 2) - 2.5, center.dy - 5, 5, 9), 2.5), hex(0xFF8FA3));
    }
  }

  // MARK: Desk decorations (desk top at y -22.5, desk spans x -60…62; the right corner is free)

  static void desk(Accessory accessory, GContext g) {
    const spot = Offset(54, -22.5);
    switch (accessory) {
      case Accessory.plant:
        g.fill(Shapes.roundedRect(Rect.fromLTWH(spot.dx - 4.5, spot.dy - 9, 9, 9), 2), hex(0xD98E5F));
        for (final (angle, length) in const [(-0.5, 11.0), (0.1, 13.0), (0.6, 10.0)]) {
          final leaf = g.copy()
            ..translateBy(spot.dx, spot.dy - 9)
            ..rotate(angle);
          leaf.fill(Shapes.ellipse(Offset(0, -length / 2), 5, length), hex(0x6FB794));
        }
      case Accessory.coffeeMug:
        ItemRenderer.draw(HeldItem.coffee, g, Offset(spot.dx, spot.dy - 6), 13);
      case Accessory.rubberDuck:
        g.fill(Shapes.ellipse(Offset(spot.dx, spot.dy - 4), 12, 8), hex(0xFFD54A));
        g.fill(Shapes.ellipse(Offset(spot.dx + 3, spot.dy - 10), 7, 7), hex(0xFFD54A));
        g.fill(Shapes.ellipse(Offset(spot.dx + 6.8, spot.dy - 9.5), 3.6, 2), hex(0xFF9248));
        g.fill(Shapes.ellipse(Offset(spot.dx + 4, spot.dy - 11), 1.4, 1.4), hex(0x2C2234));
      case Accessory.pumpkin:
        for (final offset in const [-3.0, 0.0, 3.0]) {
          g.fill(Shapes.ellipse(Offset(spot.dx + offset, spot.dy - 5), 7, 10), hex(offset == 0 ? 0xFF9C3F : 0xF28A2E));
        }
        g.fill(Shapes.roundedRect(Rect.fromLTWH(spot.dx - 1, spot.dy - 12.5, 2.4, 4), 1), hex(0x6B8E3A));
      case Accessory.trophy:
        ItemRenderer.draw(HeldItem.trophy, g, Offset(spot.dx, spot.dy - 7), 14);
      case Accessory.lavaLamp:
        g.fill(Shapes.roundedRect(Rect.fromLTWH(spot.dx - 3.5, spot.dy - 18, 7, 15), 3.5), hex(0xB9A7FF).fade(0.7));
        g.fill(Shapes.ellipse(Offset(spot.dx, spot.dy - 12), 4, 5), hex(0xFF8FB1));
        g.fill(Shapes.roundedRect(Rect.fromLTWH(spot.dx - 4.5, spot.dy - 4, 9, 4), 1.5), hex(0x5E5E70));
      default:
        break;
    }
  }
}
