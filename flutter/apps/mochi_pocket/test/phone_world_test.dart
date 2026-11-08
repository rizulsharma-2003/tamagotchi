// Mochi's world on the phone (A5): it follows the computer as the iPhone's PhoneWorld does. Claude's state there plays
// here as simulated events that never count; petting, play and treats go both ways without being counted twice; the
// look's names and holidays come from the computer; and it ticks only while the room can be seen.

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/scene/phone_world.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_world/mochi_world.dart';

import 'support/fakes.dart';

void main() {
  late FakeRelay relay;
  late PocketModel model;
  late PhoneWorld phone;
  late DateTime date;
  late double uptime;

  setUp(() async {
    relay = FakeRelay();
    model = PocketModel(
      credentialStore: MemoryCredentialStore(phoneCredentials),
      doneDocument: MemoryDocument(),
      notifier: FakeNotifier(),
      connect: relay.connect,
      deviceName: 'realme RMX3242',
    );
    // A Diwali afternoon (Lakshmi Puja 2026 is 8 November).
    date = DateTime(2026, 11, 8, 14);
    uptime = 1000;
    phone = PhoneWorld(model: model, seed: 42, clock: () => date, uptime: () => uptime, toolDelay: const Duration(milliseconds: 150));
    await model.load();
    await pumpEventQueue();
    relay.devices(online: true);
    relay.presence(macOnline: true);
    relay.fromMac(LinkKey.look, sampleLook().toValue());
    await pumpEventQueue();
  });

  tearDown(() {
    phone.dispose();
    model.dispose();
  });

  MochiWorld world() => phone.world;

  /// [seconds] pass on both clocks while the world ticks at 4 Hz.
  void pass(double seconds) {
    for (var t = 0.0; t < seconds; t += 0.25) {
      date = date.add(const Duration(milliseconds: 250));
      uptime += 0.25;
      phone.tick();
    }
  }

  Future<void> claude(String phase, {String? category, bool resting = false}) async {
    relay.fromMac(LinkKey.claude, ClaudeMirror(phase: phase, category: category, resting: resting, at: now()).toValue());
    await pumpEventQueue();
  }

  List<String?> sentKinds() => [for (final value in relay.sentValues(LinkKey.phoneInteraction)) LinkInteraction.fromValue(value)?.kind];

  group('Claude on the computer', () {
    test('plays here as a simulated mirror session: Patch works the way Claude works and Mochi watches', () async {
      await claude('working', category: 'edit');
      expect(world().sessions.single.isSimulated, isTrue);
      expect(world().companion.base, CompanionAnimation.typing);
      expect(world().pet.base, PetAnimation.watch);
      const loops = {
        'read': CompanionAnimation.reading,
        'search': CompanionAnimation.searching,
        'shell': CompanionAnimation.runningCommand,
        'web': CompanionAnimation.browsing,
        'agent': CompanionAnimation.delegating,
        'think': CompanionAnimation.thinking,
      };
      for (final MapEntry(key: category, value: loop) in loops.entries) {
        await claude('working', category: category);
        pass(0.5);
        expect(world().companion.base, loop, reason: category);
        expect(world().pet.base, PetAnimation.watch, reason: category);
      }
      // The tool "finishes" a moment later, as on the iPhone.
      await claude('working', category: 'edit');
      expect(world().sessions.single.currentTool?.name, 'Edit');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(world().sessions.single.currentTool, isNull);
      await claude('working', category: 'think');
      expect(phone.describe(), 'Mochi is watching Claude work. Patch is thinking');
    });

    test('a finished turn is a high five, a snag a worried look, and waiting a wave; none of it counts', () async {
      await claude('working', category: 'edit');
      pass(2);
      await claude('done');
      expect(world().interaction?.id, InteractionID.highFive);
      pass(10);
      await claude('working', category: 'shell');
      pass(2);
      await claude('waiting');
      pass(4);
      expect(world().pet.base, PetAnimation.waveGently);
      expect(world().companion.base, CompanionAnimation.waiting);
      expect(world().status.mood, WorldMood.waiting);
      expect(phone.describe(), startsWith('Claude needs you.'));
      await claude('error');
      expect(world().pet.current.animation, PetAnimation.concerned);
      await claude('none');
      expect(world().sessions.single.phase, SessionPhase.ended);

      // The computer counts Claude's work; the phone mirrors it and never counts it, keeps it or announces it.
      final progress = world().progress;
      expect(progress.observedSessions, 0);
      expect(progress.observedTurns, 0);
      expect(progress.projectKeys, isEmpty);
      expect(progress.unlocked, isEmpty);
      expect(world().diagnostics.simulatedEvents, greaterThan(8));
      expect(world().toJson()['history'], isEmpty, reason: 'simulated events are never kept');
      expect(world().attention, isNull, reason: 'no badges for simulated events');
    });

    test('a tool still running when Claude needs you finishes first: Mochi keeps waving', () async {
      await claude('working', category: 'edit');
      await claude('working', category: 'shell');
      await claude('waiting');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      pass(1);
      expect(world().sessions.single.phase, SessionPhase.waitingForUser);
      expect(world().pet.base, PetAnimation.waveGently);
      final names = [for (final event in world().timeline) event.rawName];
      expect(names.sublist(names.length - 3), ['PreToolUse', 'PostToolUse', 'Notification']);
    });

    test('the first state seen sets the scene quietly: no high five for a turn that ended before you looked', () async {
      await claude('done');
      expect(world().interaction, isNull);
      expect(world().pet.isPlayingOneShot, isFalse);
      expect(world().sessions.single.phase, SessionPhase.turnCompleted);
      await claude('working', category: 'edit');
      pass(2);
      await claude('done');
      expect(world().interaction?.id, InteractionID.highFive, reason: 'later changes react');
    });

    test('Mochi naps while the computer rests and wakes with a stretch when it is in use again', () async {
      await claude('idle', resting: true);
      pass(70);
      expect(world().petAsleep, isTrue);
      expect(phone.napping, isFalse, reason: 'Patch is still up at his desk');
      // Patch nods off after a quiet while (Settings › Characters on the computer; 6 minutes by default).
      pass(330);
      expect(world().companion.base, CompanionAnimation.sleep);
      expect(phone.napping, isTrue);
      expect(phone.describe(), startsWith('Mochi is napping.'));
      await claude('idle');
      pass(0.5);
      expect(world().petAsleep, isFalse);
      expect(world().pet.current.animation, PetAnimation.wakeUp);
    });
  });

  group('petting, play and treats', () {
    test("the phone's own play here and go to the computer, which counts them; the computer's play here and aren't sent "
        'back', () async {
      model.interact('pet');
      await pumpEventQueue();
      expect(world().pet.current.animation, PetAnimation.petted);
      expect(sentKinds(), ['pet']);
      pass(6);
      relay.fromMac(LinkKey.macInteraction, LinkInteraction(id: 'mac-1', kind: 'treat', at: now()).toValue());
      await pumpEventQueue();
      expect(world().pet.current.animation, PetAnimation.treat);
      expect(sentKinds(), ['pet'], reason: "the computer's treat isn't echoed, so it's never counted twice");
      pass(10);
      // The same one again, or one from long ago: nothing.
      relay.fromMac(LinkKey.macInteraction, LinkInteraction(id: 'mac-1', kind: 'treat', at: now()).toValue());
      relay.fromMac(LinkKey.macInteraction, LinkInteraction(id: 'mac-2', kind: 'play', at: now() - 300).toValue());
      await pumpEventQueue();
      expect(world().pet.isPlayingOneShot, isFalse);
    });

    test("the friendship shown is the computer's: the phone's petting isn't kept or shown", () async {
      for (var i = 0; i < 30; i++) {
        model.interact('pet');
        await pumpEventQueue();
        pass(3);
      }
      expect(model.friendshipLevel, 3, reason: "the look's level, the computer's");
      expect(world().achievements.onChange, isNull, reason: 'nothing the phone counts is written anywhere');
      expect(sentKinds(), hasLength(30));
    });
  });

  group('the look', () {
    test("names from the computer; today's holiday from its settings", () async {
      expect(world().settings.companionVisibility, CompanionVisibility.always);
      expect(phone.season, SeasonalEvent.diwali);
      relay.fromMac(
        LinkKey.look,
        const PetLook(
          petName: 'Kiwi',
          companionName: 'Bolt',
          petColor: 'mint',
          theme: 'gardenOffice',
          seasonal: {'enabled': false, 'decorateMenuBar': true},
          friendshipLevel: 2,
        ).toValue(),
      );
      await pumpEventQueue();
      expect(world().settings.petName, 'Kiwi');
      expect(world().settings.companionName, 'Bolt');
      expect(phone.season, isNull, reason: 'decorations off on the computer');
      relay.fromMac(
        LinkKey.look,
        const PetLook(
          petName: 'Kiwi',
          companionName: 'Bolt',
          petColor: 'mint',
          theme: 'gardenOffice',
          seasonal: {'enabled': true, 'birthdayMonth': 11, 'birthdayDay': 8, 'decorateMenuBar': true},
          friendshipLevel: 2,
        ).toValue(),
      );
      await pumpEventQueue();
      expect(phone.season, SeasonalEvent.userBirthday);
    });
  });

  group('ticking', () {
    test('only while the room can be seen', () {
      expect(phone.ticking, isFalse, reason: 'nothing ticks until the room shows');
      phone.roomVisible(true);
      expect(phone.ticking, isTrue);
      phone.roomVisible(false);
      expect(phone.ticking, isFalse);
      phone.roomVisible(true);
      phone.dispose();
      expect(phone.ticking, isFalse);
      phone = PhoneWorld(model: model);
    });

    test('a moment is busy (smooth drawing); a nap barely moves', () async {
      expect(phone.busy, isFalse);
      model.interact('play');
      await pumpEventQueue();
      expect(phone.busy, isTrue);
      expect(phone.napping, isFalse);
    });
  });
}
