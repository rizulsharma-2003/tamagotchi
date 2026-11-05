import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';

import 'support/fakes.dart';

void main() {
  late FakeRelay relay;
  late FakeNotifier notifier;
  late MemoryCredentialStore store;
  late MemoryDocument doneDocument;
  late List<(PairingCode, String)> joins;
  late List<LinkCredentials> leaves;
  late PocketModel model;
  late List<PetCue> cues;

  PocketModel makeModel({Future<LinkCredentials> Function(PairingCode code, String name)? join}) {
    final made = PocketModel(
      credentialStore: store,
      doneDocument: doneDocument,
      notifier: notifier,
      connect: relay.connect,
      join:
          join ??
          (code, name) async {
            joins.add((code, name));
            return phoneCredentials;
          },
      leave: (credentials) async => leaves.add(credentials),
      deviceName: 'realme RMX3242',
    );
    made.cues.listen(cues.add);
    return made;
  }

  /// Loads with a saved pairing and lets the socket open.
  Future<void> paired() async {
    store.saved = phoneCredentials;
    await model.load();
    await pumpEventQueue();
  }

  setUp(() {
    relay = FakeRelay();
    notifier = FakeNotifier();
    store = MemoryCredentialStore();
    doneDocument = MemoryDocument();
    joins = [];
    leaves = [];
    cues = [];
    model = makeModel();
  });

  tearDown(() => model.dispose());

  group('pairing', () {
    test('without a saved pairing the app asks to pair, and connects to nothing', () async {
      expect(model.phase, PairingPhase.loading);
      await model.load();
      expect(model.phase, PairingPhase.unpaired);
      expect(relay.sockets, isEmpty);
    });

    test('a saved pairing reconnects at launch with its own credential', () async {
      await paired();
      expect(model.phase, PairingPhase.paired);
      expect(model.macName, 'Test Mac');
      expect(relay.socket.url.toString(), 'wss://relay.test/v1/rooms/room_1/socket');
      expect(relay.socket.headers['authorization'], 'Bearer dev_phone.phone-secret');
      expect(relay.socket.sent.first['op'], 'hello');
      expect(relay.socket.sent.first['platform'], 'android');
    });

    test('a pairing link joins as this phone, keeps the credentials and connects', () async {
      await model.load();
      expect(await model.pair(pairingCode.url), isTrue);
      expect(joins.single.$1, pairingCode);
      expect(joins.single.$2, 'realme RMX3242');
      expect(store.saved, phoneCredentials);
      expect(model.phase, PairingPhase.paired);
      await pumpEventQueue();
      expect(relay.sockets, hasLength(1));
    });

    test("text that isn't a pairing link is refused with a hint, and nothing is joined", () async {
      await model.load();
      expect(await model.pair('https://example.com'), isFalse);
      expect(model.problem, contains('Pair Another Device'));
      expect(joins, isEmpty);
      expect(model.phase, PairingPhase.unpaired);
    });

    test("a used or expired code says what to do; the relay's other refusals pass through", () async {
      model.dispose();
      var code = 'invite_used';
      model = makeModel(join: (_, _) async => throw LinkPairingException('The relay said no ($code).', status: 409, code: code));
      await model.load();
      expect(await model.pair(pairingCode.url), isFalse);
      expect(model.problem, contains('already used'));
      code = 'invite_expired';
      await model.pair(pairingCode.url);
      expect(model.problem, contains('expired'));
      code = 'weird';
      await model.pair(pairingCode.url);
      expect(model.problem, 'The relay said no (weird).');
      expect(model.phase, PairingPhase.unpaired);
      expect(store.saved, isNull);
    });

    test('the same link opened again (Android redelivers it) is a no-op', () async {
      await paired();
      expect(await model.pair(pairingCode.url), isTrue);
      expect(joins, isEmpty);
    });

    test('unpairing leaves the room, forgets the credentials and the done marks, and stops the link', () async {
      await paired();
      model.markDone(['mail:1']);
      await pumpEventQueue();
      expect(doneDocument.json, isNotNull);
      await model.unpair();
      expect(model.phase, PairingPhase.unpaired);
      expect(store.saved, isNull);
      expect(doneDocument.json, isNull);
      expect(leaves.single.device, 'dev_phone');
      expect(relay.socket.closed, isTrue);
      expect(model.isDone('mail:1'), isFalse);
    });

    test('a deleted room (4004) ends the link; unpairing then only forgets locally', () async {
      await paired();
      relay.socket.drop(4004);
      await pumpEventQueue();
      expect(model.connection, MacConnection.removed);
      await model.unpair();
      expect(leaves, isEmpty);
      expect(store.saved, isNull);
    });
  });

  group('what the Mac shares', () {
    test('look, Claude, sessions and what is waiting are read as they arrive', () async {
      await paired();
      expect(model.petName, 'Mochi');
      relay.fromMac(LinkKey.look, sampleLook(petName: 'Momo').toValue());
      relay.fromMac(LinkKey.claude, const ClaudeMirror(phase: 'working', category: 'edit').toValue());
      relay.fromMac(LinkKey.sessions, sampleSessions().toValue());
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      await pumpEventQueue();
      expect(model.petName, 'Momo');
      expect(model.companionName, 'Patch');
      expect(model.friendshipLevel, 3);
      expect(model.claude?.phase, 'working');
      expect(model.claude?.category, 'edit');
      expect(model.summariesShared, isTrue);
      expect(model.sessions.single.project, 'mac-Tamagotchi');
      expect(model.waiting.map((note) => note.id), ['mail:18c2', 'cal:review']);
    });

    test('summaries turned off on the Mac: no sessions, and the app can say so', () async {
      await paired();
      expect(model.summariesShared, isNull);
      relay.fromMac(LinkKey.sessions, const PhoneSessions(enabled: false).toValue());
      await pumpEventQueue();
      expect(model.summariesShared, isFalse);
      expect(model.sessions, isEmpty);
    });

    test('presence: the Mac online, then away since a time', () async {
      await paired();
      expect(model.connection, MacConnection.macAway);
      relay.presence(macOnline: true);
      await pumpEventQueue();
      expect(model.macOnline, isTrue);
      expect(model.connection, MacConnection.macOnline);
      relay.presence(macOnline: false, lastSeen: 1762243200);
      await pumpEventQueue();
      expect(model.connection, MacConnection.macAway);
      expect(model.mac?.lastSeen, 1762243200);
    });

    test("the Mac's alerts become notifications", () async {
      await paired();
      relay.alert({
        'title': 'Claude finished',
        'body': 'mac-Tamagotchi: tests pass.',
        'userInfo': {'card': 'session-1'},
      });
      await pumpEventQueue();
      expect(notifier.shown.single.title, 'Claude finished');
      expect(notifier.shown.single.body, 'mac-Tamagotchi: tests pass.');
      expect(model.lastAlertAt, isNotNull);
    });

    test("a pet, play or treat from the Mac plays here once; an old one doesn't", () async {
      await paired();
      relay.fromMac(LinkKey.macInteraction, LinkInteraction(id: 'i1', kind: 'play', at: now()).toValue());
      relay.fromMac(LinkKey.macInteraction, LinkInteraction(id: 'i2', kind: 'treat', at: now() - 300).toValue());
      await pumpEventQueue();
      expect(cues, [PetCue.play]);
    });
  });

  group('what you send', () {
    test('a typed request goes to the Mac as a command; its replies update Recently', () async {
      await paired();
      final id = model.send('  Water the plants  ')!;
      final command = LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)!;
      expect(command.id, id);
      expect(command.text, 'Water the plants');
      expect(command.typed, isTrue);
      expect(command.project, isNull);
      expect(model.exchanges.single.state, ExchangeState.sending);
      relay.fromMac(LinkKey.reply, LinkReply(id: id, state: 'working', at: now()).toValue());
      await pumpEventQueue();
      expect(model.exchanges.single.state, ExchangeState.working);
      relay.fromMac(LinkKey.reply, LinkReply(id: id, state: 'done', text: 'Watered.', at: now()).toValue());
      await pumpEventQueue();
      expect(model.exchanges.single.state, ExchangeState.done);
      expect(model.exchanges.single.reply, 'Watered.');
      expect(cues, [PetCue.sending, PetCue.working, PetCue.replied]);
    });

    test('a reply to a session carries its project and session; empty text sends nothing', () async {
      await paired();
      expect(model.send('   '), isNull);
      model.send('Push it', project: 'mac-Tamagotchi', session: 'session-1');
      final command = LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)!;
      expect(command.project, 'mac-Tamagotchi');
      expect(command.session, 'session-1');
      expect(model.exchanges.single.project, 'mac-Tamagotchi');
    });

    test('Recently keeps the last six; a failed reply says so', () async {
      await paired();
      final ids = [for (var i = 0; i < 8; i++) model.send('request $i')!];
      expect(model.exchanges, hasLength(6));
      expect(model.exchanges.first.text, 'request 2');
      relay.fromMac(LinkKey.reply, LinkReply(id: ids.last, state: 'failed', at: now()).toValue());
      await pumpEventQueue();
      expect(model.exchanges.last.state, ExchangeState.failed);
    });

    test('while offline, a command waits in the outbox and goes once connected', () async {
      final id = model.send('early');
      expect(id, isNull, reason: 'nothing to send to before pairing');
      await paired();
      relay.socket.drop(1006);
      await pumpEventQueue();
      model.send('while away');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await pumpEventQueue();
      expect(relay.sockets, hasLength(2));
      expect(LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)?.text, 'while away');
    });

    test('pet, play and treat go to the Mac and play here', () async {
      await paired();
      model.interact('pet');
      model.interact('treat');
      await pumpEventQueue();
      expect([for (final value in relay.sentValues(LinkKey.phoneInteraction)) LinkInteraction.fromValue(value)?.kind], ['pet', 'treat']);
      expect(cues, [PetCue.pet, PetCue.treat]);
    });

    test("approvals: a fresh one shows, the answer goes back as a verdict, and it doesn't come back", () async {
      await paired();
      final request = ApprovalRequest(
        id: 'approval-1',
        target: 'session-1',
        project: 'mac-Tamagotchi',
        message: 'Run the tests.',
        at: now(),
      );
      relay.fromMac(LinkKey.approval, request.toValue());
      await pumpEventQueue();
      expect(model.approval?.message, 'Run the tests.');
      model.answer(model.approval!, allow: true);
      expect(model.approval, isNull);
      final verdict = LinkVerdict.fromValue(relay.sentValues(LinkKey.verdict).single)!;
      expect(verdict.id, 'approval-1');
      expect(verdict.allow, isTrue);
      relay.fromMac(LinkKey.claude, const ClaudeMirror(phase: 'working').toValue());
      await pumpEventQueue();
      expect(model.approval, isNull, reason: 'answered ones stay answered');
    });

    test('an approval more than two minutes old is not shown', () async {
      await paired();
      relay.fromMac(LinkKey.approval, ApprovalRequest(id: 'old', target: 's', message: 'm', at: now() - 600).toValue());
      await pumpEventQueue();
      expect(model.approval, isNull);
    });
  });

  group('done marks', () {
    test('marking done shares phoneDone, persists, and takes the item out of Waiting for you', () async {
      await paired();
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      await pumpEventQueue();
      model.markDone(['mail:18c2']);
      await pumpEventQueue();
      expect(model.waiting.map((note) => note.id), ['cal:review']);
      expect(AgentDoneList.fromValue(relay.sentValues(LinkKey.phoneDone).last)?.ids.keys, ['mail:18c2']);
      expect((doneDocument.json?['done'] as Map?)?.keys, ['mail:18c2']);
      model.markNotDone('mail:18c2');
      expect(model.waiting, hasLength(2));
      expect(AgentDoneList.fromValue(relay.sentValues(LinkKey.phoneDone).last)?.ids, isEmpty);
    });

    test("the Mac's and other phones' marks are taken in once, so undoing one here sticks", () async {
      await paired();
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      relay.fromMac(LinkKey.macDone, AgentDoneList(ids: {'cal:review': now()}).toValue());
      await pumpEventQueue();
      expect(model.isDone('cal:review'), isTrue);
      model.markNotDone('cal:review');
      relay.fromMac(LinkKey.macDone, AgentDoneList(ids: {'cal:review': now()}).toValue());
      await pumpEventQueue();
      expect(model.isDone('cal:review'), isFalse);
    });

    test('done marks survive a restart', () async {
      await paired();
      model.markDone(['mail:18c2']);
      await pumpEventQueue();
      model.dispose();
      model = makeModel();
      await paired();
      expect(model.isDone('mail:18c2'), isTrue);
    });
  });

  test('resume reconnects right away after the socket dropped', () async {
    model.dispose();
    model = PocketModel(
      credentialStore: store,
      doneDocument: doneDocument,
      notifier: notifier,
      connect: (credentials) => RelayLink(
        credentials,
        connect: (url, headers) {
          final socket = FakeSocket(url, headers);
          relay.sockets.add(socket);
          return socket;
        },
        backoff: (_) => const Duration(hours: 1),
      ),
    );
    await paired();
    relay.socket.drop(1006);
    await pumpEventQueue();
    expect(relay.sockets, hasLength(1));
    model.resume();
    await pumpEventQueue();
    expect(relay.sockets, hasLength(2));
    expect(model.status, LinkStatus.online);
  });
}
