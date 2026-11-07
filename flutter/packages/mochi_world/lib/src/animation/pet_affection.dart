// Port of Sources/TamagotchiCore/Animation/PetAffectionAnimations.swift.

import 'dart:math' as math;

import '../model/ease.dart';
import '../model/poses.dart';
import 'choreography.dart';
import 'pet_idle_life.dart';
import 'pet_pose_evaluator.dart';

/// Being petted (≈3.2 s), three different moods: melting under the hand with a purr, flopping over for a belly rub
/// with paws kneading the air, or pushing the chin up into a scratch with sleepy eyes and a thumping foot. Each ends
/// with its own satisfied blep and returns to an upright rest.
abstract final class PetAffection {
  static const double natural = 3.2;
  static const List<String> variants = ['Melt and purr', 'Roll over', 'Chin scratch'];

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
        melt(p, t: ft, context: context, lite: lite);
      case 1:
        rollOver(p, t: ft, context: context, lite: lite);
      default:
        chinScratch(p, t: ft, context: context, lite: lite);
    }
  }

  static void purrLines(PetPose p, {required double t, required double amount}) {
    if (!(amount > 0.05)) return;
    p.add(Effect(EffectKind.purr, x: -0.6, y: 0.45, scale: 0.9, opacity: amount, variant: 0, phase: t));
    p.add(Effect(EffectKind.purr, x: 0.6, y: 0.45, scale: 0.9, opacity: amount, variant: 1, phase: t));
  }

  // MARK: (a) Melt and purr

  static void melt(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final press = Choreo.window(t, 0, 2.45, fade: 0.25);
    final strokes = Choreo.window(t, 0.3, 2.4, fade: 0.3);
    final stroke = math.sin(2 * math.pi * 0.95 * (t - 0.3));
    final purr = Choreo.window(t, 0.35, 2.4, fade: 0.25);
    p.lean = 0.08 * stroke * strokes * m;
    p.scaleY -= (0.1 * press + 0.035 * stroke.abs() * strokes) * m;
    p.scaleX += (0.08 * press + 0.025 * stroke.abs() * strokes) * m;
    final bounceBack = Choreo.bump(t, 2.45, 2.75);
    p.scaleY += 0.06 * bounceBack * m;
    p.scaleX -= 0.04 * bounceBack * m;
    p.tailWag = 0.5 * math.sin(2 * math.pi * 0.95 * t) * m;
    p.tailCurl = 0.9;
    p.tailLift = 0.2;
    p.leftArm = 0.06 + 0.06 * strokes;
    p.rightArm = 0.06 + 0.06 * strokes;
    if (lite) return;
    // Ears flatten under the hand, then perk back up one after the other.
    final leftUp = Choreo.rampBack(t, 2.4, 2.62, 0, 1, overshoot: 2.4);
    final rightUp = Choreo.rampBack(t, 2.52, 2.74, 0, 1, overshoot: 2.4);
    p.earPerk = Ease.lerp(-1.3, 0.3, Choreo.seg(t, 2.4, 2.75)) * Choreo.seg(t, 0, 0.2) + (1 - Choreo.seg(t, 0, 0.2)) * p.earPerk;
    p.earLeft += -0.25 * press + 0.18 * (1 - leftUp) * Choreo.seg(t, 2.35, 2.5) - 0.15 * leftUp + 0.15 * Choreo.seg(t, 2.62, 2.9);
    p.earRight += 0.25 * press - 0.18 * (1 - rightUp) * Choreo.seg(t, 2.47, 2.6) + 0.15 * rightUp - 0.15 * Choreo.seg(t, 2.74, 3.0);
    p.eyes = t < 2.5 ? PetEyes.happy : (t < 2.82 ? PetEyes.open : PetEyes.happy);
    if (t >= 2.5 && t < 2.82) p.eyeOpenness = 1;
    p.eyeSparkle = Choreo.window(t, 2.5, 2.85, fade: 0.08);
    p.mouth = t < 0.9 ? PetMouth.cat : (t < 2.45 ? PetMouth.smile : (t < 2.8 ? PetMouth.o : PetMouth.blep));
    p.blush = 0.45 + 0.5 * Choreo.seg(t, 0.1, 0.8);
    p.lookX = 0;
    p.lookY = 0;
    p.headTurn = 0;
    p.tilt = 0.06 * stroke * strokes;
    purrLines(p, t: t, amount: purr);
    PetFX.hearts(p, t: t - 0.4, x: 0.18, y: 1.05, count: 3, spacing: 0.55, reduced: false, pop: true, life: 0.85);
  }

  // MARK: (b) Roll over

  static void rollOver(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final g = context.time;
    // A quick squash and a flop straight onto the back, belly up, paws kneading the air.
    final flopSquash = Choreo.bump(t, 0, 0.16);
    final over = Choreo.ramp(t, 0.12, 0.5, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 2.2, 2.58)));
    final belly = Choreo.window(t, 0.42, 2.3, fade: 0.12);
    final rock = 0.08 * math.sin(2 * math.pi * 2 * (t - 0.5)) * belly;
    p.rotation = (-1.3 * over + rock) * math.max(m, 0.5);
    // On its back the body's own x axis points up: squash that way, flat against the floor.
    p.scaleY -= 0.08 * flopSquash * m;
    p.scaleX += 0.06 * flopSquash * m - 0.1 * belly * m;
    p.scaleY += 0.05 * belly * m;
    p.y = math.max(0.08 * Choreo.hop(t, 2.42, 2.72) * m, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY));
    final knead = math.sin(2 * math.pi * 3 * (t - 0.5));
    p.leftArm = (0.75 + 0.15 * knead) * belly;
    p.rightArm = (0.75 - 0.15 * knead) * belly;
    // Hind paws paddle happily.
    p.step = math.sin(2 * math.pi * 2.6 * t) * belly;
    p.stride = math.cos(2 * math.pi * 2.6 * t) * 0.6 * belly;
    p.tailWag = (0.5 * math.sin(t * 6) + 1.0 * math.sin(g * 11) * belly) * m;
    p.tailCurl = 0.6;
    if (lite) return;
    p.earPerk = -0.7 * belly + 0.3 * Choreo.seg(t, 2.55, 2.9);
    p.earLeft += 0.15 * math.sin(2 * math.pi * 2 * (t - 0.5)) * belly;
    p.earRight -= 0.15 * math.sin(2 * math.pi * 2 * (t - 0.5) + 0.6) * belly;
    // Open, adoring eyes up at the hand (no purr: this one is a wriggly giggle).
    if (t < 0.42) {
      p.eyes = PetEyes.wide;
      p.mouth = PetMouth.o;
    } else if (t < 2.3) {
      p.eyes = PetEyes.open;
      p.mouth = ((t - 0.42) * 3).toInt().remainder(3) == 2 ? PetMouth.open : PetMouth.grin;
    } else if (t < 2.7) {
      p.eyes = PetEyes.open;
      p.mouth = PetMouth.open;
    } else {
      p.eyes = PetEyes.wink;
      p.mouth = PetMouth.blep;
    }
    p.eyeSparkle = 0.9 * belly;
    p.eyeScale = 1 + 0.12 * belly;
    p.blush = 0.5 + 0.45 * Choreo.seg(t, 0.1, 0.9);
    p.lookX = -0.15;
    p.lookY = -0.55 * belly;
    p.headTurn = -0.2 * belly;
    PetFX.hearts(p, t: t - 0.7, x: 0.0, y: 0.95, count: 3, spacing: 0.4, reduced: false, pop: true, life: 0.8);
  }

  // MARK: (c) Chin scratch with a happy foot thump

  static const double thumpRate = 4.0;

  static void chinScratch(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    // The chin pushes up into the hand: a long stretch, head tipped back, sleepy eyes.
    final up = Choreo.window(t, 0, 2.45, fade: 0.28);
    final thumping = Choreo.window(t, 0.45, 2.25, fade: 0.15);
    final thumpPhase = 2 * math.pi * thumpRate * (t - 0.45);
    final thump = math.max(0.0, math.sin(thumpPhase)) * thumping;
    p.kick = -0.42 * thump;
    p.scaleY += (0.06 * up - 0.02 * math.max(0.0, -math.sin(thumpPhase)) * thumping) * m;
    p.scaleX -= 0.03 * up * m;
    p.lean = -0.04 * up * m;
    // Paws knead slowly in contentment.
    final knead = math.sin(2 * math.pi * 1.4 * (t - 0.3));
    p.leftArm = (0.18 + 0.1 * knead) * up;
    p.rightArm = (0.18 - 0.1 * knead) * up;
    p.tailWag = 0.9 * math.sin(thumpPhase) * thumping * m;
    p.tailCurl = 0.7;
    p.tailLift = 0.3;
    if (lite) return;
    p.lookY = -0.5 * up;
    p.lookX = 0;
    p.headTurn = 0;
    p.tilt = -0.2 * up + 0.04 * math.sin(2 * math.pi * 0.8 * t) * up;
    p.earPerk = Ease.lerp(0.2, -0.6, Choreo.seg(t, 0.3, 1.2)) * (1 - Choreo.seg(t, 2.3, 2.6)) + 0.6 * Choreo.seg(t, 2.3, 2.6);
    p.earLeft -= 0.14 * thump;
    // Eyes blissfully shut (soft lid arcs, not melt's happy ^^), a look up, a slow blink.
    if (t < 0.3) {
      p.eyes = PetEyes.happy;
    } else if (t < 2.35) {
      p.eyes = PetEyes.closed;
    } else if (t < 2.7) {
      p.eyes = PetEyes.open;
    } else {
      p.eyes = PetEyes.closed;
    }
    if (t >= 2.35 && t < 2.7) p.eyeOpenness = 1;
    p.eyeOpenness = math.min(p.eyeOpenness, 1 - 0.95 * PetLife.slowBlinkShape(t - 2.72));
    p.mouth = t < 0.5 ? PetMouth.smile : (t < 2.3 ? PetMouth.smile : (t < 2.7 ? PetMouth.o : PetMouth.blep));
    p.blush = 0.5 + 0.45 * Choreo.seg(t, 0.2, 0.9);
    purrLines(p, t: t, amount: 0.7 * Choreo.window(t, 0.6, 2.2, fade: 0.2));
    // A little dust puff from every thump, fading out completely before the next one.
    if (thumping > 0.1) {
      final cycle = (t - 0.45) * thumpRate;
      final since = Ease.fract(cycle - 0.5) / thumpRate;
      const life = 0.9 / thumpRate;
      if (since < life) {
        p.add(
          Effect(
            EffectKind.dust,
            x: -0.32,
            y: 0.03,
            scale: 0.35 + 0.6 * since / life,
            opacity: (1 - since / life) * 0.7 * thumping,
            variant: 0,
            phase: since / life,
          ),
        );
      }
    }
    if (t > 0.7) {
      PetFX.hearts(p, t: t - 0.7, x: 0.15, y: 1.08, count: 2, spacing: 0.7, reduced: false, pop: true, life: 0.9);
    }
  }

  // MARK: Reduced motion

  static void calm(PetPose p, {required double t, required int variant, required bool lite}) {
    if (lite) return;
    p.blush = 0.45 + 0.5 * Choreo.seg(t, 0.1, 0.8);
    p.lookX = 0;
    switch (variant) {
      case 0:
        p.eyes = t < 2.6 ? PetEyes.happy : PetEyes.open;
        p.mouth = t < 2.7 ? PetMouth.smile : PetMouth.blep;
        p.earPerk = Ease.lerp(-1.0, 0.3, Choreo.seg(t, 2.4, 2.8));
        purrLines(p, t: 0, amount: Choreo.window(t, 0.3, 2.5, fade: 0.3));
      case 1:
        p.eyes = t < 2.6 ? PetEyes.open : PetEyes.wink;
        p.eyeSparkle = 0.8 * Choreo.window(t, 0.3, 2.4, fade: 0.3);
        p.mouth = t < 2.7 ? PetMouth.grin : PetMouth.blep;
        p.lookY = -0.4;
        p.earPerk = -0.3;
      default:
        p.eyes = t < 2.6 ? PetEyes.closed : PetEyes.open;
        p.mouth = t < 2.7 ? PetMouth.smile : PetMouth.blep;
        p.lookY = -0.4;
        p.earPerk = Ease.lerp(-0.5, 0.3, Choreo.seg(t, 2.4, 2.8));
    }
    p.tailCurl = 0.9;
    PetFX.hearts(p, t: t - 0.4, x: 0.2, y: 1.05, count: 2, spacing: 0.9, reduced: true);
  }
}
