// Mochi on the taskbar while Mochi's window is open (docs/SPRINT_2.md W26): the pet's window is Mochi's pages then, and the
// native stage draws Mochi where the pet's window would, so the stroll goes on. With a fake taskbar, a fake window, the
// test's clock and a stand that records what it's told (and, for the clicks, the real one on a fake stage): Mochi goes to
// the stage at the very spot it stands and comes back to the window at the spot the stage had it, strolls on while the
// window is open, hides for a full-screen app, does nothing while the screen is unseen, and keeps to what a plain
// picture shows (no toys, no landmark lifts, no Peekaboo).

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/platform/native_stage.dart' show StagePointerKind;
import 'package:mochi_desktop/src/core/pc_rhythm.dart' show SystemActivity;
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';

import 'support/fake_stage.dart';
import 'support/fakes.dart';

/// A stand that records what it's shown.
class _Stand implements TaskbarStand {
  final List<({StrollSample sample, (int, int) feet, double ratio, double unit})> shows = [];
  int raises = 0;
  int hides = 0;

  @override
  bool shown = false;

  @override
  bool show(StrollSample sample, {required (int, int) feet, required double ratio, required double unit}) {
    shows.add((sample: sample, feet: feet, ratio: ratio, unit: unit));
    shown = true;
    return true;
  }

  @override
  void raise() => raises++;

  @override
  void hide() {
    hides++;
    shown = false;
  }
}

void main() {
  late TestDesktop t;
  late FakePetWindow window;
  late FakeShell shell;
  late FakeTaskbar taskbar;
  late _Stand stand;
  final strolls = <TaskbarStroll>[];

  setUp(() {
    t = TestDesktop.make();
    window = FakePetWindow();
    shell = FakeShell(petWindow: window);
    final reading = FakeTaskbar.bottomTaskbar();
    taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    stand = _Stand();
  });

  tearDown(() => t.dispose());

  void standTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final stroll in strolls) {
        stroll.dispose();
      }
      strolls.clear();
    }
  });

  Future<TaskbarStroll> start(WidgetTester tester, {int seed = 7, TaskbarStand? withStand}) async {
    final stroll = TaskbarStroll(
      shell: shell,
      taskbar: taskbar,
      settings: t.desktop.settings,
      motion: t.desktop.motion,
      cues: t.desktop.cues,
      rhythm: t.desktop.rhythm,
      mischief: t.desktop.mischief,
      clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
      random: Random(seed),
    )..stand = withStand ?? stand;
    strolls.add(stroll);
    unawaited(stroll.show(Surface.pet));
    await tester.pump();
    return stroll;
  }

  Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.1}) async {
    for (var s = 0.0; s < seconds; s += step) {
      await tester.pump(Duration(microseconds: (step * 1e6).round()));
    }
  }

  /// Mochi's window opens (without time passing).
  Future<void> openMain(WidgetTester tester, TaskbarStroll stroll) async {
    unawaited(stroll.show(Surface.main));
    await tester.pump();
  }

  _strollerCases();

  group('handing over', () {
    standTest('opening Mochi\'s window hands Mochi to the stage at the very spot, the same size and on the same feet line', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 20);
      final stage = stroll.stage!;
      final before = stroll.sample()!;
      final moves = window.moves.length;
      final frames = window.frames.length;
      await openMain(tester, stroll);
      expect(stroll.placement, PetPlacement.stage);
      expect(shell.shown.last, Surface.main);
      expect(stand.shown, isTrue);
      final first = stand.shows.first;
      expect(first.feet.$1, (before.x * stage.scale).round(), reason: 'where it stood');
      expect(first.feet.$2, stage.boxBottom - (stroll.box.height * SurfaceSizes.taskbarFeet * stage.scale).round(), reason: 'the pet window\'s feet line');
      expect((first.ratio, first.unit), (stage.scale, stroll.unit), reason: 'the taskbar\'s size, not the desktop\'s');
      expect(first.sample.facing, before.facing);
      expect(window.moves.length, moves, reason: 'the window is Mochi\'s pages now: it isn\'t moved');
      expect(window.frames.length, frames);
      expect(window.settles, greaterThan(0), reason: 'the main window takes clicks');
      expect(stroll.standingClickThrough, isFalse);
    });

    standTest('closing it hands Mochi back to the window at the spot the stage had it, and the stage lets it go', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 20);
      final scale = stroll.stage!.scale;
      await openMain(tester, stroll);
      await elapse(tester, 25);
      final x = stand.shows.last.sample.x;
      expect(stand.shows.last.feet.$1, (x * scale).round());
      stand.hides = 0;
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      await elapse(tester, 0.5);
      expect(stroll.placement, PetPlacement.taskbar);
      final frame = stroll.frame!;
      expect((frame.left + frame.width / 2) / scale, closeTo(x, 1));
      expect(stand.hides, greaterThan(0));
      expect(stand.shown, isFalse);
      expect(stroll.stroller.view, isTrue);
    });

    standTest('Patch isn\'t drawn by the stage: Mochi has the taskbar to itself while the window is open, and Patch\'s desk is back after', (tester) async {
      t.desktop.receive(hook('SessionStart', at: DateTime.now()));
      final patch = CompanionDirector(t.desktop.world);
      addTearDown(patch.dispose);
      final stroll = TaskbarStroll(
        shell: shell,
        taskbar: taskbar,
        settings: t.desktop.settings,
        motion: t.desktop.motion,
        cues: t.desktop.cues,
        companion: patch,
        clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        random: Random(7),
      )..stand = stand;
      strolls.add(stroll);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      await elapse(tester, 1);
      expect(stroll.home, isNotNull, reason: 'Patch is on the taskbar');
      final desk = stroll.stroller.home;
      expect(desk, isNotNull);
      await openMain(tester, stroll);
      expect(stroll.placement, PetPlacement.stage);
      expect(stroll.home, isNull);
      expect(stroll.stroller.home, isNull, reason: 'Mochi roams the whole taskbar alone');
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      await elapse(tester, 0.5);
      expect(stroll.home, isNotNull, reason: 'Patch is back at his desk');
    });
  });

  group('while the window is open', () {
    standTest('the stroll goes on: Mochi walks along the taskbar, drawn by the stage, and the window isn\'t moved', (tester) async {
      final stroll = await start(tester, seed: 3);
      await openMain(tester, stroll);
      final moves = window.moves.length;
      var travelled = false;
      var rested = false;
      await elapse(tester, 300, step: 0.5);
      for (final show in stand.shows) {
        if (show.sample.travelling) travelled = true;
      }
      for (var s = 0; s < 40 && !rested; s++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (!stroll.moving) rested = true;
      }
      expect(travelled, isTrue, reason: 'it walked');
      expect(rested, isTrue, reason: 'no frame timer while it sits');
      final xs = {for (final show in stand.shows) show.feet.$1};
      expect(xs.length, greaterThan(40), reason: 'it moved along the taskbar');
      expect(window.moves.length, moves);
      expect(stroll.sample(), isNotNull);
    });

    standTest('frames only while it moves: sitting draws nothing new and no timer runs but its next wake-up', (tester) async {
      final stroll = await start(tester, seed: 3);
      await openMain(tester, stroll);
      // Wait for a long hold.
      var held = false;
      for (var s = 0; s < 600 && !held; s++) {
        await tester.pump(const Duration(milliseconds: 500));
        final sample = stroll.sample()!;
        held = !stroll.moving && !sample.travelling && !stroll.stroller.playingAt(stroll.now());
      }
      expect(held, isTrue);
      final shows = stand.shows.length;
      expect(stroll.waiting, isTrue, reason: 'one wake-up for when the picture next changes');
      await tester.pump(const Duration(milliseconds: 500));
      expect(stand.shows.length, shows, reason: 'nothing drawn while it holds');
    });

    standTest('a click on Mochi\'s pixels does the tray icon\'s click; a right-click is the pet\'s menu (the real stand on a fake stage)', (tester) async {
      final fake = FakeNativeStage();
      var opened = 0;
      final menus = <(int, int)>[];
      final mischief = MischiefStage(
        desktop: t.desktop,
        stage: fake,
        displays: FakeDisplays([FakeDisplays.main1080]),
        cursor: () => null,
        home: _NoHome(),
        onOpen: () => opened++,
        onMenu: (x, y) => menus.add((x, y)),
      );
      addTearDown(mischief.dispose);
      final real = mischief.stand!;
      final actor = real.pet.actor;
      fake.point(actor, StagePointerKind.down, x: 10, y: 10, screenX: 400, screenY: 1040);
      fake.point(actor, StagePointerKind.up, x: 10, y: 10, screenX: 400, screenY: 1040);
      expect(opened, 1, reason: 'a click: Mochi\'s own page, as the tray icon\'s click');
      // A press that moved off isn't a click.
      fake.point(actor, StagePointerKind.down, screenX: 400, screenY: 1040);
      fake.point(actor, StagePointerKind.up, screenX: 460, screenY: 1040);
      expect(opened, 1);
      fake.point(actor, StagePointerKind.rightUp, screenX: 410, screenY: 1030);
      expect(menus, [(410, 1030)]);
      // Another actor's clicks aren't Mochi's.
      fake.point(actor + 99, StagePointerKind.down);
      fake.point(actor + 99, StagePointerKind.up);
      expect(opened, 1);
    });

    standTest('the stand draws Mochi at the taskbar\'s size, on the stage, and never behind the window in use', (tester) async {
      final fake = FakeNativeStage();
      final mischief = MischiefStage(
        desktop: t.desktop,
        stage: fake,
        displays: FakeDisplays([FakeDisplays.main1080]),
        cursor: () => null,
        home: _NoHome(),
      );
      addTearDown(mischief.dispose);
      final real = mischief.stand!;
      final stroll = await start(tester, withStand: real);
      await openMain(tester, stroll);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(real.shown, isTrue, reason: 'its picture came up');
      final shot = fake.showing[real.pet.actor]!;
      expect(shot.topmost, isTrue);
      expect(shot.clickThrough, isFalse);
      expect(shot.hand, isTrue);
      expect(fake.belows, isEmpty, reason: 'no Peekaboo behind the window in use');
      stroll.stand = null;
    });

    standTest('it is put back over the taskbar every half second, and at once when the taskbar is clicked', (tester) async {
      final stroll = await start(tester);
      await openMain(tester, stroll);
      await elapse(tester, 0.6);
      final raises = stand.raises;
      expect(raises, greaterThan(0), reason: 'over the taskbar from the start');
      await elapse(tester, 2);
      expect(stand.raises, greaterThanOrEqualTo(raises + 3));
      final seen = stand.raises;
      taskbar.inFront = true;
      await tester.pump(const Duration(milliseconds: 120));
      expect(stand.raises, seen + 1, reason: 'a click on the taskbar: up again at once');
    });

    standTest('a full-screen app hides it, and it\'s back when the app is gone', (tester) async {
      final stroll = await start(tester);
      await openMain(tester, stroll);
      await elapse(tester, 1);
      expect(stand.shown, isTrue);
      taskbar.busy = true;
      await elapse(tester, 4);
      expect(stand.shown, isFalse);
      expect(stroll.placement, PetPlacement.away);
      expect(stroll.moving || stroll.waiting, isFalse, reason: 'nothing moves while it is away');
      final shows = stand.shows.length;
      await elapse(tester, 10);
      expect(stand.shows.length, shows);
      taskbar.busy = false;
      await elapse(tester, 4);
      expect(stand.shown, isTrue);
      expect(stroll.placement, PetPlacement.stage);
    });

    standTest('nothing runs while nobody can see the screen, and Mochi carries on when it is back', (tester) async {
      final stroll = await start(tester, seed: 3);
      await openMain(tester, stroll);
      await elapse(tester, 5);
      expect(stroll.watchingPointer, isTrue);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
      await tester.pump();
      expect(t.desktop.rhythm.unseen, isTrue);
      expect(stroll.anyTimer, isFalse, reason: 'no frames, no pointer checks, no taskbar checks');
      final shows = stand.shows.length;
      await tester.pump(const Duration(minutes: 5));
      expect(stand.shows.length, shows);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 0));
      await tester.pump();
      await elapse(tester, 1);
      expect(stroll.watchingPointer, isTrue);
      expect(stand.shows.length, greaterThan(shows));
    });

    standTest('roaming turned off, or the pet off, takes Mochi off the stage', (tester) async {
      final stroll = await start(tester);
      await openMain(tester, stroll);
      expect(stand.shown, isTrue);
      t.desktop.settings.showPet = false;
      await elapse(tester, 0.5);
      expect(stand.shown, isFalse);
      expect(stroll.placement, PetPlacement.away);
      t.desktop.settings.showPet = true;
      await elapse(tester, 0.5);
      expect(stand.shown, isTrue);
      expect(stroll.placement, PetPlacement.stage);
    });

    standTest('the popover surface is unchanged: Mochi is in the popover\'s room, and nothing is on the stage', (tester) async {
      final stroll = await start(tester);
      await elapse(tester, 3);
      unawaited(stroll.show(Surface.popover));
      await tester.pump();
      await elapse(tester, 0.5);
      expect(shell.shown.last, Surface.popover);
      expect(stroll.placement, PetPlacement.away);
      expect(stand.shows, isEmpty);
      expect(stand.shown, isFalse);
      expect(stroll.popover, isNotNull);
    });
  });
}

/// A home that is never out (the stand's own stage tests).
class _NoHome extends ChangeNotifier implements PetHome {
  @override
  bool get out => false;

  @override
  bool get canGoOut => false;

  @override
  ({int x, int y, double scale, double facing, double unit})? departure() => null;

  @override
  void goOut() {}

  @override
  void comeBack({int? x}) {}
}

void _strollerCases() {
  group('the plan without the pet\'s view', () {
    const zones = [StrollLine(190, 680), StrollLine(1236, 1600)];
    const excluded = {
      StrollActivity.butterfly,
      StrollActivity.ball,
      StrollActivity.yarn,
      StrollActivity.leaf,
      StrollActivity.swing,
      StrollActivity.batStart,
      StrollActivity.perch,
      StrollActivity.hide,
    };
    const marks = [
      StrollLandmark(StrollVisit.clock, x: 900, lift: 8, up: 90, reach: 900),
      StrollLandmark(StrollVisit.start, x: 700, reach: 900),
      StrollLandmark(StrollVisit.widgets, x: 100, lift: 30, up: 90, reach: 900),
    ];

    test('toys, landmark visits and Peekaboo are never chosen, while the walking, resting and zoomies are', () {
      final seen = <StrollActivity>{};
      for (var seed = 0; seed < 16; seed++) {
        final stroller = Stroller(random: Random(seed))
          ..useView(false, 0)
          ..place(zones, now: 0, x: 300);
        stroller.setLandmarks(marks, 0);
        expect(stroller.hide(0), isFalse, reason: 'Peekaboo needs the view');
        expect(stroller.visitNow(StrollVisit.clock, 0), isFalse);
        for (var now = 0.0; now < 3000; now += 0.5) {
          stroller.update(now, mode: StrollMode.free);
          for (final segment in stroller.segments) {
            seen.add(segment.activity);
          }
          final sample = stroller.sample(now);
          expect(sample.props, isEmpty);
          expect(sample.sink, 0);
          expect(sample.lift, 0);
        }
        expect(stroller.playRoom(100), isNull);
        final draws = {for (var i = 0; i < 400; i++) stroller.chooseFreeActivity()};
        expect(draws.intersection(excluded), isEmpty, reason: 'seed $seed');
      }
      expect(seen.intersection(excluded), isEmpty);
      expect(seen, containsAll([StrollActivity.wander, StrollActivity.rest, StrollActivity.nap, StrollActivity.sniff, StrollActivity.zoomies]));
    });

    test('handing over cuts a toy that is in play (Mochi stands where it is), and the view brings the toys back', () {
      final stroller = Stroller(random: Random(5))..place(zones, now: 0, x: 300);
      // Run until a toy is up.
      var now = 0.0;
      while (now < 4000 && !(stroller.segments.any((s) => s.activity == StrollActivity.ball || s.activity == StrollActivity.butterfly) && stroller.playRoom(now) != null)) {
        now += 0.25;
        stroller.update(now, mode: StrollMode.free);
      }
      expect(stroller.playRoom(now), isNotNull, reason: 'a toy is in play');
      final x = stroller.sample(now).x;
      stroller.useView(false, now);
      expect(stroller.playRoom(now), isNull);
      expect(stroller.sample(now).props, isEmpty);
      expect(stroller.sample(now).x, closeTo(x, 0.5), reason: 'it stays where it is');
      stroller.useView(true, now);
      final draws = {for (var i = 0; i < 600; i++) stroller.chooseFreeActivity()};
      expect(draws.intersection({StrollActivity.ball, StrollActivity.yarn, StrollActivity.butterfly, StrollActivity.leaf}), isNotEmpty);
    });
  });
}
