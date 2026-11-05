import 'dart:convert';

import 'json.dart';
import 'link_crypto.dart';

/// The `op` of a frame.
enum LinkOp {
  put,
  send,
  ack,
  hello,
  sync,
  presence,
  devices,
  register,
  error;

  static LinkOp? tryParse(Object? raw) {
    for (final op in values) {
      if (op.name == raw) return op;
    }
    return null;
  }
}

/// An optional wake-up hint on a `send`.
class LinkPushHint {
  const LinkPushHint({required this.kind, this.priority, this.collapse});

  /// alert · background · liveactivity
  final String kind;
  final int? priority;
  final String? collapse;

  static LinkPushHint? fromJson(Object? json) {
    final j = asJsonMap(json);
    final kind = j?['kind'];
    if (j == null || kind is! String) return null;
    return LinkPushHint(kind: kind, priority: jsonInt(j['priority']), collapse: jsonString(j['collapse']));
  }

  Map<String, Object?> toJson() => {'kind': kind, 'priority': ?priority, 'collapse': ?collapse};

  @override
  bool operator ==(Object other) => other is LinkPushHint && other.kind == kind && other.priority == priority && other.collapse == collapse;

  @override
  int get hashCode => Object.hash(kind, priority, collapse);
}

/// One frame on the wire (docs/MOCHI_LINK_PLAN.md 4.4), with the field names of Swift `LinkEnvelope` and the relay.
/// `nonce` and `box` carry the sealed inner JSON (`{"v": <value>}`); everything else is routing the relay may read.
/// Relay-only frames (`sync`, `presence`, `devices`, `error`) carry more fields; [RelayLink] reads those as JSON.
class LinkEnvelope {
  const LinkEnvelope({
    this.v = 1,
    required this.op,
    this.key,
    this.id,
    this.from,
    this.to,
    this.at,
    this.ttl,
    this.push,
    this.nonce,
    this.box,
  });

  final int v;
  final LinkOp op;
  final String? key;
  final String? id;

  /// Filled in by the relay from the device's credential; never trusted from a client.
  final String? from;

  /// A role ("host") or device ids; null means everyone else in the room.
  final List<String>? to;

  /// Seconds since 1970 (the sender's clock).
  final num? at;

  /// Messages only: seconds before the relay drops it undelivered.
  final int? ttl;
  final LinkPushHint? push;
  final String? nonce;
  final String? box;

  LinkSealed? get sealed {
    final nonce = this.nonce, box = this.box;
    return nonce == null || box == null ? null : LinkSealed(nonce: nonce, box: box);
  }

  /// Null fields are left out, as Swift's `JSONEncoder` does; a whole-number `at` is written without a fraction.
  Map<String, Object?> toJson() => {
    'v': v,
    'op': op.name,
    'key': ?key,
    'id': ?id,
    'from': ?from,
    'to': ?to,
    'at': ?jsonNumber(at),
    'ttl': ?ttl,
    'push': ?push?.toJson(),
    'nonce': ?nonce,
    'box': ?box,
  };

  String encode() => jsonEncode(toJson());

  /// Null when it isn't an envelope (not an object, or no known `op`). `to` may be a single string, as the relay
  /// accepts.
  static LinkEnvelope? fromJson(Object? json) {
    final j = asJsonMap(json);
    final op = LinkOp.tryParse(j?['op']);
    if (j == null || op == null) return null;
    final to = j['to'];
    return LinkEnvelope(
      v: jsonInt(j['v']) ?? 1,
      op: op,
      key: jsonString(j['key']),
      id: jsonString(j['id']),
      from: jsonString(j['from']),
      to: to is String ? [to] : (to is List ? to.whereType<String>().toList() : null),
      at: j['at'] is num ? j['at'] as num : null,
      ttl: jsonInt(j['ttl']),
      push: LinkPushHint.fromJson(j['push']),
      nonce: jsonString(j['nonce']),
      box: jsonString(j['box']),
    );
  }

  static LinkEnvelope? decode(String text) => fromJson(tryJsonDecode(text));

  @override
  bool operator ==(Object other) => other is LinkEnvelope && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
