import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/live/live_push.dart';
import 'package:mochi_pocket/src/live/live_update_view.dart';
import 'package:mochi_pocket/src/live/live_updates.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';

import 'support/fakes.dart';

/// Mochi on the lock screen while Claude works (A1): what the notification says per phase, how updates are shown once
/// and in order whichever way they come, how it ends, and the computer's sealed text opening with K_la.
void main() {
  final mac = LinkHostName(platform: LinkPlatform.macOS, name: 'BELPL-LT-636');
  const t0 = 1793800000;
  final at = DateTime.fromMillisecondsSinceEpoch(t0 * 1000);

  LinkLiveActivity read(Map<String, Object?> apns, {String id = ''}) =>
      LinkLiveActivity.fromApns(apns, liveActivityKey: liveActivityKey, id: id)!;

  group('what it says, per phase', () {
    test('working: the timer, ongoing and quiet, Open, Mochi working; no detail says where', () {
      final view = LiveUpdateView.of(
        read(macLiveActivity('start', 'working', timestamp: t0, since: t0 - 95, frame: 4)),
        host: mac,
        now: at,
      );
      expect([view.title, view.text, view.art, view.frame], ['Claude is working', 'On your Mac', 'working', 4]);
      expect([view.ongoing, view.chronometer, view.alert, view.chip], [true, true, false, null]);
      expect(view.sinceMs, (t0 - 95) * 1000);
      expect(view.timeoutMs, LiveUpdateView.workingTimeout.inMilliseconds);
      expect(view.actions, ['open']);
      final pc = LiveUpdateView.of(
        read(macLiveActivity('update', 'working', timestamp: t0)),
        host: LinkHostName(platform: LinkPlatform.windows),
        now: at,
      );
      expect(pc.text, 'On your PC');
    });

    test('the detail the computer shares is the text', () {
      final view = LiveUpdateView.of(
        read(macLiveActivity('update', 'working', timestamp: t0, detail: 'web · 3 tools')),
        host: mac,
        now: at,
      );
      expect(view.text, 'web · 3 tools');
    });

    test('Claude needs you: lights up with a sound, the timer, Needs you, and Open the Session', () {
      final view = LiveUpdateView.of(
        read(macLiveActivity('update', 'waiting', timestamp: t0, alert: true)),
        host: mac,
        now: at,
      );
      expect([view.title, view.alert, view.chronometer, view.chip], ['Claude needs you', true, true, 'Needs you']);
      expect(view.actions, ['open', 'session']);
      expect(view.timeoutMs, LiveUpdateView.waitingTimeout.inMilliseconds);
      // Without the alert (a quiet update about the same wait), no sound.
      expect(
        LiveUpdateView.of(
          read(macLiveActivity('update', 'waiting', timestamp: t0)),
          host: mac,
          now: at,
        ).alert,
        isFalse,
      );
    });

    test('done, a snag, idle and napping: no timer, their chip, quiet; an unknown phase draws as idle', () {
      for (final (phase, chip) in [('done', 'Done'), ('error', 'Snag'), ('idle', 'Idle'), ('asleep', 'Napping')]) {
        final view = LiveUpdateView.of(
          read(macLiveActivity('update', phase, timestamp: t0, alert: true)),
          host: mac,
          now: at,
        );
        expect([view.art, view.chronometer, view.chip, view.alert], [phase, false, chip, false], reason: phase);
        expect(view.timeoutMs, LiveUpdateView.restingTimeout.inMilliseconds);
        expect(view.actions, ['open']);
      }
      expect(
        LiveUpdateView.of(
          read(macLiveActivity('update', 'dancing', timestamp: t0)),
          host: mac,
          now: at,
        ).art,
        'idle',
      );
    });

    test('ended: not ongoing, no timer or chip, gone at the dismissal time', () {
      final view = LiveUpdateView.of(
        read(macLiveActivity('end', 'done', timestamp: t0, dismissalDate: t0 + 180.0)),
        host: mac,
        now: at.add(const Duration(seconds: 10)),
      );
      expect([view.ongoing, view.chronometer, view.chip, view.alert], [false, false, null, false]);
      expect(view.timeoutMs, 170 * 1000);
      expect(view.actions, ['open']);
    });

    test('a title that won\'t open shows the placeholder (the pet\'s name)', () {
      final apns = macLiveActivity('update', 'working', timestamp: t0, key: LinkCrypto.liveActivityKey(LinkCrypto.newRoomKey()));
      final view = LiveUpdateView.of(read(apns), host: mac, now: at);
      expect(view.title, 'Mochi');
    });

    test('the map for the plugin round-trips', () {
      final view = LiveUpdateView.of(
        read(macLiveActivity('update', 'waiting', timestamp: t0, alert: true)),
        host: mac,
        now: at,
      );
      final again = LiveUpdateView.fromMap(jsonDecode(jsonEncode(view.toMap())) as Map<String, Object?>)!;
      expect(again.toMap(), view.toMap());
      expect(LiveUpdateView.fromMap({'title': 1}), isNull);
    });

    test("Settings' sample: two minutes, whatever came before", () {
      final sample = LiveUpdateView.sample('waiting', host: mac, now: at);
      expect([sample.title, sample.force, sample.chip, sample.timeoutMs], ['Claude needs you', true, 'Needs you', 120000]);
    });
  });

  group('showing it once, in order', () {
    late FakeLiveNotifier notifier;
    late MemoryDocument record;
    late bool enabled;
    late DateTime clock;
    late LiveUpdates live;

    setUp(() {
      notifier = FakeLiveNotifier();
      record = MemoryDocument();
      enabled = true;
      clock = at;
      live = LiveUpdates(notifier: notifier, record: record, enabled: () async => enabled, clock: () => clock);
    });

    Future<LiveOutcome> handle(Map<String, Object?> apns, {String? id}) =>
        live.handle(read(apns, id: id ?? 'la-${apns['timestamp']}-${apns['event']}'), host: mac);

    test('a start shows it, updates replace it in place, and a repeat or an older one is dropped', () async {
      expect(await handle(macLiveActivity('start', 'working', timestamp: t0, since: t0)), LiveOutcome.shown);
      expect(await handle(macLiveActivity('update', 'working', timestamp: t0 + 6, since: t0, frame: 1)), LiveOutcome.shown);
      // The same update again (socket, then push), and an older one arriving late.
      expect(
        await handle(
          macLiveActivity('update', 'working', timestamp: t0 + 6, since: t0, frame: 1),
          id: 'la-x',
        ),
        LiveOutcome.duplicate,
      );
      expect(
        await handle(
          macLiveActivity('update', 'working', timestamp: t0 + 6, since: t0),
          id: 'la-${t0 + 6}-update',
        ),
        LiveOutcome.duplicate,
      );
      expect(await handle(macLiveActivity('update', 'working', timestamp: t0 + 3, since: t0)), LiveOutcome.duplicate);
      expect(notifier.shown.map((view) => view.frame), [0, 1]);
      expect(LiveRecord.fromJson(record.json).timestamp, t0 + 6);
    });

    test('an update from more than ten minutes ago is history', () async {
      clock = at.add(const Duration(minutes: 11));
      expect(await handle(macLiveActivity('start', 'working', timestamp: t0)), LiveOutcome.stale);
      expect(notifier.shown, isEmpty);
    });

    test('an update starts it while Claude works or waits (a start FCM folded away), not once Claude is done', () async {
      expect(await handle(macLiveActivity('update', 'done', timestamp: t0)), LiveOutcome.notStarted);
      expect(await handle(macLiveActivity('update', 'idle', timestamp: t0 + 1)), LiveOutcome.notStarted);
      expect(notifier.shown, isEmpty);
      expect(await handle(macLiveActivity('update', 'waiting', timestamp: t0 + 2, alert: true)), LiveOutcome.shown);
      // Showing now: done updates it.
      expect(await handle(macLiveActivity('update', 'done', timestamp: t0 + 3, alert: true)), LiveOutcome.shown);
      expect(notifier.last!.chip, 'Done');
    });

    test("the computer's end keeps it until the dismissal time; End It takes it away at once", () async {
      await handle(macLiveActivity('start', 'working', timestamp: t0, since: t0));
      clock = at.add(const Duration(seconds: 10));
      expect(await handle(macLiveActivity('end', 'done', timestamp: t0 + 10, dismissalDate: t0 + 190.0)), LiveOutcome.ended);
      expect([notifier.last!.ongoing, notifier.last!.timeoutMs], [false, 180 * 1000]);
      expect(LiveRecord.fromJson(record.json).showing, isFalse);

      await handle(macLiveActivity('start', 'working', timestamp: t0 + 20, since: t0 + 20));
      expect(notifier.showing, isTrue);
      expect(await handle(macLiveActivity('end', 'working', timestamp: t0 + 30, dismissalDate: t0 - 30.0)), LiveOutcome.removed);
      expect(notifier.showing, isFalse);
      expect(notifier.cancels.last.timestamp, t0 + 30);
      // An end with nothing showing only makes sure nothing is.
      expect(await handle(macLiveActivity('end', 'idle', timestamp: t0 + 40)), LiveOutcome.notStarted);
    });

    test('swiped away: this turn stays away; Claude needing you or the next turn brings it back', () async {
      await handle(macLiveActivity('start', 'working', timestamp: t0, since: t0));
      notifier.showing = false; // the user swiped it away
      expect(await handle(macLiveActivity('update', 'working', timestamp: t0 + 6, since: t0, frame: 1)), LiveOutcome.dismissed);
      expect(await handle(macLiveActivity('update', 'working', timestamp: t0 + 12, since: t0, frame: 2)), LiveOutcome.dismissed);
      expect(notifier.shown, hasLength(1));
      expect(await handle(macLiveActivity('update', 'waiting', timestamp: t0 + 20, since: t0 + 19, alert: true)), LiveOutcome.shown);
      expect(notifier.last!.alert, isTrue);
      // Gone because its time ran out, not swiped: the next update shows again.
      clock = at.add(LiveUpdateView.waitingTimeout + const Duration(minutes: 1));
      notifier.showing = false;
      expect(
        await handle(macLiveActivity('start', 'working', timestamp: t0 + LiveUpdateView.waitingTimeout.inSeconds + 30, since: t0 + 5000.0)),
        LiveOutcome.shown,
      );
    });

    test('off: nothing shows, and what was showing goes', () async {
      await handle(macLiveActivity('start', 'working', timestamp: t0));
      enabled = false;
      expect(await handle(macLiveActivity('update', 'working', timestamp: t0 + 6)), LiveOutcome.off);
      expect(notifier.showing, isFalse);
      expect(notifier.shown, hasLength(1));
      await live.turnedOff();
      expect(notifier.cancels.last.force, isTrue);
    });

    test('notifications turned off for Mochi: blocked', () async {
      notifier.allowed = false;
      expect(await handle(macLiveActivity('start', 'working', timestamp: t0)), LiveOutcome.blocked);
      expect(LiveRecord.fromJson(record.json).showing, isFalse);
    });

    test("the computer's activityEnded ends this turn's (iPhone followMacEnd), once, and never a newer turn's", () async {
      await handle(macLiveActivity('start', 'working', timestamp: t0, since: t0.toDouble()));
      // About an older turn: kept.
      expect(await live.macEnded(ActivityEnded(at: t0 + 5, since: t0 - 100, dismissAt: t0 + 5)), isNull);
      expect(notifier.showing, isTrue);
      // This turn, dismissed in three minutes: stays without its timer.
      clock = at.add(const Duration(seconds: 10));
      expect(await live.macEnded(ActivityEnded(at: t0 + 10, since: t0.toDouble(), dismissAt: t0 + 190)), LiveOutcome.ended);
      expect([notifier.last!.ongoing, notifier.last!.timeoutMs, notifier.last!.title], [false, 180 * 1000, 'Claude is working']);
      // The same note again: nothing.
      expect(await live.macEnded(ActivityEnded(at: t0 + 10, since: t0.toDouble(), dismissAt: t0 + 190)), isNull);

      // End It (dismissed already): gone at once.
      await handle(macLiveActivity('start', 'working', timestamp: t0 + 20, since: t0 + 20));
      expect(await live.macEnded(ActivityEnded(at: t0 + 30, since: t0 + 20, dismissAt: t0 - 30)), LiveOutcome.removed);
      expect(notifier.showing, isFalse);
    });

    test('after unpairing nothing stays: taken away, the record and the last timestamp forgotten', () async {
      await handle(macLiveActivity('start', 'working', timestamp: t0));
      await live.forget();
      expect([notifier.showing, notifier.resets, record.json], [false, 1, null]);
      // A new room starts afresh, even with an older clock.
      expect(await handle(macLiveActivity('start', 'working', timestamp: t0 - 100)), LiveOutcome.shown);
    });

    test("Settings' sample shows whatever came before and goes when asked", () async {
      await handle(macLiveActivity('start', 'working', timestamp: t0 + 1000));
      await live.sample('done', host: mac);
      expect([notifier.last!.title, notifier.last!.force], ['Claude finished!', true]);
      await live.removeSample();
      expect(notifier.showing, isFalse);
    });
  });

  group('the push', () {
    late FakeLiveNotifier notifier;
    late LiveUpdates live;

    setUp(() {
      notifier = FakeLiveNotifier();
      live = LiveUpdates(notifier: notifier, record: MemoryDocument(), enabled: () async => true, clock: () => at);
    });

    Future<LiveOutcome?> push(Map<String, Object?> data, {LinkCredentials? credentials}) =>
        LivePush.handle(data, credentials: () async => credentials, live: live, host: (_) => mac);

    test("relay 1.4.0's data message opens with K_la derived from the room key, and shows", () async {
      final apns = macLiveActivity('start', 'working', timestamp: t0, detail: 'secret-project · 2 tools');
      expect(jsonEncode(apns), isNot(contains('secret-project')));
      expect(await push(livePush('la-1', apns), credentials: phoneCredentials), LiveOutcome.shown);
      expect([notifier.last!.title, notifier.last!.text], ['Claude is working', 'secret-project · 2 tools']);
    });

    test('ignored when it is not a Live Activity, this phone is not paired, or it is from another room', () async {
      final apns = macLiveActivity('start', 'working', timestamp: t0);
      expect(await push({'kind': 'alert'}, credentials: phoneCredentials), isNull);
      expect(await push(livePush('la-1', apns)), isNull);
      expect(await push(livePush('la-1', apns, room: 'room_other'), credentials: phoneCredentials), isNull);
      expect(await push({'kind': 'liveActivity', 'apns': '{broken'}, credentials: phoneCredentials), isNull);
      expect(notifier.shown, isEmpty);
    });

    test('the same update by push and on the socket shows once', () async {
      final apns = macLiveActivity('start', 'working', timestamp: t0);
      expect(await push(livePush('la-1', apns), credentials: phoneCredentials), LiveOutcome.shown);
      expect(await live.handle(read(apns, id: 'la-1'), host: mac), LiveOutcome.duplicate);
      expect(notifier.shown, hasLength(1));
    });
  });

  group('in the app', () {
    late FakeRelay relay;
    late FakeLiveNotifier liveNotifier;
    late FakePushService push;
    late PocketModel model;

    setUp(() async {
      relay = FakeRelay();
      liveNotifier = FakeLiveNotifier();
      push = FakePushService();
      model = PocketModel(
        credentialStore: MemoryCredentialStore()..saved = phoneCredentials,
        doneDocument: MemoryDocument(),
        notifier: FakeNotifier(),
        connect: relay.connect,
        push: push,
        live: LiveUpdates(notifier: liveNotifier, record: MemoryDocument(), enabled: () async => true),
      );
      await model.load();
      await pumpEventQueue();
    });

    tearDown(() => model.dispose());

    int stamp() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

    test('the socket copy shows it, the push copy of the same update is dropped, and the room names the Mac', () async {
      relay.devices(platform: 'macOS', name: 'BELPL-LT-636', online: true);
      final now = stamp();
      final apns = macLiveActivity('start', 'working', timestamp: now);
      relay.liveActivity(apns, id: 'la-1');
      await pumpEventQueue();
      expect(liveNotifier.shown.single.text, 'On your Mac');
      push.pushes.add(livePush('la-1', apns));
      await pumpEventQueue();
      expect(liveNotifier.shown, hasLength(1));
      // A newer one by push (the socket missed it) updates it.
      push.pushes.add(livePush('la-2', macLiveActivity('update', 'waiting', timestamp: now + 1, alert: true)));
      await pumpEventQueue();
      expect(liveNotifier.shown.last.chip, 'Needs you');
    });

    test('activityEnded from the computer ends it, and unpairing takes it away', () async {
      final now = stamp();
      relay.liveActivity(
        macLiveActivity('start', 'working', timestamp: now, since: now.toDouble()),
        id: 'la-1',
      );
      await pumpEventQueue();
      expect(liveNotifier.showing, isTrue);
      relay.fromMac(LinkKey.activityEnded, {'at': now + 1, 'since': now, 'dismissAt': now - 60});
      await pumpEventQueue();
      expect(liveNotifier.showing, isFalse);

      relay.liveActivity(
        macLiveActivity('start', 'working', timestamp: now + 5, since: now + 5),
        id: 'la-2',
      );
      await pumpEventQueue();
      expect(liveNotifier.showing, isTrue);
      await model.unpair();
      await pumpEventQueue();
      expect([liveNotifier.showing, liveNotifier.resets], [false, 1]);
    });
  });
}
