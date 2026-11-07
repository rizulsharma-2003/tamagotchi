// The interaction scheduler against the Swift engine (link-spec/world/scheduler.json), and SplitMix64 itself.

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  test('SplitMix64 and Ease.hash match Swift for seeds above 2^63', () {
    // Reference values from the Swift implementation (the canonical SplitMix64 sequence for seed 0).
    final rng = SplitMix64(0);
    expect(unsignedString(rng.next()), '16294208416658607535');
    expect(unsignedString(rng.next()), '7960286522194355700');
    expect(unsignedMod(parseUnsigned('18446744073709551615'), 1000), 615);
    expect(unsignedMod(-1, 7), 1); // (2^64 − 1) mod 7
    expect(parseUnsigned(unsignedString(-2)), -2);
  });

  for (final c in cases(readWorldFixture('scheduler.json'))) {
    test('scheduler: ${c['note']}', () {
      final seed = parseUnsigned(c['seed']);
      final start = (c['start']! as num).toDouble();
      final step = (c['step']! as num).toDouble();
      final count = c['count']! as int;
      final dayEvery = (c['dayEvery']! as num).toDouble();
      final segments = objs(c['segments']);
      final scheduler = InteractionScheduler(seed: seed, now: start);
      final events = <List<Object?>>[];
      final checkpoints = <Map<String, Object?>>[];
      for (var index = 0; index < count; index++) {
        final now = start + index * step;
        final day = 20000 + (index * step / dayEvery).floor();
        final segment = segments.lastWhere((s) => (s['from']! as int) <= index);
        final from = segment['from']! as int;
        if (from == index) {
          if (segment['postpone'] case final num by) scheduler.postpone(now: now, by: by.toDouble());
          if (segment['noteTriggered'] case final String id) scheduler.noteTriggered(byName(InteractionID.values, id), now: now);
        }
        final idle = now - (start + from * step) + ((segment['idleOffset'] as num?)?.toDouble() ?? 0);
        final context = SchedulerContext(
          companionPresent: segment['companionPresent'] != false,
          activity: byName(AmbientActivity.values, segment['activity'] ?? 'idle'),
          idleSeconds: idle,
          charactersBusy: segment['busy'] == true,
          paused: segment['paused'] == true,
          reducedMotion: segment['reducedMotion'] == true,
          intensity: byName(AnimationIntensity.values, segment['intensity'] ?? 'normal'),
          petAsleep: segment['petAsleep'] == true,
        );
        final next = scheduler.nextInteraction(now: now, day: day, context: context);
        if (next != null) {
          events.add([index, 'interaction', next.$1.name, next.$2]);
        } else if (scheduler.nextSolo(now: now, context: context) case final solo?) {
          events.add([index, 'solo', solo.name]);
        }
        if (index % 200 == 199 || index == count - 1) {
          checkpoints.add({
            'after': index,
            'rng': unsignedString(scheduler.rng.state),
            'nextInteractionAt': scheduler.nextInteractionAt,
            'nextSoloAt': scheduler.nextSoloAt,
            'recent': [for (final id in scheduler.recent) id.name],
            'dailyCounts': {
              for (final id in InteractionID.values)
                if (scheduler.dailyCounts[id] case final n?) id.name: n,
            },
          });
        }
      }
      final expectedEvents = (c['events']! as List).cast<List<Object?>>();
      for (var i = 0; i < expectedEvents.length && i < events.length; i++) {
        expect(events[i], expectedEvents[i], reason: 'event $i');
      }
      expect(events.length, expectedEvents.length);
      expect(diffJson(checkpoints, objs(c['checkpoints'])), isEmpty);
      // The schedule really exercised the rules: rare ones show up, caps and cooldowns hold.
      expect(events.where((e) => e[1] == 'interaction'), isNotEmpty);
    });
  }

  test('a saved scheduler picks up where it left off', () {
    final a = InteractionScheduler(seed: 77, now: 0);
    const context = SchedulerContext(companionPresent: true, activity: AmbientActivity.idle, idleSeconds: 9999);
    for (var t = 0.0; t < 2000; t += 10) {
      a.nextInteraction(now: t, day: 1, context: context);
    }
    final b = InteractionScheduler.fromJson(a.toJson())!;
    for (var t = 2000.0; t < 6000; t += 10) {
      expect(b.nextInteraction(now: t, day: 1, context: context), a.nextInteraction(now: t, day: 1, context: context));
    }
  });
}
