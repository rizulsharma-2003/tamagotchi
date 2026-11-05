import 'dart:convert';
import 'dart:typed_data';

import 'json.dart';
import 'link_crypto.dart';

/// This device's place in a Mochi Link room (Swift `LinkCredentials`, same JSON field names): where the relay is,
/// the room, this device's credential and the room key K. Keep it in the platform's secure storage (Android
/// Keystore, Windows DPAPI / Credential Locker); [toString] leaves the secrets out.
class LinkCredentials {
  const LinkCredentials({
    required this.relay,
    required this.room,
    required this.device,
    required this.secret,
    required this.key,
    required this.role,
    this.peerName,
  });

  /// The relay's host, e.g. `mochi-link.example.workers.dev` (`localhost:8787` for a local one).
  final String relay;
  final String room;
  final String device;
  final String secret;

  /// The room key K, base64url. Never sent to the relay.
  final String key;

  /// host · pocket · cloud
  final String role;

  /// What this device is paired with ("Rizul's MacBook"), for Settings.
  final String? peerName;

  /// `Authorization: Bearer <device>.<secret>`.
  String get bearer => '$device.$secret';

  /// K as bytes, or null when [key] isn't 32 bytes of base64url.
  Uint8List? get roomKey {
    final bytes = LinkCrypto.fromBase64url(key);
    return bytes?.length == LinkCrypto.keyLength ? bytes : null;
  }

  Map<String, Object?> toJson() => {
    'relay': relay,
    'room': room,
    'device': device,
    'secret': secret,
    'key': key,
    'role': role,
    'peerName': ?peerName,
  };

  String encode() => jsonEncode(toJson());

  static LinkCredentials? fromJson(Object? json) {
    final j = asJsonMap(json);
    if (j == null) return null;
    final relay = jsonString(j['relay']), room = jsonString(j['room']), device = jsonString(j['device']);
    final secret = jsonString(j['secret']), key = jsonString(j['key']), role = jsonString(j['role']);
    if (relay == null || room == null || device == null || secret == null || key == null || role == null) return null;
    return LinkCredentials(
      relay: relay,
      room: room,
      device: device,
      secret: secret,
      key: key,
      role: role,
      peerName: jsonString(j['peerName']),
    );
  }

  static LinkCredentials? decode(String text) => fromJson(tryJsonDecode(text));

  @override
  bool operator ==(Object other) =>
      other is LinkCredentials &&
      other.relay == relay &&
      other.room == room &&
      other.device == device &&
      other.secret == secret &&
      other.key == key &&
      other.role == role &&
      other.peerName == peerName;

  @override
  int get hashCode => Object.hash(relay, room, device, secret, key, role, peerName);

  @override
  String toString() => 'LinkCredentials(relay: $relay, room: $room, device: $device, role: $role, peerName: $peerName)';
}
