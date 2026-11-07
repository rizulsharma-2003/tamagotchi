import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';

void main() {
  final roomKey = List<int>.filled(32, 7);
  final phone = LinkCredentials(
    relay: 'relay.test',
    room: 'room_1',
    device: 'dev_phone',
    secret: 'phone-secret',
    key: LinkCrypto.base64url(roomKey),
    role: 'pocket',
  );

  test('send posts the frame as it is to the room, with the bearer credential, and returns the ack', () async {
    late http.Request seen;
    final client = MockClient((request) async {
      seen = request;
      final frame = jsonDecode(request.body) as Map;
      return http.Response(jsonEncode({'v': 1, 'op': 'ack', 'id': frame['id'], 'key': frame['key'], 'at': 1}), 200);
    });
    final frame = RelayLink.frame(
      const LinkCommand(id: 'c1', text: 'Run the tests', at: 1, typed: true, project: 'mac-Tamagotchi', session: 's1').toValue(),
      LinkKey.command,
      phone,
      roomKey,
      id: 'c1',
    );
    final answer = await LinkPairing.send(frame, from: phone, client: client);
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'https://relay.test/v1/rooms/room_1/send');
    expect(seen.headers['authorization'], 'Bearer dev_phone.phone-secret');
    expect(seen.body, frame);
    expect(answer['op'], 'ack');
    expect(answer['id'], 'c1');
  });

  test("a refusal carries the relay's code; no answer is a plain failure", () async {
    final refusing = MockClient(
      (request) async => http.Response(jsonEncode({'error': 'rate_limited', 'message': 'Slow down.', 'id': 'c1', 'key': 'command'}), 429),
    );
    await expectLater(
      LinkPairing.send('{}', from: phone, client: refusing),
      throwsA(isA<LinkPairingException>().having((error) => error.code, 'code', 'rate_limited').having((e) => e.status, 'status', 429)),
    );
    final offline = MockClient((request) async => throw http.ClientException('Failed host lookup'));
    await expectLater(
      LinkPairing.send('{}', from: phone, client: offline),
      throwsA(isA<LinkPairingException>().having((error) => error.code, 'code', isNull)),
    );
    final slow = MockClient((request) => Future.delayed(const Duration(seconds: 5), () => http.Response('{}', 200)));
    await expectLater(
      LinkPairing.send('{}', from: phone, client: slow, within: const Duration(milliseconds: 20)),
      throwsA(isA<LinkPairingException>().having((error) => error.message, 'message', contains('in time'))),
    );
  });

  test("devices asks the relay for the room's list over HTTPS and reads names, platforms and who's online", () async {
    final client = MockClient((request) async {
      expect(jsonDecode(request.body), {'v': 1, 'op': 'devices'});
      return http.Response(
        jsonEncode({
          'v': 1,
          'op': 'devices',
          'devices': [
            {'id': 'dev_mac', 'role': 'host', 'platform': 'macOS', 'name': 'BELPL-LT-636', 'online': true, 'lastSeen': 1762243200},
            {'id': 'dev_phone', 'role': 'pocket', 'platform': 'android', 'name': 'realme RMX3242', 'online': false},
            {'role': 'pocket'},
          ],
        }),
        200,
      );
    });
    final peers = await LinkPairing.devices(phone, client: client);
    expect(peers.map((peer) => peer.device), ['dev_mac', 'dev_phone']);
    expect(peers.first.online, isTrue);
    expect(peers.first.lastSeen, 1762243200);
    expect(LinkPeerNames.host(peers, me: 'dev_phone').yours, 'your Mac');
    expect(LinkPeer.fromJson(const {'device': 'dev_x', 'online': true})?.online, isTrue);
    expect(LinkPeer.fromJson(const {'online': true}), isNull);
  });

  test('an alert without a push hint on the envelope takes the one given (an FCM push carries it beside the box)', () {
    final frame =
        (jsonDecode(LinkAlert.frame({'title': 'Mochi', 'userInfo': <String, Object?>{}}, phone, roomKey, id: 'a1')) as Map)
            .cast<String, Object?>()
          ..remove('push')
          ..['from'] = 'dev_phone';
    final alert = LinkAlert.open(frame, room: 'room_1', roomKey: roomKey, category: 'mochi-agent', threadId: 'mochi-agent')!;
    expect(alert.category, 'mochi-agent');
    expect(alert.threadId, 'mochi-agent');
  });
}
