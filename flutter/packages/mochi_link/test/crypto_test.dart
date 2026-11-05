import 'dart:convert';
import 'dart:typed_data';

import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';

import 'support/spec.dart';

/// Mochi Link's encryption against the shared vectors (made with CryptoKit) and the Swift tests in
/// Tests/TamagotchiCoreTests/LinkTests.swift.
void main() {
  final vectors = (readJson('${specDirectory().path}/vectors.json')['vectors']! as List).cast<Map<String, Object?>>();

  test('there are at least four shared vectors', () => expect(vectors.length, greaterThanOrEqualTo(4)));

  for (final vector in vectors) {
    test('sealing reproduces the "${vector['name']}" vector, and opening returns the plaintext', () {
      final key = LinkCrypto.fromBase64url(vector['key']! as String)!;
      final nonce = LinkCrypto.fromBase64url(vector['nonce']! as String)!;
      final ad = vector['ad']! as String;
      final plaintext = vector['plaintext']! as String;
      final sealed = LinkCrypto.seal(utf8.encode(plaintext), ad: ad, key: key, nonce: nonce);
      expect(sealed.box, vector['box']);
      expect(sealed.nonce, vector['nonce']);
      expect(utf8.decode(LinkCrypto.open(sealed, ad: ad, key: key)!), plaintext);
      // The vector as given (not just our own output) opens too.
      final given = LinkSealed(nonce: vector['nonce']! as String, box: vector['box']! as String);
      expect(utf8.decode(LinkCrypto.open(given, ad: ad, key: key)!), plaintext);
    });
  }

  test('a vector won\'t open with a changed associated data, key or byte', () {
    for (final vector in vectors) {
      final key = LinkCrypto.fromBase64url(vector['key']! as String)!;
      final ad = vector['ad']! as String;
      final given = LinkSealed(nonce: vector['nonce']! as String, box: vector['box']! as String);
      expect(LinkCrypto.open(given, ad: '${ad}x', key: key), isNull);
      expect(LinkCrypto.open(given, ad: ad, key: Uint8List.fromList(key.reversed.toList())), isNull);
      final box = LinkCrypto.fromBase64url(given.box)!..[0] ^= 0x01;
      expect(
        LinkCrypto.open(
          LinkSealed(nonce: given.nonce, box: LinkCrypto.base64url(box)),
          ad: ad,
          key: key,
        ),
        isNull,
      );
    }
  });

  test('a box won\'t open with another room, key name, id, sender or key, or with a flipped byte', () {
    final key = LinkCrypto.newRoomKey();
    final ad = LinkCrypto.associatedData(room: 'room_A', key: 'command', id: '01JC', from: 'dev_phone');
    expect(ad, 'mochi-link/v1|room_A|command|01JC|dev_phone');
    final sealed = LinkCrypto.seal(utf8.encode('{"text":"run the tests"}'), ad: ad, key: key);
    expect(LinkCrypto.open(sealed, ad: ad, key: key), isNotNull);
    for (final other in [
      LinkCrypto.associatedData(room: 'room_B', key: 'command', id: '01JC', from: 'dev_phone'),
      LinkCrypto.associatedData(room: 'room_A', key: 'reply', id: '01JC', from: 'dev_phone'),
      LinkCrypto.associatedData(room: 'room_A', key: 'command', id: '01JD', from: 'dev_phone'),
      LinkCrypto.associatedData(room: 'room_A', key: 'command', id: '01JC', from: 'dev_cloud'),
    ]) {
      expect(
        LinkCrypto.open(sealed, ad: other, key: key),
        isNull,
        reason: other,
      );
    }
    expect(LinkCrypto.open(sealed, ad: ad, key: LinkCrypto.newRoomKey()), isNull);
    final bytes = LinkCrypto.fromBase64url(sealed.box)!..[0] ^= 0x01;
    expect(
      LinkCrypto.open(
        LinkSealed(nonce: sealed.nonce, box: LinkCrypto.base64url(bytes)),
        ad: ad,
        key: key,
      ),
      isNull,
    );
    final tag = LinkCrypto.fromBase64url(sealed.box)!;
    tag[tag.length - 1] ^= 0x80;
    expect(
      LinkCrypto.open(
        LinkSealed(nonce: sealed.nonce, box: LinkCrypto.base64url(tag)),
        ad: ad,
        key: key,
      ),
      isNull,
    );
    // Malformed pieces don't throw.
    expect(
      LinkCrypto.open(
        LinkSealed(nonce: 'short', box: sealed.box),
        ad: ad,
        key: key,
      ),
      isNull,
    );
    expect(
      LinkCrypto.open(
        LinkSealed(nonce: sealed.nonce, box: 'AAAA'),
        ad: ad,
        key: key,
      ),
      isNull,
    );
    expect(
      LinkCrypto.open(
        LinkSealed(nonce: sealed.nonce, box: '%%%'),
        ad: ad,
        key: key,
      ),
      isNull,
    );
    expect(LinkCrypto.open(sealed, ad: ad, key: Uint8List(16)), isNull);
    expect(() => LinkCrypto.seal(const [1], ad: ad, key: Uint8List(16)), throwsArgumentError);
  });

  test('each seal uses a fresh nonce', () {
    final key = LinkCrypto.newRoomKey();
    final first = LinkCrypto.seal(utf8.encode('same'), ad: 'ad', key: key);
    final second = LinkCrypto.seal(utf8.encode('same'), ad: 'ad', key: key);
    expect(first.nonce, isNot(second.nonce));
    expect(first.box, isNot(second.box));
    expect(LinkCrypto.fromBase64url(first.nonce)!.length, 12);
    expect(LinkCrypto.newRoomKey(), isNot(LinkCrypto.newRoomKey()));
  });

  test('the Live Activity key matches CryptoKit\'s HKDF, is stable, and can\'t open what K sealed', () {
    final roomKey = Uint8List(32)..fillRange(0, 32, 7);
    final derived = LinkCrypto.liveActivityKey(roomKey);
    // HKDF<SHA256>.deriveKey(inputKeyMaterial: K, info: "mochi-link/v1 live-activity", outputByteCount: 32), CryptoKit.
    expect(LinkCrypto.base64url(derived), 'McrAx3YCwrIXXU5yWE1wVXosmh1rfebRgV8AhtoMrLA');
    expect(LinkCrypto.base64url(LinkCrypto.liveActivityKey(List.generate(32, (i) => i))), 'S1ieazEEBqsLr1aRH-Hc_LDYChhM94Ob_uapbMKgAFQ');
    expect(LinkCrypto.liveActivityKey(roomKey), derived);
    expect(derived, isNot(roomKey));
    final sealed = LinkCrypto.seal(utf8.encode('command'), ad: 'ad', key: roomKey);
    expect(LinkCrypto.open(sealed, ad: 'ad', key: derived), isNull);
  });

  test('base64url has no padding and reads what Swift reads', () {
    expect(LinkCrypto.base64url([0xfb, 0xff]), '-_8');
    expect(LinkCrypto.fromBase64url('-_8'), [0xfb, 0xff]);
    expect(LinkCrypto.fromBase64url('-_8='), [0xfb, 0xff]);
    expect(LinkCrypto.fromBase64url('+/8'), [0xfb, 0xff]);
    expect(LinkCrypto.fromBase64url(''), isEmpty);
    expect(LinkCrypto.fromBase64url('A'), isNull);
    expect(LinkCrypto.fromBase64url('AB C'), isNull);
    expect(LinkCrypto.fromBase64url('AAAAAAAAAAAAAAAB'), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
  });
}
