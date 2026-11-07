// Mochi's and Patch's poses and the interaction frames against the Swift engine (link-spec/world/poses-*.json,
// interactions.json, written by Tests/TamagotchiCoreTests/WorldFixtureTests.swift).

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('Mochi (poses-pet.json)', () {
    final fixture = readWorldFixture('poses-pet.json');
    final all = cases(fixture);
    test('covers every animation and variant', () {
      final seen = {for (final c in all) '${c['animation']}/${c['variant'] ?? '-'}'};
      for (final animation in PetAnimation.values) {
        for (var v = 0; v < PetPoseEvaluator.variantCount(animation); v++) {
          expect(seen, contains('${animation.name}/$v'));
        }
      }
    });
    // One test per animation, so a failure names it.
    final byAnimation = <String, List<Map<String, Object?>>>{};
    for (final c in all) {
      byAnimation.putIfAbsent(c['animation']! as String, () => []).add(c);
    }
    for (final entry in byAnimation.entries) {
      test(entry.key, () {
        final failures = <String>[];
        for (final c in entry.value) {
          final animation = byName(PetAnimation.values, c['animation']);
          final variant = c['variant'] as int?;
          final duration = (c['duration'] as num?)?.toDouble();
          final base = obj(c['context']);
          for (final sample in objs(c['samples'])) {
            final t = (sample['t']! as num).toDouble();
            final context = contextFromJson(base, time: (sample['time']! as num).toDouble());
            if (variant == null) {
              final start = (base['time']! as num).toDouble();
              expect(
                PetPoseEvaluator.variant(animation, startedAt: start, seed: context.seed),
                sample['variant'],
                reason: '${c['note']}: variant from start $start',
              );
            }
            final pose = PetPoseEvaluator.pose(animation, elapsed: t, duration: duration, context: context, variant: variant);
            final diff = diffPet(pose, obj(sample['pose']));
            if (diff.isNotEmpty) failures.add('${c['note']} v$variant t=$t: ${diff.join('; ')}');
          }
        }
        expect(failures, isEmpty, reason: failures.take(6).join('\n'));
      });
    }
  });

  group('Patch (poses-companion.json)', () {
    final all = cases(readWorldFixture('poses-companion.json'));
    test('every case', () {
      final failures = <String>[];
      for (final c in all) {
        final animation = byName(CompanionAnimation.values, c['animation']);
        final duration = (c['duration'] as num?)?.toDouble();
        final base = obj(c['context']);
        final d = obj(c['detail']);
        final detail = CompanionDetail(
          waitingFor: d['waitingFor'] == null ? null : byName(AttentionKind.values, d['waitingFor']),
          subagents: (d['subagents'] as int?) ?? 0,
        );
        for (final sample in objs(c['samples'])) {
          final t = (sample['t']! as num).toDouble();
          final context = contextFromJson(base, time: (sample['time']! as num).toDouble());
          final pose = CompanionPoseEvaluator.pose(animation, elapsed: t, duration: duration, context: context, detail: detail);
          final diff = diffCompanion(pose, obj(sample['pose']));
          if (diff.isNotEmpty) failures.add('${c['animation']} ${c['note']} t=$t: ${diff.join('; ')}');
        }
      }
      expect(failures, isEmpty, reason: failures.take(6).join('\n'));
    });
  });

  group('Interactions (interactions.json)', () {
    final all = cases(readWorldFixture('interactions.json'));
    for (final c in all) {
      final id = byName(InteractionID.values, c['interaction']);
      test('${id.name} v${c['variant']} (${c['note']})', () {
        final variant = c['variant']! as int;
        final script = InteractionLibrary.script(id, variant: variant);
        expect(script.duration, closeTo((c['duration']! as num).toDouble(), 1e-12));
        expect(script.requiresCompanion, c['requiresCompanion'] ?? false);
        final beats = [
          for (final b in script.pet) {'start': b.start, 'end': b.end, 'animation': b.animation.name},
          for (final b in script.companion) {'character': 'companion', 'start': b.start, 'end': b.end, 'animation': b.animation.name},
        ];
        expect(diffJson(beats, objs(c['beats'])), isEmpty);
        final petBase = obj(c['petContext']);
        final companionBase = obj(c['companionContext']);
        final playback = InteractionPlayback(
          id: id,
          startedAt: (petBase['time']! as num).toDouble(),
          variant: variant,
          companionLoop: byName(CompanionAnimation.values, c['companionLoop']),
        );
        final failures = <String>[];
        for (final f in objs(c['frames'])) {
          final t = (f['t']! as num).toDouble();
          final frame = InteractionLibrary.frame(
            playback,
            elapsed: t,
            petContext: contextFromJson(petBase, time: playback.startedAt + t),
            companionContext: contextFromJson(companionBase, time: playback.startedAt + t),
            detail: const CompanionDetail(subagents: 1),
          );
          final diff = [
            ...diffPet(frame.pet, obj(f['pet'])).map((d) => 'pet$d'),
            ...diffCompanion(frame.companion, obj(f['companion'])).map((d) => 'companion$d'),
            ...diffProps(frame.props, objs(f['props'])).map((d) => 'props$d'),
          ];
          if (diff.isNotEmpty) failures.add('t=$t: ${diff.join('; ')}');
        }
        expect(failures, isEmpty, reason: failures.take(6).join('\n'));
      });
    }
  });
}
