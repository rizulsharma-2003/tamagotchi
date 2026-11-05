// Port of Sources/TamagotchiCore/Animation/PetTinyFit.swift: fits a pose to the menu bar
// (or any spot where Mochi is about 12–16 pt tall).

import 'dart:math' as math;

import 'model/ease.dart';
import 'model/poses.dart';

abstract final class PetTinyFit {
  /// Lift compression scale (body heights).
  static const double liftScale = 0.26;

  /// Effects whose top is above this height (body heights above the feet) are eased down…
  static const double effectKnee = 0.95;

  /// …so that none goes higher than this.
  static const double effectCeiling = 1.38;

  /// At most this many effects are drawn.
  static const int maxEffects = 5;

  static double lift(double y) => y <= 0 ? y : liftScale * _tanh(y / liftScale);

  /// Eases an absolute height (body heights above the feet) under the ceiling.
  static double height(double h) {
    if (h <= effectKnee) return h;
    const span = effectCeiling - effectKnee;
    return effectKnee + span * _tanh((h - effectKnee) / span);
  }

  /// Draw priority at menu-bar size (null = not drawn) and how many of a kind to keep.
  static (int, int)? rank(EffectKind kind) => switch (kind) {
    EffectKind.ball ||
    EffectKind.yarn ||
    EffectKind.butterfly ||
    EffectKind.bubble ||
    EffectKind.treat ||
    EffectKind.fish ||
    EffectKind.berry ||
    EffectKind.cupcake ||
    EffectKind.frosting ||
    EffectKind.orb ||
    EffectKind.tangle => (0, 4),
    EffectKind.heart ||
    EffectKind.heartPop ||
    EffectKind.z ||
    EffectKind.note ||
    EffectKind.star ||
    EffectKind.sparkle ||
    EffectKind.noseBubble ||
    EffectKind.notice ||
    EffectKind.sneeze ||
    EffectKind.burst ||
    EffectKind.pop ||
    EffectKind.question ||
    EffectKind.exclamation ||
    EffectKind.sweat ||
    EffectKind.confetti ||
    EffectKind.clap => (1, 3),
    EffectKind.streak || EffectKind.sniff || EffectKind.dust => (2, 1),
    EffectKind.shakeLines || EffectKind.crumb || EffectKind.droplet => (2, 2),
    EffectKind.purr ||
    EffectKind.steam ||
    EffectKind.shadow ||
    EffectKind.speechDots ||
    EffectKind.speechLock ||
    EffectKind.speechQuestion ||
    EffectKind.plug ||
    EffectKind.thinkingDots => null,
  };

  static PetPose fit(PetPose pose) {
    final p = pose.copy();
    final y0 = pose.y;
    final y1 = lift(y0);
    p.y = y1;
    final lost = y0 - y1;
    if (lost > 0) {
      final stretch = math.min(0.04, 0.12 * lost);
      p.scaleY *= 1 + stretch;
      p.scaleX *= 1 - 0.6 * stretch;
    }
    p.effects = select(pose.effects).map((e) => e.copy()).toList();
    for (final e in p.effects) {
      if (e.kind == EffectKind.tangle) continue;
      final world = y0 + e.y;
      if (e.worldSpace) {
        // Floor props keep their place on the floor; airborne ones come down with the body.
        final airborne = Ease.smooth(Ease.segment(world, 0.15, 0.45));
        e.y = Ease.lerp(world - y1, e.y, airborne);
      }
      e.y = height(y1 + e.y) - y1;
    }
    return p;
  }

  /// Stable selection by rank: at most [maxEffects], each kind capped, faint ones dropped.
  static List<Effect> select(List<Effect> effects) {
    if (effects.isEmpty) return effects;
    final chosen = <int>[];
    for (var pass = 0; pass <= 2; pass++) {
      for (var index = 0; index < effects.length && chosen.length < maxEffects; index++) {
        final effect = effects[index];
        final r = rank(effect.kind);
        if (effect.opacity <= 0.12 || r == null || r.$1 != pass) continue;
        var count = 0;
        for (final other in chosen) {
          if (effects[other].kind == effect.kind) count++;
        }
        if (count < r.$2) chosen.add(index);
      }
    }
    chosen.sort();
    return chosen.map((i) => effects[i]).toList();
  }

  static double _tanh(double x) {
    final e2 = math.exp(2 * x);
    return (e2 - 1) / (e2 + 1);
  }
}
