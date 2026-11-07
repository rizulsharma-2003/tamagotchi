// Mochi's world on this PC (core/desktop_world.dart, docs/SPRINT_2.md G1): fed by Claude Code's hook events (live from
// the bridge, late from the spool), the PC's rhythm and Settings; its own moments reach Windows' sounds and
// notifications with the Mac's rules while Claude's keep theirs in Reactions (W1), so nothing is said twice; and what it
// learns is kept across launches.

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/desktop_world.dart';
import 'package:mochi_desktop/src/core/notifications.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/core/toasts.dart';
import 'package:mochi_wire/mochi_wire.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

void main() {
  late DateTime now;
  late double seconds;
  late TestDesktop t;

  setUp(() {
    now = DateTime(2026, 11, 8, 10);
    seconds = 1000;
    t = TestDesktop.make(clock: () => now, uptime: () => seconds);
  });
  tearDown(() => t.dispose());

  w.MochiWorld world() => t.desktop.world.world;

  /// Both clocks on by [by], the world ticking four times a second.
  void later(Duration by) {
    final steps = (by.inMilliseconds / 250).ceil();
    for (var i = 0; i < steps; i++) {
      now = now.add(const Duration(milliseconds: 250));
      seconds += 0.25;
      t.desktop.world.tick();
    }
  }

  WireEvent event(String name, {String session = 's1', String? tool}) =>
      hook(name, session: session, tool: tool, toolUseId: tool == null ? null : 'u-$tool', at: now);

  group('What goes in', () {
    test("hook events from the bridge drive Mochi and Patch; the spool's late ones are only history", () {
      t.desktop.receive(event('SessionStart'));
      expect(world().companionPresent, isTrue, reason: 'Patch arrives with the session');
      later(const Duration(seconds: 6));
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(seconds: 1));
      expect(world().pet.base, PetAnimation.watch, reason: 'Mochi watches Claude work');
      expect(world().progress.unlockedIDs, contains(w.AchievementID.firstSession));

      // Late events (the helper kept them while Mochi wasn't running): sessions and history, never a reaction.
      final token = world().pet.current.token;
      final points = world().progress.observedTurns;
      t.desktop.world.ingest(event('Stop', session: 'late'), late: true);
      expect(world().registry['late'], isNotNull);
      expect(world().pet.current.token, token, reason: 'no reaction to history');
      expect(world().interaction, isNull);
      expect(world().progress.observedTurns, points, reason: 'late events never count');
    });

    test('the spool is drained into the world at launch, late, and its notice says how many', () async {
      // The validator goes by the real clock.
      now = DateTime.now();
      final line = event('SessionStart', session: 'spooled').encodeLine().trim();
      EventSpool.append(line, t.desktop.paths.spoolFile);
      await t.desktop.start();
      expect(world().registry['spooled'], isNotNull);
      expect(world().missed?.delivered, 1);
      expect(world().companionPresent, isFalse, reason: 'a late session start is no arrival');
      expect(world().progress.observedSessions, 0);
    });

    test("the PC's rhythm: Mochi naps while the PC rests and wakes with a stretch when you're back", () {
      final rhythm = t.desktop.rhythm;
      rhythm.report(const SystemActivity(idleSeconds: 30 * 60));
      later(const Duration(minutes: 2));
      expect(t.desktop.world.asleep, isTrue);
      expect(world().pet.base, PetAnimation.sleep);
      rhythm.report(const SystemActivity(idleSeconds: 1));
      later(const Duration(seconds: 1));
      expect(t.desktop.world.asleep, isFalse);
      expect(world().pet.current.animation, PetAnimation.wakeUp);
    });

    test("Settings reach the world: names, Patch's visibility, pausing, life stages", () {
      t.desktop.settings
        ..petName = 'Biscuit'
        ..companionName = 'Byte'
        ..companionVisibility = CompanionVisibility.always
        ..pauseReactions = true;
      final settings = world().settings;
      expect((settings.petName, settings.companionName, settings.companionVisibility, settings.pauseReactions), (
        'Biscuit',
        'Byte',
        w.CompanionVisibility.always,
        true,
      ));
      expect(world().companionPresent, isTrue);
      t.desktop.settings.lifeStages = false;
      expect(t.desktop.world.stage, LifeStage.grownUp);
      expect(PetRenderer.stage, LifeStage.grownUp);
    });

    test("this PC's moments: a pet, play or treat here or from a phone counts, with the Mac's daily caps", () {
      for (var i = 0; i < 12; i++) {
        t.desktop.interact('pet');
        later(const Duration(seconds: 4));
      }
      expect(world().progress.affectionPoints, 8, reason: 'petting earns at most 8 points a day');
      t.desktop.cue(PetCue.treat);
      expect(world().pet.current.animation, PetAnimation.treat);
      t.desktop.cue(PetCue.replied);
      later(const Duration(seconds: 6));
      t.desktop.cue(PetCue.failed);
      expect(world().pet.current.animation, PetAnimation.concerned, reason: 'Ask Mochi going wrong');
    });

    test('Mochi\'s window or popover open: the world knows you\'re looking (no badges from it, greetings can be said)', () {
      t.desktop.world.setWindowVisible(true);
      expect((world().windowVisible, t.desktop.world.speech.windowVisible), (true, true));
      t.desktop.world.setWindowVisible(false);
      expect(world().windowVisible, isFalse);
    });
  });

  group('What comes out', () {
    setUp(() async {
      t.desktop.settings
        ..soundEnabled = true
        ..setDelivery(NotificationCategory.turnCompleted, const CategoryDelivery(banner: true, sound: true))
        ..setDelivery(NotificationCategory.achievement, const CategoryDelivery(banner: true, sound: true));
      await t.desktop.start();
    });

    test("Claude's moments: one Windows notification and one sound (Reactions'), the world only animates them", () {
      t.desktop.receive(event('SessionStart'));
      later(const Duration(seconds: 6));
      final before = (t.toasts.shown.length, t.sound.played.length);
      now = now.add(const Duration(minutes: 1));
      t.desktop.receive(event('UserPromptSubmit'));
      later(const Duration(seconds: 20));
      t.desktop.receive(event('Stop'));
      final turn = t.toasts.shown.skip(before.$1).where((toast) => toast.title == 'Claude finished responding');
      expect(turn, hasLength(1), reason: 'not twice');
      expect(world().interaction?.id, InteractionID.highFive, reason: 'the world celebrates it');
    });

    test('its own moments: an achievement plays its sound and shows a notification, as Settings › Notifications says', () {
      final sounds = t.sound.played.length;
      t.desktop.receive(event('SessionStart'));
      expect(world().progress.unlockedIDs, contains(w.AchievementID.firstSession));
      final achievement = t.toasts.shown.where((toast) => toast.title.startsWith('Achievement unlocked'));
      expect(achievement.single.title, 'Achievement unlocked: Hello, Patch');
      expect(achievement.single.target, ToastTarget.main);
      expect(t.sound.played.length, greaterThan(sounds));
      expect(world().activeToast?.title, 'Achievement: Hello, Patch', reason: 'and a note at the top of the scene');
    });

    test('petting purrs (a pop) with sounds on, and stays quiet in quiet mode', () {
      final sounds = t.sound.played.length;
      t.desktop.interact('pet');
      expect(t.sound.played.length, sounds + 1);
      t.desktop.settings.quietMode = true;
      later(const Duration(seconds: 3));
      t.desktop.interact('pet');
      expect(t.sound.played.length, sounds + 1);
    });
  });

  group('Kept across launches', () {
    test('friendship, achievements, the seed and the last hours of real events; restored events never react', () async {
      t.desktop.receive(event('SessionStart'));
      t.desktop.interact('play');
      later(const Duration(seconds: 2));
      t.desktop.receive(event('UserPromptSubmit'));
      t.desktop.world.save();
      final saved = t.worldStore.json!;
      expect(saved['seed'], 0x5EED5);
      expect((saved['world']! as Map)['history'], isNotEmpty);

      final again = TestDesktop.make(clock: () => now, uptime: () => seconds, worldStore: MemoryWorldStore(saved), worldSeed: null);
      addTearDown(again.dispose);
      final restored = again.desktop.world.world;
      expect(restored.seed, 0x5EED5, reason: "Mochi's habits stay its own");
      expect(restored.progress.affectionPoints, 2);
      expect(restored.progress.unlockedIDs, contains(w.AchievementID.firstSession));
      expect(restored.registry['s1']?.phase, w.SessionPhase.promptSubmitted, reason: "Claude's session is rebuilt");
      expect(restored.interaction, isNull, reason: 'without reacting');
    });

    test("Claude Code's notification text isn't kept on disk, only the events", () {
      t.desktop.receive(event('SessionStart'));
      t.desktop.receive(hook('Notification', notificationType: 'permission_prompt', at: now)..message = 'Claude needs your permission to use Bash');
      t.desktop.world.save();
      final history = (t.worldStore.json!['world']! as Map)['history']! as List;
      expect(history, hasLength(2));
      expect(history.every((e) => !(e as Map).containsKey('message')), isTrue);
      expect(world().registry['s1']?.phase, w.SessionPhase.waitingForUser, reason: 'in memory, the session is as it was');
    });

    test('a damaged or missing file starts afresh', () {
      final fresh = TestDesktop.make(worldStore: MemoryWorldStore({'world': 'nonsense', 'seed': 'x'}));
      addTearDown(fresh.dispose);
      expect(fresh.desktop.world.world.progress.affectionPoints, 0);
    });
  });
}
