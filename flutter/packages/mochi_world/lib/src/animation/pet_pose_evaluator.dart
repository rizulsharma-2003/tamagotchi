// Port of Sources/TamagotchiCore/Animation/PetPoseEvaluator.swift (and `PetPoseEvaluator.idleBehaviour` from
// PetIdleLife.swift). `Keys` lives in model/ease.dart and the legacy effect-array builders in
// companion_pose_evaluator.dart (`LegacyEffects`).

import 'dart:math' as math;

import '../model/animations.dart';
import '../model/ease.dart';
import '../model/poses.dart' as poses;
import '../model/poses.dart' show Brows, Effect, EffectKind, PetEyes, PetMouth, PetPose, PoseContext;
import 'choreography.dart';
import 'pet_affection.dart';
import 'pet_idle_life.dart';
import 'pet_play.dart';
import 'pet_secondary_motion.dart';
import 'pet_treat.dart';

/// The primary kinematics of a pose at some moment (Swift `PetSecondaryMotion.Sample`).
class KinematicsSample {
  const KinematicsSample({required this.x, required this.y, required this.rotation});

  final double x;
  final double y;
  final double rotation;
}

/// Mochi's animation language: soft, squishy, bouncy and organic.
///
/// A pose is built in three layers, all pure functions of (animation, elapsed, global time, seed, reduced motion,
/// intensity):
/// 1. the living base (`PetLife`): breathing, blinks, saccades, ear twitches, tail;
/// 2. the primary choreography for the animation (and variant);
/// 3. secondary motion (`PetSecondaryMotion`): ears, tail and body follow-through, squash/stretch, lean and landing
///    dust, from re-sampling layer 2 in the recent past.
/// One-shots ease in from, and settle exactly onto, the loop they return to (`PoseContext.returnLoop`), so the
/// animator can switch clips without a pop.
abstract final class PetPoseEvaluator {
  /// Body widths per path unit (pet home → companion home) in the popover scene. World-space props (a ball on the
  /// floor) use it to stay put while Mochi moves.
  static const double bodyWidthsPerPathUnit = poses.bodyWidthsPerPathUnit;

  /// Upper bound on particles per pose.
  static const int maxEffects = poses.petMaxEffects;

  /// A one-shot squeezed into a shorter slot plays at most this much faster; the rest of the clip is trimmed (the
  /// settle at the end still brings everything home).
  static const double maxSpeedUp = 1.35;

  /// Swift's two `pose` overloads in one: with [variant] null the variant is picked from the start time and seed (the
  /// fixed variant is for dev tools and tests).
  static PetPose pose(PetAnimation animation, {required double elapsed, double? duration, required PoseContext context, int? variant}) {
    final t = elapsed;
    final chosen = variant ?? PetPoseEvaluator.variant(animation, startedAt: context.time - t, seed: context.seed);
    final d = math.max(0.05, duration ?? animation.defaultDuration);
    final count = variantCount(animation);
    final v = (chosen.remainder(count) + count).remainder(count);
    final oneShot = isOneShot(animation);
    // Past its end a one-shot has handed over: it is exactly the loop it returns to.
    if (oneShot && t >= d) return returnPose(context);
    final p = primary(animation, t: t, d: d, context: context, variant: v, lite: false);
    if (!context.reducedMotion) {
      PetSecondaryMotion.apply(p, animation: animation, t: t, duration: d, context: context, variant: v);
    }
    if (oneShot) settle(p, animation: animation, t: t, d: d, context: context);
    finalize(p, reduced: context.reducedMotion);
    return p;
  }

  static bool isOneShot(PetAnimation animation) => !animation.isLoop && animation != PetAnimation.scripted;

  /// The loop a one-shot hands back to.
  static PetAnimation returnLoop(PoseContext context) => context.returnLoop.isLoop ? context.returnLoop : PetAnimation.idle;

  /// The return loop's pose right now (loops depend only on global time).
  static PetPose returnPose(PoseContext context) => pose(returnLoop(context), elapsed: 0, duration: null, context: context, variant: 0);

  /// Clips that start on a deliberate hit frame rather than easing in.
  static bool startsOnHit(PetAnimation animation) => switch (animation) {
    PetAnimation.petted || PetAnimation.wakeUp || PetAnimation.offer || PetAnimation.highFive || PetAnimation.rpsShake => true,
    _ => false,
  };

  /// Continuity for one-shots. Over the first 0.15 s the gaze, head, ears, arms and tail ease in from the return loop
  /// (and its lift fades out). Over the last 0.3 s (less in short slots) every channel settles onto that loop: eye
  /// shapes swap behind a blink, the clip's effects fade and the loop's own effects fade in.
  static void settle(PetPose p, {required PetAnimation animation, required double t, required double d, required PoseContext context}) {
    final start = startsOnHit(animation) ? 1.0 : Ease.smooth(Ease.segment(t, 0, 0.15));
    final window = math.min(0.3, 0.3 * d);
    final end = Ease.smooth(Ease.segment(t, d - window, d));
    if (!(start < 1 || end > 0)) return;
    final ambient = returnPose(context);
    if (start < 1) {
      final w = 1 - start;
      p.y += ambient.y * w;
      p.lean += ambient.lean * w;
      blendExpression(p, toward: ambient, amount: w);
    }
    if (!(end > 0)) return;
    double blend(double value, double target) => value + (target - value) * end;
    p.x = blend(p.x, ambient.x);
    p.y = blend(p.y, ambient.y);
    p.rotation = Ease.lerp(ieeeRemainder(p.rotation, 2 * math.pi), ambient.rotation, end);
    p.scaleX = blend(p.scaleX, ambient.scaleX);
    p.scaleY = blend(p.scaleY, ambient.scaleY);
    p.lean = blend(p.lean, ambient.lean);
    p.step = blend(p.step, ambient.step);
    p.stride = blend(p.stride, ambient.stride);
    p.kick = blend(p.kick, ambient.kick);
    p.pawToMouth = blend(p.pawToMouth, ambient.pawToMouth);
    p.holdFront = blend(p.holdFront, ambient.holdFront);
    p.crossEyed = blend(p.crossEyed, ambient.crossEyed);
    p.shadow = blend(p.shadow, ambient.shadow);
    p.breath = blend(p.breath, ambient.breath);
    blendExpression(p, toward: ambient, amount: end);
    if (end > 0.55) {
      p.mouth = ambient.mouth;
      p.brows = ambient.brows;
    }
    if (end > 0.6) p.facing = ambient.facing;
    // Eye shapes swap behind a quick blink.
    final swapBlink = p.eyes == ambient.eyes && p.eyes == PetEyes.open ? 0.0 : Choreo.bump(t, d - 0.57 * window, d - 0.1 * window);
    if (end > 0.7) p.eyes = ambient.eyes;
    p.eyeOpenness = math.min(Ease.lerp(p.eyeOpenness, ambient.eyeOpenness, end), 1 - 0.95 * swapBlink);
    final fade = 1 - Ease.smooth(Ease.segment(t, d - math.min(0.25, window), d));
    if (fade < 1) {
      for (final effect in p.effects) {
        effect.opacity *= fade;
      }
    }
    for (final ambientEffect in ambient.effects) {
      final effect = ambientEffect.copy();
      effect.opacity *= end;
      p.add(effect);
    }
  }

  /// Gaze, head, ears, arms, tail and face channels moved `amount` of the way to `a`.
  static void blendExpression(PetPose p, {required PetPose toward, required double amount}) {
    final a = toward;
    final w = amount;
    double mix(double value, double target) => value + (target - value) * w;
    p.lookX = mix(p.lookX, a.lookX);
    p.lookY = mix(p.lookY, a.lookY);
    p.tilt = mix(p.tilt, a.tilt);
    p.headTurn = mix(p.headTurn, a.headTurn);
    p.earPerk = mix(p.earPerk, a.earPerk);
    p.earLeft = mix(p.earLeft, a.earLeft);
    p.earRight = mix(p.earRight, a.earRight);
    p.earListen = mix(p.earListen, a.earListen);
    p.leftArm = mix(p.leftArm, a.leftArm);
    p.rightArm = mix(p.rightArm, a.rightArm);
    p.tailWag = mix(p.tailWag, a.tailWag);
    p.tailCurl = mix(p.tailCurl, a.tailCurl);
    p.tailLift = mix(p.tailLift, a.tailLift);
    p.eyeScale = mix(p.eyeScale, a.eyeScale);
    p.eyeSparkle = mix(p.eyeSparkle, a.eyeSparkle);
    p.blush = mix(p.blush, a.blush);
    p.cheekLeft = mix(p.cheekLeft, a.cheekLeft);
    p.cheekRight = mix(p.cheekRight, a.cheekRight);
    p.eyeOpenness = mix(p.eyeOpenness, a.eyeOpenness);
  }

  // MARK: Variants

  /// How many distinct stories an animation has.
  static int variantCount(PetAnimation animation) => switch (animation) {
    PetAnimation.play => PetPlay.variants.length,
    PetAnimation.treat => PetTreat.variants.length,
    PetAnimation.petted => PetAffection.variants.length,
    _ => 1,
  };

  static String variantName(PetAnimation animation, int variant) {
    final count = variantCount(animation);
    final v = (variant.remainder(count) + count).remainder(count);
    return switch (animation) {
      PetAnimation.play => PetPlay.variants[v],
      PetAnimation.treat => PetTreat.variants[v],
      PetAnimation.petted => PetAffection.variants[v],
      _ => animation.title,
    };
  }

  /// Deterministic variant for a run that started at `startedAt` (context.time − elapsed).
  static int variant(PetAnimation animation, {required double startedAt, required int seed}) {
    final count = variantCount(animation);
    if (!(count > 1 && startedAt.isFinite)) return 0;
    // Quantize so the tiny float error of time − elapsed can never flip the choice mid-run.
    // Petting keeps one style for a whole petting session (repeated clicks restart it).
    final bucket = animation == PetAnimation.petted ? (startedAt / 12).roundToDouble().toInt() : (startedAt * 3.7).roundToDouble().toInt();
    final salt = animation.name.length * 7919;
    return math.min(count - 1, (Ease.hash(bucket, seed ^ 0x5EEDA11E ^ salt) * count.toDouble()).toInt());
  }

  /// Dev tools: the idle behaviour playing at `time` (its name, and seconds into it).
  static ({String name, double local}) idleBehaviour({required double at, required int seed}) {
    final event = PetLife.idleEvent(at, seed: seed);
    return (name: event.event.name, local: event.local);
  }

  // MARK: Layers

  /// The base + primary layers. `lite` skips effects and expression-only work; the kinematics (x, y, rotation) are
  /// identical either way.
  static PetPose primary(
    PetAnimation animation, {
    required double t,
    required double d,
    required PoseContext context,
    required int variant,
    required bool lite,
  }) {
    final p = PetLife.base(context, lite: lite);
    switch (animation) {
      case PetAnimation.idle || PetAnimation.scripted:
        PetLife.idle(p, context: context, lite: lite);
      case PetAnimation.sleep:
        PetLife.sleep(p, context: context, lite: lite, curled: false);
      case PetAnimation.curl:
        PetLife.sleep(p, context: context, lite: lite, curled: true);
      case PetAnimation.watch:
        PetLife.watch(p, context: context, lite: lite);
      case PetAnimation.waveGently:
        PetLife.waveGently(p, context: context, lite: lite);
      case PetAnimation.sit:
        PetLife.sit(p, context: context, lite: lite);
      case PetAnimation.play:
        PetPlay.pose(p, t: t, d: d, context: context, variant: variant, lite: lite);
      case PetAnimation.treat:
        PetTreat.pose(p, t: t, d: d, context: context, variant: variant, lite: lite);
      case PetAnimation.petted:
        PetAffection.pose(p, t: t, d: d, context: context, variant: variant, lite: lite);
      case PetAnimation.walk || PetAnimation.carry:
        walk(p, context: context, lite: lite, carrying: animation == PetAnimation.carry);
      case PetAnimation.run:
        run(p, context: context, lite: lite);
      default:
        oneShot(animation, p, t: t, d: d, context: context, lite: lite);
    }
    return p;
  }

  /// Primary kinematics at another moment (for secondary motion).
  static KinematicsSample kinematics(
    PetAnimation animation, {
    required double elapsed,
    required double duration,
    required double time,
    required PoseContext context,
    required int variant,
  }) {
    final t = elapsed;
    final d = duration;
    if (isOneShot(animation) && t < 0) {
      return const KinematicsSample(x: 0, y: 0, rotation: 0);
    }
    final shifted = context.copy();
    shifted.time = time;
    final p = primary(animation, t: t, d: d, context: shifted, variant: variant, lite: true);
    return KinematicsSample(x: p.x, y: p.y, rotation: p.rotation);
  }

  static void finalize(PetPose p, {required bool reduced}) {
    p.rotation = ieeeRemainder(p.rotation, 2 * math.pi);
    if (p.rotation.abs() < 1e-9) p.rotation = 0;
    if (reduced) {
      p.x = 0;
      p.y = 0;
      p.rotation = 0;
      p.lean = 0;
      p.stride = 0;
      p.kick = 0;
      p.step = 0;
    }
    p.earLeft = Ease.clamp(p.earLeft, -1.2, 1.2);
    p.earRight = Ease.clamp(p.earRight, -1.2, 1.2);
    p.earPerk = Ease.clamp(p.earPerk, -1.6, 1.2);
    p.lean = Ease.clamp(p.lean, -0.4, 0.4);
    p.tailWag = Ease.clamp(p.tailWag, -2.5, 2.5);
    p.tailCurl = Ease.clamp(p.tailCurl, -1.2, 1.2);
    p.tailLift = Ease.clamp(p.tailLift, -1.2, 1.2);
    p.scaleX = Ease.clamp(p.scaleX, 0.62, 1.45);
    p.scaleY = Ease.clamp(p.scaleY, 0.62, 1.45);
    p.eyeScale = Ease.clamp(p.eyeScale, 0.6, 1.5);
    p.eyeSparkle = Ease.clamp(p.eyeSparkle);
    p.crossEyed = Ease.clamp(p.crossEyed);
    p.cheekLeft = Ease.clamp(p.cheekLeft);
    p.cheekRight = Ease.clamp(p.cheekRight);
    p.pawToMouth = Ease.clamp(p.pawToMouth);
    p.holdFront = Ease.clamp(p.holdFront);
    p.blush = Ease.clamp(p.blush);
    p.stride = Ease.clamp(p.stride, -1.2, 1.2);
    p.kick = Ease.clamp(p.kick, -1, 1);
    p.headTurn = Ease.clamp(p.headTurn, -1, 1);
    p.earListen = Ease.clamp(p.earListen);
    p.shadow = Ease.clamp(p.shadow, 0.25, 1);
  }

  /// Plays a one-shot authored for `natural` seconds inside a slot of `d` seconds: sped up (at most [maxSpeedUp], then
  /// trimmed) when the slot is shorter, natural speed (then rest) when longer.
  static double fit(double t, {required double natural, required double d}) =>
      d < natural ? t * math.min(natural / math.max(d, 0.05), maxSpeedUp) : t;

  // MARK: Locomotion loops

  /// A bouncy "boing-waddle": two springy bounces per gait cycle, a squash on every footfall and a little stretch in the
  /// air, a side-to-side rock that peaks mid-step (never at contact, so the feet stay on the floor) and ears that
  /// bounce a beat late.
  static void walk(PetPose p, {required PoseContext context, required bool lite, required bool carrying}) {
    final g = context.time;
    final m = context.motion;
    const cadence = 1.8;
    final phase = 2 * math.pi * g * cadence;
    final s = math.sin(phase);
    final air = s.abs();
    final contact = Ease.clamp(1 - air / 0.42);
    final footfall = contact * contact;
    p.y = 0.075 * air * m;
    p.rotation = -0.085 * s * m;
    p.scaleY *= 1 + (0.04 * air - 0.065 * footfall) * m;
    p.scaleX *= 1 - (0.025 * air - 0.05 * footfall) * m;
    p.lean = 0.05 * m;
    p.step = s * (context.reducedMotion ? 0.0 : 1.0);
    p.stride = -math.cos(phase) * 0.85 * m;
    p.tailWag = 0.8 * math.sin(phase - 0.9) * m;
    p.tailCurl = 0.15;
    p.tailLift = 0.3 + 0.15 * air * m;
    if (lite) return;
    // Ears bounce an eighth of a step behind the body and sway with the rock.
    final lagged = math.cos(2 * phase - math.pi / 4);
    p.earPerk = 0.3 - 0.24 * lagged * m;
    p.earLeft += 0.1 * math.sin(phase - 1.0) * m;
    p.earRight += 0.1 * math.sin(phase - 1.0) * m;
    p.tilt = 0.03 * s * m;
    p.headTurn = 0.3;
    p.lookX = 0.6;
    p.lookY = 0.05;
    if (carrying) {
      p.leftArm = 0.55 + 0.04 * math.sin(phase * 2) * m;
      p.rightArm = 0.55 + 0.04 * math.sin(phase * 2) * m;
      p.mouth = PetMouth.smile;
    } else {
      p.leftArm = 0.08 + 0.3 * math.max(0.0, s) * m;
      p.rightArm = 0.08 + 0.3 * math.max(0.0, -s) * m;
      p.mouth = PetMouth.cat;
    }
  }

  static void run(PetPose p, {required PoseContext context, required bool lite}) {
    final g = context.time;
    final m = context.motion;
    const cadence = 2.4;
    final cycle = g * cadence;
    final phase = 2 * math.pi * cycle;
    // Two bounds per cycle: push off, fly, land.
    final half = Ease.fract(cycle * 2);
    final flight = Ease.hop(half);
    p.y = 0.09 * flight * m;
    final contactSquash = Choreo.bump(half, 0.86, 1.0) + Choreo.bump(half, 0, 0.12);
    p.scaleY *= 1 + (0.07 * flight - 0.1 * contactSquash) * m;
    p.scaleX *= 1 - (0.045 * flight - 0.08 * contactSquash) * m;
    p.step = math.sin(phase) * (context.reducedMotion ? 0.0 : 1.0);
    p.stride = -math.cos(phase) * 1.15 * m;
    p.lean = (0.17 + 0.03 * math.cos(phase * 2)) * m;
    p.rotation = 0.025 * math.sin(phase) * m;
    p.tailWag = 0.25 * math.sin(phase * 2) * m;
    p.tailCurl = -0.9;
    p.tailLift = 0.15;
    if (lite) return;
    p.earPerk = -0.55;
    p.earLeft -= 0.42 * m;
    p.earRight -= 0.42 * m;
    p.headTurn = 0.5;
    p.lookX = 0.85;
    p.lookY = 0.1;
    p.mouth = PetMouth.pant;
    p.eyeScale = 0.96;
    p.leftArm = 0.18 + 0.22 * math.max(0.0, -math.sin(phase)) * m;
    p.rightArm = 0.18 + 0.22 * math.max(0.0, math.sin(phase)) * m;
    p.blush = 0.5;
    if (!context.reducedMotion) {
      // Dust kicked up behind on each footfall (screen space: behind a right-facing runner).
      final sinceContact = Ease.fract(cycle * 2 - 0.9) / (cadence * 2);
      PetFX.dustKick(p, age: sinceContact, life: 0.34, strength: 0.8);
      final earlier = sinceContact + 1 / (cadence * 2);
      PetFX.dustKick(p, age: earlier, life: 0.34, strength: 0.6);
      // Speed lines trailing behind.
      p.add(Effect(EffectKind.streak, x: -0.52, y: 0.52 + 0.03 * math.sin(phase), scale: 0.85, opacity: 0.75, variant: 2));
    }
  }

  // MARK: One-shots and building blocks

  static void oneShot(
    PetAnimation animation,
    PetPose p, {
    required double t,
    required double d,
    required PoseContext context,
    required bool lite,
  }) {
    final raw = t;
    final m = context.motion;
    final g = context.time;
    final reduced = context.reducedMotion;
    switch (animation) {
      case PetAnimation.lookAround:
        lookAround(
          p,
          t: fit(raw, natural: 2.6, d: d),
          context: context,
          lite: lite,
        );

      case PetAnimation.happyBounce:
        final t = fit(raw, natural: 1.0, d: d);
        final crouch = Choreo.bump(t, 0, 0.12);
        p.y = (0.14 * Choreo.hop(t, 0.09, 0.46) + 0.07 * Choreo.hop(t, 0.52, 0.82)) * m;
        p.scaleY -= 0.08 * crouch * m;
        p.scaleX += 0.06 * crouch * m;
        final air = Choreo.bump(t, 0.09, 0.46) + 0.6 * Choreo.bump(t, 0.52, 0.82);
        p.leftArm = 0.3 + 0.3 * air;
        p.rightArm = 0.3 + 0.3 * air;
        p.tailWag = 1.0 * math.sin(g * 13) * m;
        p.tailLift = 0.5;
        p.tailCurl = 0.4;
        if (lite) break;
        p.eyes = PetEyes.happy;
        p.mouth = t < 0.5 ? PetMouth.grin : PetMouth.open;
        p.blush = 0.75;
        p.earPerk = 0.75;
        p.lookX = 0.1;
        // Pastel sparkles: gold ones are reserved for real Claude events (this one plays ambiently too).
        if (!reduced) {
          PetFX.sparkles(p, t: t - 0.2, around: (0, 1.08), count: 2, spread: 0.55, seed: context.seed + 17, life: 0.6, variant: 1);
        }

      case PetAnimation.excitedJump:
        final t = fit(raw, natural: 1.4, d: d);
        final crouch = Choreo.bump(t, 0, 0.3);
        p.y = (0.48 * Choreo.hop(t, 0.24, 0.74) + 0.16 * Choreo.hop(t, 0.84, 1.16)) * m;
        p.scaleY -= 0.15 * crouch * m;
        p.scaleX += 0.12 * crouch * m;
        final armsUp = Choreo.ramp(t, 0.18, 0.34, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 1.12, 1.4)));
        p.leftArm = armsUp;
        p.rightArm = armsUp * (0.92 + 0.08 * math.sin(t * 26) * Choreo.window(t, 0.3, 0.7, fade: 0.1));
        p.shadow = 1 - 0.55 * p.y;
        p.tailWag = 1.1 * math.sin(g * 14) * m;
        p.tailLift = 0.8;
        if (lite) break;
        p.eyes = t < 0.26 ? PetEyes.wide : PetEyes.happy;
        p.eyeScale = 1 + 0.2 * crouch;
        p.eyeSparkle = crouch;
        p.mouth = t < 0.26 ? PetMouth.o : PetMouth.grin;
        p.blush = 0.85;
        p.earPerk = Choreo.perk(t, 0.18, 0.42, 0.2, 1);
        if (t > 0.38 && t < 1.35) {
          PetFX.sparkles(p, t: t - 0.38, around: (0, 1.0), count: 4, spread: 0.66, seed: context.seed, variant: 1);
        }

      case PetAnimation.roll:
        final t = fit(raw, natural: 1.6, d: d);
        if (reduced) {
          if (lite) break;
          p.eyes = t < 1.05 ? PetEyes.happy : PetEyes.dizzy;
          p.mouth = t < 1.05 ? PetMouth.open : PetMouth.wavy;
          PetFX.dizzyStars(p, t: 0, amount: Choreo.window(t, 1.0, 1.6, fade: 0.2));
          break;
        }
        final squash = Choreo.bump(t, 0, 0.24);
        final progress = Choreo.seg(t, 0.2, 1.05);
        final balled = Choreo.window(t, 0.18, 1.08, fade: 0.14);
        p.scaleY -= (0.12 * squash + 0.08 * balled) * m;
        p.scaleX += (0.1 * squash - 0.04 * balled) * m;
        p.rotation = 2 * math.pi * Ease.smooth(progress) * p.facing;
        p.x = 0.16 * math.sin(math.pi * progress) * m;
        p.y = 0.03 * Ease.hop(progress) * m + Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY);
        p.holdFront = 0.8 * balled;
        final wobble = Choreo.window(t, 1.03, 1.6, fade: 0.22);
        if (lite) break;
        p.eyes = t < 1.05 ? PetEyes.happy : PetEyes.dizzy;
        p.mouth = t < 1.05 ? PetMouth.open : PetMouth.wavy;
        p.earPerk = -0.8 * balled;
        p.tilt = 0.12 * math.sin(t * 14) * wobble;
        p.earLeft += 0.2 * math.sin(t * 14) * wobble;
        p.earRight += 0.2 * math.sin(t * 14 + 1) * wobble;
        PetFX.dizzyStars(p, t: t, amount: wobble);

      case PetAnimation.dance:
        final beat = raw / 0.8;
        final amount = Ease.envelope(raw, duration: d, fadeIn: 0.3, fadeOut: 0.45);
        final sway = math.sin(2 * math.pi * beat * 0.5);
        p.x = 0.035 * (1 + sway) * 0.5 * m * amount;
        p.y = 0.05 * math.sin(2 * math.pi * beat).abs() * m * amount;
        p.lean = 0.07 * sway * m * amount;
        p.rotation = 0.06 * math.sin(2 * math.pi * beat) * m * amount;
        // A little twirl on the third beat of each bar when there is room for it.
        final bar = (beat / 4).floorToDouble();
        final twirlStart = bar * 4 * 0.8 + 2 * 0.8;
        var twirlHop = 0.0;
        if (bar >= 0 && twirlStart + 0.65 <= d - 0.3 && !reduced) {
          // A little jump carries the twirl, so it spins in the air rather than on its ears.
          p.rotation += 2 * math.pi * Ease.smooth(Choreo.seg(raw, twirlStart, twirlStart + 0.65)) * p.facing;
          twirlHop = 0.2 * Choreo.hop(raw, twirlStart - 0.04, twirlStart + 0.69) * m;
        }
        p.y = math.max(p.y + twirlHop, Choreo.floorLift(p.rotation));
        p.step = math.sin(2 * math.pi * beat) * amount;
        p.leftArm = (0.5 + 0.45 * math.sin(2 * math.pi * beat)) * amount;
        p.rightArm = (0.5 - 0.45 * math.sin(2 * math.pi * beat)) * amount;
        p.tailWag = 1.0 * math.sin(2 * math.pi * beat) * m;
        p.tailLift = 0.5;
        if (lite) break;
        p.eyes = PetEyes.happy;
        p.mouth = (beat * 2).toInt().remainder(2) == 0 ? PetMouth.open : PetMouth.grin;
        p.blush = 0.7;
        p.earPerk = 0.6;
        p.tilt = 0.08 * math.sin(2 * math.pi * beat) * math.max(m, 0.4) * amount;
        PetFX.notes(p, t: raw, x: 0.45, y: 1.0, reduced: reduced);

      case PetAnimation.confusedTilt:
        final t = fit(raw, natural: 1.8, d: d);
        final tilt = Ease.outBack(Choreo.seg(t, 0, 0.4), 2.2) * (1 - Choreo.smooth(Choreo.seg(t, 1.35, 1.75)));
        if (lite) break;
        p.tilt = 0.26 * tilt * math.max(m, 0.5) + 0.05 * math.sin((t - 1.35) * 20) * Choreo.window(t, 1.35, 1.75, fade: 0.1) * m;
        p.brows = Brows.confused;
        p.mouth = t < 1.0 ? PetMouth.o : PetMouth.wavy;
        p.lookX = 0.3;
        p.lookY = -0.3;
        p.earPerk = -0.1;
        if (!reduced) {
          p.earRight -= 0.35 * tilt;
          p.earLeft -= 0.1 * tilt;
        }
        p.eyeOpenness = math.min(p.eyeOpenness, 1 - 0.95 * PetLife.blinkShape(t - 0.55));
        final pop = Ease.outBack(Choreo.seg(t, 0.15, 0.45));
        p.add(
          Effect(
            EffectKind.question,
            x: 0.48,
            y: 1.22 + 0.05 * pop,
            scale: pop,
            opacity: 1 - Choreo.seg(t, 1.4, 1.8),
            rotation: reduced ? 0 : 0.15 * math.sin(t * 5),
          ),
        );

      case PetAnimation.concerned:
        final amount = Ease.envelope(raw, duration: d, fadeIn: 0.3, fadeOut: 0.4);
        p.scaleY -= 0.04 * amount * math.max(m, 0.4);
        // A worried half-step back (tiny: the desktop window has little room behind the tail).
        p.x = -0.012 * amount * m;
        p.lean = -0.04 * amount * m;
        p.tailWag = 0.1 * math.sin(g * 3) * m;
        p.tailLift = -0.7 * amount;
        p.tailCurl = 0.7 * amount;
        final fidget = math.sin(raw * 2 * math.pi * 2.6) * amount * (reduced ? 0.0 : 1.0);
        p.leftArm = 0.18 * amount + 0.05 * fidget;
        p.rightArm = 0.18 * amount - 0.05 * fidget;
        if (lite) break;
        p.earPerk = -0.85 * amount;
        p.brows = Brows.worried;
        p.eyes = PetEyes.worried;
        p.mouth = PetMouth.wavy;
        p.lookX = 0.55;
        final drip = Choreo.seg(raw, 0.3, 1.6);
        p.add(Effect(EffectKind.sweat, x: 0.4, y: 0.98 - 0.14 * drip * math.max(m, 0.2), scale: 0.9, opacity: Ease.bump(raw, 0.25, 2.2)));

      case PetAnimation.victory:
        final t = fit(raw, natural: 2.4, d: d);
        final squash = Choreo.bump(t, 0, 0.22);
        p.y = 0.36 * Choreo.hop(t, 0.2, 0.74) * m;
        p.scaleY -= 0.13 * squash * m;
        p.scaleX += 0.1 * squash * m;
        // The spin needs the full clip; in a short script slot it would strobe.
        if (!reduced && d >= 1.8) p.rotation = 2 * math.pi * Ease.smooth(Choreo.seg(t, 0.22, 0.86)) * p.facing;
        p.y = math.max(p.y, Choreo.floorLift(p.rotation));
        final pump = Choreo.bump(t, 0.85, 1.15) + Choreo.bump(t, 1.25, 1.55);
        final arms = Choreo.ramp(t, 0.16, 0.32, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 1.9, 2.35)));
        p.rightArm = arms * (0.9 + 0.1 * pump);
        p.leftArm = arms * (0.95 - 0.55 * Choreo.window(t, 0.7, 1.9, fade: 0.2));
        p.y += 0.03 * pump * m;
        p.scaleY += 0.03 * Choreo.window(t, 0.75, 1.9, fade: 0.2) * m;
        p.shadow = 1 - 0.5 * p.y;
        p.tailWag = 1.2 * math.sin(g * 12) * m;
        p.tailLift = 0.9;
        if (lite) break;
        p.eyes = PetEyes.happy;
        p.mouth = PetMouth.grin;
        p.blush = 0.85;
        p.earPerk = 1;
        // Victory only plays for real successes, so it keeps the gold sparkles and confetti.
        PetFX.confetti(p, t: t - 0.3, originY: 1.2, count: 8, seed: context.seed, reduced: reduced);
        PetFX.sparkles(p, t: t, around: (0, 1.05), count: 2, spread: 0.6, seed: context.seed + 3);

      case PetAnimation.greet:
        final t = fit(raw, natural: 1.8, d: d);
        final crouch = Choreo.bump(t, 0, 0.12);
        p.y = 0.09 * Choreo.hop(t, 0.1, 0.38) * m;
        p.scaleY -= 0.06 * crouch * m;
        p.scaleX += 0.05 * crouch * m;
        final raise = Choreo.rampBack(t, 0.22, 0.48, 0, 1, overshoot: 2) * (1 - Choreo.smooth(Choreo.seg(t, 1.45, 1.78)));
        final wave = math.sin((t - 0.45) * 2 * math.pi * 2.4) * Choreo.window(t, 0.45, 1.5, fade: 0.15);
        p.rightArm = context.reducedMotion ? 0.85 * raise : 0.84 * raise + 0.14 * wave;
        p.lean = (0.04 * raise + 0.02 * wave) * m;
        p.tailWag = 0.9 * math.sin(g * 10) * m;
        p.tailLift = 0.5;
        if (lite) break;
        p.eyes = t < 0.45 ? PetEyes.happy : PetEyes.open;
        p.eyeSparkle = 0.6 * Choreo.window(t, 0.45, 1.5, fade: 0.2);
        p.mouth = t < 1.2 ? PetMouth.open : PetMouth.smile;
        p.earPerk = 0.75;
        if (!reduced) p.earRight += 0.12 * wave;
        p.lookX = 0;
        p.headTurn = -0.2 * raise;
        p.blush = 0.6;

      case PetAnimation.wave:
        final t = fit(raw, natural: 1.8, d: d);
        final raise = Choreo.rampBack(t, 0.05, 0.35, 0, 1, overshoot: 2) * (1 - Choreo.smooth(Choreo.seg(t, 1.5, 1.8)));
        final wave = math.sin((t - 0.3) * 2 * math.pi * 2.4) * Choreo.window(t, 0.3, 1.55, fade: 0.15);
        p.rightArm = context.reducedMotion ? 0.85 * raise : 0.84 * raise + 0.14 * wave;
        p.lean = 0.02 * wave * m;
        if (lite) break;
        p.mouth = PetMouth.smile;
        p.lookX = 0;
        p.earPerk = 0.5;
        if (!reduced) p.earRight += 0.1 * wave;

      case PetAnimation.leanForward:
        final t = fit(raw, natural: 1.4, d: d);
        final lean = leanForwardTrack(t);
        p.lean = 0.16 * lean * m;
        p.tailLift = 0.5 * lean;
        if (lite) break;
        p.lookX = 0.8;
        p.lookY = 0.1;
        p.headTurn = 0.5 * lean;
        p.earPerk = 0.7 * lean;
        p.eyes = t > 0.2 && t < 1.15 ? PetEyes.wide : PetEyes.open;
        p.eyeScale = 1 + 0.12 * lean;
        p.mouth = PetMouth.o;

      case PetAnimation.nod:
        final t = fit(raw, natural: 0.8, d: d);
        p.y = (-0.025 * Choreo.bump(t, 0, 0.38) - 0.018 * Choreo.bump(t, 0.4, 0.76)) * m;
        p.scaleY -= (0.025 * Choreo.bump(t, 0, 0.38) + 0.015 * Choreo.bump(t, 0.4, 0.76)) * m;
        if (lite) break;
        p.lookY = 0.3 * (Choreo.bump(t, 0, 0.38) + 0.7 * Choreo.bump(t, 0.4, 0.76));
        p.tilt = 0.05 * Ease.bump(t, 0, 0.8) * math.max(m, 0.4);
        p.eyes = t > 0.08 && t < 0.62 ? PetEyes.happy : PetEyes.open;
        p.mouth = PetMouth.smile;

      case PetAnimation.blep:
        final t = fit(raw, natural: 1.4, d: d);
        if (lite) break;
        // The tongue stays out for most of the clip; the head tips and an ear flicks.
        p.mouth = t > 0.1 && t < 1.2 ? PetMouth.blep : PetMouth.cat;
        p.eyes = t > 0.15 && t < 1.15 ? PetEyes.wink : PetEyes.open;
        p.tilt = 0.15 * Ease.bump(t, 0, 1.4) * math.max(m, 0.4);
        p.headTurn = -0.35 * Ease.bump(t, 0, 1.4);
        p.blush = 0.65;
        p.earPerk = 0.3;
        if (!reduced) {
          p.earLeft -= 0.3 * Choreo.bump(t, 0.1, 0.5);
          p.earRight += 0.5 * PetLife.flick(t - 0.75);
        }

      case PetAnimation.yawn:
        final t = fit(raw, natural: 1.8, d: d);
        final stretch = Choreo.window(t, 0.15, 1.42, fade: 0.35);
        final open = Choreo.ramp(t, 0.18, 0.58, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 1.18, 1.36)));
        final amount = reduced ? 0.25 : math.max(m, 0.3);
        p.leftArm = 0.7 * Ease.outBack(Choreo.seg(t, 0.2, 0.55)) * (1 - Choreo.smooth(Choreo.seg(t, 1.1, 1.45)));
        p.rightArm = p.leftArm;
        p.scaleY += 0.08 * stretch * amount;
        p.scaleX -= 0.04 * stretch * amount;
        p.tailLift = 0.6 * stretch;
        p.tailCurl = -0.4 * stretch;
        if (lite) break;
        // Head back, the mouth opens wide over 0.4 s, snaps shut, then a sleepy lip-smack.
        p.tilt = -0.1 * open * math.max(m, 0.4);
        p.lookY = -0.3 * open;
        if (t < 0.18) {
          p.mouth = PetMouth.cat;
        } else if (t < 0.32) {
          p.mouth = PetMouth.o;
        } else if (t < 0.46) {
          p.mouth = PetMouth.open;
        } else if (t < 1.18) {
          p.mouth = PetMouth.yawn;
        } else if (t < 1.3) {
          p.mouth = PetMouth.o;
        } else if (t < 1.62) {
          p.mouth = ((t - 1.3) * 12).toInt().remainder(2) == 0 ? PetMouth.nom : PetMouth.lick;
        } else {
          p.mouth = PetMouth.cat;
        }
        p.eyes = t > 0.22 && t < 1.34 ? PetEyes.closed : PetEyes.sleepy;
        p.earPerk = -0.2 - 0.5 * stretch;
        if (t > 1.18 && t < 1.78) {
          p.add(
            Effect(
              EffectKind.droplet,
              x: 0.26,
              y: 0.52 - 0.05 * Choreo.seg(t, 1.3, 1.78),
              scale: 0.3,
              opacity: Choreo.window(t, 1.18, 1.78, fade: 0.15),
            ),
          );
        }

      case PetAnimation.wakeUp:
        final t = fit(raw, natural: 1.2, d: d);
        final stretch = Choreo.window(t, 0.3, 0.85, fade: 0.2);
        p.leftArm = 0.5 * stretch;
        p.rightArm = 0.5 * stretch;
        p.scaleY += 0.05 * stretch * (reduced ? 0.25 : math.max(m, 0.3));
        final shake = math.sin((t - 0.72) * 2 * math.pi * 4) * Choreo.window(t, 0.72, 1.02, fade: 0.08);
        if (lite) break;
        p.eyes = t < 0.32 ? PetEyes.sleepy : (t < 0.72 ? PetEyes.closed : (t < 0.95 ? PetEyes.wide : PetEyes.open));
        p.eyeOpenness = t < 0.32 ? 0.5 + 0.5 * math.sin(t * 9).abs() : p.eyeOpenness;
        p.mouth = t > 0.32 && t < 0.7 ? PetMouth.o : PetMouth.cat;
        p.tilt = 0.1 * shake * (reduced ? 0.0 : 1.0);
        p.earPerk = Choreo.ramp(t, 0, 0.5, -0.6, 0.2);
        if (!reduced) {
          p.earLeft += 0.3 * shake - 0.25 * Choreo.bump(t, 0.85, 1.05);
          p.earRight += 0.3 * shake + 0.25 * Choreo.bump(t, 0.95, 1.15);
        }
        p.earPerk += 0.5 * Choreo.seg(t, 0.85, 1.1);

      case PetAnimation.offer:
        final t = fit(raw, natural: 1.0, d: d);
        final reach = Choreo.rampBack(t, 0, 0.32, 0.2, 0.75);
        p.leftArm = reach;
        p.rightArm = reach;
        p.lean = 0.06 * Choreo.window(t, 0, 1.0, fade: 0.25) * m;
        if (lite) break;
        p.eyes = PetEyes.happy;
        p.mouth = PetMouth.smile;
        p.blush = 0.6;

      case PetAnimation.highFive:
        final t = fit(raw, natural: 0.7, d: d);
        p.rightArm = Choreo.rampBack(t, 0.04, 0.24, 0.3, 1.0, overshoot: 1.2);
        p.y = 0.07 * Choreo.hop(t, 0.06, 0.42) * m;
        p.scaleY -= 0.05 * Choreo.bump(t, 0, 0.08) * m;
        p.lean = 0.05 * Choreo.seg(t, 0.05, 0.25) * m;
        if (lite) break;
        p.eyes = PetEyes.happy;
        p.mouth = PetMouth.open;
        p.earPerk = 0.85;

      case PetAnimation.rpsShake:
        final t = raw;
        final shakes = math.sin(math.pi * t / 0.5).abs() * Choreo.window(t, 0, d, fade: 0.12);
        p.rightArm = 0.35 + 0.3 * shakes;
        p.y = 0.02 * shakes * m;
        p.scaleY -= 0.03 * shakes * m;
        if (lite) break;
        p.eyes = PetEyes.wide;
        p.mouth = PetMouth.flat;
        p.brows = Brows.raised;
        p.earPerk = 0.5;

      case PetAnimation.pounce ||
          PetAnimation.bat ||
          PetAnimation.tumble ||
          PetAnimation.sniff ||
          PetAnimation.stretch ||
          PetAnimation.scratch ||
          PetAnimation.shake ||
          PetAnimation.leapCatch:
        if (reduced) {
          calmBlock(animation, p, t: raw, d: d, lite: lite);
          break;
        }
        switch (animation) {
          case PetAnimation.pounce:
            pounce(
              p,
              t: fit(raw, natural: 1.3, d: d),
              context: context,
              lite: lite,
            );
          case PetAnimation.bat:
            bat(
              p,
              t: fit(raw, natural: 0.6, d: d),
              context: context,
              lite: lite,
            );
          case PetAnimation.tumble:
            tumble(
              p,
              t: fit(raw, natural: 1.3, d: d),
              context: context,
              lite: lite,
            );
          case PetAnimation.sniff:
            sniff(
              p,
              t: fit(raw, natural: 1.8, d: d),
              context: context,
              lite: lite,
            );
          case PetAnimation.stretch:
            stretch(
              p,
              t: fit(raw, natural: 2.6, d: d),
              context: context,
              lite: lite,
            );
          case PetAnimation.scratch:
            scratch(
              p,
              t: fit(raw, natural: 2.0, d: d),
              context: context,
              lite: lite,
            );
          case PetAnimation.shake:
            shake(
              p,
              t: fit(raw, natural: 1.1, d: d),
              context: context,
              lite: lite,
            );
          default:
            leapCatch(
              p,
              t: fit(raw, natural: 1.1, d: d),
              context: context,
              lite: lite,
            );
        }

      default:
        break;
    }
    if (reduced) {
      switch (animation) {
        case PetAnimation.pounce ||
            PetAnimation.bat ||
            PetAnimation.tumble ||
            PetAnimation.sniff ||
            PetAnimation.stretch ||
            PetAnimation.scratch ||
            PetAnimation.shake ||
            PetAnimation.leapCatch ||
            PetAnimation.roll:
          break;
        default:
          // Reduced Motion: gestures become small, slow paw lifts.
          p.leftArm *= 0.3;
          p.rightArm *= 0.3;
      }
    }
  }

  static final Track leanForwardTrack = Track([(0, 0, Curve.linear), (0.3, 1, Curve.back), (1.0, 1, Curve.hold), (1.4, 0, Curve.smooth)]);

  // MARK: Look around

  /// Glances ahead (ears swivel, head turns), turns right round to look behind, turns back and peeks upward. The turns
  /// squeeze the body thin with the tail tucked, so the change of side reads as a turn and not a flip.
  static final Track lookAroundX = Track([
    (0, 0.15, Curve.linear),
    (0.22, 0.9, Curve.easeOut),
    (0.84, 0.9, Curve.hold),
    (0.94, -0.9, Curve.easeOut),
    (1.74, -0.9, Curve.hold),
    (1.84, 0.5, Curve.easeOut),
    (2.0, 0.1, Curve.smooth),
    (2.6, 0.15, Curve.smooth),
  ]);
  static final Track lookAroundY = Track([
    (0, 0, Curve.linear),
    (1.3, 0, Curve.hold),
    (1.42, 0.25, Curve.easeOut),
    (1.7, 0.25, Curve.hold),
    (1.86, 0, Curve.smooth),
    (2.02, -0.65, Curve.easeOut),
    (2.36, -0.65, Curve.hold),
    (2.6, 0, Curve.smooth),
  ]);

  static void lookAround(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final reduced = context.reducedMotion;
    final ahead = Choreo.window(t, 0.1, 0.9, fade: 0.2);
    final behind = Choreo.window(t, 0.98, 1.8, fade: 0.2);
    final up = Choreo.window(t, 1.96, 2.5, fade: 0.16);
    if (!reduced) {
      if (t >= 0.95 && t < 1.85) p.facing = -p.facing;
      PetTurn.apply(p, t: t, at: 0.95, motion: m);
      PetTurn.apply(p, t: t, at: 1.85, motion: m);
    }
    p.lean += 0.04 * (ahead + behind) * m;
    if (lite) return;
    p.lookX = lookAroundX(t);
    p.lookY = lookAroundY(t);
    final curious = Choreo.window(t, 1.3, 1.72, fade: 0.1);
    if (reduced) {
      p.tilt = 0.06 * (ahead - behind);
    } else {
      p.headTurn = 0.85 * (ahead + behind);
      p.tilt = 0.15 * ahead - 0.15 * behind - 0.06 * up;
      // The front ear swivels towards the view (own frame: the facing side), the other follows.
      p.earRight += 0.35 * (ahead + behind);
      p.earLeft += 0.15 * (ahead + behind);
      p.earLeft -= PetLife.flick(t - 1.32) * 1.5;
    }
    p.earPerk = 0.3 + 0.25 * (ahead + behind) + 0.4 * curious + 0.55 * up;
    p.eyes = curious > 0.3 || (up > 0.5 && t < 2.3) ? PetEyes.wide : PetEyes.open;
    p.mouth = curious > 0.4 ? PetMouth.o : PetMouth.cat;
    // Blinks as the gaze sweeps across at each turn.
    p.eyeOpenness = math.min(p.eyeOpenness, 1 - 0.95 * math.max(PetLife.blinkShape(t - 0.88), PetLife.blinkShape(t - 1.78)));
  }

  // MARK: Play building blocks

  /// Butt-wiggle, a leap that tips nose-down onto the prey, a pin, and a hop back.
  static void pounce(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    const k = bodyWidthsPerPathUnit;
    final crouch = Choreo.window(t, 0, 0.56, fade: 0.14);
    // The rear sways at 4 Hz (a lean, so the feet stay planted) and the tail tip twitches.
    final wiggle = math.sin((t - 0.12) * 2 * math.pi * 4) * Choreo.window(t, 0.12, 0.52, fade: 0.1);
    p.scaleY -= 0.14 * crouch * m;
    p.scaleX += 0.1 * crouch * m;
    p.lean = (-0.05 * crouch + 0.06 * wiggle) * m;
    final leap = Choreo.seg(t, 0.52, 0.88);
    final back = Choreo.seg(t, 1.0, 1.24);
    p.x = (0.16 * Ease.smooth(leap) - 0.16 * Ease.smooth(back)) * m;
    // Nose up on take-off, nose down over the last part of the flight, level again after the pin.
    final noseDown = Choreo.ramp(t, 0.62, 0.86, 0, 1) * (1 - Choreo.smooth(Choreo.seg(t, 0.94, 1.08)));
    p.rotation = (-0.08 * Choreo.bump(t, 0.5, 0.7) + 0.3 * noseDown) * p.facing * m;
    final flight = 0.36 * Choreo.hop(t, 0.52, 0.88) * m + 0.05 * Choreo.hop(t, 1.0, 1.24) * m;
    p.y = math.max(flight, Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY));
    final reach = Choreo.window(t, 0.5, 0.95, fade: 0.08);
    final pin = Choreo.window(t, 0.86, 1.0, fade: 0.04);
    p.leftArm = math.max(0.0, 0.6 * reach - 0.2 * pin);
    p.rightArm = math.max(0.0, 0.66 * reach - 0.2 * pin);
    p.tailWag = (0.9 * math.sin((t - 0.12) * 2 * math.pi * 4 + 1.2) * crouch + 0.4 * math.sin(t * 6)) * m;
    p.tailLift = 0.6 * crouch;
    if (lite) return;
    p.eyes = t < 0.95 ? PetEyes.wide : PetEyes.happy;
    p.eyeScale = 1 + 0.2 * crouch;
    p.lookX = 0.9;
    p.lookY = 0.35 + 0.3 * noseDown;
    p.headTurn = 0.5 * crouch;
    p.earPerk = 0.85;
    p.mouth = t < 0.5 ? PetMouth.tiny : (t < 0.95 ? PetMouth.open : PetMouth.grin);
    p.blush = 0.55;
    if (t > 0.6 && t < 0.9) {
      PetFX.streak(p, x: -0.1, y: 0.4, angle: -0.35, length: 0.9, amount: Choreo.bump(t, 0.6, 0.9) * 0.8);
    }
    // Touchdown dust where the front paws land.
    PetFX.dustPuff(p, age: t - 0.86, worldX: 0.16 * m * k + 0.4, strength: 0.6);
  }

  /// Wind up, swipe down through the target with a streak, a squash on the hit, recover.
  static void bat(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final hit = Choreo.bump(t, 0.2, 0.31);
    if (t < 0.17) {
      p.rightArm = Choreo.rampOut(t, 0, 0.17, 0.1, 1.0);
    } else if (t < 0.27) {
      p.rightArm = Choreo.ramp(t, 0.17, 0.27, 1.0, 0.0);
    } else {
      p.rightArm = Choreo.ramp(t, 0.3, 0.58, 0.0, 0.1) + 0.06 * Choreo.bump(t, 0.25, 0.42);
    }
    p.lean = (-0.05 * Choreo.bump(t, 0, 0.2) + 0.08 * Choreo.window(t, 0.17, 0.46, fade: 0.08)) * m;
    p.scaleY -= (0.03 * Choreo.bump(t, 0.02, 0.18) + 0.07 * hit) * m;
    p.scaleX += (0.02 * Choreo.bump(t, 0.02, 0.18) + 0.05 * hit) * m;
    p.tailWag += 0.6 * Choreo.bump(t, 0.15, 0.45) * m;
    if (lite) return;
    p.eyes = t < 0.3 ? PetEyes.wide : PetEyes.open;
    p.eyeScale = 1.12 - 0.1 * hit;
    p.lookX = 0.85;
    p.lookY = 0.35;
    p.headTurn = 0.6;
    p.earPerk = 0.7 - 0.45 * hit;
    p.mouth = t < 0.24 ? PetMouth.tiny : (t < 0.45 ? PetMouth.o : PetMouth.smile);
    PetFX.streak(p, x: 0.55, y: 0.5, angle: 1.1, length: 1.0, amount: Choreo.bump(t, 0.17, 0.36));
  }

  /// Curl into a ball and roll over forwards, then a dizzy recovery.
  static void tumble(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final squash = Choreo.bump(t, 0, 0.16);
    final roll = Choreo.seg(t, 0.12, 0.82);
    final balled = Choreo.window(t, 0.06, 0.9, fade: 0.18);
    p.scaleY -= (0.12 * squash + 0.1 * balled) * m;
    p.scaleX += (0.1 * squash - 0.06 * balled) * m;
    p.rotation = 2 * math.pi * Ease.smooth(roll) * p.facing;
    // A round arc: up and a little forward while going over, back down onto the feet.
    p.x = 0.06 * math.sin(math.pi * roll) * m;
    p.y = 0.07 * Ease.hop(roll) * m + Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY);
    final dizzy = Choreo.window(t, 0.8, 1.3, fade: 0.15);
    p.holdFront = 0.85 * balled;
    p.tailCurl = 1.0 * balled;
    p.tailLift = -0.4 * balled;
    if (lite) return;
    p.eyes = t < 0.82 ? PetEyes.closed : (t < 1.15 ? PetEyes.dizzy : PetEyes.happy);
    p.mouth = t < 0.82 ? PetMouth.o : PetMouth.wavy;
    p.earPerk = -1.1 * balled;
    p.earLeft -= 0.3 * balled;
    p.earRight -= 0.3 * balled;
    p.tilt = 0.12 * math.sin(t * 13) * dizzy;
    p.earLeft += 0.25 * math.sin(t * 13) * dizzy;
    p.earRight += 0.25 * math.sin(t * 13 + 1.2) * dizzy;
    PetFX.dizzyStars(p, t: t, amount: dizzy);
  }

  /// Nose down, quick sniffs that bob the head, then a satisfied look up.
  static void sniff(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final down = Choreo.window(t, 0, 1.45, fade: 0.3);
    final sniffTap = Choreo.taps(t, start: 0.35, spacing: 0.25, count: 4, width: 0.14);
    p.lean = (0.1 * down + 0.03 * sniffTap.amount) * m;
    p.scaleY -= (0.06 * down + 0.035 * sniffTap.amount) * m;
    p.scaleX += (0.04 * down + 0.015 * sniffTap.amount) * m;
    p.tailLift = 0.55 * down;
    p.tailWag = 0.5 * math.sin(t * 9) * down * m;
    if (lite) return;
    p.lookX = 0.45;
    p.lookY = 0.9 * down;
    p.headTurn = 0.4 * down;
    p.tilt = 0.04 * sniffTap.amount;
    p.eyes = PetEyes.open;
    p.eyeOpenness = math.min(p.eyeOpenness, 1 - 0.35 * down);
    p.earPerk = 0.6 * down;
    p.earRight += 0.12 * sniffTap.amount;
    p.mouth = sniffTap.amount > 0.3 ? PetMouth.tiny : PetMouth.cat;
    if (t > 1.45) {
      p.eyes = t < 1.75 ? PetEyes.happy : PetEyes.open;
      p.mouth = PetMouth.smile;
      p.earPerk = math.max(p.earPerk, 0.6 * Choreo.smooth(Choreo.seg(t, 1.42, 1.62)));
      p.earLeft -= PetLife.flick(t - 1.5) * 1.4;
    }
    if (sniffTap.index >= 0) {
      p.add(
        Effect(
          EffectKind.sniff,
          x: 0.24,
          y: 0.3,
          scale: 0.95,
          opacity: sniffTap.amount,
          variant: sniffTap.index.remainder(2),
          phase: Choreo.seg(t - 0.35 - sniffTap.index.toDouble() * 0.25, 0, 0.14),
        ),
      );
    }
  }

  /// Play-bow with the tail up, then a big stretch and a yawn.
  static void stretch(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final bow = Choreo.window(t, 0, 1.25, fade: 0.38);
    final up = Choreo.window(t, 1.15, 2.3, fade: 0.32);
    final amount = math.max(m, 0.3);
    p.rotation = 0.22 * bow * p.facing * m;
    p.y = Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY);
    p.scaleX += (0.1 * bow - 0.04 * up) * amount;
    p.scaleY += (-0.08 * bow + 0.1 * up) * amount;
    p.rightArm = 0.32 * bow + 0.78 * up;
    p.leftArm = 0.18 * bow + 0.78 * up;
    p.tailLift = 0.9 * bow + 0.4 * up;
    p.tailCurl = -0.5 * bow;
    p.tailWag = 0.5 * math.sin(t * 5) * bow * m;
    if (lite) return;
    p.eyes = PetEyes.closed;
    p.tilt = -0.08 * up;
    p.mouth = bow > 0.5 ? PetMouth.o : (up > 0.3 ? PetMouth.yawn : PetMouth.cat);
    if (t > 2.3) {
      p.mouth = (t * 12).toInt().remainder(2) == 0 ? PetMouth.nom : PetMouth.cat;
      p.eyes = PetEyes.sleepy;
    }
    p.earPerk = -0.5 * up + 0.2 * bow;
    p.blush = 0.5;
  }

  /// Hind foot scratching behind the ear, blissful face.
  static void scratch(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final lift = Choreo.window(t, 0.05, 1.7, fade: 0.25);
    final scratching = Choreo.window(t, 0.3, 1.55, fade: 0.1);
    final rub = math.sin((t - 0.3) * 2 * math.pi * 4.5);
    p.kick = 0.9 * lift + 0.1 * rub * scratching;
    p.lean = -0.06 * lift * m;
    p.scaleY -= 0.04 * lift * m;
    p.scaleX += 0.02 * lift * m;
    // The whole body jiggles a little with each stroke.
    p.scaleY += 0.012 * rub * scratching * m;
    if (lite) return;
    p.tilt = 0.2 * lift * p.facing * math.max(m, 0.4) + 0.04 * rub * scratching;
    p.headTurn = -0.3 * lift;
    p.eyes = scratching > 0.3 ? PetEyes.happy : PetEyes.closed;
    p.mouth = scratching > 0.3 ? PetMouth.blep : PetMouth.smile;
    p.blush = 0.5 + 0.3 * scratching;
    p.earPerk = -0.2;
    // The scratched (front) ear flaps with the foot.
    p.earRight += (0.45 * rub - 0.15) * scratching;
    if (scratching > 0.3) {
      p.add(Effect(EffectKind.shakeLines, x: 0.52, y: 0.9, scale: 0.6, opacity: 0.75 * scratching * (0.55 + 0.45 * rub.abs()), variant: 1));
    }
    if (t > 1.7) {
      p.eyes = PetEyes.open;
      p.tilt = 0.08 * math.sin((t - 1.7) * 18) * Choreo.window(t, 1.7, 2.0, fade: 0.06);
    }
  }

  /// A wet-dog shake with flapping ears, motion lines and droplets.
  static void shake(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    const k = bodyWidthsPerPathUnit;
    final brace = Choreo.bump(t, 0, 0.16);
    final amount = Choreo.window(t, 0.1, 0.86, fade: 0.18);
    final wobble = math.sin((t - 0.1) * 2 * math.pi * 5);
    p.rotation = 0.2 * wobble * amount * m;
    p.y = Choreo.floorLift(p.rotation, scaleX: p.scaleX, scaleY: p.scaleY);
    p.lean = 0.06 * wobble * amount * m;
    p.scaleY -= (0.05 * brace + 0.03 * wobble.abs() * amount) * m;
    p.scaleX += (0.04 * brace + 0.05 * amount) * m;
    p.tailWag = 1.6 * math.sin((t - 0.1) * 2 * math.pi * 5 + 1.2) * amount * m;
    // All fluffed up afterwards.
    final fluff = Choreo.window(t, 0.85, 1.1, fade: 0.12);
    p.scaleX += 0.05 * fluff * m;
    if (lite) return;
    p.eyes = amount > 0.2 ? PetEyes.squint : (t > 0.86 ? PetEyes.happy : PetEyes.open);
    p.mouth = amount > 0.2 ? PetMouth.wavy : PetMouth.smile;
    p.earLeft += 0.6 * math.sin((t - 0.1) * 2 * math.pi * 5 - 0.8) * amount;
    p.earRight += 0.6 * math.sin((t - 0.1) * 2 * math.pi * 5 - 0.2) * amount;
    if (amount > 0.3) {
      p.add(Effect(EffectKind.shakeLines, x: -0.62, y: 0.5, scale: 0.9, opacity: amount, variant: 0));
      p.add(Effect(EffectKind.shakeLines, x: 0.62, y: 0.5, scale: 0.9, opacity: amount, variant: 1));
    }
    for (var index = 0; index < 6; index++) {
      final born = 0.22 + index.toDouble() * 0.1;
      final side = index % 2 == 0 ? -1.0 : 1.0;
      PetFX.ballistic(
        p,
        kind: EffectKind.droplet,
        t: t,
        born: born,
        fromX: p.x * k + side * 0.42,
        fromY: 0.72,
        side: side,
        speed: 0.9 + 0.5 * Ease.hash(index, context.seed),
        up: 0.9,
        seed: index,
        scale: 0.34,
        life: 0.5,
        spin: 0,
      );
    }
  }

  /// Crouch, leap up and clap a catch at the top, land and hug it.
  static void leapCatch(PetPose p, {required double t, required PoseContext context, required bool lite}) {
    final m = context.motion;
    final crouch = Choreo.bump(t, 0, 0.26);
    p.y = 0.52 * Choreo.hop(t, 0.22, 0.78) * m;
    p.scaleY -= 0.14 * crouch * m;
    p.scaleX += 0.11 * crouch * m;
    final reach = Choreo.ramp(t, 0.2, 0.4, 0.1, 1) * (1 - Choreo.smooth(Choreo.seg(t, 0.48, 0.6)));
    final hug = Choreo.window(t, 0.5, 1.1, fade: 0.12);
    p.leftArm = math.max(reach, 0.42 * hug);
    p.rightArm = math.max(reach, 0.42 * hug);
    p.shadow = 1 - 0.55 * p.y;
    p.tailLift = 0.6;
    p.tailWag = 0.8 * math.sin(t * 12) * m;
    if (lite) return;
    p.eyes = t < 0.48 ? PetEyes.wide : PetEyes.happy;
    p.eyeScale = 1 + 0.15 * crouch;
    p.lookY = -0.6 * Choreo.window(t, 0.1, 0.55, fade: 0.1);
    p.tilt = -0.1 * Choreo.window(t, 0.1, 0.55, fade: 0.1);
    p.mouth = t < 0.48 ? PetMouth.o : PetMouth.grin;
    p.earPerk = 1;
    p.blush = 0.7;
    if (t > 0.46 && t < 0.8) {
      final age = Choreo.seg(t, 0.46, 0.8);
      p.add(Effect(EffectKind.burst, x: 0, y: 1.08, scale: 0.8, opacity: 1 - age, variant: 1, phase: age));
    }
  }

  /// Reduced Motion versions of the building blocks: no travel, rotation or squash, no snapping limbs; expressions,
  /// gaze and slow paw gestures only.
  static void calmBlock(PetAnimation animation, PetPose p, {required double t, required double d, required bool lite}) {
    if (lite) return;
    final raw = t;
    final natural = animation.defaultDuration;
    final local = fit(raw, natural: natural, d: d);
    final present = Choreo.window(local, 0, natural, fade: math.max(0.3, natural / 4));
    final early = local < natural * 0.5;
    switch (animation) {
      case PetAnimation.pounce:
        p.eyes = early ? PetEyes.wide : PetEyes.happy;
        p.eyeScale = 1 + 0.15 * present;
        p.lookX = 0.8;
        p.lookY = 0.4;
        p.earPerk = 0.3 + 0.5 * present;
        p.mouth = early ? PetMouth.tiny : PetMouth.smile;
      case PetAnimation.bat:
        p.rightArm = 0.1 + 0.3 * present;
        p.eyes = PetEyes.wide;
        p.lookX = 0.8;
        p.lookY = 0.35;
        p.earPerk = 0.6 * present;
        p.mouth = early ? PetMouth.tiny : PetMouth.o;
      case PetAnimation.tumble:
        p.eyes = local < natural * 0.6 ? PetEyes.happy : PetEyes.dizzy;
        p.mouth = local < natural * 0.6 ? PetMouth.open : PetMouth.wavy;
        PetFX.dizzyStars(p, t: 0, amount: Choreo.window(local, natural * 0.6, natural, fade: 0.25));
      case PetAnimation.sniff:
        p.lookY = 0.8 * present;
        p.lookX = 0.45;
        p.eyeOpenness = math.min(p.eyeOpenness, 1 - 0.35 * present);
        p.earPerk = 0.5 * present;
        p.mouth = PetMouth.tiny;
        p.add(Effect(EffectKind.sniff, x: 0.24, y: 0.3, scale: 0.95, opacity: 0.8 * present, phase: 0.5));
      case PetAnimation.stretch:
        p.eyes = PetEyes.closed;
        p.mouth = Choreo.window(local, natural * 0.45, natural * 0.85, fade: 0.2) > 0.5 ? PetMouth.yawn : PetMouth.cat;
        p.earPerk = -0.4 * present;
      case PetAnimation.scratch:
        p.eyes = PetEyes.happy;
        p.mouth = PetMouth.blep;
        p.blush = 0.5 + 0.3 * present;
        p.earPerk = -0.2 * present;
      case PetAnimation.shake:
        p.eyes = Choreo.window(local, 0.15, natural * 0.8, fade: 0.1) > 0.5 ? PetEyes.squint : PetEyes.happy;
        p.mouth = PetMouth.wavy;
      case PetAnimation.leapCatch:
        p.eyes = early ? PetEyes.wide : PetEyes.happy;
        p.leftArm = 0.45 * present;
        p.rightArm = 0.45 * present;
        p.lookY = -0.6 * present;
        p.mouth = early ? PetMouth.o : PetMouth.grin;
      default:
        break;
    }
  }
}
