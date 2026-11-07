// Patch (ui/pet/companion_director.dart), as Mochi's world runs him (core/desktop_world.dart), on the test's clocks:
// when he's around (Settings › Characters), what he does at his desk for each of Claude's phases, his part in Claude's
// moments, the moments he and Mochi share and the Mac's ambient schedule.

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'support/fakes.dart';

void main() {
  late DateTime now;
  late double seconds;
  late TestDesktop t;
  late CompanionDirector patch;

  setUp(() {
    now = DateTime(2026, 11, 7, 10);
    seconds = 1000;
    t = TestDesktop.make(clock: () => now, uptime: () => seconds);
    patch = CompanionDirector(t.desktop.world);
  });

  tearDown(() async {
    patch.dispose();
    await t.dispose();
  });

  /// A live hook event for the world, now.
  void event(String name, {String session = 's1', String? tool, String? notificationType, void Function(WireEvent)? edit}) {
    final wire = hook(name, session: session, tool: tool, toolUseId: tool == null ? null : 'u-$tool', notificationType: notificationType, at: now);
    edit?.call(wire);
    t.desktop.world.ingest(wire);
  }

  /// Both clocks on by [by], the world ticking four times a second meanwhile.
  void later(Duration by) {
    final steps = (by.inMilliseconds / 250).ceil();
    for (var i = 0; i < steps; i++) {
      now = now.add(const Duration(milliseconds: 250));
      seconds += 0.25;
      t.desktop.world.tick();
    }
  }

  group('When Patch is around', () {
    test('while Claude Code is active: he arrives with a welcome, packs up, lingers, then leaves', () {
      expect((patch.present, patch.visible), (false, false), reason: 'no session yet');
      event('SessionStart');
      expect(patch.present, isTrue);
      expect(patch.interaction?.id, InteractionID.welcome, reason: 'he arrives with a hello for Mochi');
      expect(patch.describe('Patch'), 'Patch and Mochi: welcome');
      later(const Duration(seconds: 6));
      expect(patch.together, isFalse);
      event('SessionEnd');
      later(const Duration(minutes: 5));
      expect(patch.present, isTrue, reason: 'he stays a while after the last session');
      later(const Duration(minutes: 6));
      expect(patch.visible, isFalse, reason: 'and leaves when his time is up');
      expect(patch.describe('Patch'), 'Patch is away');
    });

    test('"Stays… after the last session" at 0 sends him off at once', () {
      t.desktop.settings.companionLingerMinutes = 0;
      event('SessionStart');
      later(const Duration(seconds: 6));
      event('SessionEnd');
      later(const Duration(milliseconds: 500));
      expect(patch.departing || !patch.visible, isTrue);
      later(const Duration(seconds: 3));
      expect(patch.visible, isFalse);
    });

    test('Always: there from the start, no session needed; Never: not even with one', () {
      t.desktop.settings.companionVisibility = CompanionVisibility.always;
      later(const Duration(seconds: 6));
      expect(patch.present, isTrue);
      t.desktop.settings.companionVisibility = CompanionVisibility.never;
      later(const Duration(seconds: 3));
      event('SessionStart');
      later(const Duration(seconds: 1));
      expect(patch.visible, isFalse);
    });

    test('pausing reactions: he comes and goes without a fuss', () {
      t.desktop.settings.pauseReactions = true;
      event('SessionStart');
      expect(patch.present, isTrue);
      expect(patch.together, isFalse, reason: 'no welcome while paused');
    });
  });

  group("Patch's states per Claude phase", () {
    test('he works the way Claude works, waits with you, idles between turns and naps when it is quiet', () {
      event('SessionStart');
      later(const Duration(seconds: 6));
      event('UserPromptSubmit');
      later(const Duration(seconds: 1));
      expect(patch.loop, CompanionAnimation.thinking);
      event('PreToolUse', tool: 'Read');
      later(const Duration(seconds: 1));
      expect(patch.loop, CompanionAnimation.reading);
      expect(patch.describe('Patch'), 'Patch is reading');
      event('PostToolUse', tool: 'Read');
      event('Notification', notificationType: 'permission_prompt');
      later(const Duration(seconds: 1));
      expect(patch.loop, CompanionAnimation.waiting);
      expect(patch.waiting, isTrue);
      event('UserPromptSubmit');
      event('Stop');
      later(const Duration(seconds: 8));
      expect(patch.loop, CompanionAnimation.idleAtDesk);
      later(Duration(minutes: t.desktop.settings.companionSleepAfterMinutes + 1));
      expect(patch.loop, CompanionAnimation.sleep, reason: 'he naps when Claude has been quiet a while');
      expect(patch.frameRate(seconds), 6);
    });

    test('his pose is his loop or his moment, from the world; a click gets a wave back', () {
      t.desktop.settings.companionVisibility = CompanionVisibility.always;
      later(const Duration(seconds: 6));
      final loop = patch.frame(seconds, quantum: 1 / 15);
      expect(loop.repeats, isTrue, reason: 'a loop on the ring: its pictures can be kept');
      expect(patch.frameRate(seconds), 10);
      patch.greet();
      expect(patch.busyAt(seconds), isTrue);
      expect(patch.frame(seconds + 0.2).repeats, isFalse, reason: 'his wave is drawn from the art');
      expect(patch.frameRate(seconds), 24);
    });
  });

  group("Claude's moments", () {
    test('a finished turn: a high five with Mochi and a burst of confetti', () {
      event('SessionStart');
      later(const Duration(seconds: 6));
      event('UserPromptSubmit');
      later(const Duration(seconds: 20));
      event('Stop');
      expect(patch.interaction?.id, InteractionID.highFive);
      expect(patch.burst, isNotNull);
      expect(patch.burstAt(seconds + 0.5), closeTo(0.5, 1e-9));
      expect(patch.scene(seconds + 1), isNotNull, reason: 'the moment together has both of them');
      later(const Duration(seconds: 8));
      expect(patch.together, isFalse);
    });

    test('a long turn gets a victory dance, a passing test run a tiny trophy', () {
      event('SessionStart');
      later(const Duration(seconds: 6));
      event('UserPromptSubmit');
      later(const Duration(minutes: 11));
      event('Stop');
      expect(patch.interaction?.id, InteractionID.victoryDance);
      later(const Duration(seconds: 10));
      event('UserPromptSubmit');
      later(const Duration(seconds: 5));
      event('PreToolUse', tool: 'Bash');
      event(
        'PostToolUse',
        tool: 'Bash',
        edit: (wire) => wire
          ..commandKind = 'test'
          ..commandReliable = true
          ..exitCode = 0,
      );
      later(const Duration(seconds: 3));
      event('Stop');
      expect(patch.interaction?.id, InteractionID.trophyCelebration);
      expect(patch.burst?.big, isTrue);
    });

    test('without Patch around, a finished turn is just the confetti', () {
      t.desktop.settings.companionVisibility = CompanionVisibility.never;
      event('SessionStart');
      event('UserPromptSubmit');
      later(const Duration(seconds: 20));
      event('Stop');
      expect(patch.together, isFalse);
      expect(patch.burst, isNotNull);
      expect(patch.frameRate(seconds), 24, reason: 'the burst still needs drawing');
    });
  });

  group('Moments together, now and then', () {
    test("the Mac's ambient interactions: after a while, when nothing urgent is going on", () {
      t.desktop.settings.companionVisibility = CompanionVisibility.always;
      final seen = <InteractionID>{};
      for (var minute = 0; minute < 90 && seen.isEmpty; minute++) {
        later(const Duration(minutes: 1));
        // Mochi stays awake: you're at the PC, playing with it now and then.
        if (minute % 4 == 0) t.desktop.world.interact('pet');
        final id = patch.interaction?.id;
        if (id != null && id != InteractionID.welcome) seen.add(id);
      }
      expect(seen, isNotEmpty);
    });

    test('never while Claude needs you', () {
      event('SessionStart');
      later(const Duration(seconds: 6));
      event('Notification', notificationType: 'permission_prompt');
      for (var minute = 0; minute < 30; minute++) {
        later(const Duration(minutes: 1));
        expect(patch.together, isFalse);
      }
    });
  });
}
