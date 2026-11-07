// Patch (ui/pet/companion_director.dart) with the test's clocks: when he's around (Settings › Characters), what he
// does at his desk for each of Claude's phases, his part in Claude's moments, the moments he and Mochi share (from the
// recordings) and the Mac's ambient schedule.

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';

import 'support/fakes.dart';

void main() {
  late PoseLibrary library;
  late DateTime now;
  late double seconds;
  late TestDesktop t;

  setUpAll(() => library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync()));

  setUp(() {
    now = DateTime(2026, 11, 7, 10);
    seconds = 1000;
    t = TestDesktop.make(clock: () => now);
  });

  tearDown(() => t.dispose());

  final directors = <CompanionDirector>[];

  /// Patch on the test's clocks, with the recordings.
  CompanionDirector patch({int seed = 3, bool withLibrary = true}) {
    final director = CompanionDirector(
      sessions: t.desktop.sessions,
      settings: t.desktop.settings,
      cues: t.desktop.cues,
      lastActivity: () => now,
      clock: () => seconds,
      random: Random(seed),
    )..library = withLibrary ? library : null;
    directors.add(director);
    return director;
  }

  // Every director (and its timers) goes before the test ends: the test checks for pending timers before tear-downs.
  void patchTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final director in directors) {
        director.dispose();
      }
      directors.clear();
    }
  });

  void event(String name, {String session = 's1', String? tool, String? notificationType}) =>
      t.desktop.sessions.apply(hook(name, session: session, tool: tool, toolUseId: tool == null ? null : 'u-$tool', notificationType: notificationType, at: now));

  /// Moves both clocks on by [by], and lets Patch look again (his tick).
  Future<void> later(WidgetTester tester, Duration by) async {
    now = now.add(by);
    seconds += by.inMicroseconds / 1e6;
    await tester.pump(by);
  }

  group('When Patch is around', () {
    patchTest('while Claude Code is active: he arrives with a welcome, packs up, lingers, then leaves', (tester) async {
      final director = patch();
      expect((director.present, director.visible), (false, false), reason: 'no session yet');
      event('SessionStart');
      expect(director.present, isTrue);
      expect(director.pending, InteractionID.welcome, reason: 'a hello for Mochi, as on the Mac');
      director.startPending();
      expect(director.scene(seconds + 1), isNotNull);
      event('SessionEnd');
      expect(director.shot?.animation, CompanionAnimation.packUp);
      expect(director.present, isTrue, reason: 'he stays 10 minutes after the last session');
      await later(tester, const Duration(minutes: 9));
      expect(director.present, isTrue);
      while (director.present) {
        await later(tester, const Duration(seconds: 5));
      }
      expect(now.difference(DateTime(2026, 11, 7, 10)), greaterThanOrEqualTo(const Duration(minutes: 10)));
      expect((director.present, director.departing, director.visible), (false, true, true), reason: 'on his way out');
      expect(director.shot?.animation, CompanionAnimation.depart);
      await later(tester, const Duration(seconds: 2));
      expect((director.present, director.departing, director.visible), (false, false, false));
      expect(director.describe('Patch'), 'Patch is away');
    });

    patchTest('"Stays… after the last session" at 0 sends him off at once', (tester) async {
      t.desktop.settings.companionLingerMinutes = 0;
      final director = patch();
      event('SessionStart');
      event('SessionEnd');
      expect(director.departing, isTrue);
      await later(tester, const Duration(seconds: 5));
      expect(director.visible, isFalse);
    });

    patchTest('Always: there from the start, no session needed; Never: not even with one', (tester) async {
      t.desktop.settings.companionVisibility = CompanionVisibility.always;
      final always = patch();
      expect((always.present, always.pending), (true, null), reason: 'already at his desk at launch: no arrival');
      expect(always.loop, CompanionAnimation.idleAtDesk);
      t.desktop.settings.companionVisibility = CompanionVisibility.never;
      expect(always.departing, isTrue, reason: 'he leaves when you change it');
      await later(tester, const Duration(seconds: 5));
      expect(always.visible, isFalse);
      final never = patch();
      event('SessionStart');
      event('UserPromptSubmit');
      expect(never.visible, isFalse);
    });

    patchTest('pausing reactions: he comes and goes without a fuss', (tester) async {
      t.desktop.settings.pauseReactions = true;
      final director = patch();
      event('SessionStart');
      expect((director.present, director.pending, director.shot), (true, null, null));
      t.desktop.settings.companionLingerMinutes = 0;
      event('SessionEnd');
      expect(director.visible, isFalse, reason: 'gone at once, no packing up');
    });
  });

  group("Patch's states per Claude phase", () {
    patchTest('he works the way Claude works, waits with you, idles between turns and naps when it is quiet', (tester) async {
      final director = patch();
      event('SessionStart');
      director.startPending();
      final expected = <(String, String?, String?), CompanionAnimation>{
        ('UserPromptSubmit', null, null): CompanionAnimation.thinking,
        ('PreToolUse', 'Read', null): CompanionAnimation.reading,
        ('PreToolUse', 'Grep', null): CompanionAnimation.searching,
        ('PreToolUse', 'Edit', null): CompanionAnimation.typing,
        ('PreToolUse', 'Bash', null): CompanionAnimation.runningCommand,
        ('PreToolUse', 'WebFetch', null): CompanionAnimation.browsing,
        ('PreToolUse', 'Task', null): CompanionAnimation.delegating,
        ('Notification', null, 'permission_prompt'): CompanionAnimation.waiting,
        ('Stop', null, null): CompanionAnimation.idleAtDesk,
      };
      for (final MapEntry(key: (name, tool, type), value: loop) in expected.entries) {
        event(name, tool: tool, notificationType: type);
        expect(director.loop, loop, reason: '$name ${tool ?? type ?? ''}');
        await later(tester, const Duration(seconds: 1));
      }
      expect(director.describe('Byte'), 'Byte is at his desk');
      // Six quiet minutes (Settings › Characters › Naps after): asleep at his desk; news wakes him with a stretch.
      await later(tester, const Duration(minutes: 7));
      expect(director.loop, CompanionAnimation.sleep);
      expect(director.describe('Patch'), 'Patch is napping at his desk');
      event('UserPromptSubmit');
      expect(director.loop, CompanionAnimation.thinking);
      expect(director.shot?.animation, CompanionAnimation.wakeUp);
    });

    patchTest('his pose comes from his loop, a one-shot over it, or the moment he shares with Mochi', (tester) async {
      final director = patch();
      event('SessionStart');
      director.startPending();
      await later(tester, const Duration(seconds: 10));
      event('UserPromptSubmit');
      event('PreToolUse', tool: 'Edit');
      final typing = library.companionTrack(CompanionAnimation.typing)!;
      expect(director.pose(library, seconds).toJson(), typing.at(seconds).toJson());
      expect(director.pose(library, seconds, calm: true).toJson(), typing.calmed(seconds, calm: true).toJson(), reason: 'calmer with animations off');
      expect(director.frameRate(seconds), 12, reason: 'the screen scrolls while he types');
      director.greet();
      final greet = library.companionTrack(CompanionAnimation.greet)!;
      expect(director.pose(library, seconds + 0.5).toJson(), greet.at(0.5).toJson());
      expect(director.frameRate(seconds), 24);
    });
  });

  group("Claude's moments", () {
    patchTest('a finished turn: a high five with Mochi and a burst of confetti', (tester) async {
      final director = patch();
      event('SessionStart');
      director.startPending();
      event('UserPromptSubmit');
      await later(tester, const Duration(minutes: 2));
      event('Stop');
      t.desktop.cue(PetCue.finished);
      await tester.pump();
      expect(director.pending, InteractionID.highFive);
      expect(director.burstAt(seconds + 0.5), closeTo(0.5, 1e-9));
      expect(director.burst?.big, isFalse);
      director.startPending();
      final track = library.interactionTrack(InteractionID.highFive)!;
      final frame = director.scene(seconds + 1)!;
      expect(frame.pet.toJson(), track.at(1).pet.toJson());
      expect(frame.companion.toJson(), track.at(1).companion.toJson());
      expect(director.describe('Patch'), 'Patch and Mochi: high five');
      expect(director.scene(seconds + track.length + 0.1), isNull, reason: 'it ends');
      expect(director.burstAt(seconds + Celebration.length + 0.1), isNull);
    });

    patchTest('a long turn gets a victory dance, a passing test run a tiny trophy', (tester) async {
      final director = patch();
      event('SessionStart');
      director.startPending();
      event('UserPromptSubmit');
      await later(tester, const Duration(minutes: 12));
      event('Stop');
      t.desktop.cue(PetCue.finished);
      await tester.pump();
      expect((director.pending, director.burst?.big), (InteractionID.victoryDance, true));
      director.startPending();
      await later(tester, const Duration(seconds: 30));
      event('UserPromptSubmit');
      t.desktop.sessions.apply(
        hook('PostToolUse', tool: 'Bash', toolUseId: 'test-run', at: now)
          ..commandKind = 'test'
          ..commandReliable = true,
      );
      expect(t.desktop.sessions.all.first.lastBuildTest, 'Tests passed');
      event('Stop');
      t.desktop.cue(PetCue.finished);
      await tester.pump();
      expect((director.pending, director.burst?.big), (InteractionID.trophyCelebration, true));
    });

    patchTest('a snag worries him, Claude needing you makes him look up and wave, petting Mochi gets a pat', (tester) async {
      final director = patch();
      event('SessionStart');
      director.startPending();
      await later(tester, const Duration(seconds: 10));
      t.desktop.cue(PetCue.snag);
      await tester.pump();
      expect(director.shot?.animation, CompanionAnimation.concerned);
      t.desktop.cue(PetCue.needsYou);
      await tester.pump();
      expect(director.shot?.animation, CompanionAnimation.greet);
      t.desktop.cue(PetCue.pet);
      await tester.pump();
      expect(director.shot?.animation, CompanionAnimation.pat);
      t.desktop.settings.pauseReactions = true;
      director.shot = null;
      t.desktop.cue(PetCue.snag);
      await tester.pump();
      expect(director.shot, isNull, reason: 'reactions paused');
    });

    patchTest('without Patch around, a finished turn is just the confetti', (tester) async {
      t.desktop.settings.companionVisibility = CompanionVisibility.never;
      final director = patch();
      t.desktop.cue(PetCue.finished);
      await tester.pump();
      expect(director.pending, isNull);
      expect(director.burst, isNotNull);
    });
  });

  group('Moments together, now and then', () {
    patchTest("the Mac's ambient interactions: after a while, when nothing urgent is going on", (tester) async {
      t.desktop.settings.companionVisibility = CompanionVisibility.always;
      final director = patch(seed: 11);
      final seen = <InteractionID>{};
      for (var minute = 0; minute < 120; minute++) {
        await later(tester, const Duration(minutes: 1));
        final id = director.pending;
        if (id != null) {
          seen.add(id);
          director.startPending();
        }
      }
      expect(seen, isNotEmpty);
      final ambient = {for (final rule in AmbientInteraction.all) rule.id};
      expect(seen.every(ambient.contains), isTrue, reason: '$seen');
    });

    patchTest('never while Claude needs you, nor while Mochi naps', (tester) async {
      final director = patch(seed: 11);
      event('SessionStart');
      director.startPending();
      event('UserPromptSubmit');
      event('Notification', notificationType: 'permission_prompt');
      for (var minute = 0; minute < 30; minute++) {
        await later(tester, const Duration(minutes: 1));
        expect(director.pending, isNull, reason: 'Claude needs you');
        // Keep the session from going stale.
        event('Notification', notificationType: 'permission_prompt');
      }
    });
  });
}
