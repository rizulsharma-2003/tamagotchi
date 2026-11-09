// Docs/SPRINT_2.md W23a: Mochi's agent, the core (the Mac's Tests/TamagotchiCoreTests/AgentTests.swift ported):
// settings, the `claude -p` command and environment, the prompts, the digest, the connections probe, what Mochi tells
// and remembers, VIPs, sender names, and when to look.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/agent/agent_command.dart';
import 'package:mochi_desktop/src/core/agent/agent_news.dart';
import 'package:mochi_desktop/src/core/agent/agent_settings.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show AttentionLevel;
import 'package:mochi_link/mochi_link.dart';

/// A local wall-clock time (the schedule reads the PC's own).
DateTime at(int hour, [int minute = 0, int day = 3]) => DateTime(2026, 11, day, hour, minute);

AgentDigest sampleDigest() => const AgentDigest(
  headline: 'News',
  emails: [
    AgentEmail(id: 'a', from: 'CleverTap', subject: 'Maintenance', gist: 'Maintenance tomorrow night', urgency: 'low'),
    AgentEmail(id: 'b', from: 'Figma', subject: 'Mention', gist: 'Someone mentioned you', needsReply: true),
  ],
  events: [AgentEvent(id: 'e', title: 'Standup', start: '2026-11-03T10:00:00Z')],
  tasks: [AgentTask(id: 't', title: 'Ship v5', due: '2026-11-03')],
);

AgentNote note(String id, AgentSource source, {bool important = false, required double at, double? due}) =>
    AgentNote(id: id, source: source, title: id, detail: '', important: important, at: at, due: due);

String result({String headline = 'h', List<Object?> emails = const [], List<Object?> events = const [], List<Object?> tasks = const []}) => jsonEncode({
  'type': 'result',
  'is_error': false,
  'structured_output': {'headline': headline, 'emails': emails, 'events': events, 'tasks': tasks},
});

void main() {
  group('Settings', () {
    test('off by default, with the Mac’s defaults', () {
      const settings = AgentSettings();
      expect(settings.enabled, isFalse);
      expect(settings.watched, AgentSource.values);
      expect(settings.intervalMinutes, 15);
      expect((settings.quietHours.enabled, settings.quietHours.startMinute, settings.quietHours.endMinute), (true, 23 * 60, 8 * 60));
      expect((settings.briefingEnabled, settings.briefingMinute), (true, 9 * 60));
      expect((settings.tellInBubble, settings.tellWithBadge, settings.tellPhone, settings.phoneSkipsLowPriority), (true, true, true, true));
      expect(settings.cloudFireURL, '');
      expect(settings.vips, isEmpty);
      expect(settings.markReadWhenDone, isTrue);
    });

    test('decode tolerantly', () {
      final settings = AgentSettings.fromJson({
        'enabled': true,
        'watched': ['gmail', 'fax', 'notion'],
        'intervalMinutes': 2,
        'briefingMinute': 1500,
      });
      expect(settings.enabled, isTrue);
      expect(settings.watched, [AgentSource.gmail, AgentSource.notion]);
      expect(settings.intervalMinutes, 5);
      expect(settings.briefingMinute, 60);
      expect(settings.tellPhone, isTrue);
      expect(AgentSettings.fromJson(const {}), const AgentSettings());
      expect(AgentSettings.fromJson('nonsense'), const AgentSettings());
      expect(AgentSettings.fromJson({'enabled': 'yes', 'watched': 3, 'vips': [1], 'quietHours': 'x'}), const AgentSettings());
      expect(AgentSettings.fromJson({'vips': [' Amogh ', '', '  ']}).vips, ['Amogh']);
    });

    test('round-trip, including the two kept for W23b', () {
      final settings = const AgentSettings().copyWith(
        enabled: true,
        vips: ['Amogh'],
        markReadWhenDone: false,
        cloudFireURL: 'https://api.anthropic.com/v1/claude_code/routines/x/fire',
      );
      expect(AgentSettings.fromJson(jsonDecode(jsonEncode(settings.toJson()))), settings);
    });

    test('the app’s settings without an agent keep the defaults, and save the agent', () {
      final document = MemorySettingsDocument({'v': DesktopSettings.version, 'petName': 'Moo'});
      final settings = DesktopSettings(document);
      expect(settings.agent, const AgentSettings());
      expect(settings.agent.enabled, isFalse);
      settings.agent = settings.agent.copyWith(enabled: true, intervalMinutes: 30);
      final reopened = DesktopSettings(MemorySettingsDocument(jsonDecode(jsonEncode(document.read())) as Map<String, Object?>));
      expect((reopened.agent.enabled, reopened.agent.intervalMinutes), (true, 30));
      reopened.reset();
      expect(reopened.agent.enabled, isFalse);
    });

    test('watching keeps the usual order', () {
      var settings = const AgentSettings().watching(AgentSource.gmail, false);
      expect(settings.watched, [AgentSource.calendar, AgentSource.notion]);
      settings = settings.watching(AgentSource.gmail, true);
      expect(settings.watched, AgentSource.values);
    });
  });

  group('The Claude run', () {
    test('only read tools are allowed, and exactly the Mac’s', () {
      final arguments = AgentCommand.arguments(AgentSource.values);
      expect(arguments, [
        '-p',
        '--model',
        'haiku',
        '--output-format',
        'json',
        '--setting-sources',
        'project',
        '--no-session-persistence',
        '--permission-mode',
        'dontAsk',
        '--tools',
        'ToolSearch',
        '--allowedTools',
        'ToolSearch',
        'mcp__claude_ai_Gmail__search_threads',
        'mcp__claude_ai_Gmail__get_thread',
        'mcp__claude_ai_Gmail__get_message',
        'mcp__claude_ai_Gmail__list_labels',
        'mcp__claude_ai_Google_Calendar__list_events',
        'mcp__claude_ai_Google_Calendar__get_event',
        'mcp__claude_ai_Google_Calendar__search_events',
        'mcp__claude_ai_Google_Calendar__list_calendars',
        'mcp__claude_ai_Notion__notion-search',
        'mcp__claude_ai_Notion__notion-fetch',
        'mcp__claude_ai_Notion__notion-get-self',
        'mcp__claude_ai_Notion__notion-query-data-sources',
        '--json-schema',
        AgentCommand.schema,
      ]);
      for (final tool in [
        'send_message',
        'reply',
        'forward',
        'create_draft',
        'trash_thread',
        'unlabel_thread',
        'create_event',
        'delete_event',
        'notion-update-page',
        'notion-delete-pages',
        'notion-create-pages',
      ]) {
        expect(arguments.any((argument) => argument.endsWith('__$tool')), isFalse, reason: '$tool must never be allowed');
      }
      final gmailOnly = AgentCommand.arguments([AgentSource.gmail]);
      expect(gmailOnly.any((argument) => argument.contains('Notion') || argument.contains('Calendar')), isFalse);
      expect(gmailOnly, containsAll(['--setting-sources', '--no-session-persistence']));
      expect(() => jsonDecode(AgentCommand.schema), returnsNormally);
    });

    test('runs on the subscription, never an API key, and waits for the connectors', () {
      final environment = AgentCommand.environment({
        'ANTHROPIC_API_KEY': 'sk-test',
        'ANTHROPIC_AUTH_TOKEN': 't',
        'ANTHROPIC_BASE_URL': 'https://example.com',
        'CLAUDE_CODE_USE_BEDROCK': '1',
        'CLAUDE_CODE_USE_VERTEX': '1',
        'PATH': r'C:\Windows',
        'MCP_CONNECTION_NONBLOCKING': 'true',
      });
      expect(environment['MCP_CONNECTION_NONBLOCKING'], 'false', reason: 'connectors must be ready before the model looks');
      expect(environment['ENABLE_CLAUDEAI_MCP_SERVERS'], 'true');
      for (final key in ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX']) {
        expect(environment.containsKey(key), isFalse, reason: key);
      }
      expect(environment['PATH'], r'C:\Windows');
    });

    test('a check asks for mail since the last look, in the PC’s time zone', () {
      final now = DateTime.utc(2026, 11, 3, 9, 30);
      final since = DateTime.utc(2026, 11, 3, 9, 13);
      final prompt = AgentCommand.prompt(mode: AgentCheck(since), sources: [AgentSource.gmail, AgentSource.calendar], now: now);
      expect(prompt, contains('is:unread in:inbox after:${since.millisecondsSinceEpoch ~/ 1000}'));
      expect(prompt, contains('until 2026-11-03T11:00:00Z'));
      expect(prompt, contains('Now: Tuesday 2026-11-03 09:30 (UTC, UTC+00:00).'));
      expect(prompt, contains('Notion is not part of this check'));
      expect(prompt, contains('Read only'));
      const india = AgentZone('Asia/Kolkata', Duration(hours: 5, minutes: 30));
      final local = AgentCommand.prompt(mode: AgentCheck(since), sources: AgentSource.values, now: now, zone: india);
      expect(local, contains('Now: Tuesday 2026-11-03 15:00 (Asia/Kolkata, UTC+05:30).'));
      expect(local, contains('until 2026-11-03T16:30:00+05:30'));
      expect(local, contains('due today or overdue'));
    });

    test('a briefing covers the whole day', () {
      final prompt = AgentCommand.prompt(mode: const AgentBriefing(), sources: AgentSource.values, now: DateTime.utc(2026, 11, 3, 9));
      expect(prompt, contains('newer_than:1d'));
      expect(prompt, contains('until 2026-11-03T23:59:59Z'));
      expect(prompt, contains('within the next 2 days'));
      const india = AgentZone('Asia/Kolkata', Duration(hours: 5, minutes: 30));
      // 22:00 UTC is already tomorrow morning in India: its day ends at the end of the 4th.
      final late = AgentCommand.prompt(mode: const AgentBriefing(), sources: [AgentSource.calendar], now: DateTime.utc(2026, 11, 3, 22), zone: india);
      expect(late, contains('until 2026-11-04T23:59:59+05:30'));
    });

    test('reads the digest from Claude’s output', () {
      final output = result(
        headline: '2 new emails',
        emails: [
          {'id': 't1', 'from': 'Figma', 'subject': 'Mention', 'gist': 'Someone mentioned you', 'urgency': 'normal', 'needs_reply': true},
          {'id': '', 'from': 'x', 'subject': 'y', 'gist': 'z', 'urgency': 'low', 'needs_reply': false},
          {'id': 't2', 'from': 'Shop', 'subject': 'Sale', 'gist': '50% off', 'urgency': 'weird', 'needs_reply': false},
        ],
        events: [
          {'id': 'e1', 'title': 'Standup', 'start': '2026-11-03T10:00:00Z', 'where': 'Zoom'},
        ],
      );
      final digest = AgentDigest.parse(output)!;
      expect(digest.headline, '2 new emails');
      expect(digest.emails.map((email) => email.id), ['t1', 't2']);
      expect(digest.emails[0].needsReply, isTrue);
      expect(digest.emails[1].urgency, 'normal');
      expect(digest.events.first.place, 'Zoom');
      expect(AgentDigest.failure(output), isNull);
      // A list of events, as some versions print: the last result counts.
      expect(AgentDigest.parse('[{"type":"system"},$output]')?.headline, '2 new emails');
    });

    test('a failed run explains itself', () {
      const output = '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Usage limit reached"}';
      expect(AgentDigest.parse(output), isNull);
      expect(AgentDigest.failure(output), 'Usage limit reached');
      expect(AgentDigest.failure('{"type":"result","is_error":false,"result":""}'), "Claude didn't return a digest.");
      expect(AgentDigest.failure('{"type":"result","is_error":true}'), 'Claude reported an error.');
      expect(AgentDigest.parse('not json'), isNull);
      expect(AgentDigest.failure('not json'), isNull);
      expect(AgentDigest.parse('{"type":"result","is_error":false,"structured_output":{"headline":"h"}}'), isNull, reason: 'the lists are part of the digest');
    });

    test('the digest keeps addresses and meeting links, and only https ones', () {
      final digest = AgentDigest.parse(
        result(
          emails: [
            {
              'id': 't1',
              'from': 'Amogh Sharma',
              'address': 'Amogh Sharma <Amogh@InsideEdge.club>',
              'subject': 'Deck',
              'gist': 'Wants the deck',
              'urgency': 'normal',
              'needs_reply': true,
            },
          ],
          events: [
            {'id': 'e1', 'title': 'Standup', 'start': '2026-11-04T10:00:00Z', 'link': 'https://meet.google.com/abc-defg-hij'},
            {'id': 'e2', 'title': 'Lunch', 'start': '2026-11-04T13:00:00Z', 'link': 'javascript:alert(1)'},
          ],
        ),
      )!;
      expect(digest.emails[0].address, 'amogh@insideedge.club');
      expect(digest.events[0].link, 'https://meet.google.com/abc-defg-hij');
      expect(digest.events[1].link, isNull);
      expect(AgentNews(events: digest.events).notes(DateTime.now()).first.link, 'https://meet.google.com/abc-defg-hij');
    });
  });

  group('Connections', () {
    test('read each connector’s state from the probe, which looks and never calls', () {
      final states = AgentConnections.parse('{"type":"result","is_error":false,"structured_output":{"gmail":true,"calendar":false,"notion":true}}')!;
      expect(states[AgentSource.gmail], AgentConnection.connected);
      expect(states[AgentSource.calendar], AgentConnection.unavailable);
      expect(states[AgentSource.notion], AgentConnection.connected);
      expect(AgentConnections.parse('{"type":"result","is_error":true,"result":"x"}'), isNull);
      final arguments = AgentConnections.probeArguments;
      expect(arguments, contains('dontAsk'));
      expect(arguments.any((argument) => argument.startsWith('mcp__')), isFalse, reason: 'the probe may look, never call');
      expect(AgentConnections.connectURL.toString(), 'https://claude.ai/customize/connectors');
      expect(AgentConnection.needsSignIn.title, 'Needs sign-in');
    });

    test('forget only the Mac’s three sign-in notes', () {
      final directory = Directory.systemTemp.createTempSync('agent_notes');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/needs-auth.json')
        ..writeAsStringSync(
          jsonEncode({
            'claude.ai Notion': {'timestamp': 1},
            'claude.ai Slack': {'timestamp': 2},
            'claude.ai Google Calendar': {'timestamp': 3},
          }),
        );
      expect(AgentConnections.forgetSignInNotes(file), isTrue);
      expect((jsonDecode(file.readAsStringSync()) as Map).keys, ['claude.ai Slack']);
      expect(AgentConnections.forgetSignInNotes(file), isFalse);
      expect(AgentConnections.forgetSignInNotes(File('${directory.path}/missing.json')), isFalse);
    });

    test('Claude Code’s note is under the user’s .claude folder, or CLAUDE_CONFIG_DIR', () {
      expect(AgentConnections.signInNotesFile({'USERPROFILE': r'C:\Users\me'}, windows: true).path, r'C:\Users\me\.claude\mcp-needs-auth-cache.json');
      expect(AgentConnections.signInNotesFile({'HOME': '/home/me'}, windows: false).path, '/home/me/.claude/mcp-needs-auth-cache.json');
      expect(AgentConnections.signInNotesFile({'CLAUDE_CONFIG_DIR': '/cfg', 'HOME': '/h'}, windows: false).path, '/cfg/mcp-needs-auth-cache.json');
    });
  });

  group('Telling the news', () {
    test('says each thing once, and an open task once a day', () {
      final memory = AgentMemory();
      final now = at(9);
      final first = memory.news(sampleDigest(), now: now);
      expect(first.emails.map((email) => email.id), ['b', 'a']);
      expect((first.events.length, first.tasks.length), (1, 1));
      expect(memory.news(sampleDigest(), now: now.add(const Duration(minutes: 15))).isEmpty, isTrue);
      final tomorrow = memory.news(sampleDigest(), now: now.add(const Duration(days: 1)));
      expect(tomorrow.emails, isEmpty);
      expect(tomorrow.events, isEmpty);
      expect(tomorrow.tasks.map((task) => task.id), ['t']);
    });

    test('the most important thing comes first', () {
      final digest = sampleDigest();
      final news = AgentNews(emails: digest.emails, events: digest.events);
      final parts = news.parts();
      expect(parts.first, '2 new emails · Figma: Someone mentioned you (needs a reply)');
      expect(parts, contains('Standup at 10:00 AM'));
      expect(news.line(), endsWith(' · and more'));
      expect(news.attention, AttentionLevel.attention);
      final alert = news.notification();
      expect(alert.title, 'Mochi has news');
      expect(alert.body, contains('Figma'));
      const india = AgentZone('Asia/Kolkata', Duration(hours: 5, minutes: 30));
      expect(news.parts(india), contains('Standup at 3:30 PM'));
    });

    test('newsletters alone stay quiet, and off the phones', () {
      final news = AgentNews(
        emails: const [
          AgentEmail(id: 'a', from: 'Shop', subject: 'Sale', gist: '50% off', urgency: 'low'),
          AgentEmail(id: 'c', from: 'News', subject: 'Weekly', gist: 'This week', urgency: 'low'),
        ],
      );
      expect(news.line(), '2 new emails, nothing urgent');
      expect(news.attention, isNull);
      expect(news.worthPhone(skippingLow: true), isFalse);
      expect(news.worthPhone(skippingLow: false), isTrue);
      expect(news.notification().title, '2 new emails');
      expect(AgentNews(emails: const [AgentEmail(id: 'a', from: 'Shop', subject: 's', gist: 'g', urgency: 'low')]).line(), 'New email from Shop, nothing urgent');
    });

    test('titles for the phone say what came', () {
      expect(AgentNews(events: const [AgentEvent(id: 'e', title: 'Standup', start: '2026-11-03T10:00:00Z')]).notification().title, 'Coming up');
      expect(AgentNews(tasks: const [AgentTask(id: 't', title: 'Ship')]).notification().title, 'Due in Notion');
      expect(AgentNews(tasks: const [AgentTask(id: 't', title: 'Ship')]).parts(), ['Due in Notion: Ship']);
      expect(AgentNews(emails: const [AgentEmail(id: 'a', from: 'A', subject: 's', gist: 'g')]).notification().title, 'New email');
      expect(AgentNews().line(), '');
    });

    test('the bubble’s line is short', () {
      final long = AgentNews(emails: [AgentEmail(id: 'a', from: 'A', subject: 's', gist: 'x' * 300, needsReply: true)]);
      expect(long.line().length, lessThanOrEqualTo(120));
      expect(long.line(), endsWith('…'));
    });

    test('the memory forgets old things', () {
      final memory = AgentMemory();
      final now = DateTime.now();
      final old = now.subtract(const Duration(days: 20)).millisecondsSinceEpoch / 1000;
      memory.seen = {'mail:old': old, 'mail:new': now.millisecondsSinceEpoch / 1000};
      memory.remember([AgentNote(id: 'x', source: AgentSource.gmail, title: 'Old', detail: '', important: false, at: old)]);
      memory.done = {'mail:old': old};
      memory.prune(now: now);
      expect(memory.seen.keys, ['mail:new']);
      expect(memory.notes, isEmpty);
      expect(memory.done, isEmpty);
    });
  });

  group('When to look', () {
    AgentSettings on() => const AgentSettings(enabled: true);

    test('checks on the interval, outside quiet hours', () {
      final morning = at(10);
      expect(AgentSchedule.checkDue(on(), now: morning), isTrue);
      expect(AgentSchedule.checkDue(on(), lastCheck: morning.subtract(const Duration(minutes: 10)), now: morning), isFalse);
      expect(AgentSchedule.checkDue(on(), lastCheck: morning.subtract(const Duration(minutes: 15)), now: morning), isTrue);
      expect(AgentSchedule.checkDue(on(), now: at(2)), isFalse, reason: 'quiet 23:00 to 08:00');
      expect(AgentSchedule.checkDue(on(), now: at(23, 30)), isFalse);
      expect(AgentSchedule.checkDue(const AgentSettings(), now: morning), isFalse, reason: 'off');
      expect(AgentSchedule.checkDue(on().copyWith(intervalMinutes: 60), lastCheck: morning.subtract(const Duration(minutes: 30)), now: morning), isFalse);
    });

    test('briefs once a morning, up to three hours after the chosen time', () {
      expect(AgentSchedule.briefingDue(on(), now: at(8, 30)), isFalse, reason: 'quiet, and before nine');
      expect(AgentSchedule.briefingDue(on(), now: at(9, 5)), isTrue);
      expect(AgentSchedule.briefingDue(on(), lastBriefingDay: '2026-11-03', now: at(9, 5)), isFalse);
      expect(AgentSchedule.briefingDue(on(), lastBriefingDay: '2026-11-02', now: at(9, 5)), isTrue);
      expect(AgentSchedule.briefingDue(on(), now: at(11, 59)), isTrue, reason: 'a PC that slept through it still briefs');
      expect(AgentSchedule.briefingDue(on(), now: at(12)), isFalse);
      expect(AgentSchedule.briefingDue(on(), now: at(18)), isFalse);
      expect(AgentSchedule.briefingDue(on().copyWith(briefingEnabled: false), now: at(9, 5)), isFalse);
      expect(AgentSchedule.briefingDue(on().copyWith(briefingMinute: 7 * 60, quietHours: AgentSettings.defaultQuietHours.copyWith(enabled: false)), now: at(7, 10)), isTrue);
    });

    test('picks up just before the last look', () {
      final now = at(10);
      expect(AgentSchedule.since(lastCheck: now.subtract(const Duration(minutes: 15)), now: now), now.subtract(const Duration(seconds: 1020)));
      expect(AgentSchedule.since(now: now), now.subtract(const Duration(hours: 2)));
      expect(AgentSchedule.since(lastCheck: now.subtract(const Duration(days: 3)), now: now), now.subtract(const Duration(hours: 2)));
      expect(AgentSchedule.dayKey(at(9)), '2026-11-03');
    });
  });

  group('The Pending card', () {
    test('a briefing replaces and checks add', () {
      final memory = AgentMemory();
      final now = at(9);
      final t = now.millisecondsSinceEpoch / 1000;
      memory.updatePending([note('mail:a', AgentSource.gmail, at: t), note('task:t', AgentSource.notion, at: t)], replacing: true, headline: 'Your day', now: now);
      expect(memory.pending.map((each) => each.id), ['task:t', 'mail:a']);
      expect(memory.pendingHeadline, 'Your day');
      memory.updatePending(
        [note('mail:b', AgentSource.gmail, important: true, at: t + 60), note('event:e', AgentSource.calendar, at: t + 60, due: t + 1800)],
        replacing: false,
        now: now.add(const Duration(minutes: 1)),
      );
      expect(memory.pending.map((each) => each.id), ['event:e', 'mail:b', 'task:t', 'mail:a']);
      expect(memory.pendingHeadline, 'Your day');
      memory.updatePending([note('mail:c', AgentSource.gmail, at: t + 120)], replacing: true, headline: 'Fresh', now: now.add(const Duration(minutes: 2)));
      expect(memory.pending.map((each) => each.id), ['mail:c']);
    });

    test('started meetings and old mail drop off, and the card holds eight', () {
      final memory = AgentMemory();
      final now = at(9);
      final t = now.millisecondsSinceEpoch / 1000;
      memory.pending = [
        note('event:soon', AgentSource.calendar, at: t, due: t + 600),
        note('event:gone', AgentSource.calendar, at: t, due: t - 1200),
        note('mail:old', AgentSource.gmail, at: t - 31 * 3600),
        note('mail:new', AgentSource.gmail, at: t),
      ];
      expect(memory.prunePending(now: now), isTrue);
      expect(memory.pending.map((each) => each.id), ['event:soon', 'mail:new']);
      expect(memory.prunePending(now: now), isFalse);
      memory.pending = [for (var i = 0; i < 12; i++) note('mail:$i', AgentSource.gmail, at: t + i)];
      memory.prunePending(now: now);
      expect(memory.pending.length, agentPendingMax);
      expect(memory.pending.first.id, 'mail:11', reason: 'newest first');
      memory.pending = [note('mail:x', AgentSource.gmail, at: t - 40 * 3600)];
      memory.pendingHeadline = 'old';
      memory.prunePending(now: now);
      expect(memory.pending, isEmpty);
      expect(memory.pendingHeadline, isNull);
    });

    test('old memory files still load, and what is kept saves and loads', () {
      final old = AgentMemory.fromJson(jsonDecode('{"seen": {"mail:a": 1800000000}, "lastCheckAt": 1800000000, "notes": []}'));
      expect(old.seen['mail:a'], 1800000000);
      expect(old.pending, isEmpty);
      expect(AgentMemory.fromJson('garbage').seen, isEmpty);
      final memory = AgentMemory()
        ..seen = {'mail:a': 5}
        ..lastCheckAt = 9
        ..lastBriefingDay = '2026-11-03'
        ..pendingHeadline = 'h'
        ..pending = [note('mail:a', AgentSource.gmail, at: 5)]
        ..notes = [note('mail:a', AgentSource.gmail, at: 5)]
        ..markDone({'mail:z': 7})
        ..markedRead = {'z': 8};
      final back = AgentMemory.fromJson(jsonDecode(jsonEncode(memory.toJson())));
      expect(back.seen, {'mail:a': 5.0, 'mail:z': 7.0});
      expect((back.lastCheckAt, back.lastBriefingDay, back.pendingHeadline), (9.0, '2026-11-03', 'h'));
      expect(back.done, {'mail:z': 7.0});
      expect(back.markedRead, {'z': 8.0});
      expect((back.pending.single.id, back.notes.single.id), ('mail:a', 'mail:a'));
      expect(memory.toJson().keys.toSet(), {'seen', 'lastCheckAt', 'lastBriefingDay', 'notes', 'pending', 'pendingHeadline', 'done', 'markedRead'}, reason: 'only what the Mac keeps');
    });

    test('the card rides in the notification, small enough for a push', () {
      final items = [
        for (var i = 0; i < 8; i++)
          AgentNote(
            id: 'mail:$i',
            source: AgentSource.gmail,
            title: 'x' * 200,
            detail: 'd',
            important: true,
            at: 1,
            link: 'https://mail.google.com/mail/#all/abc$i',
          ),
      ];
      final card = AgentPending(enabled: true, headline: '2 new emails', items: items, lookedAt: 10, updatedAt: 11);
      final inner = AgentAlert.inner(title: 'New email', body: 'b', pending: card, quietIfKnown: true);
      expect(jsonEncode(inner).length, lessThan(4096));
      expect(inner['title'], 'New email');
      expect(inner['body'], 'b');
      expect(inner.keys, unorderedEquals(['title', 'body', 'userInfo']));
      final info = inner['userInfo']! as Map;
      expect(info.keys, unorderedEquals(['kind', 'quietIfKnown', 'pending']));
      expect((info['kind'], info['quietIfKnown']), ('agent', true));
      final decoded = AgentPending.fromJson(info['pending'])!;
      expect(decoded.items.length, 6);
      expect(decoded.items[0].title.length, lessThanOrEqualTo(60));
      expect(decoded.updatedAt, 11);
      expect(AgentAlert.category, 'mochi-agent');
      expect(AgentAlert.threadId, 'mochi-agent');
      expect(((AgentAlert.inner(title: 't', body: 'b')['userInfo']! as Map)).containsKey('pending'), isFalse);
      expect(((AgentAlert.inner(title: 't', body: 'b')['userInfo']! as Map))['quietIfKnown'], false);
    });

    test('links open Gmail and Notion, and nothing else', () {
      final notes = AgentNews(
        emails: const [AgentEmail(id: '19a3f2c', from: 'Figma', subject: 's', gist: 'g'), AgentEmail(id: 'a/b', from: 'X', subject: 's', gist: 'g')],
        tasks: const [AgentTask(id: 't', title: 'Ship', url: 'https://www.notion.so/abc'), AgentTask(id: 'u', title: 'Odd', url: 'javascript:x')],
      ).notes(DateTime.now());
      expect(notes.firstWhere((each) => each.id == 'mail:19a3f2c').link, 'https://mail.google.com/mail/#all/19a3f2c');
      expect(notes.firstWhere((each) => each.id == 'mail:a/b').link, isNull);
      expect(notes.firstWhere((each) => each.id == 'task:t').link, 'https://www.notion.so/abc');
      expect(notes.firstWhere((each) => each.id == 'task:u').link, isNull);
    });
  });

  group('Sender names', () {
    const cases = {
      'VFDF via Figma <comments-lzhpqhzeuzf3nxedxnsjmg@email.figma.com>': 'VFDF via Figma',
      '"Rahul Sharma" <rahul@insideedge.club>': 'Rahul Sharma',
      'comments-lzhpqhzeuzf3nxedxnsjmg@email.figma.com': 'Figma',
      'no-reply@accounts.google.com': 'Google',
      'no-reply@clevertap.com': 'CleverTap',
      'team@mail.notion.so': 'Notion',
      '<orders@shop.co.uk>': 'Shop',
      'Google (no-reply@accounts.google.com)': 'Google',
      'no-reply@accounts.google.com (Google Accounts)': 'Google Accounts',
      'Figma': 'Figma',
    };
    cases.forEach((raw, expected) => test('$raw → $expected', () => expect(AgentEmail.senderName(raw), expected)));

    test('the plain address', () {
      expect(AgentEmail.plainAddress('Amogh <Amogh@InsideEdge.club>'), 'amogh@insideedge.club');
      expect(AgentEmail.plainAddress('"a@b.com"'), 'a@b.com');
      expect(AgentEmail.plainAddress('Figma'), isNull);
      expect(AgentEmail.plainAddress('a b@c.com'), isNull);
    });

    test('the digest shows names and subjects', () {
      final digest = AgentDigest.parse(
        result(
          emails: [
            {'id': 't1', 'from': 'no-reply@accounts.google.com', 'subject': 'Security alert', 'gist': 'New sign-in on a PC', 'urgency': 'normal', 'needs_reply': false},
          ],
        ),
      )!;
      expect(digest.emails[0].from, 'Google');
      final one = AgentNews(emails: digest.emails).notes(DateTime.now()).first;
      expect((one.title, one.subject, one.detail), ('Google', 'Security alert', 'New sign-in on a PC'));
    });
  });

  group('VIPs, done', () {
    AgentEmail email(String id, String from, String? address, {String urgency = 'normal'}) =>
        AgentEmail(id: id, from: from, subject: 'S', gist: 'G', urgency: urgency, address: address);

    test('VIPs match names, addresses and domains', () {
      final amogh = email('1', 'Amogh Sharma', 'amogh@insideedge.club');
      final figma = email('2', 'VFDF via Figma', 'comments@figma.com');
      expect(AgentVIP.matches(amogh, ['amogh']), isTrue);
      expect(AgentVIP.matches(amogh, ['AMOGH@insideedge.club']), isTrue);
      expect(AgentVIP.matches(amogh, ['@insideedge.club']), isTrue);
      expect(AgentVIP.matches(figma, ['@insideedge.club', 'amogh']), isFalse);
      expect(AgentVIP.matches(email('3', 'Someone', null), ['@insideedge.club']), isFalse);
      expect(AgentVIP.matches(amogh, ['', '  ']), isFalse);
      expect(AgentVIP.gmailQuery(['Amogh Sharma', '@insideedge.club', 'a@b.com']), 'from:("Amogh Sharma" OR insideedge.club OR a@b.com)');
      expect(AgentVIP.gmailQuery([' ']), isNull);
    });

    test('with VIPs only their mail rings', () {
      const vips = ['@insideedge.club'];
      final boss = email('1', 'Amogh', 'amogh@insideedge.club');
      final loud = email('2', 'Stranger', 'x@y.com', urgency: 'high');
      expect(AgentNews(emails: [loud], vips: vips).attention, isNull);
      expect(AgentNews(emails: [loud, boss], vips: vips).attention, AttentionLevel.attention);
      expect(AgentNews(emails: [loud, boss], vips: vips).emails.first.id, '1', reason: 'VIPs come first');
      expect(AgentNews(emails: [loud]).attention, AttentionLevel.attention, reason: 'without VIPs, urgency decides');
      expect(AgentNews(tasks: const [AgentTask(id: 't', title: 'x')], vips: vips).attention, AttentionLevel.info);
      final notes = AgentNews(emails: [loud, boss], vips: vips).notes(DateTime.now());
      expect((notes[0].vip, notes[0].important), (true, true));
      expect(notes[1].vip, isNull);
    });

    test('done leaves the card and never comes back', () {
      final memory = AgentMemory();
      final now = at(9);
      final t = now.millisecondsSinceEpoch / 1000;
      final digest = AgentDigest(headline: 'h', emails: [email('t1', 'A', null), email('t2', 'B', null)]);
      final news = memory.news(digest, now: now);
      memory.updatePending(news.notes(now), replacing: true, headline: 'Two emails', now: now);
      expect(memory.pending.length, 2);
      expect(memory.markDone({'mail:t1': t}), isTrue);
      expect(memory.markDone({'mail:t1': t}), isFalse, reason: 'already done');
      expect(memory.pending.map((each) => each.id), ['mail:t2']);
      expect(memory.threadsToMarkRead, ['t1']);
      // A briefing that still sees it doesn't bring it back.
      memory.updatePending(AgentNews(emails: digest.emails).notes(now), replacing: true, headline: 'h', now: now);
      expect(memory.pending.map((each) => each.id), ['mail:t2']);
      memory.markDone({'mail:t2': t});
      expect(memory.pending, isEmpty);
      expect(memory.pendingHeadline, isNull);
      // Done before Mochi ever mentioned it (marked on a phone from a cloud card): never news.
      final fresh = AgentMemory()..markDone({'mail:t1': t});
      expect(fresh.news(digest, now: now).emails.map((each) => each.id), ['t2']);
    });

    test('the done list stays small and recent, and the union keeps the later mark', () {
      final now = at(9);
      final t = now.millisecondsSinceEpoch / 1000;
      final memory = AgentMemory()..done = {'old': t - 8 * 86400, for (var i = 0; i < 400; i++) 'mail:$i': t - i};
      final trimmed = doneList(memory, now: now);
      expect(trimmed.ids.length, AgentDoneList.maxItems);
      expect(trimmed.ids['old'], isNull);
      expect(trimmed.ids['mail:0'], isNotNull);
      expect(trimmed.ids['mail:399'], isNull);
      expect(AgentDoneList.fromValue(trimmed.toValue())?.ids, trimmed.ids);
      expect(const AgentDoneList(ids: {'a': 1, 'b': 5}).union(const AgentDoneList(ids: {'a': 3})).ids, {'a': 3, 'b': 5});
    });
  });
}
