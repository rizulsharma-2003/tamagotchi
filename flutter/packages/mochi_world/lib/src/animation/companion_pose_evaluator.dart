// Port of Sources/TamagotchiCore/Animation/CompanionPoseEvaluator.swift (and the legacy effect-array builders of
// PetPoseEvaluator.swift that only the companion uses).

import 'dart:math' as math;

import '../events/events.dart' show AttentionKind;
import '../model/animations.dart';
import '../model/ease.dart';
import '../model/poses.dart';

/// Extra context for the companion that only real session state can provide.
class CompanionDetail {
  const CompanionDetail({this.waitingFor, this.subagents = 0});

  final AttentionKind? waitingFor;
  final int subagents;

  @override
  bool operator ==(Object other) => other is CompanionDetail && other.waitingFor == waitingFor && other.subagents == subagents;

  @override
  int get hashCode => Object.hash(waitingFor, subagents);
}

/// The companion's animation language: a sturdy little pixel creature that bobs, hops and squashes, expressive through
/// its eyes and stubby arms.
abstract final class CompanionPoseEvaluator {
  static CompanionPose pose(
    CompanionAnimation animation, {
    required double elapsed,
    double? duration,
    required PoseContext context,
    CompanionDetail detail = const CompanionDetail(),
  }) {
    final t = elapsed;
    final p = basePose(context);
    final m = context.motion;
    final g = context.time;
    final d = duration ?? animation.defaultDuration;
    final reduced = context.reducedMotion;

    switch (animation) {
      case CompanionAnimation.absent:
        p.opacity = 0;
        p.laptop.openness = 0;

      case CompanionAnimation.idleAtDesk || CompanionAnimation.scripted:
        // Now and then a little bounce on the spot.
        final cycle = Ease.fract(g / 11.3 + Ease.hash(5, context.seed)) * 11.3;
        p.y += 0.09 * Ease.hop(Ease.segment(cycle, 0, 0.36)) * m;
        p.scaleY = 1 - 0.1 * Ease.bump(cycle, 0.3, 0.46) * m;

      case CompanionAnimation.thinking:
        p.lookY = -0.45;
        p.lookX = 0.3 + 0.12 * math.sin(g * 0.7);
        p.leftArm = 0.42;
        p.reach = 0.2;
        p.antennaTint = AntennaTint.working;
        p.antennaGlow = 0.45 + 0.35 * (0.5 + 0.5 * math.sin(g * 4));
        p.rotation = 0.07 * math.sin(g * 1.4) * m;
        p.effects = [thinkingDots(g, reduced: reduced)];

      case CompanionAnimation.typing:
        p.reach = 1;
        final tap = reduced ? 0.0 : 1.0;
        p.leftArm = 0.1 + 0.12 * math.max(0.0, math.sin(g * 17)) * tap;
        p.rightArm = 0.1 + 0.12 * math.max(0.0, math.sin(g * 17 + math.pi)) * tap;
        p.eyes = VisorEyes.focused;
        p.lookY = 0.35;
        p.lookX = 0.15 * math.sin(g * 0.8);
        p.y += 0.008 * math.sin(g * 17) * m;
        p.laptop.screen = LaptopScreen.code;
        p.laptop.scroll = g * 0.8;
        p.antennaTint = AntennaTint.working;
        p.antennaGlow = 0.7 + 0.1 * math.sin(g * 9);

      case CompanionAnimation.reading:
        // Holds the page out to the side so the face stays visible.
        p.held = HeldItem.document;
        p.leftArm = 0.58;
        p.rightArm = 0.12;
        p.reach = 0.4;
        final line = Ease.fract(g / 1.8);
        p.lookX = -0.85 + 0.45 * Ease.smooth(math.min(1.0, line * 1.2));
        p.lookY = -0.12 + 0.05 * (Ease.fract(g / 7.2) * 4).floorToDouble();
        p.laptop.screen = LaptopScreen.docs;
        p.antennaTint = AntennaTint.working;
        p.antennaGlow = 0.6;

      case CompanionAnimation.searching:
        p.held = HeldItem.magnifier;
        final sweep = math.sin(g * 1.6);
        p.rightArm = 0.6 + 0.15 * sweep;
        p.lookX = 0.55 * sweep;
        p.lookY = 0.1;
        p.eyes = VisorEyes.wide;
        p.rotation = 0.04 * sweep * m;
        p.laptop.screen = LaptopScreen.search;
        p.laptop.scroll = g;
        p.antennaTint = AntennaTint.working;
        p.antennaGlow = 0.65;

      case CompanionAnimation.runningCommand:
        p.reach = 0.55;
        p.eyes = VisorEyes.focused;
        p.lookY = 0.35;
        p.laptop.screen = LaptopScreen.terminal;
        p.laptop.scroll = g * 1.2;
        p.antennaTint = AntennaTint.working;
        p.antennaGlow = 0.45 + 0.45 * Ease.fract(g * 1.2);
        p.rightArm = 0.12 + 0.12 * Ease.bump(Ease.fract(g / 2.4) * 2.4, 0, 0.3);

      case CompanionAnimation.browsing:
        p.reach = 0.6;
        p.lookY = 0.3;
        p.lookX = 0.35 * math.sin(g * 2.1);
        p.laptop.screen = LaptopScreen.web;
        p.laptop.scroll = g * 0.5;
        p.antennaTint = AntennaTint.working;
        p.antennaGlow = 0.6;
        p.rightArm = 0.12 + 0.1 * Ease.bump(Ease.fract(g / 1.9) * 1.9, 0, 0.25);

      case CompanionAnimation.delegating:
        p.lookY = -0.35;
        p.lookX = 0.4 * math.sin(g * 0.9);
        p.leftArm = 0.5 + 0.2 * math.sin(g * 3) * math.max(m, 0.2);
        p.eyes = VisorEyes.happy;
        p.laptop.screen = LaptopScreen.code;
        p.laptop.scroll = g * 0.4;
        p.antennaTint = AntennaTint.working;
        p.antennaGlow = 0.7;

      case CompanionAnimation.waiting:
        final cycle = Ease.fract(g / 3.6) * 3.6;
        final wave = Ease.bump(cycle, 0, 1.2) * (reduced ? 0 : 1);
        p.rightArm = 0.85 + 0.1 * math.sin(cycle * 14) * wave;
        p.lookX = 0;
        p.lookY = -0.12;
        p.eyes = VisorEyes.normal;
        p.reach = 0.1;
        p.antennaTint = AntennaTint.attention;
        p.antennaGlow = 0.3 + 0.6 * (0.5 + 0.5 * math.sin(g * 2.4));
        final bubble = switch (detail.waitingFor) {
          AttentionKind.permission => EffectKind.speechLock,
          AttentionKind.mcpDialog || AttentionKind.backgroundAgent => EffectKind.speechQuestion,
          _ => EffectKind.speechDots,
        };
        p.effects = [Effect(bubble, x: -0.62, y: 1.32 + 0.02 * math.sin(g * 2) * m, scale: 1, opacity: 1)];

      case CompanionAnimation.detective:
        p.hat = HeldItem.detectiveHat;
        p.held = HeldItem.magnifier;
        final sweep = math.sin(g * 1.4);
        p.rightArm = 0.55 + 0.12 * sweep;
        p.lookX = 0.5 * sweep;
        p.eyes = VisorEyes.focused;
        p.antennaTint = AntennaTint.attention;
        p.antennaGlow = 0.6;
        p.laptop.screen = LaptopScreen.error;
        p.laptop.scroll = g * 0.3;
        final cycle = Ease.fract(g / 4.5) * 4.5;
        if (cycle < 1.4) {
          p.effects = [
            Effect(
              EffectKind.question,
              x: 0.5,
              y: 1.35,
              scale: 0.8 * Ease.outBack(Ease.segment(cycle, 0, 0.3)),
              opacity: Ease.bump(cycle, 0, 1.4),
            ),
          ];
        }

      case CompanionAnimation.rest:
        p.laptop.openness = 0.04;
        p.laptop.screen = LaptopScreen.off;
        p.held = HeldItem.coffee;
        final sipCycle = Ease.fract(g / 6.5) * 6.5;
        final sip = Ease.bump(sipCycle, 0, 1.6);
        p.rightArm = 0.42 + 0.3 * sip;
        p.eyes = sip > 0.4 ? VisorEyes.happy : VisorEyes.normal;
        p.eyeOpenness *= 0.85;
        p.mouth = VisorMouth.smile;
        p.rotation = -0.05 * m;
        p.y = 0.02 * math.sin(2 * math.pi * g / 4) * m;
        p.antennaGlow = 0.25;
        p.effects = [steam(g, x: 0.48, y: 0.78, reduced: reduced)];

      case CompanionAnimation.sleep:
        p.laptop.openness = 0.04;
        p.laptop.screen = LaptopScreen.off;
        p.visorBrightness = 0.35;
        p.eyes = VisorEyes.sleepy;
        p.antennaGlow = 0.06;
        p.antennaBend = 0.35;
        p.y = -0.03 + 0.008 * math.sin(2 * math.pi * g / 4.6) * m;
        p.reach = 0.1;
        p.effects = LegacyEffects.zParticles(g + 1.1, x: 0.38, y: 1.05, reduced: reduced);

      case CompanionAnimation.offline:
        p.laptop.openness = 0.04;
        p.laptop.screen = LaptopScreen.off;
        p.eyes = VisorEyes.off;
        p.visorBrightness = 0.3;
        p.antennaTint = AntennaTint.off;
        p.antennaGlow = 0;
        p.y = -0.02;
        p.effects = [Effect(EffectKind.plug, x: -0.6, y: 1.25, scale: 0.9, opacity: 0.9)];

      case CompanionAnimation.arrive:
        final drop = Ease.segment(t, 0, 0.8);
        p.y = (1 - Ease.outBack(drop, 1.2)) * 1.3 * m;
        final land = Ease.bump(t, 0.62, 0.95) * m;
        p.scaleY = 1 - 0.14 * land;
        p.scaleX = 1 + 0.1 * land;
        p.opacity = Ease.segment(t, 0, 0.35);
        p.laptop.openness = 0.04;
        p.laptop.screen = LaptopScreen.off;
        p.eyes = t < 0.75 ? VisorEyes.wide : VisorEyes.happy;
        p.shadow = Ease.segment(t, 0.2, 0.8);
        p.rightArm = 0.85 * Ease.bump(t, 1.0, d) + 0.1 * math.sin(t * 14) * Ease.bump(t, 1.0, d);
        p.effects = LegacyEffects.sparkles(t - 0.75, around: (0, 0.6), count: 4, spread: 0.7, seed: context.seed);

      case CompanionAnimation.setup:
        p.laptop.openness = Ease.outBack(Ease.segment(t, 0.2, 0.9), 1.1);
        p.laptop.screen = t < 0.9 ? LaptopScreen.off : LaptopScreen.celebrate;
        p.laptop.scroll = t;
        final stretch = Ease.bump(t, 0.9, 1.7);
        p.leftArm = 0.95 * stretch;
        p.rightArm = 0.95 * stretch;
        p.reach = 0.6 * Ease.segment(t, 0, 0.4) * (1 - stretch);
        p.eyes = t < 1.0 ? VisorEyes.focused : VisorEyes.happy;
        p.antennaGlow = 0.3 + 0.5 * Ease.segment(t, 0.6, 1.2);

      case CompanionAnimation.readTaskCard:
        p.held = HeldItem.taskCard;
        final lift = Ease.outBack(Ease.segment(t, 0, 0.3));
        p.leftArm = 0.58 * lift;
        p.rightArm = 0.15;
        p.lookX = Keys.value(t, const [(0, 0), (0.35, -0.9), (0.75, -0.4), (0.85, -0.9), (1.25, -0.4), (1.5, -0.2)]);
        p.lookY = -0.1;
        p.y += -0.025 * Ease.bump(t, 1.55, d) * m;
        p.eyes = t > 1.55 ? VisorEyes.happy : VisorEyes.normal;
        p.antennaTint = AntennaTint.working;
        p.antennaGlow = 0.6;

      case CompanionAnimation.concerned:
        p.eyes = VisorEyes.worried;
        p.mouth = VisorMouth.wavy;
        p.antennaTint = AntennaTint.alert;
        p.antennaGlow = 0.5 + 0.2 * math.sin(t * 6);
        p.held = HeldItem.errorBoard;
        p.leftArm = 0.6 * Ease.outBack(Ease.segment(t, 0, 0.35));
        p.lookX = -0.35;
        p.lookY = 0.1;
        p.rightArm = 0.88 * Ease.bump(t, 0.9, 2.3) + 0.05 * math.sin(t * 20) * Ease.bump(t, 1.0, 2.2) * math.max(m, 0.2);
        p.rotation = -0.05 * Ease.envelope(t, duration: d) * m;
        p.laptop.screen = LaptopScreen.error;
        p.effects = [
          Effect(EffectKind.exclamation, x: 0.42, y: 1.32, scale: Ease.outBack(Ease.segment(t, 0.05, 0.3)), opacity: Ease.bump(t, 0, 1.0)),
        ];

      case CompanionAnimation.celebrate:
        final jump = Ease.segment(t, 0.15, 0.75);
        p.y = 0.32 * Ease.hop(jump) * m;
        final crouch = (Ease.bump(t, 0, 0.17) + Ease.bump(t, 0.72, 0.95)) * m;
        final stretch = Ease.bump(t, 0.15, 0.45) * m;
        p.scaleY = 1 - 0.15 * crouch + 0.08 * stretch;
        p.scaleX = 1 + 0.1 * crouch - 0.05 * stretch;
        // A happy wiggle in mid-air (a spin would flatten a front-facing pixel sprite to a line).
        p.rotation = 0.09 * math.sin(t * 24) * Ease.bump(t, 0.2, 0.7) * m * (context.intensity == AnimationIntensity.calm ? 0 : 1);
        final arms = Ease.segment(t, 0.1, 0.3) * (1 - Ease.segment(t, 1.9, 2.4));
        p.leftArm = arms;
        p.rightArm = arms;
        p.eyes = VisorEyes.star;
        p.mouth = VisorMouth.grin;
        p.antennaGlow = 1;
        p.laptop.screen = LaptopScreen.celebrate;
        p.laptop.scroll = t;
        p.shadow = 1 - 0.5 * p.y;
        p.effects = LegacyEffects.confetti(t - 0.3, originY: 1.3, count: 8, seed: context.seed, reduced: reduced);

      case CompanionAnimation.trophy:
        p.held = HeldItem.trophy;
        p.rightArm = Ease.outBack(Ease.segment(t, 0, 0.4));
        p.leftArm = 0.4;
        p.y = 0.18 * Ease.hop(Ease.segment(t, 0.1, 0.5)) * m;
        p.scaleY = 1 - 0.12 * Ease.bump(t, 0.45, 0.65) * m;
        p.eyes = VisorEyes.star;
        p.mouth = VisorMouth.grin;
        p.antennaGlow = 1;
        p.laptop.screen = LaptopScreen.celebrate;
        p.laptop.scroll = t;
        p.effects = LegacyEffects.sparkles(t - 0.3, around: (0.45, 1.35), count: 4, spread: 0.35, seed: context.seed);

      case CompanionAnimation.packUp:
        p.laptop.openness = 1 - Ease.smooth(Ease.segment(t, 0.6, 1.4));
        p.laptop.screen = t < 0.6 ? LaptopScreen.idle : LaptopScreen.off;
        p.reach = 0.8 * (1 - Ease.segment(t, 1.2, 1.6));
        p.eyes = t > 1.3 ? VisorEyes.happy : VisorEyes.normal;
        p.mouth = VisorMouth.smile;
        if (t > 1.6) {
          p.held = HeldItem.coffee;
          p.rightArm = 0.42;
        }

      case CompanionAnimation.depart:
        p.laptop.openness = 0.04;
        p.laptop.screen = LaptopScreen.off;
        final wave = Ease.bump(t, 0, 0.7);
        p.rightArm = 0.9 * wave + 0.1 * math.sin(t * 16) * wave;
        p.eyes = VisorEyes.happy;
        p.y = 1.2 * Ease.smooth(Ease.segment(t, 0.6, d)) * m;
        p.opacity = 1 - Ease.segment(t, 0.7, d);
        p.shadow = 1 - Ease.segment(t, 0.6, 1.0);

      case CompanionAnimation.greet:
        final wave = Ease.bump(t, 0, d);
        p.rightArm = 0.88 * math.min(1.0, wave * 1.5) + 0.1 * math.sin(t * 15) * wave * math.max(m, 0.2);
        p.eyes = VisorEyes.happy;
        p.mouth = VisorMouth.smile;
        p.lookX = -0.3;
        p.y += 0.11 * Ease.hop(Ease.segment(t, 0, 0.4)) * m;

      case CompanionAnimation.nod:
        p.y += (-0.03 * Ease.bump(t, 0, 0.45) - 0.02 * Ease.bump(t, 0.45, 0.9)) * m;
        p.eyes = t > 0.1 && t < 0.7 ? VisorEyes.happy : VisorEyes.normal;

      case CompanionAnimation.wakeUp:
        p.visorBrightness = Ease.lerp(0.35, 1, Ease.segment(t, 0, 0.6));
        p.eyes = t < 0.4 ? VisorEyes.sleepy : (t < 0.8 ? VisorEyes.wide : VisorEyes.normal);
        p.antennaBend = 0.35 * (1 - Ease.outBack(Ease.segment(t, 0.3, 0.8)));
        p.antennaGlow = Ease.lerp(0.06, 0.5, Ease.segment(t, 0.2, 0.8));

      case CompanionAnimation.stretch:
        final stretch = Ease.bump(t, 0.1, 1.7);
        p.leftArm = 0.95 * stretch;
        p.rightArm = 0.95 * stretch;
        p.rotation = 0.05 * math.sin(t * 3) * stretch * m;
        p.eyes = VisorEyes.closed;
        p.mouth = VisorMouth.o;
        p.reach = 0;

      case CompanionAnimation.sip:
        p.held = HeldItem.coffee;
        p.rightArm = Keys.value(t, const [(0, 0.42), (0.35, 0.78), (1.5, 0.78), (1.85, 0.42)]);
        p.eyes = t > 0.5 && t < 1.6 ? VisorEyes.happy : VisorEyes.normal;
        p.mouth = VisorMouth.smile;
        p.effects = [steam(g, x: 0.45, y: 1.0, reduced: reduced)];

      case CompanionAnimation.dance:
        final beat = t / 0.8;
        final amount = Ease.envelope(t, duration: d, fadeIn: 0.25, fadeOut: 0.35);
        p.rotation = 0.1 * math.sin(2 * math.pi * beat) * m * amount;
        p.y += 0.1 * math.sin(2 * math.pi * beat).abs() * m * amount;
        p.scaleY = 1 - 0.08 * (1 - math.sin(2 * math.pi * beat).abs()) * m * amount;
        p.leftArm = (0.5 - 0.45 * math.sin(2 * math.pi * beat)) * amount;
        p.rightArm = (0.5 + 0.45 * math.sin(2 * math.pi * beat)) * amount;
        p.reach = 0;
        p.eyes = VisorEyes.happy;
        p.mouth = VisorMouth.grin;
        p.antennaGlow = 0.6 + 0.4 * math.sin(2 * math.pi * beat).abs();
        p.laptop.screen = LaptopScreen.celebrate;
        p.laptop.scroll = t;
        p.effects = LegacyEffects.notes(t + 0.4, x: 0.5, y: 1.15, reduced: reduced);

      case CompanionAnimation.presentCode:
        p.held = HeldItem.codeCard;
        p.leftArm = 0.7 * Ease.outBack(Ease.segment(t, 0, 0.35));
        p.eyes = VisorEyes.happy;
        p.mouth = VisorMouth.smile;
        p.lookX = -0.5;
        p.reach = 0;

      case CompanionAnimation.highFive:
        p.leftArm = Keys.value(t, [(0, 0.3), (0.2, 1.0), (d, 1.0)]);
        p.y += 0.16 * Ease.hop(Ease.segment(t, 0.05, 0.45)) * m;
        p.scaleY = 1 - 0.12 * Ease.bump(t, 0.4, 0.6) * m;
        p.eyes = VisorEyes.happy;
        p.mouth = VisorMouth.grin;
        p.reach = 0;

      case CompanionAnimation.catchBall:
        final catchPose = Ease.bump(t, 0.1, 0.7);
        p.leftArm = 0.7 * catchPose;
        p.rightArm = 0.7 * catchPose + 0.5 * Ease.bump(t, 0.7, 1.1);
        p.eyes = t < 0.35 ? VisorEyes.wide : VisorEyes.happy;
        p.antennaBend = 0.25 * math.sin(t * 18) * Ease.bump(t, 0, 0.5) * m;

      case CompanionAnimation.doubleTake:
        p.eyes = t > 0.25 && t < 1.0 ? VisorEyes.wide : VisorEyes.normal;
        p.lookX = Keys.value(t, const [(0, 0), (0.2, -0.75), (0.45, 0.2), (0.65, -0.8), (1.4, -0.6)]);
        p.y += 0.13 * Ease.bump(t, 0.25, 0.45) * m;
        p.effects = [
          Effect(
            EffectKind.exclamation,
            x: 0.45,
            y: 1.32,
            scale: Ease.outBack(Ease.segment(t, 0.25, 0.45)),
            opacity: Ease.bump(t, 0.25, 1.2),
          ),
        ];

      case CompanionAnimation.rpsShake:
        final shakes = math.sin(math.pi * t / 0.5).abs();
        p.leftArm = 0.35 + 0.3 * shakes;
        p.reach = 0;
        p.eyes = VisorEyes.focused;
        p.lookX = -0.5;
        p.y += 0.015 * shakes * m;

      case CompanionAnimation.pat:
        p.leftArm = 0.55 + 0.1 * math.sin(t * 10) * Ease.bump(t, 0.2, 1.4) * math.max(m, 0.3);
        p.eyes = VisorEyes.happy;
        p.mouth = VisorMouth.smile;
        p.lookX = -0.6;
        p.lookY = 0.2;
        p.effects = LegacyEffects.hearts(t - 0.4, x: -0.5, y: 0.9, count: 1, reduced: reduced);
    }
    return p;
  }

  static CompanionPose basePose(PoseContext context) {
    final p = CompanionPose();
    final g = context.time;
    final m = context.motion;
    final phase = Ease.hash(2, context.seed) * 6.28;
    p.y = 0.03 * math.sin(2 * math.pi * g / 2.8 + phase) * m;
    p.eyeOpenness = Ease.blink(g, seed: context.seed, period: 5.1);
    // Discrete glances: hold a direction, then move smoothly to the next.
    const period = 6.0;
    final cycle = (g / period).floorToDouble().toInt();
    final local = g - cycle * period;
    final from = (Ease.hash(cycle - 1, context.seed) - 0.5) * 0.8;
    final to = (Ease.hash(cycle, context.seed) - 0.5) * 0.8;
    p.lookX = Ease.lerp(from, to, Ease.smooth(Ease.segment(local, 0, 0.35)));
    p.antennaGlow = 0.35 + 0.08 * math.sin(g * 1.7);
    p.antennaBend = 0.06 * math.sin(g * 1.3) * m;
    p.reach = 0.3;
    p.laptop.scroll = g;
    p.shadow = 1;
    return p;
  }

  static Effect thinkingDots(double g, {required bool reduced}) => Effect(
    EffectKind.thinkingDots,
    x: 0.5,
    y: 1.35,
    scale: 1,
    opacity: 1,
    rotation: 0,
    variant: reduced ? 3 : (Ease.fract(g / 1.2) * 4).toInt(),
  );

  static Effect steam(double g, {required double x, required double y, required bool reduced}) =>
      Effect(EffectKind.steam, x: x, y: y, scale: 1, opacity: 0.8, rotation: reduced ? 0 : g, variant: 0);
}

/// PetPoseEvaluator's "legacy array builders" (Swift: `PetPoseEvaluator.zParticles` and friends), kept exactly as
/// before for the companion.
abstract final class LegacyEffects {
  static List<Effect> zParticles(double g, {required double x, required double y, required bool reduced}) => [
    for (var index = 0; index < 3; index++)
      () {
        final p = Ease.fract(g / 3.2 + index / 3);
        if (reduced) {
          return Effect(EffectKind.z, x: x + 0.12 * index, y: y + 0.2 * index, scale: 0.6 + 0.2 * index, opacity: 0.85);
        }
        return Effect(
          EffectKind.z,
          x: x + 0.22 * p,
          y: y + 0.55 * p,
          scale: 0.55 + 0.5 * p,
          opacity: math.sin(math.pi * p),
          rotation: -0.2 + 0.3 * p,
        );
      }(),
  ];

  static List<Effect> sparkles(
    double t, {
    required (double, double) around,
    required int count,
    required double spread,
    required int seed,
  }) => [
    for (var index = 0; index < count; index++)
      () {
        final angle = Ease.hash(index, seed) * 2 * math.pi;
        final radius = spread * (0.7 + 0.3 * Ease.hash(index + 11, seed));
        final delay = index * 0.18;
        final life = Ease.bump(t - delay, 0, 0.7);
        return Effect(
          EffectKind.sparkle,
          x: around.$1 + math.cos(angle) * radius,
          y: around.$2 + math.sin(angle) * radius * 0.6 + 0.1,
          scale: 0.5 + 0.6 * life,
          opacity: life,
          rotation: t * 2,
        );
      }(),
  ];

  static List<Effect> hearts(double t, {required double x, required double y, required int count, required bool reduced}) {
    final out = <Effect>[];
    for (var index = 0; index < count; index++) {
      final local = t - index * 0.35;
      if (!(local > 0 && local < 1.3)) continue;
      final p = local / 1.3;
      final sway = reduced ? 0.0 : 0.06 * math.sin(local * 7);
      out.add(
        Effect(
          EffectKind.heart,
          x: x + index * 0.12 - 0.12 + sway,
          y: y + (reduced ? 0.15 : 0.5 * p),
          scale: 0.55 + 0.35 * Ease.outBack(math.min(1.0, p * 3)),
          opacity: math.sin(math.pi * p),
        ),
      );
    }
    return out;
  }

  static List<Effect> notes(double t, {required double x, required double y, required bool reduced}) => [
    for (var index = 0; index < 2; index++)
      () {
        final p = Ease.fract(t / 1.6 + index * 0.5);
        return Effect(
          EffectKind.note,
          x: x + (reduced ? 0 : 0.15 * math.sin(p * 6)) + 0.12 * index,
          y: y + (reduced ? 0.1 : 0.45 * p),
          scale: 0.7,
          opacity: math.sin(math.pi * p),
          rotation: 0.2 * math.sin(p * 5),
          variant: index,
        );
      }(),
  ];

  static List<Effect> confetti(double t, {required double originY, required int count, required int seed, required bool reduced}) {
    if (!(t > 0 && t < 1.9)) return [];
    return [
      for (var index = 0; index < count; index++)
        () {
          final angle = Ease.lerp(-2.4, -0.7, Ease.hash(index, seed)) * -1;
          final speed = 0.6 + 0.5 * Ease.hash(index + 5, seed);
          final fall = t * t * 0.55;
          final x = math.cos(angle) * speed * math.min(t, 0.9) * (Ease.hash(index + 9, seed) > 0.5 ? 1 : -1);
          final y = originY + math.sin(angle) * speed * math.min(t, 0.6) - fall;
          final opacity = 1 - Ease.segment(t, 1.3, 1.9);
          if (reduced) {
            return Effect(
              EffectKind.confetti,
              x: math.cos(index.toDouble()) * 0.5,
              y: originY + 0.1 * (index % 3),
              scale: 0.6,
              opacity: opacity,
              variant: index % 4,
            );
          }
          return Effect(EffectKind.confetti, x: x, y: y, scale: 0.6, opacity: opacity, rotation: t * 8 + index, variant: index % 4);
        }(),
    ];
  }
}
