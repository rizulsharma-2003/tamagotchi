// W15: the focus timer and log against the Swift engine (link-spec/world/focus.json), plus the Mac app's focus buddy
// (what Mochi and Patch say and do, the break choreography, naps in the world), which has no Swift fixture.

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

final _start = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000, isUtc: true);

DateTime _at(num seconds) => _start.add(Duration(microseconds: (seconds * 1e6).round()));

double _since(DateTime date) => date.difference(_start).inMicroseconds / 1e6;

List<Object?> _transition(FocusTransition t) => switch (t) {
  FocusStarted(:final phase, :final cycle) => ['started', phase.name, cycle],
  FocusCompleted(:final block) => ['completed', block.endedAt.microsecondsSinceEpoch / 1e6, block.minutes],
  FocusFinished(:final blocks) => ['finished', blocks],
  FocusStopped() => ['stopped'],
  FocusExpired() => ['expired'],
};

void main() {
  final fixture = readWorldFixture('focus.json');

  test('durations from settings, within bounds', () {
    for (final row in (fixture['settings']! as List).cast<List<Object?>>()) {
      final d = FocusDurations.fromSettings(
        FocusSettings(
          workMinutes: row[0]! as int,
          breakMinutes: row[1]! as int,
          longBreakMinutes: row[2]! as int,
          cyclesBeforeLongBreak: row[3]! as int,
        ),
      );
      expect([d.focus, d.shortBreak, d.longBreak, d.cyclesBeforeLongBreak], row.sublist(4), reason: '$row');
    }
    final raw = FocusDurations(focus: 0, shortBreak: -5, longBreak: 0.5, cyclesBeforeLongBreak: 0);
    expect([raw.focus, raw.shortBreak, raw.longBreak, raw.cyclesBeforeLongBreak], fixture['raw']);
  });

  test('the clock text', () {
    for (final row in (fixture['clocks']! as List).cast<List<Object?>>()) {
      expect(focusClock((row[0]! as num).toDouble()), row[1], reason: '${row[0]}');
    }
  });

  for (final scenario in cases(fixture, 'timers')) {
    test('timer: ${scenario['note']}', () {
      final d = (scenario['durations']! as List).cast<num>();
      final timer = FocusTimer(
        FocusDurations(
          focus: d[0].toDouble(),
          shortBreak: d[1].toDouble(),
          longBreak: d[2].toDouble(),
          cyclesBeforeLongBreak: d[3].toInt(),
        ),
      );
      for (final step in objs(scenario['steps'])) {
        final at = _at(step['at']! as num);
        final transitions = switch (step['op']) {
          'start' => timer.start(at),
          'stop' => timer.stop(at),
          'skip' => timer.skip(at),
          _ => timer.advance(at),
        };
        final where = '${step['op']} at ${step['at']}';
        expect(diffJson(transitions.map(_transition).toList(), step['transitions']), isEmpty, reason: where);
        final running = timer.running;
        if (running == null) {
          expect(step['running'], isNull, reason: where);
        } else {
          expect(
            diffJson([running.phase.name, _since(running.startedAt), running.duration, running.cycle], step['running']),
            isEmpty,
            reason: where,
          );
          final status = timer.status(naps: true)!;
          expect(status.petNaps, step['petNaps'], reason: where);
          expect(diffJson([status.remaining(at), status.progress(at)], [step['remaining'], step['progress']]), isEmpty, reason: where);
        }
        expect(timer.completedBlocks, step['completedBlocks'], reason: where);
      }
    });
  }

  test('the focus log keeps a week of completed blocks', () {
    final log = FocusLog();
    for (final row in (fixture['log']! as List).cast<List<Object?>>()) {
      log.append(
        FocusBlock(endedAt: _at(row[0]! as num), minutes: (row[1]! as num).toDouble()),
        now: _at(row[2]! as num),
      );
      expect(
        [
          for (final b in log.blocks) [_since(b.endedAt), b.minutes],
        ],
        row[3],
        reason: '$row',
      );
    }
    final day = 86400;
    expect(log.blocksIn(_at(5 * day), _at(12 * day)).map((b) => _since(b.endedAt)), fixture['within']);
    final memory = FocusLog(retentionDays: 0)
      ..append(FocusBlock(endedAt: _at(-30 * day), minutes: 25), now: _start)
      ..append(FocusBlock(endedAt: _start, minutes: 25), now: _start);
    expect(memory.blocks.map((b) => _since(b.endedAt)), fixture['memory']);
    expect(memory.persists, isFalse);

    final saved = FocusLog()..load(log.toJson(), now: _at(12 * day));
    expect(saved.toJson(), log.toJson());
    final mac = FocusLog()
      ..load([
        {'endedAt': 1800000000, 'minutes': 25},
        {'endedAt': 1800000100, 'minutes': 0},
        'junk',
      ], now: _start);
    expect(mac.blocks, [FocusBlock(endedAt: _start, minutes: 25)]);
  });

  test('settings JSON uses the Mac\'s keys, and missing keys keep their defaults', () {
    const settings = FocusSettings(workMinutes: 50, bannerAtBreak: true);
    expect(FocusSettings.fromJson(settings.toJson()), settings);
    expect(FocusSettings.fromJson({'breakMinutes': 10}), const FocusSettings(breakMinutes: 10));
  });

  group('the focus buddy (the Mac\'s FocusController)', () {
    late DateTime date;
    late double uptime;
    late MochiWorld world;
    late List<SoundCue> sounds;
    late List<BannerContent> banners;

    setUp(() {
      date = DateTime.utc(2027, 1, 15, 10);
      uptime = 100;
      sounds = [];
      banners = [];
      world = MochiWorld(
        settings: const WorldSettings(soundEnabled: true),
        seed: 9,
        clock: () => date,
        uptime: () => uptime,
        calendar: const WorldCalendar.utc(),
        effects: _Effects(sounds, banners),
      );
    });

    void advance(double seconds, FocusBuddy buddy) {
      // Tick at 4 Hz, like the hosts do.
      final steps = (seconds * 4).round();
      for (var i = 0; i < steps; i++) {
        date = date.add(const Duration(milliseconds: 250));
        uptime += 0.25;
        world.tick();
        buddy.tick();
      }
    }

    test('a whole set: naps, stretch breaks, the log and the finale', () {
      final buddy = FocusBuddy(world, settings: const FocusSettings(bannerAtBreak: true), computer: 'PC');
      buddy.begin(durations: FocusDurations(focus: 60, shortBreak: 20, longBreak: 30, cyclesBeforeLongBreak: 2));
      expect(world.focus?.petNaps, isTrue);
      expect(world.activeSpeech?.text, "Focus time. I'll nap right here.");
      expect(world.activeToast?.title, 'Focus · 1 minute');
      expect(world.activeToast?.detail, 'Mochi wakes you for a stretch break.');
      expect(buddy.menuTitle, 'Stop Focus (Focus 1:00 left)');

      advance(60, buddy);
      expect(world.focus?.phase, FocusPhase.shortBreak);
      expect(world.focus?.petNaps, isFalse);
      expect(world.activeToast?.title, 'Stretch break!');
      expect(world.activeToast?.detail, 'Focus block 1 done · 20 seconds break.');
      expect(world.activeSpeech?.text, 'Stretch break! Stand up and wiggle with me.');
      expect(sounds, contains(SoundCue.success));
      expect(banners.single.title, 'Stretch break!');
      expect(buddy.log.blocks.single.minutes, 1);
      advance(2, buddy);
      expect(world.pet.current.animation, PetAnimation.stretch, reason: 'wake, then a stretch 1.3 s later');

      advance(18, buddy);
      expect(world.activeToast?.detail, 'Block 2 of 2.');
      expect(sounds.last, SoundCue.greeting);
      advance(60, buddy);
      expect(world.focus?.phase, FocusPhase.longBreak);
      expect(world.activeToast?.title, 'Long break!');
      expect(world.activeToast?.detail, '2 focus blocks done · 1 minute to recharge.', reason: 'half a minute rounds up, as on the Mac');
      advance(30, buddy);
      expect(buddy.isRunning, isFalse);
      expect(world.focus, isNull);
      expect(world.activeToast?.title, 'Focus set complete!');
      expect(world.activeToast?.detail, '2 focus blocks · 2 minutes. Well done!');
      expect(world.activeSpeech?.text, 'We did it! Time for a proper rest.');
      expect(sounds.last, SoundCue.celebration);
      expect(buddy.menuTitle, 'Start Focus');
    });

    test('stopping wakes a napping Mochi; a slept-through block expires quietly', () {
      final buddy = FocusBuddy(world, settings: const FocusSettings(chimeAtBreak: false), computer: 'PC');
      buddy.begin();
      buddy.stop();
      expect(buddy.lastMoment?.line?.text, 'Okay! Back to playing.');
      expect(buddy.lastMoment?.pet, PetAnimation.wakeUp);
      expect(world.focus, isNull);

      buddy.begin();
      date = date.add(const Duration(minutes: 40));
      uptime += 2400;
      buddy.tick();
      expect(buddy.isRunning, isFalse);
      expect(world.activeToast?.title, 'Focus session ended');
      expect(world.activeToast?.detail, "Your PC was asleep when the block ended, so it wasn't counted.");
      expect(buddy.log.blocks, isEmpty);
      expect(sounds, isEmpty, reason: 'no chime asked for');
    });

    test('without naps Mochi keeps you company, and banners stay off by default', () {
      final buddy = FocusBuddy(world, settings: const FocusSettings(napsDuringFocus: false));
      buddy.begin(durations: FocusDurations(focus: 10, shortBreak: 10, longBreak: 10, cyclesBeforeLongBreak: 4));
      expect(world.focus?.petNaps, isFalse);
      expect(world.activeSpeech?.text, "Focus time. I'll keep you company.");
      advance(10, buddy);
      expect(banners, isEmpty);
      advance(10, buddy);
      expect(world.activeSpeech?.text, "Back to it! You've got this.");
      buddy.skip();
      expect(world.focus?.phase, FocusPhase.shortBreak);
      expect(buddy.log.blocks, hasLength(1), reason: 'a skipped block is not logged');
    });
  });
}

class _Effects extends WorldEffects {
  _Effects(this.sounds, this.banners);
  final List<SoundCue> sounds;
  final List<BannerContent> banners;

  @override
  void play(SoundCue sound) => sounds.add(sound);

  @override
  void postBanner(BannerContent content, NotificationCategory category, String? sessionID) => banners.add(content);
}
