import 'dart:convert';
import 'dart:io';

import 'package:mochi_link/mochi_link.dart';
import 'package:test/test.dart';

import 'support/spec.dart';

/// Every sample payload in link-spec/fixtures (written by the Swift tests from the Swift models) decodes with the
/// Dart models, and the Dart models write it back in the same shape, so the two worlds can't drift apart silently.
void main() {
  final folder = '${specDirectory().path}/fixtures';
  final keys = LinkKey.values.where((key) => key.kind != LinkKeyKind.registration).toList();
  final roomKey = List.filled(32, 5);
  final credentials = LinkCredentials(
    relay: 'r',
    room: 'room_1',
    device: 'dev_win',
    secret: 's',
    key: LinkCrypto.base64url(roomKey),
    role: 'host',
  );

  Object? toValue(Object model) => switch (model) {
    PetLook() => model.toValue(),
    ClaudeMirror() => model.toValue(),
    PhoneSessions() => model.toValue(),
    AgentPending() => model.toValue(),
    AgentDoneList() => model.toValue(),
    CloudTrigger() => model.toValue(),
    ApprovalRequest() => model.toValue(),
    ActivityEnded() => model.toValue(),
    LinkInteraction() => model.toValue(),
    LinkCommand() => model.toValue(),
    LinkReply() => model.toValue(),
    LinkVerdict() => model.toValue(),
    _ => throw StateError('no model for $model'),
  };

  test('there is one fixture for every state and message key, and no other', () {
    final names = Directory(folder).listSync().whereType<File>().map((file) => file.uri.pathSegments.last).toSet();
    expect(names, {for (final key in keys) '${key.name}.json'});
  });

  for (final key in keys) {
    test('${key.name}: decodes with the Dart model, writes back the same, and survives sealing', () {
      final fixture = readJson('$folder/${key.name}.json');
      expect(fixture['key'], key.name);
      final value = fixture['value'];
      final storedAsString = fixture['storedAs'] == 'json-string';
      expect(key.storedAsJsonString, storedAsString, reason: 'storedAs ${fixture['storedAs']}');
      // What RelayLink.value returns for it: the JSON string, or the decoded object.
      final wire = storedAsString ? jsonEncode(value) : value;
      final model = decodeLinkValue(key, wire);
      expect(model, isNotNull);
      final back = toValue(model!);
      if (storedAsString) {
        expect(back, isA<String>());
        expect(jsonDecode(back! as String), value);
      } else {
        expect(back, isA<Map<String, Object?>>());
        expect(back, value);
      }
      // A decoded object works as well as the string.
      expect(decodeLinkValue(key, value), isNotNull);
      final frame = RelayLink.frame(wire, key, credentials, roomKey);
      expect(RelayLink.open(frame, credentials, from: 'dev_win', roomKey: roomKey)!.value, wire);
    });
  }

  test('the models read the fields the apps use', () {
    Object? fixture(LinkKey key) {
      final value = readJson('$folder/${key.name}.json')['value'];
      return key.storedAsJsonString ? jsonEncode(value) : value;
    }

    final look = PetLook.fromValue(fixture(LinkKey.look))!;
    expect(
      [look.petName, look.companionName, look.petColor, look.theme, look.deskAccessory],
      ['Mochi', 'Patch', 'cream', 'cozyDesk', 'plant'],
    );
    expect(look.friendshipLevel, 3);
    expect(look.petAccessory, isNull);
    expect(look.room['items'], isEmpty);

    final claude = ClaudeMirror.fromValue(fixture(LinkKey.claude))!;
    expect([claude.phase, claude.category, claude.resting], ['working', 'edit', false]);

    final sessions = PhoneSessions.fromValue(fixture(LinkKey.sessions))!;
    expect(sessions.enabled, isTrue);
    final card = sessions.sessions.single;
    expect([card.id, card.project, card.phase], ['session-1', 'mac-Tamagotchi', 'done']);
    expect(card.summary?.done, 'Gave Mochi its own voice.');
    expect(card.summary?.next, ['Push it']);
    expect(card.files, ['KokoroVoice.swift']);
    expect(card.finishedAt, 1762243100);

    final agent = AgentPending.fromValue(fixture(LinkKey.agent))!;
    expect(agent.headline, 'Priya is waiting on the invoice.');
    final note = agent.items.single;
    expect(note.threadId, '18c2');
    expect(note.source, AgentSource.gmail);
    expect([note.important, note.vip], [true, true]);

    final done = AgentDoneList.fromValue(fixture(LinkKey.phoneDone))!;
    expect(done.ids['mail:18c2'], 1762243150);
    expect(done.union(const AgentDoneList(ids: {'mail:18c2': 1, 'x': 2})).ids, {'mail:18c2': 1762243150, 'x': 2});

    expect(LinkCommand.fromValue(fixture(LinkKey.command))?.typed, isTrue);
    expect(LinkReply.fromValue(fixture(LinkKey.reply))?.text, 'Five things are waiting.');
    expect(LinkVerdict.fromValue(fixture(LinkKey.verdict))?.allow, isTrue);
    expect(ApprovalRequest.fromValue(fixture(LinkKey.approval))?.target, 'session-1');
    expect(LinkInteraction.fromValue(fixture(LinkKey.phoneInteraction))?.kind, 'treat');
    expect(ActivityEnded.fromValue(fixture(LinkKey.activityEnded))?.dismissAt, 1762243500);
    expect(CloudTrigger.fromValue(fixture(LinkKey.cloud))?.token, 'example-token');
  });

  test('values Swift would refuse to decode are refused here too', () {
    expect(PetLook.fromValue('{"petName":"Mochi"}'), isNull);
    expect(PhoneSessions.fromValue('{"enabled":true,"sessions":[{"id":"s"}]}'), isNull);
    expect(AgentPending.fromValue('{"enabled":true,"items":[{"id":"x","source":"slack"}]}'), isNull);
    expect(AgentDoneList.fromValue('{"ids":{"a":"soon"}}'), isNull);
    expect(LinkCommand.fromValue({'id': 'c'}), isNull);
    expect(PetLook.fromValue('not json'), isNull);
    expect(PetLook.fromValue(42), isNull);
  });

  test('whole-number times are written as Swift writes them', () {
    const command = LinkCommand(id: 'c', text: 't', at: 1762243200, typed: true);
    expect(jsonEncode(command.toValue()), '{"id":"c","text":"t","at":1762243200,"typed":true}');
    expect(jsonEncode(const LinkReply(id: 'c', state: 'done', at: 1762243200.25).toValue()), contains('"at":1762243200.25'));
  });
}
