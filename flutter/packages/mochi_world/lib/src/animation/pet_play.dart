// Port of Sources/TamagotchiCore/Animation/PetPlayAnimations.swift. Swift's nested `PetPlay.Prop` and
// `PetPlay.Bubble` are the top-level classes [Prop] and [Bubble].

import 'dart:math' as math;

import '../model/ease.dart';
import '../model/poses.dart';
import 'choreography.dart';
import 'pet_idle_life.dart';
import 'pet_pose_evaluator.dart';

/// A toy's state at a moment (world space).
class Prop {
  Prop({required this.x, required this.y, required this.spin, required this.squash, required this.opacity});

  double x;
  double y;
  double spin;
  double squash;
  double opacity;
}

/// One of the bubbles in the "Bubbles" story.
class Bubble {
  const Bubble({required this.x, required this.top, required this.low, required this.appear, required this.popAt, required this.size});

  final double x;
  final double top;
  final double low;
  final double appear;
  final double popAt;
  final double size;
}

/// Mochi's play stories (≈5 s each). The variant is chosen from the start time, so each press of Play can tell a
/// different story. Props live in world space (body widths from Mochi's home, body heights above the floor) and stay
/// put while Mochi moves around them. Every story starts and ends at home, upright; travel only goes forwards (towards
/// the companion), because the desktop window has almost no room behind Mochi's tail, and airborne props stay below
/// about 1.6 body heights.
abstract final class PetPlay {
  static const double natural = 5.0;
  static const List<String> variants = ['Ball chase', 'Yarn tangle', 'Butterfly', 'Bubbles'];
  static final double k = PetPoseEvaluator.bodyWidthsPerPathUnit;

  static void pose(
    PetPose p, {
    required double t,
    required double d,
    required PoseContext context,
    required int variant,
    required bool lite,
  }) {
    final ft = PetPoseEvaluator.fit(t, natural: natural, d: d);
    if (context.reducedMotion) {
      calm(p, t: ft, variant: variant, lite: lite);
      return;
    }
    switch (variant) {
      case 0:
        ballChase(p, t: ft, context: context, lite: lite);
      case 1:
        yarn(p, t: ft, context: context, lite: lite);
      case 2:
        butterfly(p, t: ft, context: context, lite: lite);
      default:
        bubbles(p, t: ft, context: context, lite: lite);
    }
  }

  // MARK: Shared gestures

  /// Points the eyes at a world-space target (`atWorld`, `by`); with `head` the head turns after them and the chin
  /// lifts for things overhead.
  static void look(PetPose p, double by, {required double atWorld, double strength = 1, double head = 0}) {
    final bx = atWorld;
    final ex = p.x * k;
    final ey = p.y + 0.55;
    final lx = Ease.clamp((bx - ex) / 0.85, -1, 1);
    final ly = Ease.clamp(-(by - ey) / 0.9, -1, 1);
    p.lookX = Ease.lerp(p.lookX, lx, strength);
    p.lookY = Ease.lerp(p.lookY, ly, strength);
    if (!(head > 0)) return;
    final side = p.facing >= 0 ? 1.0 : -1.0;
    final w = head * strength;
    p.headTurn = Ease.lerp(p.headTurn, 0.7 * lx * side, w);
    // Counter-clockwise (chin up) for a right-facing Mochi.
    p.tilt -= 0.17 * math.max(0.0, -ly) * w * side;
    p.scaleY += 0.03 * math.max(0.0, -ly) * w;
  }

  /// Arm value for a bat at `at`: wind up, swipe down through the target, recover.
  static double? batArm(double t, {required double at, double high = 0.8, double rest = 0.08}) {
    final start = at - 0.15;
    if (!(t > start && t < at + 0.32)) return null;
    if (t < at - 0.04) return Choreo.ramp(t, start, at - 0.04, rest, high);
    if (t < at + 0.06) return Choreo.ramp(t, at - 0.04, at + 0.06, high, 0);
    return Choreo.ramp(t, at + 0.06, at + 0.32, 0, rest) + 0.06 * Choreo.bump(t, at + 0.06, at + 0.2);
  }

  /// Arm value for a scoop at `at`: dip under the toy, flick up high, ease down.
  static double? scoopArm(double t, {required double at, required double from}) {
    final rest = from;
    if (!(t > at - 0.16 && t < at + 0.42)) return null;
    if (t < at - 0.07) return Choreo.ramp(t, at - 0.16, at - 0.07, rest, 0);
    if (t < at + 0.05) return Choreo.ramp(t, at - 0.07, at + 0.05, 0, 0.95);
    if (t < at + 0.1) return 0.95;
    return Choreo.ramp(t, at + 0.1, at + 0.42, 0.95, rest);
  }

  /// A ball (or other round prop) with a soft contact shadow on the floor.
  static void addRolling(
    PetPose p,
    EffectKind kind, {
    required double x,
    required double y,
    required double radius,
    required double spin,
    required double squash,
    double opacity = 1,
    double scale = 1,
    double x2 = 0,
    double y2 = 0,
  }) {
    if (!(opacity > 0.01)) return;
    final height = math.max(0.0, y - radius);
    p.addWorld(
      Effect(
        EffectKind.shadow,
        x: x,
        y: 0.01,
        scale: scale * (1 - Ease.clamp(height / 2.2, 0, 0.6)),
        opacity: opacity * (1 - Ease.clamp(height / 2.4, 0, 0.7)),
      ),
    );
    p.addWorld(
      Effect(kind, x: x, y: y + radius * squash * 0.9, scale: scale, opacity: opacity, rotation: spin, stretch: squash, x2: x2, y2: y2),
    );
  }

  // MARK: (a) Ball chase

  static const double ballRadius = 0.12;

  /// Radians of spin per body width rolled.
  static const double ballRoll = 60.0 / 6.5;
  static const double ballRestA = 1.0;
  static const double ballRestB = 1.36;
  static const double headerAt = 3.52;
  static const ({double x, double y}) header = (x: 0.62, y: 1.24);

  /// The ball: rolls in, is pinned, squirts out, is scooped up, bonks Mochi's head and rolls away.
  static Prop ball(double t) {
    const r = ballRadius;
    if (t < 0.8) {
      final x = Ease.lerp(2.6, ballRestA, Ease.outCubic(Choreo.seg(t, 0, 0.8)));
      final y = r + 0.26 * Choreo.hop(t, 0, 0.32) + 0.11 * Choreo.hop(t, 0.32, 0.55) + 0.04 * Choreo.hop(t, 0.55, 0.7);
      final squash = -0.2 * (Choreo.bump(t, 0.29, 0.37) + 0.6 * Choreo.bump(t, 0.52, 0.58));
      return Prop(x: x, y: y, spin: (x - 2.6) * ballRoll, squash: squash, opacity: Choreo.seg(t, 0, 0.12));
    }
    const spinA = (ballRestA - 2.6) * ballRoll;
    if (t < 1.96) {
      final rock = 0.14 * math.sin((t - 0.8) * 7) * math.exp(-(t - 0.8) * 2.2);
      // Squashed flat under the landing paws.
      return Prop(x: ballRestA, y: r, spin: spinA + rock, squash: -0.38 * Choreo.bump(t, 1.8, 1.96), opacity: 1);
    }
    if (t < 2.9) {
      // Squirts out from under the paws and rolls to a stop.
      final x = Ease.lerp(ballRestA, ballRestB, Ease.outCubic(Choreo.seg(t, 1.96, 2.6)));
      final y = r + 0.2 * Choreo.hop(t, 1.96, 2.2) + 0.06 * Choreo.hop(t, 2.2, 2.32);
      final squash = 0.2 * Choreo.bump(t, 1.96, 2.04) - 0.22 * Choreo.bump(t, 2.17, 2.24);
      return Prop(x: x, y: y, spin: spinA + (x - ballRestA) * ballRoll, squash: squash, opacity: 1);
    }
    const spinB = spinA + (ballRestB - ballRestA) * ballRoll;
    if (t < headerAt) {
      // Scooped up, it arcs back over and drops onto Mochi's head.
      final s = Choreo.seg(t, 2.9, headerAt);
      return Prop(
        x: Ease.lerp(ballRestB, header.x, s),
        y: Ease.lerp(r, header.y, s) + 0.68 * Ease.hop(s),
        spin: spinB - 10 * s,
        squash: 0.15 * Choreo.bump(t, 2.9, 3.0),
        opacity: 1,
      );
    }
    if (t < 4.1) {
      // Boing: off the head, up and away to the right.
      final s = Choreo.seg(t, headerAt, 4.1);
      return Prop(
        x: Ease.lerp(header.x, 2.2, s),
        y: Ease.lerp(header.y, r, s) + 0.45 * Ease.hop(s),
        spin: spinB - 10 - 12 * s,
        squash: -0.3 * Choreo.bump(t, headerAt, headerAt + 0.08),
        opacity: 1,
      );
    }
    final x = Ease.lerp(2.2, 3.0, Ease.outCubic(Choreo.seg(t, 4.1, 5.0)));
    final y = r + 0.16 * Choreo.hop(t, 4.12, 4.34) + 0.05 * Choreo.hop(t, 4.34, 4.46);
    return Prop(
      x: x,
      y: y,
      spin: spinB - 22 - (x - 2.2) * ballRoll,
      squash: -0.22 * Choreo.bump(t, 4.1, 4.16),
      opacity: 1 - Choreo.seg(t, 4.4, 4.9),
    );
  }

  static void ballChase(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final g = context.time;
    // Travel (path units, never behind home): pounce, two bounds after the ball, a little shuffle back under it, then
    // the header knocks Mochi back home in a backward roll.
    var x = 0.2 * Choreo.smooth(Choreo.seg(t, 1.4, 1.85));
    x += 0.05 * Choreo.smooth(Choreo.seg(t, 2.12, 2.42)) + 0.05 * Choreo.smooth(Choreo.seg(t, 2.44, 2.74));
    x -= 0.03 * Choreo.smooth(Choreo.seg(t, 3.2, 3.4));
    x = Ease.lerp(x, 0.03, Choreo.smooth(Choreo.seg(t, 3.64, 4.36)));
    p.x = Ease.lerp(x, 0, Choreo.smooth(Choreo.seg(t, 4.62, 4.96)));

    final bound1 = Choreo.hop(t, 2.12, 2.42);
    final bound2 = Choreo.hop(t, 2.44, 2.74);
    final roll = Choreo.seg(t, 3.64, 4.36);
    final crouch = Choreo.window(t, 0.8, 1.42, fade: 0.16);
    final headerCrouch = Choreo.bump(t, 3.26, 3.46);
    final balled = Choreo.window(t, 3.6, 4.4, fade: 0.17);
    final proud = Choreo.window(t, 4.6, 5.0, fade: 0.15);
    final bounding = Choreo.window(t, 2.1, 2.76, fade: 0.08);
    // The butt-wiggle sways the rear at 4 Hz (a lean, so the feet stay planted).
    final wiggle = math.sin(2 * math.pi * 4 * (t - 0.86)) * Choreo.window(t, 0.86, 1.38, fade: 0.1);
    final noseDown = Choreo.ramp(t, 1.62, 1.84, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 1.9, 2.06)));

    p.scaleY -= (0.14 * crouch + 0.08 * headerCrouch + 0.1 * balled - 0.045 * proud) * m;
    p.scaleX += (0.1 * crouch + 0.06 * headerCrouch - 0.06 * balled - 0.02 * proud) * m;
    p.scaleY += 0.07 * Choreo.bump(t, 1.4, 1.6) * m;
    p.rotation = (-0.1 * Choreo.bump(t, 1.38, 1.6) + 0.3 * noseDown + 0.05 * (bound1 + bound2)) * m - 2 * math.pi * Ease.smooth(roll);
    final lift =
        (0.05 * Choreo.hop(t, 0.25, 0.42) +
            0.46 * Choreo.hop(t, 1.4, 1.85) +
            0.1 * (bound1 + bound2) +
            0.16 * Choreo.hop(t, 3.44, 3.74) +
            0.1 * Ease.hop(roll)) *
        m;
    // Ride on the floor while tipped or rolling rather than through it.
    p.y = math.max(lift, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY));
    p.lean = (-0.04 * crouch + 0.06 * wiggle + 0.1 * bounding - 0.03 * headerCrouch + 0.03 * proud) * m;

    // Arms.
    final reach = Choreo.window(t, 1.36, 1.94, fade: 0.13);
    final pin = Choreo.window(t, 1.82, 2.1, fade: 0.09);
    var left = 0.22 * Choreo.bump(t, 0.25, 0.5) + 0.62 * reach - 0.15 * pin + 0.25 * (bound1 + bound2);
    var right = 0.22 * Choreo.bump(t, 0.25, 0.5) + 0.68 * reach - 0.15 * pin + 0.25 * (bound1 + bound2);
    final scoop = scoopArm(t, at: 2.9, from: 0.12);
    if (scoop != null) right = scoop;
    final headerArms = Choreo.window(t, 3.3, 3.8, fade: 0.1);
    left = math.max(left, 0.45 * headerArms);
    right = math.max(right, 0.45 * headerArms);
    p.leftArm = math.max(0.0, left) * (1 - balled) + 0.12 * proud;
    p.rightArm = math.max(0.0, right) * (1 - balled) + 0.12 * proud;
    p.holdFront = 0.85 * balled;
    final stepPhase = 2 * math.pi * 3.4 * (t - 2.12);
    p.step = math.sin(stepPhase) * bounding + 0.6 * math.sin(2 * math.pi * 5 * (t - 3.2)) * Choreo.window(t, 3.2, 3.42, fade: 0.05);
    p.stride = -math.cos(stepPhase) * bounding;

    // Tail.
    p.tailWag =
        (0.8 * math.sin(2 * math.pi * 4 * (t - 0.86) + 1.4) * crouch + 0.9 * math.sin(g * 10) * proud) * m +
        p.tailWag * (1 - crouch) * (1 - proud);
    p.tailLift = 0.45 * crouch + 0.95 * proud + 0.3 * Choreo.window(t, 0.25, 0.8, fade: 0.1) - 0.5 * balled;
    p.tailCurl = -0.8 * bounding + 0.3 * proud + 0.9 * balled;

    if (lite) return;
    final ballProp = ball(t);
    final dizzy = Choreo.window(t, 4.3, 4.66, fade: 0.08);
    p.earPerk =
        Choreo.perk(t, 0.25, 0.55, 0.1, 1.0) -
        0.15 * crouch -
        0.6 * bounding -
        1.0 * balled +
        0.2 * proud +
        0.3 * Choreo.window(t, 2.9, 3.4, fade: 0.1);
    p.earLeft -= 0.3 * bounding + 0.25 * balled;
    p.earRight -= 0.3 * bounding + 0.25 * balled;
    p.eyeScale = 1 + 0.25 * Choreo.window(t, 0.25, 2.1, fade: 0.25) + 0.15 * Choreo.window(t, 2.95, 3.45, fade: 0.1);
    p.eyeSparkle = 0.5 * crouch + 0.8 * proud;
    if (t < 0.25) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.cat;
    } else if (t < 0.8) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.o;
    } else if (t < 1.4) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.tiny;
    } else if (t < 1.85) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.open;
    } else if (t < 2.1) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.o;
    } else if (t < 2.76) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.pant;
    } else if (t < 2.98) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.tiny;
    } else if (t < 3.44) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.o;
    } else if (t < 3.56) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.open;
    } else if (t < 3.66) {
      p.eyes = PetEyes.squint;
      p.mouth = PetMouth.open;
    } else if (t < 4.34) {
      p.eyes = PetEyes.closed;
      p.mouth = PetMouth.o;
    } else if (t < 4.62) {
      p.eyes = PetEyes.dizzy;
      p.mouth = PetMouth.wavy;
    } else {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.smile;
    }
    p.blush = 0.4 + 0.35 * Choreo.seg(t, 3.7, 4.2);
    if (t < 3.6) {
      look(p, atWorld: ballProp.x, ballProp.y, strength: Choreo.smooth(Choreo.seg(t, 0.25, 0.45)), head: 1 - bounding);
    } else if (t < 4.62) {
      p.lookX = 0;
      p.lookY = 0;
      p.headTurn = 0;
    } else {
      // Proud: chest out, chin up, tail high.
      p.lookX = 0.12;
      p.lookY = -0.12;
      p.headTurn = 0.2 * proud;
      p.tilt -= 0.06 * proud;
    }
    p.tilt += 0.1 * math.sin((t - 4.3) * 14) * dizzy;

    // Props and particles.
    addRolling(
      p,
      EffectKind.ball,
      x: ballProp.x,
      y: ballProp.y,
      radius: ballRadius,
      spin: ballProp.spin,
      squash: ballProp.squash,
      opacity: ballProp.opacity,
    );
    if (t > 0.25 && t < 0.85) {
      final pop = Ease.outBack(Choreo.seg(t, 0.25, 0.4), 2.4);
      p.add(Effect(EffectKind.notice, x: 0.3, y: 1.12 + 0.04 * pop, scale: pop, opacity: 1 - Choreo.seg(t, 0.7, 0.85), rotation: 0.25));
    }
    if (t > 1.44 && t < 1.84) {
      PetFX.streak(p, x: -0.42, y: 0.55, angle: 0.3, length: 0.9, amount: 0.75 * Choreo.bump(t, 1.44, 1.84));
    }
    PetFX.dustPuff(p, age: t - 1.84, worldX: 0.2 * k + 0.38, strength: 0.7);
    if (t > 2.84 && t < 3.04) {
      PetFX.streak(p, x: 0.52, y: 0.4, angle: -0.9, length: 0.85, amount: Choreo.bump(t, 2.84, 3.04), side: 1);
    }
    if (t > headerAt - 0.02 && t < headerAt + 0.3) {
      final age = Choreo.seg(t, headerAt - 0.02, headerAt + 0.3);
      p.add(Effect(EffectKind.burst, x: 0.02, y: 1.1, scale: 0.85, opacity: 1 - age, variant: 1, phase: age));
    }
    PetFX.dizzyStars(p, t: t, amount: 0.9 * dizzy, y: 1.08);
  }

  // MARK: (b) Yarn tangle

  static const double yarnRadius = 0.13;
  static const double yarnRoll = 60.0 / 7;

  /// Right, left, right: two bats and a boop that sends it rolling ahead.
  static const List<double> yarnBats = [0.86, 1.36, 1.84];
  static const List<double> yarnStops = [0.62, -0.22, 0.72, 0.95];
  static const double yarnGrab = 2.4;
  static const double yarnRelease = 3.6;
  static const double yarnDrop = 0.42;

  /// The yarn ball on the floor (null while Mochi holds it).
  static Prop? yarnBall(double t) {
    const r = yarnRadius;
    if (t < 0.72) {
      final x = Ease.lerp(2.4, yarnStops[0], Ease.outCubic(Choreo.seg(t, 0, 0.72)));
      return Prop(x: x, y: r, spin: (x - 2.4) * yarnRoll, squash: 0, opacity: Choreo.seg(t, 0, 0.12));
    }
    if (t < yarnGrab) {
      var x = yarnStops[0];
      var hop = 0.0;
      var squash = 0.0;
      for (var index = 0; index < yarnBats.length; index++) {
        final at = yarnBats[index];
        final s = Ease.outCubic(Choreo.seg(t, at + 0.04, at + (index == 2 ? 0.55 : 0.42)));
        if (t > at + 0.04) x = Ease.lerp(yarnStops[index], yarnStops[index + 1], s);
        hop += 0.05 * Choreo.hop(t, at + 0.03, at + 0.2);
        squash -= 0.22 * Choreo.bump(t, at - 0.02, at + 0.06);
      }
      return Prop(x: x, y: r + hop, spin: (x - 2.4) * yarnRoll, squash: squash, opacity: 1);
    }
    if (t < yarnRelease) return null;
    // Dropped in front as Mochi sits up, then (once shaken free) it rolls away off-stage.
    final fall = Choreo.seg(t, yarnRelease, yarnRelease + 0.16);
    final away = Ease.smooth(Choreo.seg(t, 4.5, 5.0));
    final x = Ease.lerp(yarnDrop, 2.6, away);
    final y = r + 0.16 * (1 - fall * fall) + 0.04 * Choreo.hop(t, yarnRelease + 0.16, yarnRelease + 0.3);
    return Prop(
      x: x,
      y: y,
      spin: (x - 2.4) * yarnRoll,
      squash: -0.2 * Choreo.bump(t, yarnRelease + 0.12, yarnRelease + 0.2),
      opacity: 1 - Choreo.seg(t, 4.7, 4.98),
    );
  }

  static void yarn(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final g = context.time;
    final rally = Choreo.window(t, 0.72, 2.0, fade: 0.15);
    final onBack = Choreo.ramp(t, yarnGrab, 2.62, 0, 1) * (1 - Choreo.ramp(t, 3.42, 3.72, 0, 1));
    final kicking = Choreo.window(t, 2.62, 3.42, fade: 0.1);
    final tangled = Choreo.window(t, 3.66, 4.05, fade: 0.1);
    final shaking = Choreo.window(t, 4.0, 4.5, fade: 0.1);
    final content = Choreo.window(t, 4.72, 5.0, fade: 0.12);

    // Shuffle after the yarn, pounce on it, slide back as he flops over, sit up near home.
    var x = 0.04 * Choreo.smooth(Choreo.seg(t, 1.0, 1.9));
    x = Ease.lerp(x, 0.22, Choreo.smooth(Choreo.seg(t, 2.05, 2.4)));
    x = Ease.lerp(x, 0.1, Choreo.smooth(Choreo.seg(t, 2.4, 2.66)));
    x = Ease.lerp(x, 0.04, Choreo.smooth(Choreo.seg(t, 3.42, 3.72)));
    p.x = Ease.lerp(x, 0, Choreo.smooth(Choreo.seg(t, 4.55, 4.95)));

    var lean = 0.0;
    var left = 0.06;
    var right = 0.06;
    for (var index = 0; index < yarnBats.length; index++) {
      final at = yarnBats[index];
      final rightPaw = index % 2 == 0;
      final reachSide = rightPaw ? 1.0 : -1.0;
      lean += reachSide * (0.06 * Choreo.bump(t, at - 0.16, at) - 0.04 * Choreo.bump(t, at, at + 0.28));
      final value = batArm(t, at: at, high: 0.75, rest: 0.06);
      if (value != null) {
        if (rightPaw) {
          right = value;
        } else {
          left = value;
        }
      }
    }
    // Rolling on the back: rocking, bunny-kicking the yarn hugged to the chest.
    final rock = 0.08 * math.sin(2 * math.pi * 2 * (t - 2.62)) * kicking;
    final shake = math.sin(2 * math.pi * 5 * (t - 4.0)) * shaking;
    p.rotation = (-1.25 * onBack + rock) * math.max(m, 0.5) + 0.18 * shake * m - 0.1 * Choreo.bump(t, 2.05, 2.25) * m;
    p.scaleY -= (0.04 * rally + 0.1 * kicking + 0.03 * shake.abs() + 0.03 * content) * m;
    p.scaleX += (0.03 * rally + 0.06 * kicking + 0.05 * shaking) * m;
    final lift = 0.2 * Choreo.hop(t, 2.05, 2.4) * m + 0.03 * Choreo.hop(t, 0.3, 0.48) * m;
    p.y = math.max(lift, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY));
    p.lean = (lean + 0.05 * shake + 0.08 * Choreo.window(t, 1.98, 2.4, fade: 0.1)) * m * (1 - onBack);
    p.holdFront = Choreo.ramp(t, yarnGrab - 0.05, yarnGrab + 0.12, 0, 1) * (1 - Choreo.ramp(t, yarnRelease - 0.1, yarnRelease, 0, 1));
    p.leftArm = left + 0.15 * tangled + 0.5 * Choreo.window(t, 2.0, 2.42, fade: 0.08);
    p.rightArm = right + 0.15 * tangled + 0.5 * Choreo.window(t, 2.0, 2.42, fade: 0.08);
    final bunny = math.sin(2 * math.pi * 3.2 * (t - 2.62));
    p.kick = 0.55 * bunny * kicking;
    p.step = 0.5 * math.sin(2 * math.pi * 2.2 * t) * rally + 0.7 * math.sin(2 * math.pi * 3.2 * (t - 2.62) + 1.4) * kicking;
    p.stride = 0.5 * math.cos(2 * math.pi * 3.2 * (t - 2.62)) * kicking;
    p.tailWag =
        (0.9 * math.sin(2 * math.pi * 2.2 * t) * rally +
            1.4 * math.sin(2 * math.pi * 5 * (t - 4.0) + 1) * shaking +
            0.8 * math.sin(g * 9) * kicking) *
        m;
    p.tailLift = 0.5 * rally - 0.3 * tangled + 0.4 * content;
    p.tailCurl = 0.5 * tangled + 0.6 * content;

    if (lite) return;
    p.earPerk = Choreo.perk(t, 0.3, 0.6, 0.1, 0.85) - 0.5 * tangled - 0.7 * onBack + 0.1 * content;
    if (shaking > 0) {
      p.earLeft += 0.55 * math.sin(2 * math.pi * 5 * (t - 4.0) - 0.8) * shaking;
      p.earRight += 0.55 * math.sin(2 * math.pi * 5 * (t - 4.0) - 0.2) * shaking;
    }
    p.eyeScale = 1 + 0.15 * rally + 0.2 * tangled;
    if (t < 0.3) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.cat;
    } else if (t < 0.72) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.o;
    } else if (t < 2.0) {
      final batting = yarnBats.any((at) => (t - at).abs() < 0.07);
      p.eyes = PetEyes.wide;
      p.mouth = batting ? PetMouth.tiny : PetMouth.grin;
    } else if (t < 2.42) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.open;
    } else if (t < 3.42) {
      p.eyes = PetEyes.happy;
      p.mouth = ((t - 2.42) * 4).toInt().remainder(2) == 0 ? PetMouth.grin : PetMouth.open;
    } else if (t < 3.68) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.o;
    } else if (t < 4.02) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.wavy;
      p.brows = Brows.confused;
    } else if (t < 4.5) {
      p.eyes = PetEyes.squint;
      p.mouth = PetMouth.wavy;
    } else if (t < 4.72) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.smile;
    } else {
      p.eyes = PetEyes.happy;
      p.mouth = PetMouth.cat;
    }
    p.blush = 0.45 + 0.3 * kicking + 0.2 * content;
    final ballProp = yarnBall(t);
    if (ballProp != null && t < 2.42) {
      look(p, atWorld: ballProp.x, ballProp.y, strength: Choreo.seg(t, 0.25, 0.45), head: 0.8);
    } else if (t < 3.42) {
      p.lookX = 0.25;
      p.lookY = 0.35;
    } else if (t < 4.0) {
      // Looks down at the loops round the tummy.
      p.lookX = 0.05 * math.sin(t * 9);
      p.lookY = 0.75;
    } else if (t < 4.5) {
      p.lookX = 0;
      p.lookY = 0;
    } else if (ballProp != null) {
      look(p, atWorld: ballProp.x, ballProp.y, strength: Choreo.window(t, 4.5, 4.9, fade: 0.12), head: 0.6);
    }
    p.tilt += 0.06 * p.lookX * rally - 0.08 * tangled * math.sin(t * 4);

    // The yarn: on the floor, hugged to the chest, dropped, rolling away.
    final anchor = p.bodyPoint(18, -15);
    final caught = Choreo.ramp(t, yarnBats[0], yarnBats[0] + 0.2, 0, 1) * (1 - Choreo.ramp(t, 4.05, 4.25, 0, 1));
    if (ballProp != null) {
      final pet = p.x * k;
      final anchorX = Ease.lerp(ballProp.x + 0.5, pet + anchor.x, caught);
      final anchorY = Ease.lerp(ballProp.y - 0.1, p.y + anchor.y, caught);
      addRolling(
        p,
        EffectKind.yarn,
        x: ballProp.x,
        y: ballProp.y,
        radius: yarnRadius,
        spin: ballProp.spin,
        squash: ballProp.squash,
        opacity: ballProp.opacity,
        x2: anchorX - ballProp.x,
        y2: anchorY - ballProp.y,
      );
    } else {
      // Held between the paws (body space, follows the roll): it wobbles with the kicks.
      final chest = p.bodyPoint(0, -17);
      final grab = Choreo.smooth(Choreo.seg(t, yarnGrab, yarnGrab + 0.12));
      final floorX = yarnStops[3] - p.x * k, floorY = yarnRadius - p.y;
      final hx = Ease.lerp(floorX, chest.x, grab) + 0.02 * bunny * kicking;
      final hy = Ease.lerp(floorY, chest.y, grab) + 0.02 * math.cos(2 * math.pi * 3.2 * (t - 2.62)) * kicking;
      p.add(Effect(EffectKind.yarn, x: hx, y: hy, rotation: (yarnStops[3] - 2.4) * yarnRoll + 3 * (t - yarnGrab)));
      // Its floor shadow fades as it leaves the floor.
      if (grab < 1) p.addWorld(Effect(EffectKind.shadow, x: yarnStops[3], y: 0.01, opacity: 1 - grab));
    }
    // Loops wind round Mochi while he rolls, then fly off in the shake.
    const bands = [2.72, 2.98, 3.24];
    var loops = 0;
    for (final at in bands) {
      if (t > at) loops += 1;
    }
    if (loops > 0 && t < 4.4) {
      final lastBand = bands[loops - 1];
      final flyOff = Choreo.seg(t, 4.08, 4.4);
      final fadeIn = Choreo.seg(t, lastBand, lastBand + 0.08);
      p.add(
        Effect(
          EffectKind.tangle,
          x: 0,
          y: 0.5,
          scale: 1 + 0.6 * flyOff,
          opacity: (1 - flyOff) * (0.35 + 0.65 * fadeIn),
          rotation: 0.3 * math.sin(t * 3) * flyOff,
          variant: loops,
          phase: t,
        ),
      );
    }
    PetFX.dizzyStars(p, t: t, amount: Choreo.window(t, 3.72, 4.0, fade: 0.08), y: 1.12);
    for (var index = 0; index < yarnBats.length; index++) {
      final at = yarnBats[index];
      if (!(t > at - 0.05 && t < at + 0.16)) continue;
      final rightPaw = index % 2 == 0;
      PetFX.streak(
        p,
        x: rightPaw ? 0.42 : -0.42,
        y: 0.32,
        angle: rightPaw ? -1.3 : 1.3 + math.pi,
        length: 0.75,
        amount: Choreo.bump(t, at - 0.05, at + 0.16),
        side: rightPaw ? 0 : 1,
      );
    }
    if (shaking > 0.3) {
      p.add(Effect(EffectKind.shakeLines, x: -0.62, y: 0.5, scale: 0.9, opacity: shaking, variant: 0));
      p.add(Effect(EffectKind.shakeLines, x: 0.62, y: 0.5, scale: 0.9, opacity: shaking, variant: 1));
    }
  }

  // MARK: (c) Butterfly

  static ({double x, double y, double flap, double opacity, double tilt}) butterflyPath(
    double t, {
    required double noseX,
    required double noseY,
  }) {
    final flutterX = 0.07 * math.sin(2 * math.pi * 1.3 * t);
    final flutterY = 0.06 * math.sin(2 * math.pi * 1.9 * t + 0.5);
    final beat = t * 2 * math.pi * 3.5;
    if (t < 1.3) {
      final s = Ease.smooth(Choreo.seg(t, 0, 0.95));
      return (
        x: Ease.lerp(2.0, 0.62, s) + flutterX,
        y: Ease.lerp(1.42, 1.24, s) + flutterY,
        flap: beat,
        opacity: Choreo.seg(t, 0, 0.2),
        tilt: -0.2,
      );
    }
    if (t < 1.6) {
      // Dodges the first clap: up and back.
      final s = Ease.smooth(Choreo.seg(t, 1.3, 1.52));
      return (
        x: Ease.lerp(0.62 + flutterX, 0.08, s),
        y: Ease.lerp(1.24 + flutterY, 1.44, s),
        flap: beat,
        opacity: 1,
        tilt: 0.3 * Choreo.bump(t, 1.3, 1.52),
      );
    }
    if (t < 2.18) {
      // Drifts ahead, leading Mochi on.
      final s = Ease.smooth(Choreo.seg(t, 1.6, 2.1));
      return (
        x: Ease.lerp(0.08, 0.58, s) + flutterX * s,
        y: Ease.lerp(1.44, 1.38, s) + flutterY * s,
        flap: beat,
        opacity: 1,
        tilt: -0.15 * Choreo.bump(t, 1.6, 2.1),
      );
    }
    if (t < 2.8) {
      // Dodges the second clap, then hovers.
      final s = Ease.smooth(Choreo.seg(t, 2.18, 2.4));
      final hover = Choreo.seg(t, 2.4, 2.8);
      return (
        x: Ease.lerp(0.58 + flutterX, -0.05, s) + flutterX * hover,
        y: Ease.lerp(1.38 + flutterY, 1.46, s) + flutterY * hover,
        flap: beat,
        opacity: 1,
        tilt: 0.3 * Choreo.bump(t, 2.18, 2.4),
      );
    }
    if (t < 3.3) {
      // Spirals down onto Mochi's nose and folds its wings.
      final s = Ease.smooth(Choreo.seg(t, 2.8, 3.3));
      final spiral = 0.18 * math.sin(2 * math.pi * 1.6 * (t - 2.8)) * (1 - s);
      final settle = 1 - Choreo.seg(t, 3.05, 3.3);
      return (
        x: Ease.lerp(-0.05 + flutterX, noseX, s) + spiral,
        y: Ease.lerp(1.46 + flutterY, noseY, s),
        flap: beat * settle + 1.2 * (1 - settle),
        opacity: 1,
        tilt: 0,
      );
    }
    if (t < 3.95) {
      // Resting on the nose, wings slowly opening and closing.
      return (x: noseX, y: noseY, flap: 1.2 + 1.1 * math.sin(2 * math.pi * 1.4 * (t - 3.3)), opacity: 1, tilt: 0);
    }
    // Blown off by the sneeze, it flutters away up and to the right.
    final lift = Ease.outCubic(Choreo.seg(t, 3.95, 4.75));
    return (
      x: Ease.lerp(noseX, 1.75, lift) + 0.08 * math.sin(2 * math.pi * 2.2 * t) * lift,
      y: Ease.lerp(noseY, 1.45, lift) + 0.05 * math.sin(2 * math.pi * 3 * t) * lift,
      flap: t * 2 * math.pi * 4.2,
      opacity: 1 - Choreo.seg(t, 4.4, 4.85),
      tilt: -0.3 * Choreo.bump(t, 3.95, 4.4),
    );
  }

  static const List<double> claps = [1.33, 2.2];

  static void butterfly(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final g = context.time;
    // A hop and a clap, a skip after it, another hop and clap, then it lands on his nose.
    final hop1 = Choreo.hop(t, 1.12, 1.55);
    final skip = Choreo.hop(t, 1.62, 1.92);
    final hop2 = Choreo.hop(t, 1.98, 2.42);
    final back = Choreo.smooth(Choreo.seg(t, 4.35, 4.95));
    p.x = 0.12 * Choreo.smooth(Choreo.seg(t, 1.62, 1.92)) * (1 - back);
    p.y = (0.38 * hop1 + 0.07 * skip + 0.42 * hop2 + 0.03 * Choreo.hop(t, 4.45, 4.62) + 0.03 * Choreo.hop(t, 4.66, 4.83)) * m;
    final crouch1 = Choreo.bump(t, 0.98, 1.14);
    final crouch2 = Choreo.bump(t, 1.86, 2.0);
    final inhale = Choreo.window(t, 3.55, 3.9, fade: 0.25);
    final sneeze = Choreo.bump(t, 3.87, 4.12);
    final deflated = Choreo.window(t, 2.42, 2.85, fade: 0.12);
    p.scaleY -= (0.11 * crouch1 + 0.12 * crouch2 - 0.06 * inhale + 0.16 * sneeze + 0.04 * deflated) * m;
    p.scaleX += (0.08 * crouch1 + 0.09 * crouch2 - 0.03 * inhale + 0.12 * sneeze) * m;
    p.lean =
        (0.03 * Choreo.window(t, 0.2, 1.0, fade: 0.3) +
            0.06 * Choreo.window(t, 1.58, 1.96, fade: 0.1) -
            0.04 * deflated -
            0.04 * inhale +
            0.12 * sneeze -
            0.03 * Choreo.window(t, 4.35, 4.95, fade: 0.15)) *
        m;
    p.rotation = (0.05 * Choreo.bump(t, 1.12, 1.55) - 0.06 * Choreo.bump(t, 1.98, 2.42)) * m;
    final reach1 = Choreo.window(t, 1.08, 1.6, fade: 0.1);
    final reach2 = Choreo.window(t, 1.94, 2.46, fade: 0.1);
    final reach = math.max(reach1, reach2);
    final clap = Choreo.bump(t, 1.27, 1.39) + Choreo.bump(t, 2.14, 2.26);
    p.leftArm = 0.95 * reach * (1 - 0.18 * clap);
    p.rightArm = 0.95 * reach * (1 - 0.18 * clap);
    // Waving goodbye while backing home.
    final bye = Choreo.window(t, 4.4, 5.0, fade: 0.14);
    final byeWave = math.sin(2 * math.pi * 2.6 * (t - 4.5)) * Choreo.window(t, 4.5, 4.92, fade: 0.08);
    p.rightArm = math.max(p.rightArm, 0.82 * bye + 0.12 * byeWave);
    p.step = 0.6 * math.sin(2 * math.pi * 3 * (t - 4.4)) * Choreo.window(t, 4.4, 4.95, fade: 0.08);
    p.tailWag = (0.7 * math.sin(2 * math.pi * 1.5 * t) * Choreo.window(t, 0, 2.8, fade: 0.3) + 0.5 * math.sin(g * 9) * bye) * m;
    p.tailLift = 0.5 * Choreo.window(t, 0.2, 2.6, fade: 0.3) + 0.4 * bye - 0.3 * deflated;
    p.tailCurl = 0.3;

    if (lite) return;
    final nose = p.mouthPoint;
    final noseX = p.x * k + nose.x + 0.02;
    final noseY = p.y + nose.y + 0.06;
    final fly = butterflyPath(t, noseX: noseX, noseY: noseY);
    final landed = Choreo.ramp(t, 2.95, 3.3, 0, 1) * (1 - Choreo.ramp(t, 3.95, 4.15, 0, 1));
    final still = Choreo.window(t, 2.95, 3.9, fade: 0.2);
    p.earPerk = 0.9 * Choreo.window(t, 0.15, 2.42, fade: 0.2) + 1.0 * still - 0.5 * deflated;
    if (sneeze > 0.05) {
      p.earLeft -= 0.45 * sneeze;
      p.earRight += 0.45 * sneeze;
    }
    if (t > 3.4 && t < 3.7) p.earRight += PetLife.flick(t - 3.42);
    p.crossEyed = Choreo.ramp(t, 2.95, 3.25, 0, 1) * (1 - Choreo.ramp(t, 3.86, 3.92, 0, 1));
    p.eyeScale = 1 + 0.15 * Choreo.window(t, 0.2, 2.42, fade: 0.2) - 0.25 * inhale;
    if (t < 0.2) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.cat;
    } else if (t < 1.08) {
      p.eyes = PetEyes.wide;
      p.mouth = t < 0.6 ? PetMouth.o : PetMouth.smile;
    } else if (t < 1.55) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.open;
    } else if (t < 1.98) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.grin;
    } else if (t < 2.42) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.open;
    } else if (t < 2.85) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.wavy;
    } else if (t < 3.5) {
      p.eyes = PetEyes.wide;
      p.mouth = (t * 8).toInt().remainder(2) == 0 && t > 3.3 ? PetMouth.cat : PetMouth.tiny;
    } else if (t < 3.88) {
      p.eyes = t > 3.75 ? PetEyes.squint : PetEyes.open;
      p.mouth = PetMouth.o;
    } else if (t < 4.12) {
      p.eyes = PetEyes.squint;
      p.mouth = PetMouth.chomp;
    } else if (t < 4.3) {
      p.eyes = PetEyes.squint;
      p.mouth = PetMouth.wavy;
    } else if (t < 4.42) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.wavy;
    } else {
      p.eyes = PetEyes.happy;
      p.mouth = PetMouth.smile;
    }
    if (t < 2.95 || t > 4.3) {
      look(p, atWorld: fly.x, fly.y, strength: Choreo.seg(t, 0.15, 0.35) * (t > 4.75 ? 1 - Choreo.seg(t, 4.75, 5.0) : 1), head: 0.9);
    } else {
      p.lookX = 0.02 + 0.03 * math.sin(t * 13) * still;
      p.lookY = 0.1;
      p.headTurn = 0;
    }
    p.tilt += -0.09 * inhale + 0.05 * math.sin((t - 4.3) * 24) * Choreo.window(t, 4.3, 4.6, fade: 0.06);
    p.blush = 0.45 + 0.3 * still;

    if (fly.opacity > 0.01) {
      p.addWorld(
        Effect(
          EffectKind.butterfly,
          x: fly.x,
          y: fly.y,
          scale: 0.95 - 0.33 * landed,
          opacity: fly.opacity,
          rotation: fly.tilt,
          variant: 0,
          phase: fly.flap,
        ),
      );
    }
    for (final at in claps) {
      if (!(t > at && t < at + 0.3)) continue;
      final age = (t - at) / 0.3;
      p.add(Effect(EffectKind.burst, x: 0.04, y: 1.3, scale: 0.65, opacity: 1 - age, variant: 1, phase: age));
    }
    if (t > 3.88 && t < 4.4) {
      final age = Choreo.seg(t, 3.88, 4.4);
      p.add(Effect(EffectKind.sneeze, x: nose.x + 0.14, y: nose.y + 0.03, scale: 0.9, opacity: 1 - age * age, phase: age));
    }
    if (t > 3.5 && t < 3.88) {
      // The tickle builds at the nose.
      p.add(
        Effect(
          EffectKind.sniff,
          x: nose.x + 0.14,
          y: nose.y + 0.03,
          scale: 0.75,
          opacity: Choreo.window(t, 3.5, 3.88, fade: 0.08),
          variant: (t * 7).toInt().remainder(2),
          phase: Ease.fract(t * 3.5),
        ),
      );
    }
  }

  // MARK: (d) Bubbles

  /// A bat-pop, a clap-pop at the top of a hop, a nose boop, and one big bubble that swallows Mochi's head.
  static const List<Bubble> bubbleSet = [
    Bubble(x: 0.66, top: 1.45, low: 0.72, appear: 0.0, popAt: 0.98, size: 1),
    Bubble(x: 0.44, top: 1.48, low: 1.24, appear: 0.25, popAt: 1.5, size: 0.9),
    Bubble(x: 0.9, top: 1.45, low: 0.5, appear: 0.9, popAt: 2.3, size: 0.8),
    Bubble(x: 0.65, top: 1.45, low: 0.62, appear: 1.9, popAt: 3.66, size: 1),
  ];
  static const double engulfAt = 3.2;

  static ({double x, double y, double opacity, double scale}) bubblePosition(
    int index,
    double t, {
    required (double, double) nose,
    required (double, double) head,
  }) {
    final b = bubbleSet[index];
    final life = Choreo.seg(t, b.appear, b.popAt);
    final fade = Choreo.seg(t, b.appear, b.appear + 0.3);
    var x = b.x + 0.07 * math.sin(2 * math.pi * 0.9 * t + index.toDouble());
    var y = Ease.lerp(b.top, b.low, Ease.outCubic(life)) + 0.04 * math.sin(2 * math.pi * 1.3 * t + index.toDouble() * 2);
    var scale = b.size;
    if (index == 2) {
      // Drifts down onto the nose for a boop.
      final land = Ease.smooth(Choreo.seg(t, 1.7, 2.3));
      x = Ease.lerp(x, nose.$1 + 0.06, land);
      y = Ease.lerp(y, nose.$2 + 0.04, land);
    }
    if (index == 3) {
      // The big one: swells as it sinks, then settles over the head.
      scale = 1 + 2.4 * Ease.smooth(Choreo.seg(t, 2.3, engulfAt));
      final land = Ease.smooth(Choreo.seg(t, 2.6, engulfAt));
      x = Ease.lerp(x, head.$1, land);
      y = Ease.lerp(y, head.$2, land);
    }
    return (x: x, y: y, opacity: fade, scale: scale);
  }

  static void bubbles(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final g = context.time;
    final hop = Choreo.hop(t, 1.2, 1.62);
    final inside = Choreo.window(t, engulfAt - 0.1, 3.68, fade: 0.15);
    final shaking = Choreo.window(t, 3.72, 4.3, fade: 0.1);
    final fluffed = Choreo.window(t, 4.28, 5.0, fade: 0.15);
    final wobble = math.sin(2 * math.pi * 5 * (t - 3.72)) * shaking;
    p.x = 0.1 * Choreo.smooth(Choreo.seg(t, 1.15, 1.55)) * (1 - Choreo.smooth(Choreo.seg(t, 4.4, 4.95)));
    p.rotation = (0.04 * Choreo.bump(t, 0.75, 1.15) - 0.05 * Choreo.bump(t, 1.2, 1.62)) * m + 0.18 * wobble * m;
    final crouch = Choreo.bump(t, 1.04, 1.22);
    final boop = Choreo.bump(t, 2.2, 2.4);
    final squish = Choreo.bump(t, 3.1, 3.3);
    p.scaleY -= (0.1 * crouch + 0.05 * boop + 0.06 * squish + 0.03 * wobble.abs()) * m;
    p.scaleX += (0.08 * crouch + 0.04 * squish + 0.05 * shaking + 0.06 * fluffed) * m;
    final lift = (0.34 * hop + 0.03 * Choreo.hop(t, 4.5, 4.66) + 0.03 * Choreo.hop(t, 4.7, 4.86)) * m;
    p.y = math.max(lift, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY));
    p.lean = (0.05 * Choreo.window(t, 0.6, 1.1, fade: 0.15) + 0.08 * boop + 0.05 * wobble) * m;
    var right = 0.08;
    final bat = batArm(t, at: 0.98, high: 0.95, rest: 0.08);
    if (bat != null) right = bat;
    final clapUp = Choreo.window(t, 1.16, 1.66, fade: 0.1);
    final clap = Choreo.bump(t, 1.44, 1.56);
    p.rightArm = math.max(right, 0.95 * clapUp * (1 - 0.18 * clap));
    p.leftArm = math.max(0.08, 0.95 * clapUp * (1 - 0.18 * clap)) + 0.25 * inside;
    p.rightArm += 0.25 * inside;
    p.step = 0.6 * math.sin(2 * math.pi * 3 * (t - 4.4)) * Choreo.window(t, 4.4, 4.95, fade: 0.08);
    p.tailWag =
        (0.6 * math.sin(2 * math.pi * 1.6 * t) * (1 - inside) +
            1.4 * math.sin(2 * math.pi * 5 * (t - 3.72) + 1.2) * shaking +
            0.6 * math.sin(g * 9) * fluffed) *
        m;
    p.tailLift = 0.4 + 0.3 * fluffed - 0.4 * inside;
    p.tailCurl = 0.5 * inside;

    if (lite) return;
    final nosePoint = p.mouthPoint;
    final nose = (p.x * k + nosePoint.x, p.y + nosePoint.y);
    final headPoint = p.bodyPoint(0, -30);
    final head = (p.x * k + headPoint.x, p.y + headPoint.y);
    p.crossEyed = 0.8 * Choreo.window(t, 2.12, 2.38, fade: 0.06);
    p.earPerk = 0.75 - 0.9 * inside - 0.2 * shaking + 0.2 * Choreo.window(t, 2.5, 3.1, fade: 0.15);
    p.eyeScale = 1 + 0.15 * Choreo.window(t, 0.1, 2.4, fade: 0.2) + 0.3 * Choreo.window(t, 2.6, 3.66, fade: 0.15);
    p.cheekLeft = 0.6 * inside;
    p.cheekRight = 0.6 * inside;
    if (shaking > 0) {
      p.earLeft += 0.6 * math.sin(2 * math.pi * 5 * (t - 3.72) - 0.8) * shaking;
      p.earRight += 0.6 * math.sin(2 * math.pi * 5 * (t - 3.72) - 0.2) * shaking;
    }
    if (t < 0.15) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.cat;
    } else if (t < 0.9) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.o;
    } else if (t < 1.05) {
      p.eyes = PetEyes.squint;
      p.mouth = PetMouth.grin;
    } else if (t < 1.44) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.open;
    } else if (t < 1.62) {
      p.eyes = PetEyes.squint;
      p.mouth = PetMouth.grin;
    } else if (t < 2.24) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.smile;
    } else if (t < 2.4) {
      p.eyes = PetEyes.squint;
      p.mouth = PetMouth.tiny;
    } else if (t < 2.6) {
      p.eyes = PetEyes.happy;
      p.mouth = PetMouth.smile;
    } else if (t < 3.66) {
      p.eyes = PetEyes.wide;
      p.mouth = t < engulfAt ? PetMouth.o : PetMouth.tiny;
    } else if (t < 3.74) {
      p.eyes = PetEyes.squint;
      p.mouth = PetMouth.o;
    } else if (t < 4.3) {
      p.eyes = PetEyes.squint;
      p.mouth = PetMouth.wavy;
    } else {
      p.eyes = PetEyes.happy;
      p.mouth = t < 4.6 ? PetMouth.grin : PetMouth.smile;
    }
    p.blush = 0.45 + 0.35 * Choreo.seg(t, 3.7, 4.3);

    // Look at the next bubble that is still floating.
    (double, double)? target;
    for (var index = 0; index < bubbleSet.length; index++) {
      if (!(t < bubbleSet[index].popAt && t > bubbleSet[index].appear)) continue;
      final b = bubblePosition(index, t, nose: nose, head: head);
      target = (b.x, b.y);
      break;
    }
    if (target != null && t < 3.05) {
      look(p, atWorld: target.$1, target.$2, strength: Choreo.seg(t, 0.1, 0.3), head: 0.8);
    } else if (t < 3.7) {
      p.lookX = 0.03;
      p.lookY = -0.2;
    }

    for (var index = 0; index < bubbleSet.length; index++) {
      final b = bubbleSet[index];
      if (t > b.appear && t < b.popAt) {
        final pos = bubblePosition(index, t, nose: nose, head: head);
        final wob = index == 3 ? t * 5 : t * 3 + index.toDouble();
        p.addWorld(
          Effect(EffectKind.bubble, x: pos.x, y: pos.y, scale: pos.scale, opacity: pos.opacity * (index == 3 ? 0.9 : 1), phase: wob),
        );
      } else if (t >= b.popAt && t < b.popAt + 0.35) {
        final pos = bubblePosition(index, b.popAt - 0.001, nose: nose, head: head);
        final age = (t - b.popAt) / 0.35;
        p.addWorld(Effect(EffectKind.pop, x: pos.x, y: pos.y, scale: index == 3 ? 1.8 : 0.9, opacity: 1 - age, variant: 1, phase: age));
      }
    }
    final batAmount = Choreo.bump(t, 0.92, 1.1);
    if (batAmount > 0.02) PetFX.streak(p, x: 0.45, y: 0.8, angle: -1.1, length: 0.7, amount: batAmount);
    // Soaked by the big pop: a shake with flying droplets.
    for (var index = 0; index < 6; index++) {
      final side = index % 2 == 0 ? -1.0 : 1.0;
      PetFX.ballistic(
        p,
        kind: EffectKind.droplet,
        t: t,
        born: 3.66 + index.toDouble() * 0.09,
        fromX: p.x * k + side * 0.4,
        fromY: 0.7 + 0.1 * (index % 3).toDouble(),
        side: side,
        speed: 0.8 + 0.4 * Ease.hash(index, context.seed),
        up: 0.8,
        seed: index,
        scale: 0.34,
        life: 0.5,
        spin: 0,
      );
    }
    if (shaking > 0.3) {
      p.add(Effect(EffectKind.shakeLines, x: -0.62, y: 0.5, scale: 0.9, opacity: shaking, variant: 0));
      p.add(Effect(EffectKind.shakeLines, x: 0.62, y: 0.5, scale: 0.9, opacity: shaking, variant: 1));
    }
  }

  // MARK: Reduced motion

  /// Calm play: Mochi stays home, the toy fades in and out, and each story keeps its own little beat with expressions
  /// only (a notice, a tangle, a cross-eyed sneeze, a bubble on the nose).
  static void calm(PetPose p, {required double t, required int variant, required bool lite}) {
    if (lite) return;
    final present = Choreo.window(t, 0.2, 4.6, fade: 0.4);
    p.earPerk = 0.2 + 0.7 * present;
    p.eyes = t < 1.2 ? PetEyes.wide : PetEyes.happy;
    p.eyeSparkle = 0.6 * Choreo.window(t, 0.3, 1.4, fade: 0.2);
    p.mouth = t < 1.2 ? PetMouth.o : (t < 4.4 ? PetMouth.grin : PetMouth.smile);
    p.blush = 0.4 + 0.35 * Choreo.seg(t, 1.0, 1.6);
    p.lookX = 0.7;
    p.lookY = 0.3;
    p.rightArm = 0.3 * Choreo.window(t, 1.4, 3.6, fade: 0.5);
    switch (variant) {
      case 0:
        p.addWorld(Effect(EffectKind.shadow, x: 0.85, y: 0.01, scale: 1, opacity: present));
        p.addWorld(Effect(EffectKind.ball, x: 0.85, y: ballRadius, opacity: present));
        p.add(Effect(EffectKind.notice, x: 0.3, y: 1.14, opacity: Choreo.window(t, 0.3, 1.1, fade: 0.25), rotation: 0.25));
      case 1:
        p.addWorld(Effect(EffectKind.shadow, x: 0.85, y: 0.01, scale: 1, opacity: present));
        p.addWorld(Effect(EffectKind.yarn, x: 0.85, y: yarnRadius, opacity: present, x2: -0.7, y2: 0.2));
        // Wound up in the strand for a moment, puzzled, then free.
        final wound = Choreo.window(t, 1.6, 3.4, fade: 0.4);
        p.add(Effect(EffectKind.tangle, x: 0, y: 0.5, opacity: wound, variant: 2));
        if (wound > 0.5) {
          p.eyes = PetEyes.wide;
          p.mouth = PetMouth.wavy;
          p.brows = Brows.confused;
          p.lookY = 0.7;
          p.lookX = 0;
        }
      case 2:
        // The butterfly visits, then rests on the nose: cross-eyed, a squinting sneeze, gone.
        final away = Choreo.window(t, 0.2, 1.9, fade: 0.35);
        final onNose = Choreo.window(t, 1.9, 3.9, fade: 0.35);
        p.lookY = -0.4 * away;
        p.addWorld(Effect(EffectKind.butterfly, x: 0.75, y: 1.45, scale: 0.9, opacity: away, phase: 1.4));
        p.addWorld(Effect(EffectKind.butterfly, x: 0.16, y: 0.48, scale: 0.62, opacity: onNose, phase: 1.2));
        p.crossEyed = onNose;
        if (onNose > 0.2) {
          p.lookX = 0;
          p.lookY = 0.1;
          p.mouth = PetMouth.tiny;
          p.eyes = PetEyes.wide;
        }
        if (t > 3.45 && t < 3.95) {
          p.eyes = PetEyes.squint;
          p.mouth = PetMouth.chomp;
          p.crossEyed = 0;
        }
      default:
        // A bubble drifts by, then one rests on the nose and fades with a blink.
        p.lookY = -0.3;
        p.addWorld(Effect(EffectKind.bubble, x: 0.7, y: 1.3, opacity: Choreo.window(t, 0.2, 2.2, fade: 0.4), phase: 0));
        final onNose = Choreo.window(t, 2.2, 3.8, fade: 0.4);
        p.addWorld(Effect(EffectKind.bubble, x: 0.2, y: 0.46, scale: 0.6, opacity: onNose, phase: 1));
        p.crossEyed = 0.8 * onNose;
        if (onNose > 0.3) {
          p.lookX = 0;
          p.lookY = 0.1;
          p.eyes = PetEyes.wide;
        }
        p.eyeOpenness = math.min(p.eyeOpenness, 1 - 0.95 * PetLife.blinkShape(t - 3.75));
    }
    if (t > 4.0) {
      PetFX.hearts(p, t: t - 4.0, x: 0.25, y: 1.05, count: 1, spacing: 0.8, reduced: true);
    }
  }
}
