// Port of Sources/TamagotchiCore/Progress/AchievementEngine.swift, Customization.swift (the accessory unlocks) and
// Features/LifeStage.swift: friendship points with daily caps, achievements and growing up. Nothing here ever
// decreases, and the pet never gets sick or sad because the app was closed.

import '../events/events.dart';
import '../events/sessions.dart';
import '../model/json.dart';
import '../world/settings.dart';

enum AchievementID {
  firstSession('Hello, Patch', 'Connect Claude Code and observe a first session.'),
  firstTurn('First Finish', 'Observe Claude finishing a turn.'),
  firstGreenBuild('Green Light', 'Receive a real passing build or test result.'),
  firstMilestone('Milestone Maker', 'Mark or report a milestone.'),
  globetrotter('Globetrotter', 'Observe Claude Code sessions in 3 different projects.'),
  caseClosed('Case Closed', 'A turn finishes after the companion went into detective mode.'),
  goodFriends('Good Friends', 'Play with your pet on 7 different days (not necessarily in a row).'),
  bestFriends('Best Friends', 'Reach friendship level 5.');

  const AchievementID(this.title, this.criteria);
  final String title;

  /// Exactly how it is earned, so progress is transparent.
  final String criteria;

  Accessory? get reward {
    for (final accessory in Accessory.values) {
      if (accessory.unlockAchievement == this) return accessory;
    }
    return null;
  }
}

enum AccessorySlot { wearable, desk }

enum Accessory {
  // Wearables
  partyHat('Party Hat'),
  beanie('Cozy Beanie'),
  graduationCap('Graduation Cap'),
  detectiveHat('Detective Hat'),
  santaHat('Festive Hat'),
  flowerCrown('Flower Crown'),
  witchHat('Witch Hat'),
  roundGlasses('Round Glasses'),
  headphones('Tiny Headphones'),
  hoodie('Developer Hoodie'),
  scarf('Knitted Scarf'),
  // Desk
  plant('Desk Plant'),
  coffeeMug('Coffee Mug'),
  rubberDuck('Rubber Duck'),
  pumpkin('Little Pumpkin'),
  trophy('Tiny Trophy'),
  lavaLamp('Lava Lamp');

  const Accessory(this.title);
  final String title;

  AccessorySlot get slot => switch (this) {
    plant || coffeeMug || rubberDuck || pumpkin || trophy || lavaLamp => AccessorySlot.desk,
    _ => AccessorySlot.wearable,
  };

  /// The achievement that unlocks it, if that's how it's earned.
  AchievementID? get unlockAchievement => switch (this) {
    headphones => AchievementID.firstSession,
    partyHat => AchievementID.firstTurn,
    trophy => AchievementID.firstGreenBuild,
    graduationCap => AchievementID.firstMilestone,
    detectiveHat => AchievementID.caseClosed,
    hoodie => AchievementID.goodFriends,
    lavaLamp => AchievementID.globetrotter,
    flowerCrown => AchievementID.bestFriends,
    _ => null,
  };

  /// Months (1–12) when a seasonal accessory is available.
  (int, int)? get seasonMonths => switch (this) {
    pumpkin || witchHat => (10, 11),
    santaHat => (12, 12),
    _ => null,
  };

  bool isAvailable({required Set<AchievementID> unlocked, required DateTime date, WorldCalendar calendar = const WorldCalendar.local()}) {
    if (unlockAchievement case final id?) return unlocked.contains(id);
    if (seasonMonths case (final first, final last)) {
      final month = calendar.month(date);
      return month >= first && month <= last;
    }
    return true;
  }
}

enum PetInteraction {
  pet,
  play,
  treat;

  int get points => switch (this) {
    pet => 1,
    play => 2,
    treat => 1,
  };

  /// Maximum points per day from this interaction, so affection cannot be farmed and there is never pressure to keep
  /// clicking.
  int get dailyCap => switch (this) {
    pet => 8,
    play => 8,
    treat => 3,
  };
}

/// Locally stored, transparent progress (the Mac's progress.json: same keys, dates as ISO 8601).
class ProgressState {
  ProgressState();

  /// Achievement name → when it was unlocked.
  Map<String, DateTime> unlocked = {};
  int affectionPoints = 0;

  /// Distinct calendar days (yyyy-MM-dd) with at least one interaction.
  List<String> interactionDays = [];

  /// Points earned per day per interaction type, for daily caps.
  Map<String, int> dailyPoints = {};
  String dailyPointsDay = '';

  /// Hashed project keys seen in real sessions (never names or paths).
  List<String> projectKeys = [];
  int observedSessions = 0;
  int observedTurns = 0;
  int milestones = 0;
  DateTime? firstMetAt;

  Set<AchievementID> get unlockedIDs => {
    for (final name in unlocked.keys)
      if (enumByName(AchievementID.values, name) case final id?) id,
  };

  static const List<int> levelThresholds = [0, 10, 30, 60, 100, 160];

  int get friendshipLevel {
    var level = 0;
    for (var i = 0; i < levelThresholds.length; i++) {
      if (affectionPoints >= levelThresholds[i]) level = i;
    }
    return level;
  }

  int? get pointsToNextLevel {
    final level = friendshipLevel;
    if (!(level + 1 < levelThresholds.length)) return null;
    return levelThresholds[level + 1] - affectionPoints;
  }

  ProgressState copy() => ProgressState.fromJson(toJson());

  Map<String, Object?> toJson() => {
    'unlocked': {for (final e in unlocked.entries) e.key: _iso(e.value)},
    'affectionPoints': affectionPoints,
    'interactionDays': [...interactionDays],
    'dailyPoints': {...dailyPoints},
    'dailyPointsDay': dailyPointsDay,
    'projectKeys': [...projectKeys],
    'observedSessions': observedSessions,
    'observedTurns': observedTurns,
    'milestones': milestones,
    'firstMetAt': ?(firstMetAt == null ? null : _iso(firstMetAt!)),
  };

  /// Reads the Mac's progress.json too. Missing keys take the defaults.
  factory ProgressState.fromJson(Object? json) {
    final j = asMap(json);
    final state = ProgressState();
    for (final e in asMap(j['unlocked']).entries) {
      final date = _parseDate(e.value);
      if (date != null) state.unlocked[e.key] = date;
    }
    state.affectionPoints = integer(j, 'affectionPoints', 0);
    state.interactionDays = [
      for (final d in (j['interactionDays'] is List ? j['interactionDays'] as List : const []))
        if (d is String) d,
    ];
    state.dailyPoints = {
      for (final e in asMap(j['dailyPoints']).entries)
        if (e.value is num) e.key: (e.value as num).toInt(),
    };
    state.dailyPointsDay = string(j, 'dailyPointsDay') ?? '';
    state.projectKeys = [
      for (final k in (j['projectKeys'] is List ? j['projectKeys'] as List : const []))
        if (k is String) k,
    ];
    state.observedSessions = integer(j, 'observedSessions', 0);
    state.observedTurns = integer(j, 'observedTurns', 0);
    state.milestones = integer(j, 'milestones', 0);
    state.firstMetAt = _parseDate(j['firstMetAt']);
    return state;
  }

  /// Swift's `.iso8601` (whole seconds, UTC, "Z").
  static String _iso(DateTime date) {
    final s = date.toUtc().toIso8601String();
    final dot = s.indexOf('.');
    return '${dot < 0 ? s.substring(0, s.length - 1) : s.substring(0, dot)}Z';
  }

  static DateTime? _parseDate(Object? value) {
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    // Swift's default date encoding (seconds since 2001-01-01), in case a file was written that way.
    if (value is num) return DateTime.utc(2001).add(Duration(microseconds: (value * 1e6).round()));
    return null;
  }
}

class InteractionResult {
  const InteractionResult({required this.pointsAwarded, required this.levelUp, required this.unlocked});
  final int pointsAwarded;
  final bool levelUp;
  final List<AchievementID> unlocked;
}

/// Records what earns friendship and achievements (Swift `AchievementEngine`). Persistence is the host's: read
/// [state] (or `state.toJson()`) after a change, and pass a saved state in.
class AchievementEngine {
  AchievementEngine({ProgressState? state, this.calendar = const WorldCalendar.local(), this.onChange}) : state = state ?? ProgressState();

  ProgressState state;
  final WorldCalendar calendar;

  /// Called whenever the Mac would save progress.json.
  void Function(ProgressState state)? onChange;

  /// Records an observed real event. Returns achievements unlocked by it.
  List<AchievementID> record(CompanionEvent event, {SessionTransition? transition, SessionSnapshot? session}) {
    // Simulated and late/restored events never count towards progress.
    if (event.isSimulated || event.delivery != EventDelivery.live) return const [];
    final unlockedNow = <AchievementID>[];
    final now = event.timestamp;

    if (transition?.isNewSession == true || event.kind == EventKind.sessionStarted) {
      if (transition?.isNewSession == true) state.observedSessions += 1;
      unlockedNow.addAll(_unlock(AchievementID.firstSession, now));
      final key = event.project?.key;
      if (key != null && !state.projectKeys.contains(key)) {
        state.projectKeys.add(key);
        if (state.projectKeys.length > 50) state.projectKeys.removeAt(0);
      }
      if (state.projectKeys.length >= 3) unlockedNow.addAll(_unlock(AchievementID.globetrotter, now));
    }
    if (event.kind == EventKind.turnCompleted) {
      state.observedTurns += 1;
      unlockedNow.addAll(_unlock(AchievementID.firstTurn, now));
      if (session != null && session.investigatedThisTurn) unlockedNow.addAll(_unlock(AchievementID.caseClosed, now));
    } else if (event.kind == EventKind.report && event.report?.kind == ReportKind.milestone) {
      state.milestones += 1;
      unlockedNow.addAll(_unlock(AchievementID.firstMilestone, now));
    }
    final outcome = event.buildTestOutcome;
    if (outcome != null && outcome.passed) unlockedNow.addAll(_unlock(AchievementID.firstGreenBuild, now));
    if (unlockedNow.isNotEmpty || event.kind == EventKind.sessionStarted || event.kind == EventKind.turnCompleted) _save();
    return unlockedNow;
  }

  /// A milestone the user marked by hand.
  List<AchievementID> recordManualMilestone(DateTime now) {
    state.milestones += 1;
    final unlocked = _unlock(AchievementID.firstMilestone, now);
    _save();
    return unlocked;
  }

  InteractionResult recordInteraction(PetInteraction interaction, DateTime now) {
    final day = calendar.dayString(now);
    state.firstMetAt ??= now;
    if (state.dailyPointsDay != day) {
      state.dailyPointsDay = day;
      state.dailyPoints = {};
    }
    final used = state.dailyPoints[interaction.name] ?? 0;
    var award = interaction.dailyCap - used;
    if (interaction.points < award) award = interaction.points;
    if (award < 0) award = 0;
    final levelBefore = state.friendshipLevel;
    state.affectionPoints += award;
    state.dailyPoints[interaction.name] = used + award;
    if (!state.interactionDays.contains(day)) {
      state.interactionDays.add(day);
      if (state.interactionDays.length > 400) state.interactionDays.removeAt(0);
    }
    final unlocked = <AchievementID>[];
    if (state.interactionDays.length >= 7) unlocked.addAll(_unlock(AchievementID.goodFriends, now));
    if (state.friendshipLevel >= 5) unlocked.addAll(_unlock(AchievementID.bestFriends, now));
    _save();
    return InteractionResult(pointsAwarded: award, levelUp: state.friendshipLevel > levelBefore, unlocked: unlocked);
  }

  bool isUnlocked(AchievementID id) => state.unlocked[id.name] != null;

  void reset() {
    state = ProgressState();
    _save();
  }

  List<AchievementID> _unlock(AchievementID id, DateTime date) {
    if (state.unlocked[id.name] != null) return const [];
    state.unlocked[id.name] = date;
    return [id];
  }

  void _save() => onChange?.call(state);
}

/// Mochi grows up: kitten, then young, then grown-up, as the friendship grows over the weeks. The inputs (affection
/// points, days together, the first meeting) never go down, so neither does the stage.
enum LifeStage implements Comparable<LifeStage> {
  kitten('Kitten'),
  young('Young'),
  grownUp('Grown-up');

  const LifeStage(this.title);
  final String title;

  /// A stored stage: Swift encodes it as its Int raw value (kitten 0, young 1, grownUp 2); a name works too.
  static LifeStage? fromJson(Object? value) =>
      value is int && value >= 0 && value < values.length ? values[value] : enumByName(values, value);

  @override
  int compareTo(LifeStage other) => index - other.index;

  static double _weeks(ProgressState progress, DateTime now) =>
      progress.firstMetAt == null ? 0 : now.difference(progress.firstMetAt!).inMicroseconds / 1e6 / (7 * 86400);

  static LifeStage stage(ProgressState progress, DateTime now) {
    final days = progress.interactionDays.length;
    final weeks = _weeks(progress, now);
    final level = progress.friendshipLevel;
    if (level >= 4 && (days >= 10 || weeks >= 3)) return LifeStage.grownUp;
    if (level >= 2 && (days >= 3 || weeks >= 1)) return LifeStage.young;
    return LifeStage.kitten;
  }

  /// What it takes to reach the next stage, in plain words (null when fully grown).
  static String? nextStep(ProgressState progress, DateTime now) {
    final current = stage(progress, now);
    if (current == LifeStage.grownUp) return null;
    final (level, days, weeks) = current == LifeStage.kitten ? (2, 3, 1) : (4, 10, 3);
    final needs = <String>[];
    if (progress.friendshipLevel < level) needs.add('friendship level $level');
    final together = progress.interactionDays.length;
    final known = _weeks(progress, now);
    if (together < days && known < weeks) {
      needs.add('$days days of play ($together so far) or $weeks week${weeks == 1 ? '' : 's'} together');
    }
    final next = LifeStage.values[current.index + 1].title.toLowerCase();
    return needs.isEmpty ? null : 'Grows ${next == 'grown-up' ? 'up' : 'into a young cat'} with ${needs.join(' and ')}';
  }
}
