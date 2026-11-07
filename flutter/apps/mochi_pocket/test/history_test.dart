// A6: the week of "Waiting for you" (iOS/MochiPocket/UpdatesStore.swift): recording, grouping by day, keeping a week,
// persisting (also from the push handler's isolate), and where each done mark was made.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/model/done_marks.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/model/updates_history.dart';
import 'package:mochi_pocket/src/screens/updates_screen.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/services/notify/action_outbox.dart';

import 'support/fakes.dart';

/// Unix seconds for a local time.
double at(int year, int month, int day, [int hour = 12, int minute = 0]) =>
    DateTime(year, month, day, hour, minute).millisecondsSinceEpoch / 1000;

AgentNote note(String id, {String title = 'Someone', double at = 0, AgentSource source = AgentSource.gmail, String detail = 'Hello'}) =>
    AgentNote(id: id, source: source, title: title, detail: detail, important: false, at: at);

void main() {
  group('UpdatesHistory', () {
    test('new items join with when they first came in; known ones take their latest words and keep that time', () {
      final history = UpdatesHistory();
      final nine = at(2026, 11, 7, 9);
      expect(history.record([note('mail:a'), note('mail:b')], now: nine), isTrue);
      expect(history.record([note('mail:a'), note('mail:b')], now: nine + 60), isFalse, reason: 'nothing new');
      expect(
        history.record([note('mail:a', detail: 'Now with the invoice'), note('cal:c', source: AgentSource.calendar)], now: nine + 120),
        isTrue,
      );
      expect(history.entries.map((entry) => entry.id), ['cal:c', 'mail:a', 'mail:b'], reason: 'newest first');
      expect(history['mail:a']!.note.detail, 'Now with the invoice');
      expect(history['mail:a']!.firstSeen, nine);
      expect(history['cal:c']!.firstSeen, nine + 120);
    });

    test('grouped by local day, newest day first and newest first within a day, leaving out what is waiting now', () {
      final history = UpdatesHistory();
      history.record([note('mon-1')], now: at(2026, 11, 2, 8));
      history.record([note('wed-1')], now: at(2026, 11, 4, 9));
      history.record([note('wed-2')], now: at(2026, 11, 4, 23, 59));
      history.record([note('fri-1')], now: at(2026, 11, 6, 0, 1));
      history.record([note('sat-1'), note('sat-waiting')], now: at(2026, 11, 7, 10));
      final days = history.days(excluding: {'sat-waiting'});
      expect(
        [for (final day in days) day.day],
        [DateTime(2026, 11, 7), DateTime(2026, 11, 6), DateTime(2026, 11, 4), DateTime(2026, 11, 2)],
      );
      expect(
        [for (final day in days) day.entries.map((entry) => entry.id).toList()],
        [
          ['sat-1'],
          ['fri-1'],
          ['wed-2', 'wed-1'],
          ['mon-1'],
        ],
      );
      expect(history.days(excluding: {'sat-1', 'sat-waiting'}).first.day, DateTime(2026, 11, 6), reason: 'a day with nothing left goes');
    });

    test('keeps a week and at most 300 items', () {
      final history = UpdatesHistory();
      final now = at(2026, 11, 7);
      history.record([note('old')], now: now - 7 * 86400 - 1);
      history.record([note('six-days')], now: now - 6 * 86400);
      history.record([note('today')], now: now);
      expect(history.entries.map((entry) => entry.id), ['today', 'six-days']);
      for (var i = 0; i < 320; i++) {
        history.record([note('n$i')], now: now + i);
      }
      expect(history.entries, hasLength(UpdatesHistory.maxEntries));
      expect(history.entries.first.id, 'n319');
      expect(history['six-days'], isNull, reason: 'the oldest go first');
    });

    test('survives JSON; a damaged entry is skipped; a merge keeps the earliest sighting', () {
      final history = UpdatesHistory()..record([note('a', title: 'Priya'), note('b')], now: 1000);
      final copy = UpdatesHistory.fromJson({
        ...history.toJson(),
        'entries': [
          ...(history.toJson()['entries']! as List),
          {'note': 'broken'},
        ],
      });
      expect(copy.entries.map((entry) => (entry.id, entry.firstSeen, entry.note.title)), [
        ('a', 1000.0, 'Priya'),
        ('b', 1000.0, 'Someone'),
      ]);
      final other = UpdatesHistory()..record([note('a', title: 'Old words'), note('c')], now: 900);
      expect(copy.merge(other, now: 2000), isTrue);
      expect(copy['a']!.firstSeen, 900);
      expect(copy['a']!.note.title, 'Priya', reason: "this copy's words stay");
      expect(copy['c'], isNotNull);
      expect(copy.merge(other, now: 2000), isFalse);
    });

    test('recordHistory adds a card to the file, as the push handler does while the app is closed', () async {
      final document = MemoryDocument();
      await recordHistory(document, [note('mail:a')], now: DateTime(2026, 11, 7, 9));
      await recordHistory(document, [note('mail:a'), note('mail:b')], now: DateTime(2026, 11, 7, 10));
      final saved = UpdatesHistory.fromJson(document.json);
      expect(saved.entries.map((entry) => (entry.id, timeOf(entry.firstSeen).hour)), [('mail:b', 10), ('mail:a', 9)]);
    });
  });

  testWidgets("day headings are the iPhone's: Earlier today, Yesterday, then the weekday and date", (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );
    final now = DateTime(2026, 11, 7, 18);
    expect(dayTitle(context, DateTime(2026, 11, 7), now: now), 'Earlier today');
    expect(dayTitle(context, DateTime(2026, 11, 6), now: now), 'Yesterday');
    expect(dayTitle(context, DateTime(2026, 11, 4), now: now), 'Wednesday, 4 Nov');
    expect(dayTitle(context, DateTime(2026, 11, 1), now: DateTime(2026, 11, 2, 0, 30)), 'Yesterday');
    expect(dayTitle(context, DateTime(2026, 10, 31), now: DateTime(2026, 11, 1, 9)), 'Yesterday', reason: 'across a month');
  });

  group('DoneMarks remember where each mark was made', () {
    test('here, on the computer, or on another phone; kept in JSON; older files without it still load', () {
      final marks = DoneMarks();
      expect(marks.mark(['a'], now: 100), isTrue);
      expect(marks.mark(['a'], now: 200), isFalse);
      marks.takeIn(const AgentDoneList(ids: {'b': 150}), now: 300, from: DoneMarks.computer);
      marks.takeIn(const AgentDoneList(ids: {'c': 160, 'a': 170}), now: 300, from: 'dev_iphone');
      expect([marks.doneBy('a'), marks.doneBy('b'), marks.doneBy('c')], [DoneMarks.here, DoneMarks.computer, 'dev_iphone']);
      expect(marks.doneAt('a'), 100, reason: 'the first mark keeps its time');
      final copy = DoneMarks.fromJson(marks.toJson());
      expect(copy.by, marks.by);
      expect(
        DoneMarks.fromJson({
          'done': {'x': 1},
        }).doneBy('x'),
        isNull,
      );
      copy.unmark('b');
      expect(copy.doneBy('b'), isNull);
    });

    test("a mark made here and undone isn't brought back by the computer's list", () {
      final marks = DoneMarks()..mark(['a'], now: 100);
      marks.unmark('a');
      expect(marks.takeIn(const AgentDoneList(ids: {'a': 100}), now: 200, from: DoneMarks.computer), isFalse);
      expect(marks.isDone('a'), isFalse);
    });
  });

  group('the model', () {
    late FakeRelay relay;
    late MemoryDocument historyDocument;
    late MemoryDocument doneDocument;
    late MemoryDocument outboxDocument;
    late PocketModel model;

    PocketModel makeModel() => PocketModel(
      credentialStore: MemoryCredentialStore(phoneCredentials),
      doneDocument: doneDocument,
      historyDocument: historyDocument,
      outboxDocument: outboxDocument,
      notifier: FakeNotifier(),
      connect: relay.connect,
    );

    setUp(() {
      relay = FakeRelay();
      historyDocument = MemoryDocument();
      doneDocument = MemoryDocument();
      outboxDocument = MemoryDocument();
      model = makeModel();
    });

    tearDown(() => model.dispose());

    test("records every card from the computer, saves it, and lists earlier days under what's waiting", () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch / 1000;
      historyDocument.json = (UpdatesHistory()..record([note('mail:old', title: 'GitHub')], now: yesterday)).toJson();
      await model.load();
      await pumpEventQueue();
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      await pumpEventQueue();
      expect(model.history.entries.map((entry) => entry.id), containsAll(['mail:18c2', 'cal:review', 'mail:old']));
      expect(UpdatesHistory.fromJson(historyDocument.json).entries, hasLength(3), reason: 'saved');
      expect(model.historyDays.expand((day) => day.entries).map((entry) => entry.id), ['mail:old'], reason: 'waiting ones stay above');
      model.markDone(['mail:18c2']);
      await pumpEventQueue();
      expect(model.historyDays.first.entries.single.id, 'mail:18c2', reason: 'done today, so under Earlier today');
      expect(model.doneWhere('mail:18c2'), 'here');
      model.dispose();
      model = makeModel();
      await model.load();
      expect(model.history.entries, hasLength(3), reason: 'it survives a restart');
    });

    test('says where a mark was made: here, on your Mac, or on the other phone by name', () async {
      await model.load();
      await pumpEventQueue();
      relay.devices();
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      relay.fromMac(LinkKey.macDone, AgentDoneList(ids: {'cal:review': now()}).toValue());
      relay.socket.deliver(
        RelayLinkFrames.fromDevice(LinkKey.phoneDone, AgentDoneList(ids: {'mail:18c2': now()}).toValue(), device: 'dev_iphone'),
      );
      await pumpEventQueue();
      expect(model.doneWhere('cal:review'), 'on your Mac');
      expect(model.doneWhere('mail:18c2'), 'on iPhone');
      expect(model.waiting, isEmpty);
    });

    test('a card that rides on an alert joins the history too', () async {
      await model.load();
      await pumpEventQueue();
      relay.alert({
        'title': 'New email',
        'body': 'Priya: the invoice',
        'userInfo': {'kind': 'agent', 'pending': sampleAgent().toJson()},
      });
      await pumpEventQueue();
      expect(model.history.entries.map((entry) => entry.id), containsAll(['mail:18c2', 'cal:review']));
    });

    test('takes in what notification buttons left while it was closed', () async {
      final fresh = LinkCommand(
        id: 'c-fresh',
        text: 'Run the tests',
        at: now() - 30,
        typed: true,
        project: 'mac-Tamagotchi',
        session: 's1',
      );
      final queued = LinkCommand(id: 'c-queued', text: 'Push it', at: now() - 60, typed: true, project: 'mac-Tamagotchi', session: 's1');
      final stale = LinkCommand(id: 'c-stale', text: 'Too late', at: now() - 3600, typed: true, project: 'mac-Tamagotchi', session: 's1');
      doneDocument.json = (DoneMarks()..mark(['mail:18c2'], now: now())).toJson();
      outboxDocument.json = NotificationOutbox(sent: [fresh], queued: [queued, stale], doneChanged: true).toJson();
      await model.load();
      await pumpEventQueue();
      expect(model.exchanges.map((exchange) => exchange.id), ['c-fresh', 'c-queued', 'c-stale']);
      expect(model.exchanges.last.state, ExchangeState.failed);
      expect(LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)?.id, 'c-queued', reason: 'the fresh queued reply goes now');
      expect(AgentDoneList.fromValue(relay.sentValues(LinkKey.phoneDone).last)?.ids.keys, ['mail:18c2'], reason: 'shared');
      expect(outboxDocument.json, isNull, reason: 'taken');
      // The computer's answer finds the reply sent from the notification.
      relay.fromMac(LinkKey.reply, LinkReply(id: 'c-fresh', state: 'done', text: 'Tests pass.', at: now()).toValue());
      await pumpEventQueue();
      expect(model.exchanges.first.state, ExchangeState.done);
      expect(model.exchanges.first.reply, 'Tests pass.');
    });
  });
}

/// Frames from devices other than the fake Mac.
abstract final class RelayLinkFrames {
  static Map<String, Object?> fromDevice(LinkKey key, Object? value, {required String device}) {
    final credentials = LinkCredentials(
      relay: 'relay.test',
      room: 'room_1',
      device: device,
      secret: 's',
      key: LinkCrypto.base64url(roomKey),
      role: 'pocket',
    );
    final frame = RelayLinkFrames._decode(RelayLink.frame(value, key, credentials, roomKey, id: 'frame-$device-${key.name}'));
    return {...frame, 'from': device};
  }

  static Map<String, Object?> _decode(String text) => (jsonDecode(text) as Map).cast<String, Object?>();
}
