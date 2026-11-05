import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'json.dart';
import 'link_credentials.dart';
import 'link_crypto.dart';
import 'pairing_code.dart';

/// The relay refused or couldn't be reached.
class LinkPairingException implements Exception {
  const LinkPairingException(this.message, {this.status, this.code});

  final String message;

  /// The HTTP status, when the relay answered.
  final int? status;

  /// The relay's error code (`invite_used`, `unauthorized`, …).
  final String? code;

  @override
  String toString() => 'LinkPairingException: $message';
}

/// The relay's HTTP calls for pairing (docs/MOCHI_LINK_PLAN.md 4.2), as Swift `LinkPairing`. Pass a [http.Client]
/// to reuse connections; otherwise each call makes and closes its own.
abstract final class LinkPairing {
  static const Duration timeout = Duration(seconds: 20);

  /// `https`/`wss` for a real relay; `http`/`ws` for a local one (`localhost:8787` while developing).
  static Uri url(String relay, String path, {String scheme = 'https'}) {
    final local = relay.startsWith('localhost') || relay.startsWith('127.0.0.1');
    final realScheme = local ? (scheme == 'wss' ? 'ws' : 'http') : scheme;
    return Uri.parse('$realScheme://$relay$path');
  }

  /// `GET /v1/health`: `{ok, version, protocol}`.
  static Future<Map<String, Object?>> health(String relay, {http.Client? client}) =>
      _call(relay, '/v1/health', 'GET', null, client: client);

  /// The host makes a room and becomes its first device. The room key K is made here and never leaves the devices.
  static Future<LinkCredentials> createRoom({
    required String relay,
    required String platform,
    required String name,
    http.Client? client,
  }) async {
    final body = await _call(relay, '/v1/rooms', 'POST', {'platform': platform, 'name': name}, client: client);
    final room = jsonString(body['room']), device = jsonString(body['device']), secret = jsonString(body['secret']);
    if (room == null || device == null || secret == null) {
      throw const LinkPairingException("The relay's answer didn't include a room.");
    }
    return LinkCredentials(
      relay: relay,
      room: room,
      device: device,
      secret: secret,
      key: LinkCrypto.base64url(LinkCrypto.newRoomKey()),
      role: 'host',
    );
  }

  /// A single-use invitation (10 minutes) for the QR code. [role] limits it to one role (`pocket`, `host`).
  static Future<PairingCode> invite(LinkCredentials credentials, {required String hostName, String? role, http.Client? client}) async {
    final body = await _call(
      credentials.relay,
      '/v1/rooms/${credentials.room}/invites',
      'POST',
      {'role': ?role},
      bearer: credentials.bearer,
      client: client,
    );
    final invite = jsonString(body['invite']);
    if (invite == null) throw const LinkPairingException("The relay didn't make an invitation.");
    return PairingCode(relay: credentials.relay, room: credentials.room, invite: invite, key: credentials.key, name: hostName);
  }

  /// The scanning device joins with the code and gets its own credential.
  static Future<LinkCredentials> join(
    PairingCode code, {
    required String role,
    required String platform,
    required String name,
    http.Client? client,
  }) async {
    final body = await _call(code.relay, '/v1/rooms/${code.room}/join', 'POST', {
      'invite': code.invite,
      'role': role,
      'platform': platform,
      'name': name,
    }, client: client);
    final device = jsonString(body['device']), secret = jsonString(body['secret']);
    if (device == null || secret == null) {
      throw const LinkPairingException("The relay didn't let this device join. The code may have expired: make a new one.");
    }
    return LinkCredentials(
      relay: code.relay,
      room: code.room,
      device: device,
      secret: secret,
      key: code.key,
      role: jsonString(body['role']) ?? role,
      peerName: code.name,
    );
  }

  /// Deletes the whole room on the relay (host only): every device has to pair again.
  static Future<void> deleteRoom(LinkCredentials credentials, {http.Client? client}) async {
    await _call(credentials.relay, '/v1/rooms/${credentials.room}', 'DELETE', null, bearer: credentials.bearer, client: client);
  }

  /// Removes a device from the room (a host, or a device removing itself).
  static Future<void> remove(String device, {required LinkCredentials from, http.Client? client}) async {
    await _call(from.relay, '/v1/rooms/${from.room}/devices/$device', 'DELETE', null, bearer: from.bearer, client: client);
  }

  static Future<Map<String, Object?>> _call(
    String relay,
    String path,
    String method,
    Map<String, Object?>? body, {
    String? bearer,
    http.Client? client,
  }) async {
    final uri = url(relay, path);
    final own = client == null;
    final httpClient = client ?? http.Client();
    try {
      final request = http.Request(method, uri)..headers['content-type'] = 'application/json';
      if (bearer != null) request.headers['authorization'] = 'Bearer $bearer';
      if (body != null) request.body = jsonEncode(body);
      final response = await http.Response.fromStream(await httpClient.send(request).timeout(timeout)).timeout(timeout);
      final json = asJsonMap(tryJsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true))) ?? const {};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = jsonString(json['error']);
        final reason = code ?? jsonString(json['message']) ?? 'status ${response.statusCode}';
        throw LinkPairingException('The relay said no ($reason).', status: response.statusCode, code: code);
      }
      return json;
    } on TimeoutException {
      throw const LinkPairingException("The relay didn't answer in time.");
    } on http.ClientException catch (error) {
      throw LinkPairingException("Couldn't reach the relay (${error.message}).");
    } finally {
      if (own) httpClient.close();
    }
  }
}
