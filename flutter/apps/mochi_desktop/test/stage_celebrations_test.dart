// Full-screen celebrations on the native stage (docs/SPRINT_2.md X10): confetti for G2's big wins (graduation, a
// milestone, green tests or build), fireworks for streak milestones, on the display you're on; short, cheap (pictures
// drawn once, one call a frame, no timer between celebrations) and skipped whenever Mischief may not run (a full-screen
// app, quiet hours, animation effects off, nobody looking), stopping at once if that starts halfway.

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/json_store.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show QuietHours;
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/streaks.dart';
import 'package:mochi_desktop/src/ui/stage/celebrations.dart';
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fake_stage.dart';
import 'support/fakes.dart';

w.CompanionEvent companionEvent(DateTime at, {w.EventDelivery delivery = w.EventDelivery.live}) => w.CompanionEvent(
  id: 'e-${at.microsecondsSinceEpoch}',
  kind: w.EventKind.turnCompleted,
  rawName: 'Stop',
  timestamp: at,
  receivedAt: at,
  sessionID: 's1',
  origin: w.EventOrigin.claudeHook,
  delivery: delivery,
);

void main() {
  group('Streaks', () {
    test('days in a row from live events, once a day; a gap starts again; milestones reached once; kept', () {
      var now = DateTime(2026, 11, 1, 9);
      final store = MemoryJsonStore();
      var recap = 1;
      final watch = StreakWatch(store: store, recapStreak: () => recap, clock: () => now);
      final reached = <int>[];
      watch.reached.listen(reached.add);
      watch.observe(companionEvent(now, delivery: w.EventDelivery.late));
      expect(watch.count, 0, reason: 'late events are history');
      watch.observe(companionEvent(now));
      expect(watch.count, 1);
      watch.observe(companionEvent(now.add(const Duration(hours: 2))));
      expect(watch.count, 1, reason: 'once a day');
      for (var day = 1; day <= 6; day++) {
        now = DateTime(2026, 11, 1 + day, 9);
        watch.observe(companionEvent(now));
      }
      expect(watch.count, 7);
      expect(reached, [3, 5, 7]);
      // A day off: it starts again.
      now = DateTime(2026, 11, 9, 9);
      watch.observe(companionEvent(now));
      expect(watch.count, 1);
      // Kept: a new watch carries on from the file (not the recap).
      recap = 99;
      final again = StreakWatch(store: store, recapStreak: () => recap, clock: () => now);
      now = DateTime(2026, 11, 10, 9);
      again.observe(companionEvent(now));
      expect(again.count, 2);
      watch.dispose();
      again.dispose();
    });

    test('the first time, it starts from the recap’s week', () {
      final now = DateTime(2026, 11, 8, 9);
      final watch = StreakWatch(store: MemoryJsonStore(), recapStreak: () => 5, clock: () => now);
      final reached = <int>[];
      watch.reached.listen(reached.add);
      watch.observe(companionEvent(now));
      expect(watch.count, 5);
      expect(reached, [5]);
      watch.dispose();
    });
  });

  group('On the stage', () {
    late TestDesktop t;
    late FakeNativeStage stage;
    late MischiefStage mischief;
    late FakeDisplays displays;
    var fullScreen = false;
    (int, int)? pointer = (900, 500);
    var now = DateTime(2026, 11, 8, 15);

    setUp(() {
      fullScreen = false;
      pointer = (900, 500);
      now = DateTime(2026, 11, 8, 15);
      t = TestDesktop.make(
        clock: () => now,
        fullScreen: () => fullScreen,
        activity: const SystemActivity(idleSeconds: 1),
      );
      t.desktop.rhythm.sample();
      stage = FakeNativeStage();
      displays = FakeDisplays([FakeDisplays.main1080, FakeDisplays.side1440]);
      mischief = MischiefStage(desktop: t.desktop, stage: stage, displays: displays, cursor: () => pointer, clock: testSeconds);
    });

    /// Starts watching inside the test (its listeners and timers belong to the test's fake time).
    void begin() {
      t.desktop.mischief.start();
      mischief.start();
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
    }

    tearDown(() async {
      mischief.dispose();
      await t.dispose();
    });

    /// Lets the pictures be drawn (that takes real time), then plays [seconds] of frames.
    Future<void> play(WidgetTester tester, double seconds) async {
      for (var i = 0; i < 200 && mischief.celebrations.running && !mischief.celebrations.started; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      for (var i = 0; i < (seconds * 30).ceil(); i++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
    }

    Future<void> done(WidgetTester tester) async {
      mischief.celebrations.stop();
      t.desktop.mischief.stop();
      await tester.pump();
    }

    testWidgets('graduation: big confetti across the display you’re on, click-through, pictures drawn once, one call a frame', (
      tester,
    ) async {
      begin();
      t.desktop.markMilestone();
      expect(mischief.celebrations.playing, CelebrationKind.bigConfetti);
      await play(tester, 1.5);
      final pictures = StageCelebrations.shapes * celebrationColors.length * StageCelebrations.tumbleSteps;
      expect(stage.definedSprites, pictures, reason: 'every piece’s picture once, before the first frame');
      expect(stage.callsTo('sprites'), 1, reason: 'handed over together');
      final shows = stage.callsTo('show');
      expect(shows, greaterThan(30));
      expect(shows, lessThanOrEqualTo(mischief.celebrations.frames), reason: 'at most one call a frame');
      expect(stage.showing, isNotEmpty);
      for (final shot in stage.showing.values) {
        expect(shot.clickThrough, isTrue);
        expect(shot.topmost, isTrue);
        expect(shot.left, inInclusiveRange(-80, 1920 + 80), reason: 'on the main display, where the pointer is');
        expect(shot.top, inInclusiveRange(-80, 1080 + 80));
      }
      expect(mischief.perfState(), 'celebration (bigConfetti)');
      await play(tester, 3.5);
      expect(mischief.celebrations.running, isFalse);
      expect(mischief.celebrations.ticking, isFalse, reason: 'no timer after it');
      expect(stage.windows, isEmpty, reason: 'every piece is taken down');
      expect(stage.definedSprites, pictures, reason: 'nothing was drawn again');
      await done(tester);
    });

    testWidgets('green tests and milestones get confetti; a finished turn doesn’t (it high-fives on the taskbar)', (tester) async {
      begin();
      t.desktop.receive(hook('SessionStart', at: now));
      t.desktop.receive(hook('UserPromptSubmit', at: now));
      t.desktop.receive(hook('Stop', at: now));
      expect(mischief.celebrations.running, isFalse);
      t.desktop.markMilestone();
      expect(mischief.celebrations.playing, CelebrationKind.bigConfetti);
      await done(tester);
    });

    testWidgets('on the display the pointer is on, at its scale', (tester) async {
      begin();
      pointer = (3000, 700);
      expect(mischief.preview(CelebrationKind.confetti), isTrue);
      await play(tester, 1.2);
      expect(stage.showing, isNotEmpty);
      for (final shot in stage.showing.values) {
        expect(shot.left, greaterThanOrEqualTo(1920 - 80), reason: 'on the side display');
      }
      // Its pieces are drawn at 1.5: 24 logical pixels across, 36 and a bit physical.
      final sprite = stage.sprites.values.first;
      expect(sprite.width, greaterThanOrEqualTo(36));
      await done(tester);
    });

    testWidgets('fireworks for a streak milestone: the third day in a row', (tester) async {
      begin();
      for (final day in [6, 7, 8]) {
        now = DateTime(2026, 11, day, 9);
        t.desktop.receive(hook('SessionStart', session: 's$day', at: now));
        if (day < 8) expect(mischief.celebrations.running, isFalse, reason: 'day ${day - 5}');
      }
      expect(t.desktop.streaks.count, 3);
      expect(mischief.celebrations.playing, CelebrationKind.fireworks);
      await play(tester, 1.6);
      expect(stage.showing, isNotEmpty);
      expect(stage.sprites.length, celebrationColors.length * 3);
      await play(tester, 2);
      expect(mischief.celebrations.running, isFalse);
      expect(stage.windows, isEmpty);
      await done(tester);
    });

    testWidgets('skipped while a full-screen app has the screen, in quiet hours, with animation effects off, and unseen', (tester) async {
      begin();
      fullScreen = true;
      t.desktop.mischief.check();
      expect(mischief.celebrations.celebrate(CelebrationKind.confetti), isFalse);
      expect(mischief.preview(CelebrationKind.confetti), isFalse, reason: 'not even a preview over a full-screen app');
      fullScreen = false;
      t.desktop.mischief.check();
      t.desktop.settings.quietHours = const QuietHours(enabled: true, startMinute: 14 * 60, endMinute: 16 * 60);
      expect(mischief.celebrations.celebrate(CelebrationKind.confetti), isFalse);
      t.desktop.settings.quietHours = const QuietHours();
      t.desktop.motion.value = true;
      expect(mischief.celebrations.celebrate(CelebrationKind.confetti), isFalse);
      t.desktop.motion.value = false;
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
      expect(mischief.celebrations.celebrate(CelebrationKind.confetti), isFalse);
      expect(stage.calls, isEmpty, reason: 'nothing was sent at all');
      expect(mischief.celebrations.ticking, isFalse);
      await done(tester);
    });

    testWidgets('the extra’s own switch off: no confetti (the rest of Mischief carries on)', (tester) async {
      begin();
      t.desktop.settings.mischief = t.desktop.settings.mischief.withExtra(MischiefExtra.celebrations, false);
      t.desktop.markMilestone();
      expect(mischief.celebrations.running, isFalse);
      await done(tester);
    });

    testWidgets('stops at once when the screen goes off or a full-screen app starts halfway', (tester) async {
      begin();
      expect(mischief.preview(CelebrationKind.fireworks), isTrue);
      await play(tester, 1);
      expect(stage.showing, isNotEmpty);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
      expect(mischief.celebrations.running, isFalse);
      expect(mischief.celebrations.ticking, isFalse);
      expect(stage.windows, isEmpty);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 1));
      expect(mischief.preview(CelebrationKind.confetti), isTrue);
      await play(tester, 0.5);
      fullScreen = true;
      t.desktop.mischief.check();
      expect(mischief.celebrations.running, isFalse);
      expect(stage.windows, isEmpty);
      await done(tester);
    });

    testWidgets('one at a time; a preview in quiet hours still plays (you asked for it)', (tester) async {
      begin();
      t.desktop.settings.quietMode = true;
      expect(mischief.preview(CelebrationKind.confetti), isTrue);
      expect(mischief.preview(CelebrationKind.fireworks), isFalse, reason: 'one at a time');
      await done(tester);
    });

    test('the development switch', () {
      expect(MischiefStage.demoFrom('confetti:20, fireworks:45,nonsense,bigConfetti:1'), {
        CelebrationKind.confetti: const Duration(seconds: 20),
        CelebrationKind.fireworks: const Duration(seconds: 45),
      });
      expect(MischiefStage.demoFrom(null), isEmpty);
    });
  });
}
