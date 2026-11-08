// Reacts to what you do (docs/SPRINT_2.md X7): Mochi bops to music, goes quiet while the microphone is in use and perks up
// when an editor or terminal comes to the front. The three readers are fakes here: the director (core/reacts.dart) against
// the Mischief gate, the stroll's choices (ui/pet/stroller.dart) and the Settings row.

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_art/mochi_art.dart' show PetAnimation;
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show SoundCue;
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/reacts.dart';
import 'package:mochi_desktop/src/core/sounds.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

class _Media implements MediaReader {
  bool value = false;
  int reads = 0;

  @override
  Future<bool> playing() async {
    reads++;
    return value;
  }
}

class _Mic implements MicReader {
  bool value = false;
  int reads = 0;

  @override
  bool inUse() {
    reads++;
    return value;
  }
}

class _Apps implements ForegroundApps {
  String? value;
  int reads = 0;

  @override
  String? processName() {
    reads++;
    return value;
  }
}

const _zones = [StrollLine(100, 700), StrollLine(900, 1500)];

void main() {
  _pacing();
  group('The pieces', () {
    test('editors and terminals match on the process name, without regard to case; nothing else does', () {
      for (final name in EditorApps.names) {
        expect(EditorApps.matches(name), isTrue, reason: name);
        expect(EditorApps.matches(name.toUpperCase()), isTrue, reason: name.toUpperCase());
        expect(EditorApps.matches(name.toLowerCase()), isTrue, reason: name.toLowerCase());
      }
      expect(EditorApps.names, hasLength(13));
      expect(EditorApps.matches(r'C:\Users\me\AppData\Local\Programs\Microsoft VS Code\Code.exe'), isTrue, reason: 'only the last part counts');
      expect(EditorApps.matches('Code - Insiders.exe'), isTrue);
      for (final other in ['chrome.exe', 'Spotify.exe', 'notepad.exe', 'Code', 'Code.exe.bak', 'xCode.exe', '', 'cmd']) {
        expect(EditorApps.matches(other), isFalse, reason: other);
      }
      expect(EditorApps.matches(null), isFalse);
    });

    test('the registry: an app with a start time and a stop time of 0 is using the microphone now', () {
      const active = MicStamp(133_000_000_000_000_000, 0);
      expect(active.active, isTrue);
      expect(const MicStamp(133_000_000_000_000_000, 133_000_000_100_000_000).active, isFalse, reason: 'it stopped');
      expect(const MicStamp(0, 0).active, isFalse, reason: 'never used');
      expect(const MicStamp(null, null).active, isFalse, reason: 'values missing');
      expect(const MicStamp(133_000_000_000_000_000, null).active, isFalse, reason: 'no stop value: not known to be open');
      expect(const MicStamp(null, 0).active, isFalse);
      expect(MicConsent.inUse(const []), isFalse);
      expect(MicConsent.inUse(const [MicStamp(5, 9), MicStamp(0, 0)]), isFalse);
      expect(MicConsent.inUse(const [MicStamp(5, 9), active, MicStamp(0, 0)]), isTrue, reason: 'any one app is enough');
      expect(MicConsent.key, r'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone');
      expect(MicConsent.nonPackaged, 'NonPackaged');
    });

    test('the development switch names the three states and nothing else', () {
      expect(ReactsForce.from('music'), ReactsForce.music);
      expect(ReactsForce.from(' Call '), ReactsForce.call);
      expect(ReactsForce.from('EDITOR'), ReactsForce.editor);
      expect(ReactsForce.from('games'), isNull);
      expect(ReactsForce.from(''), isNull);
      expect(ReactsForce.from(null), isNull);
    });

    test('the extra is built, on once Mischief is, and says it hides for full-screen games', () {
      expect(MischiefExtra.available, contains(MischiefExtra.reacts));
      expect(MischiefExtra.reacts.title, 'Reacts to what you do');
      expect(MischiefExtra.reacts.detail, contains('full-screen games'));
      expect(MischiefExtra.reacts.detail, contains('never what or who'));
      final settings = DesktopSettings(MemorySettingsDocument());
      expect(settings.mischief.on(MischiefExtra.reacts), isTrue);
      expect(settings.mischief.allows(MischiefExtra.reacts), isFalse, reason: 'the master switch is off at first');
      settings.mischief = const MischiefSettings(enabled: true);
      expect(settings.mischief.allows(MischiefExtra.reacts), isTrue);
      expect(settings.mischief.toJson()['reacts'], isTrue);
    });
  });

  group('The director', () {
    late DesktopSettings settings;
    late PcRhythm rhythm;
    late SystemMotion motion;
    late MischiefGate gate;
    late _Media media;
    late _Mic mic;
    late _Apps apps;
    late ReactsDirector reacts;
    var fullScreen = false;
    var now = DateTime(2026, 11, 8, 15);
    final log = <String>[];

    void build({ReactsForce? force}) {
      reacts = ReactsDirector(gate: gate, media: media, mic: mic, apps: apps, force: force, clock: () => now, log: log.add)..start();
    }

    setUp(() {
      fullScreen = false;
      now = DateTime(2026, 11, 8, 15);
      log.clear();
      settings = DesktopSettings(MemorySettingsDocument());
      settings.mischief = const MischiefSettings(enabled: true);
      rhythm = PcRhythm(settings: settings)..report(const SystemActivity(idleSeconds: 2));
      motion = SystemMotion(read: () => false);
      gate = MischiefGate(
        settings: settings,
        rhythm: rhythm,
        motion: motion,
        supported: true,
        fullScreen: () => fullScreen,
        clock: () => now,
        checkEvery: const Duration(seconds: 2),
      )..start();
      media = _Media();
      mic = _Mic();
      apps = _Apps();
    });

    tearDown(() {
      reacts.dispose();
      gate.dispose();
      rhythm.dispose();
      motion.dispose();
    });

    test('music is seen while media plays and not after; the log has only a state word', () async {
      build();
      await reacts.poll();
      expect((reacts.music, reacts.calling, reacts.label), (false, false, null));
      media.value = true;
      await reacts.poll();
      expect((reacts.music, reacts.label), (true, 'music'));
      media.value = false;
      await reacts.poll();
      expect(reacts.music, isFalse);
      expect(log, ['reacts: music', 'reacts: none']);
    });

    test('a call: the microphone in use is quiet at once, and normal about 10 seconds after it is free', () async {
      build();
      mic.value = true;
      await reacts.poll();
      expect((reacts.calling, reacts.label), (true, 'call'));
      mic.value = false;
      now = now.add(const Duration(seconds: 5));
      await reacts.poll();
      expect(reacts.calling, isTrue, reason: '5 s after: still quiet');
      now = now.add(const Duration(seconds: 4));
      await reacts.poll();
      expect(reacts.calling, isTrue, reason: '9 s after');
      now = now.add(const Duration(seconds: 1, milliseconds: 1));
      await reacts.poll();
      expect(reacts.calling, isFalse, reason: '10 s after: back to normal');
      // A blip of the microphone (the next call) starts it again.
      mic.value = true;
      await reacts.poll();
      expect(reacts.calling, isTrue);
      expect(ReactsDirector.calmAfter, const Duration(seconds: 10));
    });

    test('the editor look: only on a change to an editor or terminal, once per 10 minutes', () async {
      build();
      final looks = <int>[];
      final sub = reacts.perks.listen((_) => looks.add(1));
      apps.value = 'chrome.exe';
      await reacts.poll();
      expect(looks, isEmpty, reason: 'the first read is only a baseline');
      apps.value = 'Code.exe';
      await reacts.poll();
      expect(looks, hasLength(1), reason: 'a change to an editor');
      await reacts.poll();
      expect(looks, hasLength(1), reason: 'no change');
      apps.value = 'chrome.exe';
      await reacts.poll();
      now = now.add(const Duration(minutes: 9, seconds: 59));
      apps.value = 'WINDOWSTERMINAL.EXE';
      await reacts.poll();
      expect(looks, hasLength(1), reason: 'under 10 minutes since the last look');
      apps.value = 'chrome.exe';
      await reacts.poll();
      now = now.add(const Duration(seconds: 2));
      apps.value = 'cmd.exe';
      await reacts.poll();
      expect(looks, hasLength(2), reason: 'past 10 minutes');
      apps.value = null;
      await reacts.poll();
      apps.value = 'notepad.exe';
      await reacts.poll();
      expect(looks, hasLength(2), reason: 'not an editor');
      expect(log.where((line) => line.contains('chrome') || line.contains('Code')), isEmpty, reason: 'never a name in the log');
      await sub.cancel();
    });

    test('no look for an editor while a call has the microphone', () async {
      build();
      final looks = <int>[];
      final sub = reacts.perks.listen((_) => looks.add(1));
      apps.value = 'chrome.exe';
      await reacts.poll();
      mic.value = true;
      apps.value = 'Code.exe';
      await reacts.poll();
      expect(looks, isEmpty);
      await sub.cancel();
    });

    test('nothing is read while the gate is closed, and it is read again when it opens', () async {
      settings.mischief = const MischiefSettings();
      gate.check();
      build();
      expect(reacts.reading, isFalse, reason: 'no timer while Mischief is off');
      await reacts.poll();
      expect((media.reads, mic.reads, apps.reads, reacts.polls), (0, 0, 0, 0));
      settings.mischief = const MischiefSettings(enabled: true);
      await Future<void>.delayed(Duration.zero);
      expect(reacts.reading, isTrue);
      expect((media.reads, mic.reads, apps.reads), (1, 1, 1), reason: 'one read when it opens');
      settings.mischief = const MischiefSettings(enabled: true).withExtra(MischiefExtra.reacts, false);
      expect(reacts.reading, isFalse, reason: 'its own switch off');
      await reacts.poll();
      expect(media.reads, 1);
    });

    test('a closed gate (full screen, quiet hours, paused, an unseen screen) stops the reads and puts Mochi back to normal', () async {
      media.value = true;
      mic.value = true;
      build();
      await Future<void>.delayed(Duration.zero);
      expect((reacts.music, reacts.calling), (true, true));
      var reads = media.reads;

      fullScreen = true;
      gate.check();
      expect((reacts.music, reacts.calling, reacts.reading), (false, false, false), reason: 'full screen');
      await reacts.poll();
      expect(media.reads, reads);
      fullScreen = false;
      gate.check();
      expect(reacts.reading, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(reacts.music, isTrue, reason: 'back when the screen is free');
      reads = media.reads;

      settings.pauseReactions = true;
      expect((reacts.music, reacts.reading), (false, false), reason: 'paused reactions');
      settings.pauseReactions = false;
      await Future<void>.delayed(Duration.zero);
      reads = media.reads;

      settings.quietMode = true;
      expect((reacts.music, reacts.reading), (false, false), reason: 'quiet mode');
      settings.quietMode = false;
      await Future<void>.delayed(Duration.zero);
      expect(reacts.reading, isTrue);
      reads = media.reads;

      rhythm.report(const SystemActivity(idleSeconds: 2, displaysAsleep: true));
      expect(gate.why(MischiefExtra.reacts), MischiefPause.unseen);
      expect((reacts.music, reacts.reading), (false, false), reason: 'an unseen screen');
      await reacts.poll();
      expect(media.reads, reads, reason: 'nothing read while nobody can see it');
    });

    test('the development switch forces a state, and still waits for the gate', () async {
      build(force: ReactsForce.music);
      await reacts.poll();
      expect(reacts.music, isTrue);
      expect(media.reads, 0, reason: 'forced: not read');
      reacts.dispose();
      mic.reads = 0;
      build(force: ReactsForce.call);
      await reacts.poll();
      expect((reacts.calling, reacts.music), (true, false));
      expect(mic.reads, 0);
      reacts.dispose();
      build(force: ReactsForce.editor);
      final looks = <int>[];
      final sub = reacts.perks.listen((_) => looks.add(1));
      await reacts.poll();
      expect(looks, hasLength(1), reason: 'the first read is a look');
      await reacts.poll();
      expect(looks, hasLength(1), reason: 'still once per 10 minutes');
      await sub.cancel();
      reacts.dispose();
      settings.quietMode = true;
      build(force: ReactsForce.music);
      await reacts.poll();
      expect(reacts.music, isFalse, reason: 'forced, but quiet hours still close the gate');
    });
  });

  group('The stroll', () {
    Stroller make(int seed, {bool music = false, bool calm = false, bool late = false, StrollMode mode = StrollMode.free}) {
      final stroller = Stroller(random: Random(seed))..place(_zones, now: 0, x: 400, mode: mode);
      stroller.reactsWhen(music: () => music, calm: () => calm);
      stroller.lateNight = late;
      return stroller;
    }

    Map<StrollActivity, int> draw(Stroller stroller, {int count = 6000}) {
      final counts = <StrollActivity, int>{};
      for (var i = 0; i < count; i++) {
        counts.update(stroller.chooseFreeActivity(), (n) => n + 1, ifAbsent: () => 1);
      }
      return counts;
    }

    test('a bop is chosen only while music plays, free and awake, and not late at night; zoomies stay possible', () {
      expect(draw(make(1)).containsKey(StrollActivity.bop), isFalse, reason: 'no music');
      final playing = draw(make(1, music: true));
      expect(playing[StrollActivity.bop], greaterThan(0));
      expect(playing[StrollActivity.zoomies], greaterThan(0), reason: 'zoomies stay possible');
      expect(playing[StrollActivity.wander], greaterThan(0));
      // Weight 1.5 against the rest (the total is about 11.9 in these stretches, before the repeat rules): about an eighth.
      final share = playing[StrollActivity.bop]! / playing.values.fold<int>(0, (a, b) => a + b);
      expect(share, closeTo(1.5 / 12.1, 0.04));
      expect(draw(make(1, music: true, late: true)).containsKey(StrollActivity.bop), isFalse, reason: 'late at night stays calm');
      for (final mode in [StrollMode.working, StrollMode.asleep, StrollMode.attending, StrollMode.paused, StrollMode.still]) {
        final stroller = make(1, music: true, mode: mode);
        stroller.update(0, mode: mode);
        expect(draw(stroller, count: 500).containsKey(StrollActivity.bop), isFalse, reason: mode.name);
      }
    });

    test('the bop is a rhythm of bounces and nods in place', () {
      var seen = 0;
      for (var seed = 0; seed < 60 && seen < 3; seed++) {
        final stroller = make(seed, music: true);
        for (var t = 0.0; t < 900 && seen < 3; t += 0.25) {
          stroller.update(t, mode: StrollMode.free);
          final bop = stroller.segments.where((segment) => segment.activity == StrollActivity.bop).toList();
          if (bop.length < 5) continue;
          seen++;
          expect(bop.every((segment) => segment.fromX == segment.toX), isTrue, reason: 'in place');
          expect(bop.map((segment) => segment.animation).toSet(), {PetAnimation.happyBounce, PetAnimation.nod});
          expect(bop.first.animation, PetAnimation.happyBounce);
          break;
        }
      }
      expect(seen, greaterThan(0));
    });

    test('on a call: no zoomies, toys, landmark visits or walks, only rests, fidgets and naps', () {
      final stroller = make(2, calm: true, music: true);
      stroller.setLandmarks(const [
        StrollLandmark(StrollVisit.clock, x: 300),
        StrollLandmark(StrollVisit.start, x: 150),
      ], 0);
      final counts = draw(stroller);
      expect(counts.keys.toSet(), {StrollActivity.settle, StrollActivity.fidget, StrollActivity.nap});
      expect(counts.containsKey(StrollActivity.bop), isFalse, reason: 'the call wins over the music');
      // And over a long life: nothing but those, never a toy's props.
      for (var seed = 0; seed < 6; seed++) {
        final lived = make(seed, calm: true);
        for (var t = 0.0; t < 1500; t += 0.25) {
          lived.update(t, mode: StrollMode.free);
          final sample = lived.sample(t);
          expect(sample.props, isEmpty);
          expect(const {StrollActivity.zoomies, StrollActivity.butterfly, StrollActivity.ball, StrollActivity.yarn, StrollActivity.leaf}.contains(sample.activity), isFalse);
        }
      }
    });

    test('the call ends: the choice is back to normal', () {
      var calling = true;
      final stroller = Stroller(random: Random(4))..place(_zones, now: 0, x: 400);
      stroller.reactsWhen(music: () => false, calm: () => calling);
      expect(draw(stroller, count: 1000).containsKey(StrollActivity.zoomies), isFalse);
      calling = false;
      expect(draw(stroller, count: 1000)[StrollActivity.zoomies], greaterThan(0));
    });
  });

  group('Mochi’s sounds', () {
    test('are muted while a call has the microphone, even a forced one', () {
      final output = FakeSound();
      var quiet = false;
      final sounds = MochiSounds(output: output, volume: () => 0.5)..muted = () => quiet;
      expect(sounds.play(SoundCue.values.first), isTrue);
      quiet = true;
      expect(sounds.play(SoundCue.values.last, force: true), isFalse);
      expect(output.played, hasLength(1));
      quiet = false;
      expect(sounds.play(SoundCue.values.last, force: true), isTrue);
    });
  });

  group('The taskbar stroll', () {
    late TestDesktop t;
    late FakeShell shell;
    late FakeTaskbar taskbar;
    late _Media media;
    late _Mic mic;
    late _Apps apps;
    late ReactsDirector reacts;
    final strolls = <TaskbarStroll>[];

    setUp(() {
      t = TestDesktop.make();
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      shell = FakeShell(petWindow: FakePetWindow());
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
      media = _Media();
      mic = _Mic();
      apps = _Apps();
    });

    tearDown(() => t.dispose());

    Future<TaskbarStroll> start(WidgetTester tester) async {
      final stroll = TaskbarStroll(
        shell: shell,
        taskbar: taskbar,
        settings: t.desktop.settings,
        motion: t.desktop.motion,
        cues: t.desktop.cues,
        reacts: reacts = ReactsDirector(
          gate: t.desktop.mischief,
          media: media,
          mic: mic,
          apps: apps,
          clock: () => tester.binding.clock.now(),
        ),
        clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        random: Random(7),
      );
      strolls.add(stroll);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      return stroll;
    }

    void finish() {
      reacts.dispose();
      for (final stroll in strolls) {
        stroll.dispose();
      }
      strolls.clear();
    }

    testWidgets('an editor coming to the front gives one attentive look, and the stroll asks the director for the music and the call', (tester) async {
      try {
        final stroll = await start(tester);
        expect(stroll.stroller.isPlaced, isTrue);
        // Wired: a call is calm, music is a bop.
        mic.value = true;
        media.value = true;
        reacts.start();
        await tester.pump();
        await reacts.poll();
        expect(stroll.stroller.calm, isTrue);
        mic.value = false;
        apps.value = 'chrome.exe';
        await reacts.poll();
        // The look is only for a Mochi that's free; first the call's quiet has to be over.
        await tester.pump(const Duration(seconds: 11));
        expect(reacts.calling, isFalse);
        apps.value = 'Code.exe';
        await reacts.poll();
        expect(stroll.sample()!.style, StrollStyle.attentive, reason: 'one attentive look, toward you');
        expect(stroll.sample()!.activity, StrollActivity.react);
      } finally {
        finish();
      }
    });
  });

  group('Settings', () {
    testWidgets('the row says what it sees and that it hides for full-screen games', (tester) async {
      final t = TestDesktop.make();
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      expect(t.desktop.reacts.reading, isFalse, reason: 'nothing runs until the desktop starts');
      expect(MischiefExtra.reacts.detail, contains('full-screen games'));
      expect(t.desktop.mischief.why(MischiefExtra.reacts), isNull);
      t.dispose();
    });
  });
}

void _pacing() {
  group('Pacing', () {
    testWidgets('the three are read every 5 seconds, no oftener, and only while allowed', (tester) async {
      final settings = DesktopSettings(MemorySettingsDocument())..mischief = const MischiefSettings(enabled: true);
      final rhythm = PcRhythm(settings: settings)..report(const SystemActivity(idleSeconds: 2));
      final motion = SystemMotion(read: () => false);
      final gate = MischiefGate(settings: settings, rhythm: rhythm, motion: motion, supported: true)..start();
      final media = _Media();
      final reacts = ReactsDirector(gate: gate, media: media, clock: () => tester.binding.clock.now())..start();
      try {
        expect(ReactsDirector(gate: gate).every, const Duration(seconds: 5));
        await tester.pump();
        expect(media.reads, 1, reason: 'one as it starts');
        await tester.pump(const Duration(seconds: 4));
        expect(media.reads, 1);
        await tester.pump(const Duration(seconds: 1));
        expect(media.reads, 2, reason: 'at 5 s');
        await tester.pump(const Duration(seconds: 15));
        expect(media.reads, 5, reason: 'at 10, 15 and 20 s');
        settings.quietMode = true;
        await tester.pump(const Duration(seconds: 30));
        expect(media.reads, 5, reason: 'quiet hours: nothing');
        expect(reacts.reading, isFalse);
        settings.quietMode = false;
        await tester.pump();
        expect(media.reads, 6, reason: 'one when it is allowed again');
        expect(reacts.polls, 6);
      } finally {
        reacts.dispose();
        gate.dispose();
        rhythm.dispose();
        motion.dispose();
      }
    });
  });
}
