import 'dart:convert';
import 'dart:io';

import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';

import 'support/spec.dart';

/// Frames on the wire, matching Swift `RelayLinkStore.frame` (RelayClientTests.frames): sealed for their room, key,
/// id and sender, routing only in the clear.
void main() {
  final roomKey = List.filled(32, 3);
  final host = LinkCredentials(
    relay: 'localhost:8787',
    room: 'room_1',
    device: 'dev_mac',
    secret: 's1',
    key: LinkCrypto.base64url(roomKey),
    role: 'host',
  );

  Map<String, Object?> parse(String frame) => (jsonDecode(frame) as Map).cast<String, Object?>();

  test('a message is a sealed send with the Swift fields, to its role, with its TTL, and no plaintext', () {
    final command = {'id': 'cmd-1', 'text': "What's pending?", 'at': 1762243200.0, 'typed': true};
    final data = RelayLink.frame(command, LinkKey.command, host, roomKey, id: '01JC', at: 1762243200.4);
    final frame = parse(data);
    expect(frame.keys.toSet(), {'v', 'op', 'key', 'id', 'to', 'at', 'ttl', 'nonce', 'box'});
    expect(frame['v'], 1);
    expect(frame['op'], 'send');
    expect(frame['key'], 'command');
    expect(frame['id'], '01JC');
    expect(frame['to'], ['host']);
    expect(frame['ttl'], 600);
    expect(frame['at'], 1762243200, reason: 'whole seconds, as Swift rounds them');
    expect(LinkCrypto.fromBase64url(frame['nonce']! as String)!.length, 12);
    expect(data, isNot(contains('pending')));
    expect(data, isNot(contains('cmd-1')));
    final opened = RelayLink.open(data, host, from: 'dev_mac', roomKey: roomKey)!.value! as Map;
    expect(opened['text'], "What's pending?");
    expect(opened['typed'], true);
    // Claiming another sender, room or key breaks it.
    expect(RelayLink.open(data, host, from: 'dev_other', roomKey: roomKey), isNull);
    final elsewhere = LinkCredentials.fromJson({...host.toJson(), 'room': 'room_2'})!;
    expect(RelayLink.open(data, elsewhere, from: 'dev_mac', roomKey: roomKey), isNull);
    expect(RelayLink.open(data.replaceFirst('"key":"command"', '"key":"verdict"'), host, from: 'dev_mac', roomKey: roomKey), isNull);
    expect(RelayLink.open(data, host, from: 'dev_mac', roomKey: List.filled(32, 4)), isNull);
  });

  test('the sealed inner JSON is {"v": value}', () {
    final data = RelayLink.frame(['a', 1, true, null], LinkKey.reply, host, roomKey, id: 'r1');
    final frame = parse(data);
    final plain = LinkCrypto.open(
      LinkSealed(nonce: frame['nonce']! as String, box: frame['box']! as String),
      ad: LinkCrypto.associatedData(room: 'room_1', key: 'reply', id: 'r1', from: 'dev_mac'),
      key: roomKey,
    )!;
    expect(jsonDecode(utf8.decode(plain)), {
      'v': ['a', 1, true, null],
    });
    expect(frame['to'], ['pocket']);
  });

  test('state is a put to everyone; a JSON-string value survives as a string; clearing seals null', () {
    final look = RelayLink.frame('{"petName":"Mochi"}', LinkKey.look, host, roomKey);
    final lookFrame = parse(look);
    expect(lookFrame['op'], 'put');
    expect(lookFrame.containsKey('to'), isFalse);
    expect(lookFrame.containsKey('ttl'), isFalse);
    expect(RelayLink.open(look, host, from: 'dev_mac', roomKey: roomKey)!.value, '{"petName":"Mochi"}');
    final cleared = RelayLink.frame(null, LinkKey.approval, host, roomKey);
    final opened = RelayLink.open(cleared, host, from: 'dev_mac', roomKey: roomKey);
    expect(opened, isNotNull);
    expect(opened!.value, isNull);
    expect(parse(cleared)['box'], isNotNull, reason: 'a sealed null, not a relay-level clear');
    expect(parse(RelayLink.frame('hex', LinkKey.deviceToken, host, roomKey))['op'], 'put');
  });

  test('ids are lowercase UUIDs and frames get a fresh one each time', () {
    final id = RelayLink.newId();
    expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(RelayLink.newId(), isNot(id));
    expect(
      parse(RelayLink.frame(1, LinkKey.look, host, roomKey))['id'],
      isNot(parse(RelayLink.frame(1, LinkKey.look, host, roomKey))['id']),
    );
  });

  test('values that aren\'t JSON are refused before anything is sent', () {
    expect(() => RelayLink.frame(DateTime(2026), LinkKey.look, host, roomKey), throwsA(isA<JsonUnsupportedObjectError>()));
  });

  // Cross-language: Tests/TamagotchiCoreTests/LinkTests.swift ("A frame sealed by the Dart client opens") opens
  // these with Swift's RelayLinkStore.open. Fixed id, time and nonce make them reproducible here.
  test('the frames in test/fixtures/dart_frames.json are what this client seals', () {
    final windows = LinkCredentials(
      relay: 'localhost:8787',
      room: 'room_1',
      device: 'dev_win',
      secret: 's1',
      key: LinkCrypto.base64url(roomKey),
      role: 'host',
    );
    final samples = <(LinkKey, Object?)>[
      (LinkKey.command, {'id': 'cmd-1', 'text': "What's pending? — मोची 🐾", 'at': 1762243200, 'typed': true}),
      (LinkKey.look, '{"petName":"Mochi","companionName":"Patch"}'),
      (LinkKey.approval, null),
    ];
    final frames = [
      for (final (index, (key, value)) in samples.indexed)
        {
          'value': value,
          'frame': RelayLink.frame(
            value,
            key,
            windows,
            roomKey,
            id: 'dart-$index',
            at: 1762243200,
            nonce: List.generate(12, (i) => index * 16 + i),
          ),
        },
    ];
    final file = packageFixture('dart_frames.json');
    final expected = const JsonEncoder.withIndent('  ').convert({
      'about':
          'Frames sealed by the Dart client (RelayLink.frame) with fixed ids, times and nonces. Swift RelayLinkStore.open must open '
          'them (Tests/TamagotchiCoreTests/LinkTests.swift). Regenerate with MOCHI_WRITE_DART_FRAMES=1 dart test test/frame_test.dart.',
      'credentials': windows.toJson(),
      'frames': frames,
    });
    if (Platform.environment['MOCHI_WRITE_DART_FRAMES'] == '1') file.writeAsStringSync('$expected\n');
    expect(file.readAsStringSync().trim(), expected);
    for (final item in frames) {
      expect(RelayLink.open(item['frame']! as String, windows, from: 'dev_win', roomKey: roomKey)!.value, item['value']);
    }
  });
}
