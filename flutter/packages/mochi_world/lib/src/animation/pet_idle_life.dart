// Port of Sources/TamagotchiCore/Animation/PetIdleLife.swift (`enum PetLife`). The dev-tools helper
// `PetPoseEvaluator.idleBehaviour(at:seed:)` from the same file lives on PetPoseEvaluator (pet_pose_evaluator.dart).

import 'dart:math' as math;

import '../model/ease.dart';
import '../model/poses.dart';
import 'choreography.dart';

/// Where the eyes look and how far the head follows (Swift `PetLife.Gaze`).
class Gaze {
  const Gaze({required this.x, required this.y, required this.head});

  final double x;
  final double y;

  /// Slow head-follow of the gaze, -1…1.
  final double head;
}

/// The small idle behaviours (Swift `PetLife.IdleEvent`; same order as the Swift raw values).
enum IdleEvent {
  none,
  weightShift,
  headTilt,
  earPerk,
  tailFlick,
  smile,
  blep,
  lick,
  pawLift,
  hop,
  stretchUp,

  /// One ear swivels towards an imagined sound and the head turns to it.
  listen,

  /// The tail slowly curls up tight (or loosens), then relaxes.
  tailCurl,
}

/// Mochi's "alive" layer: breathing with a belly rise, natural blinks (single, double, slow), eye saccades with holds,
/// single-ear twitches, tail swishes, weight shifts and small idle behaviours. Everything is derived from global time
/// and the per-character seed, so it is deterministic, continues across animations and never synchronizes between
/// characters.
abstract final class PetLife {
  static const int _blinkSalt = 0xB11C0001;
  static const int _gazeSalt = 0x6A2E0002;
  static const int _earSalt = 0xEA250003;
  static const int _tailSalt = 0x7A110004;
  static const int _eventSalt = 0xE7E70005;
  static const int _dreamSalt = 0xD2EA0006;

  // MARK: Breathing

  /// -1 exhaled … 1 inhaled: a quicker inhale, a longer exhale and a short rest.
  static double breath(double g, {required double period, required double phase}) {
    final f = Ease.fract(g / period + phase);
    if (f < 0.4) return -1 + 2 * Ease.smooth(f / 0.4);
    if (f < 0.9) return 1 - 2 * Ease.smooth((f - 0.4) / 0.5);
    return -1;
  }

  // MARK: Blinking

  /// Eye openness 0…1 with an irregular natural rhythm. `slowChance` raises the share of slow, trusting blinks
  /// (watching, content).
  static double blink(double g, {required int seed, double slot = 3.4, double slowChance = 0.12}) {
    final s = seed ^ _blinkSalt;
    final n = (g / slot).floorToDouble().toInt();
    if (!(Ease.hash(n, s) > 0.1)) return 1;
    final start = n.toDouble() * slot + Ease.hash(n + 101, s) * (slot - 1.0);
    final local = g - start;
    if (!(local >= 0 && local < 0.9)) return 1;
    final kind = Ease.hash(n + 211, s);
    double closed;
    if (kind < 1 - slowChance - 0.16) {
      closed = blinkShape(local);
    } else if (kind < 1 - slowChance) {
      closed = math.max(blinkShape(local), blinkShape(local - 0.24));
    } else {
      closed = slowBlinkShape(local);
    }
    return 1 - 0.97 * closed;
  }

  /// Quick lid close (0.06 s), tiny hold, slightly slower open.
  static double blinkShape(double l) {
    if (!(l > 0 && l < 0.19)) return 0;
    if (l < 0.06) return Ease.smooth(l / 0.06);
    if (l < 0.09) return 1;
    return 1 - Ease.smooth((l - 0.09) / 0.1);
  }

  /// The slow "I trust you" blink: lids drift down, rest, and lift lazily.
  static double slowBlinkShape(double l) {
    if (!(l > 0 && l < 0.78)) return 0;
    if (l < 0.16) return Ease.smooth(l / 0.16);
    if (l < 0.4) return 1;
    return 1 - Ease.smooth((l - 0.4) / 0.38);
  }

  // MARK: Gaze

  /// Saccades: the eyes jump quickly to a new point, hold (about `slot` ± 50 %), and jump again; the head follows
  /// lazily. Rests look straight at the user.
  static Gaze gaze(
    double g, {
    required int seed,
    double slot = 3.8,
    (double, double) center = (0.04, 0.0),
    (double, double) range = (0.7, 0.3),
    double restChance = 0.35,
  }) {
    final s = seed ^ _gazeSalt;
    final n = (g / slot).floorToDouble().toInt();
    (double, double) target(int k) {
      if (Ease.hash(k * 3, s) < restChance) return center;
      return (center.$1 + range.$1 * (2 * Ease.hash(k * 3 + 1, s) - 1), center.$2 + range.$2 * (2 * Ease.hash(k * 3 + 2, s) - 1));
    }

    double saccadeTime(int k) => (k.toDouble() + 0.25 + 0.5 * Ease.hash(k + 77, s)) * slot;
    final t0 = target(n - 2), t1 = target(n - 1), t2 = target(n);
    final eyeBlend = Ease.smooth((g - saccadeTime(n)) / 0.075);
    final x = Ease.lerp(t1.$1, t2.$1, eyeBlend);
    final y = Ease.lerp(t1.$2, t2.$2, eyeBlend);
    final prevHead = Ease.smooth((g - saccadeTime(n - 1)) / 0.5);
    final headFrom = Ease.lerp(t0.$1, t1.$1, prevHead);
    final head = Ease.lerp(headFrom, t2.$1, Ease.smooth((g - saccadeTime(n)) / 0.5));
    // A whisper of drift during holds keeps the eyes from looking painted on.
    final drift = 0.025 * Choreo.noise(g * 0.9, s + 9);
    return Gaze(x: x + drift, y: y + 0.6 * drift, head: head);
  }

  // MARK: Ears and tail

  /// Occasional single-ear flicks, as outward angles (radians) per ear.
  static ({double left, double right}) earTwitch(
    double g, {
    required int seed,
    double slot = 3.1,
    double chance = 0.42,
    double strength = 1,
  }) {
    final s = seed ^ _earSalt;
    final n = (g / slot).floorToDouble().toInt();
    if (!(Ease.hash(n, s) < chance)) return (left: 0, right: 0);
    final start = n.toDouble() * slot + Ease.hash(n + 5, s) * (slot - 0.75);
    final l = g - start;
    if (!(l >= 0 && l < 0.75)) return (left: 0, right: 0);
    var amount = flick(l);
    if (Ease.hash(n + 9, s) > 0.62) amount += 0.8 * flick(l - 0.22);
    amount *= strength;
    return Ease.hash(n + 3, s) > 0.5 ? (left: 0, right: amount) : (left: amount, right: 0);
  }

  /// A quick outward flick that springs back with a little overshoot.
  static double flick(double l) {
    if (!(l > 0 && l < 0.45)) return 0;
    if (l < 0.05) return 0.4 * Ease.smooth(l / 0.05);
    final r = l - 0.05;
    return 0.4 * math.exp(-r * 13) * math.cos(r * 2 * math.pi * 4.2);
  }

  /// A lazy tail sway with an occasional flick of the tip.
  static ({double wag, double curl}) tail(double g, {required int seed, double energy = 1}) {
    final s = seed ^ _tailSalt;
    final phase = Ease.hash(1, s) * 6.28;
    final lazy = 0.36 * math.sin(2 * math.pi * g / 3.1 + phase) * (0.65 + 0.35 * Choreo.noise(g / 3.7, s)) * energy;
    var flickAmount = 0.0;
    const slot = 4.3;
    final n = (g / slot).floorToDouble().toInt();
    if (Ease.hash(n, s + 1) < 0.38) {
      final start = n.toDouble() * slot + Ease.hash(n + 2, s) * (slot - 0.9);
      final l = g - start;
      if (l > 0 && l < 0.9) flickAmount = math.exp(-l * 4.5) * math.sin(l * 2 * math.pi * 2.6);
    }
    return (wag: lazy + 0.7 * flickAmount * energy, curl: 0.25 * flickAmount.abs());
  }

  // MARK: Base layer shared by every animation

  /// Breathing, blinks, gaze, ear twitches and tail swish. One-shots build on top of this.
  static PetPose base(PoseContext context, {required bool lite}) {
    final p = PetPose();
    final g = context.time;
    final phase = Ease.hash(1, context.seed);
    final b = breath(g, period: 3.6, phase: phase);
    final amount = context.reducedMotion ? 0.5 : 1.0;
    p.breath = b;
    p.scaleY = 1 + 0.02 * b * amount;
    p.scaleX = 1 - 0.012 * b * amount;
    p.tailWag = 0.35 * math.sin(g * 2.2) * context.motion;
    if (lite) return p;
    p.eyeOpenness = blink(g, seed: context.seed);
    final gaze = PetLife.gaze(g, seed: context.seed);
    p.lookX = gaze.x;
    p.lookY = gaze.y;
    p.earPerk = 0.08 * math.sin(g / 3 + phase * 6.28);
    // The head turns lazily after the eyes (screen space equals Mochi's own frame here: facing right).
    p.headTurn = 0.55 * (gaze.head - 0.04) * (context.reducedMotion ? 0.5 : 1.0);
    if (!context.reducedMotion) {
      p.tilt = 0.04 * (gaze.head - 0.04);
      final twitch = earTwitch(g, seed: context.seed, chance: 0.3);
      p.earLeft = -twitch.left;
      p.earRight = twitch.right;
      final tail = PetLife.tail(g, seed: context.seed);
      p.tailWag = tail.wag;
      p.tailCurl = tail.curl;
    }
    return p;
  }

  // MARK: Idle

  /// The idle behaviour scheduled for this moment: at most one at a time, calm spacing.
  static ({IdleEvent event, double local, double side}) idleEvent(double g, {required int seed}) {
    final s = seed ^ _eventSalt;
    const slot = 3.2;
    final n = (g / slot).floorToDouble().toInt();
    final r = Ease.hash(n, s);
    final table = idleTable;
    var acc = 0.0;
    var chosen = IdleEvent.none;
    for (final (event, weight) in table) {
      acc += weight;
      if (r < acc) {
        chosen = event;
        break;
      }
    }
    if (chosen == IdleEvent.none) return (event: IdleEvent.none, local: 0, side: 1);
    final duration = idleDuration(chosen);
    final start = n.toDouble() * slot + Ease.hash(n + 13, s) * (slot - duration - 0.05);
    final local = g - start;
    if (!(local >= 0 && local <= duration)) return (event: IdleEvent.none, local: 0, side: 1);
    return (event: chosen, local: local, side: Ease.hash(n + 29, s) > 0.5 ? 1 : -1);
  }

  static const List<(IdleEvent, double)> idleTable = [
    (IdleEvent.none, 0.2),
    (IdleEvent.weightShift, 0.11),
    (IdleEvent.headTilt, 0.09),
    (IdleEvent.listen, 0.12),
    (IdleEvent.earPerk, 0.06),
    (IdleEvent.tailFlick, 0.08),
    (IdleEvent.tailCurl, 0.06),
    (IdleEvent.smile, 0.07),
    (IdleEvent.blep, 0.04),
    (IdleEvent.lick, 0.05),
    (IdleEvent.pawLift, 0.06),
    (IdleEvent.hop, 0.03),
    (IdleEvent.stretchUp, 0.03),
  ];

  static double idleDuration(IdleEvent event) => switch (event) {
    IdleEvent.none => 0,
    IdleEvent.weightShift => 2.3,
    IdleEvent.headTilt => 1.9,
    IdleEvent.earPerk => 1.5,
    IdleEvent.tailFlick => 0.9,
    IdleEvent.smile => 1.7,
    IdleEvent.blep => 1.2,
    IdleEvent.lick => 0.75,
    IdleEvent.pawLift => 1.4,
    IdleEvent.hop => 0.8,
    IdleEvent.stretchUp => 1.7,
    IdleEvent.listen => 2.0,
    IdleEvent.tailCurl => 2.6,
  };

  static void idle(PetPose p, {required PoseContext context, required bool lite}) {
    final g = context.time;
    final m = context.motion;
    final reduced = context.reducedMotion;
    final (:event, local: l, :side) = idleEvent(g, seed: context.seed);
    switch (event) {
      case IdleEvent.none:
        break;
      case IdleEvent.weightShift:
        final shift = Choreo.window(l, 0, 2.3, fade: 0.6);
        p.lean += side * 0.035 * shift * m;
        // The unweighted foot shuffles as the weight moves.
        p.step +=
            side * 0.55 * Choreo.bump(l, 0.05, 0.32) * (reduced ? 0.0 : 1.0) -
            side * 0.45 * Choreo.bump(l, 1.75, 2.0) * (reduced ? 0.0 : 1.0);
        if (!lite) p.lookX += 0.15 * side * shift;
      case IdleEvent.headTilt:
        if (lite) break;
        final tilt = Choreo.window(l, 0, 1.9, fade: 0.38);
        p.tilt += side * 0.1 * tilt * (reduced ? 0.4 : 1.0);
        p.earPerk += 0.2 * tilt;
        if (side > 0) {
          p.earRight += 0.18 * tilt;
        } else {
          p.earLeft -= 0.18 * tilt;
        }
        p.lookY -= 0.12 * tilt;
      case IdleEvent.earPerk:
        if (lite) break;
        final perk = Choreo.window(l, 0, 1.5, fade: 0.2);
        p.earPerk += 0.55 * perk;
        p.lookX = Ease.lerp(p.lookX, 0.75 * side, perk);
        p.lookY = Ease.lerp(p.lookY, -0.1, perk);
        p.eyeScale += 0.06 * perk;
      case IdleEvent.tailFlick:
        if (lite || reduced) break;
        p.tailWag += 1.0 * math.exp(-l * 3.5) * math.sin(l * 2 * math.pi * 3);
        p.tailCurl += 0.5 * Choreo.bump(l, 0, 0.9);
        p.tailLift += 0.4 * Choreo.bump(l, 0, 0.9);
      case IdleEvent.smile:
        if (lite) break;
        if (l > 0.1 && l < 1.6) p.mouth = PetMouth.smile;
        p.blush += 0.15 * Choreo.window(l, 0, 1.7, fade: 0.3);
      case IdleEvent.blep:
        if (lite) break;
        if (l > 0.12 && l < 1.05) p.mouth = PetMouth.blep;
      case IdleEvent.lick:
        if (lite) break;
        if (l > 0.1 && l < 0.42) {
          p.mouth = PetMouth.lick;
        } else if (l >= 0.42 && l < 0.6) {
          p.mouth = PetMouth.nom;
        }
      case IdleEvent.pawLift:
        final lift = Choreo.window(l, 0, 1.4, fade: 0.32);
        final knead = 0.07 * math.sin((l - 0.32) * 2 * math.pi * 2.4) * Choreo.window(l, 0.32, 1.08, fade: 0.1);
        final value = 0.3 * lift + knead;
        if (side > 0) {
          p.rightArm = math.max(p.rightArm, value);
        } else {
          p.leftArm = math.max(p.leftArm, value);
        }
        if (!lite) {
          p.lookY += 0.28 * lift;
          p.lookX = Ease.lerp(p.lookX, 0.3 * side, lift);
        }
      case IdleEvent.hop:
        final crouch = Choreo.bump(l, 0, 0.16);
        p.scaleY -= 0.05 * crouch * m;
        p.scaleX += 0.04 * crouch * m;
        p.y += 0.05 * Choreo.hop(l, 0.14, 0.44) * m;
        if (!lite && l > 0.12 && l < 0.62) {
          p.eyes = PetEyes.happy;
          p.mouth = PetMouth.smile;
        }
      case IdleEvent.listen:
        // The ear on that side snaps round like a little radar dish, the head follows, both relax.
        final ear = Choreo.window(l, 0, 1.9, fade: 0.1) * (1 - 0.25 * Choreo.window(l, 0.9, 1.3, fade: 0.15));
        final head = Choreo.window(l, 0.12, 1.95, fade: 0.4);
        if (!reduced) {
          if (side > 0) {
            p.earRight += 0.5 * ear;
          } else {
            p.earLeft -= 0.5 * ear;
          }
        }
        if (lite) break;
        p.headTurn += 0.55 * side * head;
        p.lookX = Ease.lerp(p.lookX, 0.8 * side, head);
        p.lookY = Ease.lerp(p.lookY, -0.05, head);
        p.earPerk += 0.25 * ear;
        p.eyeScale += 0.05 * head;
        p.tilt += 0.05 * side * head * (reduced ? 0.4 : 1.0);
      case IdleEvent.tailCurl:
        if (reduced) break;
        final curl = Choreo.window(l, 0, 2.6, fade: 0.7);
        p.tailCurl += (side > 0 ? 0.8 : -0.6) * curl;
        p.tailLift += 0.45 * curl;
      case IdleEvent.stretchUp:
        final stretch = Choreo.window(l, 0, 1.7, fade: 0.45);
        p.leftArm = math.max(p.leftArm, 0.5 * stretch);
        p.rightArm = math.max(p.rightArm, 0.5 * stretch);
        p.scaleY += 0.045 * stretch * (reduced ? 0.25 : 1.0);
        p.scaleX -= 0.025 * stretch * (reduced ? 0.25 : 1.0);
        if (!lite) {
          if (l > 0.25 && l < 1.4) {
            p.eyes = PetEyes.closed;
            p.mouth = PetMouth.o;
          }
          p.earPerk -= 0.3 * stretch;
        }
    }
  }

  // MARK: Watching the companion

  static void watch(PetPose p, {required PoseContext context, required bool lite}) {
    final g = context.time;
    final m = context.motion;
    final s = context.seed ^ _eventSalt;
    // Occasional lean forward: something interesting on the screen.
    const leanSlot = 6.3;
    final ln = (g / leanSlot).floorToDouble().toInt();
    var interest = 0.0;
    if (Ease.hash(ln, s + 41) < 0.4) {
      final start = ln.toDouble() * leanSlot + Ease.hash(ln + 1, s + 41) * (leanSlot - 2.6);
      interest = Choreo.window(g - start, 0, 2.6, fade: 0.5);
    }
    // Leaning towards the screen (a shear, so the feet stay planted and the pose stays upright).
    p.lean += (0.03 + 0.06 * interest) * m;
    if (lite) return;
    // Only watch's own ear twitches (below), not the idle base's: an attentive, not restless, listener.
    p.earLeft = 0;
    p.earRight = 0;
    final gaze = PetLife.gaze(g, seed: context.seed, slot: 1.6, center: (0.72, 0.12), range: (0.14, 0.1), restChance: 0.45);
    p.lookX = gaze.x;
    p.lookY = gaze.y;
    p.eyeOpenness = blink(g, seed: context.seed, slot: 3.8, slowChance: 0.3);
    p.earPerk = 0.45 + 0.25 * interest;
    p.eyeScale += 0.08 * interest;
    if (interest > 0.5) p.mouth = PetMouth.o;
    // Curious head tilts.
    const tiltSlot = 4.6;
    final tn = (g / tiltSlot).floorToDouble().toInt();
    if (Ease.hash(tn, s + 43) < 0.38) {
      final start = tn.toDouble() * tiltSlot + Ease.hash(tn + 1, s + 43) * (tiltSlot - 1.8);
      final side = Ease.hash(tn + 2, s + 43) > 0.5 ? 1.0 : -1.0;
      final tilt = Choreo.window(g - start, 0, 1.8, fade: 0.35);
      p.tilt = side * 0.09 * tilt * (context.reducedMotion ? 0.4 : 1.0);
      if (side > 0) {
        p.earRight += 0.12 * tilt;
      } else {
        p.earLeft -= 0.12 * tilt;
      }
    } else {
      p.tilt = 0.03 * math.sin(g * 0.8) * math.max(m, 0.3);
    }
    p.headTurn = 0.45 + 0.2 * interest;
    if (!context.reducedMotion) {
      // Ears swivel towards little sounds from the desk (about eight a minute).
      final twitch = earTwitch(g, seed: context.seed + 3, slot: 3.2, chance: 0.36);
      p.earLeft -= twitch.left;
      p.earRight += twitch.right * 1.2;
      final tail = PetLife.tail(g, seed: context.seed, energy: 0.8);
      p.tailWag = tail.wag;
      p.tailCurl = tail.curl + 0.2;
      p.tailLift = 0.2;
    }
  }

  // MARK: Gentle wave

  static void waveGently(PetPose p, {required PoseContext context, required bool lite}) {
    final g = context.time;
    final m = context.motion;
    final cycle = Ease.fract(g / 4.4) * 4.4;
    final reduced = context.reducedMotion;
    final anticipation = Choreo.bump(cycle, 0, 0.32);
    final raise = Choreo.rampBack(cycle, 0.22, 0.6, 0, 1, overshoot: 2.2) * (1 - Choreo.smooth(Choreo.seg(cycle, 1.95, 2.45)));
    final waving = Choreo.window(cycle, 0.55, 2.0, fade: 0.25);
    final wave = math.sin((cycle - 0.55) * 2 * math.pi * 2.2) * waving;
    if (reduced) {
      p.rightArm = 0.75 * Choreo.window(cycle, 0.1, 2.4, fade: 0.4);
    } else {
      p.rightArm = 0.1 - 0.08 * anticipation + 0.72 * raise + 0.14 * wave;
    }
    p.lean += (0.025 * wave - 0.015 * anticipation) * m;
    if (lite) return;
    p.lookX = 0.05 + 0.08 * math.sin(g * 0.7);
    p.lookY = -0.05;
    p.mouth = raise > 0.6 ? PetMouth.open : PetMouth.smile;
    p.eyes = raise > 0.6 && waving > 0.6 && (cycle * 2).toInt().remainder(3) == 0 ? PetEyes.happy : PetEyes.open;
    p.blush += 0.15 * raise;
    p.earPerk = 0.35 + 0.2 * raise;
    if (!reduced) {
      p.earRight += 0.1 * wave;
      p.earLeft += 0.06 * wave;
      p.tilt = -0.04 * wave;
      p.tailWag = 0.6 * math.sin(g * 5) * (0.4 + 0.6 * raise);
    }
  }

  // MARK: Sleep

  static void sleep(PetPose p, {required PoseContext context, required bool lite, required bool curled}) {
    final g = context.time;
    final m = context.motion;
    final reduced = context.reducedMotion;
    final s = context.seed ^ _dreamSalt;
    final period = curled ? 5.2 : 4.8;
    final b = breath(g, period: period, phase: Ease.hash(2, context.seed));
    p.breath = b;
    // A deep sigh now and then.
    const sighSlot = 11.0;
    final sn = (g / sighSlot).floorToDouble().toInt();
    var sigh = 0.0;
    if (Ease.hash(sn, s) < 0.5) {
      final start = sn.toDouble() * sighSlot + Ease.hash(sn + 1, s) * (sighSlot - 2.2);
      sigh = Choreo.bump(g - start, 0, 2.2);
    }
    final depth = reduced ? 0.6 : 1.0;
    if (curled) {
      p.scaleY = 0.82 + (0.022 * b + 0.015 * sigh) * depth;
      p.scaleX = 1.12 - (0.012 * b + 0.008 * sigh) * depth;
    } else {
      p.scaleY = 1 + (0.038 * b + 0.02 * sigh) * depth;
      p.scaleX = 1 - (0.022 * b + 0.012 * sigh) * depth;
    }
    p.y = 0;
    p.rotation = 0;
    p.tailWag = 0.12 * math.sin(g * 0.9) * m;
    p.tailCurl = curled ? 1 : 0.75;
    p.tailLift = curled ? 0.1 : -0.35;
    if (lite) return;
    p.eyes = PetEyes.closed;
    p.eyeOpenness = 1;
    p.mouth = PetMouth.cat;
    p.earPerk = curled ? -0.9 : -0.6;
    p.headTurn = 0;
    p.tilt = 0;
    // Deep sleep: no idle ear twitches, only the odd dream flick (about two a minute).
    p.earLeft = 0;
    p.earRight = 0;
    p.blush = 0.5 + 0.08 * (b + 1) / 2;
    p.lookX = 0;
    p.lookY = 0;
    // Dreams: a paw twitch, an ear flick, a little chew or a smile.
    const dreamSlot = 5.3;
    final dn = (g / dreamSlot).floorToDouble().toInt();
    if (Ease.hash(dn, s + 7) < 0.5) {
      final start = dn.toDouble() * dreamSlot + Ease.hash(dn + 1, s + 7) * (dreamSlot - 1.6);
      final l = g - start;
      final kind = Ease.hash(dn + 2, s + 7);
      if (l >= 0 && l < 1.6) {
        if (kind < 0.25 && !reduced) {
          final twitch = Choreo.bump(l, 0, 0.12) + 0.7 * Choreo.bump(l, 0.22, 0.34);
          p.rightArm = math.max(p.rightArm, 0.16 * twitch);
        } else if (kind < 0.55 && !reduced) {
          final flickAmount = flick(l);
          if (Ease.hash(dn + 3, s) > 0.5) {
            p.earRight += flickAmount;
          } else {
            p.earLeft -= flickAmount;
          }
        } else if (kind < 0.8) {
          if (l < 1.0) p.mouth = (l * 7).toInt().remainder(2) == 0 ? PetMouth.nom : PetMouth.cat;
        } else {
          if (l < 1.5) p.mouth = PetMouth.smile;
          p.blush += 0.15 * Choreo.bump(l, 0, 1.6);
        }
      }
    }
    PetFX.zParticles(p, g: g, x: curled ? 0.36 : 0.42, y: curled ? 0.72 : 0.95, reduced: reduced, slow: curled ? 1.15 : 1);
    // A nose bubble that swells as Mochi breathes out (some of the time), popping now and then.
    if (!curled) {
      final cyclePosition = g / period + Ease.hash(2, context.seed);
      final cycle = cyclePosition.floorToDouble().toInt();
      final local = cyclePosition - cyclePosition.floorToDouble();
      if (Ease.hash(cycle ~/ 3, s + 21) < 0.55) {
        final swell = (1 - b) / 2;
        final pops = cycle.remainder(3) == 2;
        if (pops && local > 0.9) {
          final age = (local - 0.9) / 0.1;
          p.add(Effect(EffectKind.pop, x: 0.16, y: 0.4, scale: 0.6, opacity: 1 - age, variant: 1, phase: age));
        } else if ((cycle - 1).remainder(3) == 2 && local < 0.4) {
          // Re-forms after the next breath in.
        } else {
          p.add(Effect(EffectKind.noseBubble, x: 0.08 + 0.08 * swell, y: 0.4, scale: 0.2 + 0.8 * swell * swell, opacity: 0.85));
        }
      }
    }
  }

  // MARK: Sit

  /// Sitting contentedly (the menu bar rests here for long stretches): open eyes with the usual blinks and glances, now
  /// and then a long contented squint or a blep, deeper breathing, and the tail wrapped round the feet with its tip
  /// flicking.
  static void sit(PetPose p, {required PoseContext context, required bool lite}) {
    final g = context.time;
    final m = context.motion;
    final reduced = context.reducedMotion;
    final s = context.seed ^ _eventSalt;
    final b = breath(g, period: 3.4, phase: Ease.hash(1, context.seed));
    p.breath = b;
    final depth = reduced ? 0.5 : 1.0;
    p.scaleY = 0.9 + 0.02 * b * depth;
    p.scaleX = 1.07 - 0.011 * b * depth;
    p.tailCurl = 0.95;
    p.tailLift = -0.3;
    p.tailWag = 0.12 * math.sin(g * 1.1) * m;
    if (!reduced) {
      const slot = 5.5;
      final n = (g / slot).floorToDouble().toInt();
      if (Ease.hash(n, s + 51) < 0.5) {
        final l = g - (n.toDouble() * slot + Ease.hash(n + 1, s + 51) * (slot - 1.1));
        if (l > 0 && l < 1.1) {
          p.tailWag += 0.75 * math.exp(-l * 3.8) * math.sin(l * 2 * math.pi * 2.2);
          p.tailCurl -= 0.35 * Choreo.bump(l, 0, 1.1);
          p.tailLift += 0.25 * Choreo.bump(l, 0, 1.1);
        }
      }
    }
    if (lite) return;
    p.earPerk = 0.35 + 0.05 * math.sin(g / 2.7);
    p.blush = 0.55;
    p.lookY += 0.04;
    // A long contented squint (eyes swap behind a blink at each end).
    const squintSlot = 9.0;
    final sn = (g / squintSlot).floorToDouble().toInt();
    if (Ease.hash(sn, s + 61) < 0.55) {
      final length = 1.5 + Ease.hash(sn + 2, s + 61);
      final from = sn.toDouble() * squintSlot + Ease.hash(sn + 1, s + 61) * (squintSlot - length - 0.3);
      final l = g - from;
      if (l > 0 && l < length) {
        p.eyes = PetEyes.happy;
        p.blush += 0.15;
      }
      final swap = math.max(blinkShape(l + 0.08), blinkShape(l - length + 0.08));
      p.eyeOpenness = math.min(p.eyeOpenness, 1 - 0.95 * swap);
    }
    // A blep every 15–25 s.
    const blepSlot = 20.0;
    final bn = (g / blepSlot).floorToDouble().toInt();
    final blepAt = bn.toDouble() * blepSlot + 2.5 + Ease.hash(bn, s + 71) * (blepSlot - 5);
    final bl = g - blepAt;
    if (bl > 0.12 && bl < 1.0) {
      p.mouth = PetMouth.blep;
      p.tilt += 0.05 * Choreo.window(bl, 0, 1.0, fade: 0.12) * (reduced ? 0.4 : 1.0);
    }
  }
}
