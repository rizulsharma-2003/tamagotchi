// W14, mini-games. Port of Sources/TamagotchiCore/Features/CatchGame.swift (Catch the Treats: the simulation, its
// scoring, combos, golden treats, levels and Mochi's pose), RPSGame.swift (rock-paper-scissors rounds, tallies and the
// seeded picks), GameModels.swift (the records kept in settings) and the pure parts of Sources/App/Features/Games
// (GamesController's sounds, toasts and records; RPSGameView's round timing, result text and stage poses).

import 'dart:math' as math;

import '../animation/companion_pose_evaluator.dart';
import '../animation/pet_pose_evaluator.dart';
import '../interactions/interaction_library.dart';
import '../model/animations.dart';
import '../model/ease.dart';
import '../model/json.dart';
import '../model/poses.dart';
import '../model/random.dart';
import '../world/reactions.dart';
import 'moment.dart';

/// Local mini-game records (the Mac's `games` setting: same keys; missing keys keep their defaults).
class GameRecords {
  GameRecords({
    this.catchHighScore = 0,
    this.catchGamesPlayed = 0,
    this.catchBestCombo = 0,
    this.rpsWins = 0,
    this.rpsLosses = 0,
    this.rpsDraws = 0,
    this.rpsBestStreak = 0,
  });

  int catchHighScore;
  int catchGamesPlayed;
  int catchBestCombo;
  int rpsWins;
  int rpsLosses;
  int rpsDraws;

  /// Most rounds in a row won (at least one duel won, none lost).
  int rpsBestStreak;

  bool get isEmpty => this == GameRecords();

  /// Records a finished game of Catch the Treats. Returns true for a new high score.
  bool recordCatch({required int score, required int bestCombo}) {
    catchGamesPlayed += 1;
    catchBestCombo = math.max(catchBestCombo, bestCombo);
    if (score <= catchHighScore) return false;
    catchHighScore = score;
    return true;
  }

  /// Adds one rock-paper-scissors round: you against each opponent is one duel. Returns true when [streak] (rounds
  /// won in a row) beats the best streak.
  bool recordRPS(RPSRound round, {required int streak}) {
    for (final outcome in round.duels) {
      switch (outcome) {
        case 1:
          rpsWins += 1;
        case -1:
          rpsLosses += 1;
        default:
          rpsDraws += 1;
      }
    }
    if (streak <= rpsBestStreak) return false;
    rpsBestStreak = streak;
    return true;
  }

  GameRecords copy() => GameRecords.fromJson(toJson());

  Map<String, Object?> toJson() => {
    'catchHighScore': catchHighScore,
    'catchGamesPlayed': catchGamesPlayed,
    'catchBestCombo': catchBestCombo,
    'rpsWins': rpsWins,
    'rpsLosses': rpsLosses,
    'rpsDraws': rpsDraws,
    'rpsBestStreak': rpsBestStreak,
  };

  static GameRecords fromJson(Object? json) {
    final j = asMap(json);
    return GameRecords(
      catchHighScore: integer(j, 'catchHighScore', 0),
      catchGamesPlayed: integer(j, 'catchGamesPlayed', 0),
      catchBestCombo: integer(j, 'catchBestCombo', 0),
      rpsWins: integer(j, 'rpsWins', 0),
      rpsLosses: integer(j, 'rpsLosses', 0),
      rpsDraws: integer(j, 'rpsDraws', 0),
      rpsBestStreak: integer(j, 'rpsBestStreak', 0),
    );
  }

  /// Settings › Games, as the Mac words it.
  String get catchSummary =>
      catchGamesPlayed == 0 ? 'Not played yet' : 'Best $catchHighScore · best combo $catchBestCombo · $catchGamesPlayed played';

  String get rpsSummary => rpsWins + rpsLosses + rpsDraws == 0 ? 'Not played yet' : '$rpsWins won · $rpsLosses lost · $rpsDraws drawn';

  @override
  bool operator ==(Object other) =>
      other is GameRecords &&
      other.catchHighScore == catchHighScore &&
      other.catchGamesPlayed == catchGamesPlayed &&
      other.catchBestCombo == catchBestCombo &&
      other.rpsWins == rpsWins &&
      other.rpsLosses == rpsLosses &&
      other.rpsDraws == rpsDraws &&
      other.rpsBestStreak == rpsBestStreak;

  @override
  int get hashCode => Object.hash(catchHighScore, catchGamesPlayed, catchBestCombo, rpsWins, rpsLosses, rpsDraws, rpsBestStreak);
}

// MARK: - Catch the Treats

enum TreatKind {
  cookie,
  fish,
  berry,

  /// A golden bonus cookie: worth more, and letting it go costs nothing.
  golden;

  int get points => this == golden ? 5 : 1;
}

class CatchTreat {
  CatchTreat({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.speed,
    required this.spin,
    this.age = 0,
  });

  final int id;
  final TreatKind kind;
  double x;
  double y;

  /// Fall speed in field heights per second.
  final double speed;

  /// Spin in radians per second (drawing only).
  final double spin;
  double age;

  double get rotation => spin * age;

  CatchTreat copy() => CatchTreat(id: id, kind: kind, x: x, y: y, speed: speed, spin: spin, age: age);
}

enum CatchPhase { playing, over }

/// What happened during a step, for sounds and reactions.
sealed class CatchEvent {
  const CatchEvent();
}

class CatchCaught extends CatchEvent {
  const CatchCaught(this.kind, {required this.points, required this.combo});
  final TreatKind kind;
  final int points;
  final int combo;

  @override
  bool operator ==(Object other) => other is CatchCaught && other.kind == kind && other.points == points && other.combo == combo;

  @override
  int get hashCode => Object.hash(kind, points, combo);

  @override
  String toString() => 'caught(${kind.name}, $points, combo $combo)';
}

class CatchMissed extends CatchEvent {
  const CatchMissed(this.kind);
  final TreatKind kind;

  @override
  bool operator ==(Object other) => other is CatchMissed && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'missed(${kind.name})';
}

class CatchFaster extends CatchEvent {
  const CatchFaster(this.level);
  final int level;

  @override
  bool operator ==(Object other) => other is CatchFaster && other.level == level;

  @override
  int get hashCode => level.hashCode;

  @override
  String toString() => 'faster($level)';
}

class CatchGameOver extends CatchEvent {
  const CatchGameOver(this.score);
  final int score;

  @override
  bool operator ==(Object other) => other is CatchGameOver && other.score == score;

  @override
  int get hashCode => score.hashCode;

  @override
  String toString() => 'gameOver($score)';
}

/// A short-lived marker where a treat was caught or landed (pops and "+3" labels).
class CatchSplash {
  const CatchSplash({required this.kind, required this.x, required this.y, required this.points, required this.at});
  final TreatKind kind;
  final double x;
  final double y;

  /// Points scored; 0 for a treat that landed on the floor.
  final int points;
  final double at;
}

enum CatchReactionKind { munch, golden, oops }

/// Mochi's latest reaction, for the pose.
class CatchReaction {
  const CatchReaction(this.kind, this.at);
  final CatchReactionKind kind;
  final double at;
}

class CatchInput {
  const CatchInput({this.direction = 0, this.targetX});

  /// -1 left, 0 still, 1 right (arrow keys / A-D).
  final double direction;

  /// Where the pointer is while dragging, in field units; wins over the keys.
  final double? targetX;
}

/// "Catch the Treats": treats fall from the top and Mochi runs along the floor to catch them.
///
/// A pure, deterministic simulation in a unit field (x 0…1 left to right, y 0 at the floor … 1 at the top). The app
/// steps it once per frame with the player's input; the same seed and inputs always play out the same way, on the Mac
/// too. Three treats on the floor end the game (golden bonus treats never count against you). It speeds up every
/// [levelDuration] seconds.
class CatchGame {
  /// [seed] is a UInt64's bit pattern.
  CatchGame(int seed) : _rng = SplitMix64(seed ^ 0x43415443485F4D45);

  // Tuning (field units and seconds).
  static const int maxMisses = 3;

  /// Treats are caught between the floor and this height (Mochi's head).
  static const double catchHeight = 0.22;

  /// Treats touch the floor at this height.
  static const double floorY = 0.04;

  /// Half the width of Mochi's catch zone.
  static const double catchRadius = 0.085;
  static const double petMinX = 0.06;
  static const double petMaxX = 0.94;

  /// Running speed with the keys, field widths per second.
  static const double runSpeed = 0.95;

  /// Fastest speed while following the pointer.
  static const double dragSpeed = 1.9;

  /// Seconds per speed level.
  static const double levelDuration = 20;
  static const int maxLevel = 8;
  static const double splashLife = 0.9;

  CatchPhase _phase = CatchPhase.playing;
  double _time = 0;
  int _score = 0;
  int _combo = 0;
  int _bestCombo = 0;
  int _caught = 0;
  int _misses = 0;
  int _level = 1;
  double _petX = 0.5;
  double _petVelocity = 0;
  double _facing = 1;
  final List<CatchTreat> _treats = [];
  final List<CatchSplash> _splashes = [];
  CatchReaction? _reaction;

  /// Drop treats automatically (tests place them by hand instead).
  bool autoSpawn = true;
  final SplitMix64 _rng;
  double _nextSpawnAt = 0.8;
  int _nextID = 1;
  bool _lastWasGolden = false;
  bool _recorded = false;

  CatchPhase get phase => _phase;

  /// Game time in seconds (only advances while playing).
  double get time => _time;
  int get score => _score;

  /// Catches in a row since the last treat on the floor.
  int get combo => _combo;
  int get bestCombo => _bestCombo;
  int get caught => _caught;
  int get misses => _misses;
  int get level => _level;
  double get petX => _petX;

  /// Field widths per second (positive = right).
  double get petVelocity => _petVelocity;
  double get facing => _facing;
  List<CatchTreat> get treats => List.unmodifiable(_treats);
  List<CatchSplash> get splashes => List.unmodifiable(_splashes);
  CatchReaction? get reaction => _reaction;

  /// The generator's state (a UInt64's bit pattern), for checking determinism.
  int get rngState => _rng.state;

  // MARK: Difficulty

  /// Combo multiplier: ×1 for the first five catches in a row, ×2 from the sixth, … up to ×4.
  static int multiplier(int combo) => math.min(4, 1 + math.max(0, combo - 1) ~/ 5);

  /// Base fall speed (field heights per second) at a level.
  static double fallSpeed(int level) => 0.27 * (1 + 0.14 * (level - 1));

  /// Mean seconds between treats at a level.
  static double spawnInterval(int level) => 1.3 * math.pow(0.87, level - 1).toDouble();

  // MARK: Simulation

  /// Advances the game by [dt] seconds (at most 0.1 s per step). Returns what happened, in order.
  List<CatchEvent> step(double rawDT, [CatchInput input = const CatchInput()]) {
    if (_phase != CatchPhase.playing || !(rawDT > 0)) return const [];
    final dt = math.min(rawDT, 0.1);
    final events = <CatchEvent>[];
    _time += dt;

    final newLevel = math.min(maxLevel, 1 + (_time / levelDuration).floor());
    if (newLevel > _level) {
      _level = newLevel;
      events.add(CatchFaster(_level));
    }

    _movePet(dt, input);

    if (autoSpawn) {
      while (_time >= _nextSpawnAt) {
        _spawn();
        _nextSpawnAt += spawnInterval(_level) * _rng.nextIn(0.75, 1.25);
      }
    }

    final remaining = <CatchTreat>[];
    for (final treat in _treats) {
      final oldY = treat.y;
      treat.y -= treat.speed * dt;
      treat.age += dt;
      // Swept test, so a long step can't carry a treat through Mochi.
      final throughCatchZone = treat.y <= catchHeight && oldY >= floorY;
      if (throughCatchZone && (treat.x - _petX).abs() <= catchRadius) {
        _combo += 1;
        _bestCombo = math.max(_bestCombo, _combo);
        _caught += 1;
        final points = treat.kind.points * multiplier(_combo);
        _score += points;
        _splashes.add(CatchSplash(kind: treat.kind, x: treat.x, y: math.max(treat.y, floorY + 0.1), points: points, at: _time));
        _reaction = CatchReaction(treat.kind == TreatKind.golden ? CatchReactionKind.golden : CatchReactionKind.munch, _time);
        events.add(CatchCaught(treat.kind, points: points, combo: _combo));
      } else if (treat.y <= floorY) {
        _splashes.add(CatchSplash(kind: treat.kind, x: treat.x, y: floorY, points: 0, at: _time));
        events.add(CatchMissed(treat.kind));
        if (treat.kind != TreatKind.golden) {
          _combo = 0;
          _misses += 1;
          _reaction = CatchReaction(CatchReactionKind.oops, _time);
        }
      } else {
        remaining.add(treat);
      }
    }
    _treats
      ..clear()
      ..addAll(remaining);
    _splashes.removeWhere((s) => _time - s.at > splashLife);

    if (_misses >= maxMisses) {
      _phase = CatchPhase.over;
      _petVelocity = 0;
      events.add(CatchGameOver(_score));
    }
    return events;
  }

  /// Drops a treat now. The spawner uses it; tests place treats by hand.
  void drop(TreatKind kind, double x, {double y = 1.04, double? speed}) {
    final fall = speed ?? fallSpeed(_level) * (kind == TreatKind.golden ? 1.15 : 1);
    _treats.add(CatchTreat(id: _nextID, kind: kind, x: math.min(math.max(x, 0.04), 0.96), y: y, speed: fall, spin: 0));
    _nextID += 1;
  }

  void _spawn() {
    final TreatKind kind;
    if (!_lastWasGolden && _time > 6 && _rng.nextUnit() < 0.08) {
      kind = TreatKind.golden;
    } else {
      final pick = _rng.nextUnit();
      kind = pick < 0.42 ? TreatKind.cookie : (pick < 0.72 ? TreatKind.fish : TreatKind.berry);
    }
    _lastWasGolden = kind == TreatKind.golden;
    // Keep a new treat out of the previous one's column, so two never stack exactly.
    var x = _rng.nextIn(0.07, 0.93);
    if (_treats.isNotEmpty && (_treats.last.x - x).abs() < 0.08) x = x > 0.5 ? x - 0.16 : x + 0.16;
    final fall = fallSpeed(_level) * _rng.nextIn(0.88, 1.12) * (kind == TreatKind.golden ? 1.15 : 1);
    _treats.add(CatchTreat(id: _nextID, kind: kind, x: x, y: 1.04, speed: fall, spin: _rng.nextIn(-3, 3)));
    _nextID += 1;
  }

  void _movePet(double dt, CatchInput input) {
    final double desired;
    // Keys accelerate gently; the pointer is followed briskly without overshooting.
    final double response;
    if (input.targetX case final target?) {
      final clamped = math.min(math.max(target, petMinX), petMaxX);
      desired = math.min(math.max((clamped - _petX) * 12, -dragSpeed), dragSpeed);
      response = 30;
    } else {
      desired = math.max(-1.0, math.min(1.0, input.direction)) * runSpeed;
      response = 14;
    }
    _petVelocity += (desired - _petVelocity) * math.min(1, dt * response);
    if (desired == 0 && _petVelocity.abs() < 0.002) _petVelocity = 0;
    _petX += _petVelocity * dt;
    if (!(_petX >= petMinX && _petX <= petMaxX)) {
      _petX = math.min(math.max(_petX, petMinX), petMaxX);
      _petVelocity = 0;
    }
    if (_petVelocity.abs() > 0.05) _facing = _petVelocity > 0 ? 1 : -1;
  }

  // MARK: Mochi's pose

  /// Seconds each reaction shows on Mochi.
  static double reactionLength(CatchReactionKind kind) => switch (kind) {
    CatchReactionKind.munch => 0.8,
    CatchReactionKind.golden => 1.1,
    CatchReactionKind.oops => 1.2,
  };

  /// Mochi in the game right now: walking or running with the movement (facing the way it goes), a happy hop and a
  /// munch for a catch, a little "oops" for a treat on the floor, and eyes on the lowest treat while standing still.
  /// `x` is left at 0: the host places Mochi at [petX].
  PetPose petPose(PoseContext context) {
    final speed = _petVelocity.abs();
    final loop = _phase == CatchPhase.over
        ? PetAnimation.sit
        : (speed > 0.45 ? PetAnimation.run : (speed > 0.06 ? PetAnimation.walk : PetAnimation.idle));
    final c = context.copy()..returnLoop = loop;
    PetPose pose;
    final reaction = _reaction;
    if (_phase == CatchPhase.playing && reaction != null && _time - reaction.at < reactionLength(reaction.kind)) {
      final t = _time - reaction.at;
      switch (reaction.kind) {
        case CatchReactionKind.munch:
          pose = PetPoseEvaluator.pose(PetAnimation.happyBounce, elapsed: t, duration: reactionLength(CatchReactionKind.munch), context: c);
          munch(pose, t);
        case CatchReactionKind.golden:
          pose = PetPoseEvaluator.pose(
            PetAnimation.excitedJump,
            elapsed: t,
            duration: reactionLength(CatchReactionKind.golden),
            context: c,
          );
          pose.eyeSparkle = math.max(pose.eyeSparkle, 0.8);
          if (t > 0.5) munch(pose, t - 0.5);
        case CatchReactionKind.oops:
          pose = PetPoseEvaluator.pose(PetAnimation.concerned, elapsed: t, duration: reactionLength(CatchReactionKind.oops), context: c);
      }
    } else {
      pose = PetPoseEvaluator.pose(loop, elapsed: 0, context: c);
      if (_phase == CatchPhase.over) {
        pose.eyes = PetEyes.happy;
        pose.mouth = PetMouth.smile;
        pose.lookX = 0;
      } else if (loop == PetAnimation.idle && _treats.isNotEmpty) {
        // Watching the next treat come down (screen space, before turning around).
        var next = _treats.first;
        for (final treat in _treats) {
          if (treat.y < next.y) next = treat;
        }
        pose.lookX = math.max(-1.0, math.min(1.0, (next.x - _petX) * 4)) * _facing;
        pose.lookY = -0.25 - 0.45 * math.min(1, next.y);
        pose.earPerk = math.max(pose.earPerk, 0.4);
      }
    }
    pose.x = 0;
    return _facing < 0 ? pose.mirrored() : pose;
  }

  /// Chewing: the mouth works and the cheeks puff for half a second.
  static void munch(PetPose pose, double t) {
    if (t < 0 || t >= 0.55) return;
    pose.mouth = (t / 0.09).floor() % 2 == 0 ? PetMouth.nom : PetMouth.tiny;
    final puff = 0.55 * Ease.bump(t, 0, 0.55);
    pose.cheekLeft = math.max(pose.cheekLeft, puff);
    pose.cheekRight = math.max(pose.cheekRight, puff);
    pose.eyes = PetEyes.happy;
    pose.blush = math.max(pose.blush, 0.7);
  }

  // MARK: Moments (the Mac's GamesController)

  /// The sound for a step's events (a pop for a catch, a chime for a golden one); the game's end is [finish].
  static FeatureMoment? momentFor(CatchEvent event) => switch (event) {
    CatchCaught(:final kind) => FeatureMoment(sound: kind == TreatKind.golden ? SoundCue.success : SoundCue.pop),
    _ => null,
  };

  /// Records the finished game and says how to celebrate: a new high score gets a jump, a toast and a fanfare; any
  /// other ending a soft sound. Returns whether it was a new record (never for a score of 0). A game is recorded once:
  /// later calls change nothing and show nothing (the Mac only finishes a game that is still playing).
  (bool newRecord, FeatureMoment moment) finish(GameRecords records, {required String petName}) {
    if (_recorded) return (false, const FeatureMoment());
    _recorded = true;
    final newRecord = records.recordCatch(score: _score, bestCombo: _bestCombo) && _score > 0;
    if (!newRecord) return (false, const FeatureMoment(sound: SoundCue.sleep));
    return (
      true,
      FeatureMoment(
        sound: SoundCue.celebration,
        pet: PetAnimation.excitedJump,
        toast: FeatureToast('New high score: $_score!', '$petName caught $_caught treats. Yum!'),
      ),
    );
  }
}

// MARK: - Rock, paper, scissors

extension RPSChoiceText on RPSChoice {
  String get title => switch (this) {
    RPSChoice.rock => 'Rock',
    RPSChoice.paper => 'Paper',
    RPSChoice.scissors => 'Scissors',
  };

  String get emoji => switch (this) {
    RPSChoice.rock => '✊',
    RPSChoice.paper => '✋',
    RPSChoice.scissors => '✌️',
  };

  /// The keys shown under each choice.
  String get keyHint => switch (this) {
    RPSChoice.rock => 'R or 1',
    RPSChoice.paper => 'P or 2',
    RPSChoice.scissors => 'S or 3',
  };
}

/// Keyboard shortcuts: R/P/S or 1/2/3.
RPSChoice? rpsChoiceForKey(String key) => switch (key.toLowerCase()) {
  'r' || '1' => RPSChoice.rock,
  'p' || '2' => RPSChoice.paper,
  's' || '3' => RPSChoice.scissors,
  _ => null,
};

/// One round: you play Mochi and (when it joins) the companion at the same time. Each pairing with you is a duel.
class RPSRound {
  const RPSRound({required this.player, required this.pet, this.companion});

  final RPSChoice player;
  final RPSChoice pet;
  final RPSChoice? companion;

  /// Your result against Mochi: 1 won, -1 lost, 0 draw.
  int get vsPet => player.outcome(pet);

  /// Your result against the companion, if it played.
  int? get vsCompanion => companion == null ? null : player.outcome(companion!);

  /// Your duels in order (Mochi first).
  List<int> get duels => [vsPet, ?vsCompanion];

  /// Won at least one duel and lost none.
  bool get isWin => duels.contains(1) && !duels.contains(-1);

  /// Lost at least one duel and won none.
  bool get isLoss => duels.contains(-1) && !duels.contains(1);

  /// What the round means, in words (the Mac's `RPSText.result`).
  ({String headline, String detail}) result({required String petName, required String companionName}) {
    String duel(int outcome, String name) => switch (outcome) {
      1 => 'you beat $name',
      -1 => '$name wins',
      _ => 'a draw with $name',
    };
    final parts = [duel(vsPet, petName), if (vsCompanion case final c?) duel(c, companionName)];
    final detail = parts.join(' · ');
    final String headline;
    if (isWin) {
      headline = duels.every((d) => d == 1) ? 'Clean sweep!' : 'You win!';
    } else if (isLoss) {
      headline = duels.every((d) => d == -1) ? 'They got you!' : 'Not this time!';
    } else if (duels.every((d) => d == 0)) {
      headline = 'Great minds think alike!';
    } else {
      headline = 'Split decision!';
    }
    return (headline: headline, detail: detail.substring(0, 1).toUpperCase() + detail.substring(1));
  }

  @override
  bool operator ==(Object other) => other is RPSRound && other.player == player && other.pet == pet && other.companion == companion;

  @override
  int get hashCode => Object.hash(player, pet, companion);
}

/// Running totals of one side's duels.
class RPSTally {
  int wins = 0;
  int losses = 0;
  int draws = 0;

  void record(int outcome) {
    switch (outcome) {
      case 1:
        wins += 1;
      case -1:
        losses += 1;
      default:
        draws += 1;
    }
  }

  int get played => wins + losses + draws;

  /// "2–1–0": won, lost, drawn this sitting.
  String get score => '$wins–$losses–$draws';
}

/// A sitting of rock-paper-scissors. The characters choose with a seeded generator, so a match is reproducible (the
/// same seed gives the Mac's picks); they never peek at your choice.
class RPSMatch {
  /// [seed] is a UInt64's bit pattern.
  RPSMatch(int seed, {required this.withCompanion}) : _rng = SplitMix64(seed ^ 0x5250535F4D415443);

  final bool withCompanion;
  final RPSTally vsPet = RPSTally();
  final RPSTally vsCompanion = RPSTally();
  final List<RPSRound> _rounds = [];
  int _streak = 0;
  final SplitMix64 _rng;

  /// The last 50 rounds.
  List<RPSRound> get rounds => List.unmodifiable(_rounds);

  /// Rounds won in a row (see [RPSRound.isWin]).
  int get streak => _streak;

  /// The characters' picks for the next round, decided before they know yours.
  ({RPSChoice pet, RPSChoice? companion}) nextPicks() {
    final pet = RPSChoice.values[unsignedMod(_rng.next(), 3)];
    final companion = RPSChoice.values[unsignedMod(_rng.next(), 3)];
    return (pet: pet, companion: withCompanion ? companion : null);
  }

  /// Plays a round against fresh picks.
  RPSRound playChoice(RPSChoice choice) {
    final picks = nextPicks();
    return play(RPSRound(player: choice, pet: picks.pet, companion: picks.companion));
  }

  /// Scores a round whose picks are already known.
  RPSRound play(RPSRound round) {
    vsPet.record(round.vsPet);
    if (round.vsCompanion case final outcome?) vsCompanion.record(outcome);
    _rounds.add(round);
    if (_rounds.length > 50) _rounds.removeRange(0, _rounds.length - 50);
    _streak = round.isWin ? _streak + 1 : 0;
    return round;
  }

  /// Records a revealed round and says how to react: a new best streak (3 or more) gets a jump, a toast and a fanfare;
  /// otherwise a sound for a win, a loss or a draw.
  static FeatureMoment reveal(RPSRound round, {required int streak, required GameRecords records}) {
    final newBest = records.recordRPS(round, streak: streak) && streak >= 3;
    if (newBest) {
      return FeatureMoment(
        sound: SoundCue.celebration,
        pet: PetAnimation.excitedJump,
        toast: FeatureToast('New best streak: $streak!', 'Rock, paper, scissors champion.'),
      );
    }
    if (round.isWin) return const FeatureMoment(sound: SoundCue.success);
    if (round.isLoss) return const FeatureMoment(sound: SoundCue.investigate);
    return const FeatureMoment(sound: SoundCue.pop);
  }
}

/// The rock-paper-scissors stage (the Mac's `RPSModel` timing and `RPSStageRenderer` poses): Mochi on the left, the
/// companion on the right, your hand in the middle; just Mochi and you when the companion never shows.
abstract final class RPSStage {
  /// Shake, reveal, react: the round's beats in seconds. Score the round ([RPSMatch.play]) at [shake].
  static const double shake = 1.5;
  static const double hold = 0.45;
  static const double roundLength = 3.6;

  static const double companionX = 0.75;
  static double petX(bool withCompanion) => withCompanion ? 0.25 : 0.34;
  static double handX(bool withCompanion) => withCompanion ? 0.5 : 0.68;

  /// The chant over the shake: "Rock…", "Paper…", "Scissors…", "Shoot!" (null once it's over).
  static String? chant(double elapsed) {
    if (elapsed >= shake + 0.6) return null;
    const words = ['Rock…', 'Paper…', 'Scissors…', 'Shoot!'];
    return words[math.min(3, (elapsed / 0.5).floor())];
  }

  /// "Won!" over a character that beat you, "Lost" when you beat it, "Draw" otherwise ([outcome] from its side).
  static String badge(int outcome) => outcome > 0 ? 'Won!' : (outcome < 0 ? 'Lost' : 'Draw');

  /// The line under the stage between rounds.
  static String prompt({required bool busy, required bool withCompanion, required String petName, required String companionName}) =>
      busy ? 'Rock… paper… scissors…' : 'Pick one: you play $petName${withCompanion ? ' and $companionName' : ''} at once.';

  /// Mochi [elapsed] seconds into [round] (null: waiting for your pick).
  static PetPose petPose(RPSRound? round, double? elapsed, PoseContext context) {
    if (round == null || elapsed == null) {
      return PetPoseEvaluator.pose(PetAnimation.idle, elapsed: 0, context: context)..lookX = 0.5;
    }
    final t = elapsed;
    if (t < shake) return PetPoseEvaluator.pose(PetAnimation.rpsShake, elapsed: t, duration: shake, context: context);
    final r = t - shake;
    final PetPose pose;
    if (r < hold) {
      pose = PetPoseEvaluator.pose(PetAnimation.idle, elapsed: 0, context: context)
        ..eyes = PetEyes.wide
        ..earPerk = 0.6;
    } else {
      // From Mochi's side: it won when you lost to it.
      final outcome = -round.vsPet;
      final animation = outcome > 0 ? PetAnimation.excitedJump : (outcome < 0 ? PetAnimation.concerned : PetAnimation.blep);
      final length = outcome < 0 ? 1.9 : animation.defaultDuration;
      pose = PetPoseEvaluator.pose(animation, elapsed: r - hold, duration: length, context: context);
    }
    pose.held = round.pet.item;
    pose.rightArm = math.max(pose.rightArm, 0.45);
    return pose;
  }

  /// The companion [elapsed] seconds into [round].
  static CompanionPose companionPose(RPSRound? round, double? elapsed, PoseContext context) {
    final companion = round?.companion;
    if (round == null || companion == null || elapsed == null) {
      return CompanionPoseEvaluator.pose(CompanionAnimation.idleAtDesk, elapsed: 0, context: context);
    }
    final t = elapsed;
    if (t < shake) return CompanionPoseEvaluator.pose(CompanionAnimation.rpsShake, elapsed: t, duration: shake, context: context);
    final r = t - shake;
    CompanionPose pose;
    if (r < hold) {
      pose = CompanionPoseEvaluator.pose(CompanionAnimation.idleAtDesk, elapsed: 0, context: context)..eyes = VisorEyes.wide;
    } else {
      final outcome = -(round.vsCompanion ?? 0);
      final animation = outcome > 0 ? CompanionAnimation.celebrate : (outcome < 0 ? CompanionAnimation.doubleTake : CompanionAnimation.nod);
      final local = r - hold;
      pose = local < animation.defaultDuration
          ? CompanionPoseEvaluator.pose(animation, elapsed: local, context: context)
          : CompanionPoseEvaluator.pose(CompanionAnimation.idleAtDesk, elapsed: 0, context: context);
      if (outcome > 0 && local >= animation.defaultDuration) pose.eyes = VisorEyes.happy;
    }
    pose.held = companion.item;
    pose.leftArm = math.max(pose.leftArm, 0.5);
    return pose;
  }
}
