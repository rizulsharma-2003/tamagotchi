// Docs/SPRINT_2.md W23a: the agent's controller (the Mac's AgentController), against fakes for the `claude` process, the
// clock, the phones, the opener and the files: nothing runs and no timer exists while it's off; the interval, quiet hours
// and the briefing; what each "Tell me" setting gates; the Pending card, Done and the phones' done list; "what's pending?";
// the meeting nudge; the connections; that a stop ends a run; and that the log holds no subjects or senders.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/agent/agent_command.dart';
import 'package:mochi_desktop/src/core/agent/agent_controller.dart';
import 'package:mochi_desktop/src/core/agent/agent_settings.dart';
import 'package:mochi_desktop/src/core/claude_cli.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/json_store.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show AttentionLevel;
import 'package:mochi_link/mochi_link.dart';

import 'support/agent_fakes.dart';

class Rig {
  Rig({AgentSettings? settings, DateTime? now, bool installed = true, bool connectedAll = true}) : now = now ?? DateTime(2026, 11, 3, 10) {
    directory = Directory.systemTemp.createTempSync('agent_rig');
    notes = File('${directory.path}/needs-auth.json');
    this.settings = DesktopSettings(MemorySettingsDocument());
    if (settings != null) this.settings.agent = settings;
    this.installed = installed;
    controller = AgentController(
      settings: this.settings,
      store: store,
      runner: () => this.installed ? claude : null,
      phone: phone,
      say: (line, seconds) => said.add((line, seconds)),
      opener: opener,
      clock: () => this.now,
      zone: () => AgentZone('Test/Zone', this.now.timeZoneOffset),
      signInNotes: () => notes,
      log: log.add,
      lookingAtMochi: () => looking,
      petName: () => 'Mochi',
      // Real timers never fire inside these tests: ticks are called by hand.
      tickEvery: const Duration(hours: 5),
      firstTickAfter: const Duration(hours: 5),
    );
    if (!connectedAll) claude.probe = probeOutput(gmail: false, calendar: false, notion: false);
  }

  late final Directory directory;
  late final File notes;
  late final DesktopSettings settings;
  late final AgentController controller;
  late bool installed;
  DateTime now;
  bool looking = false;
  final AgentClaudeFake claude = AgentClaudeFake();
  final AgentPhoneFake phone = AgentPhoneFake();
  final OpenerFake opener = OpenerFake();
  final MemoryJsonStore store = MemoryJsonStore();
  final List<(String, int)> said = [];
  final List<String> log = [];

  void set(AgentSettings Function(AgentSettings) change) => settings.agent = change(settings.agent);

  void advance(Duration by) => now = now.add(by);

  Future<void> close() async {
    controller.dispose();
    settings.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

AgentSettings on({List<AgentSource>? watched}) => AgentSettings(enabled: true, watched: watched ?? AgentSource.values);

/// On, with no morning briefing in the way (the interval tests start at 10:00, inside its three hours).
AgentSettings onQuietly() => on().copyWith(briefingEnabled: false);

void main() {
  late Rig rig;
  tearDown(() => rig.close());

  group('Off', () {
    test('nothing runs, no timer exists, and the card says the agent is off', () async {
      rig = Rig();
      rig.controller.start();
      expect(rig.controller.ticking, isFalse);
      rig.controller.tick();
      expect(rig.claude.runs, isEmpty);
      expect(rig.phone.card?.enabled, isFalse);
      expect(rig.phone.card?.items, isEmpty);
      expect(rig.store.writes, 0, reason: 'nothing is saved before the agent has looked');
      // Everything that would start a run does nothing but say so.
      final outcome = await rig.controller.answer();
      expect((outcome.text, outcome.ok), ('Turn on Mochi\'s agent in Settings › Agent first.', false));
      expect(rig.claude.runs, isEmpty);
    });

    testWidgets('no timer: two hours pass and nothing happens; turning it on starts a light tick, off ends it', (tester) async {
      rig = Rig();
      final controller = AgentController(
        settings: rig.settings,
        store: rig.store,
        runner: () => rig.claude,
        phone: rig.phone,
        say: (line, seconds) {},
        clock: () => rig.now,
        zone: () => AgentZone.utc,
        firstTickAfter: const Duration(seconds: 10),
      );
      addTearDown(controller.dispose);
      controller.start();
      await tester.pump(const Duration(hours: 2));
      expect(controller.ticking, isFalse);
      expect(rig.claude.runs, isEmpty);
      rig.settings.agent = on();
      expect(controller.ticking, isTrue);
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      expect(rig.claude.probes, hasLength(1), reason: 'the first tick looks at the connections, then checks');
      expect(rig.claude.checks, hasLength(1));
      rig.settings.agent = on().copyWith(enabled: false);
      expect(controller.ticking, isFalse);
      final before = rig.claude.runs.length;
      await tester.pump(const Duration(hours: 3));
      expect(rig.claude.runs.length, before);
      expect(rig.phone.card?.enabled, isFalse);
    });

    test('a development run works with the agent off, and tells nobody', () async {
      rig = Rig();
      rig.controller.start();
      rig.claude.check = digestOutput(emails: [mail('a', reply: true)]);
      await rig.controller.debugRun('check');
      expect(rig.log, contains('agent: check ok, 1 mail, 0 event, 0 tasks'));
      expect(rig.said, isEmpty);
      expect(rig.controller.badge, isNull);
      expect(rig.phone.news, isEmpty);
      expect(rig.phone.card?.enabled, isFalse);
      expect(rig.phone.card?.items, isEmpty, reason: 'nothing of it reaches the phones');
      await rig.controller.debugRun('connections');
      expect(rig.log.last, 'agent: connections gmail=connected calendar=connected notion=connected');
      await rig.controller.debugRun('brief');
      expect(rig.log, contains('agent: brief ok, 1 mail, 0 event, 0 tasks'));
      expect(rig.phone.news, isEmpty);
    });
  });

  group('A check', () {
    test('runs claude exactly as the Mac does, tells what is new, and saves only what the Mac keeps', () async {
      rig = Rig(settings: on());
      rig.claude.check = digestOutput(
        headline: 'A new email',
        emails: [mail('t1', from: 'Figma <comments@email.figma.com>', reply: true)],
        events: [meeting('e1', DateTime(2026, 11, 3, 10, 40).toUtc(), link: 'https://meet.google.com/abc-defg-hij')],
      );
      rig.controller.start();
      await rig.controller.checkNow();
      expect(rig.claude.probes, hasLength(1), reason: 'connections first, once');
      expect(rig.claude.probes.single.arguments, AgentConnections.probeArguments);
      expect(rig.claude.probes.single.timeout, const Duration(seconds: 90));
      final run = rig.claude.checks.single;
      expect(run.arguments, AgentCommand.arguments(AgentSource.values));
      expect(run.timeout, const Duration(seconds: 180));
      expect(run.input, contains('is:unread in:inbox after:${DateTime(2026, 11, 3, 8).millisecondsSinceEpoch ~/ 1000}'), reason: 'two hours back the first time');
      expect(run.input, contains('Now: Tuesday 2026-11-03 10:00 (Test/Zone, UTC'));
      expect(rig.controller.lastResult, 'New email from Figma: Someone mentioned you (needs a reply) · and more');
      expect(rig.controller.lastError, isNull);
      expect(rig.said.single, ('New email from Figma: Someone mentioned you (needs a reply) · and more', 8));
      expect(rig.controller.badge, AttentionLevel.attention);
      expect(rig.phone.news, hasLength(1));
      final sent = rig.phone.news.single;
      expect((sent.title, sent.quietIfKnown), ('Mochi has news', true));
      expect(sent.body, contains('Figma: Someone mentioned you'));
      expect(sent.pending?.items.map((item) => item.id), ['event:e1', 'mail:t1']);
      expect(rig.phone.card?.enabled, isTrue);
      expect(rig.phone.card?.items.map((item) => item.id), ['event:e1', 'mail:t1']);
      expect(rig.phone.card?.items.first.link, 'https://meet.google.com/abc-defg-hij');
      expect(rig.phone.card?.lookedAt, isNotNull);
      final saved = rig.store.json! as Map;
      expect(saved.keys.toSet().difference({'seen', 'lastCheckAt', 'lastBriefingDay', 'notes', 'pending', 'pendingHeadline', 'done', 'markedRead'}), isEmpty);
      expect(saved['seen'], {'mail:t1': rig.now.millisecondsSinceEpoch / 1000, 'event:e1': rig.now.millisecondsSinceEpoch / 1000});
      expect(jsonEncode(saved), isNot(contains('is:unread')), reason: 'no mail body, and no prompt, is kept');
    });

    test('a second look finds nothing new and says nothing', () async {
      rig = Rig(settings: on());
      rig.claude.check = digestOutput(emails: [mail('t1', reply: true)]);
      rig.controller.start();
      await rig.controller.checkNow();
      rig.said.clear();
      rig.phone.news.clear();
      rig.advance(const Duration(minutes: 15));
      await rig.controller.checkNow();
      expect(rig.controller.lastResult, 'Nothing new');
      expect(rig.said, isEmpty);
      expect(rig.phone.news, isEmpty);
      expect(rig.claude.checks.last.input, contains('after:${rig.now.subtract(const Duration(minutes: 17)).millisecondsSinceEpoch ~/ 1000}'), reason: 'from a little before the last look');
    });

    test('only the connected, watched sources are asked', () async {
      rig = Rig(settings: on(watched: [AgentSource.gmail, AgentSource.notion]));
      rig.claude.probe = probeOutput(notion: false);
      rig.controller.start();
      await rig.controller.checkNow();
      expect(rig.claude.checks.single.arguments, AgentCommand.arguments([AgentSource.gmail]));
      expect(rig.claude.checks.single.input, contains('Notion is not part of this check'));
      expect(rig.controller.activeSources, [AgentSource.gmail]);
    });

    test('nothing connected: it says so, and does not run', () async {
      rig = Rig(settings: on(), connectedAll: false);
      rig.controller.start();
      await rig.controller.checkNow();
      expect(rig.claude.checks, isEmpty);
      expect(rig.controller.lastError, 'Connect Gmail, Google Calendar or Notion first.');
    });

    test('a run that times out is an error, tells nobody, and still counts as a look', () async {
      rig = Rig(settings: on());
      rig.controller.start();
      await rig.controller.refreshConnections();
      rig.claude.timedOut = true;
      await rig.controller.checkNow();
      expect(rig.controller.lastError, 'The check didn\'t finish in time.');
      expect(rig.said, isEmpty);
      expect(rig.phone.news, isEmpty);
      expect(rig.log.last, 'agent: check failed (timed out)');
      expect((rig.store.json! as Map)['lastCheckAt'], rig.now.millisecondsSinceEpoch / 1000, reason: 'it is not tried again every 20 seconds');
      expect(rig.controller.running, isFalse);
    });

    test('Claude’s own words explain a failed run', () async {
      rig = Rig(settings: on());
      rig.controller.start();
      await rig.controller.refreshConnections();
      rig.claude.check = '{"type":"result","is_error":true,"result":"Usage limit reached"}';
      await rig.controller.checkNow();
      expect(rig.controller.lastError, 'Usage limit reached');
      expect(rig.log.last, 'agent: check failed (claude reported a problem)', reason: 'its words stay out of the log');
    });

    test('claude is not installed', () async {
      rig = Rig(settings: on(), installed: false);
      rig.controller.start();
      await rig.controller.checkNow();
      expect(rig.controller.lastError, contains('isn\'t installed on this PC'));
      expect(rig.claude.runs, isEmpty);
    });

    test('one run at a time', () async {
      rig = Rig(settings: on());
      rig.controller.start();
      await rig.controller.refreshConnections();
      rig.claude.hold = Completer<ClaudeRun>();
      final first = rig.controller.checkNow();
      await Future<void>.delayed(Duration.zero);
      expect(rig.controller.running, isTrue);
      await rig.controller.checkNow();
      await rig.controller.briefNow();
      await rig.controller.refreshConnections();
      expect(rig.claude.checks, hasLength(1));
      expect(rig.claude.probes, hasLength(1));
      final outcome = await rig.controller.answer();
      expect(outcome.text, 'I\'m checking right now — give me a moment.');
      rig.claude.hold!.complete(ClaudeRun(exitCode: 0, output: digestOutput()));
      await first;
      expect(rig.controller.running, isFalse);
    });
  });

  group('Tell me', () {
    Future<void> check(Rig rig, {required List<Map<String, Object?>> emails, List<Map<String, Object?>> events = const []}) async {
      rig.claude.check = digestOutput(emails: emails, events: events);
      rig.controller.start();
      await rig.controller.checkNow();
    }

    test('each switch gates its own way of telling', () async {
      rig = Rig(settings: on().copyWith(tellInBubble: false, tellWithBadge: false, tellPhone: false));
      await check(rig, emails: [mail('a', reply: true)]);
      expect(rig.said, isEmpty);
      expect(rig.controller.badge, isNull);
      expect(rig.phone.news, isEmpty);
      expect(rig.controller.lastResult, isNotEmpty, reason: 'it is still listed in Settings');
      expect(rig.controller.notes, hasLength(1));
      await rig.close();

      rig = Rig(settings: on().copyWith(tellWithBadge: false, tellPhone: false));
      await check(rig, emails: [mail('a', reply: true)]);
      expect(rig.said, hasLength(1));
      expect(rig.controller.badge, isNull);
      expect(rig.phone.news, isEmpty);
      await rig.close();

      rig = Rig(settings: on().copyWith(tellInBubble: false, tellPhone: false));
      await check(rig, emails: [mail('a', reply: true)]);
      expect(rig.said, isEmpty);
      expect(rig.controller.badge, AttentionLevel.attention);
      await rig.close();

      rig = Rig(settings: on().copyWith(tellInBubble: false, tellWithBadge: false));
      await check(rig, emails: [mail('a', reply: true)]);
      expect(rig.said, isEmpty);
      expect(rig.phone.news, hasLength(1));
    });

    test('newsletters alone: spoken, but no badge, and off the phones unless allowed', () async {
      rig = Rig(settings: on());
      await check(rig, emails: [mail('a', urgency: 'low', from: 'Shop'), mail('b', urgency: 'low', from: 'News')]);
      expect(rig.said.single.$1, '2 new emails, nothing urgent');
      expect(rig.controller.badge, isNull);
      expect(rig.phone.news, isEmpty, reason: 'the low-priority skip');
      await rig.close();

      rig = Rig(settings: on().copyWith(phoneSkipsLowPriority: false));
      await check(rig, emails: [mail('a', urgency: 'low', from: 'Shop'), mail('b', urgency: 'low', from: 'News')]);
      expect(rig.phone.news, hasLength(1));
      expect(rig.phone.news.single.title, '2 new emails');
    });

    test('with VIPs only theirs rings; the rest waits on the card', () async {
      rig = Rig(settings: on().copyWith(vips: ['@insideedge.club']));
      await check(rig, emails: [mail('a', urgency: 'high', reply: true, address: 'x@y.com')]);
      expect(rig.controller.badge, isNull);
      expect(rig.phone.news, isEmpty);
      expect(rig.phone.card?.items.map((item) => item.id), ['mail:a'], reason: 'it is on the card');
      await rig.close();

      rig = Rig(settings: on().copyWith(vips: ['@insideedge.club']));
      await check(rig, emails: [mail('b', from: 'Amogh', address: 'amogh@insideedge.club')]);
      expect(rig.controller.badge, AttentionLevel.attention);
      expect(rig.phone.news, hasLength(1));
      expect(rig.phone.card?.items.single.vip, isTrue);
    });

    test('a nearer badge is never lowered by a quieter one', () async {
      rig = Rig(settings: on());
      await check(rig, emails: [mail('a', reply: true)]);
      expect(rig.controller.badge, AttentionLevel.attention);
      rig.claude.check = digestOutput(tasks: [
        {'id': 't', 'title': 'Ship'},
      ]);
      await rig.controller.checkNow();
      expect(rig.controller.badge, AttentionLevel.attention);
      rig.controller.acknowledge();
      expect(rig.controller.badge, isNull);
    });

    test('opening Mochi clears the dot at the next tick', () async {
      rig = Rig(settings: on());
      await check(rig, emails: [mail('a', reply: true)]);
      expect(rig.controller.badge, isNotNull);
      rig.looking = true;
      rig.controller.tick();
      expect(rig.controller.badge, isNull);
    });

    test('the morning briefing tells the day, once, to the phones as “Your day”', () async {
      rig = Rig(settings: on(), now: DateTime(2026, 11, 3, 9, 5));
      rig.claude.check = digestOutput(headline: 'Busy day: standup at 10', emails: [mail('a', reply: true)]);
      rig.controller.start();
      rig.controller.tick();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(rig.claude.checks.single.input, contains('newer_than:1d'));
      expect(rig.said.single, ('Busy day: standup at 10', 8));
      expect(rig.phone.news.single.title, 'Your day');
      expect(rig.phone.news.single.body, startsWith('Busy day: standup at 10\n'));
      expect(rig.phone.news.single.quietIfKnown, isFalse, reason: 'a briefing always rings');
      expect(rig.phone.card?.headline, 'Busy day: standup at 10');
      expect((rig.store.json! as Map)['lastBriefingDay'], '2026-11-03');
      // The day is done: a tick later checks instead.
      rig.advance(const Duration(minutes: 20));
      expect(rig.controller.running, isFalse);
      rig.controller.tick();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(rig.claude.checks.last.input, contains('is:unread in:inbox after:'));
    });

    test('Briefing Now in Settings tells the bubble but not the phones', () async {
      rig = Rig(settings: on());
      rig.claude.check = digestOutput(headline: 'Quiet day');
      rig.controller.start();
      await rig.controller.briefNow();
      expect(rig.said.single.$1, 'Quiet day');
      expect(rig.phone.news, isEmpty);
      expect((rig.store.json! as Map)['lastBriefingDay'], isNull, reason: 'only the morning one counts as the day’s');
    });
  });

  group('When to look', () {
    Future<void> tick(Rig rig) async {
      rig.controller.tick();
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('every interval, never in quiet hours', () async {
      rig = Rig(settings: onQuietly(), now: DateTime(2026, 11, 3, 10));
      rig.controller.start();
      await tick(rig);
      expect(rig.claude.checks, hasLength(1));
      rig.advance(const Duration(minutes: 10));
      await tick(rig);
      expect(rig.claude.checks, hasLength(1), reason: '15 minutes between looks');
      rig.advance(const Duration(minutes: 5));
      await tick(rig);
      expect(rig.claude.checks, hasLength(2));
      rig.now = DateTime(2026, 11, 3, 23, 30);
      await tick(rig);
      rig.now = DateTime(2026, 11, 4, 2);
      await tick(rig);
      expect(rig.claude.checks, hasLength(2), reason: 'quiet 23:00 to 08:00');
      rig.now = DateTime(2026, 11, 4, 8, 1);
      await tick(rig);
      expect(rig.claude.checks, hasLength(3), reason: 'quiet hours are over');
    });

    test('a longer interval waits longer, and quiet hours can be off', () async {
      rig = Rig(settings: onQuietly().copyWith(intervalMinutes: 60), now: DateTime(2026, 11, 3, 10));
      rig.controller.start();
      await tick(rig);
      rig.advance(const Duration(minutes: 30));
      await tick(rig);
      expect(rig.claude.checks, hasLength(1));
      rig.advance(const Duration(minutes: 30));
      await tick(rig);
      expect(rig.claude.checks, hasLength(2));
      rig.set((settings) => settings.copyWith(quietHours: settings.quietHours.copyWith(enabled: false)));
      rig.now = DateTime(2026, 11, 4, 3);
      await tick(rig);
      expect(rig.claude.checks, hasLength(3), reason: 'no quiet hours');
    });

    test('the briefing goes once, from its time, not before and not in quiet hours', () async {
      rig = Rig(settings: on(), now: DateTime(2026, 11, 3, 8, 30));
      rig.controller.start();
      await tick(rig);
      expect(rig.claude.checks.single.input, contains('after:'), reason: 'before 09:00 a check, not a briefing');
      rig.now = DateTime(2026, 11, 3, 9, 1);
      await tick(rig);
      expect(rig.claude.checks.last.input, contains('newer_than:1d'));
      final count = rig.claude.checks.length;
      rig.now = DateTime(2026, 11, 3, 9, 30);
      await tick(rig);
      expect(rig.claude.checks.length, count + 1);
      expect(rig.claude.checks.last.input, isNot(contains('newer_than:1d')), reason: 'briefed today');
      rig.set((settings) => settings.copyWith(briefingEnabled: false));
      rig.now = DateTime(2026, 11, 4, 9, 30);
      await tick(rig);
      expect(rig.claude.checks.last.input, isNot(contains('newer_than:1d')), reason: 'briefing off');
    });
  });

  group('Done, and the phones’ Pending card', () {
    Future<void> found(Rig rig) async {
      rig.claude.check = digestOutput(emails: [mail('t1', reply: true), mail('t2', from: 'Google', urgency: 'low')]);
      rig.controller.start();
      await rig.controller.checkNow();
    }

    test('Done takes a note off the card here and on the phones, and is shared as macDone', () async {
      rig = Rig(settings: on());
      await found(rig);
      expect(rig.phone.card?.items.map((item) => item.id), ['mail:t1', 'mail:t2']);
      final note = rig.controller.notes.firstWhere((each) => each.id == 'mail:t1');
      rig.controller.markDone(note);
      expect(rig.controller.isDone('mail:t1'), isTrue);
      expect(rig.phone.card?.items.map((item) => item.id), ['mail:t2']);
      expect(rig.phone.macDones.last.ids.keys, ['mail:t1']);
      // It never comes back: not from another check, not from a briefing.
      rig.advance(const Duration(minutes: 20));
      await rig.controller.briefNow();
      expect(rig.phone.card?.items.map((item) => item.id), ['mail:t2']);
      expect((rig.store.json! as Map)['done'], {'mail:t1': rig.now.subtract(const Duration(minutes: 20)).millisecondsSinceEpoch ~/ 1000});
      rig.controller.markDone(note);
      expect(rig.phone.macDones, hasLength(1), reason: 'once');
    });

    test('what a phone marked done is kept with ours: the union', () async {
      rig = Rig(settings: on());
      await found(rig);
      rig.controller.markDone(rig.controller.notes.firstWhere((each) => each.id == 'mail:t2'));
      rig.phone.macDones.clear();
      final t = rig.now.millisecondsSinceEpoch / 1000;
      rig.phone.phoneMarked({'mail:t1': t, 'mail:other': t});
      expect(rig.controller.isDone('mail:t1'), isTrue);
      expect(rig.controller.isDone('mail:t2'), isTrue);
      expect(rig.phone.card?.items, isEmpty);
      expect(rig.phone.macDones.last.ids.keys, unorderedEquals(['mail:t1', 'mail:t2', 'mail:other']), reason: 'the union goes back out as macDone');
      expect(rig.controller.badge, isNull, reason: 'an empty card has no dot');
    });

    test('a phone’s list that is old or already known changes nothing', () async {
      rig = Rig(settings: on());
      await found(rig);
      final writes = rig.store.writes;
      rig.phone.phoneMarked({'mail:t1': rig.now.millisecondsSinceEpoch / 1000 - 9 * 86400});
      expect(rig.store.writes, writes, reason: 'older than a week');
      expect(rig.controller.isDone('mail:t1'), isFalse);
    });

    test('the card is shared only while the agent is on with “On my phones”', () async {
      rig = Rig(settings: on());
      await found(rig);
      expect(rig.phone.card?.enabled, isTrue);
      rig.set((settings) => settings.copyWith(tellPhone: false));
      expect(rig.phone.card?.enabled, isFalse);
      expect(rig.phone.card?.items, isEmpty);
      expect(rig.phone.card?.headline, isNull);
      rig.set((settings) => settings.copyWith(tellPhone: true));
      expect(rig.phone.card?.items, isNotEmpty);
      rig.set((settings) => settings.copyWith(enabled: false));
      expect(rig.phone.card?.enabled, isFalse);
      expect(rig.phone.card?.items, isEmpty);
      expect(rig.controller.badge, isNull);
    });

    test('the card is published afresh when the link comes back, and not twice for the same thing', () async {
      rig = Rig(settings: on());
      await found(rig);
      final count = rig.phone.pendings.length;
      rig.controller.publishPending();
      rig.controller.publishPending(force: true);
      expect(rig.phone.pendings.length, count, reason: 'unchanged: not sent again');
      rig.phone.linkCameBack();
      expect(rig.phone.pendings.length, count + 1);
      expect(rig.phone.macDones, isNotEmpty);
    });

    test('forgetting starts over', () async {
      rig = Rig(settings: on());
      await found(rig);
      rig.controller.forgetNews();
      expect(rig.controller.notes, isEmpty);
      expect(rig.controller.badge, isNull);
      expect(rig.phone.card?.items, isEmpty);
      await rig.controller.checkNow();
      expect(rig.phone.card?.items, hasLength(2), reason: 'reported again');
    });
  });

  group('The meeting nudge', () {
    Future<Rig> withMeeting(DateTime start, {AgentSettings? settings, String? link}) async {
      final made = Rig(settings: settings ?? on(), now: DateTime(2026, 11, 3, 10));
      made.claude.check = digestOutput(events: [meeting('e1', start, link: link)]);
      made.controller.start();
      await made.controller.checkNow();
      made.said.clear();
      return made;
    }

    test('about ten minutes before, once, with the badge', () async {
      rig = await withMeeting(DateTime(2026, 11, 3, 10, 40), link: 'https://meet.google.com/abc-defg-hij');
      rig.advance(const Duration(minutes: 20));
      rig.controller.tick();
      expect(rig.said, isEmpty, reason: '20 minutes to go');
      rig.advance(const Duration(minutes: 10));
      rig.controller.tick();
      expect(rig.said.single, ('Standup in 10 minutes — the link\'s on the card', 10));
      expect(rig.controller.badge, AttentionLevel.attention);
      rig.advance(const Duration(minutes: 1));
      rig.controller.tick();
      expect(rig.said, hasLength(1), reason: 'once per meeting');
    });

    test('without a link it does not mention one, and a meeting that is too close or gone is not nudged', () async {
      rig = await withMeeting(DateTime(2026, 11, 3, 10, 30));
      rig.advance(const Duration(minutes: 22));
      rig.controller.tick();
      expect(rig.said.single.$1, 'Standup in 8 minutes');
      rig.said.clear();
      rig.advance(const Duration(minutes: 5));
      rig.controller.tick();
      expect(rig.said, isEmpty);
    });

    test('it needs the bubble on, and does not nudge for what is done', () async {
      rig = await withMeeting(DateTime(2026, 11, 3, 10, 40), settings: on().copyWith(tellInBubble: false));
      rig.advance(const Duration(minutes: 30));
      rig.controller.tick();
      expect(rig.said, isEmpty);
      await rig.close();
      rig = await withMeeting(DateTime(2026, 11, 3, 10, 40));
      rig.controller.markDone(rig.controller.notes.firstWhere((each) => each.id == 'event:e1'));
      rig.advance(const Duration(minutes: 30));
      rig.controller.tick();
      expect(rig.said, isEmpty);
    });
  });

  group('“What’s pending?”', () {
    test('says the headline and what else matters', () async {
      rig = Rig(settings: on());
      rig.claude.check = digestOutput(
        headline: 'A standup at 11 and one email',
        emails: [mail('a', reply: true)],
        events: [meeting('e', DateTime(2026, 11, 3, 11))],
      );
      rig.controller.start();
      final outcome = await rig.controller.answer();
      expect(outcome.ok, isTrue);
      expect(outcome.text, startsWith('A standup at 11 and one email. '));
      expect(outcome.text, contains('New email from Figma: Someone mentioned you (needs a reply)'));
      expect(rig.claude.checks.single.input, contains('newer_than:1d'), reason: 'always a fresh look, as on the Mac');
      expect(rig.phone.news, isEmpty, reason: 'asked, not told');
      expect(rig.said, isEmpty);
    });

    test('when it cannot look it says why', () async {
      rig = Rig(settings: on());
      rig.controller.start();
      await rig.controller.refreshConnections();
      rig.claude.timedOut = true;
      final outcome = await rig.controller.answer();
      expect((outcome.text, outcome.ok), ('The check didn\'t finish in time.', false));
    });
  });

  group('Connections', () {
    test('Check Connections reads each state and logs only the states', () async {
      rig = Rig();
      rig.claude.probe = probeOutput(notion: false);
      rig.notes.writeAsStringSync(jsonEncode({'claude.ai Notion': {'timestamp': 1}, 'claude.ai Slack': {'timestamp': 2}}));
      await rig.controller.refreshConnections(forgetNotes: true);
      expect(rig.controller.connections[AgentSource.gmail], AgentConnection.connected);
      expect(rig.controller.connections[AgentSource.notion], AgentConnection.unavailable);
      expect(rig.log.single, 'agent: connections gmail=connected calendar=connected notion=unavailable');
      expect((jsonDecode(rig.notes.readAsStringSync()) as Map).keys, ['claude.ai Slack'], reason: 'only the stale sign-in note went');
      expect(rig.controller.checkingConnections, isFalse);
    });

    test('a probe answered in words, not the form, is asked once more (the Windows VM, with no connectors)', () async {
      rig = Rig();
      const words = '{"type":"result","subtype":"success","is_error":false,"result":"I have no tool search tool, so I can\'t tell."}';
      rig.claude.probesFirst.add(words);
      rig.claude.probe = probeOutput(gmail: false, calendar: false, notion: false);
      await rig.controller.refreshConnections();
      expect(rig.claude.probes, hasLength(2));
      expect(rig.controller.connections[AgentSource.gmail], AgentConnection.unavailable);
      expect(rig.log, ['agent: connections answered without the form, asking again', 'agent: connections gmail=unavailable calendar=unavailable notion=unavailable']);
      // Only once: two answers in words are a failure, as before.
      rig.claude.probesFirst.addAll([words, words]);
      await rig.controller.refreshConnections();
      expect(rig.claude.probes, hasLength(4));
      expect(rig.log.last, 'agent: connections failed');
    });

    test('a probe that fails explains itself', () async {
      rig = Rig();
      rig.claude.probe = '{"type":"result","is_error":true,"result":"Not logged in"}';
      await rig.controller.refreshConnections();
      expect(rig.controller.lastError, 'Not logged in');
      expect(rig.controller.connections, isEmpty);
      rig.claude.timedOut = true;
      await rig.controller.refreshConnections();
      expect(rig.controller.lastError, 'Checking the connections took too long.');
    });

    test('Connect… opens Claude’s connectors page and forgets the stale note; the agent then watches until all are in', () async {
      rig = Rig(settings: on(), connectedAll: false);
      rig.notes.writeAsStringSync(jsonEncode({'claude.ai Gmail': {'timestamp': 1}}));
      rig.controller.start();
      await rig.controller.connect();
      expect(rig.opener.opened, [Uri.parse('https://claude.ai/customize/connectors')]);
      expect(jsonDecode(rig.notes.readAsStringSync()), isEmpty);
      rig.controller.tick();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(rig.claude.probes, hasLength(1), reason: 'looks while the user is away');
      rig.advance(const Duration(seconds: 10));
      rig.controller.tick();
      await Future<void>.delayed(Duration.zero);
      expect(rig.claude.probes, hasLength(1), reason: 'not more often than every 20 seconds');
      rig.claude.probe = probeOutput();
      rig.advance(const Duration(seconds: 30));
      rig.controller.tick();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(rig.claude.probes, hasLength(2));
      expect(rig.controller.connections.values.every((state) => state == AgentConnection.connected), isTrue);
      rig.advance(const Duration(minutes: 1));
      rig.controller.tick();
      await Future<void>.delayed(Duration.zero);
      expect(rig.claude.probes, hasLength(2), reason: 'all connected: it stops looking');
    });

    test('with the agent off, Connect… only opens the page: nothing watches', () async {
      rig = Rig(connectedAll: false);
      rig.controller.start();
      await rig.controller.connect();
      expect(rig.opener.opened, hasLength(1));
      rig.controller.tick();
      expect(rig.claude.runs, isEmpty);
    });
  });

  group('Stopping', () {
    test('turning the agent off ends the run in progress, quietly', () async {
      rig = Rig(settings: on());
      rig.controller.start();
      await rig.controller.refreshConnections();
      rig.claude.hold = Completer<ClaudeRun>();
      final running = rig.controller.checkNow();
      await Future<void>.delayed(Duration.zero);
      expect(rig.controller.running, isTrue);
      rig.set((settings) => settings.copyWith(enabled: false));
      expect(rig.claude.stops, 1);
      await running;
      expect(rig.controller.running, isFalse);
      expect(rig.controller.lastError, isNull, reason: 'a run the user ended is not an error');
      expect(rig.said, isEmpty);
      expect(rig.phone.news, isEmpty);
    });

    test('quitting stops it too, and nothing starts afterwards', () async {
      rig = Rig(settings: on());
      rig.controller.start();
      await rig.controller.refreshConnections();
      rig.claude.hold = Completer<ClaudeRun>();
      final running = rig.controller.checkNow();
      await Future<void>.delayed(Duration.zero);
      rig.controller.stop();
      expect(rig.claude.stops, 1);
      await running;
      expect(rig.controller.ticking, isFalse);
    });
  });

  group('Privacy', () {
    test('the log holds counts and outcomes only: no subject, sender, title, gist, link or task', () async {
      rig = Rig(settings: on());
      rig.claude.check = digestOutput(
        headline: 'HEADLINE-SECRET',
        emails: [mail('THREADID', from: 'SENDER-SECRET <sender-secret@example.com>', subject: 'SUBJECT-SECRET', gist: 'GIST-SECRET', reply: true)],
        events: [meeting('EVENTID', DateTime(2026, 11, 3, 10, 40), title: 'MEETING-SECRET', link: 'https://zoom.us/j/LINK-SECRET', where: 'PLACE-SECRET')],
        tasks: [
          {'id': 'TASKID', 'title': 'TASK-SECRET', 'url': 'https://notion.so/URL-SECRET'},
        ],
      );
      rig.controller.start();
      await rig.controller.debugRun('connections');
      await rig.controller.checkNow();
      await rig.controller.briefNow();
      rig.advance(const Duration(minutes: 31));
      rig.controller.tick();
      await rig.controller.answer();
      rig.claude.timedOut = true;
      await rig.controller.checkNow();
      rig.claude.timedOut = false;
      rig.claude.check = '{"type":"result","is_error":true,"result":"SENDER-SECRET said no"}';
      await rig.controller.checkNow();
      final everything = rig.log.join('\n');
      for (final secret in ['SECRET', 'THREADID', 'EVENTID', 'TASKID', 'example.com', 'zoom.us', 'notion.so']) {
        expect(everything, isNot(contains(secret)), reason: secret);
      }
      expect(rig.log, isNotEmpty);
      for (final line in rig.log) {
        expect(
          line,
          matches(RegExp(r'^agent: (connections (\w+=\w+ ?)+|(check|brief) (ok, \d+ mail, \d+ event, \d+ tasks|failed \([a-z ]+\)|skipped, [a-z ]+))$')),
          reason: line,
        );
      }
    });

    test('what is kept is what the Mac keeps, and nothing of the prompt or the body', () async {
      rig = Rig(settings: on());
      rig.claude.check = digestOutput(emails: [mail('t1', gist: 'a gist', subject: 'a subject', reply: true)]);
      rig.controller.start();
      await rig.controller.checkNow();
      final text = jsonEncode(rig.store.json);
      expect(text, contains('a subject'));
      expect(text, isNot(contains('Read only')));
      expect(text, isNot(contains('structured_output')));
      expect(text, isNot(contains('needs_reply')));
    });
  });
}
