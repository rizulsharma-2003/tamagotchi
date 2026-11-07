// The part of the Mac's AppSettings (Sources/TamagotchiCore/Settings/AppSettings.swift, QuietHours.swift,
// Features/SpeechModels.swift) that Mochi's world reads, with the same keys, defaults and enum raw values, so a host
// can store them in its own settings file and hand them to the world. Plus a calendar the host injects (day
// boundaries and quiet hours are local time on the Mac).

import '../model/animations.dart';
import '../model/json.dart';

enum ReducedMotionPreference { system, always, never }

enum CompanionVisibility { duringSessions, always, never }

enum Chattiness { quiet, normal, chatty }

/// How a category of event may reach the user.
class CategoryDelivery {
  const CategoryDelivery({this.animate = true, this.badge = false, this.banner = false, this.sound = false});

  final bool animate;
  final bool badge;
  final bool banner;
  final bool sound;

  CategoryDelivery copyWith({bool? animate, bool? badge, bool? banner, bool? sound}) => CategoryDelivery(
    animate: animate ?? this.animate,
    badge: badge ?? this.badge,
    banner: banner ?? this.banner,
    sound: sound ?? this.sound,
  );

  Map<String, Object?> toJson() => {'animate': animate, 'badge': badge, 'banner': banner, 'sound': sound};

  static CategoryDelivery fromJson(Object? json) {
    final j = asMap(json);
    return CategoryDelivery(
      animate: boolean(j, 'animate', true),
      badge: boolean(j, 'badge', false),
      banner: boolean(j, 'banner', false),
      sound: boolean(j, 'sound', false),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CategoryDelivery && other.animate == animate && other.badge == badge && other.banner == banner && other.sound == sound;

  @override
  int get hashCode => Object.hash(animate, badge, banner, sound);
}

enum NotificationCategory {
  needsAttention('Claude needs you', 'Permission prompts, idle input requests and MCP dialogs.'),
  turnCompleted('Turn completed', 'Claude finished responding. Says nothing about builds or tests.'),
  toolFailure('Tool errors', 'A tool call reported an error. The turn usually continues.'),
  turnError('API errors', 'A turn ended because of an API error (rate limit, overload…).'),
  buildTest('Build & test results', 'Explicit reports, or build/test commands with a trustworthy exit status.'),
  sessionLifecycle('Session start & end', 'A Claude Code session started or ended.'),
  toolActivity('Tool activity', 'Individual tool calls. Never sent as notifications.'),
  milestone('Milestones', 'Milestones you mark or report.'),
  achievement('Achievements', 'Friendship achievements unlocked.');

  const NotificationCategory(this.title, this.explanation);
  final String title;
  final String explanation;

  /// Tool activity is far too frequent for banners or badges.
  bool get allowsBanner => this != toolActivity;
  bool get allowsBadge => this != toolActivity && this != sessionLifecycle;

  CategoryDelivery get defaultDelivery => switch (this) {
    needsAttention => const CategoryDelivery(animate: true, badge: true, banner: false, sound: true),
    turnCompleted => const CategoryDelivery(animate: true, badge: false, banner: false, sound: true),
    toolFailure => const CategoryDelivery(animate: true, badge: true, banner: false, sound: false),
    turnError => const CategoryDelivery(animate: true, badge: true, banner: false, sound: false),
    buildTest => const CategoryDelivery(animate: true, badge: false, banner: false, sound: true),
    sessionLifecycle => const CategoryDelivery(animate: true, badge: false, banner: false, sound: true),
    toolActivity => const CategoryDelivery(animate: true, badge: false, banner: false, sound: false),
    milestone => const CategoryDelivery(animate: true, badge: false, banner: false, sound: true),
    achievement => const CategoryDelivery(animate: true, badge: false, banner: false, sound: true),
  };
}

/// Local-time questions the world asks about a moment. The Mac uses the user's calendar and time zone; hosts pass
/// [WorldCalendar.local] (the default) and tests pass [WorldCalendar.utc] so fixtures don't depend on the machine.
class WorldCalendar {
  const WorldCalendar.local() : _utc = false;
  const WorldCalendar.utc() : _utc = true;

  final bool _utc;

  DateTime local(DateTime moment) => _utc ? moment.toUtc() : moment.toLocal();

  /// A number that changes once per local day (Swift's `ordinality(of: .day, in: .era)`; only compared for equality).
  int dayNumber(DateTime moment) {
    final t = local(moment);
    return DateTime.utc(t.year, t.month, t.day).millisecondsSinceEpoch ~/ 86400000;
  }

  /// yyyy-MM-dd in local time (the achievement engine's day keys).
  String dayString(DateTime moment) {
    final t = local(moment);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}';
  }

  int minuteOfDay(DateTime moment) {
    final t = local(moment);
    return t.hour * 60 + t.minute;
  }

  int month(DateTime moment) => local(moment).month;
}

/// A daily quiet window, e.g. 22:00–08:00 (wrapping past midnight is supported).
class QuietHours {
  const QuietHours({this.enabled = false, int startMinute = 22 * 60, int endMinute = 8 * 60})
    : startMinute = ((startMinute % 1440) + 1440) % 1440,
      endMinute = ((endMinute % 1440) + 1440) % 1440;

  final bool enabled;

  /// Minutes after midnight.
  final int startMinute;
  final int endMinute;

  bool isActive(DateTime moment, {WorldCalendar calendar = const WorldCalendar.local()}) {
    if (!enabled || startMinute == endMinute) return false;
    final minute = calendar.minuteOfDay(moment);
    if (startMinute < endMinute) return minute >= startMinute && minute < endMinute;
    return minute >= startMinute || minute < endMinute;
  }

  Map<String, Object?> toJson() => {'enabled': enabled, 'startMinute': startMinute, 'endMinute': endMinute};

  static QuietHours fromJson(Object? json) {
    final j = asMap(json);
    return QuietHours(
      enabled: boolean(j, 'enabled', false),
      startMinute: integer(j, 'startMinute', 22 * 60),
      endMinute: integer(j, 'endMinute', 8 * 60),
    );
  }
}

/// The settings Mochi's world reads (a subset of the Mac's AppSettings; same JSON keys and defaults).
class WorldSettings {
  const WorldSettings({
    this.pauseReactions = false,
    this.quietMode = false,
    this.quietHours = const QuietHours(),
    this.animationIntensity = AnimationIntensity.normal,
    this.reducedMotion = ReducedMotionPreference.system,
    this.petName = 'Mochi',
    this.companionName = 'Patch',
    this.companionVisibility = CompanionVisibility.duringSessions,
    this.companionLingerMinutes = 10,
    this.companionSleepAfterMinutes = 6,
    this.followSystem = true,
    this.restAfterMinutes = 5,
    this.celebrateCommandResults = true,
    this.longTurnMinutes = 10,
    this.categoryDelivery = const {},
    this.soundEnabled = false,
    this.workSounds = false,
    this.keepNotificationText = true,
    this.pinnedSessionID,
    this.speechEnabled = true,
    this.chattiness = Chattiness.normal,
    this.lifeStages = true,
  });

  final bool pauseReactions;
  final bool quietMode;
  final QuietHours quietHours;
  final AnimationIntensity animationIntensity;
  final ReducedMotionPreference reducedMotion;
  final String petName;
  final String companionName;
  final CompanionVisibility companionVisibility;
  final int companionLingerMinutes;
  final int companionSleepAfterMinutes;

  /// The pet sleeps while the computer rests and is awake while you work.
  final bool followSystem;

  /// Minutes without input before the computer counts as resting.
  final int restAfterMinutes;
  final bool celebrateCommandResults;
  final int longTurnMinutes;

  /// Per-category overrides, keyed by the category's name (Swift's raw value).
  final Map<String, CategoryDelivery> categoryDelivery;
  final bool soundEnabled;
  final bool workSounds;
  final bool keepNotificationText;
  final String? pinnedSessionID;

  /// `speech.enabled` on the Mac.
  final bool speechEnabled;

  /// `speech.chattiness` on the Mac.
  final Chattiness chattiness;

  /// Mochi grows up (kitten → young → grown-up).
  final bool lifeStages;

  CategoryDelivery delivery(NotificationCategory category) {
    var delivery = categoryDelivery[category.name] ?? category.defaultDelivery;
    if (!category.allowsBanner) delivery = delivery.copyWith(banner: false);
    if (!category.allowsBadge) delivery = delivery.copyWith(badge: false);
    return delivery;
  }

  WorldSettings copyWith({
    bool? pauseReactions,
    bool? quietMode,
    QuietHours? quietHours,
    AnimationIntensity? animationIntensity,
    ReducedMotionPreference? reducedMotion,
    String? petName,
    String? companionName,
    CompanionVisibility? companionVisibility,
    int? companionLingerMinutes,
    int? companionSleepAfterMinutes,
    bool? followSystem,
    int? restAfterMinutes,
    bool? celebrateCommandResults,
    int? longTurnMinutes,
    Map<String, CategoryDelivery>? categoryDelivery,
    bool? soundEnabled,
    bool? workSounds,
    bool? keepNotificationText,
    String? Function()? pinnedSessionID,
    bool? speechEnabled,
    Chattiness? chattiness,
    bool? lifeStages,
  }) => WorldSettings(
    pauseReactions: pauseReactions ?? this.pauseReactions,
    quietMode: quietMode ?? this.quietMode,
    quietHours: quietHours ?? this.quietHours,
    animationIntensity: animationIntensity ?? this.animationIntensity,
    reducedMotion: reducedMotion ?? this.reducedMotion,
    petName: petName ?? this.petName,
    companionName: companionName ?? this.companionName,
    companionVisibility: companionVisibility ?? this.companionVisibility,
    companionLingerMinutes: companionLingerMinutes ?? this.companionLingerMinutes,
    companionSleepAfterMinutes: companionSleepAfterMinutes ?? this.companionSleepAfterMinutes,
    followSystem: followSystem ?? this.followSystem,
    restAfterMinutes: restAfterMinutes ?? this.restAfterMinutes,
    celebrateCommandResults: celebrateCommandResults ?? this.celebrateCommandResults,
    longTurnMinutes: longTurnMinutes ?? this.longTurnMinutes,
    categoryDelivery: categoryDelivery ?? this.categoryDelivery,
    soundEnabled: soundEnabled ?? this.soundEnabled,
    workSounds: workSounds ?? this.workSounds,
    keepNotificationText: keepNotificationText ?? this.keepNotificationText,
    pinnedSessionID: pinnedSessionID == null ? this.pinnedSessionID : pinnedSessionID(),
    speechEnabled: speechEnabled ?? this.speechEnabled,
    chattiness: chattiness ?? this.chattiness,
    lifeStages: lifeStages ?? this.lifeStages,
  );

  /// The Mac's AppSettings keys (`speech` is nested as there).
  Map<String, Object?> toJson() => {
    'pauseReactions': pauseReactions,
    'quietMode': quietMode,
    'quietHours': quietHours.toJson(),
    'animationIntensity': animationIntensity.name,
    'reducedMotion': reducedMotion.name,
    'petName': petName,
    'companionName': companionName,
    'companionVisibility': companionVisibility.name,
    'companionLingerMinutes': companionLingerMinutes,
    'companionSleepAfterMinutes': companionSleepAfterMinutes,
    'followSystem': followSystem,
    'restAfterMinutes': restAfterMinutes,
    'celebrateCommandResults': celebrateCommandResults,
    'longTurnMinutes': longTurnMinutes,
    'categoryDelivery': {for (final e in categoryDelivery.entries) e.key: e.value.toJson()},
    'soundEnabled': soundEnabled,
    'workSounds': workSounds,
    'keepNotificationText': keepNotificationText,
    'pinnedSessionID': ?pinnedSessionID,
    'speech': {'enabled': speechEnabled, 'chattiness': chattiness.name},
    'lifeStages': lifeStages,
  };

  /// Reads settings written by any version (the Mac's AppSettings JSON works too): unknown keys are ignored, missing or
  /// bad values take the defaults.
  static WorldSettings fromJson(Object? json) {
    final j = asMap(json);
    const d = WorldSettings();
    final speech = asMap(j['speech']);
    return WorldSettings(
      pauseReactions: boolean(j, 'pauseReactions', d.pauseReactions),
      quietMode: boolean(j, 'quietMode', d.quietMode),
      quietHours: j['quietHours'] is Map ? QuietHours.fromJson(j['quietHours']) : d.quietHours,
      animationIntensity: enumByName(AnimationIntensity.values, j['animationIntensity']) ?? d.animationIntensity,
      reducedMotion: enumByName(ReducedMotionPreference.values, j['reducedMotion']) ?? d.reducedMotion,
      petName: string(j, 'petName') ?? d.petName,
      companionName: string(j, 'companionName') ?? d.companionName,
      companionVisibility: enumByName(CompanionVisibility.values, j['companionVisibility']) ?? d.companionVisibility,
      companionLingerMinutes: integer(j, 'companionLingerMinutes', d.companionLingerMinutes),
      companionSleepAfterMinutes: integer(j, 'companionSleepAfterMinutes', d.companionSleepAfterMinutes),
      followSystem: boolean(j, 'followSystem', d.followSystem),
      restAfterMinutes: integer(j, 'restAfterMinutes', d.restAfterMinutes),
      celebrateCommandResults: boolean(j, 'celebrateCommandResults', d.celebrateCommandResults),
      longTurnMinutes: integer(j, 'longTurnMinutes', d.longTurnMinutes),
      categoryDelivery: {for (final e in asMap(j['categoryDelivery']).entries) e.key: CategoryDelivery.fromJson(e.value)},
      soundEnabled: boolean(j, 'soundEnabled', d.soundEnabled),
      workSounds: boolean(j, 'workSounds', d.workSounds),
      keepNotificationText: boolean(j, 'keepNotificationText', d.keepNotificationText),
      pinnedSessionID: string(j, 'pinnedSessionID'),
      speechEnabled: boolean(speech, 'enabled', d.speechEnabled),
      chattiness: enumByName(Chattiness.values, speech['chattiness']) ?? d.chattiness,
      lifeStages: boolean(j, 'lifeStages', d.lifeStages),
    );
  }
}
