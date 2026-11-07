// Port of Sources/TamagotchiCore/Interactions/InteractionLibrary.swift: the sixteen scripted moments Mochi and Patch
// share, as beats over time, and their whole frames (both poses and the scene props).

import 'dart:math' as math;

import '../animation/companion_pose_evaluator.dart';
import '../animation/pet_pose_evaluator.dart';
import '../model/animations.dart';
import '../model/ease.dart';
import '../model/json.dart';
import '../model/poses.dart';

enum InteractionID {
  // Ambient (scheduled)
  coffeeDelivery('Coffee delivery'),
  showCode('Show and tell'),
  ballDistraction('Ball distraction'),
  rockPaperScissors('Rock, paper, scissors'),
  sleepWatch('Keeping watch'),
  chairSteal('Chair thief'),
  keyboardNap('Keyboard nap'),
  mysteryOrb('The mysterious glow'),
  // Triggered by real events or by the user
  welcome('Welcome'),
  highFive('High five'),
  victoryDance('Victory dance'),
  trophyCelebration('Tiny trophy'),
  caseClosed('Case closed'),
  detectiveHat('Detective mode'),
  graduation('Graduation'),
  syncDance('Synchronized dance');

  const InteractionID(this.title);
  final String title;
}

enum ScenePropKind { ball, orb, clap, confetti, sparkle, butterfly, yarn, leaf, dust, bubble, treat, crumb }

/// A prop that belongs to the scene rather than to one character.
class SceneProp {
  SceneProp(this.kind, {required this.x, required this.y, this.scale = 1, this.opacity = 1, this.rotation = 0, this.variant = 0});

  factory SceneProp.fromJson(Map<String, Object?> j) => SceneProp(
    enumByName(ScenePropKind.values, j['kind']) ?? ScenePropKind.sparkle,
    x: dbl(j, 'x', 0),
    y: dbl(j, 'y', 0),
    scale: dbl(j, 'scale', 1),
    opacity: dbl(j, 'opacity', 1),
    rotation: dbl(j, 'rotation', 0),
    variant: integer(j, 'variant', 0),
  );

  ScenePropKind kind;

  /// 0 = the pet's home position, 1 = the companion's.
  double x;

  /// Height above the floor in pet body heights.
  double y;
  double scale, opacity, rotation;
  int variant;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'x': x,
    'y': y,
    if (scale != 1) 'scale': scale,
    if (opacity != 1) 'opacity': opacity,
    if (rotation != 0) 'rotation': rotation,
    if (variant != 0) 'variant': variant,
  };
}

/// A running interaction.
class InteractionPlayback {
  InteractionPlayback({
    required this.id,
    required this.startedAt,
    required this.variant,
    required this.companionLoop,
    this.sessionLabel,
    this.petToken,
    this.companionToken,
  });

  final InteractionID id;
  final double startedAt;
  final int variant;

  /// What the companion was doing when it started; `.scripted` beats return to it.
  final CompanionAnimation companionLoop;
  int? petToken;
  int? companionToken;

  /// Project label when the interaction celebrates a specific session.
  final String? sessionLabel;

  double get duration => InteractionLibrary.script(id, variant: variant).duration;

  bool isFinished(double now) => now - startedAt >= duration;

  Map<String, Object?> toJson() => {
    'id': id.name,
    'startedAt': startedAt,
    'variant': variant,
    'companionLoop': companionLoop.name,
    'petToken': ?petToken,
    'companionToken': ?companionToken,
    'sessionLabel': ?sessionLabel,
  };

  static InteractionPlayback? fromJson(Object? json) {
    final j = asMap(json);
    final id = enumByName(InteractionID.values, j['id']);
    final loop = enumByName(CompanionAnimation.values, j['companionLoop']);
    if (id == null || loop == null) return null;
    return InteractionPlayback(
      id: id,
      startedAt: dbl(j, 'startedAt', 0),
      variant: integer(j, 'variant', 0),
      companionLoop: loop,
      sessionLabel: string(j, 'sessionLabel'),
      petToken: j['petToken'] is num ? (j['petToken'] as num).toInt() : null,
      companionToken: j['companionToken'] is num ? (j['companionToken'] as num).toInt() : null,
    );
  }
}

class PetBeat {
  const PetBeat(this.start, this.end, this.animation, this.from, this.to, this.held, this.hat, this.facing, this.lift);

  final double start;
  final double end;
  final PetAnimation animation;
  final double from;
  final double to;
  final HeldItem? held;
  final HeldItem? hat;
  final double facing;

  /// Height above the floor (e.g. sitting on the desk), in body heights.
  final (double, double) lift;
}

class CompanionBeat {
  const CompanionBeat(this.start, this.end, this.animation, this.from, this.to, this.held);

  final double start;
  final double end;

  /// `.scripted` means "whatever the companion was doing when the interaction began".
  final CompanionAnimation animation;
  final double from;
  final double to;
  final HeldItem? held;
}

class InteractionScript {
  const InteractionScript({
    required this.id,
    required this.duration,
    required this.pet,
    required this.companion,
    required this.requiresCompanion,
  });

  final InteractionID id;
  final double duration;
  final List<PetBeat> pet;
  final List<CompanionBeat> companion;
  final bool requiresCompanion;
}

class InteractionFrame {
  InteractionFrame({required this.pet, required this.companion, required this.props});

  final PetPose pet;
  final CompanionPose companion;
  final List<SceneProp> props;
}

enum RPSChoice {
  rock,
  paper,
  scissors;

  HeldItem get item => switch (this) {
    RPSChoice.rock => HeldItem.rock,
    RPSChoice.paper => HeldItem.paper,
    RPSChoice.scissors => HeldItem.scissors,
  };

  /// 1 if this beats [other], -1 if it loses, 0 for a tie.
  int outcome(RPSChoice other) {
    if (this == other) return 0;
    return switch ((this, other)) {
      (RPSChoice.rock, RPSChoice.scissors) || (RPSChoice.paper, RPSChoice.rock) || (RPSChoice.scissors, RPSChoice.paper) => 1,
      _ => -1,
    };
  }
}

abstract final class InteractionLibrary {
  /// Where the pet stands to interact with the companion (fraction of the path).
  static const double meet = 0.6;

  static PetBeat _pet(
    double start,
    double end,
    PetAnimation animation, {
    double at = 0,
    double? to,
    HeldItem? held,
    HeldItem? hat,
    double facing = 1,
    (double, double) lift = (0, 0),
  }) => PetBeat(start, end, animation, at, to ?? at, held, hat, facing, lift);

  static CompanionBeat _comp(double start, double end, CompanionAnimation animation, {double at = 0, double? to, HeldItem? held}) =>
      CompanionBeat(start, end, animation, at, to ?? at, held);

  static ({RPSChoice pet, RPSChoice companion}) rpsChoices(int variant) {
    final v = variant.abs();
    return (pet: RPSChoice.values[v % 3], companion: RPSChoice.values[(v ~/ 3) % 3]);
  }

  static InteractionScript script(InteractionID id, {int variant = 0}) {
    const m = meet;
    switch (id) {
      case InteractionID.coffeeDelivery:
        return InteractionScript(
          id: id,
          duration: 8.0,
          pet: [
            _pet(0, 0.6, PetAnimation.idle, held: HeldItem.coffee),
            _pet(0.6, 2.6, PetAnimation.carry, at: 0, to: m, held: HeldItem.coffee),
            _pet(2.6, 3.6, PetAnimation.offer, at: m, held: HeldItem.coffee),
            _pet(3.6, 5.0, PetAnimation.happyBounce, at: m),
            _pet(5.0, 7.4, PetAnimation.walk, at: m, to: 0, facing: -1),
            _pet(7.4, 8.0, PetAnimation.idle),
          ],
          companion: [
            _comp(0, 2.6, CompanionAnimation.scripted),
            _comp(2.6, 3.6, CompanionAnimation.greet),
            _comp(3.6, 6.2, CompanionAnimation.sip, held: HeldItem.coffee),
            _comp(6.2, 8.0, CompanionAnimation.scripted),
          ],
          requiresCompanion: true,
        );

      case InteractionID.showCode:
        final delighted = variant.remainder(2) == 1;
        return InteractionScript(
          id: id,
          duration: 6.6,
          pet: [
            _pet(0, 0.8, PetAnimation.watch),
            _pet(0.8, 2.2, PetAnimation.walk, at: 0, to: 0.5),
            _pet(2.2, 4.0, delighted ? PetAnimation.excitedJump : PetAnimation.confusedTilt, at: 0.5),
            _pet(4.0, 6.0, PetAnimation.walk, at: 0.5, to: 0, facing: -1),
            _pet(6.0, 6.6, PetAnimation.idle),
          ],
          companion: [
            _comp(0, 0.8, CompanionAnimation.scripted),
            _comp(0.8, 4.2, CompanionAnimation.presentCode),
            _comp(4.2, 6.6, CompanionAnimation.scripted),
          ],
          requiresCompanion: true,
        );

      case InteractionID.ballDistraction:
        return InteractionScript(
          id: id,
          duration: 6.4,
          pet: [
            _pet(0, 0.8, PetAnimation.blep, held: HeldItem.ball),
            _pet(0.8, 1.2, PetAnimation.offer, held: HeldItem.ball),
            _pet(1.2, 1.5, PetAnimation.offer),
            _pet(1.5, 4.3, PetAnimation.watch),
            _pet(4.3, 5.3, PetAnimation.happyBounce, held: HeldItem.ball),
            _pet(5.3, 6.4, PetAnimation.idle),
          ],
          companion: [
            _comp(0, 2.0, CompanionAnimation.scripted),
            _comp(2.0, 3.4, CompanionAnimation.catchBall),
            _comp(3.4, 6.4, CompanionAnimation.scripted),
          ],
          requiresCompanion: true,
        );

      case InteractionID.rockPaperScissors:
        final choices = rpsChoices(variant);
        final outcome = choices.pet.outcome(choices.companion);
        return InteractionScript(
          id: id,
          duration: 5.8,
          pet: [
            _pet(0, 0.4, PetAnimation.idle),
            _pet(0.4, 1.9, PetAnimation.rpsShake),
            _pet(1.9, 3.4, PetAnimation.watch, held: choices.pet.item),
            _pet(
              3.4,
              4.8,
              outcome > 0 ? PetAnimation.happyBounce : (outcome < 0 ? PetAnimation.concerned : PetAnimation.blep),
              held: choices.pet.item,
            ),
            _pet(4.8, 5.8, PetAnimation.idle),
          ],
          companion: [
            _comp(0, 0.4, CompanionAnimation.idleAtDesk),
            _comp(0.4, 1.9, CompanionAnimation.rpsShake),
            _comp(1.9, 3.4, CompanionAnimation.idleAtDesk, held: choices.companion.item),
            _comp(
              3.4,
              4.8,
              outcome < 0 ? CompanionAnimation.nod : (outcome > 0 ? CompanionAnimation.doubleTake : CompanionAnimation.greet),
              held: choices.companion.item,
            ),
            _comp(4.8, 5.8, CompanionAnimation.scripted),
          ],
          requiresCompanion: true,
        );

      case InteractionID.sleepWatch:
        if (variant.remainder(2) == 0) {
          return InteractionScript(
            id: id,
            duration: 24,
            pet: [
              _pet(0, 1.8, PetAnimation.yawn),
              _pet(1.8, 22, PetAnimation.sleep),
              _pet(22, 23.2, PetAnimation.wakeUp),
              _pet(23.2, 24, PetAnimation.idle),
            ],
            companion: [_comp(0, 24, CompanionAnimation.rest)],
            requiresCompanion: true,
          );
        }
        return InteractionScript(
          id: id,
          duration: 24,
          pet: [_pet(0, 24, PetAnimation.watch)],
          companion: [
            _comp(0, 2, CompanionAnimation.stretch),
            _comp(2, 22, CompanionAnimation.sleep),
            _comp(22, 23.2, CompanionAnimation.wakeUp),
            _comp(23.2, 24, CompanionAnimation.idleAtDesk),
          ],
          requiresCompanion: true,
        );

      case InteractionID.chairSteal:
        return InteractionScript(
          id: id,
          duration: 7.6,
          pet: [
            _pet(0, 1.6, PetAnimation.watch),
            _pet(1.6, 3.0, PetAnimation.walk, at: 0, to: 1.0),
            _pet(3.0, 5.6, PetAnimation.sit, at: 1.0, lift: (0.18, 0.18)),
            _pet(5.6, 7.0, PetAnimation.walk, at: 1.0, to: 0, facing: -1),
            _pet(7.0, 7.6, PetAnimation.idle),
          ],
          companion: [
            _comp(0, 1.2, CompanionAnimation.stretch),
            _comp(1.2, 2.2, CompanionAnimation.idleAtDesk, at: 0, to: 0.45),
            _comp(2.2, 4.2, CompanionAnimation.sip, at: 0.45, held: HeldItem.coffee),
            _comp(4.2, 5.0, CompanionAnimation.idleAtDesk, at: 0.45, held: HeldItem.coffee),
            _comp(5.0, 6.4, CompanionAnimation.doubleTake, at: 0.45, held: HeldItem.coffee),
            _comp(6.4, 7.6, CompanionAnimation.idleAtDesk, at: 0.45, to: 0, held: HeldItem.coffee),
          ],
          requiresCompanion: true,
        );

      case InteractionID.keyboardNap:
        return InteractionScript(
          id: id,
          duration: 14,
          pet: [
            _pet(0, 2.0, PetAnimation.walk, at: 0, to: 0.8),
            _pet(2.0, 2.6, PetAnimation.happyBounce, at: 0.8, lift: (0, 0.42)),
            _pet(2.6, 11, PetAnimation.curl, at: 0.8, lift: (0.42, 0.42)),
            _pet(11, 12.2, PetAnimation.wakeUp, at: 0.8, lift: (0.42, 0.42)),
            _pet(12.2, 12.8, PetAnimation.happyBounce, at: 0.8, lift: (0.42, 0)),
            _pet(12.8, 14, PetAnimation.walk, at: 0.8, to: 0, facing: -1),
          ],
          companion: [
            _comp(0, 2.6, CompanionAnimation.scripted),
            _comp(2.6, 4.0, CompanionAnimation.doubleTake),
            _comp(4.0, 5.6, CompanionAnimation.pat),
            _comp(5.6, 11.6, CompanionAnimation.rest),
            _comp(11.6, 14, CompanionAnimation.scripted),
          ],
          requiresCompanion: true,
        );

      case InteractionID.mysteryOrb:
        return InteractionScript(
          id: id,
          duration: 8,
          pet: [
            _pet(0, 1.0, PetAnimation.watch),
            _pet(1.0, 3.6, PetAnimation.lookAround),
            _pet(3.6, 5.4, PetAnimation.confusedTilt),
            _pet(5.4, 6.6, PetAnimation.watch),
            _pet(6.6, 7.6, PetAnimation.happyBounce),
            _pet(7.6, 8, PetAnimation.idle),
          ],
          companion: [
            _comp(0, 1.4, CompanionAnimation.scripted),
            _comp(1.4, 5.4, CompanionAnimation.searching),
            _comp(5.4, 6.6, CompanionAnimation.doubleTake),
            _comp(6.6, 8, CompanionAnimation.greet),
          ],
          requiresCompanion: true,
        );

      case InteractionID.welcome:
        return InteractionScript(
          id: id,
          duration: 3.6,
          pet: [
            _pet(0, 0.6, PetAnimation.watch),
            _pet(0.6, 2.4, PetAnimation.greet),
            _pet(2.4, 3.4, PetAnimation.happyBounce),
            _pet(3.4, 3.6, PetAnimation.watch),
          ],
          companion: [_comp(0, 1.8, CompanionAnimation.arrive), _comp(1.8, 3.6, CompanionAnimation.setup)],
          requiresCompanion: true,
        );

      case InteractionID.highFive:
        return InteractionScript(
          id: id,
          duration: 4.0,
          pet: [
            _pet(0, 1.0, PetAnimation.walk, at: 0, to: m),
            _pet(1.0, 1.7, PetAnimation.highFive, at: m),
            _pet(1.7, 2.7, PetAnimation.happyBounce, at: m),
            _pet(2.7, 3.6, PetAnimation.walk, at: m, to: 0, facing: -1),
            _pet(3.6, 4.0, PetAnimation.idle),
          ],
          companion: [
            _comp(0, 1.0, CompanionAnimation.greet),
            _comp(1.0, 1.7, CompanionAnimation.highFive),
            _comp(1.7, 4.0, CompanionAnimation.celebrate),
          ],
          requiresCompanion: true,
        );

      case InteractionID.victoryDance:
        return InteractionScript(
          id: id,
          duration: 5.6,
          pet: [
            _pet(0, 1.0, PetAnimation.walk, at: 0, to: 0.4),
            _pet(1.0, 4.2, PetAnimation.dance, at: 0.4),
            _pet(4.2, 5.2, PetAnimation.walk, at: 0.4, to: 0, facing: -1),
            _pet(5.2, 5.6, PetAnimation.idle),
          ],
          companion: [
            _comp(0, 1.0, CompanionAnimation.greet),
            _comp(1.0, 4.2, CompanionAnimation.dance),
            _comp(4.2, 5.6, CompanionAnimation.idleAtDesk),
          ],
          requiresCompanion: true,
        );

      case InteractionID.trophyCelebration:
        return InteractionScript(
          id: id,
          duration: 4.2,
          pet: [
            _pet(0, 0.3, PetAnimation.watch),
            _pet(0.3, 1.7, PetAnimation.excitedJump),
            _pet(1.7, 2.7, PetAnimation.happyBounce),
            _pet(2.7, 4.2, PetAnimation.idle),
          ],
          companion: [_comp(0, 2.8, CompanionAnimation.trophy), _comp(2.8, 4.2, CompanionAnimation.idleAtDesk)],
          requiresCompanion: true,
        );

      case InteractionID.caseClosed:
        return InteractionScript(
          id: id,
          duration: 4.8,
          pet: [
            _pet(0, 1.2, PetAnimation.walk, at: 0, to: m),
            _pet(1.2, 2.0, PetAnimation.watch, at: m),
            _pet(2.0, 2.7, PetAnimation.highFive, at: m),
            _pet(2.7, 3.7, PetAnimation.happyBounce, at: m),
            _pet(3.7, 4.6, PetAnimation.walk, at: m, to: 0, facing: -1),
            _pet(4.6, 4.8, PetAnimation.idle),
          ],
          companion: [
            _comp(0, 1.2, CompanionAnimation.detective),
            _comp(1.2, 2.0, CompanionAnimation.greet, held: HeldItem.detectiveHat),
            _comp(2.0, 2.7, CompanionAnimation.highFive),
            _comp(2.7, 4.8, CompanionAnimation.celebrate),
          ],
          requiresCompanion: true,
        );

      case InteractionID.detectiveHat:
        return InteractionScript(
          id: id,
          duration: 2.8,
          pet: [_pet(0, 1.8, PetAnimation.confusedTilt), _pet(1.8, 2.8, PetAnimation.watch)],
          companion: [_comp(0, 2.8, CompanionAnimation.detective)],
          requiresCompanion: true,
        );

      case InteractionID.graduation:
        return InteractionScript(
          id: id,
          duration: 5.4,
          pet: [
            _pet(0, 1.0, PetAnimation.walk, at: 0, to: m),
            _pet(1.0, 2.4, PetAnimation.watch, at: m),
            _pet(2.4, 4.4, PetAnimation.victory, at: m, hat: HeldItem.gradCap),
            _pet(4.4, 5.4, PetAnimation.walk, at: m, to: 0, hat: HeldItem.gradCap, facing: -1),
          ],
          companion: [
            _comp(0, 1.0, CompanionAnimation.greet),
            _comp(1.0, 2.4, CompanionAnimation.presentCode, held: HeldItem.gradCap),
            _comp(2.4, 5.4, CompanionAnimation.celebrate),
          ],
          requiresCompanion: true,
        );

      case InteractionID.syncDance:
        return InteractionScript(
          id: id,
          duration: 6.4,
          pet: [
            _pet(0, 0.4, PetAnimation.watch),
            _pet(0.4, 3.6, PetAnimation.dance),
            _pet(3.6, 5.2, PetAnimation.roll),
            _pet(5.2, 6.4, PetAnimation.victory),
          ],
          companion: [
            _comp(0, 0.4, CompanionAnimation.greet),
            _comp(0.4, 3.6, CompanionAnimation.dance),
            _comp(3.6, 6.0, CompanionAnimation.celebrate),
            _comp(6.0, 6.4, CompanionAnimation.idleAtDesk),
          ],
          requiresCompanion: true,
        );
    }
  }

  /// Evaluates both characters and scene props at `elapsed` seconds into the interaction.
  static InteractionFrame frame(
    InteractionPlayback playback, {
    required double elapsed,
    required PoseContext petContext,
    required PoseContext companionContext,
    CompanionDetail detail = const CompanionDetail(),
  }) {
    final script = InteractionLibrary.script(playback.id, variant: playback.variant);
    final t = math.min(math.max(0.0, elapsed), script.duration);
    final motion = petContext.motion > 0 ? 1.0 : 0.0;

    final petBeat = script.pet.lastWhere((b) => b.start <= t, orElse: () => script.pet[0]);
    final petLocal = t - petBeat.start;
    final petPose = PetPoseEvaluator.pose(petBeat.animation, elapsed: petLocal, duration: petBeat.end - petBeat.start, context: petContext);
    final petProgress = Ease.smooth(Ease.segment(t, petBeat.start, petBeat.end));
    // Walking is translation; with Reduced Motion the pet interacts from home.
    petPose.x += Ease.lerp(petBeat.from, petBeat.to, petProgress) * motion;
    petPose.y += Ease.lerp(petBeat.lift.$1, petBeat.lift.$2, petProgress) * motion;
    petPose.facing = petBeat.facing;
    if (petBeat.facing < 0) petPose.lookX = -petPose.lookX.abs();
    if (petBeat.held != null) petPose.held = petBeat.held;
    if (petBeat.hat != null) petPose.hat = petBeat.hat;

    final compBeat = script.companion.lastWhere((b) => b.start <= t, orElse: () => script.companion[0]);
    final compAnimation = compBeat.animation == CompanionAnimation.scripted ? playback.companionLoop : compBeat.animation;
    final compLocal = t - compBeat.start;
    final compPose = CompanionPoseEvaluator.pose(
      compAnimation,
      elapsed: compLocal,
      duration: compBeat.end - compBeat.start,
      context: companionContext,
      detail: detail,
    );
    final compProgress = Ease.smooth(Ease.segment(t, compBeat.start, compBeat.end));
    compPose.x += Ease.lerp(compBeat.from, compBeat.to, compProgress) * motion;
    if (compBeat.held != null) compPose.held = compBeat.held;

    return InteractionFrame(
      pet: petPose,
      companion: compPose,
      props: props(playback.id, t: t, variant: playback.variant, reduced: motion == 0),
    );
  }

  static List<SceneProp> props(InteractionID id, {required double t, required int variant, required bool reduced}) {
    switch (id) {
      case InteractionID.ballDistraction:
        if (t >= 1.2 && t < 2.1) {
          final p = Ease.segment(t, 1.2, 2.1);
          return [SceneProp(ScenePropKind.ball, x: Ease.lerp(0.12, 0.9, p), y: 0.55 + 0.75 * Ease.hop(p), rotation: t * 8)];
        }
        if (t >= 2.1 && t < 3.4) {
          return [SceneProp(ScenePropKind.ball, x: 0.9, y: 1.05 + 0.04 * math.sin(t * 10), rotation: t * 2)];
        }
        if (t >= 3.4 && t < 4.3) {
          final p = Ease.segment(t, 3.4, 4.3);
          return [
            SceneProp(ScenePropKind.ball, x: Ease.lerp(0.9, 0.12, p), y: Ease.lerp(1.05, 0.55, p) + 0.6 * Ease.hop(p), rotation: -t * 8),
          ];
        }
        return [];
      case InteractionID.highFive || InteractionID.caseClosed:
        final clapAt = id == InteractionID.highFive ? 1.15 : 2.15;
        final life = Ease.bump(t, clapAt, clapAt + 0.6);
        if (!(life > 0)) return [];
        return [SceneProp(ScenePropKind.clap, x: 0.83, y: 1.35, scale: 0.6 + 0.6 * life, opacity: life)];
      case InteractionID.victoryDance || InteractionID.syncDance || InteractionID.graduation:
        final bursts = id == InteractionID.graduation ? const [2.4] : const [1.0, 2.6];
        return [
          for (final start in bursts)
            if (t - start > 0 && t - start < 2.2)
              for (var index = 0; index < 10; index++)
                () {
                  final local = t - start;
                  final seed = index * 31 + (start * 10).toInt();
                  final x = 0.15 + 0.7 * Ease.hash(index, seed);
                  final fallSpeed = 0.5 + 0.4 * Ease.hash(index + 3, seed);
                  final y = reduced ? 1.6 + 0.2 * Ease.hash(index + 7, seed) : 2.2 - local * fallSpeed;
                  return SceneProp(
                    ScenePropKind.confetti,
                    x: x + (reduced ? 0 : 0.04 * math.sin(local * 5 + index)),
                    y: y,
                    scale: 0.8,
                    opacity: 1 - Ease.segment(local, 1.6, 2.2),
                    rotation: local * 6 + index,
                    variant: index % 4,
                  );
                }(),
        ];
      case InteractionID.trophyCelebration:
        return [
          for (var index = 0; index < 4; index++)
            () {
              final local = t - 0.4 - index * 0.35;
              final life = Ease.bump(local, 0, 0.8);
              return SceneProp(
                ScenePropKind.sparkle,
                x: 0.75 + 0.12 * (index % 2) * (index > 1 ? -1 : 1),
                y: 1.55 + 0.15 * (index % 3),
                scale: 0.5 + 0.5 * life,
                opacity: life,
                rotation: t * 2,
              );
            }(),
        ];
      case InteractionID.mysteryOrb:
        double x;
        double y;
        var opacity = 1.0;
        if (t < 2.5) {
          final p = Ease.smooth(Ease.segment(t, 0, 2.5));
          x = Ease.lerp(-0.25, 0.5, p);
          y = 1.6 + 0.15 * math.sin(t * 3);
          opacity = Ease.segment(t, 0, 0.6);
        } else if (t < 5.5) {
          final local = t - 2.5;
          x = 0.5 + 0.15 * math.sin(local * 2.2);
          y = 1.55 + 0.12 * math.cos(local * 2.2);
        } else {
          final p = Ease.smooth(Ease.segment(t, 5.5, 6.6));
          x = 0.5 + 0.4 * p;
          y = 1.55 + 1.6 * p;
          opacity = 1 - p;
        }
        return [SceneProp(ScenePropKind.orb, x: x, y: y, scale: 1, opacity: opacity, rotation: t)];
      default:
        return [];
    }
  }
}
