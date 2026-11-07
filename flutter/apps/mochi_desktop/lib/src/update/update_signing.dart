// The integrity of Mochi's updates (docs/SPRINT_2.md W29): an Ed25519 signature over the manifest's exact bytes,
// made with the release key that lives only in the release Mac's Keychain, and the zip's SHA-256 named in that
// manifest. The app installs nothing unless both check out. Pure Dart (no Flutter): tool/update_signing.dart signs with
// the same code the app verifies with.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

abstract final class UpdateSigning {
  static final Ed25519 _ed25519 = Ed25519();

  static const int keyLength = 32;
  static const int signatureLength = 64;

  /// Whether [signature] (base64url, as in `manifest.sig`) is [publicKey]'s signature of [manifest]. False for
  /// anything malformed, never an exception.
  static Future<bool> verify(List<int> manifest, String signature, List<int> publicKey) async {
    final bytes = base64UrlDecode(signature.trim());
    if (bytes == null || bytes.length != signatureLength || publicKey.length != keyLength) return false;
    try {
      return await _ed25519.verify(
        manifest,
        signature: Signature(bytes, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
      );
    } on Object {
      return false;
    }
  }

  /// The signature of [manifest] with the private key [seed] (32 bytes), base64url without padding.
  static Future<String> sign(List<int> manifest, List<int> seed) async {
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    final signature = await _ed25519.sign(manifest, keyPair: keyPair);
    return base64UrlEncode(signature.bytes);
  }

  /// The public key of the private key [seed].
  static Future<List<int>> publicKey(List<int> seed) async {
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    return (await keyPair.extractPublicKey()).bytes;
  }

  /// A new private key (32 random bytes from the system's secure generator).
  static List<int> newSeed() => SecretKeyData.random(length: keyLength).bytes;

  /// base64url without padding (as the relay and `manifest.sig` use).
  static String base64UrlEncode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  /// null when [text] isn't base64url (padding optional).
  static Uint8List? base64UrlDecode(String text) {
    if (text.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(text)) return null;
    try {
      return base64Url.decode(base64Url.normalize(text));
    } on FormatException {
      return null;
    }
  }

  /// The SHA-256 of a file, lowercase hex, read in chunks.
  static Future<String> sha256OfFile(String path) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in File(path).openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final hash = await sink.hash();
    return hash.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Compares two hex digests without stopping at the first difference.
  static bool sameDigest(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}
