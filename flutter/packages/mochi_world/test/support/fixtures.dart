import 'dart:convert';
import 'dart:io';

import 'package:mochi_world/mochi_world.dart';

/// The repository's `link-spec/world` folder (the golden fixtures the Swift tests write), found by walking up.
Directory worldSpecDirectory() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = Directory('${dir.path}/link-spec/world');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('link-spec/world not found above ${Directory.current.path}');
    dir = parent;
  }
}

Map<String, Object?> readWorldFixture(String name) =>
    (jsonDecode(File('${worldSpecDirectory().path}/$name').readAsStringSync()) as Map).cast<String, Object?>();

List<Map<String, Object?>> cases(Map<String, Object?> fixture, [String key = 'cases']) =>
    ((fixture[key] as List?) ?? const []).map((e) => (e as Map).cast<String, Object?>()).toList();

Map<String, Object?> obj(Object? value) => value is Map ? value.cast<String, Object?>() : const {};

List<Map<String, Object?>> objs(Object? value) => value is List ? value.map(obj).toList() : const [];

T byName<T extends Enum>(List<T> values, Object? name) => values.firstWhere((v) => v.name == name, orElse: () {
  throw StateError('unknown ${T.toString()} "$name"');
});

/// The fixture's PoseContext.
PoseContext contextFromJson(Map<String, Object?> j, {double? time}) => PoseContext(
  time: time ?? (j['time'] as num).toDouble(),
  reducedMotion: j['reducedMotion'] == true,
  intensity: j['intensity'] == null ? AnimationIntensity.normal : byName(AnimationIntensity.values, j['intensity']),
  seed: parseUnsigned(j['seed'] ?? '1'),
  returnLoop: j['returnLoop'] == null ? PetAnimation.idle : byName(PetAnimation.values, j['returnLoop']),
);

/// Numbers in the fixtures have 12 significant digits.
bool close(double actual, double expected) {
  final tolerance = 2e-9 * (expected.abs() > 1 ? expected.abs() : 1);
  return (actual - expected).abs() <= tolerance;
}

/// Compares two JSON values (maps from `toJson`, with the expected side missing keys equal to their defaults, which the
/// caller fills by round-tripping through `fromJson`). Returns the first few differences.
List<String> diffJson(Object? actual, Object? expected, [String path = '']) {
  final out = <String>[];
  void walk(Object? a, Object? e, String p) {
    if (out.length > 8) return;
    if (a is num && e is num) {
      if (!close(a.toDouble(), e.toDouble())) out.add('$p: $a (Swift $e)');
    } else if (a is Map && e is Map) {
      final keys = {...a.keys, ...e.keys};
      for (final k in keys) {
        walk(a[k], e[k], '$p.$k');
      }
    } else if (a is List && e is List) {
      if (a.length != e.length) {
        out.add('$p: ${a.length} items (Swift ${e.length}): ${_kinds(a)} vs ${_kinds(e)}');
        return;
      }
      for (var i = 0; i < a.length; i++) {
        walk(a[i], e[i], '$p[$i]');
      }
    } else if (a != e) {
      out.add('$p: $a (Swift $e)');
    }
  }

  walk(actual, expected, path);
  return out;
}

String _kinds(List<Object?> items) => items.map((e) => e is Map ? (e['kind'] ?? '?') : e).join(',');

/// Every field of an effect (the fixtures and `toJson` leave defaults out, and a value a hair off its default must
/// still compare with the default on the other side).
Map<String, Object?> fullEffect(Effect e) => {
  'kind': e.kind.name,
  'x': e.x,
  'y': e.y,
  'scale': e.scale,
  'opacity': e.opacity,
  'rotation': e.rotation,
  'variant': e.variant,
  'stretch': e.stretch,
  'phase': e.phase,
  'x2': e.x2,
  'y2': e.y2,
  'followsFacing': e.followsFacing,
  'worldSpace': e.worldSpace,
};

Map<String, Object?> _fullPet(PetPose p) => p.toJson()..['effects'] = p.effects.map(fullEffect).toList();

Map<String, Object?> _fullCompanion(CompanionPose p) => p.toJson()..['effects'] = p.effects.map(fullEffect).toList();

Map<String, Object?> _fullProp(SceneProp p) => {
  'kind': p.kind.name,
  'x': p.x,
  'y': p.y,
  'scale': p.scale,
  'opacity': p.opacity,
  'rotation': p.rotation,
  'variant': p.variant,
};

List<String> diffPet(PetPose actual, Map<String, Object?> expected) => diffJson(_fullPet(actual), _fullPet(PetPose.fromJson(expected)));

List<String> diffCompanion(CompanionPose actual, Map<String, Object?> expected) =>
    diffJson(_fullCompanion(actual), _fullCompanion(CompanionPose.fromJson(expected)));

List<String> diffProps(List<SceneProp> actual, List<Map<String, Object?>> expected) =>
    diffJson(actual.map(_fullProp).toList(), expected.map((e) => _fullProp(SceneProp.fromJson(e))).toList());
