// Where Mochi's updates come from: the user's own Mochi Link relay (docs/SPRINT_2.md W29; the relay's README, "App
// updates"). Only a device of a room can read the feed, with the same credential as the link, so nothing is public.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mochi_link/mochi_link.dart';

/// The manifest's exact bytes and its signature (base64url; null when the relay sent none).
class SignedManifest {
  const SignedManifest(this.bytes, this.signature);

  final List<int> bytes;
  final String? signature;
}

/// The feed couldn't be read.
class UpdateFeedException implements Exception {
  const UpdateFeedException(this.message, {this.offline = false, this.status});

  final String message;

  /// The relay couldn't be reached at all (no network, a timeout).
  final bool offline;

  /// The relay's HTTP status, when it answered.
  final int? status;

  /// Nothing has been published for this platform yet.
  bool get nothingPublished => status == 404;

  @override
  String toString() => 'UpdateFeedException: $message';
}

abstract interface class UpdateFeed {
  /// The newest manifest and its signature.
  Future<SignedManifest> manifest();

  /// Downloads [name] to [target], at most [size] bytes, resuming a `<target>.part` left by an interrupted download.
  /// [progress] hears the bytes so far.
  Future<void> download(String name, String target, {required int size, void Function(int received)? progress});
}

/// The feed on the relay this PC's room is on: `GET /v1/rooms/{room}/updates/{platform}/…` with the device's
/// credential. [credentials] makes the room first if this PC has none yet (LinkHost.ensureRoom).
class RelayUpdateFeed implements UpdateFeed {
  RelayUpdateFeed({
    required Future<LinkCredentials?> Function() credentials,
    this.platform = 'windows',
    http.Client Function()? client,
    this.timeout = const Duration(seconds: 30),
  }) : _credentials = credentials,
       _client = client ?? http.Client.new;

  final Future<LinkCredentials?> Function() _credentials;
  final http.Client Function() _client;

  /// The feed's name on the relay: `windows`, or `windows-test` for trying a release first.
  final String platform;

  /// How long to wait for an answer, and for the next piece of a download.
  final Duration timeout;

  static const String signatureHeader = 'x-mochi-signature';

  Future<(LinkCredentials, Uri Function(String))> _where() async {
    LinkCredentials? found;
    try {
      found = await _credentials();
    } on Object {
      found = null;
    }
    final credentials = found;
    if (credentials == null) throw const UpdateFeedException("Couldn't reach your Mochi Link relay.", offline: true);
    final base = '/v1/rooms/${credentials.room}/updates/$platform/';
    return (credentials, (String rest) => LinkPairing.url(credentials.relay, '$base$rest'));
  }

  @override
  Future<SignedManifest> manifest() async {
    final (credentials, url) = await _where();
    final client = _client();
    try {
      final response = await _get(client, url('manifest'), credentials);
      final bytes = await _read(response, limit: 64 * 1024);
      var signature = response.headers[signatureHeader];
      if (signature == null || signature.isEmpty) {
        final sig = await _get(client, url('file/manifest.sig'), credentials);
        signature = String.fromCharCodes(await _read(sig, limit: 1024)).trim();
      }
      return SignedManifest(bytes, signature.isEmpty ? null : signature);
    } finally {
      client.close();
    }
  }

  @override
  Future<void> download(String name, String target, {required int size, void Function(int received)? progress}) async {
    final (credentials, url) = await _where();
    final part = File('$target.part');
    part.parent.createSync(recursive: true);
    var have = part.existsSync() ? part.lengthSync() : 0;
    if (have > size) {
      part.deleteSync();
      have = 0;
    }
    final client = _client();
    try {
      if (have < size) {
        var response = await _get(client, url('file/$name'), credentials, from: have, allow416: true);
        if (response.statusCode == 416) {
          // The .part doesn't fit this file: start again.
          await response.stream.drain<void>();
          have = 0;
          response = await _get(client, url('file/$name'), credentials);
        }
        // 206: the rest after what we have; 200: the whole file (the relay ignored the range).
        final append = response.statusCode == 206 && have > 0;
        if (!append) have = 0;
        final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
        var received = have;
        try {
          await for (final chunk in response.stream.timeout(timeout)) {
            received += chunk.length;
            if (received > size) throw const UpdateFeedException('The download was bigger than the update should be.');
            sink.add(chunk);
            progress?.call(received);
          }
        } on TimeoutException {
          throw const UpdateFeedException('The download stalled.', offline: true);
        } on http.ClientException {
          throw const UpdateFeedException('The download was cut off.', offline: true);
        } on SocketException {
          throw const UpdateFeedException('The download was cut off.', offline: true);
        } finally {
          await sink.close();
        }
      }
      final length = part.lengthSync();
      if (length != size) throw UpdateFeedException('The download stopped at $length of $size bytes.', offline: length < size);
      final finished = File(target);
      if (finished.existsSync()) finished.deleteSync();
      part.renameSync(target);
    } on UpdateFeedException catch (error) {
      // A download that went wrong (rather than one that was cut off) starts again next time.
      if (!error.offline && part.existsSync()) part.deleteSync();
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<http.StreamedResponse> _get(
    http.Client client,
    Uri url,
    LinkCredentials credentials, {
    int from = 0,
    bool allow416 = false,
  }) async {
    final request = http.Request('GET', url)..headers['authorization'] = 'Bearer ${credentials.bearer}';
    if (from > 0) request.headers['range'] = 'bytes=$from-';
    final http.StreamedResponse response;
    try {
      response = await client.send(request).timeout(timeout);
    } on TimeoutException {
      throw const UpdateFeedException("Your Mochi Link relay didn't answer in time.", offline: true);
    } on http.ClientException {
      throw const UpdateFeedException("Couldn't reach your Mochi Link relay.", offline: true);
    } on SocketException {
      throw const UpdateFeedException("Couldn't reach your Mochi Link relay.", offline: true);
    }
    final status = response.statusCode;
    if (status == 200 || status == 206 || (allow416 && status == 416)) return response;
    await response.stream.drain<void>().catchError((Object _) {});
    throw UpdateFeedException(switch (status) {
      401 || 403 => "Your Mochi Link relay didn't accept this PC's link.",
      404 => 'Nothing has been published yet.',
      429 => 'Your Mochi Link relay asked Mochi to slow down.',
      503 => "Updates aren't set up on your Mochi Link relay yet.",
      _ => 'Your Mochi Link relay answered $status.',
    }, status: status);
  }

  /// The whole body, at most [limit] bytes.
  Future<List<int>> _read(http.StreamedResponse response, {required int limit}) async {
    final bytes = <int>[];
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > limit) throw const UpdateFeedException('The manifest is too big.');
      }
    } on TimeoutException {
      throw const UpdateFeedException("Your Mochi Link relay didn't answer in time.", offline: true);
    } on http.ClientException {
      throw const UpdateFeedException("Couldn't reach your Mochi Link relay.", offline: true);
    }
    return bytes;
  }
}
