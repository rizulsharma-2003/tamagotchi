// W16: the daily recap against the Swift engine (link-spec/world/recap.json), plus the Mac app's recap rules (the
// event journal it counts from, the history start, the evening announcement and the card's words).

import 'dart:convert';

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

DateTime _date(Object? seconds) => DateTime.fromMicrosecondsSinceEpoch(((seconds! as num) * 1e6).round(), isUtc: true);

CompanionEvent _normalize(Map<String, Object?> step) {
  final wire = obj(step['wire']);
  return EventNormalizer.normalize(
    wire,
    receivedAt: _date(wire['ts']),
    delivery: byName(EventDelivery.values, step['delivery'] ?? 'live'),
  )!;
}

const _utc = WorldCalendar.utc();

void main() {
  final fixture = readWorldFixture('recap.json');

  for (final c in cases(fixture)) {
    test('recap: ${c['note']}', () {
      final events = objs(c['events']).map(_normalize).toList();
      final focus = [
        for (final b in (c['focus'] as List? ?? const []).cast<List<Object?>>())
          FocusBlock(endedAt: _date(b[0]), minutes: (b[1]! as num).toDouble()),
      ];
      final recap = DailyRecap.compute(
        day: _date(c['day']),
        events: events,
        focus: focus,
        historyStart: _date(c['historyStart']),
        calendar: _utc,
      );
      expect(diffJson(recap.toJson(), c['recap']), isEmpty);
      expect(recap.hasActivity, c['hasActivity']);
      expect(recap.isQuiet, c['isQuiet']);
      expect(diffJson(recap.activeSpan, c['activeSpan']), isEmpty);
      expect(diffJson(recap.tiles.map((t) => t.toJson()).toList(), c['tiles']), isEmpty);
      expect(recap.summary(petName: 'Mochi', companionName: 'Patch'), c['summary']);
      expect(recap.readyBanner(petName: 'Mochi', companionName: 'Patch').body, c['banner']);
    });
  }

  test('the evening announcement is due once per active day, from the hour', () {
    final day = DateTime.utc(2027, 1, 15);
    for (final row in (fixture['announce']! as List).cast<List<Object?>>()) {
      final settings = RecapSettings(announce: row[0]! as bool, hour: row[1]! as int, lastAnnouncedDay: row[2] as String?);
      final due = StringBuffer();
      for (final hour in [0.5, 17.99, 18.0, 22.5, 23.5]) {
        for (final activity in [true, false]) {
          final now = day.add(Duration(microseconds: (hour * 3600 * 1e6).round()));
          due.write(settings.isAnnouncementDue(now, hasActivity: activity, calendar: _utc) ? '1' : '0');
        }
      }
      expect(due.toString(), row[3], reason: '$row');
    }
    for (final row in (fixture['decoded']! as List).cast<List<Object?>>()) {
      final settings = RecapSettings.fromJson(jsonDecode(row[0]! as String));
      expect([settings.announce, settings.hour, settings.banner], row.sublist(1), reason: '${row[0]}');
    }
  });

  test('day names, day keys and tool titles', () {
    for (final row in (fixture['dayNames']! as List).cast<List<Object?>>()) {
      expect(
        DailyRecap.dayName(_date(row[0]), now: _date(row[1]), calendar: _utc),
        row[2],
        reason: '$row',
      );
    }
    for (final row in (fixture['dayKeys']! as List).cast<List<Object?>>()) {
      expect(DailyRecap.dayKey(_date(row[0]), calendar: _utc), row[1]);
    }
    for (final row in (fixture['recapTitles']! as List).cast<List<Object?>>()) {
      expect(byName(ToolCategory.values, row[0]).recapTitle, row[1]);
    }
  });

  group('the Mac app\'s recap', () {
    final day = DateTime.utc(2027, 1, 15);
    CompanionEvent event(String name, DateTime at, {String id = '', String session = 's1', String origin = 'hook'}) =>
        EventNormalizer.normalize({
          'v': 1,
          'id': id.isEmpty ? 'e${at.microsecondsSinceEpoch}' : id,
          'ts': at.microsecondsSinceEpoch / 1e6,
          'origin': origin,
          'event': name,
          'session': session,
          'project': 'InsideEdge',
          'projectKey': 'k1',
        }, receivedAt: at)!;

    test('the journal keeps a week of real events, from onRecord, and knows where its history starts', () {
      final journal = EventJournal();
      final now = day.add(const Duration(hours: 20));
      expect(journal.append(event('Stop', day.add(const Duration(hours: 9))), now: now), isTrue);
      expect(journal.append(event('Stop', day.add(const Duration(hours: 9))), now: now), isFalse, reason: 'a duplicate');
      expect(journal.append(event('Stop', day.add(const Duration(hours: 10)), origin: 'simulator'), now: now), isFalse);
      journal.append(event('Stop', day.subtract(const Duration(days: 9))), now: now);
      expect(journal.all, hasLength(2));
      // History starts at the oldest event's day, or a week ago, whichever is later.
      expect(journal.historyStart(now: now, launchedAt: now, calendar: _utc), now.subtract(const Duration(days: 7)));
      journal.enforceRetention(now);
      expect(journal.all, hasLength(1));
      expect(journal.historyStart(now: now, launchedAt: now, calendar: _utc), day);

      final saved = EventJournal()..load(journal.toJsonLines(), now: now);
      expect(saved.all.map((e) => e.id), journal.all.map((e) => e.id));

      final off = EventJournal(retentionDays: 0);
      off.append(event('Stop', day.add(const Duration(hours: 9))), now: now);
      expect(off.isOff, isTrue);
      expect(
        off.historyStart(now: now, launchedAt: day.add(const Duration(hours: 12)), calendar: _utc),
        day.add(const Duration(hours: 12)),
      );

      final capped = EventJournal(maxEvents: 3);
      for (var i = 0; i < 3; i++) {
        capped.append(event('Stop', day.add(Duration(hours: 9 + i))), now: now);
      }
      expect(
        capped.historyStart(now: now, launchedAt: now, calendar: _utc),
        day.add(const Duration(hours: 9)),
        reason: 'at the size cap',
      );
    });

    test('a world\'s onRecord feeds the journal; the recap counts it', () {
      var clock = day.add(const Duration(hours: 9));
      final journal = EventJournal();
      final world = MochiWorld(
        seed: 5,
        clock: () => clock,
        uptime: () => 10,
        calendar: _utc,
        onRecord: (e) => journal.append(e, now: clock),
      );
      world.ingestWire({
        'v': 1,
        'id': 'a',
        'ts': clock.microsecondsSinceEpoch / 1e6,
        'origin': 'hook',
        'event': 'SessionStart',
        'session': 's1',
      });
      clock = clock.add(const Duration(minutes: 30));
      world.ingestWire({'v': 1, 'id': 'b', 'ts': clock.microsecondsSinceEpoch / 1e6, 'origin': 'hook', 'event': 'Stop', 'session': 's1'});
      world.ingestWire({
        'v': 1,
        'id': 'c',
        'ts': clock.microsecondsSinceEpoch / 1e6,
        'origin': 'simulator',
        'event': 'Stop',
        'session': 'x',
      });
      final recap = DailyRecap.compute(
        day: clock,
        events: journal.all,
        historyStart: journal.historyStart(now: clock, launchedAt: clock, calendar: _utc),
        calendar: _utc,
      );
      expect(recap.turnsFinished, 1);
      expect(recap.sessions, 1);
      expect(recap.streak, 1);
      expect(recap.tiles.whereType<RecapActiveSpan>().single.detail, '30 min');
    });

    test('the schedule announces once, from 18:00, only after real activity', () {
      final settings = RecapSettings();
      final busy = DailyRecap(day: day, coverage: const RecapCoverageFull())
        ..turnsFinished = 2
        ..sessions = 1
        ..firstActivity = day.add(const Duration(hours: 9));
      final quiet = DailyRecap(day: day, coverage: const RecapCoverageFull());
      const world = WorldSettings();
      var computed = 0;
      DailyRecap busyRecap() {
        computed += 1;
        return busy;
      }

      expect(
        RecapSchedule.check(now: day.add(const Duration(hours: 17)), settings: settings, recapFor: busyRecap, world: world, calendar: _utc),
        isNull,
      );
      expect(computed, 0, reason: 'nothing is computed before the hour');
      expect(
        RecapSchedule.check(
          now: day.add(const Duration(hours: 18)),
          settings: settings,
          recapFor: () => quiet,
          world: world,
          calendar: _utc,
        ),
        isNull,
      );
      final moment = RecapSchedule.check(
        now: day.add(const Duration(hours: 18)),
        settings: settings,
        recapFor: busyRecap,
        world: world,
        calendar: _utc,
        where: 'Open Recap from the tray.',
      );
      expect(
        moment?.toast,
        const FeatureToast('Your day with Claude is ready', 'Mochi & Patch made you a recap card. Open Recap from the tray.', seconds: 10),
      );
      expect(moment?.line, const FeatureLine('Your day with Claude is ready! Want to see?', duration: 6));
      expect(moment?.pet, PetAnimation.greet);
      expect(moment?.companion, CompanionAnimation.greet);
      expect(moment?.banner, isNull, reason: 'banners are opt-in');
      expect(settings.lastAnnouncedDay, '2027-01-15');
      expect(
        RecapSchedule.check(now: day.add(const Duration(hours: 19)), settings: settings, recapFor: busyRecap, world: world, calendar: _utc),
        isNull,
      );
      final withBanner = RecapSettings(banner: true);
      final noPatch = RecapSchedule.check(
        now: day.add(const Duration(hours: 20)),
        settings: withBanner,
        recapFor: busyRecap,
        world: const WorldSettings(companionVisibility: CompanionVisibility.never),
        calendar: _utc,
      );
      expect(noPatch?.toast?.detail, startsWith('Mochi made you a recap card.'));
      expect(noPatch?.banner?.body, 'Mochi & Patch made you a recap card. 2 turns finished · 1 session.');
      expect(RecapSettings.fromJson(withBanner.toJson()).toJson(), withBanner.toJson());
    });

    test('the card\'s words', () {
      final now = day.add(const Duration(hours: 20));
      final recap = DailyRecap(day: day, coverage: RecapCoveragePartial(day.add(const Duration(hours: 8))))
        ..turnsFinished = 1
        ..firstActivity = day.add(const Duration(hours: 9))
        ..lastActivity = day.add(const Duration(hours: 11, minutes: 5))
        ..streak = 4
        ..streakIsLowerBound = true;
      expect(recap.title(now: now, petName: 'Mochi', companionName: 'Patch', calendar: _utc), 'Today with Mochi & Patch');
      expect(recap.streakText, 'At least 4 days in a row');
      expect(recap.footer(computer: 'PC', formatTime: (d) => '${d.hour}:00'), 'History starts at 8:00 this day · real events only');
      expect(recap.tiles.whereType<RecapActiveSpan>().single.detail, '2 h 5 min');
      expect(const RecapTurns(1).label, 'turn finished');
      expect(const RecapBuildsAndTests(builds: 2, tests: 1).detail, '2 builds · 1 test run');
      expect(const RecapFocus(minutes: 50, blocks: 1).value, '50 min');
      final quiet = DailyRecap(day: day.subtract(const Duration(days: 3)), coverage: const RecapCoverageNone());
      expect(
        quiet.title(now: now, petName: 'Mochi', companionName: 'Patch', showCompanion: false, calendar: _utc),
        'A quiet Tuesday with Mochi',
      );
      expect(quiet.quietMessage(now: now, computer: 'PC', calendar: _utc), 'This day is older than the history kept on this PC.');
      expect(quiet.streakText, isNull);
      final today = DailyRecap(day: day, coverage: const RecapCoverageFull());
      expect(today.quietMessage(now: now, calendar: _utc), 'No Claude Code sessions yet today.\nRest days count too.');
      expect(today.footer(computer: 'PC', formatTime: (d) => ''), 'From real Claude Code events on this PC');
    });
  });
}
