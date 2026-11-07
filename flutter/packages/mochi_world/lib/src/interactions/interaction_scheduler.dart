// Port of Sources/TamagotchiCore/Interactions/InteractionScheduler.swift: when the characters do something on their
// own, with weighted, seeded picks, cooldowns, daily caps and no repeats of the last two.

import '../model/animations.dart';
import '../model/json.dart';
import '../model/random.dart';
import 'interaction_library.dart';

enum AmbientActivity {
  /// No Claude turn in progress.
  idle,

  /// A Claude turn is in progress (cosmetic interactions only, never claims about the work).
  working,

  /// Claude is waiting for the user: never distract from that.
  waiting,
}

enum Rarity { common, uncommon, rare }

class InteractionDefinition {
  const InteractionDefinition({
    required this.id,
    required this.weight,
    required this.cooldown,
    required this.dailyCap,
    required this.rarity,
    required this.activities,
    required this.minimumIdle,
  });

  final InteractionID id;
  final double weight;
  final double cooldown;
  final int dailyCap;
  final Rarity rarity;
  final Set<AmbientActivity> activities;

  /// Required time since the last real activity or user interaction.
  final double minimumIdle;

  static const List<InteractionDefinition> ambient = [
    InteractionDefinition(
      id: InteractionID.coffeeDelivery,
      weight: 3,
      cooldown: 25 * 60,
      dailyCap: 6,
      rarity: Rarity.common,
      activities: {AmbientActivity.idle, AmbientActivity.working},
      minimumIdle: 0,
    ),
    InteractionDefinition(
      id: InteractionID.showCode,
      weight: 2.5,
      cooldown: 18 * 60,
      dailyCap: 6,
      rarity: Rarity.common,
      activities: {AmbientActivity.working, AmbientActivity.idle},
      minimumIdle: 0,
    ),
    InteractionDefinition(
      id: InteractionID.ballDistraction,
      weight: 2,
      cooldown: 15 * 60,
      dailyCap: 6,
      rarity: Rarity.common,
      activities: {AmbientActivity.idle, AmbientActivity.working},
      minimumIdle: 30,
    ),
    InteractionDefinition(
      id: InteractionID.rockPaperScissors,
      weight: 2,
      cooldown: 20 * 60,
      dailyCap: 5,
      rarity: Rarity.common,
      activities: {AmbientActivity.idle},
      minimumIdle: 60,
    ),
    InteractionDefinition(
      id: InteractionID.sleepWatch,
      weight: 1.4,
      cooldown: 50 * 60,
      dailyCap: 3,
      rarity: Rarity.uncommon,
      activities: {AmbientActivity.idle},
      minimumIdle: 4 * 60,
    ),
    InteractionDefinition(
      id: InteractionID.chairSteal,
      weight: 0.35,
      cooldown: 3 * 3600,
      dailyCap: 1,
      rarity: Rarity.rare,
      activities: {AmbientActivity.idle},
      minimumIdle: 90,
    ),
    InteractionDefinition(
      id: InteractionID.keyboardNap,
      weight: 0.35,
      cooldown: 3 * 3600,
      dailyCap: 1,
      rarity: Rarity.rare,
      activities: {AmbientActivity.idle},
      minimumIdle: 3 * 60,
    ),
    InteractionDefinition(
      id: InteractionID.mysteryOrb,
      weight: 0.3,
      cooldown: 4 * 3600,
      dailyCap: 1,
      rarity: Rarity.rare,
      activities: {AmbientActivity.idle},
      minimumIdle: 60,
    ),
  ];
}

class SchedulerContext {
  const SchedulerContext({
    required this.companionPresent,
    required this.activity,
    required this.idleSeconds,
    this.charactersBusy = false,
    this.paused = false,
    this.reducedMotion = false,
    this.intensity = AnimationIntensity.normal,
    this.petAsleep = false,
  });

  final bool companionPresent;
  final AmbientActivity activity;

  /// Seconds since the last real Claude event or user interaction.
  final double idleSeconds;
  final bool charactersBusy;
  final bool paused;
  final bool reducedMotion;
  final AnimationIntensity intensity;
  final bool petAsleep;
}

/// Decides when the characters do something on their own.
///
/// - A global gap between interactions (scaled by animation intensity) keeps them rare.
/// - Each interaction has its own cooldown and daily cap; the last two are never repeated.
/// - Real events push ambient behaviour back so it never competes with a reaction.
/// - Nothing ambient happens while Claude is waiting for the user, or when paused.
class InteractionScheduler {
  InteractionScheduler({required int seed, required double now, this.definitions = InteractionDefinition.ambient})
    : rng = SplitMix64(seed),
      nextInteractionAt = now + 45,
      nextSoloAt = now + 12;

  static const double baseInteractionGap = 150;
  static const double baseSoloGap = 40;

  SplitMix64 rng;
  double nextInteractionAt;
  double nextSoloAt;
  final Map<InteractionID, double> lastStarted = {};
  final List<InteractionID> recent = [];
  final Map<InteractionID, int> dailyCounts = {};
  int countsDay = -1;
  final List<InteractionDefinition> definitions;

  /// Pushes ambient behaviour back after a real event or user interaction.
  void postpone({required double now, double by = 30}) {
    final seconds = by;
    if (now + seconds > nextInteractionAt) nextInteractionAt = now + seconds;
    final solo = now + (seconds < 20 ? seconds : 20);
    if (solo > nextSoloAt) nextSoloAt = solo;
  }

  /// Records an interaction that was triggered by an event, so it counts towards gaps.
  void noteTriggered(InteractionID id, {required double now}) {
    lastStarted[id] = now;
    _remember(id);
    if (now + 60 > nextInteractionAt) nextInteractionAt = now + 60;
  }

  double gap(double base, SchedulerContext context) => base * context.intensity.gapMultiplier * (context.reducedMotion ? 1.5 : 1);

  /// Returns an ambient interaction to start now (and its variant), if one is due and eligible.
  (InteractionID, int)? nextInteraction({required double now, required int day, required SchedulerContext context}) {
    if (context.paused ||
        context.activity == AmbientActivity.waiting ||
        !context.companionPresent ||
        context.charactersBusy ||
        context.petAsleep) {
      return null;
    }
    if (!(now >= nextInteractionAt)) return null;
    if (day != countsDay) {
      countsDay = day;
      dailyCounts.clear();
    }
    final lastTwo = recent.length <= 2 ? recent : recent.sublist(recent.length - 2);
    final eligible = definitions.where((definition) {
      if (!definition.activities.contains(context.activity)) return false;
      if (!(context.idleSeconds >= definition.minimumIdle)) return false;
      final last = lastStarted[definition.id];
      if (last != null && now - last < definition.cooldown) return false;
      if ((dailyCounts[definition.id] ?? 0) >= definition.dailyCap) return false;
      if (lastTwo.contains(definition.id)) return false;
      return true;
    }).toList();
    final jitter = rng.nextIn(0.7, 1.3);
    nextInteractionAt = now + gap(baseInteractionGap, context) * jitter;
    final chosen = _weightedPick(eligible);
    if (chosen == null) return null;
    lastStarted[chosen.id] = now;
    dailyCounts[chosen.id] = (dailyCounts[chosen.id] ?? 0) + 1;
    _remember(chosen.id);
    final variant = unsignedMod(rng.next(), 1000);
    return (chosen.id, variant);
  }

  /// Returns a small solo behaviour for the pet, if one is due.
  PetAnimation? nextSolo({required double now, required SchedulerContext context}) {
    if (context.paused || context.charactersBusy || context.petAsleep || !(now >= nextSoloAt)) return null;
    nextSoloAt = now + gap(baseSoloGap, context) * rng.nextIn(0.7, 1.6);
    var options = <(PetAnimation, double)>[
      (PetAnimation.lookAround, 4),
      (PetAnimation.blep, 1.2),
      (PetAnimation.sniff, 1.0),
      (PetAnimation.stretch, 0.8),
      (PetAnimation.scratch, 0.8),
      (PetAnimation.shake, 0.5),
    ];
    if (context.activity == AmbientActivity.idle) {
      // Happy bounces only when nothing is going on: during a turn one could read as Claude's success.
      options += [
        (PetAnimation.happyBounce, 0.9),
        (PetAnimation.roll, 0.7),
        (PetAnimation.dance, 0.35),
        (PetAnimation.play, 0.9),
        (PetAnimation.tumble, 0.5),
        (PetAnimation.pounce, 0.5),
      ];
      if (context.idleSeconds > 180) options.add((PetAnimation.yawn, 0.8));
    }
    if (context.reducedMotion) {
      // Expressions only: nothing that jumps, spins or travels.
      const moving = {PetAnimation.roll, PetAnimation.dance, PetAnimation.play, PetAnimation.tumble, PetAnimation.pounce};
      options.removeWhere((o) => moving.contains(o.$1));
    }
    if (context.activity == AmbientActivity.waiting) {
      // Only quiet glances while Claude waits for the user.
      options = [(PetAnimation.lookAround, 1)];
    }
    var total = 0.0;
    for (final o in options) {
      total += o.$2;
    }
    var roll = rng.nextUnit() * total;
    for (final (animation, weight) in options) {
      roll -= weight;
      if (roll <= 0) return animation;
    }
    return options.isEmpty ? null : options.last.$1;
  }

  InteractionDefinition? _weightedPick(List<InteractionDefinition> candidates) {
    var total = 0.0;
    for (final c in candidates) {
      total += c.weight;
    }
    if (!(total > 0)) return null;
    var roll = rng.nextUnit() * total;
    for (final candidate in candidates) {
      roll -= candidate.weight;
      if (roll <= 0) return candidate;
    }
    return candidates.last;
  }

  void _remember(InteractionID id) {
    recent.add(id);
    if (recent.length > 4) recent.removeAt(0);
  }

  // MARK: Persistence

  Map<String, Object?> toJson() => {
    'rng': unsignedString(rng.state),
    'nextInteractionAt': nextInteractionAt,
    'nextSoloAt': nextSoloAt,
    'lastStarted': {for (final e in lastStarted.entries) e.key.name: e.value},
    'recent': [for (final id in recent) id.name],
    'dailyCounts': {for (final e in dailyCounts.entries) e.key.name: e.value},
    'countsDay': countsDay,
  };

  /// Restores a scheduler written by [toJson] (null when the JSON isn't one).
  static InteractionScheduler? fromJson(Object? json) {
    final j = asMap(json);
    if (j['rng'] == null) return null;
    final scheduler = InteractionScheduler(seed: parseUnsigned(j['rng']), now: 0);
    scheduler.nextInteractionAt = dbl(j, 'nextInteractionAt', 45);
    scheduler.nextSoloAt = dbl(j, 'nextSoloAt', 12);
    for (final e in asMap(j['lastStarted']).entries) {
      final id = enumByName(InteractionID.values, e.key);
      if (id != null && e.value is num) scheduler.lastStarted[id] = (e.value as num).toDouble();
    }
    for (final name in (j['recent'] is List ? j['recent'] as List : const [])) {
      final id = enumByName(InteractionID.values, name);
      if (id != null) scheduler.recent.add(id);
    }
    for (final e in asMap(j['dailyCounts']).entries) {
      final id = enumByName(InteractionID.values, e.key);
      if (id != null && e.value is num) scheduler.dailyCounts[id] = (e.value as num).toInt();
    }
    scheduler.countsDay = integer(j, 'countsDay', -1);
    return scheduler;
  }
}
