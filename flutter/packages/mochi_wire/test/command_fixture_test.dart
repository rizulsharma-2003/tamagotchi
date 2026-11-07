// The build/test detection behind Mochi's "real build/test result" celebrations (Sprint 2 G2) must match the Mac's
// TamagotchiWire CommandClassifier: link-spec/world/celebrations.json lists commands with Swift's answers, and the
// wire events in it go through mochi_world's normalizer in that package's tests.

import 'dart:convert';
import 'dart:io';

import 'package:mochi_wire/mochi_wire.dart';
import 'package:test/test.dart';

Map<String, Object?> _celebrations() {
  var dir = Directory.current.absolute;
  while (true) {
    final file = File('${dir.path}/link-spec/world/celebrations.json');
    if (file.existsSync()) return (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
    if (dir.parent.path == dir.path) throw StateError('link-spec/world/celebrations.json not found');
    dir = dir.parent;
  }
}

void main() {
  test('CommandClassifier matches Swift on every command in link-spec/world/celebrations.json', () {
    final commands = (_celebrations()['commands']! as List).cast<Map<String, Object?>>();
    expect(commands.length, greaterThan(30));
    for (final c in commands) {
      final result = CommandClassifier.classify(c['command']! as String);
      expect(result, CommandKindResult(c['kind'] as String?, reliable: c['reliable']! as bool), reason: c['command'] as String);
    }
  });

  test('the fixture wire events are the JSON a WireEvent reads and writes', () {
    final scenarios = (_celebrations()['scenarios']! as List).cast<Map<String, Object?>>();
    for (final scenario in scenarios) {
      for (final step in (scenario['events']! as List).cast<Map<String, Object?>>()) {
        final json = (step['wire']! as Map).cast<String, Object?>();
        final wire = WireEvent.fromJson(json);
        expect(wire, isNotNull, reason: '${json['id']}');
        expect(jsonDecode(jsonEncode(wire!.toJson())), json, reason: '${json['id']}');
      }
    }
  });
}
