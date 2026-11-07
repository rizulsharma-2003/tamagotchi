// W11: speech lines, picks, pacing and clean-up against the Swift engine (link-spec/world/speech.json).

import 'package:mochi_world/mochi_world.dart';
import 'package:mochi_world/src/features/text.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final fixture = readWorldFixture('speech.json');

  test('every occasion: importance, situation, the lines and their picks', () {
    final occasions = objs(fixture['occasions']);
    expect(occasions.map((o) => o['occasion']), SpeechOccasion.values.map((o) => o.name));
    for (final o in occasions) {
      final occasion = byName(SpeechOccasion.values, o['occasion']);
      expect(occasion.importance.name, o['importance'], reason: occasion.name);
      expect(occasion.situation, o['situation'], reason: occasion.name);
      final lines = SpeechLines.lines(occasion);
      final expected = (o['lines']! as List).cast<List<Object?>>();
      expect(
        [
          for (final l in lines) [l.speaker.name, l.text, characterCount(l.text)],
        ],
        expected,
        reason: occasion.name,
      );
      for (final pick in (o['picks']! as List).cast<List<Object?>>()) {
        final seed = parseUnsigned(pick[0]);
        final avoid = pick[1]! as int;
        final line = SpeechLines.pick(occasion, seed, avoiding: lines.take(avoid).map((l) => l.text).toList());
        expect(line?.text, pick[2], reason: '${occasion.name} seed ${pick[0]} avoiding $avoid');
      }
    }
  });

  test('pacing for every chattiness, occasion and gap', () {
    final sinces = (fixture['sinces']! as List).map((s) => (s as num).toDouble()).toList();
    for (final p in objs(fixture['pacing'])) {
      final pacing = SpeechPacing(byName(Chattiness.values, p['chattiness']));
      expect(pacing.idleInterval, p['idleInterval'], reason: '${p['chattiness']} idle');
      expect(pacing.sleepInterval, p['sleepInterval'], reason: '${p['chattiness']} sleep');
      for (final MapEntry(:key, :value) in obj(p['allows']).entries) {
        final occasion = byName(SpeechOccasion.values, key);
        expect(sinces.map((s) => pacing.allows(occasion, s) ? '1' : '0').join(), value, reason: '${p['chattiness']} $key');
      }
    }
  });

  test('greetings by hour', () {
    expect([for (var h = 0; h < 24; h++) SpeechOccasion.greeting(h).name], fixture['greetings']);
  });

  test('generated lines are cleaned up as on the Mac (Swift character counts included)', () {
    for (final c in objs(fixture['sanitize'])) {
      final raw = c['raw']! as String;
      expect(characterCount(raw), c['count'], reason: 'count of "$raw"');
      final result = c['maxLength'] is int ? SpeechLines.sanitize(raw, maxLength: c['maxLength']! as int) : SpeechLines.sanitize(raw);
      expect(result, c['result'], reason: 'sanitize "$raw"');
      if (result != null) expect(characterCount(result), c['resultCount'], reason: 'count of "$result"');
    }
  });

  test('the occasion for each kind of Claude event', () {
    for (final e in objs(fixture['events'])) {
      final wire = obj(e['wire']);
      final at = DateTime.fromMicrosecondsSinceEpoch(((wire['ts']! as num) * 1e6).round(), isUtc: true);
      final event = EventNormalizer.normalize(wire, receivedAt: at)!;
      expect(event.kind.name, e['kind'], reason: '${wire['id']}');
      expect(SpeechOccasion.forEvent(event)?.name, e['occasion'], reason: '${wire['id']} ${wire['event']}');
    }
  });

  test('bubble durations follow the length of the line', () {
    expect(SpeechLines.duration('Hi'), 3.2);
    expect(SpeechLines.duration('Good morning! ☀️'), closeTo(2 + 15 * 0.11, 1e-12));
    expect(SpeechLines.duration('x' * 80), 6);
  });

  test('a fresh-line prompt only says what kind of moment it is', () {
    final pet = FreshLinePrompt(SpeechOccasion.petted, petName: 'Mochi', companionName: 'Patch', home: 'the Windows taskbar');
    expect(pet.speaker, SpeechSpeaker.pet);
    expect(pet.instructions, startsWith('You are Mochi, a playful, affectionate little cat who lives in the Windows taskbar.'));
    expect(pet.instructions, endsWith('No quotes, no hashtags, no names.'));
    expect(pet.prompt, 'The user is petting the cat. What do you say?');
    final companion = FreshLinePrompt(SpeechOccasion.promptSubmitted, petName: 'Mochi', companionName: 'Patch');
    expect(companion.speaker, SpeechSpeaker.companion);
    expect(companion.instructions, startsWith('You are Patch, a cheerful little pixel-art creature'));
    expect(SpeechLines.freshOccasions, hasLength(13));
  });

  group('the speech director (the Mac\'s SpeechController)', () {
    late DateTime date;
    late double uptime;

    MochiWorld makeWorld({WorldSettings settings = const WorldSettings(companionVisibility: CompanionVisibility.always)}) {
      date = DateTime.utc(2027, 1, 15, 9);
      uptime = 50;
      return MochiWorld(settings: settings, seed: 11, clock: () => date, uptime: () => uptime, calendar: const WorldCalendar.utc());
    }

    void pass(double seconds) {
      date = date.add(Duration(microseconds: (seconds * 1e6).round()));
      uptime += seconds;
    }

    CompanionEvent hook(String name, {String session = 's1', Map<String, Object?> extra = const {}}) => EventNormalizer.normalize({
      'v': 1,
      'id': '$name-$session-${date.microsecondsSinceEpoch}',
      'ts': date.microsecondsSinceEpoch / 1e6,
      'origin': 'hook',
      'event': name,
      'session': session,
      ...extra,
    }, receivedAt: date)!;

    test('Claude\'s events speak, at the chattiness\'s pace, and background sessions only for what matters', () {
      final world = makeWorld();
      final speech = SpeechDirector(world, seed: 1);
      world.effects = _SpeechEffects(speech);
      world.ingest(hook('SessionStart'));
      final first = world.activeSpeech;
      expect(first, isNotNull);
      expect(SpeechLines.lines(SpeechOccasion.sessionStarted).map((l) => l.text), contains(first!.text));
      expect(first.duration, SpeechLines.duration(first.text));
      pass(5);
      world.ingest(hook('PostToolUseFailure', extra: {'tool': 'Bash', 'toolCategory': 'shell', 'toolUseId': 't1'}));
      expect(world.speech?.id, first.id, reason: 'a medium line waits 30 s after the last one');
      pass(4);
      world.ingest(hook('Stop'));
      expect(world.speech?.id, isNot(first.id), reason: 'a finished turn gets through after 8 s');
      pass(60);
      world.ingest(hook('SessionStart', session: 's2'));
      world.ingest(hook('UserPromptSubmit', session: 's1'));
      final before = world.speech?.id;
      speech.react(
        hook('PostToolUseFailure', session: 's2', extra: {'tool': 'Bash', 'toolCategory': 'shell', 'toolUseId': 't2'}),
        world.registry['s2'],
      );
      expect(world.speech?.id, before, reason: 'a background session\'s tool error stays quiet');
      expect(speech.recent, isNotEmpty);
    });

    test('quiet speaks only for what matters; speech off and paused say nothing', () {
      final quiet = makeWorld(
        settings: const WorldSettings(companionVisibility: CompanionVisibility.always, chattiness: Chattiness.quiet),
      );
      final director = SpeechDirector(quiet, seed: 3);
      expect(director.say(SpeechOccasion.sessionStarted), isNull);
      expect(director.say(SpeechOccasion.turnCompleted), isNotNull);
      final off = makeWorld(settings: const WorldSettings(speechEnabled: false));
      expect(SpeechDirector(off).say(SpeechOccasion.turnCompleted), isNull);
      final paused = makeWorld(settings: const WorldSettings(pauseReactions: true));
      expect(SpeechDirector(paused).say(SpeechOccasion.turnCompleted), isNull);
    });

    test('Patch\'s lines need Patch, Mochi\'s need Mochi at home', () {
      final world = makeWorld(settings: const WorldSettings(companionVisibility: CompanionVisibility.never));
      final director = SpeechDirector(world, seed: 5);
      expect(director.say(SpeechOccasion.promptSubmitted), isNull, reason: 'only Patch speaks for a new task');
      world.setAdventureActive(true);
      expect(director.say(SpeechOccasion.petted), isNull);
    });

    test('petting gets a word about two times in three', () {
      final world = makeWorld();
      final director = SpeechDirector(world, seed: 8);
      var spoke = 0;
      for (var i = 0; i < 200; i++) {
        final before = world.speech?.id;
        director.interacted(PetInteraction.values[i % 3]);
        if (world.speech?.id != before) spoke += 1;
        pass(31);
      }
      expect(spoke, inInclusiveRange(110, 150));
    });

    test('a greeting once per part of the day while the window is open; mumbles in its sleep', () {
      final world = makeWorld(
        settings: const WorldSettings(companionVisibility: CompanionVisibility.always, chattiness: Chattiness.chatty),
      );
      final director = SpeechDirector(world, seed: 2);
      pass(6);
      director.tick();
      expect(world.speech, isNull, reason: 'greetings wait for the window');
      director.windowVisible = true;
      pass(6);
      director.tick();
      expect(SpeechLines.lines(SpeechOccasion.morning).map((l) => l.text), contains(world.speech?.text));
      pass(6);
      director.tick();
      expect(world.speech, isNull, reason: 'the greeting had its time, and nobody is greeted twice');
      world.petAsleep = true;
      final said = <String>[];
      for (var i = 0; i < 12 * 60; i++) {
        pass(5);
        director.tick();
        final text = world.speech?.text;
        if (text != null && (said.isEmpty || said.last != text)) said.add(text);
      }
      final sleepy = SpeechLines.lines(SpeechOccasion.sleepy).map((l) => l.text).toSet();
      expect(said.where(sleepy.contains).length, inInclusiveRange(10, 30), reason: 'chatty mumbles every 3 minutes or so for an hour');
    });

    test('fresh lines from a writer are used now and then, and refilled every two hours', () async {
      final world = makeWorld();
      var asked = 0;
      final director = SpeechDirector(
        world,
        seed: 4,
        writer: (occasions, {required petName, required companionName}) async {
          asked += 1;
          expect(occasions, SpeechLines.freshOccasions);
          return {
            SpeechOccasion.petted: [for (var i = 0; i < 5; i++) SpeechLine(SpeechSpeaker.pet, 'Fresh purr $i')],
          };
        },
      );
      await director.refillFreshLines();
      expect(asked, 1);
      expect(director.freshLines[SpeechOccasion.petted]?.map((l) => l.text), ['Fresh purr 2', 'Fresh purr 3', 'Fresh purr 4']);
      expect(director.refillFreshLines(), isNull, reason: 'not again within two hours');
      final said = <String>[];
      for (var i = 0; i < 20; i++) {
        said.add(director.say(SpeechOccasion.petted)!.text);
        pass(31);
      }
      expect(said.where((t) => t.startsWith('Fresh')).length, 3);
      pass(2 * 3600);
      await director.refillFreshLines();
      expect(asked, 2);
      world.settings = world.settings.copyWith(speechFreshLines: false);
      pass(2 * 3600);
      expect(director.refillFreshLines(), isNull);
    });

    test('the same seed says the same things', () {
      List<String> run() {
        final world = makeWorld();
        final director = SpeechDirector(world, seed: 77);
        return [
          for (var i = 0; i < 30; i++)
            ?(() {
              pass(40);
              return director.say(SpeechOccasion.values[i % SpeechOccasion.values.length])?.text;
            })(),
        ];
      }

      expect(run(), run());
    });
  });
}

class _SpeechEffects extends WorldEffects {
  _SpeechEffects(this.speech);
  final SpeechDirector speech;

  @override
  void worldDidReact(CompanionEvent event, SessionSnapshot? session) => speech.react(event, session);

  @override
  void userDidInteract(PetInteraction kind) => speech.interacted(kind);
}
