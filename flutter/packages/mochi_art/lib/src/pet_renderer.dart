// Port of Sources/App/Rendering/PetRenderer.swift.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'accessory_renderer.dart';
import 'drawing.dart';
import 'item_renderer.dart';
import 'model/ease.dart';
import 'model/poses.dart';
import 'model/world.dart';
import 'palettes.dart';
import 'pet_tiny_fit.dart';

/// Line weights and sizes for a detail level (`PetRenderer.Style`).
class PetStyle {
  PetStyle(RenderDetail detail, PetPalette palette, {bool dark = false})
    : tiny = detail == RenderDetail.tiny,
      outline = detail == RenderDetail.tiny ? 3.6 : 1.7,
      part = detail == RenderDetail.tiny ? 3.0 : 1.4,
      ink = detail == RenderDetail.tiny ? 3.0 : 1.7,
      eyeBoost = detail == RenderDetail.tiny ? 1.24 : 1,
      outlineColor = palette.outline;

  final bool tiny;
  final double outline;
  final double part;
  final double ink;
  double eyeBoost;
  final Color outlineColor;
  double ears = 1;
  LifeStage stage = LifeStage.grownUp;
}

/// Draws Mochi: a soft, round, bean-shaped creature with short ears, a curly tail and big
/// expressive eyes. Local units: origin at the feet, body 60×54, y up is negative.
abstract final class PetRenderer {
  static const double bodyWidth = 60;
  static const double bodyHeight = 54;

  /// `PetPose.faceShift`: how far a full head turn slides the face (art units).
  static const double faceShiftAmount = 2.4;

  /// Mochi's life stage (set from the friendship on the Swift side).
  static LifeStage stage = LifeStage.grownUp;

  /// Size, eye and ear proportions per life stage: kittens are small with big eyes.
  static ({double size, double eyes, double ears}) proportions(LifeStage stage) => switch (stage) {
    LifeStage.kitten => (size: 0.8, eyes: 1.2, ears: 0.86),
    LifeStage.young => (size: 0.9, eyes: 1.08, ears: 0.94),
    LifeStage.grownUp => (size: 1.0, eyes: 1.0, ears: 1.0),
  };

  static void draw(
    PetPose input,
    GContext context,
    Offset origin,
    double scale,
    PetPalette palette, {
    Accessory? accessory,
    bool dark = false,
    RenderDetail detail = RenderDetail.standard,
  }) {
    if (input.opacity <= 0.01) return;
    final style = PetStyle(detail, palette, dark: dark);
    final growth = proportions(stage);
    style.eyeBoost *= growth.eyes;
    style.ears = growth.ears;
    style.stage = stage;
    final pose = style.tiny ? PetTinyFit.fit(input) : input;
    final base = context.copy()
      ..opacity = pose.opacity
      ..translateBy(origin.dx, origin.dy)
      ..scaleBy(scale * growth.size, scale * growth.size);

    // Ground shadow (does not lift with the body; shrinks as Mochi rises). None in the menu bar.
    if (!style.tiny) {
      final lift = math.max(0.0, pose.y);
      final shadowWidth = 50 * math.max(0.3, pose.shadow) * pose.scaleX * math.max(0.45, 1 - 0.45 * lift);
      base.fill(
        Shapes.ellipse(const Offset(0, 1.5), shadowWidth, 7 * math.max(0.6, 1 - 0.3 * lift)),
        black.fade((dark ? 0.32 : 0.13) * math.max(0.4, 1 - 0.5 * lift)),
      );
    }

    final facing = pose.facing >= 0 ? 1.0 : -1.0;
    final body = base.copy()
      ..translateBy(0, -pose.y * bodyHeight)
      ..translateBy(0, -27)
      ..rotate(pose.rotation)
      ..translateBy(0, 27);
    final lean = pose.lean * facing;
    if (lean.abs() > 0.0001) {
      // Shear about the feet: the head leads, the feet stay planted.
      body.concatenate(Affine(1, 0, -lean, 1, 0, 0));
    }
    body.scaleBy(pose.scaleX, pose.scaleY);

    // The head tilt turns the face and the ears together.
    final face = body.copy()
      ..translateBy(0, -27)
      ..rotate(pose.tilt)
      ..translateBy(0, 27);

    drawTail(pose, body, palette, style);
    drawEars(pose, face, palette, style);
    drawFeet(pose, body, palette, style, front: false);
    drawBody(pose, body, palette, style);
    drawFeet(pose, body, palette, style, front: true);
    drawStageMark(face, body, palette, style);
    if (accessory == Accessory.hoodie) AccessoryRenderer.petHoodie(body);
    if (accessory == Accessory.scarf) AccessoryRenderer.petScarf(body);

    drawFace(pose, face, palette, style);

    if (accessory != null && accessory != Accessory.hoodie && accessory != Accessory.scarf && accessory.slot == AccessorySlot.wearable) {
      AccessoryRenderer.petWearable(accessory, face);
    }
    final hat = pose.hat;
    if (hat != null) AccessoryRenderer.petHatItem(hat, face);

    drawArms(pose, body, palette, style);
    // Puffed cheeks bulge over the shoulders.
    drawCheeks(pose, face, palette, style);
    final held = pose.held;
    if (held != null) {
      final lift = (pose.leftArm + pose.rightArm) / 2;
      switch (held) {
        case HeldItem.rock || HeldItem.paper || HeldItem.scissors:
          // Shown in the front paw (the right one when facing right).
          final raised = facing > 0 ? pose.rightArm : pose.leftArm;
          ItemRenderer.draw(held, body, Offset(31 * facing, -38 - 10 * raised), 15);
        default:
          ItemRenderer.draw(held, body, Offset(4 * facing, -16 - 16 * lift), 15);
      }
    }

    // Yarn wrapped around the body moves with it.
    for (final effect in pose.effects) {
      if (effect.kind == EffectKind.tangle) EffectRenderer.tangle(effect, body, style);
    }

    // Effects live in un-squashed space around the lifted body.
    final effects = base.copy()..translateBy(0, -pose.y * bodyHeight);
    for (final effect in pose.effects) {
      if (effect.kind == EffectKind.tangle) continue;
      var e = effect;
      // Legacy effects in Mochi's own frame.
      if (e.followsFacing && facing < 0) {
        e = e.copy()..x = -e.x;
        if (e.kind == EffectKind.streak) e.rotation = math.pi - e.rotation;
      }
      EffectRenderer.draw(e, effects, unitX: bodyWidth, unitY: bodyHeight, dark: dark, detail: detail);
    }
  }

  /// Horizontal slide of the face (art units, screen space) for a head turn; at menu-bar size
  /// glances also nudge the face so they read as the head turning.
  static double faceShift(PetPose pose, PetStyle style) {
    final facing = pose.facing >= 0 ? 1.0 : -1.0;
    final turn = Ease.clamp(pose.headTurn, -1, 1) * facing * faceShiftAmount;
    return style.tiny ? 1.25 * turn + 1.3 * Ease.clamp(pose.lookX, -1, 1) : turn;
  }

  // MARK: Parts

  static Path bodyPath() => Path()
    ..moveTo(-30, -7)
    ..cubicTo(-31.5, -37, -18, -54, 0, -54)
    ..cubicTo(18, -54, 31.5, -37, 30, -7)
    ..cubicTo(29.5, -1.2, 17, 0, 0, 0)
    ..cubicTo(-17, 0, -29.5, -1.2, -30, -7)
    ..close();

  static void drawBody(PetPose pose, GContext ctx, PetPalette palette, PetStyle style) {
    final path = bodyPath();
    ctx.fillLinear(path, [palette.light, palette.body, palette.body], const Offset(-8, -54), const Offset(6, 0));
    // Soft belly glow that rises and widens as Mochi breathes in.
    final breath = pose.breath;
    ctx.fill(
      Shapes.ellipse(Offset(0, -15 - 1.3 * breath), 34 + 2.2 * breath, 20 + 1.6 * breath),
      palette.light.fade(style.tiny ? 0.35 : 0.45 + 0.05 * breath),
    );
    if (!style.tiny) {
      final highlight = ctx.copy()
        ..translateBy(-13, -42)
        ..rotate(degrees(-28));
      highlight.fill(Shapes.ellipse(Offset.zero, 13, 6.5), white.fade(0.5));
      highlight.fill(Shapes.ellipse(const Offset(9, 3.5), 3, 2), white.fade(0.35));
    }
    ctx.stroke(path, style.outlineColor, style.outline);
  }

  /// A kitten's tuft of fur on top; a grown-up's little bell collar.
  static void drawStageMark(GContext face, GContext body, PetPalette palette, PetStyle style) {
    switch (style.stage) {
      case LifeStage.kitten:
        final tuft = Path()
          ..moveTo(-3.5, -52.5)
          ..quadraticBezierTo(-4.5, -57, -1.5, -59)
          ..moveTo(0, -53.5)
          ..quadraticBezierTo(-1.2, -58.5, 1.6, -61)
          ..moveTo(3.2, -52.8)
          ..quadraticBezierTo(2.8, -56.8, 5.2, -58);
        face.stroke(tuft, style.outlineColor, style.tiny ? 2.6 : 1.5, join: StrokeJoin.miter);
      case LifeStage.young:
        break;
      case LifeStage.grownUp:
        if (style.tiny) return;
        final ribbon = Path()
          ..moveTo(-21, -14.5)
          ..quadraticBezierTo(0, -8.5, 21, -14.5);
        body.stroke(ribbon, hex(0xE0566B), 2.4, join: StrokeJoin.miter);
        const bell = Offset(0, -9.2);
        body.fill(Shapes.ellipse(bell, 6.4, 6.4), hex(0xF2C14E));
        body.stroke(Shapes.ellipse(bell, 6.4, 6.4), hex(0xC8932B), 0.9);
        body.fill(Shapes.rect(Rect.fromLTWH(-1.6, bell.dy + 0.6, 3.2, 0.9)), hex(0x8A6420));
        body.fill(Shapes.ellipse(Offset(bell.dx - 1.1, bell.dy - 1.2), 1.6, 1.2), white.fade(0.7));
    }
  }

  /// Per-ear extra rotation in screen space, mirrored with facing.
  static double earRotation(PetPose pose, double side) {
    if (pose.facing >= 0) return side < 0 ? pose.earLeft : pose.earRight;
    return side < 0 ? -pose.earRight : -pose.earLeft;
  }

  static void drawEars(PetPose pose, GContext ctx, PetPalette palette, PetStyle style) {
    // A head turn slides the ears with the face and swivels them that way.
    final facing = pose.facing >= 0 ? 1.0 : -1.0;
    final turn = Ease.clamp(pose.headTurn, -1, 1) * facing + (style.tiny ? 0.3 * Ease.clamp(pose.lookX, -1, 1) : 0);
    final listen = Ease.clamp(pose.earListen);
    for (var index = 0; index < 2; index++) {
      final side = index == 0 ? -1.0 : 1.0;
      final s = side;
      // Listening closely: the ear on the far side of the turn comes forward, the near one folds back.
      final offered = side == -facing ? listen : 0.0;
      final folded = side == facing ? listen : 0.0;
      final grow = offered;
      final ear = ctx.copy()..translateBy(s * (14.5 + 2.5 * grow) + turn * 1.5, -47 - 1.5 * grow);
      final twitch = earRotation(pose, side);
      // Flicks are amplified at menu-bar size, where a 0.3 rad flick is under a pixel.
      final resting = Ease.lerp((0.3 - 0.36 * pose.earPerk) * side + 0.2 * turn, 0.2 * side, offered);
      final tilt = resting + twitch * (style.tiny ? 1.8 : 1) + 0.5 * folded * side;
      ear.rotate(tilt);
      // Floppy tips bend outward when the ear swings out.
      final outward = Ease.clamp(tilt * side - 0.3, -0.6, 1.2);
      final bend = math.max(0.0, outward) * 3.2 * s;
      // A flicked ear folds a little at the tip, so the silhouette's notch changes too.
      final fold = (style.tiny ? 0.25 : 0.08) * Ease.clamp(twitch.abs() / 0.45);
      final height =
          12 *
          style.ears *
          (1 + 0.08 * Ease.clamp(pose.earPerk - 0.4, 0, 1) - 0.06 * Ease.clamp(-pose.earPerk - 0.8, 0, 1) - fold) *
          (1 + 0.32 * grow) *
          (1 - 0.2 * folded);
      // The offered ear also opens wider, so more of its inside shows.
      final half = 7 + 1.8 * grow;
      final outer = Path()
        ..moveTo(-half, 3)
        ..quadTo(Offset(-1.2 + bend, -height + bend.abs() * 0.35), Offset(-half + 0.5 + bend * 0.4, -height * 0.66))
        ..quadTo(Offset(1.2 + bend, -height + bend.abs() * 0.35), Offset(bend, -height - 1.5))
        ..quadTo(Offset(half, 3), Offset(half - 0.5 + bend * 0.4, -height * 0.66))
        ..close();
      ear.fill(outer, palette.body);
      ear.stroke(outer, style.outlineColor, style.tiny ? 2.8 : 1.6);
      final innerHeight = height * (style.tiny ? 0.62 : 0.71 + 0.07 * grow);
      final innerHalf = 3.6 + 1.9 * grow;
      final inner = Path()
        ..moveTo(-innerHalf, 1)
        ..quadTo(Offset(bend * 0.6, -innerHeight), Offset(-innerHalf + 0.4 + bend * 0.3, -innerHeight * 0.7))
        ..quadTo(Offset(innerHalf, 1), Offset(innerHalf - 0.4 + bend * 0.3, -innerHeight * 0.7))
        ..close();
      ear.fill(inner, palette.innerEar.fade(style.tiny ? 1 : 0.85 + 0.15 * grow));
    }
  }

  /// A short tail that sweeps outward and ends in a fluffy curl. `tailLift` raises it,
  /// `tailCurl` winds it tighter, `tailWag` swings it (positive = tip up and in).
  static void drawTail(PetPose pose, GContext ctx, PetPalette palette, PetStyle style) {
    final side = pose.facing >= 0 ? -1.0 : 1.0;
    final tail = ctx.copy()..translateBy(side * (style.tiny ? 26.5 : 25.5), -6);
    // In the menu bar the tail is longer, carried up and out with a softer curl.
    double start;
    double curl;
    if (style.tiny) {
      final raw = 0.05 + 0.55 * Ease.clamp(pose.tailLift + 1.0, -1, 1.6) + 0.4 * Ease.clamp(pose.tailWag, -2.5, 2.5);
      start = Ease.clamp(raw, -0.3, 0.85);
      // Never curl back over the body (where the tail would vanish behind it).
      curl = math.min(0.9 + 0.7 * Ease.clamp(pose.tailCurl, -1.2, 1.2), (1.75 - start) / 1.1);
    } else {
      start = 0.05 + 0.55 * Ease.clamp(pose.tailLift, -1, 1) + 0.33 * Ease.clamp(pose.tailWag, -2.5, 2.5);
      curl = 2.0 + 1.15 * Ease.clamp(pose.tailCurl, -1.2, 1.2);
    }
    final length = style.tiny ? 28.0 : 21.0;
    Offset point(double a, double r, Offset p) => Offset(p.dx + side * math.cos(a) * r, p.dy - math.sin(a) * r);
    final p1 = point(start, length * 0.45, Offset.zero);
    final p2 = point(start + curl * 0.55, length * 0.33, p1);
    final tip = point(start + curl * 1.1, length * 0.28, p2);
    final path = Path()
      ..moveTo(0, 0)
      ..curveTo(tip, p1, p2);
    tail.stroke(path, style.outlineColor, style.tiny ? 10.5 : 6.4);
    tail.stroke(path, palette.body, style.tiny ? 6.2 : 3.8);
    final tipSize = style.tiny ? 8.6 : 5.2;
    final tipBall = Shapes.ellipse(tip, tipSize, tipSize);
    tail.fill(tipBall, palette.light);
    tail.stroke(tipBall, style.outlineColor, style.tiny ? 2.4 : 1.3);
  }

  static void drawFeet(PetPose pose, GContext ctx, PetPalette palette, PetStyle style, {required bool front}) {
    final facing = pose.facing >= 0 ? 1.0 : -1.0;
    final kick = Ease.clamp(pose.kick, -1, 1);
    for (var index = 0; index < 2; index++) {
      final side = index == 0 ? -1.0 : 1.0;
      // The front foot is the one on the facing side; `kick` > 0 lifts it high.
      final isFront = side == facing;
      final kicked = (kick > 0 && isFront) || (kick < 0 && !isFront);
      final kickAmount = kicked ? kick.abs() : 0.0;
      // Raised feet are drawn in front of the body so they read.
      if ((kickAmount > 0.15) != front) continue;
      // Gait: the swinging foot tucks up, the planted foot presses down and peeks out.
      final step = pose.step * side;
      final lift = math.max(0.0, step) * (style.tiny ? 3.6 : 2.6);
      final plant = math.max(0.0, -step) * (style.tiny ? 1.8 : 2.2);
      final strideOffset = pose.stride * 5.4 * (isFront ? 1 : -1) * facing;
      final kickLift = 34 * math.pow(kickAmount, 1.5);
      final center = Offset(side * (12 + 9 * kickAmount) + strideOffset, -1.6 - lift + plant - kickLift);
      if (kickAmount > 0.5) {
        final hip = Offset(side * 13, -8);
        ctx.fill(Shapes.capsule(hip, center, style.tiny ? 13.5 : 10.5), style.outlineColor);
        ctx.fill(Shapes.capsule(hip, center, style.tiny ? 8 : 7.6), palette.foot);
      }
      final foot = ctx.copy()..translateBy(center.dx, center.dy);
      if (kickAmount > 0.15) {
        // A raised foot turns its sole towards us.
        foot.rotate(side * -0.5 * math.min(1, kickAmount * 1.5));
      }
      final shape = Shapes.ellipse(Offset.zero, style.tiny ? 15 : 14, kickAmount > 0.15 ? 9 : (style.tiny ? 8.5 : 7.5));
      foot.fill(shape, palette.foot);
      foot.stroke(shape, style.outlineColor, style.part);
      if (kickAmount > 0.15 && !style.tiny) {
        // Toe beans.
        foot.fill(Shapes.ellipse(const Offset(0, 1.2), 5.2, 3.4), palette.innerEar.fade(0.95));
        for (var toe = 0; toe < 3; toe++) {
          foot.fill(Shapes.ellipse(Offset((toe - 1) * 3.4, -2.2), 2.2, 2.2), palette.innerEar.fade(0.95));
        }
      }
    }
  }

  static void drawArms(PetPose pose, GContext ctx, PetPalette palette, PetStyle style) {
    // The paw that goes to the mouth is the front one (screen right when facing right).
    final facingSign = pose.facing >= 0 ? 1.0 : -1.0;
    final pawIndex = facingSign > 0 ? 1 : 0;
    final shift = faceShift(pose, style);
    for (var index = 0; index < 2; index++) {
      final side = index == 0 ? -1.0 : 1.0;
      final value = index == 0 ? pose.leftArm : pose.rightArm;
      final angle = Ease.lerp(0.32, 2.75, Ease.clamp(value));
      final shoulder = Offset(side * 24.5, -21);
      final direction = Offset(math.sin(angle) * side, math.cos(angle));
      final length = 7.5 + 2 * Ease.clamp(value);
      var hand = Offset(shoulder.dx + direction.dx * length, shoulder.dy + direction.dy * length);
      final toMouth = index == pawIndex ? Ease.clamp(pose.pawToMouth) : 0.0;
      if (toMouth > 0) {
        final mouth = Offset(7.5 * facingSign + shift, -19.5);
        hand = Offset(hand.dx + (mouth.dx - hand.dx) * toMouth, hand.dy + (mouth.dy - hand.dy) * toMouth);
      }
      final hold = Ease.clamp(pose.holdFront) * (1 - toMouth);
      if (hold > 0) {
        final chest = Offset(side * 6, -15.5);
        hand = Offset(hand.dx + (chest.dx - hand.dx) * hold, hand.dy + (chest.dy - hand.dy) * hold);
      }
      ctx.fill(Shapes.capsule(shoulder, hand, style.tiny ? 11.5 : 10.2), style.outlineColor);
      ctx.fill(Shapes.capsule(shoulder, hand, style.tiny ? 6.4 : 7.4), palette.body);
      if (hold > 0.3) {
        final paw = Shapes.ellipse(hand, 8.6, 8);
        ctx.fill(paw, palette.body);
        ctx.stroke(paw, style.outlineColor, style.part);
      } else if (toMouth > 0.3) {
        final paw = Shapes.ellipse(hand, 9.5, 8.5);
        ctx.fill(paw, palette.body);
        ctx.stroke(paw, style.outlineColor, style.part);
        if (!style.tiny) ctx.fill(Shapes.ellipse(Offset(hand.dx, hand.dy + 0.8), 4.2, 2.8), palette.innerEar.fade(0.85));
      } else if (!style.tiny && value > 0.25) {
        // A soft paw tip so raised arms read as paws.
        ctx.fill(Shapes.ellipse(Offset(hand.dx - direction.dx * 0.6, hand.dy - direction.dy * 0.6), 4.2, 4.2), palette.light.fade(0.7));
      }
    }
  }

  /// Puffed cheeks: round bulges at the sides of the mouth that stick out past the face outline.
  static void drawCheeks(PetPose pose, GContext ctx, PetPalette palette, PetStyle style) {
    final shift = faceShift(pose, style) * 0.8;
    for (var index = 0; index < 2; index++) {
      final amount = index == 0 ? pose.cheekLeft : pose.cheekRight;
      if (amount <= 0.04) continue;
      final side = index == 0 ? -1.0 : 1.0;
      // Past 0.7 the cheeks balloon into comic hamster cheeks.
      final hamster = Ease.clamp((amount - 0.7) / 0.3);
      final radius = 3.5 + 6 * amount + 4.5 * hamster;
      final center = Offset(side * (16.5 + 6.5 * amount + 2.8 * hamster) + shift, -19.5 + 0.5 * amount - 0.8 * hamster);
      final cheek = Shapes.ellipse(center, radius * 2, radius * 1.85);
      ctx.fillLinear(cheek, [palette.light, palette.body], Offset(center.dx, center.dy - radius), Offset(center.dx, center.dy + radius));
      // Outline only on the outer side, so the bulge melts into the face.
      final rim = Path()..arc(center, radius, degrees(side > 0 ? -80 : 100), degrees(side > 0 ? 95 : 275));
      final squash = Affine.translation(
        -center.dx,
        -center.dy,
      ).concatenating(Affine.scale(1, 0.925)).concatenating(Affine.translation(center.dx, center.dy));
      ctx.stroke(rim.applying(squash), style.outlineColor.fade(math.min(1, amount * 2.5)), style.part);
      ctx.fill(
        Shapes.ellipse(Offset(center.dx - side * radius * 0.15, center.dy + radius * 0.15), radius * 1.15, radius * 0.7),
        palette.blush.fade(math.min(0.9, 0.35 + 0.6 * pose.blush)),
      );
      if (!style.tiny) {
        ctx.fill(
          Shapes.ellipse(Offset(center.dx + side * radius * 0.2, center.dy - radius * 0.45), radius * 0.55, radius * 0.35),
          white.fade(0.55),
        );
      }
    }
  }

  static void drawFace(PetPose pose, GContext ctx, PetPalette palette, PetStyle style) {
    // Glances travel further at menu-bar size so they still read; a head turn slides the face.
    final lookX = Ease.clamp(pose.lookX, -1, 1) * (style.tiny ? 4.6 : 3.2);
    final lookY = Ease.clamp(pose.lookY, -1, 1) * (style.tiny ? 3.0 : 2.4);
    final shift = faceShift(pose, style);
    final blush = Ease.clamp(pose.blush);
    if (blush > 0.02) {
      final boost = style.tiny ? 1.25 : 1.0;
      for (var index = 0; index < 2; index++) {
        final side = index == 0 ? -1.0 : 1.0;
        final puff = index == 0 ? pose.cheekLeft : pose.cheekRight;
        final center = Offset(side * (18 + 3 * puff) + lookX * 0.4 + shift * 0.8, -20.5 + puff);
        ctx.fill(Shapes.ellipse(center, 8.5 * boost, 4.6 * boost), palette.blush.fade(math.min(1, 0.75 * blush * boost)));
        if (blush > 0.92 && !style.tiny) {
          // Anime blush hatching for big moments.
          for (var line = 0; line < 3; line++) {
            final x = center.dx - 2.6 + line * 2.6;
            final hatch = Path()
              ..moveTo(x + 1, center.dy - 1.4)
              ..lineTo(x - 0.6, center.dy + 1.4);
            ctx.stroke(hatch, palette.blush.fade(0.95), 0.9);
          }
        }
      }
    }
    final cross = Ease.clamp(pose.crossEyed);
    for (var index = 0; index < 2; index++) {
      final side = index == 0 ? -1.0 : 1.0;
      final center = Offset(side * 10.5 + lookX * (1 - cross) - side * 2.6 * cross + shift, -29.5 + lookY * (1 - cross) + 1.6 * cross);
      var kind = pose.eyes;
      if (kind == PetEyes.wink) kind = index == 0 ? PetEyes.open : PetEyes.happy;
      drawEye(kind, side, center, pose, ctx, palette, style);
      drawBrow(pose.brows, side, center, ctx, palette, style);
    }
    drawMouth(pose.mouth, Offset(lookX * 0.5 * (1 - cross) + shift * 0.95, -20 + lookY * 0.4), ctx, palette, style);
  }

  static void drawEye(PetEyes kind, double side, Offset center, PetPose pose, GContext ctx, PetPalette palette, PetStyle style) {
    final eye = palette.eye;
    final openness = pose.eyeOpenness;
    final size = Ease.clamp(pose.eyeScale, 0.6, 1.5) * style.eyeBoost;
    final line = style.tiny ? 2.8 : 2.2;
    final cx = center.dx;
    final cy = center.dy;
    switch (kind) {
      case PetEyes.open || PetEyes.wink || PetEyes.worried || PetEyes.wide:
        final wide = kind == PetEyes.wide;
        final width = (wide ? 9 : (kind == PetEyes.worried ? 7.2 : 7.8)) * size;
        final height = (wide ? 12 : (kind == PetEyes.worried ? 9.6 : 10.6)) * size * math.max(0.06, openness);
        if (openness < 0.22) {
          final lid = Path()
            ..moveTo(cx - 3.8 * size, cy + 0.5)
            ..quadraticBezierTo(cx, cy + 1.8, cx + 3.8 * size, cy + 0.5);
          ctx.stroke(lid, eye, line);
          return;
        }
        ctx.fill(Shapes.ellipse(center, width, height), eye);
        final sparkle = Ease.clamp(pose.eyeSparkle);
        if (style.tiny) {
          final r = (wide ? 3.6 : 3.2) * size;
          ctx.fill(Shapes.ellipse(Offset(cx - 1.4 * size, cy - height * 0.2), r, r), palette.eyeHighlight);
          return;
        }
        final highlight = (wide ? 2.4 : 2.0) * size;
        if (sparkle > 0.05) {
          ctx.fill(Shapes.sparkle(Offset(cx - 1.4 * size, cy - height * 0.2), (2.2 + 2.2 * sparkle) * size), palette.eyeHighlight);
          ctx.fill(
            Shapes.sparkle(Offset(cx + 1.8 * size, cy + height * 0.22), (1.2 + 0.9 * sparkle) * size),
            palette.eyeHighlight.fade(0.85),
          );
          ctx.fill(
            Shapes.ellipse(Offset(cx + 1.9 * size, cy - height * 0.3), 1.2 * size, 1.2 * size),
            palette.eyeHighlight.fade(0.8 * sparkle),
          );
        } else {
          ctx.fill(
            Shapes.ellipse(Offset(cx - 1.5 * size, cy - height * 0.24), highlight * 2, highlight * 2),
            palette.eyeHighlight.fade(0.95),
          );
          ctx.fill(Shapes.ellipse(Offset(cx + 1.6 * size, cy + height * 0.22), 1.8 * size, 1.8 * size), palette.eyeHighlight.fade(0.75));
        }
      case PetEyes.closed:
        final arc = Path()
          ..moveTo(cx - 4.2 * size, cy)
          ..quadraticBezierTo(cx, cy + 3.6 * size, cx + 4.2 * size, cy);
        ctx.stroke(arc, eye, line);
      case PetEyes.happy:
        final arc = Path()
          ..moveTo(cx - 4.2 * size, cy + 1.8)
          ..quadraticBezierTo(cx, cy - 4.6 * size, cx + 4.2 * size, cy + 1.8);
        ctx.stroke(arc, eye, style.tiny ? 3 : 2.4);
      case PetEyes.squint:
        // > <
        final inward = -side;
        final mark = Path()
          ..moveTo(cx - inward * 3.6 * size, cy - 3.4 * size)
          ..lineTo(cx + inward * 3.2 * size, cy)
          ..lineTo(cx - inward * 3.6 * size, cy + 3.4 * size);
        ctx.stroke(mark, eye, style.tiny ? 2.8 : 2.2);
      case PetEyes.sleepy:
        // Heavy, drowsy lids that droop towards the outer corners, over the lower part of the eye.
        final outer = Offset(cx + side * 4.4 * size, cy + 1.5 * size);
        final inner = Offset(cx - side * 4.2 * size, cy - 0.2 * size);
        final lid = Path()
          ..moveToPoint(outer)
          ..quadTo(inner, Offset(cx + side * 0.6 * size, cy - 0.6 * size));
        final below = Path.from(lid)
          ..lineTo(inner.dx, cy + 8 * size)
          ..lineTo(outer.dx, cy + 8 * size)
          ..close();
        final lower = ctx.copy()..clip(below);
        lower.fill(Shapes.ellipse(Offset(cx, cy + 1.2), 7.0 * size, 8.4 * size), eye);
        if (!style.tiny) {
          lower.fill(Shapes.ellipse(Offset(cx - 1.2 * size, cy + 2.4 * size), 1.8 * size, 1.4 * size), palette.eyeHighlight.fade(0.8));
        }
        ctx.stroke(lid, eye, style.tiny ? 2.6 : 1.9);
      case PetEyes.dizzy:
        final spiral = Path()
          ..arc(center, 4, degrees(0), degrees(300))
          ..arc(Offset(cx + 0.6, cy), 2, degrees(300), degrees(20));
        ctx.stroke(spiral, eye, style.tiny ? 2.4 : 1.6);
      case PetEyes.heart:
        ctx.fill(Shapes.heart(center, 10 * size), hex(0xFF5A7A));
    }
  }

  static void drawBrow(Brows brows, double side, Offset eye, GContext ctx, PetPalette palette, PetStyle style) {
    if (brows == Brows.none) return;
    final s = side;
    final path = Path();
    switch (brows) {
      case Brows.none:
        return;
      case Brows.worried:
        path
          ..moveTo(eye.dx + s * 4.5, eye.dy - 7.2)
          ..lineTo(eye.dx - s * 3.5, eye.dy - 9.8);
      case Brows.raised:
        path
          ..moveTo(eye.dx - 3.8, eye.dy - 8.6)
          ..quadraticBezierTo(eye.dx, eye.dy - 11.4, eye.dx + 3.8, eye.dy - 8.6);
      case Brows.confused:
        if (side < 0) {
          path
            ..moveTo(eye.dx - 3.8, eye.dy - 9.4)
            ..quadraticBezierTo(eye.dx, eye.dy - 12.4, eye.dx + 3.8, eye.dy - 9.4);
        } else {
          path
            ..moveTo(eye.dx - 3.6, eye.dy - 7.6)
            ..lineTo(eye.dx + 3.6, eye.dy - 7.0);
        }
    }
    ctx.stroke(path, palette.eye.fade(0.85), style.tiny ? 2.4 : 1.6);
  }

  static Path catMouth(Offset c, [double width = 4.2]) => Path()
    ..moveTo(c.dx - width, c.dy - 0.8)
    ..quadraticBezierTo(c.dx - width * 0.52, c.dy + 2.6, c.dx, c.dy - 0.2)
    ..quadraticBezierTo(c.dx + width * 0.52, c.dy + 2.6, c.dx + width, c.dy - 0.8);

  static void drawMouth(PetMouth mouth, Offset c, GContext ctx, PetPalette palette, PetStyle style) {
    final ink = palette.eye;
    final mouthColor = hex(0x7A2E3B);
    final tongue = hex(0xFF8C9B);
    final line = style.ink;
    final x = c.dx;
    final y = c.dy;
    switch (mouth) {
      case PetMouth.cat || PetMouth.nom:
        ctx.stroke(catMouth(c), ink, mouth == PetMouth.nom ? line + 0.5 : line);
        if (mouth == PetMouth.nom && !style.tiny) {
          ctx.fill(Shapes.ellipse(Offset(x - 9, y - 1), 5, 4), palette.light.fade(0.9));
          ctx.fill(Shapes.ellipse(Offset(x + 9, y - 1), 5, 4), palette.light.fade(0.9));
        }
      case PetMouth.smile:
        final path = Path()
          ..moveTo(x - 4.2, y - 1)
          ..quadraticBezierTo(x, y + 3.8, x + 4.2, y - 1);
        ctx.stroke(path, ink, line + 0.1);
      case PetMouth.open || PetMouth.pant:
        final path = Path()
          ..moveTo(x - 4.8, y - 1.6)
          ..quadraticBezierTo(x, y - 2.4, x + 4.8, y - 1.6)
          ..quadraticBezierTo(x, y + 8.6, x - 4.8, y - 1.6);
        ctx.fill(path, mouthColor);
        if (mouth == PetMouth.pant) {
          final lick = Shapes.roundedRect(Rect.fromLTWH(x - 2.2, y + 0.6, 4.8, 6.4), 2.4);
          ctx.fill(lick, tongue);
          ctx.stroke(lick, mouthColor.fade(0.6), 0.6);
        } else {
          ctx.fill(Shapes.ellipse(Offset(x, y + 2.2), 5, 2.8), tongue);
        }
      case PetMouth.chomp:
        final path = Path()
          ..moveTo(x - 5.6, y - 2.2)
          ..quadraticBezierTo(x, y - 3.4, x + 5.6, y - 2.2)
          ..quadraticBezierTo(x, y + 11, x - 5.6, y - 2.2);
        ctx.fill(path, mouthColor);
        ctx.fill(Shapes.ellipse(Offset(x, y + 3.6), 5.6, 3), tongue);
        for (var index = 0; index < 2; index++) {
          final side = index == 0 ? -1.0 : 1.0;
          final fang = Path()
            ..moveTo(x + side * 3.6, y - 2.4)
            ..lineTo(x + side * 1.8, y - 2.4)
            ..lineTo(x + side * 2.8, y + 0.4)
            ..close();
          ctx.fill(fang, white);
        }
      case PetMouth.grin:
        final path = Path()
          ..moveTo(x - 5.4, y - 1.8)
          ..lineTo(x + 5.4, y - 1.8)
          ..quadraticBezierTo(x, y + 9.4, x - 5.4, y - 1.8)
          ..close();
        ctx.fill(path, mouthColor);
        final clipped = ctx.copy()..clip(path);
        clipped.fill(Shapes.ellipse(Offset(x, y + 4.4), 7, 4.6), tongue);
        ctx.stroke(path, mouthColor, 0.8);
      case PetMouth.lick:
        ctx.stroke(catMouth(c), ink, line);
        final lickPath = Path()
          ..moveTo(x + 0.8, y + 0.2)
          ..quadraticBezierTo(x + 5.6, y + 2.8, x + 5.4, y - 2.8)
          ..quadraticBezierTo(x + 2.0, y - 2.4, x + 0.8, y + 0.2);
        ctx.fill(lickPath, tongue);
        ctx.stroke(lickPath, mouthColor.fade(0.5), 0.6);
      case PetMouth.tiny:
        final path = Path()
          ..moveTo(x - 1.8, y)
          ..quadraticBezierTo(x, y + 1.2, x + 1.8, y);
        ctx.stroke(path, ink, line);
      case PetMouth.o:
        ctx.fill(Shapes.ellipse(Offset(x, y + 0.5), 3.6, 4.2), mouthColor);
      case PetMouth.flat:
        final path = Path()
          ..moveTo(x - 3, y)
          ..lineTo(x + 3, y);
        ctx.stroke(path, ink, line);
      case PetMouth.wavy:
        final path = Path()
          ..moveTo(x - 4.5, y + 0.5)
          ..quadraticBezierTo(x - 3, y - 1.6, x - 1.5, y + 0.5)
          ..quadraticBezierTo(x, y + 2.6, x + 1.5, y + 0.5)
          ..quadraticBezierTo(x + 3, y - 1.6, x + 4.5, y + 0.5);
        ctx.stroke(path, ink, line - 0.1);
      case PetMouth.blep:
        // A bigger tongue in the menu bar, so the blep reads at 12 pt.
        final k = style.tiny ? 1.5 : 1.0;
        ctx.fill(Shapes.ellipse(Offset(x + 1.4, y + 2.6 * k), 4.2 * k, 5.2 * k), tongue);
        ctx.stroke(catMouth(c), ink, line);
      case PetMouth.yawn:
        final open = Shapes.ellipse(Offset(x, y + 2.6), 9.4, 11.6);
        ctx.fill(open, mouthColor);
        final inside = ctx.copy()..clip(open);
        inside.fill(Shapes.ellipse(Offset(x, y + 7.6), 7.6, 5.4), tongue);
        ctx.stroke(open, mouthColor, 0.8);
    }
  }
}
