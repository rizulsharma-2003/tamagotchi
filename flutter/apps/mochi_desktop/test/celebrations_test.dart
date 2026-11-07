// Celebrations from real Claude events (docs/SPRINT_2.md G2) on this PC, end to end from the bridge: a high five for a
// finished turn, a victory dance for a long one (both ends seen live), the tiny trophy for a real build or test result,
// detective mode and case closed, graduation for the first milestone; and never for simulated, late or restored events.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_desktop/src/core/desktop_world.dart';
import 'package:mochi_wire/mochi_wire.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

void main() {
  late DateTime now;
  late double seconds;
  late TestDesktop t;
  late List<w.Celebration> celebrated;
  late StreamSubscription<w.Celebration> subscription;

  setUp(() {
    now = DateTime(2026, 11, 8, 10);
    seconds = 1000;
    t = TestDesktop.make(clock: () => now, uptime: () => seconds);
    celebrated = [];
    subscription = t.desktop.world.celebrated.listen(celebrated.add);
  });
  tearDown(() async {
    await subscription.cancel();
    await t.dispose();
  });

  w.MochiWorld world() => t.desktop.world.world;

  void later(Duration by) {
    final steps = (by.inMilliseconds / 250).ceil();
    for (var i = 0; i < steps; i++) {
      now = now.add(const Duration(milliseconds: 250));
      seconds += 0.25;
      t.desktop.world.tick();
    }
  }

  WireEvent event(String name, {String session = 's1', String? tool, int? id}) =>
      hook(name, session: session, tool: tool, toolUseId: tool == null ? null : 'u-$tool-${id ?? 0}', at: now)
        ..id = 'id-$name-$session-${now.microsecondsSinceEpoch}-${id ?? 0}';

  /// A session that's been open a while, Patch settled in.
  void open({String session = 's1'}) {
    t.desktop.receive(event('SessionStart', session: session));
    later(const Duration(seconds: 6));
  }

  List<w.CelebrationReason> reasons() => [for (final c in celebrated) c.reason];

  group('Real, live moments celebrate', () {
    test('a finished turn: a high five, with Patch, and the confetti', () {
      open();
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(seconds: 30));
      t.desktop.receive(event('Stop'));
      expect(reasons(), [w.CelebrationReason.turnFinished]);
      expect(world().interaction?.id, InteractionID.highFive);
      expect(world().burst, isNotNull);
      expect(t.desktop.world.lastCelebration?.celebration.interaction, InteractionID.highFive);
      expect(DesktopWorld.describeCelebration(celebrated.single, pet: 'Mochi', patch: 'Patch'), 'Mochi and Patch high-five: Claude finished');
    });

    test('a long turn, both ends seen live: a victory dance', () {
      open();
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(minutes: 12));
      t.desktop.receive(event('Stop'));
      expect(reasons(), [w.CelebrationReason.longTurn]);
      expect(world().interaction?.id, InteractionID.victoryDance);
    });

    test('a real test run that passed: the tiny trophy; a piped one (exit status not trustworthy): just a high five', () {
      open();
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(seconds: 5));
      t.desktop.receive(event('PreToolUse', tool: 'Bash'));
      t.desktop.receive(
        event('PostToolUse', tool: 'Bash')
          ..commandKind = 'test'
          ..commandReliable = true
          ..exitCode = 0,
      );
      later(const Duration(seconds: 5));
      t.desktop.receive(event('Stop'));
      expect(reasons().last, w.CelebrationReason.buildTestPassed);
      expect(world().interaction?.id, InteractionID.trophyCelebration);

      later(const Duration(seconds: 15));
      celebrated.clear();
      t.desktop.receive(event('UserPromptSubmit', id: 2));
      later(const Duration(seconds: 5));
      t.desktop.receive(event('PreToolUse', tool: 'Bash', id: 2));
      t.desktop.receive(
        event('PostToolUse', tool: 'Bash', id: 2)
          ..commandKind = 'test'
          ..commandReliable = false
          ..exitCode = 0,
      );
      later(const Duration(seconds: 5));
      t.desktop.receive(event('Stop', id: 2));
      expect(reasons(), [w.CelebrationReason.turnFinished], reason: "a piped test's exit status isn't the tests'");
    });

    test('three tool errors in a row: detective mode; the turn ends: case closed', () {
      open();
      t.desktop.receive(event('UserPromptSubmit'));
      for (var i = 0; i < 3; i++) {
        later(const Duration(seconds: 3));
        t.desktop.receive(event('PreToolUse', tool: 'Bash', id: i));
        t.desktop.receive(event('PostToolUseFailure', tool: 'Bash', id: i));
      }
      expect(reasons(), [w.CelebrationReason.investigating]);
      later(const Duration(seconds: 10));
      t.desktop.receive(event('Stop'));
      expect(reasons().last, w.CelebrationReason.caseClosed);
      expect(world().interaction?.id, InteractionID.caseClosed);
    });

    test('the first milestone (marked in the popover): graduation; a later one: a dance', () {
      open();
      t.desktop.markMilestone();
      expect(reasons(), [w.CelebrationReason.firstMilestone]);
      expect(world().interaction?.id, InteractionID.graduation);
      expect(world().progress.unlockedIDs, contains(w.AchievementID.firstMilestone));
      later(const Duration(seconds: 30));
      t.desktop.markMilestone();
      expect(reasons().last, w.CelebrationReason.milestone);
    });
  });

  group('Never for what didn\'t really happen, just now', () {
    test('simulated activity never reaches Mochi here: no celebration, no moment, no confetti, nothing counted', () {
      open();
      final interactionBefore = world().interaction;
      final simulated = [
        event('SessionStart', session: 'sim')..origin = WireOrigin.simulator,
        event('UserPromptSubmit', session: 'sim')..origin = WireOrigin.simulator,
        event('Stop', session: 'sim')..origin = WireOrigin.simulator,
      ];
      for (final e in simulated) {
        t.desktop.receive(e);
      }
      expect(celebrated, isEmpty);
      expect(world().registry['sim'], isNull);
      expect(world().interaction, interactionBefore);
      expect(world().burst, isNull);
      expect(world().progress.observedTurns, 0);
    });

    test('late events from the spool: history, never a celebration', () {
      open();
      t.desktop.world.ingest(event('UserPromptSubmit'), late: true);
      later(const Duration(minutes: 15));
      t.desktop.world.ingest(event('Stop'), late: true);
      t.desktop.world.ingest(event('Report')..report = const WireReport(kind: 'milestone', status: 'reached'), late: true);
      expect(celebrated, isEmpty);
      expect(world().interaction, isNull);
      expect(world().burst, isNull);
    });

    test('a turn that began while Mochi was away (late) and ends live is no long turn', () {
      open();
      t.desktop.world.ingest(event('UserPromptSubmit'), late: true);
      later(const Duration(minutes: 15));
      t.desktop.receive(event('Stop'));
      expect(reasons(), isNot(contains(w.CelebrationReason.longTurn)));
    });

    test('restored events (the last hours, rebuilt at launch) never celebrate', () {
      open();
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(minutes: 12));
      t.desktop.receive(event('Stop'));
      t.desktop.world.save();
      final again = TestDesktop.make(clock: () => now, uptime: () => seconds, worldStore: MemoryWorldStore(t.worldStore.json));
      addTearDown(again.dispose);
      final heard = <w.Celebration>[];
      final listening = again.desktop.world.celebrated.listen(heard.add);
      addTearDown(listening.cancel);
      for (var i = 0; i < 40; i++) {
        seconds += 0.25;
        again.desktop.world.tick();
      }
      expect(heard, isEmpty);
      expect(again.desktop.world.world.interaction, isNull);
      expect(again.desktop.world.world.burst, isNull);
      expect(again.desktop.world.world.registry['s1'], isNotNull, reason: 'the session is back, quietly');
    });

    test('the same event twice (redelivered) celebrates once', () {
      open();
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(seconds: 20));
      final stop = event('Stop');
      t.desktop.receive(stop);
      t.desktop.receive(stop);
      expect(reasons(), [w.CelebrationReason.turnFinished]);
    });
  });
}
