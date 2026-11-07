// Your PC's rhythm (docs/SPRINT_2.md W2) and "Only notify me when I'm away" (W3), as on the Mac: when the PC counts as
// resting, Mochi's nap as a state machine (asleep while the PC rests and Claude is idle, awake with a stretch when
// you're back), Mochi's mood and the phones' room following it, the summaries kept off the phones while you're here,
// and Settings › Characters › Naps.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/turn_summaries.dart';
import 'package:mochi_desktop/src/link/phone_sync.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_link/mochi_link.dart';

import 'support/fakes.dart';

final DateTime noon = DateTime(2026, 11, 7, 12);

const SystemActivity working = SystemActivity(idleSeconds: 2);
const SystemActivity away = SystemActivity(idleSeconds: 400);

void main() {
  group('When the PC rests (the Mac’s SystemActivity)', () {
    const five = Duration(minutes: 5);

    test('no input for the rest time, nothing holding the screen on, a calm processor', () {
      expect(working.isResting(five), isFalse);
      expect(working.userActive, isTrue);
      expect(const SystemActivity(idleSeconds: 299).isResting(five), isFalse);
      expect(const SystemActivity(idleSeconds: 300).isResting(five), isTrue);
      expect(const SystemActivity(idleSeconds: 45).userActive, isFalse, reason: 'not here, not resting yet either');
    });

    test('a video, a call or a busy processor keeps it awake; the display off or a lock rests it at once', () {
      expect(const SystemActivity(idleSeconds: 900, keepsDisplayAwake: true).isResting(five), isFalse);
      expect(const SystemActivity(idleSeconds: 900, cpuLoad: 0.7).isResting(five), isFalse);
      expect(const SystemActivity(idleSeconds: 900, cpuLoad: 0.5).isResting(five), isTrue);
      const locked = SystemActivity(idleSeconds: 3, displaysAsleep: true);
      expect((locked.isResting(five), locked.userActive, locked.away), (true, false, true));
    });

    test('away: after 3 minutes without input, or locked', () {
      expect(const SystemActivity(idleSeconds: 179).away, isFalse);
      expect(const SystemActivity(idleSeconds: 180).away, isTrue);
    });
  });

  group('Mochi’s nap (the Mac’s updateNap)', () {
    late NapState nap;
    late DateTime now;
    late DateTime lastActivity;
    setUp(() {
      nap = NapState();
      now = noon;
      lastActivity = noon.subtract(const Duration(minutes: 10));
    });

    bool step(SystemActivity? system, {bool follow = true, bool paused = false}) => nap.update(
      now: now,
      lastActivity: lastActivity,
      system: system,
      followSystem: follow,
      restAfter: const Duration(minutes: 5),
      paused: paused,
    );

    test('asleep while the PC rests, awake with you back; between the two it stays as it was', () {
      expect(step(working), isFalse);
      expect(step(const SystemActivity(idleSeconds: 120)), isFalse, reason: 'not resting yet');
      expect(step(const SystemActivity(idleSeconds: 300)), isTrue, reason: 'resting');
      expect(step(const SystemActivity(idleSeconds: 120)), isTrue, reason: 'still no one at the keyboard');
      expect(step(const SystemActivity(idleSeconds: 1)), isFalse, reason: 'you’re back: a stretch');
    });

    test('something happening (a hook event, a pet) wakes it, and it waits a minute before napping again', () {
      expect(step(away), isTrue);
      lastActivity = now.subtract(const Duration(seconds: 20));
      expect(step(away), isFalse);
      now = now.add(const Duration(seconds: 30));
      expect(step(away), isFalse, reason: 'under a minute since');
      now = now.add(const Duration(seconds: 15));
      expect(step(away), isTrue);
    });

    test('the display off naps at once (after a quiet minute); a call keeping the screen on doesn’t', () {
      expect(step(const SystemActivity(idleSeconds: 2, displaysAsleep: true)), isTrue);
      final call = NapState();
      expect(
        call.update(now: now, lastActivity: lastActivity, system: const SystemActivity(idleSeconds: 1200, keepsDisplayAwake: true), followSystem: true, restAfter: const Duration(minutes: 5)),
        isFalse,
      );
    });

    test('with the switch off, or without the PC’s state, the old rule: 30 quiet minutes', () {
      expect(step(away, follow: false), isFalse);
      lastActivity = now.subtract(const Duration(minutes: 31));
      expect(step(working, follow: false), isTrue);
      expect(step(null), isTrue);
      lastActivity = now;
      expect(step(null), isFalse);
    });

    test('paused reactions leave the nap as it is', () {
      expect(step(away), isTrue);
      expect(step(working, paused: true), isTrue);
    });
  });

  group('The rhythm in the app', () {
    late TestDesktop t;
    late DateTime now;
    setUp(() {
      now = noon;
      t = TestDesktop.make(clock: () => now, activity: working);
    });
    tearDown(() => t.dispose());

    test('it samples the PC, and tells only when resting, being here or being away changes', () {
      final rhythm = t.desktop.rhythm;
      var heard = 0;
      rhythm.addListener(() => heard++);
      rhythm.sample();
      expect((rhythm.available, rhythm.resting, rhythm.away), (true, false, false));
      expect(heard, 1);
      rhythm.report(const SystemActivity(idleSeconds: 5));
      expect(heard, 1, reason: 'nothing that matters changed');
      rhythm.report(away);
      expect((rhythm.resting, rhythm.away, heard), (true, true, 2));
      t.desktop.settings.restAfterMinutes = 10;
      expect(rhythm.resting, isFalse, reason: 'Settings › Characters › Naps: 10 minutes');
    });

    test('Mochi’s mood: napping while the PC rests and Claude is idle, never while Claude works', () {
      final rhythm = t.desktop.rhythm..report(away);
      final quietSince = now.subtract(const Duration(minutes: 2));
      expect(PetMood.of(t.desktop.sessions, now: now, lastActivity: quietSince, rhythm: rhythm), PetMood.napping);
      t.desktop.sessions.apply(hook('UserPromptSubmit', at: now));
      expect(PetMood.of(t.desktop.sessions, now: now, lastActivity: quietSince, rhythm: rhythm), PetMood.watching);
      rhythm.report(working);
      t.desktop.sessions.apply(hook('Stop', at: now));
      now = now.add(const Duration(minutes: 3));
      expect(PetMood.of(t.desktop.sessions, now: now, lastActivity: quietSince, rhythm: rhythm), PetMood.relaxed, reason: 'you’re working');
    });

    test('the phones’ room sleeps too while the PC rests', () async {
      final t2 = TestDesktop.make(saved: hostCredentials, clock: () => now, activity: away);
      addTearDown(t2.dispose);
      await t2.desktop.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      t2.desktop.rhythm.sample();
      t2.desktop.phone.tick(force: true);
      final mirror = ClaudeMirror.fromValue(t2.socket.values(LinkKey.claude).last)!;
      expect(mirror.resting, isTrue);
    });

    testWidgets('Settings › Characters › Naps: the switch, the minutes, and what the PC is doing now', (tester) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      t.desktop.rhythm.report(working);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.characters,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('Sleep while my PC rests, awake while I work'));
      expect(find.text('In use'), findsOneWidget);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 10, displaysAsleep: true));
      await tester.pump();
      expect(find.text('Locked or display off'), findsOneWidget);
      final row = find.ancestor(of: find.text('Sleep while my PC rests, awake while I work'), matching: find.byType(ToggleRow));
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pump();
      expect(t.desktop.settings.followSystem, isFalse);
      expect(t.document.json!['followSystem'], false);
    });
  });

  group('“Only notify me when I’m away from this PC” (the Mac’s notifyOnlyWhenAway)', () {
    late TestDesktop t;
    late DateTime now;
    bool? here;

    setUp(() async {
      now = noon;
      here = true;
      t = TestDesktop.make(saved: hostCredentials, clock: () => now);
      t.desktop.settings
        ..shareSummaries = true
        ..notifyOnlyWhenAway = true;
      await t.desktop.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      t.socket.sync(devices: [
        {'id': 'dev_pc', 'role': 'host', 'platform': 'windows', 'name': 'TEST-PC', 'online': true},
        {'id': 'dev_phone', 'role': 'pocket', 'platform': 'android', 'name': 'Pixel', 'online': true},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    tearDown(() => t.dispose());

    int alerts() => t.socket.sentFrames('send', 'alert').length;

    Future<void> finish(PhoneSync phone) async {
      phone.deliver(const TurnSummary(done: 'Fixed the login bug.'), report(now));
      await Future<void>.delayed(Duration.zero);
    }

    test('here: the phones’ card updates but they don’t ring; away (or locked): they ring', () async {
      final phone = PhoneSync(
        host: t.desktop.link,
        sessions: t.desktop.sessions,
        settings: t.desktop.settings,
        ask: t.desktop.ask,
        summariesFlagFile: '${t.temp.path}/flag',
        cue: (_) {},
        clock: () => now,
        away: () => here == null ? null : !here!,
      );
      await finish(phone);
      expect(alerts(), 0);
      expect(phone.skippedWhileHere, 1);
      expect(phone.lastSummary, 'web: Fixed the login bug.', reason: 'still kept, and the sessions list is up to date');
      here = false;
      await finish(phone);
      expect(alerts(), 1);
      here = null;
      await finish(phone);
      expect(alerts(), 2, reason: 'when Mochi can’t tell, it sends');
      t.desktop.settings.notifyOnlyWhenAway = false;
      here = true;
      await finish(phone);
      expect(alerts(), 3);
    });

    test('the desktop’s own: away comes from the PC’s rhythm', () async {
      t.usage.activity = working;
      t.desktop.rhythm.sample();
      await finish(t.desktop.phone);
      expect(alerts(), 0);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 200));
      await finish(t.desktop.phone);
      expect(alerts(), 1);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 5, displaysAsleep: true));
      await finish(t.desktop.phone);
      expect(alerts(), 2, reason: 'locked');
    });

    testWidgets('Settings › Phones: the switch, only with summaries on', (tester) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      t.desktop.settings.shareSummaries = false;
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.phones,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final row = find.ancestor(of: find.text('Only notify me when I’m away from this PC'), matching: find.byType(ToggleRow));
      await tester.ensureVisible(row);
      expect(tester.widget<ToggleRow>(row).onChanged, isNull);
      t.desktop.settings.shareSummaries = true;
      await tester.pump();
      expect(tester.widget<ToggleRow>(row).onChanged, isNotNull);
      expect(find.text('Only when I’m away from this PC'), findsNothing, reason: 'its “Not on Windows yet” row is gone');
    });
  });
}

/// A finished turn in project "web".
TurnReport report(DateTime at) => TurnReport(sessionId: 's1', project: 'web', message: 'Fixed it.', files: const ['auth.ts'], at: at);
