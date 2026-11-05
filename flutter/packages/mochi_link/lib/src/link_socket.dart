import 'dart:async';
import 'dart:io' show WebSocketException;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// The one socket [RelayLink] talks through. [IoLinkSocket] is the real one; tests pass their own.
abstract interface class LinkSocket {
  /// Completes when the socket is open; fails when it couldn't connect.
  Future<void> get ready;

  /// Text (or binary) frames from the relay; done when the socket closes.
  Stream<Object?> get stream;

  void send(String text);

  Future<void> close([int? code, String? reason]);

  /// The close code the relay sent (4001 revoked, 4004 room deleted, 4008 replaced), once closed.
  int? get closeCode;
}

/// Opens a socket to [url] with these HTTP [headers] (`authorization`).
typedef LinkSocketConnector = LinkSocket Function(Uri url, Map<String, String> headers);

/// A `dart:io` WebSocket through `package:web_socket_channel` (Android, Windows, macOS, Linux, CLI), with
/// protocol-level pings: no pong within [pingInterval] closes it, and [RelayLink] reconnects.
class IoLinkSocket implements LinkSocket {
  IoLinkSocket.connect(
    Uri url,
    Map<String, String> headers, {
    Duration pingInterval = const Duration(seconds: 25),
    Duration connectTimeout = const Duration(seconds: 20),
  }) : _channel = IOWebSocketChannel.connect(url, headers: headers, pingInterval: pingInterval, connectTimeout: connectTimeout);

  final WebSocketChannel _channel;
  bool _closed = false;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<Object?> get stream => _channel.stream;

  @override
  void send(String text) {
    if (_closed) return;
    try {
      _channel.sink.add(text);
    } on StateError {
      // Already closing; the frame stays unacknowledged and goes again on the next connection.
    }
  }

  /// A client may only close with 1000 or 3000–4999 (`package:web_socket` throws otherwise, asynchronously), so
  /// anything else becomes 1000.
  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    final allowed = code == null || code == 1000 || (code >= 3000 && code <= 4999);
    try {
      await _channel.sink.close(allowed ? code : 1000, reason).timeout(const Duration(seconds: 2));
    } on Object {
      // Nothing to do: it's gone either way.
    }
  }

  @override
  int? get closeCode => _channel.closeCode;
}

/// The HTTP status of a refused WebSocket upgrade (401 revoked or wrong credential, 404 no such room), when [error]
/// says.
int? upgradeStatus(Object? error) {
  final inner = error is WebSocketChannelException ? error.inner : error;
  return inner is WebSocketException ? inner.httpStatusCode : null;
}
