import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Mac, SecretBox, SecretBoxAuthenticationError, SecretKeyData;
import 'package:cryptography/dart.dart' show DartAesGcm, DartHmac, DartSha256;

/// A sealed value: both base64url without padding.
class LinkSealed {
  const LinkSealed({required this.nonce, required this.box});

  /// The 12-byte nonce.
  final String nonce;

  /// Ciphertext || 16-byte tag.
  final String box;

  @override
  bool operator ==(Object other) => other is LinkSealed && other.nonce == nonce && other.box == box;

  @override
  int get hashCode => Object.hash(nonce, box);

  @override
  String toString() => 'LinkSealed(nonce: $nonce, box: ${box.length} chars)';
}

/// Mochi Link's end-to-end encryption (docs/MOCHI_LINK_PLAN.md 4.3), byte-for-byte the same as Swift `LinkCrypto`
/// and `link-spec/vectors.json`: AES-256-GCM with the room key K, a random 12-byte nonce, and associated data that
/// ties each box to its room, key name, id and sender.
///
/// Synchronous (the pure-Dart AES-GCM of `package:cryptography`), so a frame is sealed the moment it's written and
/// frames leave in the order they were written.
abstract final class LinkCrypto {
  static const int keyLength = 32;
  static const int nonceLength = 12;
  static const int tagLength = 16;

  static final DartAesGcm _aes = DartAesGcm.with256bits();
  static final Random _random = Random.secure();

  /// `mochi-link/v1|<room>|<key>|<id>|<from>`.
  static String associatedData({required String room, required String key, required String id, required String from}) =>
      'mochi-link/v1|$room|$key|$id|$from';

  static Uint8List randomBytes(int count) {
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  /// A new room key: 32 random bytes.
  static Uint8List newRoomKey() => randomBytes(keyLength);

  /// Seals [plaintext] under the 32-byte [key]. [nonce] is only for tests and vectors; leave it out otherwise.
  static LinkSealed seal(List<int> plaintext, {required String ad, required List<int> key, List<int>? nonce}) {
    if (key.length != keyLength) throw ArgumentError.value(key.length, 'key', 'The room key is $keyLength bytes');
    final gcmNonce = nonce ?? randomBytes(nonceLength);
    if (gcmNonce.length != nonceLength) throw ArgumentError.value(gcmNonce.length, 'nonce', 'The nonce is $nonceLength bytes');
    final box = _aes.encryptSync(plaintext, secretKeyData: SecretKeyData(key), nonce: gcmNonce, aad: utf8.encode(ad));
    final out = Uint8List(box.cipherText.length + tagLength)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    return LinkSealed(nonce: base64url(gcmNonce), box: base64url(out));
  }

  /// The plaintext, or null when the box doesn't open (wrong key, changed AD or tampered bytes).
  static Uint8List? open(LinkSealed sealed, {required String ad, required List<int> key}) {
    final nonce = fromBase64url(sealed.nonce);
    final box = fromBase64url(sealed.box);
    if (key.length != keyLength || nonce == null || nonce.length != nonceLength || box == null || box.length < tagLength) {
      return null;
    }
    final split = box.length - tagLength;
    try {
      final plain = _aes.decryptSync(
        SecretBox(box.sublist(0, split), nonce: nonce, mac: Mac(box.sublist(split))),
        secretKeyData: SecretKeyData(key),
        aad: utf8.encode(ad),
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  /// The key the iPhone's Live Activity widget gets instead of K (spike 0.2):
  /// `HKDF-SHA256(K, salt: none, info: "mochi-link/v1 live-activity")`, 32 bytes. A leaked copy opens Live
  /// Activity text and nothing else.
  static Uint8List liveActivityKey(List<int> roomKey) {
    const hmac = DartHmac(DartSha256());
    // Extract (RFC 5869: no salt means HashLen zero bytes), then one expand block: T(1) = HMAC(PRK, info || 0x01).
    final prk = hmac.calculateMacSync(roomKey, secretKeyData: SecretKeyData(Uint8List(32)), nonce: const []).bytes;
    final okm = hmac.calculateMacSync(
      [...utf8.encode('mochi-link/v1 live-activity'), 1],
      secretKeyData: SecretKeyData(prk),
      nonce: const [],
    );
    return Uint8List.fromList(okm.bytes.sublist(0, 32));
  }

  /// base64url without padding.
  static String base64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  /// Reads base64url with or without padding (standard base64 characters are accepted too, as in Swift); null when
  /// it isn't base64.
  static Uint8List? fromBase64url(String text) {
    final padding = (4 - text.length % 4) % 4;
    if (padding == 3) return null;
    try {
      return base64Url.decode(text + '=' * padding);
    } on FormatException {
      return null;
    }
  }
}
