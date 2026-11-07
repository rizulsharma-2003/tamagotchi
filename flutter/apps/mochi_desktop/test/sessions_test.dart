import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/core/session_store.dart';
import 'package:mochi_desktop/src/core/sessions.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'support/fakes.dart';

void main() {
  final start = DateTime(2026, 11, 5, 10);
  DateTime at(int seconds) => start.add(Duration(seconds: seconds));

  group('SessionRegistry', () {
    test('follows a turn: prompt, tools, permission, finish, end', () {
      final registry = SessionRegistry();
      var t = registry.apply(hook('SessionStart', at: at(0)))!;
      expect(t.isNew, isTrue);
      expect(t.phase, SessionPhase.idle);
      expect(t.session.startObserved, isTrue);
      expect(t.session.project, 'web');

      t = registry.apply(hook('UserPromptSubmit', at: at(1)))!;
      expect(t.phase, SessionPhase.promptSubmitted);
      expect(t.session.turnStartedAt, at(1));

      t = registry.apply(hook('PreToolUse', tool: 'Bash', toolUseId: 'b1', at: at(2)))!;
      expect(t.phase, SessionPhase.runningTool);
      expect(t.session.currentTool?.name, 'Bash');
      expect(t.session.statusLine(at(2)), 'Running Bash');
      expect(t.session.phoneSessionPhase, 'working');

      t = registry.apply(hook('PreToolUse', tool: 'Read', toolUseId: 'r1', at: at(3)))!;
      expect(t.session.statusLine(at(3)), 'Running 2 tools');
      t = registry.apply(hook('PostToolUse', tool: 'Read', toolUseId: 'r1', at: at(4)))!;
      expect(t.session.currentTool?.name, 'Bash');
      t = registry.apply(hook('PostToolUse', tool: 'Bash', toolUseId: 'b1', at: at(5)))!;
      expect(t.phase, SessionPhase.thinking);

      t = registry.apply(hook('Notification', notificationType: 'permission_prompt', at: at(6)))!;
      expect(t.phase, SessionPhase.waitingForUser);
      expect(t.session.waitingFor, Attention.permission);
      expect(t.session.phoneSessionPhase, 'waiting');
      expect(t.session.statusLine(at(6)), 'Waiting for your permission');

      t = registry.apply(hook('PreToolUse', tool: 'Edit', toolUseId: 'e1', at: at(7)))!;
      expect(t.phase, SessionPhase.runningTool, reason: 'a tool starting means the wait is over');
      expect(t.session.waitingFor, isNull);

      t = registry.apply(hook('Stop', at: at(10)))!;
      expect(t.phase, SessionPhase.turnCompleted);
      expect(t.turnDuration, const Duration(seconds: 9));
      expect(t.session.runningTools, isEmpty);
      expect(t.session.turnsCompleted, 1);
      expect(t.session.phoneSessionPhase, 'done');

      t = registry.apply(hook('SessionEnd', at: at(20)))!;
      expect(t.phase, SessionPhase.ended);
      expect(registry.live, isEmpty);
    });

    test('idle prompts and errors', () {
      final registry = SessionRegistry();
      registry.apply(hook('UserPromptSubmit', at: at(0)));
      expect(registry.apply(hook('Notification', notificationType: 'idle_prompt', at: at(1)))!.session.waitingFor, Attention.input);
      expect(registry.apply(hook('Notification', notificationType: 'auth_success', at: at(2)))!.kind, EventKind.notification);
      final failed = registry.apply(hook('StopFailure', at: at(3))..reason = 'rate_limit')!;
      expect(failed.phase, SessionPhase.turnFailed);
      expect(failed.session.statusLine(at(3)), 'Turn ended with an API error (rate limit)');
      expect(failed.session.phoneSessionPhase, 'error');
    });

    test('sessions stay apart, and a late event never moves a session back', () {
      final registry = SessionRegistry();
      registry.apply(hook('UserPromptSubmit', session: 'a', project: 'web', at: at(10)));
      registry.apply(hook('Stop', session: 'b', project: 'api', at: at(11)));
      expect(registry['a']!.phase, SessionPhase.promptSubmitted);
      expect(registry['b']!.phase, SessionPhase.turnCompleted);
      registry.apply(
        hook('Stop', session: 'a', at: at(2)),
        delivery: Delivery.late,
      );
      expect(registry['a']!.phase, SessionPhase.promptSubmitted);
      expect(registry['a']!.lateEvents, 1);
      expect(registry.apply(WireEvent(id: 'p', ts: 1, origin: WireOrigin.ping, event: 'Ping')), isNull);
    });

    test('builds and tests are noted; reports attach to the project', () {
      final registry = SessionRegistry();
      registry.apply(hook('PreToolUse', tool: 'Bash', toolUseId: 'x', at: at(0)));
      registry.apply(
        hook('PostToolUseFailure', tool: 'Bash', toolUseId: 'x', at: at(1))
          ..commandKind = 'test'
          ..commandReliable = true,
      );
      expect(registry['s1']!.lastBuildTest, 'Tests failed');
      final report = WireEvent(id: 'r', ts: at(2).millisecondsSinceEpoch / 1000, origin: WireOrigin.report, event: 'Report')
        ..projectKey = ProjectIdentity.key('/code/web')
        ..report = const WireReport(kind: 'build', status: 'passed', label: 'release');
      registry.apply(report);
      expect(registry['s1']!.lastBuildTest, 'Build passed (release)');
    });

    test('the primary session: needs you › failed › working › just finished', () {
      final registry = SessionRegistry();
      final now = at(100);
      registry.apply(hook('Stop', session: 'done', at: at(90)));
      registry.apply(hook('UserPromptSubmit', session: 'work', at: at(80)));
      expect(registry.primary(now)!.id, 'work');
      registry.apply(hook('Notification', session: 'wait', notificationType: 'permission_prompt', at: at(10)));
      expect(registry.primary(now)!.id, 'wait');
      // Working but silent for 20 minutes: stale, so it ranks as idle.
      expect(registry['work']!.isStale(at(80 + 21 * 60)), isTrue);
    });

    test('the mirror the phones get: phase and kind of tool only', () {
      final registry = SessionRegistry();
      expect(registry.mirror().phase, 'none');
      registry.apply(hook('PreToolUse', tool: 'Grep', toolUseId: 'g', at: at(0)));
      final mirror = registry.mirror(now: at(1));
      expect(mirror.phase, 'working');
      expect(mirror.category, 'search');
      expect(mirror.toJson().keys, containsAll(['phase', 'category', 'resting', 'at']));
      registry.apply(hook('Notification', notificationType: 'permission_prompt', at: at(2)));
      expect(registry.mirror().phase, 'waiting');
    });

    test('prune drops ended sessions after 30 minutes and quiet ones after 6 hours', () {
      final registry = SessionRegistry();
      registry.apply(hook('SessionEnd', session: 'ended', at: at(0)));
      registry.apply(hook('Stop', session: 'quiet', at: at(0)));
      registry.prune(at(31 * 60));
      expect(registry['ended'], isNull);
      expect(registry['quiet'], isNotNull);
      registry.prune(at(7 * 3600));
      expect(registry.all, isEmpty);
    });
  });

  group('SessionStore', () {
    test('counts late events, and says how the sessions are doing', () {
      var now = at(0);
      final store = SessionStore(clock: () => now);
      var changes = 0;
      store.addListener(() => changes++);
      final transitions = <SessionTransition>[];
      store.transitions.listen(transitions.add);
      store.apply(hook('UserPromptSubmit', session: 'a', project: 'web', at: at(0)));
      store.apply(hook('Notification', session: 'b', project: 'api', notificationType: 'permission_prompt', at: at(1)));
      store.apply(
        hook('Stop', session: 'c', project: 'old', at: at(-60)),
        delivery: Delivery.late,
      );
      now = at(5 * 60);
      expect(store.statusSummary(), 'api is waiting for you · web is working (5 min) · old is idle.');
      expect(store.lateEvents, 1);
      expect(changes, 3);
      expect(transitions.last.delivery, Delivery.late);
      expect(SessionStore(clock: () => now).statusSummary(), 'No Claude sessions right now.');
    });
  });

  group("Mochi's mood", () {
    test('follows the primary session, and naps after a quiet half hour', () {
      var now = at(0);
      final store = SessionStore(clock: () => now);
      PetMood mood() => PetMood.of(store, now: now, lastActivity: at(0));
      expect(mood(), PetMood.relaxed);
      store.apply(hook('UserPromptSubmit', at: at(0)));
      expect(mood(), PetMood.watching);
      store.apply(hook('Notification', notificationType: 'permission_prompt', at: at(1)));
      expect(mood(), PetMood.needsYou);
      store.apply(hook('Stop', at: at(2)));
      expect(mood(), PetMood.happy);
      now = at(10 * 60);
      expect(mood(), PetMood.relaxed);
      now = at(40 * 60);
      expect(mood(), PetMood.napping);
      expect(PetMood.needsYou.loop, PetAnimation.waveGently);
      expect(PetMood.napping.description, 'Mochi is napping');
    });

    test("Mochi's poses come from its world: its loop for the mood, its moments over it, the nap the world's", () {
      var seconds = 1000.0;
      final t = TestDesktop.make(uptime: () => seconds);
      addTearDown(t.dispose);
      final director = PetDirector(t.desktop.world)..follow(PetMood.watching);
      final loop = director.pose(seconds, quantum: 1 / 15);
      expect(loop.repeats, isTrue, reason: 'a loop: its picture can be kept');
      expect(director.playing, isFalse);
      t.desktop.cue(PetCue.pet);
      expect(director.playing, isTrue);
      expect(t.desktop.world.world.pet.current.animation, PetAnimation.petted);
      seconds += 0.5;
      expect(director.pose(seconds).repeats, isFalse, reason: 'a moment is drawn from the art');
      seconds += 10;
      t.desktop.world.tick();
      expect(director.playing, isFalse, reason: 'moments end');
      expect(PetMood.of(t.desktop.sessions, now: t.desktop.sessions.now, lastActivity: at(0), asleep: true), PetMood.napping);
      expect(PetMood.of(t.desktop.sessions, now: t.desktop.sessions.now, lastActivity: at(0), asleep: false), PetMood.relaxed);
    });
  });
}
