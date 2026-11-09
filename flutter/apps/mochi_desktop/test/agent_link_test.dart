// Docs/SPRINT_2.md W23a: what leaves this PC for the phones, through the real Link host against a fake relay socket (frames
// sealed and opened with the room key for real), and what comes in: the `agent` card and `macDone` (the PC writes
// `macDone`), the sealed `mochi-agent` alert with the card riding along, the phones' `phoneDone` kept as a union, and
// "what's pending?" typed and from a phone's command (the phone's "Check now"). Also the development switch and the badge.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/agent/agent_settings.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show AttentionLevel;
import 'package:mochi_link/mochi_link.dart';

import 'support/agent_fakes.dart';
import 'support/fakes.dart';

Future<void> settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

double get nowSeconds => DateTime.now().millisecondsSinceEpoch / 1000;

Map<String, Object?> device(String id, String role) => {
  'id': id,
  'role': role,
  'platform': role == 'host' ? 'windows' : 'android',
  'name': id,
  'online': true,
};

void main() {
  late TestDesktop t;
  late AgentClaudeFake claude;
  tearDown(() => t.dispose());

  Future<void> paired({String? debug, bool enabled = true, AgentSettings? agent, DateTime Function()? clock}) async {
    claude = AgentClaudeFake();
    t = TestDesktop.make(saved: hostCredentials, agentClaude: claude, agentDebug: debug, clock: clock);
    if (enabled || agent != null) t.desktop.settings.agent = agent ?? const AgentSettings(enabled: true);
    await t.desktop.start();
    await settle();
    t.socket.sync(devices: [device('dev_pc', 'host'), device('dev_droid', 'pocket')]);
    await settle();
  }

  AgentPending? card() {
    final values = t.socket.values(LinkKey.agent);
    return values.isEmpty ? null : AgentPending.fromValue(values.last);
  }

  LinkAlert openAlert(Map<String, Object?> frame) => LinkAlert.open({...frame, 'from': hostCredentials.device}, room: hostCredentials.room, roomKey: roomKey)!;

  Future<void> check() async {
    await t.desktop.agent.checkNow();
    await settle();
  }

  group('What leaves the PC', () {
    test('while the agent is off, only a card that says so', () async {
      await paired(enabled: false);
      expect(t.socket.values(LinkKey.agent).last, isA<String>(), reason: 'a JSON string, as the Mac stores it');
      expect(card()?.enabled, isFalse);
      expect(card()?.items, isEmpty);
      expect(card()?.headline, isNull);
      expect(t.socket.sentFrames('send', 'alert'), isEmpty);
      expect(t.socket.sentFrames('put', 'macDone'), isEmpty);
      expect(claude.runs, isEmpty);
      expect(t.desktop.agent.ticking, isFalse);
    });

    test('a check: the card (`agent`) and one sealed `mochi-agent` alert carrying the card, never in the clear', () async {
      await paired();
      claude.check = digestOutput(
        headline: 'An invoice needs a reply',
        emails: [mail('t1', from: 'Acme Billing', subject: 'Invoice 42', gist: 'Please pay by Friday', reply: true)],
      );
      await check();
      final shared = card()!;
      expect(shared.enabled, isTrue);
      expect(shared.items.single.id, 'mail:t1');
      expect((shared.items.single.title, shared.items.single.subject, shared.items.single.detail), ('Acme Billing', 'Invoice 42', 'Please pay by Friday'));
      expect(shared.items.single.link, 'https://mail.google.com/mail/#all/t1');
      expect(shared.lookedAt, isNotNull);
      expect(shared.updatedAt, isNotNull);
      expect(t.socket.sentFrames('put', 'agent').last['to'], isNull, reason: 'state for everyone in the room');

      final frame = t.socket.sentFrames('send', 'alert').single;
      expect(frame['to'], ['pocket']);
      expect(frame['push'], {'kind': 'alert', 'priority': 10, 'category': 'mochi-agent', 'threadId': 'mochi-agent'});
      final alert = openAlert(frame);
      expect(alert.title, 'New email');
      expect(alert.subtitle, isNull);
      expect(alert.body, 'New email from Acme Billing: Please pay by Friday (needs a reply)');
      expect(alert.userInfo.keys, unorderedEquals(['kind', 'quietIfKnown', 'pending']));
      expect(alert.userInfo['kind'], 'agent');
      expect(alert.userInfo['quietIfKnown'], isTrue);
      final inner = AgentPending.fromJson(alert.userInfo['pending'])!;
      expect(inner.items.single.id, 'mail:t1');
      expect(inner.enabled, isTrue);
      final wire = jsonEncode(frame);
      for (final secret in ['Acme', 'Invoice', 'Friday', 'mail.google.com', 'needs a reply']) {
        expect(wire, isNot(contains(secret)), reason: '$secret stays sealed');
      }
    });

    test('nothing new, or a quiet newsletter: no alert', () async {
      await paired();
      claude.check = digestOutput(emails: [mail('n1', urgency: 'low', from: 'Shop')]);
      await check();
      expect(t.socket.sentFrames('send', 'alert'), isEmpty, reason: 'newsletters stay off the phones');
      expect(card()?.items.single.id, 'mail:n1', reason: 'but they are on the card');
      claude.check = digestOutput(emails: [mail('a', reply: true)]);
      await check();
      expect(t.socket.sentFrames('send', 'alert'), hasLength(1));
      await check();
      expect(t.socket.sentFrames('send', 'alert'), hasLength(1), reason: 'said once');
    });

    test('“On my phones” off: no alert, and the card says it is not shared', () async {
      await paired(agent: const AgentSettings(enabled: true, tellPhone: false));
      claude.check = digestOutput(emails: [mail('a', reply: true)]);
      await check();
      expect(t.socket.sentFrames('send', 'alert'), isEmpty);
      expect(card()?.enabled, isFalse);
      expect(card()?.items, isEmpty);
      expect(t.desktop.agent.notes, hasLength(1), reason: 'Settings still lists it');
    });

    test('the morning briefing rings as “Your day”, not quietly', () async {
      final morning = DateTime(2026, 11, 3, 9, 10);
      await paired(enabled: false, clock: () => morning);
      claude.check = digestOutput(headline: 'Two meetings today', emails: [mail('a', reply: true)]);
      t.desktop.settings.agent = const AgentSettings(enabled: true);
      // The tick finds the briefing due (09:10, after 09:00 and outside quiet hours) and tells the phones.
      t.desktop.agent.tick();
      await settle();
      final alert = openAlert(t.socket.sentFrames('send', 'alert').single);
      expect(alert.title, 'Your day');
      expect(alert.body, startsWith('Two meetings today'));
      expect(alert.userInfo['quietIfKnown'], isFalse);
      expect(AgentPending.fromJson(alert.userInfo['pending'])!.headline, 'Two meetings today');
    });

    test('Done here: off the card, and `macDone` (the PC writes macDone) says so', () async {
      await paired();
      claude.check = digestOutput(emails: [mail('t1', reply: true), mail('t2', reply: true, from: 'Other')]);
      await check();
      t.desktop.agent.markDone(t.desktop.agent.notes.firstWhere((note) => note.id == 'mail:t1'));
      await settle();
      expect(t.socket.sentFrames('put', 'macDone'), isNotEmpty);
      expect(t.socket.sentFrames('put', 'phoneDone'), isEmpty, reason: 'phoneDone is the phone’s to write');
      expect(t.socket.values(LinkKey.macDone).last, isA<String>());
      expect(AgentDoneList.fromValue(t.socket.values(LinkKey.macDone).last)!.ids.keys, ['mail:t1']);
      expect(card()!.items.map((item) => item.id), ['mail:t2']);
    });

    test('a phone’s done list is kept with ours: the union goes back out', () async {
      await paired();
      claude.check = digestOutput(emails: [mail('t1', reply: true), mail('t2', reply: true, from: 'Other'), mail('t3', reply: true, from: 'Third')]);
      await check();
      t.desktop.agent.markDone(t.desktop.agent.notes.firstWhere((note) => note.id == 'mail:t3'));
      await settle();
      t.socket.fromPhone(AgentDoneList(ids: {'mail:t1': nowSeconds}).toValue(), LinkKey.phoneDone);
      await settle();
      expect(t.desktop.agent.isDone('mail:t1'), isTrue);
      expect(card()!.items.map((item) => item.id), ['mail:t2']);
      expect(AgentDoneList.fromValue(t.socket.values(LinkKey.macDone).last)!.ids.keys, unorderedEquals(['mail:t1', 'mail:t3']));
      // The phone adds one more later, with its old mark still in its list.
      t.socket.fromPhone(AgentDoneList(ids: {'mail:t1': nowSeconds, 'mail:t2': nowSeconds}).toValue(), LinkKey.phoneDone);
      await settle();
      expect(card()!.items, isEmpty);
      expect(AgentDoneList.fromValue(t.socket.values(LinkKey.macDone).last)!.ids.keys, unorderedEquals(['mail:t1', 'mail:t2', 'mail:t3']));
    });

    test('turning the agent off tells the phones, and stops everything', () async {
      await paired();
      claude.check = digestOutput(emails: [mail('t1', reply: true)]);
      await check();
      expect(card()?.enabled, isTrue);
      t.desktop.settings.agent = const AgentSettings(enabled: false);
      await settle();
      expect(card()?.enabled, isFalse);
      expect(card()?.items, isEmpty);
      expect(t.desktop.agent.ticking, isFalse);
      expect(t.desktop.agent.badge, isNull);
    });

    test('the card is published again when the link comes back', () async {
      await paired();
      claude.check = digestOutput(emails: [mail('t1', reply: true)]);
      await check();
      final before = t.socket.sentFrames('put', 'agent').length;
      t.socket.drop();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await settle();
      t.socket.sync(devices: [device('dev_pc', 'host'), device('dev_droid', 'pocket')]);
      await settle();
      expect(t.socket.sentFrames('put', 'agent').length, greaterThan(0));
      expect(t.sockets.length, greaterThan(1), reason: 'a new connection');
      expect(before, greaterThan(0));
    });
  });

  group('“What’s pending?”', () {
    test('typed in Ask Mochi: the Mac’s answer, from a fresh look', () async {
      await paired();
      claude.check = digestOutput(headline: 'One email and a standup', emails: [mail('a', reply: true)]);
      final outcome = await t.desktop.ask.ask("what's pending?");
      expect(outcome.ok, isTrue);
      expect(outcome.text, startsWith('One email and a standup. '));
      expect(claude.checks, hasLength(1));
      expect(t.socket.sentFrames('send', 'alert'), isEmpty, reason: 'asked, not told');
      expect(card()?.headline, 'One email and a standup', reason: 'the card follows what it found');
    });

    test('with the agent off it says to turn it on, and runs nothing', () async {
      await paired(enabled: false);
      final outcome = await t.desktop.ask.ask("what's pending?");
      expect((outcome.text, outcome.ok), ('Turn on Mochi\'s agent in Settings › Agent first.', false));
      expect(claude.runs, isEmpty);
    });

    test('from a phone’s command (its “Check now”): working, then the answer', () async {
      await paired();
      claude.check = digestOutput(headline: 'Quiet morning');
      t.socket.fromPhone(LinkCommand(id: 'c1', text: 'check my email', at: nowSeconds).toValue(), LinkKey.command);
      await settle();
      final replies = [for (final value in t.socket.values(LinkKey.reply)) LinkReply.fromValue(value)!];
      expect(replies.map((reply) => (reply.id, reply.state)), [('c1', 'working'), ('c1', 'done')]);
      expect(replies.last.text, 'Quiet morning');
      expect(claude.checks, hasLength(1));
    });

    test('from a phone while the agent is off: the reply says so', () async {
      await paired(enabled: false);
      t.socket.fromPhone(LinkCommand(id: 'c2', text: "what's pending", at: nowSeconds, typed: true).toValue(), LinkKey.command);
      await settle();
      final last = LinkReply.fromValue(t.socket.values(LinkKey.reply).last)!;
      expect((last.state, last.text), ('failed', 'Turn on Mochi\'s agent in Settings › Agent first.'));
    });
  });

  group('The badge, and the development switch', () {
    test('the dot is the higher of Claude’s badge and the agent’s', () async {
      await paired();
      expect(t.desktop.badgeLevel, isNull);
      claude.check = digestOutput(tasks: [
        {'id': 't', 'title': 'Ship'},
      ]);
      await check();
      expect(t.desktop.agent.badge, AttentionLevel.info);
      expect(t.desktop.badgeLevel, AttentionLevel.info);
      claude.check = digestOutput(emails: [mail('a', reply: true)]);
      await check();
      expect(t.desktop.badgeLevel, AttentionLevel.attention);
      // Claude needs you as well: whichever is higher shows.
      t.desktop.receive(hook('SessionStart'));
      t.desktop.receive(hook('UserPromptSubmit'));
      t.desktop.receive(hook('PermissionRequest', tool: 'Bash'));
      final claudeLevel = t.desktop.reactions.badge?.level;
      if (claudeLevel != null) {
        expect(t.desktop.badgeLevel!.index, claudeLevel.index >= AttentionLevel.attention.index ? claudeLevel.index : AttentionLevel.attention.index);
      }
      t.desktop.agent.acknowledge();
      expect(t.desktop.agent.badge, isNull);
      expect(t.desktop.badgeLevel, t.desktop.reactions.badge?.level);
    });

    test('MOCHI_DESKTOP_AGENT=check runs once, shortly after the start, with the agent off, and logs counts only', () async {
      claude = AgentClaudeFake()..check = digestOutput(emails: [mail('a', from: 'SECRET-SENDER', subject: 'SECRET-SUBJECT')]);
      t = TestDesktop.make(saved: hostCredentials, agentClaude: claude, agentDebug: 'check', agentDebugAfter: const Duration(milliseconds: 150));
      Directory('${t.temp.path}/mochi').createSync(recursive: true);
      File('${t.temp.path}/mochi/stroll-debug').writeAsStringSync('');
      await t.desktop.start();
      await settle();
      expect(claude.runs, isEmpty, reason: 'shortly after, not at once');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await settle();
      expect(claude.checks, hasLength(1));
      expect(t.desktop.settings.agent.enabled, isFalse);
      final log = File('${t.temp.path}/mochi/stroll.log').readAsLinesSync().where((line) => line.contains('agent:')).toList();
      expect(log.map((line) => line.substring(line.indexOf('agent:'))), [
        'agent: connections gmail=connected calendar=connected notion=connected',
        'agent: check ok, 1 mail, 0 event, 0 tasks',
      ]);
      expect(File('${t.temp.path}/mochi/stroll.log').readAsStringSync(), isNot(contains('SECRET')));
      expect(t.socket.sentFrames('send', 'alert'), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(claude.checks, hasLength(1), reason: 'once');
    });

    test('brief and connections work too; an unknown value does nothing', () async {
      claude = AgentClaudeFake();
      t = TestDesktop.make(saved: hostCredentials, agentClaude: claude, agentDebug: 'connections', agentDebugAfter: const Duration(milliseconds: 100));
      Directory('${t.temp.path}/mochi').createSync(recursive: true);
      File('${t.temp.path}/mochi/stroll-debug').writeAsStringSync('');
      await t.desktop.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await settle();
      expect(claude.probes, hasLength(1));
      expect(claude.checks, isEmpty);
      await t.dispose();

      claude = AgentClaudeFake();
      t = TestDesktop.make(saved: hostCredentials, agentClaude: claude, agentDebug: 'sing', agentDebugAfter: const Duration(milliseconds: 50));
      await t.desktop.start();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(claude.runs, isEmpty);
      await t.dispose();

      claude = AgentClaudeFake();
      t = TestDesktop.make(saved: hostCredentials, agentClaude: claude, agentDebugAfter: const Duration(milliseconds: 50));
      await t.desktop.start();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(claude.runs, isEmpty, reason: 'without the switch nothing runs while the agent is off');
    });
  });
}
