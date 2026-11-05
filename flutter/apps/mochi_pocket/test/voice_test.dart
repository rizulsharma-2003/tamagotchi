import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/model/app_settings.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/voice/agent_speech.dart';
import 'package:mochi_pocket/src/voice/mochi_voice.dart';
import 'package:mochi_pocket/src/voice/updates_reader.dart';

import 'support/fakes.dart';

/// Unix seconds for today at [hour]:[minute] on this computer's clock.
double at(int hour, [int minute = 0]) => DateTime(2026, 11, 5, hour, minute).millisecondsSinceEpoch / 1000;

AgentNote meeting(String title, double? due) =>
    AgentNote(id: 'cal:$title', source: AgentSource.calendar, title: title, detail: 'Google Meet', important: true, at: 0, due: due);

AgentNote mail(String title, {String? subject, String detail = 'Hello.', bool important = false}) => AgentNote(
  id: 'mail:$title:$subject:$detail',
  source: AgentSource.gmail,
  title: title,
  detail: detail,
  important: important,
  at: 0,
  subject: subject,
);

AgentNote task(String title) =>
    AgentNote(id: 'notion:$title', source: AgentSource.notion, title: title, detail: '', important: false, at: 0);

void main() {
  group('the script (TamagotchiCore AgentSpeech.script, word for word)', () {
    test('nothing waiting', () {
      expect(AgentSpeech.script(const []), 'Nothing is waiting for you right now. Enjoy!');
    });

    test('one of each kind, meetings in time order, mail that needs you by subject, the rest by gist', () {
      final items = [
        meeting('Design review', at(16)),
        mail('Priya Sharma', subject: 'Invoice for October.', important: true),
        mail('GitHub', detail: '1 new commit pushed to main.'),
        meeting('Standup', at(10, 30)),
        mail('Aditi Rao', detail: 'Shared the flow · notes before Friday…', important: true),
        task('Finish the launch checklist'),
      ];
      expect(
        AgentSpeech.script(items),
        '6 things are waiting for you. Standup, at 10:30 AM. Design review, at 4:00 PM. '
        'Priya Sharma needs you: Invoice for October. Aditi Rao needs you: Shared the flow, notes before Friday. '
        'From GitHub: 1 new commit pushed to main. Due in Notion: Finish the launch checklist. '
        "That's everything.",
      );
    });

    test('one thing; a meeting without a time', () {
      expect(AgentSpeech.script([meeting('Lunch', null)]), "One thing is waiting for you. Lunch. That's everything.");
    });

    test('more than fit: "And n more …", and three or more quiet emails summed up by sender', () {
      final items = [
        for (var i = 1; i <= 4; i++) meeting('Meeting $i', at(9 + i)),
        for (var i = 1; i <= 5; i++) mail('Sender $i', subject: 'Subject $i', important: true),
        mail('Zed', detail: 'a'),
        mail('Ann', detail: 'b'),
        mail('Ann', detail: 'c'),
        for (var i = 1; i <= 4; i++) task('Task $i'),
      ];
      final script = AgentSpeech.script(items, time: (time) => '${time.hour}');
      expect(script, startsWith('16 things are waiting for you. Meeting 1, at 10. Meeting 2, at 11. Meeting 3, at 12. '));
      expect(script, contains('And 1 more meetings.'));
      expect(script, contains('Sender 4 needs you: Subject 4. And 1 more emails that need you.'));
      expect(script, contains('And 3 more emails, nothing urgent, from Ann and Zed and others.'));
      expect(script, endsWith("Due in Notion: Task 3. And 1 more tasks. That's everything."));
    });

    test('spoken() drops what a voice would read out', () {
      expect(AgentSpeech.spoken('Done… '), 'Done');
      expect(AgentSpeech.spoken('Meet · Room 4.'), 'Meet, Room 4');
      expect(AgentSpeech.spoken('Really?!'), 'Really');
    });

    test('sentences split at the end of a sentence, not inside "v2.1" or "4:00 PM"', () {
      expect(AgentSpeech.sentences('Ship v2.1 today. Standup, at 4:00 PM. Done!'), ['Ship v2.1 today.', 'Standup, at 4:00 PM.', 'Done!']);
    });
  });

  group("Mochi's voice", () {
    test("the iPhone's characters: cents become Android's pitch multiplier; pace stays", () {
      expect(VoiceCharacter.values.first, VoiceCharacter.mochi, reason: "Mochi's own voice first");
      expect(VoiceCharacter.mochi.pitch, closeTo(1.2240, 0.0001));
      expect(VoiceCharacter.tiny.pitch, closeTo(1.4983, 0.0001));
      expect(VoiceCharacter.calm.pitch, closeTo(0.9170, 0.0001));
      expect(VoiceCharacter.plain.pitch, 1);
      expect([for (final c in VoiceCharacter.values) c.pace], [1.04, 1.08, 0.92, 1]);
    });

    test("flutter_tts's voice maps: quality, needs the internet, not downloaded", () {
      final voice = VoiceInfo.fromMap({
        'name': 'en-us-x-sfg-network',
        'locale': 'en-US',
        'quality': 'very high',
        'latency': 'normal',
        'network_required': '1',
        'features': 'networkTimeoutMs\tnetworkRetriesCount',
      })!;
      expect(voice.quality, 500);
      expect(voice.network, isTrue);
      expect(voice.installed, isTrue);
      expect(voice.label, 'English (US) · SFG · Very high quality · needs the internet');
      expect(VoiceInfo.fromMap({'name': 'x', 'locale': 'en-AU', 'features': 'notInstalled'})!.installed, isFalse);
      expect(VoiceInfo.fromMap('nope'), isNull);
    });

    test('best first: on this phone, then quality, then your own accent, then US English; never not-downloaded or not English', () {
      final names = [for (final voice in VoiceChoice.choices(FakeSpeechEngine().installed, language: 'en-IN')) voice.name];
      expect(names, ['en-in-x-ena-local', 'en-us-x-tpf-local', 'en-gb-x-gbb-local', 'en-us-x-sfg-network']);
      final voices = FakeSpeechEngine().installed;
      expect(VoiceChoice.pick(voices, language: 'en-US')?.name, 'en-us-x-tpf-local');
      expect(VoiceChoice.pick(voices, chosen: 'en-gb-x-gbb-local', language: 'en-US')?.name, 'en-gb-x-gbb-local');
      expect(VoiceChoice.pick(voices, chosen: 'gone', language: 'en-US')?.name, 'en-us-x-tpf-local');
    });
  });

  group('the reader', () {
    late FakeSpeechEngine engine;
    late FakeBridge focus;
    late AppSettings settings;
    late List<String> announced;
    late UpdatesReader reader;
    final items = [mail('Priya Sharma', subject: 'Invoice', important: true), task('Checklist')];

    setUp(() {
      engine = FakeSpeechEngine();
      focus = FakeBridge();
      settings = AppSettings(MemoryDocument());
      announced = [];
      reader = UpdatesReader(engine: engine, focus: focus, settings: settings, language: () => 'en-IN', announce: announced.add);
    });

    tearDown(() => reader.dispose());

    test('reads the script a sentence at a time in the best voice with Mochi’s pitch and pace, holding audio focus', () async {
      await reader.toggle(items);
      expect(engine.spoken.map((s) => s.text), [
        '2 things are waiting for you.',
        'Priya Sharma needs you: Invoice.',
        'Due in Notion: Checklist.',
        "That's everything.",
      ]);
      expect(engine.spoken.first.voice?.name, 'en-in-x-ena-local');
      expect(engine.spoken.first.pitch, VoiceCharacter.mochi.pitch);
      expect(engine.spoken.first.pace, 1.04);
      expect(focus.requests, 1);
      expect(focus.abandons, 1);
      expect(reader.speaking, isFalse);
    });

    test('a second tap stops it mid-sentence; nothing more is said', () async {
      engine.hold = true;
      final reading = reader.toggle(items);
      await pumpEventQueue();
      expect(reader.speaking, isTrue);
      expect(engine.spoken, hasLength(1));
      await reader.toggle(items);
      await reading;
      expect(reader.speaking, isFalse);
      expect(engine.stops, 1);
      expect(engine.spoken, hasLength(1));
      expect(focus.abandons, greaterThanOrEqualTo(1));
    });

    test('a call or another app taking the audio stops Mochi', () async {
      engine.hold = true;
      final reading = reader.toggle(items);
      await pumpEventQueue();
      focus.focusLost.add(null);
      await reading;
      expect(reader.speaking, isFalse);
      expect(engine.stops, 1);
    });

    test("when the phone won't give the audio (a call is on), Mochi stays quiet", () async {
      focus.grant = false;
      await reader.toggle(items);
      expect(engine.spoken, isEmpty);
      expect(reader.speaking, isFalse);
    });

    test('with TalkBack on, TalkBack reads the script instead; nothing talks over it', () async {
      await reader.toggle(items, talkBack: true);
      expect(announced.single, startsWith('2 things are waiting for you.'));
      expect(engine.spoken, isEmpty);
      expect(focus.requests, 0);
    });

    test('the voice and character chosen in Settings are used; a sample can try another character', () async {
      settings
        ..voiceName = 'en-gb-x-gbb-local'
        ..character = VoiceCharacter.calm;
      await reader.say('Hello there.');
      expect(engine.spoken.single.voice?.name, 'en-gb-x-gbb-local');
      expect(engine.spoken.single.pitch, VoiceCharacter.calm.pitch);
      await reader.say('Squeak.', character: VoiceCharacter.tiny);
      expect(engine.spoken.last.pitch, VoiceCharacter.tiny.pitch);
    });

    test('disposing stops a reading in progress', () async {
      engine.hold = true;
      final other = UpdatesReader(engine: engine, focus: focus, settings: settings, language: () => 'en-IN');
      final reading = other.toggle(items);
      await pumpEventQueue();
      other.dispose();
      await reading;
      expect(engine.stops, 1);
    });
  });

  group('appearance', () {
    test('System by default; the choice survives a restart', () async {
      final document = MemoryDocument();
      final first = AppSettings(document);
      await first.load();
      expect(first.appearance, Appearance.system);
      first.appearance = Appearance.dark;
      first.character = VoiceCharacter.tiny;
      first.voiceName = 'en-gb-x-gbb-local';
      await pumpEventQueue();
      final again = AppSettings(document);
      await again.load();
      expect(again.appearance, Appearance.dark);
      expect(again.character, VoiceCharacter.tiny);
      expect(again.voiceName, 'en-gb-x-gbb-local');
    });
  });
}
