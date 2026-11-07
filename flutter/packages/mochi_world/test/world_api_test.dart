// The parts of MochiWorld's API the Swift fixtures don't cover: persistence, settings JSON, speech and determinism.

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

class _Clock {
  DateTime date = DateTime.utc(2027, 1, 15, 8);
  double uptime = 1000;

  void advance(double seconds) {
    date = date.add(Duration(microseconds: (seconds * 1e6).round()));
    uptime += seconds;
  }
}

class _Effects extends WorldEffects {
  final sounds = <SoundCue>[];
  final reacted = <String>[];

  @override
  void play(SoundCue sound) => sounds.add(sound);

  @override
  void worldDidReact(CompanionEvent event, SessionSnapshot? session) => reacted.add(event.id);
}

MochiWorld _world(_Clock clock, {int seed = 5, WorldEffects? effects, WorldSettings settings = const WorldSettings(soundEnabled: true)}) =>
    MochiWorld(
      settings: settings,
      seed: seed,
      clock: () => clock.date,
      uptime: () => clock.uptime,
      calendar: const WorldCalendar.utc(),
      achievements: AchievementEngine(calendar: const WorldCalendar.utc()),
      effects: effects,
      newID: () => 'fixed',
    );

Map<String, Object?> _wire(String id, String event, _Clock clock, {String session = 's1', Map<String, Object?> extra = const {}}) => {
  'v': 1,
  'id': id,
  'ts': clock.date.microsecondsSinceEpoch / 1e6,
  'origin': 'hook',
  'event': event,
  'session': session,
  'project': 'InsideEdge',
  'projectKey': 'k1',
  ...extra,
};

void _run(MochiWorld world, _Clock clock, double seconds) {
  for (var t = 0.0; t < seconds; t += 0.25) {
    clock.advance(0.25);
    world.tick();
  }
}

void main() {
  test('toJson keeps progress and recent history; restore rebuilds sessions without reacting', () {
    final clock = _Clock();
    final world = _world(clock);
    world.ingestWire(_wire('a', 'SessionStart', clock));
    _run(world, clock, 2);
    world.ingestWire(_wire('b', 'UserPromptSubmit', clock));
    world.ingestWire(_wire('c', 'PreToolUse', clock, extra: {'tool': 'Read', 'toolCategory': 'read', 'toolUseId': 't1'}));
    world.interact(PetInteraction.pet);
    _run(world, clock, 1);
    final saved = world.toJson();
    expect(saved['history'], hasLength(3));

    final effects = _Effects();
    final again = _world(clock, effects: effects);
    again.restore(saved);
    expect(again.primarySession?.phase, SessionPhase.runningTool);
    expect(again.progress.affectionPoints, 1);
    expect(again.progress.unlockedIDs, contains(AchievementID.firstSession));
    expect(again.companionPresent, isTrue);
    expect(effects.reacted, isEmpty);
    // Events it already has are duplicates.
    again.ingestWire(_wire('c', 'PreToolUse', clock, extra: {'tool': 'Read', 'toolCategory': 'read', 'toolUseId': 't1'}));
    expect(again.diagnostics.duplicatesIgnored, 1);
    _run(again, clock, 1);
    expect(again.companion.base, CompanionAnimation.reading);
  });

  test('the same seed and inputs give the same frames; another seed gives other blinks and picks', () {
    List<String> frames(int seed) {
      final clock = _Clock();
      final world = _world(
        clock,
        seed: seed,
        settings: const WorldSettings(companionVisibility: CompanionVisibility.always),
      );
      final out = <String>[];
      for (var i = 0; i < 2400; i++) {
        clock.advance(0.25);
        world.tick();
        if (i % 40 == 0) {
          final f = world.frame();
          out.add('${world.pet.current.animation.name} ${f.pet.eyeOpenness.toStringAsFixed(6)} ${f.companion.lookX.toStringAsFixed(6)}');
        }
      }
      return out;
    }

    expect(frames(11), frames(11));
    expect(frames(11), isNot(frames(12)));
  });

  test('WorldSettings reads the Mac\'s AppSettings JSON (unknown keys ignored, bad values take defaults)', () {
    final settings = WorldSettings.fromJson({
      'petName': 'Momo',
      'companionVisibility': 'always',
      'animationIntensity': 'lively',
      'reducedMotion': 'nonsense',
      'longTurnMinutes': 3,
      'categoryDelivery': {
        'turnCompleted': {'animate': true, 'badge': false, 'banner': true, 'sound': false},
      },
      'speech': {'enabled': false, 'chattiness': 'chatty', 'useAppleIntelligence': true},
      'menuBarStyle': 'roam',
    });
    expect(settings.petName, 'Momo');
    expect(settings.companionVisibility, CompanionVisibility.always);
    expect(settings.animationIntensity, AnimationIntensity.lively);
    expect(settings.reducedMotion, ReducedMotionPreference.system);
    expect(settings.longTurnMinutes, 3);
    expect(settings.delivery(NotificationCategory.turnCompleted).banner, isTrue);
    expect(settings.delivery(NotificationCategory.toolActivity).banner, isFalse);
    expect(settings.speechEnabled, isFalse);
    expect(settings.chattiness, Chattiness.chatty);
    expect(WorldSettings.fromJson(settings.toJson()).toJson(), settings.toJson());
  });

  test('speech bubbles show for their time, only while speech is on', () {
    final clock = _Clock();
    final world = _world(clock);
    world.say('  Hello!  ');
    expect(world.activeSpeech?.text, 'Hello!');
    clock.advance(4.6);
    expect(world.activeSpeech, isNull);
    world.say('Again', speaker: SpeechSpeaker.companion, duration: 2);
    final id = world.speech!.id;
    world.clearSpeech(id - 1);
    expect(world.activeSpeech?.speaker, SpeechSpeaker.companion);
    world.clearSpeech(id);
    expect(world.speech, isNull);
    world.settings = world.settings.copyWith(speechEnabled: false);
    world.say('Quiet');
    expect(world.speech, isNull);
  });

  test('a milestone marked by hand graduates', () {
    final clock = _Clock();
    final world = _world(clock, settings: const WorldSettings(companionVisibility: CompanionVisibility.always));
    _run(world, clock, 5);
    world.markMilestone(label: '  shipped\n the   beta ');
    expect(world.interaction?.id, InteractionID.graduation);
    expect(world.progress.milestones, 1);
    expect(world.timeline.last.report?.label, 'shipped the beta');
    _run(world, clock, 8);
    expect(world.interaction, isNull);
  });

  test('the animator and scheduler survive JSON', () {
    final animator = CharacterAnimator<PetAnimation>(base: PetAnimation.watch, at: 3);
    animator.play(PetAnimation.nod, priority: AnimationPriority.reaction, at: 4);
    final copy = CharacterAnimator.fromJson(animator.toJson(), PetAnimation.values)!;
    expect(copy.toJson(), animator.toJson());
    expect(copy.play(PetAnimation.nod, priority: AnimationPriority.user, at: 5), isA<PlayCoolingDown>());
  });
}
