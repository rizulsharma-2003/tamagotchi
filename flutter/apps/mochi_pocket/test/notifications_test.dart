// A8: notification buttons (iOS/MochiPocket/PhoneNotifications.swift): which alert gets which button, the payload
// each carries, and what pressing one does, in the app and with the app closed (fakes for the relay and the files).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/model/done_marks.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/services/notify/action_dispatcher.dart';
import 'package:mochi_pocket/src/services/notify/action_outbox.dart';
import 'package:mochi_pocket/src/services/notify/app_actions.dart';
import 'package:mochi_pocket/src/services/notify/background_actions.dart';
import 'package:mochi_pocket/src/services/notify/notification_plan.dart';
import 'package:mochi_pocket/src/services/push/push_messages.dart';
import 'package:mochi_pocket/src/services/push/shown_alerts.dart';

import 'support/fakes.dart';

/// The relay over HTTPS, played by the test: what was posted, opened with the room key.
class FakeRelayPost implements RelayPost {
  final List<String> frames = [];

  /// Thrown by [send] (no connection, or a refusal).
  LinkPairingException? failure;

  /// The room's devices; null: the relay doesn't answer.
  List<LinkPeer>? peers;

  @override
  Future<void> send(String frame, LinkCredentials from) async {
    final failure = this.failure;
    if (failure != null) throw failure;
    frames.add(frame);
  }

  @override
  Future<List<LinkPeer>> devices(LinkCredentials credentials) async => peers ?? (throw const LinkPairingException('no answer'));

  /// (key, value) of each frame, opened as the relay's other devices would.
  List<(String, Object?)> get opened => [
    for (final frame in frames)
      (
        (jsonDecode(frame) as Map)['key']! as String,
        RelayLink.open(frame, phoneCredentials, from: phoneCredentials.device, roomKey: roomKey)?.value,
      ),
  ];
}

const macOnline = LinkPeer(device: 'dev_mac', role: 'host', platform: 'macOS', name: 'BELPL-LT-636', online: true, lastSeen: 1);
const macAway = LinkPeer(device: 'dev_mac', role: 'host', platform: 'macOS', name: 'BELPL-LT-636', lastSeen: 1);

LinkAlert turnAlert() => const LinkAlert(
  id: 'alert-turn',
  from: 'dev_mac',
  title: 'mac-Tamagotchi',
  subtitle: 'Claude finished',
  body: 'Gave Mochi its own voice.',
  userInfo: {'session': 'session-1', 'project': 'mac-Tamagotchi', 'card': <String, Object?>{}},
  category: 'claude-turn',
);

AgentNote item(String id, double at, {String title = 'Someone', AgentSource source = AgentSource.gmail, String? link}) =>
    AgentNote(id: id, source: source, title: title, detail: 'Hi', important: true, at: at, link: link);

LinkAlert agentAlert(List<AgentNote> items, {Map<String, Object?> extra = const {}}) => LinkAlert(
  id: 'alert-agent',
  from: 'dev_mac',
  title: 'New email',
  body: 'Priya: the invoice',
  userInfo: {
    'kind': 'agent',
    'quietIfKnown': true,
    'pending': AgentPending(enabled: true, items: items, lookedAt: 1000, updatedAt: 1001).toJson(),
    ...extra,
  },
  category: 'mochi-agent',
);

void main() {
  group('which buttons an alert gets', () {
    test('"Claude finished" gets Reply, for its session', () {
      final plan = NotificationPlan.forAlert(turnAlert(), room: 'room_1');
      expect(plan.actions, [AlertAction.reply]);
      expect(plan.payload.project, 'mac-Tamagotchi');
      expect(plan.payload.session, 'session-1');
      expect(plan.payload.room, 'room_1');
      expect(plan.payload.title, 'mac-Tamagotchi');
    });

    test("news gets Mark done for what came in with it (the card's newest), never what's already done", () {
      final card = [
        item('mail:new-1', 5000, title: 'Priya'),
        item('mail:new-2', 4990, title: 'Aditi'),
        item('mail:old', 1000, title: 'GitHub'),
        item('mail:done', 5000, title: 'Done already'),
      ];
      final plan = NotificationPlan.forAlert(agentAlert(card), room: 'room_1', isDone: (id) => id == 'mail:done');
      expect(plan.actions, [AlertAction.markDone]);
      expect(plan.payload.ids, ['mail:new-1', 'mail:new-2']);
      expect(plan.payload.names, ['Priya', 'Aditi']);
      expect(NotificationPlan.markDoneTitle(plan.payload.ids.length), 'Mark both done');
      expect(NotificationPlan.markDoneTitle(1), 'Mark done');
      expect(NotificationPlan.markDoneTitle(3), 'Mark all 3 done');
    });

    test('a briefing of more than three things has no Mark done; neither does a card with nothing open', () {
      final briefing = [for (var i = 0; i < 4; i++) item('mail:$i', 5000)];
      expect(NotificationPlan.forAlert(agentAlert(briefing)).actions, isEmpty);
      expect(NotificationPlan.forAlert(agentAlert([item('a', 1)]), isDone: (_) => true).actions, isEmpty);
    });

    test('a meeting heads-up with a video link gets Join, then Mark done; a link that is not https gets no Join', () {
      final meeting = [item('event:review', 5000, title: 'Design review', source: AgentSource.calendar)];
      final plan = NotificationPlan.forAlert(agentAlert(meeting, extra: {'join': 'https://meet.google.com/abc-defg-hij'}));
      expect(plan.actions, [AlertAction.join, AlertAction.markDone]);
      expect(plan.payload.join, 'https://meet.google.com/abc-defg-hij');
      expect(NotificationPlan.forAlert(agentAlert(meeting, extra: {'join': 'javascript:alert(1)'})).actions, [AlertAction.markDone]);
    });

    test('"Reply drafted" gets Open in Gmail with its thread; a plain alert gets nothing', () {
      const drafted = LinkAlert(
        id: 'd1',
        from: 'dev_cloud',
        title: 'Reply drafted',
        userInfo: {'kind': 'draft', 'link': 'https://mail.google.com/mail/#drafts/abc', 'thread': '18c2'},
      );
      final plan = NotificationPlan.forAlert(drafted);
      expect(plan.actions, [AlertAction.openDraft]);
      expect((plan.payload.link, plan.payload.thread), ('https://mail.google.com/mail/#drafts/abc', '18c2'));
      expect(NotificationPlan.forAlert(const LinkAlert(id: 't', from: 'dev_mac', title: 'Hello')).actions, isEmpty);
    });

    test('the payload survives the notification, and the hop between isolates', () {
      final plan = NotificationPlan.forAlert(
        agentAlert([item('mail:a', 1, title: 'Priya')], extra: {'join': 'https://zoom.us/j/1'}),
        room: 'r',
      );
      final decoded = NotificationPayload.decode(plan.payload.encode())!;
      expect((decoded.alert, decoded.room, decoded.join), ('alert-agent', 'r', 'https://zoom.us/j/1'));
      expect(decoded.ids, ['mail:a']);
      expect(decoded.names, ['Priya']);
      expect(NotificationPayload.decode('not json'), isNull);
      expect(NotificationPayload.decode('{"v":1}'), isNull);
      final action = NotificationAction(notificationId: 42, payload: decoded, action: AlertAction.reply, input: 'Run the tests');
      final back = NotificationAction.fromMessage(action.toMessage())!;
      expect((back.notificationId, back.action, back.input), (42, AlertAction.reply, 'Run the tests'));
      expect(back.payload.ids, ['mail:a']);
      expect(AlertAction.parse('open-draft'), AlertAction.openDraft);
      expect(AlertAction.parse('done')?.opensApp, isFalse);
      expect(AlertAction.join.opensApp, isTrue);
    });
  });

  group('pressing a button with Mochi closed', () {
    late FakeRelayPost relay;
    late MemoryDocument done;
    late MemoryDocument outbox;
    late MemoryDocument host;
    late List<ActionReceipt> receipts;
    late ActionDispatcher dispatcher;

    setUp(() {
      relay = FakeRelayPost()..peers = [macOnline];
      done = MemoryDocument();
      outbox = MemoryDocument();
      host = MemoryDocument({'room': 'room_1', 'platform': 'macOS'});
      receipts = [];
      dispatcher = ActionDispatcher(
        state: FileActionState(credentials: MemoryCredentialStore(phoneCredentials), done: done, outbox: outbox, host: host),
        relay: relay,
        receipt: (receipt) async => receipts.add(receipt),
      );
    });

    NotificationAction reply(String text, {String room = 'room_1'}) => NotificationAction(
      notificationId: 7,
      action: AlertAction.reply,
      input: text,
      payload: NotificationPlan.forAlert(turnAlert(), room: room).payload,
    );

    NotificationAction markDone(List<String> ids) => NotificationAction(
      notificationId: 8,
      action: AlertAction.markDone,
      payload: NotificationPayload(alert: 'a', room: 'room_1', ids: ids, names: const ['Priya Sharma']),
    );

    test("Reply sends the session card's command over HTTPS, keeps it for Recently, and says it went", () async {
      expect(await dispatcher.run(reply('  Run the tests  ')), ActionResult.sent);
      final (key, value) = relay.opened.single;
      expect(key, 'command');
      final command = LinkCommand.fromValue(value)!;
      expect((command.text, command.project, command.session, command.typed), ('Run the tests', 'mac-Tamagotchi', 'session-1', true));
      expect(NotificationOutbox.fromJson(outbox.json).sent.single.id, command.id);
      expect(receipts.single.notificationId, 7, reason: 'it replaces the notification');
      expect(receipts.single.failed, isFalse);
      expect(receipts.single.body, 'Sent to Claude in mac-Tamagotchi on your Mac: “Run the tests”');
    });

    test('with the Mac away, the confirmation says Claude gets it when the Mac is back', () async {
      relay.peers = [macAway];
      await dispatcher.run(reply('Push it'));
      expect(receipts.single.body, 'Your Mac is away. Claude in mac-Tamagotchi gets “Push it” when it’s back (within 10 minutes).');
    });

    test('no connection: the reply waits for the app, and the notification says so', () async {
      relay.failure = const LinkPairingException("Couldn't reach the relay.");
      expect(await dispatcher.run(reply('Run the tests')), ActionResult.queued);
      expect(NotificationOutbox.fromJson(outbox.json).queued.single.text, 'Run the tests');
      expect(receipts.single.failed, isTrue);
      expect(receipts.single.title, 'Reply not sent yet');
      expect(receipts.single.body, contains('Open Mochi in the next 10 minutes'));
    });

    test('removed from the room: nothing is kept to send, and it says to pair again', () async {
      relay.failure = const LinkPairingException('The relay said no (unauthorized).', status: 401, code: 'unauthorized');
      expect(await dispatcher.run(reply('Run the tests')), ActionResult.notPaired);
      expect(outbox.json, isNull);
      expect(receipts.single.body, contains('pair again'));
    });

    test('a notification from a room this phone left, or an empty reply, sends nothing', () async {
      expect(await dispatcher.run(reply('Run the tests', room: 'room_old')), ActionResult.notPaired);
      expect(await dispatcher.run(reply('   ')), ActionResult.ignored);
      expect(relay.frames, isEmpty);
    });

    test('Mark done marks it here (with where), shares the whole list as phoneDone, and tells the app', () async {
      done.json = (DoneMarks()..mark(['mail:earlier'], now: now() - 60)).toJson();
      expect(await dispatcher.run(markDone(['mail:18c2'])), ActionResult.sent);
      final marks = DoneMarks.fromJson(done.json);
      expect(marks.doneBy('mail:18c2'), DoneMarks.here);
      final (key, value) = relay.opened.single;
      expect(key, 'phoneDone');
      expect(AgentDoneList.fromValue(value)?.ids.keys, unorderedEquals(['mail:18c2', 'mail:earlier']));
      expect(NotificationOutbox.fromJson(outbox.json).doneChanged, isTrue);
      expect(receipts.single.title, 'Marked done');
      expect(receipts.single.body, 'Priya Sharma. Done on your Mac and your other phones too.');
    });

    test('Mark done with no connection is done here, and shared when Mochi next connects', () async {
      relay.failure = const LinkPairingException("Couldn't reach the relay.");
      expect(await dispatcher.run(markDone(['mail:18c2'])), ActionResult.queued);
      expect(DoneMarks.fromJson(done.json).isDone('mail:18c2'), isTrue);
      expect(NotificationOutbox.fromJson(outbox.json).shareDone, isTrue);
      expect(receipts.single.title, 'Marked done on this phone');
      expect(receipts.single.failed, isFalse);
    });

    test('not paired at all: nothing is marked or sent', () async {
      dispatcher = ActionDispatcher(
        state: FileActionState(credentials: MemoryCredentialStore(), done: done, outbox: outbox, host: host),
        relay: relay,
        receipt: (receipt) async => receipts.add(receipt),
      );
      expect(await dispatcher.run(markDone(['mail:18c2'])), ActionResult.notPaired);
      expect(done.json, isNull);
      expect(relay.frames, isEmpty);
      expect(receipts.single.failed, isTrue);
    });
  });

  group('pressing a button while Mochi runs', () {
    late FakeRelay socket;
    late FakeRelayPost relay;
    late FakeNotifier notifier;
    late FakeOpener opener;
    late PocketModel model;
    late AppNotificationActions actions;

    setUp(() async {
      socket = FakeRelay();
      relay = FakeRelayPost()..peers = [macOnline];
      notifier = FakeNotifier();
      opener = FakeOpener();
      model = PocketModel(
        credentialStore: MemoryCredentialStore(phoneCredentials),
        doneDocument: MemoryDocument(),
        notifier: notifier,
        connect: socket.connect,
      );
      actions = AppNotificationActions(model: model, opener: opener, notifier: notifier, relay: relay);
      await model.load();
      await pumpEventQueue();
      socket.fromMac(LinkKey.agent, sampleAgent().toValue());
      await pumpEventQueue();
    });

    tearDown(() {
      actions.dispose();
      model.dispose();
    });

    test("Reply shows in Recently at once, and the computer's answer lands on it", () async {
      final action = NotificationAction(
        notificationId: 1,
        action: AlertAction.reply,
        input: 'Run the tests',
        payload: NotificationPlan.forAlert(turnAlert(), room: 'room_1').payload,
      );
      expect(await actions.run(action), ActionResult.sent);
      final command = LinkCommand.fromValue(relay.opened.single.$2)!;
      expect(model.exchanges.single.id, command.id);
      expect(model.exchanges.single.project, 'mac-Tamagotchi');
      expect(socket.sentValues(LinkKey.command), isEmpty, reason: 'it went over HTTPS, once');
      socket.fromMac(LinkKey.reply, LinkReply(id: command.id, state: 'done', text: 'Sent to Claude.', at: now()).toValue());
      await pumpEventQueue();
      expect(model.exchanges.single.state, ExchangeState.done);
      expect(notifier.receipts.single.body, startsWith('Sent to Claude in mac-Tamagotchi on your Mac'));
    });

    test('with no connection the reply waits in the link, like a typed one', () async {
      relay.failure = const LinkPairingException("Couldn't reach the relay.");
      final action = NotificationAction(
        notificationId: 1,
        action: AlertAction.reply,
        input: 'Run the tests',
        payload: NotificationPlan.forAlert(turnAlert(), room: 'room_1').payload,
      );
      expect(await actions.run(action), ActionResult.queued);
      expect(LinkCommand.fromValue(socket.sentValues(LinkKey.command).single)?.text, 'Run the tests');
    });

    test("Mark done takes it out of Waiting for you at once and shares the model's list", () async {
      final action = NotificationAction(
        notificationId: 2,
        action: AlertAction.markDone,
        payload: const NotificationPayload(alert: 'a', room: 'room_1', ids: ['mail:18c2'], names: ['Priya Sharma']),
      );
      expect(await actions.run(action), ActionResult.sent);
      expect(model.waiting.map((note) => note.id), ['cal:review']);
      expect(model.doneWhere('mail:18c2'), 'here');
      expect(AgentDoneList.fromValue(relay.opened.single.$2)?.ids.keys, ['mail:18c2']);
    });

    test('Join opens the meeting; a tap on a heads-up does too; a tap on anything else just opens the app', () async {
      const payload = NotificationPayload(alert: 'a', join: 'https://meet.google.com/abc-defg-hij');
      await actions.handle(const NotificationAction(notificationId: 3, action: AlertAction.join, payload: payload));
      await actions.handle(const NotificationAction(notificationId: 3, payload: payload));
      await actions.handle(
        const NotificationAction(
          notificationId: 4,
          action: AlertAction.openDraft,
          payload: NotificationPayload(alert: 'd', link: 'https://mail.google.com/x'),
        ),
      );
      await actions.handle(const NotificationAction(notificationId: 5, payload: NotificationPayload(alert: 'plain')));
      expect(opener.opened, ['https://meet.google.com/abc-defg-hij', 'https://meet.google.com/abc-defg-hij', 'https://mail.google.com/x']);
    });

    test('the background isolate hands Reply and Mark done to the running app through a named port', () async {
      final taken = <NotificationAction>[];
      final port = ActionInbox.open(taken.add);
      addTearDown(() => ActionInbox.close(port));
      const action = NotificationAction(
        notificationId: 9,
        action: AlertAction.markDone,
        payload: NotificationPayload(alert: 'a', room: 'room_1', ids: ['mail:18c2']),
      );
      expect(await ActionInbox.forward(action), isTrue);
      await pumpEventQueue();
      expect(taken.single.payload.ids, ['mail:18c2']);
      ActionInbox.close(port);
      expect(
        await ActionInbox.forward(action, wait: const Duration(milliseconds: 50)),
        isFalse,
        reason: 'no app: handled in the background',
      );
    });
  });

  group('pushes', () {
    test("a news push is shown with Mark done, the push's category is kept, and its card joins the history", () async {
      final notifier = FakeNotifier();
      final recorded = <String>[];
      final card = AgentPending(
        enabled: true,
        items: [item('mail:18c2', now(), title: 'Priya')],
        updatedAt: now(),
      );
      final data = alertPush('p1', {
        'title': 'New email',
        'body': 'Priya: the invoice',
        'userInfo': {'kind': 'agent', 'pending': card.toJson()},
      })..['category'] = 'mochi-agent';
      final outcome = await PushMessages.handle(
        data,
        credentials: () async => phoneCredentials,
        notifier: notifier,
        shown: MemoryShownAlerts(),
        isDone: (_) => false,
        record: (notes) async => recorded.addAll(notes.map((note) => note.id)),
      );
      expect(outcome, PushOutcome.shown);
      expect(notifier.shown.single.category, 'mochi-agent');
      expect(notifier.plans.single?.actions, [AlertAction.markDone]);
      expect(notifier.plans.single?.payload.room, 'room_1');
      expect(recorded, ['mail:18c2']);
    });

    test('an alert on the socket gets its buttons too', () async {
      final socket = FakeRelay();
      final notifier = FakeNotifier();
      final model = PocketModel(
        credentialStore: MemoryCredentialStore(phoneCredentials),
        doneDocument: MemoryDocument(),
        historyDocument: MemoryDocument(),
        notifier: notifier,
        connect: socket.connect,
      );
      addTearDown(model.dispose);
      await model.load();
      await pumpEventQueue();
      socket.alert({'title': 'mac-Tamagotchi', 'subtitle': 'Claude finished', 'body': 'Done.', 'userInfo': turnAlert().userInfo});
      await pumpEventQueue();
      expect(notifier.plans.single?.actions, [AlertAction.reply]);
      expect(notifier.plans.single?.payload.session, 'session-1');
    });
  });
}
