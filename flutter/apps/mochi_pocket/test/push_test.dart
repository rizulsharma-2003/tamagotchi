import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/services/push/push_messages.dart';
import 'package:mochi_pocket/src/services/push/push_service.dart';
import 'package:mochi_pocket/src/services/push/shown_alerts.dart';

import 'support/fakes.dart';

void main() {
  const inner = {
    'title': 'Claude finished',
    'subtitle': 'mac-Tamagotchi',
    'body': 'Tests pass.',
    'userInfo': {'card': 'session-1'},
  };

  group('a push in the background (PushMessages.handle)', () {
    late FakeNotifier notifier;
    late MemoryShownAlerts shown;

    Future<PushOutcome> handle(Map<String, Object?> data, {Future<LinkCredentials?> Function()? credentials}) =>
        PushMessages.handle(data, credentials: credentials ?? () async => phoneCredentials, notifier: notifier, shown: shown);

    setUp(() {
      notifier = FakeNotifier();
      shown = MemoryShownAlerts();
    });

    test('reads data.kind and the data.mochi JSON string {v, room, key, id, from, nonce, box}', () {
      final sealed = PushMessages.sealedAlert(alertPush('a1', inner))!;
      expect(sealed.keys.toSet(), {'v', 'room', 'key', 'id', 'from', 'nonce', 'box'});
      expect(sealed['key'], 'alert');
      expect(PushMessages.sealedAlert({'kind': 'other', 'mochi': '{}'}), isNull);
      expect(PushMessages.sealedAlert(const {}), isNull);
    });

    test('opens the box with the room key and shows the alert, once', () async {
      expect(await handle(alertPush('a1', inner)), PushOutcome.shown);
      final alert = notifier.shown.single;
      expect(alert.id, 'a1');
      expect(alert.title, 'Claude finished');
      expect(alert.subtitle, 'mac-Tamagotchi');
      expect(alert.body, 'Tests pass.');
      expect(alert.userInfo, {'card': 'session-1'});
      expect(await handle(alertPush('a1', inner)), PushOutcome.duplicate);
      expect(notifier.shown, hasLength(1));
    });

    test("a box that doesn't open shows Mochi / Mochi has news, and isn't recorded (the real one may still come)", () async {
      final data = alertPush('a2', inner);
      final mochi = (jsonDecode(data['mochi']! as String) as Map).cast<String, Object?>();
      final box = mochi['box']! as String;
      // Flip a bit inside the ciphertext. (Editing the base64 text's last characters could leave the bytes unchanged:
      // the final character's spare bits are ignored when decoding.)
      final bytes = base64Url.decode(base64Url.normalize(box));
      bytes[bytes.length ~/ 2] ^= 0x01;
      mochi['box'] = base64Url.encode(bytes).replaceAll('=', '');
      expect(await handle({...data, 'mochi': jsonEncode(mochi)}), PushOutcome.fallback);
      expect(notifier.shown.single.title, 'Mochi');
      expect(notifier.shown.single.body, 'Mochi has news');
      expect(notifier.shown.single.id, 'a2', reason: 'the same notification id, so the real text replaces it');
      expect(await shown.contains('a2'), isFalse);
    });

    test('unreadable credentials, or a mangled mochi object, also give the fallback', () async {
      expect(await handle(alertPush('a3', inner), credentials: () async => throw StateError('keystore')), PushOutcome.fallback);
      expect(await handle({'kind': 'alert', 'mochi': 'not json'}), PushOutcome.fallback);
      expect(notifier.shown.map((alert) => alert.body), ['Mochi has news', 'Mochi has news']);
    });

    test('not for this phone: no pairing, another room, or not an alert, so nothing shows', () async {
      expect(await handle(alertPush('a4', inner), credentials: () async => null), PushOutcome.ignored);
      expect(await handle(alertPush('a5', inner, room: 'room_other')), PushOutcome.ignored);
      expect(await handle({'kind': 'liveActivity'}), PushOutcome.ignored);
      expect(notifier.shown, isEmpty);
    });

    test('already shown over the socket: a duplicate', () async {
      await shown.claim('a6');
      expect(await handle(alertPush('a6', inner)), PushOutcome.duplicate);
      expect(notifier.shown, isEmpty);
    });
  });

  group('shown alerts file', () {
    late Directory folder;

    setUp(() => folder = Directory.systemTemp.createTempSync('mochi_shown'));
    tearDown(() => folder.deleteSync(recursive: true));

    test('claims once, remembers across instances (isolates), and forgets after two days', () async {
      var clock = DateTime(2026, 11, 5, 12);
      final file = File('${folder.path}/shown_alerts.json');
      final first = FileShownAlerts(file, clock: () => clock);
      expect(await first.claim('a1'), isTrue);
      expect(await first.claim('a1'), isFalse);
      final second = FileShownAlerts(file, clock: () => clock);
      expect(await second.contains('a1'), isTrue);
      expect(await second.claim('a1'), isFalse);
      clock = clock.add(const Duration(days: 3));
      expect(await second.claim('a2'), isTrue);
      expect(await FileShownAlerts(file).contains('a1'), isFalse, reason: 'pruned');
    });

    test('claims at the same moment: exactly one wins', () async {
      final shown = FileShownAlerts(File('${folder.path}/shown_alerts.json'));
      final results = await Future.wait([for (var i = 0; i < 6; i++) shown.claim('same')]);
      expect(results.where((won) => won), hasLength(1));
    });

    test('a damaged file starts over instead of failing', () async {
      final file = File('${folder.path}/shown_alerts.json')..writeAsStringSync('{oops');
      expect(await FileShownAlerts(file).claim('a1'), isTrue);
    });
  });

  test('notification ids are stable per alert, 31-bit, and differ between alerts', () {
    expect(notificationIdFor('5f3c'), notificationIdFor('5f3c'));
    expect(notificationIdFor('5f3c'), isNot(notificationIdFor('5f3d')));
    for (final id in ['a', 'mochi-push', '5c9e2c4e-0a8b-4b7e-9d2a-3f1e2d4c5b6a']) {
      expect(notificationIdFor(id), inInclusiveRange(0, 0x7fffffff));
    }
  });

  group('the model and push', () {
    late FakeRelay relay;
    late FakeNotifier notifier;
    late FakePushService push;
    late MemoryShownAlerts shown;
    late MemoryCredentialStore store;
    late PocketModel model;

    PocketModel makeModel() => PocketModel(
      credentialStore: store,
      doneDocument: MemoryDocument(),
      notifier: notifier,
      connect: relay.connect,
      join: (_, _) async => phoneCredentials,
      leave: (_) async {},
      push: push,
      shown: shown,
    );

    List<Map<String, Object?>> registrations() => [
      for (final socket in relay.sockets) ...socket.sent.where((frame) => frame['op'] == 'register'),
    ];

    setUp(() {
      relay = FakeRelay();
      notifier = FakeNotifier();
      push = FakePushService();
      shown = MemoryShownAlerts();
      store = MemoryCredentialStore(phoneCredentials);
      model = makeModel();
    });

    tearDown(() => model.dispose());

    test('at launch the FCM address goes to the relay as register {tokens: {fcm}}, with no APNs fields', () async {
      await model.load();
      await pumpEventQueue();
      final frame = registrations().single;
      expect(frame.keys.toSet(), {'v', 'op', 'id', 'tokens'});
      expect(frame['tokens'], {'fcm': 'fcm-token-1'});
      expect(model.pushStatus, PushStatus.registered);
    });

    test('a rotated address is registered again; pairing registers too', () async {
      store.saved = null;
      await model.load();
      expect(model.pushStatus, PushStatus.off);
      await model.pair(pairingCode.url);
      await pumpEventQueue();
      expect(registrations().map((frame) => frame['tokens']), [
        {'fcm': 'fcm-token-1'},
      ]);
      push.refreshes.add('fcm-token-1');
      await pumpEventQueue();
      expect(registrations(), hasLength(1), reason: "the same address isn't sent twice");
      push.refreshes.add('fcm-token-2');
      await pumpEventQueue();
      expect(registrations(), hasLength(2));
      expect(registrations().last['tokens'], {'fcm': 'fcm-token-2'});
    });

    test('no Firebase in the build, or no address: the reason is kept for Settings, and nothing is registered', () async {
      push.problem = 'this build of Mochi has no Firebase setup';
      await model.load();
      await pumpEventQueue();
      expect(model.pushStatus, PushStatus.unavailable);
      expect(model.pushProblem, 'this build of Mochi has no Firebase setup');
      expect(registrations(), isEmpty);
      model.dispose();
      push = FakePushService(failure: const PushException("Google Play services couldn't be reached"));
      model = makeModel();
      await model.load();
      await pumpEventQueue();
      expect(model.pushProblem, "Google Play services couldn't be reached");
    });

    test('the relay refusing the registration says so', () async {
      await model.load();
      await pumpEventQueue();
      final id = registrations().single['id'];
      relay.socket.deliver({'v': 1, 'op': 'error', 'code': 'bad_token', 'id': id});
      await pumpEventQueue();
      expect(model.pushStatus, PushStatus.unavailable);
      expect(model.pushProblem, contains('bad_token'));
    });

    test('unpairing deletes the FCM address', () async {
      await model.load();
      await pumpEventQueue();
      await model.unpair();
      await pumpEventQueue();
      expect(push.deletes, 1);
      expect(model.pushStatus, PushStatus.off);
    });

    test('with the app open, an alert over the socket and the same one by FCM shows once, in either order', () async {
      await model.load();
      await pumpEventQueue();
      relay.alert({...inner, 'body': 'socket first'});
      await pumpEventQueue();
      final socketId = notifier.shown.single.id;
      push.pushes.add(alertPush(socketId, inner));
      await pumpEventQueue();
      expect(notifier.shown, hasLength(1));
      push.pushes.add(alertPush('push-first', {...inner, 'body': 'push first'}));
      await pumpEventQueue();
      expect(notifier.shown.last.body, 'push first');
      // The relay's socket copy of that alert, with the same id.
      relay.socket.deliver({
        ...(jsonDecode(LinkAlert.frame(inner, macCredentials, roomKey, id: 'push-first')) as Map).cast<String, Object?>(),
        'from': macCredentials.device,
      });
      await pumpEventQueue();
      expect(notifier.shown, hasLength(2));
    });
  });
}
