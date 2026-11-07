// W20, holidays. Port of Sources/TamagotchiCore/Features/SeasonModels.swift (the events, their priorities, the
// settings and `SeasonCalendar`: which event shows on a date, the next one, the last day of a run, once-per-occasion
// keys) and the pure parts of Sources/App/Features/Seasons (SeasonDecor's costumes, greetings and titles, the treat
// for each season from SeasonalTreats, the birthday candles, and SeasonController's greet-once bookkeeping) as
// `SeasonTracker`. The decorations themselves are drawn by mochi_art.

import 'dart:math' as math;

import '../model/animations.dart';
import '../model/json.dart';
import '../progress/progress.dart';
import '../world/settings.dart';
import 'moment.dart';

/// Holidays and personal days that decorate the world.
enum SeasonalEvent {
  halloween('Halloween', 4),
  diwali('Diwali', 5),
  christmas('Christmas', 3),
  newYear('New Year', 2),
  valentines("Valentine's Day", 1),
  userBirthday('Your birthday', 7),
  mochiBirthday("Pet's birthday", 6);

  const SeasonalEvent(this.title, this.priority);

  /// A name for lists; the pet's birthday is named with the pet's name by [displayTitle].
  final String title;

  /// Wins when two events overlap: personal days first, then the bigger festivals.
  final int priority;

  /// The event's name as the user sees it ("Mochi's birthday").
  String displayTitle(String petName) => this == mochiBirthday ? "$petName's birthday" : title;
}

/// The Mac's `seasonal` setting (same keys and defaults).
class SeasonalSettings {
  const SeasonalSettings({this.enabled = true, this.birthdayMonth, this.birthdayDay, this.decorateMenuBar = true});

  final bool enabled;
  final int? birthdayMonth;
  final int? birthdayDay;

  /// A little decoration beside the pet's spot in the menu bar (on Windows: the taskbar strip).
  final bool decorateMenuBar;

  SeasonalSettings copyWith({bool? enabled, int? Function()? birthdayMonth, int? Function()? birthdayDay, bool? decorateMenuBar}) =>
      SeasonalSettings(
        enabled: enabled ?? this.enabled,
        birthdayMonth: birthdayMonth == null ? this.birthdayMonth : birthdayMonth(),
        birthdayDay: birthdayDay == null ? this.birthdayDay : birthdayDay(),
        decorateMenuBar: decorateMenuBar ?? this.decorateMenuBar,
      );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'birthdayMonth': ?birthdayMonth,
    'birthdayDay': ?birthdayDay,
    'decorateMenuBar': decorateMenuBar,
  };

  static SeasonalSettings fromJson(Object? json) {
    final j = asMap(json);
    return SeasonalSettings(
      enabled: boolean(j, 'enabled', true),
      birthdayMonth: j['birthdayMonth'] is num ? (j['birthdayMonth'] as num).toInt() : null,
      birthdayDay: j['birthdayDay'] is num ? (j['birthdayDay'] as num).toInt() : null,
      decorateMenuBar: boolean(j, 'decorateMenuBar', true),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SeasonalSettings &&
      other.enabled == enabled &&
      other.birthdayMonth == birthdayMonth &&
      other.birthdayDay == birthdayDay &&
      other.decorateMenuBar == decorateMenuBar;

  @override
  int get hashCode => Object.hash(enabled, birthdayMonth, birthdayDay, decorateMenuBar);
}

/// Which seasonal event (if any) is active on a date. Pure: everything depends on the arguments. `mochiBirthday` is
/// the day the pet was adopted (`ProgressState.firstMetAt`); only its anniversaries count.
abstract final class SeasonCalendar {
  /// Diwali (Lakshmi Puja) by year. The festival follows the lunar calendar, so it is looked up, not computed; years
  /// missing here simply have no Diwali decorations.
  static const Map<int, (int, int)> diwaliDates = {
    2025: (10, 20),
    2026: (11, 8),
    2027: (10, 29),
    2028: (10, 17),
    2029: (11, 5),
    2030: (10, 26),
  };

  /// Diwali lights go up three days early and stay two days after.
  static const int diwaliFrom = -3;
  static const int diwaliTo = 2;

  /// The event to show on [date]: the highest-priority one whose window contains it (null when decorations are off).
  static SeasonalEvent? event(
    DateTime date, {
    required SeasonalSettings settings,
    DateTime? mochiBirthday,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    if (!settings.enabled) return null;
    final events = activeEvents(date, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar);
    return events.isEmpty ? null : events.first;
  }

  /// Every event whose window contains [date], highest priority first (ignores `enabled`).
  static List<SeasonalEvent> activeEvents(
    DateTime date, {
    required SeasonalSettings settings,
    DateTime? mochiBirthday,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    final today = calendar.local(date);
    final year = today.year;
    final month = today.month;
    final day = today.day;
    final events = <SeasonalEvent>[];

    if ((settings.birthdayMonth, settings.birthdayDay) case (final m?, final d?) when isAnniversary(m, d, today)) {
      events.add(SeasonalEvent.userBirthday);
    }
    if (mochiBirthday != null) {
      final first = calendar.local(mochiBirthday);
      if (year > first.year && isAnniversary(first.month, first.day, today)) events.add(SeasonalEvent.mochiBirthday);
    }
    final offset = daysFromDiwali(date, year, calendar: calendar);
    if (offset != null && offset >= diwaliFrom && offset <= diwaliTo) events.add(SeasonalEvent.diwali);
    if ((month == 10 && day >= 24) || (month == 11 && day == 1)) events.add(SeasonalEvent.halloween);
    if (month == 12 && day >= 18 && day <= 26) events.add(SeasonalEvent.christmas);
    if ((month == 12 && day == 31) || (month == 1 && day == 1)) events.add(SeasonalEvent.newYear);
    if (month == 2 && day >= 13 && day <= 14) events.add(SeasonalEvent.valentines);
    events.sort((a, b) => b.priority.compareTo(a.priority));
    return events;
  }

  /// The next time a different event begins after [date] (within about a year), and the day it starts.
  static (SeasonalEvent, DateTime)? nextEvent(
    DateTime date, {
    required SeasonalSettings settings,
    DateTime? mochiBirthday,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    if (!settings.enabled) return null;
    var day = calendar.startOfDay(date);
    var previous = event(day, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar);
    for (var i = 0; i < 370; i++) {
      day = calendar.addingDays(day, 1);
      final current = event(day, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar);
      if (current != null && current != previous) return (current, day);
      previous = current;
    }
    return null;
  }

  /// The last day of the run of days showing [shown] that contains [date] (null if it isn't showing).
  static DateTime? lastDay(
    SeasonalEvent shown,
    DateTime date, {
    required SeasonalSettings settings,
    DateTime? mochiBirthday,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    var day = calendar.startOfDay(date);
    if (event(day, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar) != shown) return null;
    for (var i = 0; i < 14; i++) {
      final next = calendar.addingDays(day, 1);
      if (event(next, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar) != shown) break;
      day = next;
    }
    return day;
  }

  /// Identifies one occurrence of an event (e.g. "halloween-2026"), so it is greeted only once. New Year's Eve and New
  /// Year's Day share the new year's key.
  static String occasionKey(SeasonalEvent event, DateTime date, {WorldCalendar calendar = const WorldCalendar.local()}) {
    final year = event == SeasonalEvent.newYear ? newYear(date, calendar: calendar) : calendar.year(date);
    return '${event.name}-$year';
  }

  /// The New Year being welcomed (or just welcomed): next year from July on, this year before.
  static int newYear(DateTime date, {WorldCalendar calendar = const WorldCalendar.local()}) {
    final t = calendar.local(date);
    return t.month >= 7 ? t.year + 1 : t.year;
  }

  /// Whole years since [start] on [date] (the pet's age on its birthday).
  static int yearsSince(DateTime start, DateTime date, {WorldCalendar calendar = const WorldCalendar.local()}) =>
      math.max(0, calendar.year(date) - calendar.year(start));

  /// Whether ([month], [day]) falls on [today] (a local date); 29 February is kept on the 28th in other years.
  static bool isAnniversary(int month, int day, DateTime today) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return false;
    if (month == 2 && day == 29 && !isLeapYear(today.year)) return today.month == 2 && today.day == 28;
    return today.month == month && today.day == day;
  }

  /// Gregorian leap years.
  static bool isLeapYear(int year) => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

  /// Days from [year]'s Diwali to [date] (negative before it), if the year is known.
  static int? daysFromDiwali(DateTime date, int year, {WorldCalendar calendar = const WorldCalendar.local()}) {
    final known = diwaliDates[year];
    if (known == null) return null;
    final diwali = calendar.date(year, known.$1, known.$2);
    return calendar.daysBetween(diwali, date);
  }

  /// Settings › Holidays: what's on now and what's next, e.g. "Halloween until 1 November. Next: Diwali from
  /// 5 November." [formatDay] writes a day and month in the user's locale.
  static String statusLine(
    DateTime now, {
    required SeasonalSettings settings,
    DateTime? adopted,
    required String petName,
    required String Function(DateTime) formatDay,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    if (!settings.enabled) return 'Decorations are off.';
    final parts = <String>[];
    final current = event(now, settings: settings, mochiBirthday: adopted, calendar: calendar);
    if (current != null) {
      final until = lastDay(current, now, settings: settings, mochiBirthday: adopted, calendar: calendar);
      final name = current.displayTitle(petName);
      if (until != null && !calendar.isSameDay(until, now)) {
        parts.add('$name until ${formatDay(until)}.');
      } else {
        parts.add('$name today!');
      }
    }
    final next = nextEvent(now, settings: settings, mochiBirthday: adopted, calendar: calendar);
    if (next != null) parts.add('Next: ${next.$1.displayTitle(petName)} from ${formatDay(next.$2)}.');
    if (adopted != null) parts.add("$petName's birthday is ${formatDay(adopted)}, the day you met.");
    return parts.isEmpty ? 'Nothing to celebrate for a while.' : parts.join(' ');
  }
}

enum Wearer { pet, companion }

/// The treat Mochi gets depends on the season: candy at Halloween, a laddoo at Diwali, gingerbread at Christmas, cake
/// on birthdays, a heart cookie on Valentine's Day (mochi_art draws each).
enum TreatStyle {
  cookie,
  candy,
  laddoo,
  gingerbread,
  cakeSlice,
  heartCookie;

  static TreatStyle of(SeasonalEvent? event) => switch (event) {
    SeasonalEvent.halloween => candy,
    SeasonalEvent.diwali => laddoo,
    SeasonalEvent.christmas => gingerbread,
    SeasonalEvent.userBirthday || SeasonalEvent.mochiBirthday => cakeSlice,
    SeasonalEvent.valentines => heartCookie,
    SeasonalEvent.newYear || null => cookie,
  };
}

/// The once-per-occasion hello.
class SeasonGreeting {
  const SeasonGreeting({required this.title, required this.detail, required this.line, required this.animation});
  final String title;
  final String detail;
  final String line;
  final PetAnimation animation;
}

/// Costumes, greetings and candles (the Mac's SeasonDecor).
abstract final class SeasonDecor {
  /// The costume for an event, worn when the user hasn't chosen an accessory (the same for both characters).
  static Accessory? costume(SeasonalEvent? event, [Wearer wearer = Wearer.pet]) => switch (event) {
    SeasonalEvent.halloween => Accessory.witchHat,
    SeasonalEvent.christmas => Accessory.santaHat,
    SeasonalEvent.newYear || SeasonalEvent.userBirthday || SeasonalEvent.mochiBirthday => Accessory.partyHat,
    SeasonalEvent.diwali => Accessory.flowerCrown,
    SeasonalEvent.valentines || null => null,
  };

  /// Candles on the birthday cake: the pet's age (1–5) on its birthday, 3 otherwise.
  static int candles(
    SeasonalEvent? event, {
    DateTime? adopted,
    required DateTime now,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    if (event != SeasonalEvent.mochiBirthday) return 3;
    if (adopted == null) return 1;
    return math.min(5, math.max(1, SeasonCalendar.yearsSince(adopted, now, calendar: calendar)));
  }

  static SeasonGreeting greeting(
    SeasonalEvent event, {
    required String petName,
    required String companionName,
    DateTime? adopted,
    required DateTime now,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    final pet = petName;
    final companion = companionName;
    switch (event) {
      case SeasonalEvent.halloween:
        return SeasonGreeting(
          title: 'Happy Halloween!',
          detail: '$pet and $companion dressed up. Treats are candy this week.',
          line: 'Trick or treat!',
          animation: PetAnimation.excitedJump,
        );
      case SeasonalEvent.diwali:
        return const SeasonGreeting(
          title: 'Happy Diwali!',
          detail: 'Diyas, lights and a rangoli — and laddoos for treats.',
          line: 'So many lights!',
          animation: PetAnimation.dance,
        );
      case SeasonalEvent.christmas:
        return const SeasonGreeting(
          title: 'Merry Christmas!',
          detail: 'Snow outside, a tree inside, gingerbread for treats.',
          line: 'Is that… snow?!',
          animation: PetAnimation.happyBounce,
        );
      case SeasonalEvent.newYear:
        return SeasonGreeting(
          title: 'Happy New Year!',
          detail: "Here's to ${SeasonCalendar.newYear(now, calendar: calendar)} together.",
          line: 'Happy New Year!',
          animation: PetAnimation.victory,
        );
      case SeasonalEvent.valentines:
        return SeasonGreeting(
          title: "Happy Valentine's Day!",
          detail: '$pet baked heart cookies.',
          line: "You're my favourite human.",
          animation: PetAnimation.greet,
        );
      case SeasonalEvent.userBirthday:
        return SeasonGreeting(
          title: 'Happy Birthday!',
          detail: '$pet and $companion threw you a little party.',
          line: 'Happy birthday to you!',
          animation: PetAnimation.dance,
        );
      case SeasonalEvent.mochiBirthday:
        final years = adopted == null ? 1 : math.max(1, SeasonCalendar.yearsSince(adopted, now, calendar: calendar));
        return SeasonGreeting(
          title: 'Happy Birthday, $pet!',
          detail: '$years year${years == 1 ? '' : 's'} together today.',
          line: "It's my birthday!",
          animation: PetAnimation.victory,
        );
    }
  }
}

/// The Mac's SeasonController without its timers: [refresh] on launch (a few seconds in), on the hour, at midnight,
/// on wake and when the seasonal settings or the adoption date change. It keeps which occasions were greeted (save
/// [toJson], the Mac's seasons.json) and holds the greeting's toast until Mochi's window is open.
class SeasonTracker {
  SeasonTracker({Iterable<String> greeted = const []}) : _greeted = {...greeted};

  final Set<String> _greeted;

  /// The event showing since the last [refresh].
  SeasonalEvent? event;

  /// The greeting's note, waiting for Mochi's window to be open (see [takePendingToast]).
  FeatureToast? pendingToast;

  Set<String> get greeted => Set.unmodifiable(_greeted);

  /// Re-reads the calendar. Returns the greeting to show now (a line, a happy hop and Patch celebrating) the first
  /// time an occasion is seen, else null; its toast waits in [pendingToast]. With [greet] false (right at launch) it
  /// only updates [event].
  FeatureMoment? refresh(
    DateTime now, {
    required SeasonalSettings settings,
    DateTime? adopted,
    required String petName,
    required String companionName,
    bool greet = true,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    final current = SeasonCalendar.event(now, settings: settings, mochiBirthday: adopted, calendar: calendar);
    event = current;
    if (!greet || current == null) return null;
    final key = SeasonCalendar.occasionKey(current, now, calendar: calendar);
    if (_greeted.contains(key)) return null;
    _greeted.add(key);
    return celebrate(current, petName: petName, companionName: companionName, adopted: adopted, now: now, calendar: calendar);
  }

  /// The once-per-occasion hello for [shown] (also for replaying it).
  FeatureMoment celebrate(
    SeasonalEvent shown, {
    required String petName,
    required String companionName,
    DateTime? adopted,
    required DateTime now,
    WorldCalendar calendar = const WorldCalendar.local(),
  }) {
    final g = SeasonDecor.greeting(shown, petName: petName, companionName: companionName, adopted: adopted, now: now, calendar: calendar);
    pendingToast = FeatureToast(g.title, g.detail, seconds: 7);
    return FeatureMoment(line: FeatureLine(g.line), pet: g.animation, companion: CompanionAnimation.celebrate);
  }

  /// The waiting toast, once Mochi's window is open and the room isn't being decorated.
  FeatureToast? takePendingToast({required bool windowVisible, bool decorating = false}) {
    if (!windowVisible || decorating) return null;
    final toast = pendingToast;
    pendingToast = null;
    return toast;
  }

  /// The greeted occasions to save: only those from the last couple of years, sorted.
  Map<String, Object?> toJson({required DateTime now, WorldCalendar calendar = const WorldCalendar.local()}) {
    final year = calendar.year(now);
    final recent = _greeted.where((key) {
      final y = int.tryParse(key.split('-').last);
      return y != null && y >= year - 1;
    }).toList()..sort();
    return {'greeted': recent};
  }

  static SeasonTracker fromJson(Object? json) {
    final list = asMap(json)['greeted'];
    return SeasonTracker(greeted: [if (list is List) ...list.whereType<String>()]);
  }
}
