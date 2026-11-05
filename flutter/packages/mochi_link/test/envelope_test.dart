import 'dart:convert';

import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';

/// The envelope, the key names and the credentials, matching Swift `LinkEnvelope`, `LinkKey` (+ `relayTargets`,
/// `relayTTL`) and `LinkCredentials`.
void main() {
  test('the envelope keeps the wire names from the plan', () {
    const envelope = LinkEnvelope(
      op: LinkOp.send,
      key: 'command',
      id: '01JC',
      to: ['host'],
      at: 1762243200.0,
      ttl: 600,
      push: LinkPushHint(kind: 'alert', priority: 10, collapse: 'reply-01JC'),
      nonce: 'bm9uY2U',
      box: 'Ym94',
    );
    final json = envelope.encode();
    for (final field in [
      '"op":"send"',
      '"key":"command"',
      '"ttl":600',
      '"nonce":"bm9uY2U"',
      '"box":"Ym94"',
      '"v":1',
      '"at":1762243200,',
      '"to":["host"]',
      '"push":{"kind":"alert","priority":10,"collapse":"reply-01JC"}',
    ]) {
      expect(json, contains(field));
    }
    expect(json, isNot(contains('"from"')));
    final back = LinkEnvelope.decode(json);
    expect(back, envelope);
    expect(back!.sealed, const LinkSealed(nonce: 'bm9uY2U', box: 'Ym94'));
  });

  test('an envelope reads what the relay sends (a single `to`, `from`, unknown fields) and refuses non-envelopes', () {
    final envelope = LinkEnvelope.decode(
      '{"v":1,"op":"put","key":"look","id":"x","from":"dev_A","to":"pocket","at":1793800090.5,"nonce":"n","box":"b","extra":1}',
    )!;
    expect(envelope.op, LinkOp.put);
    expect(envelope.from, 'dev_A');
    expect(envelope.to, ['pocket']);
    expect(envelope.at, 1793800090.5);
    expect(LinkEnvelope.decode('{"op":"bogus"}'), isNull);
    expect(LinkEnvelope.decode('pong'), isNull);
    expect(LinkEnvelope.decode('[1]'), isNull);
  });

  test('keys keep their Swift raw values and kinds', () {
    expect(LinkKey.values.map((key) => key.name), [
      'look', 'claude', 'sessions', 'agent', 'cloud', 'approval', 'macDone', 'phoneDone', //
      'activityEnded', 'macInteraction', 'phoneInteraction', 'command', 'reply', 'verdict', //
      'pushToStart', 'updateTokens', 'deviceToken', 'tokensSavedAt',
    ]);
    expect(LinkKey.command.kind, LinkKeyKind.message);
    expect(LinkKey.look.kind, LinkKeyKind.state);
    expect(LinkKey.phoneDone.kind, LinkKeyKind.state);
    expect(LinkKey.deviceToken.kind, LinkKeyKind.registration);
    expect(LinkKey.tryParse('verdict'), LinkKey.verdict);
    expect(LinkKey.tryParse('agentNews'), isNull);
    expect(LinkKey.tryParse('done.dev_A'), isNull);
  });

  test('messages go to the right role with the Swift TTLs, state to everyone', () {
    expect(LinkKey.command.relayTargets, ['host']);
    expect(LinkKey.verdict.relayTargets, ['host']);
    expect(LinkKey.phoneInteraction.relayTargets, ['host']);
    expect(LinkKey.reply.relayTargets, ['pocket']);
    expect(LinkKey.macInteraction.relayTargets, ['pocket']);
    expect(LinkKey.activityEnded.relayTargets, ['pocket']);
    expect(LinkKey.command.relayTtl, 600);
    expect(LinkKey.verdict.relayTtl, 600);
    expect(LinkKey.reply.relayTtl, 600);
    expect(LinkKey.phoneInteraction.relayTtl, 90);
    expect(LinkKey.macInteraction.relayTtl, 90);
    expect(LinkKey.activityEnded.relayTtl, 3600);
    for (final key in LinkKey.values.where((key) => key.kind != LinkKeyKind.message)) {
      expect(key.relayTargets, isNull, reason: key.name);
      expect(key.relayTtl, isNull, reason: key.name);
    }
  });

  test('credentials use the Swift JSON field names and never print their secrets', () {
    final key = LinkCrypto.base64url(List.filled(32, 3));
    final credentials = LinkCredentials(relay: 'localhost:8787', room: 'room_1', device: 'dev_mac', secret: 's1', key: key, role: 'host');
    expect(credentials.toJson().keys, ['relay', 'room', 'device', 'secret', 'key', 'role']);
    expect(credentials.bearer, 'dev_mac.s1');
    expect(credentials.roomKey, List.filled(32, 3));
    // What Swift's JSONEncoder writes (peerName present).
    const swift = '{"relay":"r.example","room":"3e46","device":"dev_A","secret":"sec","key":"k","role":"pocket","peerName":"Mac"}';
    final decoded = LinkCredentials.decode(swift)!;
    expect(decoded.peerName, 'Mac');
    expect(jsonDecode(decoded.encode()), jsonDecode(swift));
    expect(decoded.roomKey, isNull, reason: 'not a 32-byte key');
    expect(LinkCredentials.decode('{"relay":"r"}'), isNull);
    expect(credentials.toString(), isNot(contains('s1')));
    expect(credentials.toString(), isNot(contains(key)));
  });

  test('the relay URL is https/wss, or http/ws for a local relay', () {
    expect(LinkPairing.url('link.example.com', '/v1/health').toString(), 'https://link.example.com/v1/health');
    expect(LinkPairing.url('link.example.com', '/v1/rooms/r/socket', scheme: 'wss').toString(), 'wss://link.example.com/v1/rooms/r/socket');
    expect(LinkPairing.url('localhost:8787', '/v1/rooms/r/socket', scheme: 'wss').toString(), 'ws://localhost:8787/v1/rooms/r/socket');
    expect(LinkPairing.url('127.0.0.1:8787', '/v1/rooms').toString(), 'http://127.0.0.1:8787/v1/rooms');
  });
}
