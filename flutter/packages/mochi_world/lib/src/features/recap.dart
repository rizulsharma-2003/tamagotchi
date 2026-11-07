// W16, the daily recap. Port of Sources/TamagotchiCore/Features/DailyRecap.swift (the day's numbers from real events
// and the focus log, the streak, the tiles, the summary line, the evening schedule), the pure parts of
// Sources/App/Features/Recap (RecapController's history start and evening announcement, RecapCardView's words) and
// Sources/TamagotchiCore/Storage/EventJournal.swift's retention as `EventJournal`, the history the recap counts from
// (fed from `MochiWorld.onRecord`).

import 'dart:math' as math;

import '../events/events.dart';
import '../model/animations.dart';
import '../model/json.dart';
import '../world/reactions.dart';
import '../world/settings.dart';
import '../world/world.dart';
import 'focus.dart';
import 'moment.dart';

/// Settings for the end-of-day recap card (the Mac's `recap` setting: same keys and defaults).
class RecapSettings {
  RecapSettings({this.announce = true, int hour = 18, this.banner = false, this.lastAnnouncedDay}) : hour = hour.clamp(0, 23);

  /// Announce the day's recap once in the evening, when there was real activity.
  bool announce;

  /// Local hour (0–23) from which the recap is announced.
  int hour;

  /// Also post a notification banner (off by default, like every banner).
  bool banner;

  /// The last day ("yyyy-MM-dd") the recap was announced, so it happens once a day.
  String? lastAnnouncedDay;

  /// True when the evening announcement is due now: on, past the hour, not yet done today, and only for a day with
  /// real activity.
  bool isAnnouncementDue(DateTime now, {required bool hasActivity, WorldCalendar calendar = const WorldCalendar.local()}) {
    if (!announce || !hasActivity || calendar.hour(now) < hour) return false;
    return lastAnnouncedDay != DailyRecap.dayKey(now, calendar: calendar);
  }

  RecapSettings copy() => RecapSettings(announce: announce, hour: hour, banner: banner, lastAnnouncedDay: lastAnnouncedDay);

  Map<String, Object?> toJson() => {'announce': announce, 'hour': hour, 'banner': banner, 'lastAnnouncedDay': ?lastAnnouncedDay};

  static RecapSettings fromJson(Object? json) {
    final j = asMap(json);
    return RecapSettings(
      announce: boolean(j, 'announce', true),
      hour: integer(j, 'hour', 18),
      banner: boolean(j, 'banner', false),
      lastAnnouncedDay: string(j, 'lastAnnouncedDay'),
    );
  }
}

/// How much of the day the history covers.
sealed class RecapCoverage {
  const RecapCoverage();
}

/// History covers the whole day.
class RecapCoverageFull extends RecapCoverage {
  const RecapCoverageFull();

  @override
  bool operator ==(Object other) => other is RecapCoverageFull;

  @override
  int get hashCode => 11;
}

/// History only starts during the day (retention or the event cap).
class RecapCoveragePartial extends RecapCoverage {
  const RecapCoveragePartial(this.since);
  final DateTime since;

  @override
  bool operator ==(Object other) => other is RecapCoveragePartial && other.since == since;

  @override
  int get hashCode => since.hashCode;
}

/// The day is older than the history kept.
class RecapCoverageNone extends RecapCoverage {
  const RecapCoverageNone();

  @override
  bool operator ==(Object other) => other is RecapCoverageNone;

  @override
  int get hashCode => 13;
}

/// A stat worth a tile on the card. Zero and missing values never get one.
sealed class RecapTile {
  const RecapTile();

  /// The big number ([RecapActiveSpan]'s is the time range, which the host formats in the user's locale).
  String get value;

  /// The words under the number.
  String get label;

  /// A smaller line, if any.
  String? get detail => null;

  Map<String, Object?> toJson();

  @override
  bool operator ==(Object other) => other is RecapTile && other.runtimeType == runtimeType && _same(other.toJson(), toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);

  @override
  String toString() => toJson().toString();
}

bool _same(Map<String, Object?> a, Map<String, Object?> b) => a.length == b.length && a.keys.every((k) => a[k] == b[k]);

class RecapTurns extends RecapTile {
  const RecapTurns(this.count);
  final int count;
  @override
  String get value => '$count';
  @override
  String get label => count == 1 ? 'turn finished' : 'turns finished';
  @override
  Map<String, Object?> toJson() => {'kind': 'turns', 'count': count};
}

class RecapSessions extends RecapTile {
  const RecapSessions(this.count);
  final int count;
  @override
  String get value => '$count';
  @override
  String get label => count == 1 ? 'session' : 'sessions';
  @override
  Map<String, Object?> toJson() => {'kind': 'sessions', 'count': count};
}

class RecapToolCalls extends RecapTile {
  const RecapToolCalls(this.count, {this.top});
  final int count;
  final ToolCategory? top;
  @override
  String get value => '$count';
  @override
  String get label => count == 1 ? 'tool call' : 'tool calls';
  @override
  String? get detail => top?.recapTitle;
  @override
  Map<String, Object?> toJson() => {'kind': 'toolCalls', 'count': count, 'top': ?top?.name};
}

class RecapBuildsAndTests extends RecapTile {
  const RecapBuildsAndTests({required this.builds, required this.tests});
  final int builds;
  final int tests;
  @override
  String get value => '${builds + tests}';
  @override
  String get label => 'green builds & tests';
  @override
  String get detail => [
    if (builds > 0) builds == 1 ? '1 build' : '$builds builds',
    if (tests > 0) tests == 1 ? '1 test run' : '$tests test runs',
  ].join(' · ');
  @override
  Map<String, Object?> toJson() => {'kind': 'buildsAndTests', 'builds': builds, 'tests': tests};
}

class RecapBouncedBack extends RecapTile {
  const RecapBouncedBack(this.count);
  final int count;
  @override
  String get value => '$count';
  @override
  String get label => count == 1 ? 'error bounced back' : 'errors bounced back';
  @override
  String get detail => 'and finished anyway';
  @override
  Map<String, Object?> toJson() => {'kind': 'bouncedBack', 'count': count};
}

class RecapFocus extends RecapTile {
  const RecapFocus({required this.minutes, required this.blocks});
  final int minutes;
  final int blocks;
  @override
  String get value => '$minutes min';
  @override
  String get label => 'of focus';
  @override
  String get detail => blocks == 1 ? '1 focus block' : '$blocks focus blocks';
  @override
  Map<String, Object?> toJson() => {'kind': 'focus', 'minutes': minutes, 'blocks': blocks};
}

class RecapActiveSpan extends RecapTile {
  const RecapActiveSpan({required this.from, required this.to});
  final DateTime from;
  final DateTime to;

  /// Format [from] and [to] as short local times, e.g. "9:00 AM–2:30 PM".
  @override
  String get value => '';
  @override
  String get label => 'active';
  @override
  String get detail {
    final span = to.difference(from).inSeconds;
    final hours = span ~/ 3600;
    final minutes = (span % 3600) ~/ 60;
    return hours > 0 ? '$hours h $minutes min' : '$minutes min';
  }

  @override
  Map<String, Object?> toJson() => {
    'kind': 'activeSpan',
    'from': from.toUtc().microsecondsSinceEpoch / 1e6,
    'to': to.toUtc().microsecondsSinceEpoch / 1e6,
  };
}

class RecapMilestones extends RecapTile {
  const RecapMilestones(this.count);
  final int count;
  @override
  String get value => '$count';
  @override
  String get label => count == 1 ? 'milestone' : 'milestones';
  @override
  Map<String, Object?> toJson() => {'kind': 'milestones', 'count': count};
}

extension ToolCategoryRecap on ToolCategory {
  /// How the recap names the most used kind of tool.
  String get recapTitle => switch (this) {
    ToolCategory.read => 'Mostly reading',
    ToolCategory.search => 'Mostly searching',
    ToolCategory.edit => 'Mostly editing',
    ToolCategory.shell => 'Mostly in the shell',
    ToolCategory.web => 'Mostly on the web',
    ToolCategory.agent => 'Mostly delegating',
    ToolCategory.plan => 'Mostly planning',
    ToolCategory.ask => 'Mostly asking you',
    ToolCategory.skill => 'Mostly skills',
    ToolCategory.mcp => 'Mostly MCP tools',
    ToolCategory.other => 'Many kinds of tools',
  };
}

/// One day's real Claude Code activity, computed from the event journal and the focus log.
///
/// Every number comes from recorded, non-simulated events. What isn't recorded stays zero/null and its tile is left
/// out; nothing is estimated. When history doesn't reach back far enough, the recap says so ([coverage],
/// [streakIsLowerBound]).
class DailyRecap {
  DailyRecap({required this.day, required this.coverage});

  /// Start of the day.
  final DateTime day;
  final RecapCoverage coverage;

  /// Distinct Claude Code sessions with events that day.
  int sessions = 0;
  int turnsFinished = 0;
  int toolCalls = 0;

  /// The most used kind of tool (never "other").
  ToolCategory? topToolCategory;

  /// Passing builds/tests from explicit reports or build/test commands with a trustworthy exit status.
  int buildsPassed = 0;
  int testsPassed = 0;

  /// Failures (tool errors, API errors, failed builds/tests) followed later by a finished turn in the same session.
  int errorsBouncedBack = 0;
  int milestones = 0;
  DateTime? firstActivity;
  DateTime? lastActivity;

  /// Completed focus blocks that ended that day.
  int focusBlocks = 0;
  double focusMinutes = 0;

  /// Consecutive days with real activity, ending on this day (0 when the day had none).
  int streak = 0;

  /// The streak reaches the start of the kept history, so it may well be longer.
  bool streakIsLowerBound = false;

  bool get hasActivity => firstActivity != null;

  /// Nothing at all to show.
  bool get isQuiet => !hasActivity && focusBlocks == 0;

  /// Seconds from the first to the last event, when that is at least a minute.
  double? get activeSpan {
    final first = firstActivity;
    final last = lastActivity;
    if (first == null || last == null) return null;
    final span = last.difference(first).inMicroseconds / 1e6;
    return span >= 60 ? span : null;
  }

  // MARK: Computing

  /// [events] is the journal (simulated and unknown events are ignored here too). [historyStart] is from when on the
  /// history is complete (see [EventJournal.historyStart]).
  static DailyRecap compute({
    required DateTime day,
    required Iterable<CompanionEvent> events,
    Iterable<FocusBlock> focus = const [],
    required DateTime historyStart,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    final dayStart = calendar.startOfDay(day);
    final dayEnd = calendar.addingDays(dayStart, 1);
    final RecapCoverage coverage = !historyStart.isAfter(dayStart)
        ? const RecapCoverageFull()
        : (historyStart.isBefore(dayEnd) ? RecapCoveragePartial(historyStart) : const RecapCoverageNone());
    final recap = DailyRecap(day: dayStart, coverage: coverage);

    final real = events.where((e) => !e.isSimulated && e.kind != EventKind.unknown).toList();
    final today = real.where((e) => !e.timestamp.isBefore(dayStart) && e.timestamp.isBefore(dayEnd)).toList();
    _stableSortByTime(today);

    recap.sessions = {for (final e in today) ?e.sessionID}.length;
    recap.turnsFinished = today.where((e) => e.kind == EventKind.turnCompleted).length;
    final starts = today.where((e) => e.kind == EventKind.toolStarting).toList();
    final finishes = today.where((e) => e.kind == EventKind.toolSucceeded || e.kind == EventKind.toolFailed).toList();
    recap.toolCalls = math.max(starts.length, finishes.length);
    recap.topToolCategory = topCategory(starts.isEmpty ? finishes : starts);
    for (final e in today) {
      final outcome = e.buildTestOutcome;
      if (outcome == null || !outcome.passed) continue;
      if (outcome.kind == CommandKind.build) {
        recap.buildsPassed += 1;
      } else {
        recap.testsPassed += 1;
      }
    }
    recap.milestones = today.where((e) => e.kind == EventKind.report && e.report?.kind == ReportKind.milestone).length;
    recap.errorsBouncedBack = bouncedBack(today);
    recap.firstActivity = today.isEmpty ? null : today.first.timestamp;
    recap.lastActivity = today.isEmpty ? null : today.last.timestamp;

    final blocks = focus.where((b) => !b.endedAt.isBefore(dayStart) && b.endedAt.isBefore(dayEnd)).toList();
    recap.focusBlocks = blocks.length;
    recap.focusMinutes = blocks.fold(0.0, (sum, b) => sum + b.minutes);

    final activeDays = {for (final e in real) calendar.dayNumber(e.timestamp)};
    final (count, lowerBound) = streakEndingOn(dayStart, activeDays: activeDays, historyStart: historyStart, calendar: calendar);
    recap.streak = count;
    recap.streakIsLowerBound = lowerBound;
    return recap;
  }

  static void _stableSortByTime(List<CompanionEvent> events) {
    final indexed = events.indexed.toList()
      ..sort((a, b) {
        final c = a.$2.timestamp.compareTo(b.$2.timestamp);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    events
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
  }

  /// The most used kind of tool among [events] (never "other"); ties go to the earlier category.
  static ToolCategory? topCategory(Iterable<CompanionEvent> events) {
    final counts = <ToolCategory, int>{};
    for (final e in events) {
      final category = e.toolCategory;
      if (category != null && category != ToolCategory.other) counts[category] = (counts[category] ?? 0) + 1;
    }
    ToolCategory? best;
    for (final category in ToolCategory.values) {
      final n = counts[category];
      if (n == null) continue;
      if (best == null || n > counts[best]!) best = category;
    }
    return best;
  }

  /// Failures followed later (that day) by a finished turn in the same session.
  static int bouncedBack(Iterable<CompanionEvent> events) {
    final pending = <String, int>{};
    var bounced = 0;
    for (final e in events) {
      final session = e.sessionID;
      if (session == null) continue;
      if (isFailure(e)) {
        pending[session] = (pending[session] ?? 0) + 1;
      } else if (e.kind == EventKind.turnCompleted) {
        final count = pending.remove(session);
        if (count != null) bounced += count;
      }
    }
    return bounced;
  }

  static bool isFailure(CompanionEvent e) => switch (e.kind) {
    EventKind.toolFailed => !e.interrupted,
    EventKind.turnFailed => true,
    EventKind.report => e.report?.status == ReportStatus.failed,
    _ => false,
  };

  /// Walks back day by day from [day] while there was activity ([activeDays] holds `WorldCalendar.dayNumber`s). Stops
  /// at the first day without any; if that day isn't fully inside the kept history, the count is a lower bound.
  static (int, bool) streakEndingOn(
    DateTime day, {
    required Set<int> activeDays,
    required DateTime historyStart,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    var count = 0;
    var cursor = calendar.startOfDay(day);
    for (var i = 0; i < 3660; i++) {
      if (activeDays.contains(calendar.dayNumber(cursor))) {
        count += 1;
        cursor = calendar.addingDays(cursor, -1);
        continue;
      }
      return (count, count > 0 && historyStart.isAfter(cursor));
    }
    return (count, true);
  }

  // MARK: Presenting

  /// The day's tiles in display order (at most eight).
  List<RecapTile> get tiles {
    final tiles = <RecapTile>[
      if (turnsFinished > 0) RecapTurns(turnsFinished),
      if (sessions > 0) RecapSessions(sessions),
      if (toolCalls > 0) RecapToolCalls(toolCalls, top: topToolCategory),
      if (buildsPassed + testsPassed > 0) RecapBuildsAndTests(builds: buildsPassed, tests: testsPassed),
      if (errorsBouncedBack > 0) RecapBouncedBack(errorsBouncedBack),
      if (focusBlocks > 0) RecapFocus(minutes: focusMinutes.round(), blocks: focusBlocks),
      if (activeSpan != null && firstActivity != null && lastActivity != null) RecapActiveSpan(from: firstActivity!, to: lastActivity!),
      if (milestones > 0) RecapMilestones(milestones),
    ];
    return tiles.length > 8 ? tiles.sublist(0, 8) : tiles;
  }

  /// One friendly line about the day, built only from its real numbers.
  String summary({required String petName, required String companionName}) {
    final focus = focusMinutes.round();
    if (!hasActivity) {
      if (focusBlocks > 0) return '$focus minutes of deep focus while $petName napped. Lovely.';
      return 'A quiet day. $petName and $companionName saved their energy for tomorrow.';
    }
    final turns = count(turnsFinished, 'turn');
    final passed = buildsPassed + testsPassed;
    if (errorsBouncedBack > 0 && turnsFinished > 0) {
      return 'Bounced back from ${count(errorsBouncedBack, 'error')} and still finished $turns. Resilient!';
    }
    if (passed > 0 && turnsFinished > 0) {
      return '$turns finished and ${count(passed, 'green build', plural: 'green builds')} — $petName is proud of you.';
    }
    if (focus > 0 && turnsFinished > 0) return '$turns finished and $focus focused minutes. Nicely done!';
    if (turnsFinished > 0) return '$turns finished across ${count(math.max(1, sessions), 'session')}. Nice and steady.';
    if (sessions > 0) return '$companionName dropped by for ${count(sessions, 'session')} today.';
    return '$companionName checked in today. $petName kept the seat warm.';
  }

  /// The card's title: "Today with Mochi & Patch", "A quiet day with Mochi", "Tuesday with …".
  String title({
    required DateTime now,
    required String petName,
    required String companionName,
    bool showCompanion = true,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    final name = dayName(day, now: now, calendar: calendar);
    final names = showCompanion ? '$petName & $companionName' : petName;
    if (isQuiet) return 'A quiet ${name == 'Today' || name == 'Yesterday' ? 'day' : name} with $names';
    return '$name with $names';
  }

  /// The streak badge: "3 days in a row", "At least 5 days in a row" (null without a streak).
  String? get streakText {
    if (streak <= 0) return null;
    final days = streak == 1 ? '1 day' : '$streak days';
    return streakIsLowerBound ? 'At least $days in a row' : '$days in a row';
  }

  /// What a quiet card says. [computer] is "Mac" or "PC".
  String quietMessage({required DateTime now, String computer = 'Mac', WorldCalendar calendar = const WorldCalendar.local()}) {
    if (coverage is RecapCoverageNone) return 'This day is older than the history kept on this $computer.';
    return 'No Claude Code sessions ${dayName(day, now: now, calendar: calendar) == 'Today' ? 'yet today' : 'this day'}.\nRest days count too.';
  }

  /// The card's footer; [formatTime] writes a short local time ("9:41 AM").
  String footer({String computer = 'Mac', required String Function(DateTime) formatTime}) => switch (coverage) {
    RecapCoveragePartial(:final since) => 'History starts at ${formatTime(since)} this day · real events only',
    _ => 'From real Claude Code events on this $computer',
  };

  static const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  /// "Today", "Yesterday" or the weekday.
  static String dayName(DateTime day, {required DateTime now, WorldCalendar calendar = const WorldCalendar.local()}) {
    if (calendar.isSameDay(day, now)) return 'Today';
    if (calendar.isSameDay(day, calendar.addingDays(now, -1))) return 'Yesterday';
    return _weekdays[calendar.local(day).weekday - 1];
  }

  /// "yyyy-MM-dd" in the calendar's time zone.
  static String dayKey(DateTime date, {WorldCalendar calendar = const WorldCalendar.local()}) => calendar.dayString(date);

  /// The evening notification, for users who turned recap banners on.
  BannerContent readyBanner({required String petName, required String companionName}) {
    final bits = [
      if (turnsFinished > 0) '${count(turnsFinished, 'turn')} finished',
      if (sessions > 0) count(sessions, 'session'),
      if (focusBlocks > 0) '${focusMinutes.round()} min of focus',
    ];
    final detail = bits.isEmpty ? '' : ' ${bits.join(' · ')}.';
    return BannerContent(title: 'Your day with Claude is ready', body: '$petName & $companionName made you a recap card.$detail');
  }

  static String count(int value, String singular, {String? plural}) => '$value ${value == 1 ? singular : (plural ?? '${singular}s')}';

  /// The evening announcement (the Mac's RecapController): a toast, a line, both characters greeting, and a banner
  /// for users who asked for one ([FeatureMoment.applyTo] still holds it back while paused or quiet). [where] tells
  /// the user where to open the card.
  FeatureMoment announcement({
    required String petName,
    required String companionName,
    bool showCompanion = true,
    bool banner = false,
    String where = 'Open Recap in the panel.',
  }) {
    final names = showCompanion ? '$petName & $companionName' : petName;
    return FeatureMoment(
      toast: FeatureToast('Your day with Claude is ready', '$names made you a recap card. $where', seconds: 10),
      line: const FeatureLine('Your day with Claude is ready! Want to see?', duration: 6),
      pet: PetAnimation.greet,
      companion: CompanionAnimation.greet,
      banner: banner ? readyBanner(petName: petName, companionName: companionName) : null,
    );
  }

  Map<String, Object?> toJson() => {
    'day': day.toUtc().microsecondsSinceEpoch / 1e6,
    'coverage': switch (coverage) {
      RecapCoverageFull() => 'full',
      RecapCoveragePartial(:final since) => {'partial': since.toUtc().microsecondsSinceEpoch / 1e6},
      RecapCoverageNone() => 'none',
    },
    'sessions': sessions,
    'turnsFinished': turnsFinished,
    'toolCalls': toolCalls,
    'topToolCategory': ?topToolCategory?.name,
    'buildsPassed': buildsPassed,
    'testsPassed': testsPassed,
    'errorsBouncedBack': errorsBouncedBack,
    'milestones': milestones,
    'firstActivity': ?_seconds(firstActivity),
    'lastActivity': ?_seconds(lastActivity),
    'focusBlocks': focusBlocks,
    'focusMinutes': focusMinutes,
    'streak': streak,
    'streakIsLowerBound': streakIsLowerBound,
  };
}

double? _seconds(DateTime? date) => date == null ? null : date.toUtc().microsecondsSinceEpoch / 1e6;

/// Checks once in a while (the Mac: every minute, and 8 seconds after launch) whether the evening recap is due, and
/// announces it once per active day.
abstract final class RecapSchedule {
  /// Returns the announcement when it's due (and marks the day in [settings], which the host then saves), else null.
  /// [recapFor] computes today's recap; it's only called when the hour has come.
  static FeatureMoment? check({
    required DateTime now,
    required RecapSettings settings,
    required DailyRecap Function() recapFor,
    required WorldSettings world,
    WorldCalendar calendar = const WorldCalendar.local(),
    String where = 'Open Recap in the panel.',
  }) {
    // Cheap checks first; the recap itself is only computed when the time has come.
    if (!settings.isAnnouncementDue(now, hasActivity: true, calendar: calendar)) return null;
    final today = recapFor();
    if (!settings.isAnnouncementDue(now, hasActivity: today.hasActivity, calendar: calendar)) return null;
    settings.lastAnnouncedDay = DailyRecap.dayKey(now, calendar: calendar);
    return today.announcement(
      petName: world.petName,
      companionName: world.companionName,
      showCompanion: world.companionVisibility != CompanionVisibility.never,
      banner: settings.banner,
      where: where,
    );
  }
}

/// A small local history of real events (the Mac's EventJournal, without the file): what the daily recap counts.
/// Feed it from `MochiWorld.onRecord`; it refuses simulated and duplicate events and keeps [retentionDays] days and at
/// most [maxEvents] events. Save [toJsonLines] (one event per line, `eventToJson`) and read it back with [load].
class EventJournal {
  EventJournal({int retentionDays = 7, int maxEvents = 2000})
    : _retentionDays = math.max(0, retentionDays),
      _maxEvents = math.max(0, maxEvents);

  int _retentionDays;
  int _maxEvents;
  final List<CompanionEvent> _events = [];
  final Set<String> _ids = {};
  int _appendedSinceCompaction = 0;

  int get retentionDays => _retentionDays;
  int get maxEvents => _maxEvents;

  /// History is off: events are kept for this run only (don't save then).
  bool get isOff => _retentionDays == 0 || _maxEvents == 0;

  List<CompanionEvent> get all => List.unmodifiable(_events);

  bool contains(String id) => _ids.contains(id);

  /// Changes the retention (the user's history setting) and applies it now.
  void setRetention({required int days, int maxEvents = 2000, required DateTime now}) {
    _retentionDays = math.max(0, days);
    _maxEvents = math.max(0, maxEvents);
    _applyRetention(now);
  }

  /// Appends an event. Returns false for simulated or duplicate events. Project paths are never kept.
  bool append(CompanionEvent event, {required DateTime now}) {
    if (event.isSimulated || _ids.contains(event.id)) return false;
    final stored = event.project?.path == null ? event : (eventFromJson(eventToJson(event)) ?? event);
    _events.add(stored);
    _ids.add(stored.id);
    if (isOff) return true;
    _appendedSinceCompaction += 1;
    if (_appendedSinceCompaction >= 200 || _events.length > _maxEvents + 200) {
      _appendedSinceCompaction = 0;
      _applyRetention(now);
    }
    return true;
  }

  /// Loads saved history (JSON lines or a JSON list of events), dropping anything malformed, simulated, repeated or
  /// out of retention.
  void load(Iterable<Object?> saved, {required DateTime now}) {
    _events.clear();
    _ids.clear();
    for (final json in saved) {
      final event = eventFromJson(json);
      if (event == null || event.isSimulated || _ids.contains(event.id)) continue;
      _events.add(event);
      _ids.add(event.id);
    }
    final indexed = _events.indexed.toList()
      ..sort((a, b) {
        final c = a.$2.timestamp.compareTo(b.$2.timestamp);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    _events
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
    _applyRetention(now);
  }

  /// Re-applies retention now (e.g. after the user changes it).
  void enforceRetention(DateTime now) => _applyRetention(now);

  void clear() {
    _events.clear();
    _ids.clear();
  }

  List<Map<String, Object?>> toJsonLines() => [for (final e in _events) eventToJson(e)];

  /// From when on the journal is complete (the Mac's RecapController): retention, the size cap, the oldest day it
  /// holds, and, with history off, this launch. Anything earlier is unknown, not "nothing happened".
  DateTime historyStart({required DateTime now, required DateTime launchedAt, WorldCalendar calendar = const WorldCalendar.local()}) {
    // Late (spooled) events are appended after newer ones, so look for the oldest.
    DateTime? oldest;
    for (final e in _events) {
      if (oldest == null || e.timestamp.isBefore(oldest)) oldest = e.timestamp;
    }
    var start = calendar.startOfDay(oldest ?? now);
    if (!isOff) {
      final cutoff = now.subtract(Duration(days: _retentionDays));
      if (cutoff.isAfter(start)) start = cutoff;
      if (_events.length >= _maxEvents && oldest != null && oldest.isAfter(start)) start = oldest;
    } else if (launchedAt.isAfter(start)) {
      start = launchedAt;
    }
    return start;
  }

  bool _applyRetention(DateTime now) {
    final before = _events.length;
    if (_retentionDays > 0) {
      final cutoff = now.subtract(Duration(days: _retentionDays));
      _events.removeWhere((e) => e.timestamp.isBefore(cutoff));
    }
    if (_events.length > _maxEvents) _events.removeRange(0, _events.length - _maxEvents);
    if (_events.length != before) {
      _ids
        ..clear()
        ..addAll(_events.map((e) => e.id));
      return true;
    }
    return false;
  }
}
