import 'dart:convert';
import 'dart:typed_data';

import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';

import 'support/spec.dart';

/// The Live Activity's key and sealed text against the shared vectors (`link-spec/live-activity.json`, made with
/// CryptoKit; the relay and Swift check the same file), and reading the host's `apns` object the three ways it
/// arrives on Android: as the relay's FCM data message, on the socket, and as built by a host.
void main() {
  final spec = readJson('${specDirectory().path}/live-activity.json');
  final keys = (spec['keys']! as List).cast<Map<String, Object?>>();
  final sealed = (spec['sealed']! as List).cast<Map<String, Object?>>();
  Uint8List bytes(Object? text) => LinkCrypto.fromBase64url(text! as String)!;

  group('shared vectors', () {
    test('there are key and sealed vectors', () {
      expect(keys.length, greaterThanOrEqualTo(3));
      expect(sealed.length, greaterThanOrEqualTo(3));
    });

    for (final vector in keys) {
      test('K_la for "${vector['name']}" is HKDF-SHA256(K, info "mochi-link/v1 live-activity")', () {
        expect(LinkCrypto.base64url(LinkCrypto.liveActivityKey(bytes(vector['roomKey']))), vector['liveActivityKey']);
      });
    }

    for (final vector in sealed) {
      test('the sealed "${vector['name']}" is reproduced from its parts and opens to its title and detail', () {
        final laKey = LinkCrypto.liveActivityKey(bytes(vector['roomKey']));
        expect(LinkCrypto.base64url(laKey), vector['liveActivityKey']);
        expect(vector['ad'], LinkLiveActivity.associatedData);
        final again = LinkCrypto.seal(
          utf8.encode(vector['plaintext']! as String),
          ad: LinkLiveActivity.associatedData,
          key: laKey,
          nonce: bytes(vector['nonce']),
        );
        expect('${again.nonce}.${again.box}', vector['sealed']);
        final opened = LinkLiveActivity.open(vector['sealed']! as String, laKey)!;
        expect(opened.title, vector['title']);
        expect(opened.detail, vector['detail']);
        // K itself, another room's K_la, a changed byte: nothing.
        expect(LinkLiveActivity.open(vector['sealed']! as String, bytes(vector['roomKey'])), isNull);
        expect(LinkLiveActivity.open(vector['sealed']! as String, LinkCrypto.liveActivityKey(LinkCrypto.newRoomKey())), isNull);
        final text = vector['sealed']! as String;
        final flipped = '${text.substring(0, text.length - 2)}${text.endsWith('A') ? 'B' : 'A'}${text.substring(text.length - 1)}';
        expect(LinkLiveActivity.open(flipped, laKey), isNull);
      });
    }

    test('malformed sealed text is refused without throwing', () {
      final laKey = LinkCrypto.liveActivityKey(List.filled(32, 7));
      for (final text in ['', '.', 'abc', 'abc.', '.abc', '%%%.%%%', 'AAAA.AAAA']) {
        expect(LinkLiveActivity.open(text, laKey), isNull, reason: text);
      }
    });
  });

  group('reading', () {
    final roomKey = List.filled(32, 7);
    final laKey = LinkCrypto.liveActivityKey(roomKey);

    test("a host's start, update and end come out as the phone needs them", () {
      final start = LinkLiveActivity.apns(
        event: 'start',
        timestamp: 1793800000,
        phase: 'working',
        title: 'Claude is working',
        detail: 'web · 3 tools',
        since: 1793799990,
        frame: 4,
        liveActivityKey: laKey,
        petName: 'Mochi',
        companionName: 'Patch',
      );
      // Nothing private in the clear.
      expect(jsonEncode(start), isNot(contains('Claude is working')));
      expect(jsonEncode(start), isNot(contains('web')));
      expect((start['content-state']! as Map)['title'], 'Mochi');
      final read = LinkLiveActivity.fromApns(start, liveActivityKey: laKey, id: 'la-1', from: 'dev_mac')!;
      expect([read.id, read.from, read.event, read.timestamp, read.phase], ['la-1', 'dev_mac', 'start', 1793800000, 'working']);
      expect([read.title, read.detail, read.opened], ['Claude is working', 'web · 3 tools', true]);
      expect([read.since, read.frame, read.petName, read.companionName], [1793799990, 4, 'Mochi', 'Patch']);
      expect([read.isStart, read.isEnd, read.showsTimer, read.art], [true, false, true, 'working']);
      expect(start['input-push-token'], 1);

      final waiting = LinkLiveActivity.fromApns(
        LinkLiveActivity.apns(
          event: 'update',
          timestamp: 1793800010,
          phase: 'waiting',
          title: 'Claude needs you',
          since: 1793800009,
          liveActivityKey: laKey,
          alert: true,
        ),
        liveActivityKey: laKey,
      )!;
      expect([waiting.title, waiting.detail, waiting.alert, waiting.sound], ['Claude needs you', null, true, true]);

      final end = LinkLiveActivity.fromApns(
        LinkLiveActivity.apns(
          event: 'end',
          timestamp: 1793800020,
          phase: 'done',
          title: 'Claude finished!',
          since: 1793800019,
          liveActivityKey: laKey,
          dismissalDate: 1793800200,
        ),
        liveActivityKey: laKey,
      )!;
      expect([end.isEnd, end.dismissalDate, end.alert, end.showsTimer], [true, 1793800200, false, false]);
    });

    test("one that won't open keeps the placeholder title and says so; an unknown phase draws as idle", () {
      final apns = LinkLiveActivity.apns(
        event: 'update',
        timestamp: 1,
        phase: 'celebrating',
        title: 'secret',
        since: 1,
        liveActivityKey: laKey,
        petName: 'Bao',
      );
      final read = LinkLiveActivity.fromApns(apns, liveActivityKey: LinkCrypto.liveActivityKey(LinkCrypto.newRoomKey()))!;
      expect([read.title, read.detail, read.opened, read.art], ['Bao', null, false, 'idle']);
      final noKey = LinkLiveActivity.fromApns(apns, liveActivityKey: null)!;
      expect([noKey.title, noKey.opened], ['Bao', false]);
    });

    test('an older host with nothing sealed: the clear title and detail are used', () {
      final read = LinkLiveActivity.fromApns({
        'event': 'update',
        'timestamp': 5,
        'content-state': {'phase': 'done', 'title': 'Claude finished!', 'detail': 'web', 'since': 4.5},
      }, liveActivityKey: laKey)!;
      expect([read.title, read.detail, read.opened, read.since, read.frame], ['Claude finished!', 'web', true, 4.5, null]);
    });

    test('not a Live Activity: refused', () {
      for (final apns in <Map<String, Object?>>[
        {},
        {'event': 'pause', 'timestamp': 1, 'content-state': <String, Object?>{}},
        {'event': 'update', 'content-state': <String, Object?>{}},
        {'event': 'update', 'timestamp': 1},
        {'event': 'update', 'timestamp': 'now', 'content-state': <String, Object?>{}},
      ]) {
        expect(LinkLiveActivity.fromApns(apns, liveActivityKey: laKey), isNull, reason: '$apns');
      }
    });

    test("the relay's FCM data message: kind, room, id, from and the apns object as a JSON string", () {
      final apns = LinkLiveActivity.apns(
        event: 'update',
        timestamp: 1793800000,
        phase: 'working',
        title: 'Claude is working',
        detail: '2 tools',
        since: 1793799000,
        frame: 7,
        liveActivityKey: laKey,
      );
      // Exactly what relay 1.4.0 sends (`liveActivityData`), every value a string.
      final data = <String, Object?>{'kind': 'liveActivity', 'room': 'room_1', 'id': 'la-9', 'from': 'dev_mac', 'apns': jsonEncode(apns)};
      expect(LinkLiveActivity.pushRoom(data), 'room_1');
      final read = LinkLiveActivity.fromPushData(data, liveActivityKey: laKey)!;
      expect(
        [read.id, read.room, read.from, read.event, read.title, read.detail, read.frame],
        ['la-9', 'room_1', 'dev_mac', 'update', 'Claude is working', '2 tools', 7],
      );
      expect(LinkLiveActivity.fromPushData({...data, 'kind': 'alert'}, liveActivityKey: laKey), isNull);
      expect(LinkLiveActivity.pushRoom({...data, 'kind': 'alert'}), isNull);
      expect(LinkLiveActivity.fromPushData({...data, 'apns': '{not json'}, liveActivityKey: laKey), isNull);
      expect(LinkLiveActivity.fromPushData({'kind': 'liveActivity'}, liveActivityKey: laKey), isNull);
    });

    test("a host's frame is Swift's: to the pockets, ten minutes, a liveactivity push hint, the apns object", () {
      final apns = LinkLiveActivity.apns(event: 'end', timestamp: 9, phase: 'idle', title: 'x', since: 8, liveActivityKey: laKey);
      final frame = (jsonDecode(LinkLiveActivity.hostFrame(apns, id: 'f1', priority: 10, at: 9)) as Map).cast<String, Object?>();
      expect(frame, {
        'v': 1,
        'op': 'send',
        'key': 'liveActivity',
        'id': 'f1',
        'to': ['pocket'],
        'ttl': 600,
        'at': 9,
        'push': {'kind': 'liveactivity', 'priority': 10, 'collapse': 'live-activity'},
        'apns': jsonDecode(jsonEncode(apns)),
      });
      expect(apns['dismissal-date'], 9 + 15 * 60);
      expect(frame, isNot(contains('nonce')));
    });
  });
}
