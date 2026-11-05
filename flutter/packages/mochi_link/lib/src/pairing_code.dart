import 'dart:convert';

import 'link_crypto.dart';

/// A pairing invitation, shown by the host as a QR code (docs/MOCHI_LINK_PLAN.md 4.2) and the same as Swift
/// `PairingCode`: `mochi://pair?v=1&relay=<host>&room=<roomId>&invite=<code>&key=<base64url(K)>&name=<host name>`.
///
/// [url] is written exactly as Swift's `URLComponents` writes it, and parsing follows `URLComponents.queryItems`:
/// percent-decoding only, so a `+` stays a `+` (Dart's `Uri.queryParameters` would turn it into a space).
class PairingCode {
  const PairingCode({required this.relay, required this.room, required this.invite, required this.key, required this.name});

  /// The relay's host, e.g. `mochi-link.example.workers.dev`.
  final String relay;
  final String room;

  /// Single-use, 10 minutes.
  final String invite;

  /// The room key K, base64url.
  final String key;

  /// The host's name, shown on the device that scans ("Pair with Rizul's MacBook?").
  final String name;

  /// The code as text, for a QR code or "Copy pairing link".
  String get url {
    final items = {'v': '1', 'relay': relay, 'room': room, 'invite': invite, 'key': key, 'name': name};
    return 'mochi://pair?${items.entries.map((item) => '${item.key}=${_encode(item.value)}').join('&')}';
  }

  /// Reads a scanned or pasted code; null unless it's a complete version 1 code with a 32-byte key.
  static PairingCode? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'mochi' || uri.host != 'pair' || !uri.hasQuery) return null;
    final items = <String, String?>{};
    for (final part in uri.query.split('&')) {
      final split = part.indexOf('=');
      final name = _decode(split < 0 ? part : part.substring(0, split));
      if (name == null || items.containsKey(name)) continue;
      items[name] = split < 0 ? null : _decode(part.substring(split + 1));
    }
    String? item(String name) {
      final value = items[name];
      return value == null || value.isEmpty ? null : value;
    }

    final relay = item('relay'), room = item('room'), invite = item('invite'), key = item('key');
    if (item('v') != '1' || relay == null || room == null || invite == null || key == null) return null;
    if (LinkCrypto.fromBase64url(key)?.length != LinkCrypto.keyLength) return null;
    return PairingCode(relay: relay, room: room, invite: invite, key: key, name: item('name') ?? 'Mochi');
  }

  @override
  bool operator ==(Object other) =>
      other is PairingCode &&
      other.relay == relay &&
      other.room == room &&
      other.invite == invite &&
      other.key == key &&
      other.name == name;

  @override
  int get hashCode => Object.hash(relay, room, invite, key, name);

  /// Leaves out the invite and the key.
  @override
  String toString() => 'PairingCode(relay: $relay, room: $room, name: $name)';

  /// What `URLComponents.queryItems` leaves as is in a query value: `urlQueryAllowed` without `&` and `=`.
  static final Set<int> _allowed = {
    for (var c = 0x30; c <= 0x39; c++) c, // 0-9
    for (var c = 0x41; c <= 0x5A; c++) c, // A-Z
    for (var c = 0x61; c <= 0x7A; c++) c, // a-z
    ...'-._~!\$\'()*+,;:@/?'.codeUnits,
  };

  static String _encode(String value) {
    final out = StringBuffer();
    for (final byte in utf8.encode(value)) {
      if (_allowed.contains(byte)) {
        out.writeCharCode(byte);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static String? _decode(String text) {
    try {
      return Uri.decodeComponent(text);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
}
