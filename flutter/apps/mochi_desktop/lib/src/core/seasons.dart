// Which holiday (if any) decorates Mochi's world today: the Dart port of TamagotchiCore's SeasonCalendar
// (Sources/TamagotchiCore/Features/SeasonModels.swift). Pure: everything depends on the arguments. mochi_art draws the
// decorations and costumes for each SeasonalEvent; this says which one is on.

import 'package:mochi_art/mochi_art.dart' show SeasonalEvent;

/// Your holiday settings, as Settings › Fun keeps them.
class SeasonalSettings {
  const SeasonalSettings({this.enabled = true, this.birthdayMonth, this.birthdayDay});

  final bool enabled;
  final int? birthdayMonth;
  final int? birthdayDay;
}

abstract final class SeasonCalendar {
  /// Diwali (Lakshmi Puja) by year. The festival follows the lunar calendar, so it is looked up, not computed; years
  /// missing here simply have no Diwali decorations.
  static final Map<int, DateTime> diwaliDates = {
    2025: DateTime(2025, 10, 20),
    2026: DateTime(2026, 11, 8),
    2027: DateTime(2027, 10, 29),
    2028: DateTime(2028, 10, 17),
    2029: DateTime(2029, 11, 5),
    2030: DateTime(2030, 10, 26),
  };

  /// Diwali lights go up three days early and stay two days after.
  static const int diwaliFrom = -3;
  static const int diwaliTo = 2;

  /// Wins when two events overlap: personal days first, then the bigger festivals.
  static int priority(SeasonalEvent event) => switch (event) {
    SeasonalEvent.userBirthday => 7,
    SeasonalEvent.mochiBirthday => 6,
    SeasonalEvent.diwali => 5,
    SeasonalEvent.halloween => 4,
    SeasonalEvent.christmas => 3,
    SeasonalEvent.newYear => 2,
    SeasonalEvent.valentines => 1,
  };

  /// The event to show on [date]: the highest-priority one whose window contains it. [mochiBirthday] is the day the
  /// pet arrived; only its anniversaries count.
  static SeasonalEvent? event(DateTime date, SeasonalSettings settings, {DateTime? mochiBirthday}) =>
      settings.enabled ? activeEvents(date, settings, mochiBirthday: mochiBirthday).firstOrNull : null;

  /// Every event whose window contains [date], highest priority first (whether or not holidays are on).
  static List<SeasonalEvent> activeEvents(DateTime date, SeasonalSettings settings, {DateTime? mochiBirthday}) {
    final year = date.year, month = date.month, day = date.day;
    final events = <SeasonalEvent>[];
    final birthMonth = settings.birthdayMonth, birthDay = settings.birthdayDay;
    if (birthMonth != null && birthDay != null && isAnniversary(birthMonth, birthDay, date)) events.add(SeasonalEvent.userBirthday);
    final adopted = mochiBirthday;
    if (adopted != null && year > adopted.year && isAnniversary(adopted.month, adopted.day, date)) {
      events.add(SeasonalEvent.mochiBirthday);
    }
    final diwali = daysFromDiwali(date);
    if (diwali != null && diwali >= diwaliFrom && diwali <= diwaliTo) events.add(SeasonalEvent.diwali);
    if ((month == 10 && day >= 24) || (month == 11 && day == 1)) events.add(SeasonalEvent.halloween);
    if (month == 12 && day >= 18 && day <= 26) events.add(SeasonalEvent.christmas);
    if ((month == 12 && day == 31) || (month == 1 && day == 1)) events.add(SeasonalEvent.newYear);
    if (month == 2 && (day == 13 || day == 14)) events.add(SeasonalEvent.valentines);
    events.sort((a, b) => priority(b).compareTo(priority(a)));
    return events;
  }

  /// The next time a different event begins after [date] (within about a year), and the day it starts.
  static ({SeasonalEvent event, DateTime starts})? nextEvent(DateTime date, SeasonalSettings settings, {DateTime? mochiBirthday}) {
    if (!settings.enabled) return null;
    var day = DateTime(date.year, date.month, date.day);
    var previous = event(day, settings, mochiBirthday: mochiBirthday);
    for (var i = 0; i < 370; i++) {
      day = DateTime(day.year, day.month, day.day + 1);
      final current = event(day, settings, mochiBirthday: mochiBirthday);
      if (current != null && current != previous) return (event: current, starts: day);
      previous = current;
    }
    return null;
  }

  /// The last day of the run of days showing [shown] that contains [date] (null if it isn't showing).
  static DateTime? lastDay(SeasonalEvent shown, DateTime date, SeasonalSettings settings, {DateTime? mochiBirthday}) {
    var day = DateTime(date.year, date.month, date.day);
    if (event(day, settings, mochiBirthday: mochiBirthday) != shown) return null;
    for (var i = 0; i < 14; i++) {
      final next = DateTime(day.year, day.month, day.day + 1);
      if (event(next, settings, mochiBirthday: mochiBirthday) != shown) break;
      day = next;
    }
    return day;
  }

  /// Whether (month, day) falls on [date]; 29 February is kept on the 28th in other years.
  static bool isAnniversary(int month, int day, DateTime date) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return false;
    if (month == 2 && day == 29 && !isLeapYear(date.year)) return date.month == 2 && date.day == 28;
    return date.month == month && date.day == day;
  }

  /// Gregorian leap years.
  static bool isLeapYear(int year) => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

  /// Days from this year's Diwali to [date] (negative before it), if the year is known.
  static int? daysFromDiwali(DateTime date) {
    final diwali = diwaliDates[date.year];
    if (diwali == null) return null;
    // Calendar days, counted in UTC so a daylight-saving change doesn't shift them.
    final from = DateTime.utc(diwali.year, diwali.month, diwali.day);
    final to = DateTime.utc(date.year, date.month, date.day);
    return to.difference(from).inDays;
  }

  /// The event's name, the pet's birthday named after the pet ("Mochi's birthday").
  static String title(SeasonalEvent event, {required String petName}) =>
      event == SeasonalEvent.mochiBirthday ? "$petName's birthday" : event.title;
}
