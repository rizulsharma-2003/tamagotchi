// The Link host flows against a fake relay socket (frames sealed and opened with the room key for real), checked
// with the same mochi_link models the iPhone's and Android's apps decode them with.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/link/link_host.dart';
import 'package:mochi_desktop/src/platform/credential_vault.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'support/brain_fakes.dart';
import 'support/fakes.dart';

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

double get now => DateTime.now().millisecondsSinceEpoch / 1000;

Map<String, Object?> device(String id, String role, {bool online = true, String? name}) => {
  'id': id,
  'role': role,
  'platform': role == 'host' ? 'windows' : 'ios',
  'name': name ?? id,
  'online': online,
};

void main() {
  late TestDesktop t;

  tearDown(() => t.dispose());

  group('Pairing', () {
    test('makes the room once, shows a code, and keeps the link in the vault', () async {
      t = TestDesktop.make();
      final link = t.desktop.link;
      await link.start();
      expect(link.loaded, isTrue);
      expect(link.paired, isFalse);

      await link.showCode();
      expect(t.api.roomsMade, 1);
      expect(t.vault.saved, hostCredentials);
      expect(link.code!.name, 'TEST-PC');
      expect(PairingCode.parse(link.code!.url), link.code, reason: 'the QR text reads back');
      await settle();
      expect(t.socket.url.toString(), 'wss://relay.test/v1/rooms/room_pc/socket');
      expect(t.socket.headers['authorization'], 'Bearer dev_pc.pc-secret');
      expect(t.socket.sent.first['op'], 'hello');
      expect(t.socket.sent.first['platform'], 'windows');

      await link.showCode();
      expect(t.api.roomsMade, 1, reason: 'the room is reused');
      expect(t.api.invites, 2);
    });

    test('the code stays up for phones already in the room, and goes when a new one joins', () async {
      t = TestDesktop.make(saved: hostCredentials);
      final link = t.desktop.link;
      await link.start();
      await link.showCode();
      await settle();
      t.socket.sync(devices: [device('dev_pc', 'host'), device('dev_old_phone', 'pocket')]);
      await settle();
      expect(link.code, isNotNull);
      expect(link.devices.single.name, 'dev_old_phone');
      t.socket.deliver({
        'v': 1,
        'op': 'devices',
        'devices': [device('dev_pc', 'host'), device('dev_old_phone', 'pocket'), device('dev_new_phone', 'pocket', name: 'Pixel 8')],
      });
      await settle();
      expect(link.code, isNull);
      expect(link.devices.map((peer) => peer.name), ['dev_old_phone', 'Pixel 8']);
    });

    test('codes expire after 10 minutes', () async {
      var clock = DateTime(2026, 11, 5, 9);
      t = TestDesktop.make(clock: () => clock);
      await t.desktop.link.showCode();
      expect(t.desktop.link.code, isNotNull);
      clock = clock.add(const Duration(minutes: 10));
      expect(t.desktop.link.code, isNull);
    });

    test('unpair deletes the room on the relay and forgets it here', () async {
      t = TestDesktop.make(saved: hostCredentials);
      final link = t.desktop.link;
      await link.start();
      await settle();
      expect(link.paired, isTrue);
      final socket = t.socket;
      await link.unpair();
      expect(t.api.deleted.single, hostCredentials);
      expect(t.vault.saved, isNull);
      expect(link.paired, isFalse);
      expect(socket.closed, isTrue);
    });

    test('problems are said in words', () async {
      t = TestDesktop.make();
      t.api.failCreate = const LinkPairingException('The relay said no (rate_limited).', code: 'rate_limited');
      await t.desktop.link.showCode();
      expect(t.desktop.link.problem, 'The relay said no (rate_limited).');
      expect(t.desktop.link.paired, isFalse);
    });

    test('a room the relay removed (4004) can be replaced by making a new code', () async {
      t = TestDesktop.make(saved: hostCredentials);
      await t.desktop.link.start();
      await settle();
      t.socket.drop(4004);
      await settle();
      expect(t.desktop.link.status, LinkStatus.removed);
      await t.desktop.link.showCode();
      expect(t.api.roomsMade, 1);
      expect(t.desktop.link.code, isNotNull);
    });
  });

  group('A room before any phone (for updates)', () {
    test('ensureRoom makes the room quietly, once, however many ask at the same time', () async {
      t = TestDesktop.make();
      final link = t.desktop.link;
      await link.start();
      final rooms = await Future.wait([link.ensureRoom(), link.ensureRoom(), link.ensureRoom()]);
      expect(rooms, everyElement(hostCredentials));
      expect(t.api.roomsMade, 1);
      expect(t.vault.saved, hostCredentials);
      expect(link.hasRoom, isTrue);
      expect(link.paired, isFalse, reason: 'a room with no phone in it is not a pairing');
      expect(link.problem, isNull, reason: 'nothing is shown');
      expect(link.code, isNull);
      expect(await link.ensureRoom(), hostCredentials);
      expect(t.api.roomsMade, 1, reason: 'the room is kept');
    });

    test('offline: no room, no problem shown, and the next call tries again', () async {
      t = TestDesktop.make();
      t.api.failCreate = const LinkPairingException("Couldn't reach the relay.");
      expect(await t.desktop.link.ensureRoom(), isNull);
      expect(t.desktop.link.problem, isNull);
      t.api.failCreate = null;
      expect(await t.desktop.link.ensureRoom(), hostCredentials);
    });

    test('pairing a phone later invites into the same room, and the first phone makes it paired', () async {
      t = TestDesktop.make();
      final link = t.desktop.link;
      await link.start();
      await link.ensureRoom();
      await settle();
      t.socket.sync(devices: [device('dev_pc', 'host')]);
      await settle();
      expect(link.paired, isFalse);
      expect(t.socket.values(LinkKey.look), isEmpty, reason: 'nothing is published to an empty room');

      await link.showCode();
      expect(t.api.roomsMade, 1);
      expect(t.api.invites, 1);
      t.desktop.phone.start();
      t.socket.deliver({
        'v': 1,
        'op': 'devices',
        'devices': [device('dev_pc', 'host'), device('dev_phone', 'pocket', name: 'Pixel 8')],
      });
      await settle();
      expect(link.paired, isTrue);
      expect(link.code, isNull, reason: 'the phone used the code');
      expect(t.socket.values(LinkKey.look), isNotEmpty, reason: 'the first phone gets everything at once');
    });

    test('a room the relay ended is made again', () async {
      t = TestDesktop.make(saved: hostCredentials);
      await t.desktop.link.start();
      await settle();
      t.socket.drop(4004);
      await settle();
      expect(t.desktop.link.status, LinkStatus.removed);
      expect(await t.desktop.link.ensureRoom(), hostCredentials);
      expect(t.api.roomsMade, 1);
    });

    test('whether phones are in the room is remembered for the next launch (before the relay answers)', () async {
      final folder = Directory.systemTemp.createTempSync('mochi_link_hint');
      addTearDown(() => folder.deleteSync(recursive: true));
      final hint = '${folder.path}/phones';
      LinkHost host(MemoryVault vault) => LinkHost(
        vault: vault,
        api: FakeLinkApi(),
        connect: (credentials) => RelayLink(
          credentials,
          platform: 'windows',
          app: 'test',
          connect: (url, headers) => FakeSocket(url, headers),
          backoff: (_) => const Duration(milliseconds: 1),
        ),
        hostName: 'TEST-PC',
        phonesHintFile: hint,
      );
      t = TestDesktop.make();
      final first = host(MemoryVault());
      await first.ensureRoom();
      expect(File(hint).readAsStringSync(), '0');
      final next = host(MemoryVault(hostCredentials));
      await next.start();
      expect(next.paired, isFalse, reason: 'no phone had joined');
      File(hint).writeAsStringSync('1');
      final later = host(MemoryVault(hostCredentials));
      await later.start();
      expect(later.paired, isTrue);
      await later.unpair();
      expect(File(hint).existsSync(), isFalse);
      first.dispose();
      next.dispose();
    });
  });

  group('What the phones get', () {
    Future<void> paired({Map<String, Object?>? settings, bool claudeInstalled = true}) async {
      t = TestDesktop.make(saved: hostCredentials, settings: settings, claudeInstalled: claudeInstalled);
      await t.desktop.start();
      await settle();
    }

    test("the look, Claude's state and the sessions list, in the Mac's shapes", () async {
      await paired();
      final look = PetLook.fromValue(t.socket.values(LinkKey.look).last);
      expect(look!.petName, 'Mochi');
      expect(look.theme, 'cozyDesk');
      expect(t.socket.values(LinkKey.look).last, isA<String>(), reason: 'stored as a JSON string, as the Mac does');
      expect(ClaudeMirror.fromValue(t.socket.values(LinkKey.claude).last)!.phase, 'none');
      final sessions = PhoneSessions.fromValue(t.socket.values(LinkKey.sessions).last)!;
      expect(sessions.enabled, isFalse);
      expect(sessions.sessions, isEmpty);
      expect(t.socket.sentFrames('put', 'sessions').last['to'], isNull);
    });

    test('commands: working, then the answer; never twice; too old ignored; one-session replies need the helper', () async {
      await paired();
      List<LinkReply> replies() => [for (final value in t.socket.values(LinkKey.reply)) LinkReply.fromValue(value)!];

      t.socket.fromPhone(
        LinkCommand(id: 'c1', text: 'status', at: now, typed: true).toValue(),
        LinkKey.command,
        id: 'f1',
      );
      await settle();
      expect(replies().map((reply) => (reply.id, reply.state)), [('c1', 'working'), ('c1', 'done')]);
      expect(replies().last.text, 'No Claude sessions right now.');
      expect(t.socket.sentFrames('send', 'reply').first['to'], ['pocket']);
      expect(t.socket.sentFrames('ack').map((frame) => frame['id']), contains('f1'));

      // The relay redelivers it: handled already.
      t.socket.fromPhone(
        LinkCommand(id: 'c1', text: 'status', at: now, typed: true).toValue(),
        LinkKey.command,
        id: 'f2',
      );
      t.socket.fromPhone(LinkCommand(id: 'old', text: 'status', at: now - 600).toValue(), LinkKey.command);
      await settle();
      expect(replies(), hasLength(2));

      t.socket.fromPhone(
        LinkCommand(id: 'c2', text: 'Yes, run the tests', at: now, project: 'web', session: 's1').toValue(),
        LinkKey.command,
      );
      await settle();
      expect(replies().last.state, 'failed');
      expect(replies().last.text, contains("couldn't start my helper Claude, so I didn't send it"));

      t.socket.fromPhone(LinkCommand(id: 'c3', text: 'tell me a joke', at: now, typed: true).toValue(), LinkKey.command);
      await settle();
      expect(replies().last.id, 'c3');
      expect(replies().last.text, 'Hi!');
      expect(t.claude.runs.single.input, endsWith('tell me a joke'));
      expect(t.desktop.ask.exchanges.last.fromPhone, isTrue);

      t.desktop.settings.acceptCommands = false;
      t.socket.fromPhone(LinkCommand(id: 'c4', text: 'status', at: now).toValue(), LinkKey.command);
      await settle();
      expect(replies().last.state, 'failed');
    });

    test(
      'Mochi’s approval card goes to the phones too; their Send or Don’t send counts for that card only, while phones may ask',
      () async {
        await paired();
        final rig = BrainRig();
        addTearDown(rig.brain.dispose);
        rig.sessions.apply(hook('UserPromptSubmit', project: 'web', at: rig.clock.now));
        t.desktop.ask.brain = rig.brain;
        rig.brain.phones = t.desktop.phone;
        List<ApprovalRequest?> cards() => [for (final value in t.socket.values(LinkKey.approval)) ApprovalRequest.fromValue(value)];

        await rig.ask('tell web to run the tests', commandId: 'c9');
        var channel = await rig.askToSend();
        await settle();
        final card = cards().last!;
        expect((card.command, card.target, card.project, card.message), ('c9', 'web-ab', 'web', 'Please run the tests.'));
        expect(card.id, rig.brain.approval!.id);

        // Someone else's id, or phones not allowed to ask: nothing happens.
        t.socket.fromPhone(LinkVerdict(id: 'other', allow: true, at: now).toValue(), LinkKey.verdict);
        t.desktop.settings.acceptCommands = false;
        t.socket.fromPhone(LinkVerdict(id: card.id, allow: true, at: now).toValue(), LinkKey.verdict);
        await settle();
        expect(rig.brain.approval, isNotNull);
        t.desktop.settings.acceptCommands = true;
        // The phone says Don't send: denied, and the card is cleared from the phones.
        t.socket.fromPhone(LinkVerdict(id: card.id, allow: false, at: now).toValue(), LinkKey.verdict);
        await settle();
        await rig.settle();
        expect(rig.verdict(channel)['behavior'], 'deny');
        expect(cards().last, isNull);
        rig.process.print(FakeBrainProcess.result('Not sent.'));
        await rig.settle();

        // Next time the phone says Send.
        await rig.ask('again', commandId: 'c10');
        channel = await rig.askToSend(toolUse: 't2');
        await settle();
        final second = cards().last!;
        t.socket.fromPhone(LinkVerdict(id: second.id, allow: true, at: now).toValue(), LinkKey.verdict);
        await settle();
        await rig.settle();
        expect(rig.verdict(channel)['behavior'], 'allow');
        // A late repeat of the same verdict does nothing.
        t.socket.fromPhone(LinkVerdict(id: second.id, allow: false, at: now).toValue(), LinkKey.verdict);
        await settle();
      },
    );

    test('pets from the phone reach Mochi; pets here reach the phones', () async {
      await paired();
      final cues = <PetCue>[];
      t.desktop.cues.listen(cues.add);
      t.socket.fromPhone(LinkInteraction(id: 'i1', kind: 'treat', at: now).toValue(), LinkKey.phoneInteraction);
      t.socket.fromPhone(LinkInteraction(id: 'i2', kind: 'pet', at: now - 200).toValue(), LinkKey.phoneInteraction);
      await settle();
      expect(cues, [PetCue.treat]);
      t.desktop.interact('play');
      final sent = LinkInteraction.fromValue(t.socket.values(LinkKey.macInteraction).single)!;
      expect(sent.kind, 'play');
    });

    test("with summaries shared: Claude's words reach the helper, a summary card and a sealed alert reach the phones", () async {
      await paired(settings: {'shareSummaries': true});
      final paths = t.desktop.paths;
      expect(File(paths.summariesFlagFile).existsSync(), isTrue);
      t.claude.output = FakeClaude.result('{"done": "Fixed the date parsing; all 48 tests pass.", "next": ["Ship it"]}');

      for (final event in [
        hook('UserPromptSubmit'),
        hook('PostToolUse', tool: 'Edit', file: 'utils.ts'),
        hook('Stop', summary: 'All 48 tests pass now. I fixed the date parsing in utils.ts.'),
      ]) {
        expect(await BridgeClient.send(event.encodeLine(), paths.bridgeFile), isA<BridgeAccepted>());
      }
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await settle();

      // The summarizer: Haiku, no tools, with the turn in its prompt.
      final run = t.claude.runs.single;
      expect(run.arguments[run.arguments.indexOf('--tools') + 1], '');
      expect(run.input, contains('Files changed: utils.ts'));
      expect(run.input, contains('All 48 tests pass now.'));

      final session = t.desktop.sessions.registry['s1']!;
      expect(session.summary!.done, 'Fixed the date parsing; all 48 tests pass.');

      final alertFrame = t.socket.sentFrames('send', 'alert').single;
      expect(alertFrame['to'], ['pocket']);
      expect(alertFrame['push'], {'kind': 'alert', 'priority': 10, 'category': 'claude-turn', 'threadId': 's1'});
      final alert = LinkAlert.open({...alertFrame, 'from': hostCredentials.device}, room: hostCredentials.room, roomKey: roomKey)!;
      expect(alert.title, 'web');
      expect(alert.subtitle, 'Claude finished');
      expect(alert.body, 'Fixed the date parsing; all 48 tests pass.');
      expect(alert.userInfo['session'], 's1');
      final card = PhoneSessionCard.fromJson(alert.userInfo['card'])!;
      expect(card.phase, 'done');
      expect(card.files, ['utils.ts']);
      expect(card.summary!.next, ['Ship it']);

      final list = PhoneSessions.fromValue(t.socket.values(LinkKey.sessions).last)!;
      expect(list.enabled, isTrue);
      expect(list.sessions.single.summary!.done, 'Fixed the date parsing; all 48 tests pass.');
      expect(list.updatedAt, isNotNull);
      // Nothing secret goes out in the clear: the frame's readable fields are routing only.
      expect(jsonEncode(alertFrame), isNot(contains('date parsing')));

      t.desktop.settings.shareSummaries = false;
      expect(File(paths.summariesFlagFile).existsSync(), isFalse);
      expect(t.desktop.sessions.registry['s1']!.summary, isNull);
      expect(PhoneSessions.fromValue(t.socket.values(LinkKey.sessions).last)!.enabled, isFalse);
    });

    test('without Claude Code, the summary is the start of Claude\'s own message', () async {
      await paired(settings: {'shareSummaries': true}, claudeInstalled: false);
      t.desktop.phone.record(hook('Stop', summary: 'Done. I renamed the **button** and updated the tests.'));
      await settle();
      final alertFrame = t.socket.sentFrames('send', 'alert').single;
      final alert = LinkAlert.open({...alertFrame, 'from': hostCredentials.device}, room: hostCredentials.room, roomKey: roomKey)!;
      expect(alert.body, 'Done. I renamed the button and updated the tests.');
    });

    test('a test notification goes to the phones, sealed', () async {
      await paired();
      t.desktop.phone.sendTestNotification();
      final frame = t.socket.sentFrames('send', 'alert').single;
      final alert = LinkAlert.open({...frame, 'from': hostCredentials.device}, room: hostCredentials.room, roomKey: roomKey)!;
      expect(alert.title, 'Hello from TEST-PC');
    });
  });

  group('Hook events into the app', () {
    test('live events update the sessions and make Mochi react; spooled ones arrive late and quietly', () async {
      t = TestDesktop.make();
      final paths = t.desktop.paths;
      // While the app was closed, the helper spooled a finished turn.
      EventSpool.append(hook('Stop', session: 'old', project: 'api').encodeLine(), paths.spoolFile);
      final cues = <PetCue>[];
      t.desktop.cues.listen(cues.add);
      await t.desktop.start();
      expect(t.desktop.sessions.registry['old']!.phase.name, 'turnCompleted');
      expect(t.desktop.sessions.lateEvents, 1);
      expect(cues, isEmpty, reason: 'late events never play reactions');

      final hookCli = HookCli(
        environment: {'CLAUDE_PROJECT_DIR': '/code/web'},
        stdinBytes: Stream.value(
          utf8.encode(jsonEncode({'hook_event_name': 'Notification', 'session_id': 'live', 'notification_type': 'permission_prompt'})),
        ),
        out: StringBuffer(),
        err: StringBuffer(),
        paths: paths,
      );
      expect(await hookCli.run(['claude-hook', 'Notification']), 0);
      await settle();
      expect(hookCli.lastOutcome, isA<BridgeAccepted>());
      expect(t.desktop.sessions.registry['live']!.project, 'web');
      expect(cues, [PetCue.needsYou]);
    });

    test('a second copy of the app reports that the bridge is taken', () async {
      t = TestDesktop.make();
      await t.desktop.start();
      final second = TestDesktop.make(home: t.desktop.paths.home);
      await second.desktop.start();
      expect(second.desktop.bridgeProblem.value, contains('already listening'));
      await second.dispose();
    });
  });
}
