// W20: holidays by date against the Swift engine (link-spec/world/seasons.json), plus the Mac app's season rules
// (costumes, treats, greetings, greeting once per occasion) and growing up (W12's announcements).

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

const _utc = WorldCalendar.utc();

DateTime _date(Object? seconds) => DateTime.fromMicrosecondsSinceEpoch(((seconds! as num) * 1e6).round(), isUtc: true);

double _seconds(DateTime d) => d.microsecondsSinceEpoch / 1e6;

void main() {
  final fixture = readWorldFixture('seasons.json');

  test('Diwali dates', () {
    expect({
      for (final e in SeasonCalendar.diwaliDates.entries) '${e.key}': [e.value.$1, e.value.$2],
    }, fixture['diwali']);
  });

  for (final v in cases(fixture, 'variants')) {
    test('every day 2025–2030: ${v['note']}', () {
      final settings = SeasonalSettings(
        enabled: v['enabled'] != false,
        birthdayMonth: v['birthdayMonth'] as int?,
        birthdayDay: v['birthdayDay'] as int?,
      );
      final adopted = v['adopted'] == null ? null : _date(v['adopted']);
      final runs = <Object?>[];
      final overlaps = <Object?>[];
      Object? previous = 'none yet';
      for (var day = DateTime.utc(2025); day.isBefore(DateTime.utc(2031, 1, 3)); day = DateTime.utc(day.year, day.month, day.day + 1)) {
        final event = SeasonCalendar.event(day, settings: settings, mochiBirthday: adopted, calendar: _utc)?.name;
        if (event != previous) {
          runs.add([_utc.dayString(day), event]);
          previous = event;
        }
        final active = SeasonCalendar.activeEvents(day, settings: settings, mochiBirthday: adopted, calendar: _utc);
        if (active.length > 1) overlaps.add([_utc.dayString(day), active.map((e) => e.name).toList()]);
      }
      expect(runs, v['runs']);
      expect(overlaps, v['overlaps']);
      for (final s in objs(v['samples'])) {
        final at = _date(s['at']);
        final next = SeasonCalendar.nextEvent(at, settings: settings, mochiBirthday: adopted, calendar: _utc);
        expect(next == null ? null : [next.$1.name, _seconds(next.$2)], s['next'], reason: 'next after ${s['at']}');
        final event = SeasonCalendar.event(at, settings: settings, mochiBirthday: adopted, calendar: _utc);
        expect(event?.name, s['event'], reason: 'event at ${s['at']}');
        if (event != null) {
          final last = SeasonCalendar.lastDay(event, at, settings: settings, mochiBirthday: adopted, calendar: _utc);
          expect(last == null ? null : _seconds(last), s['lastDay'], reason: 'last day from ${s['at']}');
          expect(SeasonCalendar.occasionKey(event, at, calendar: _utc), s['key']);
        }
      }
    });
  }

  test('occasion keys and years together', () {
    for (final row in (fixture['keys']! as List).cast<List<Object?>>()) {
      expect(SeasonCalendar.occasionKey(byName(SeasonalEvent.values, row[1]), _date(row[0]), calendar: _utc), row[2], reason: '$row');
    }
    for (final row in (fixture['years']! as List).cast<List<Object?>>()) {
      expect(SeasonCalendar.yearsSince(_date(row[0]), _date(row[1]), calendar: _utc), row[2], reason: '$row');
    }
  });

  group('the Mac app\'s holidays', () {
    test('costumes, treats, candles and names', () {
      expect(SeasonDecor.costume(SeasonalEvent.halloween), Accessory.witchHat);
      expect(SeasonDecor.costume(SeasonalEvent.christmas, Wearer.companion), Accessory.santaHat);
      expect(SeasonDecor.costume(SeasonalEvent.mochiBirthday), Accessory.partyHat);
      expect(SeasonDecor.costume(SeasonalEvent.diwali), Accessory.flowerCrown);
      expect(SeasonDecor.costume(SeasonalEvent.valentines), isNull);
      expect(SeasonDecor.costume(null), isNull);
      expect(TreatStyle.of(SeasonalEvent.halloween), TreatStyle.candy);
      expect(TreatStyle.of(SeasonalEvent.diwali), TreatStyle.laddoo);
      expect(TreatStyle.of(SeasonalEvent.christmas), TreatStyle.gingerbread);
      expect(TreatStyle.of(SeasonalEvent.userBirthday), TreatStyle.cakeSlice);
      expect(TreatStyle.of(SeasonalEvent.valentines), TreatStyle.heartCookie);
      expect(TreatStyle.of(SeasonalEvent.newYear), TreatStyle.cookie);
      final adopted = DateTime.utc(2024, 3, 2);
      expect(SeasonDecor.candles(SeasonalEvent.mochiBirthday, adopted: adopted, now: DateTime.utc(2027, 3, 2), calendar: _utc), 3);
      expect(SeasonDecor.candles(SeasonalEvent.mochiBirthday, adopted: adopted, now: DateTime.utc(2035, 3, 2), calendar: _utc), 5);
      expect(SeasonDecor.candles(SeasonalEvent.christmas, now: DateTime.utc(2027), calendar: _utc), 3);
      expect(SeasonalEvent.mochiBirthday.displayTitle('Mochi'), "Mochi's birthday");
      expect(SeasonalEvent.diwali.displayTitle('Mochi'), 'Diwali');
    });

    test('each occasion is greeted once, and its toast waits for the window', () {
      final tracker = SeasonTracker();
      const settings = SeasonalSettings();
      final halloween = DateTime.utc(2026, 10, 25, 9);
      expect(
        tracker.refresh(halloween, settings: settings, petName: 'Mochi', companionName: 'Patch', greet: false, calendar: _utc),
        isNull,
      );
      expect(tracker.event, SeasonalEvent.halloween);
      final hello = tracker.refresh(halloween, settings: settings, petName: 'Mochi', companionName: 'Patch', calendar: _utc);
      expect(hello?.line?.text, 'Trick or treat!');
      expect(hello?.pet, PetAnimation.excitedJump);
      expect(hello?.companion, CompanionAnimation.celebrate);
      expect(tracker.takePendingToast(windowVisible: false), isNull);
      expect(tracker.takePendingToast(windowVisible: true, decorating: true), isNull);
      expect(
        tracker.takePendingToast(windowVisible: true),
        const FeatureToast('Happy Halloween!', 'Mochi and Patch dressed up. Treats are candy this week.', seconds: 7),
      );
      expect(tracker.takePendingToast(windowVisible: true), isNull);
      expect(
        tracker.refresh(
          halloween.add(const Duration(days: 2)),
          settings: settings,
          petName: 'Mochi',
          companionName: 'Patch',
          calendar: _utc,
        ),
        isNull,
      );

      final saved = SeasonTracker.fromJson(tracker.toJson(now: halloween, calendar: _utc));
      expect(saved.greeted, {'halloween-2026'});
      expect(SeasonTracker(greeted: ['halloween-2023', 'diwali-2025']).toJson(now: halloween, calendar: _utc), {
        'greeted': ['diwali-2025'],
      });
      final newYear = SeasonTracker().refresh(
        DateTime.utc(2026, 12, 31, 20),
        settings: settings,
        petName: 'Mochi',
        companionName: 'Patch',
        calendar: _utc,
      );
      expect(newYear?.line?.text, 'Happy New Year!');
      final birthday = SeasonDecor.greeting(
        SeasonalEvent.mochiBirthday,
        petName: 'Mochi',
        companionName: 'Patch',
        adopted: DateTime.utc(2025, 11, 8),
        now: DateTime.utc(2027, 11, 8),
        calendar: _utc,
      );
      expect([birthday.title, birthday.detail], ['Happy Birthday, Mochi!', '2 years together today.']);
      expect(
        SeasonDecor.greeting(
          SeasonalEvent.newYear,
          petName: 'M',
          companionName: 'P',
          now: DateTime.utc(2026, 12, 31),
          calendar: _utc,
        ).detail,
        "Here's to 2027 together.",
      );
    });

    test('the settings line and the settings JSON', () {
      const settings = SeasonalSettings(birthdayMonth: 11, birthdayDay: 20);
      String day(DateTime d) => '${d.day}/${d.month}';
      expect(
        SeasonCalendar.statusLine(DateTime.utc(2026, 10, 30), settings: settings, petName: 'Mochi', formatDay: day, calendar: _utc),
        'Halloween until 1/11. Next: Diwali from 5/11.',
      );
      expect(
        SeasonCalendar.statusLine(
          DateTime.utc(2026, 11, 20, 8),
          settings: settings,
          adopted: DateTime.utc(2026, 1, 3),
          petName: 'Mochi',
          formatDay: day,
          calendar: _utc,
        ),
        "Your birthday today! Next: Christmas from 18/12. Mochi's birthday is 3/1, the day you met.",
      );
      expect(
        SeasonCalendar.statusLine(DateTime.utc(2026), settings: const SeasonalSettings(enabled: false), petName: 'Mochi', formatDay: day),
        'Decorations are off.',
      );
      expect(SeasonalSettings.fromJson(settings.toJson()), settings);
      expect(SeasonalSettings.fromJson({'decorateMenuBar': false}), const SeasonalSettings(decorateMenuBar: false));
    });
  });

  group('growing up (W12)', () {
    ProgressState progress({required int points, required int days, DateTime? met}) => ProgressState()
      ..affectionPoints = points
      ..interactionDays = [for (var i = 0; i < days; i++) '2027-01-${(i + 1).toString().padLeft(2, '0')}']
      ..firstMetAt = met;

    test('the first look introduces the kitten, later stages are celebrated once', () {
      final now = DateTime.utc(2027, 2, 1);
      final first = Growth.check(progress(points: 0, days: 0), now, lifeStages: true, seen: -1, petName: 'Mochi');
      expect(first.stage, LifeStage.kitten);
      expect(first.seen, 0);
      expect(first.moment?.toast, const FeatureToast('Meet kitten Mochi!', 'Mochi grows up as your friendship grows.', seconds: 8));
      expect(Growth.check(progress(points: 0, days: 0), now, lifeStages: true, seen: 0, petName: 'Mochi').moment, isNull);
      final young = Growth.check(progress(points: 45, days: 3), now, lifeStages: true, seen: 0, petName: 'Mochi');
      expect(young.stage, LifeStage.young);
      expect(young.seen, 1);
      expect(young.moment?.toast?.title, 'Mochi grew up!');
      expect(young.moment?.line?.text, 'Look how big I am!');
      expect(young.moment?.pet, PetAnimation.victory);
      final grown = Growth.check(progress(points: 200, days: 12), now, lifeStages: true, seen: 1, petName: 'Mochi');
      expect(grown.moment?.toast?.detail, 'Mochi is all grown up, and still your best friend.');
      final late = Growth.check(progress(points: 200, days: 12), now, lifeStages: true, seen: -1, petName: 'Mochi');
      expect([late.stage, late.seen, late.moment], [LifeStage.grownUp, 2, null], reason: 'an older friend is already at home');
      final off = Growth.check(progress(points: 0, days: 0), now, lifeStages: false, seen: -1, petName: 'Mochi');
      expect([off.stage, off.seen, off.moment], [LifeStage.grownUp, -1, null]);
    });
  });
}
