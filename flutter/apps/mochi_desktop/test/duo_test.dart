// Patch on the taskbar with Mochi: where his desk goes (TaskbarStage.home: room for both, tucked in, room for only
// one, none), and the stroll with him (ui/pet/taskbar_stroll.dart) on a fake taskbar, a fake window and the test's
// clock: one window covers both and stays put while Mochi potters beside him, clicks reach only their bodies, Mochi
// keeps him company as Claude works and needs you, trots over for a moment together, and has the taskbar to itself
// again when he leaves (or when there's no room, or "Patch on the taskbar" is off). Plus the pet's window in the app:
// Patch drawn beside Mochi, a wave when he's clicked, his name in the bubble and in what a screen reader hears.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

/// A standard 48-pixel taskbar's stage at 100% with [zones] (Mochi's centre ranges).
TaskbarStage stageWith(List<TaskbarZone> zones, {double scale = 1}) =>
    TaskbarStage(bar: PixelRect(0, (1080 - 48 * scale).round(), (1920 * scale).round(), 1080), scale: scale, zones: zones);

/// Mochi's and Patch's art scale on a 48-pixel taskbar (Mochi fills 92% of its 40-pixel box).
const double unit = 40 * SurfaceSizes.taskbarFill / 66;

void main() {
  late PoseLibrary library;

  setUpAll(() => library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync()));

  group("Patch's spot on the taskbar", () {
    test('room for both: his desk in the stretch, Mochi beside it with room to potter, all inside the stretch', () {
      const zone = (minX: 190.0, maxX: 680.0);
      final stage = stageWith([zone]);
      final home = stage.home(unit: unit, near: 400)!;
      expect(home.roomy, isTrue);
      expect(home.potter, stage.potterRoom);
      expect(home.petHome, 400, reason: 'where Mochi is');
      expect(home.minX, greaterThanOrEqualTo(zone.minX), reason: 'Mochi potters only in the free stretch');
      expect(home.deskRight, lessThanOrEqualTo(zone.maxX + stage.box.width / 2), reason: 'the desk keeps clear of the buttons');
      expect(home.deskX - home.petHome, closeTo(HomeStage.path * unit, 1e-9), reason: 'spaced as in the room');
      // Near the stretch's end, it's kept inside.
      expect(stage.home(unit: unit, near: 670)!.deskRight, lessThanOrEqualTo(zone.maxX + stage.box.width / 2));
      expect(stage.home(unit: unit, near: 0)!.minX, zone.minX);
    });

    test('a snug stretch: Patch tucks into his desk spot and Mochi sits right by it', () {
      final stage = stageWith([(minX: 190.0, maxX: 270.0)]);
      final home = stage.home(unit: unit, near: 230)!;
      expect(home.roomy, isFalse);
      expect(home.potter, 0);
      expect(home.minX, home.petHome);
    });

    test('room for only one: Patch stays off the taskbar and Mochi has it', () {
      final stage = stageWith([(minX: 190.0, maxX: 240.0), (minX: 1500.0, maxX: 1560.0)]);
      expect(stage.home(unit: unit, near: 200), isNull);
    });

    test('no free stretch at all: neither of them roams', () {
      final reading = FakeTaskbar.bottomTaskbar();
      final (:stage, :block) = TaskbarStage.of(reading, buttons: FakeTaskbar.windows11Buttons(reading, group: 1500));
      expect((stage, block), (null, RoamBlock.crowded));
    });

    test('the roomier stretch wins over a snug one, and the spot is kept while it still fits', () {
      const snug = (minX: 190.0, maxX: 270.0);
      const roomy = (minX: 1240.0, maxX: 1600.0);
      final stage = stageWith([snug, roomy]);
      final home = stage.home(unit: unit, near: 200)!;
      expect(home.roomy, isTrue);
      expect(home.petHome, greaterThanOrEqualTo(roomy.minX));
      // The buttons move a little: the desk stays where it was.
      final moved = stageWith([snug, (minX: 1230.0, maxX: 1590.0)]);
      expect(moved.home(unit: unit, near: 1500, previous: home), home);
      // Its spot fills up: it goes where there's room.
      final crowded = stageWith([(minX: 1400.0, maxX: 1800.0)]);
      final again = crowded.home(unit: unit, near: home.petHome, previous: home)!;
      expect(again, isNot(home));
      expect(again.minX, greaterThanOrEqualTo(1400));
    });

    test('one window covers both: from Mochi’s furthest potter to the desk; it grows upwards for a bubble', () {
      for (final scale in [1.0, 1.5]) {
        final stage = stageWith([(minX: 190.0, maxX: 680.0)], scale: scale);
        final home = stage.home(unit: unit, near: 400)!;
        final width = stage.homeWidth(home);
        final frame = stage.homeFrame(home, Size(width, stage.box.height));
        expect(frame.left, closeTo(home.left(stage.box.width) * scale, 1.5));
        expect(frame.right, closeTo(home.right * scale, 1.5));
        expect(frame.bottom, stage.boxBottom);
        final tall = stage.homeFrame(home, Size(width, stage.box.height + SurfaceSizes.bubble));
        expect((tall.bottom, tall.left, tall.width), (frame.bottom, frame.left, frame.width));
        expect(tall.height, frame.height + (SurfaceSizes.bubble * scale).round());
        // Their bodies are inside the window, side by side, and don't overlap.
        final mochi = stage.bodyAt(home.petHome);
        final patch = stage.companionBody(home);
        for (final body in [mochi, patch]) {
          expect(body.left >= frame.left && body.right <= frame.right && body.bottom <= frame.bottom && body.top >= frame.top, isTrue);
        }
        expect(mochi.overlaps(patch), isFalse);
        expect(mochi.right, lessThan(patch.left));
      }
    });
  });

  group('On the taskbar with Patch', () {
    late TestDesktop t;
    late FakePetWindow window;
    late FakeShell shell;
    late FakeTaskbar taskbar;

    setUp(() {
      t = TestDesktop.make();
      window = FakePetWindow();
      shell = FakeShell(petWindow: window);
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    });

    tearDown(() => t.dispose());

    final disposables = <void Function()>[];
    void duoTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final dispose in disposables.reversed) {
          dispose();
        }
        disposables.clear();
      }
    });

    void session(String name, {String? tool, String? notificationType}) => t.desktop.sessions.apply(
      hook(name, tool: tool, toolUseId: tool == null ? null : 'u-$tool', notificationType: notificationType, at: DateTime.now()),
    );

    /// Patch and the stroll on the test's clock, showing the pet.
    Future<(TaskbarStroll, CompanionDirector)> start(WidgetTester tester, {int seed = 7, SystemMotion? motion, FakeTaskbar? info}) async {
      double clock() => tester.binding.clock.now().microsecondsSinceEpoch / 1e6;
      final companion = CompanionDirector(
        sessions: t.desktop.sessions,
        settings: t.desktop.settings,
        cues: t.desktop.cues,
        clock: clock,
        random: Random(seed),
      )..library = library;
      final stroll = TaskbarStroll(
        shell: shell,
        taskbar: info ?? taskbar,
        settings: t.desktop.settings,
        motion: motion ?? t.desktop.motion,
        cues: t.desktop.cues,
        companion: companion,
        clock: clock,
        random: Random(seed),
      );
      disposables
        ..add(companion.dispose)
        ..add(stroll.dispose);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      return (stroll, companion);
    }

    Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.1, void Function()? each}) async {
      for (var s = 0.0; s < seconds; s += step) {
        await tester.pump(Duration(microseconds: (step * 1e6).round()));
        each?.call();
      }
    }

    duoTest('Patch arrives: his desk takes a spot beside Mochi, and one window covers both', (tester) async {
      final (stroll, companion) = await start(tester);
      expect((stroll.home, window.frames.last.width), (null, 64), reason: 'Mochi alone in its box before a session');
      session('SessionStart');
      await elapse(tester, 0.5);
      final home = stroll.home!;
      expect(home.roomy, isTrue);
      final stage = stroll.stage!;
      expect(window.frames.last, stage.homeFrame(home, stroll.windowSize));
      expect(stroll.duo!.originX, window.frames.last.left / stage.scale);
      expect(stage.zones.any((zone) => home.minX >= zone.minX - 0.5 && home.deskRight <= zone.maxX + stage.box.width / 2 + 0.5), isTrue);
      expect(companion.interaction?.id ?? companion.pending, InteractionID.welcome, reason: 'Mochi came over to say hello');
    });

    duoTest('Mochi keeps him company: it potters beside him inside the window, which never moves', (tester) async {
      final (stroll, companion) = await start(tester, seed: 3);
      session('SessionStart');
      await elapse(tester, 0.5);
      final home = stroll.home!;
      final frames = window.frames.length;
      var travelled = false;
      await elapse(
        tester,
        300,
        step: 0.5,
        each: () {
          final sample = stroll.sample()!;
          if (sample.travelling) travelled = true;
          expect(sample.x, inInclusiveRange(home.minX - 0.5, home.petHome + 0.5), reason: 'near Patch');
        },
      );
      expect(travelled, isTrue, reason: 'it potters about');
      expect(window.moves, isEmpty, reason: 'Mochi moves inside the window: no window moves');
      expect(window.frames.length, frames, reason: 'and no resizes');
      expect(stroll.home, home, reason: 'his desk stays put');
    });

    duoTest('clicks reach only their bodies: Mochi, Patch, and nothing between or around them', (tester) async {
      final (stroll, _) = await start(tester);
      session('SessionStart');
      await elapse(tester, 0.5);
      final bodies = stroll.bodies();
      expect(bodies, hasLength(2));
      final frame = stroll.frame!;
      for (final body in bodies) {
        taskbar.pointer = (body.left + body.width ~/ 2, body.top + body.height ~/ 2);
        await elapse(tester, 0.2);
        expect(window.clickThrough.last, isFalse, reason: '$body');
      }
      final patch = bodies.last;
      for (final point in [(frame.left + 1, frame.top + 1), (patch.right + 3, patch.bottom - 2), (patch.left + patch.width ~/ 2, frame.top + 1)]) {
        taskbar.pointer = point;
        await elapse(tester, 0.2);
        expect(window.clickThrough.last, isTrue, reason: '$point');
      }
    });

    duoTest('Claude works: Mochi watches beside Patch; Claude needs you: Mochi faces you from beside him', (tester) async {
      final (stroll, companion) = await start(tester, seed: 5);
      session('SessionStart');
      await elapse(tester, 6);
      session('UserPromptSubmit');
      session('PreToolUse', tool: 'Edit');
      stroll.mood = PetMood.watching;
      await elapse(tester, 8, step: 0.25);
      expect(companion.loop, CompanionAnimation.typing);
      expect([StrollActivity.watch, StrollActivity.potter], contains(stroll.sample()!.activity));
      session('Notification', notificationType: 'permission_prompt');
      stroll.mood = PetMood.needsYou;
      await elapse(tester, 6, step: 0.25);
      final sample = stroll.sample()!;
      expect(companion.loop, CompanionAnimation.waiting);
      expect((sample.x, sample.style, sample.activity), (stroll.home!.petHome, StrollStyle.attentive, StrollActivity.attend));
    });

    duoTest('a moment together: Mochi trots over first, and it starts when Mochi gets there', (tester) async {
      final (stroll, companion) = await start(tester, seed: 3);
      session('SessionStart');
      // Let the welcome play out, and wait for Mochi to wander a little way off.
      await elapse(tester, 8, step: 0.5);
      final home = stroll.home!;
      var tries = 0;
      while ((stroll.sample()!.x - home.petHome).abs() < 20 && tries++ < 400) {
        await elapse(tester, 0.5, step: 0.5);
      }
      expect((stroll.sample()!.x - home.petHome).abs(), greaterThan(19), reason: 'Mochi wandered off (seed 3)');
      session('UserPromptSubmit');
      session('Stop');
      t.desktop.cue(PetCue.finished);
      await tester.pump();
      expect(companion.pending, InteractionID.highFive, reason: 'waiting for Mochi');
      expect(stroll.sample()!.activity, StrollActivity.visit);
      var started = false;
      await elapse(
        tester,
        4,
        step: 0.05,
        each: () {
          if (companion.interaction != null && !started) {
            started = true;
            expect(stroll.sample()!.x, closeTo(home.petHome, 0.5), reason: 'it starts with Mochi beside him');
          }
        },
      );
      expect(started, isTrue);
      expect(companion.burst, isNotNull, reason: 'and confetti');
    });

    duoTest('Patch leaves: Mochi has the taskbar to itself again, in its own small window', (tester) async {
      final (stroll, companion) = await start(tester);
      session('SessionStart');
      await elapse(tester, 0.5);
      expect(stroll.home, isNotNull);
      t.desktop.settings.companionVisibility = CompanionVisibility.never;
      await elapse(tester, 3);
      expect((companion.visible, stroll.home), (false, null));
      expect(window.frames.last.width, 64);
      expect(stroll.placement, PetPlacement.taskbar);
    });

    duoTest('"Patch on the taskbar" off: Mochi alone; on again: his desk is back', (tester) async {
      final (stroll, companion) = await start(tester);
      session('SessionStart');
      await elapse(tester, 0.5);
      t.desktop.settings.companionOnTaskbar = false;
      await elapse(tester, 0.5);
      expect((companion.present, stroll.home), (true, null), reason: 'still around (in the room), just not on the taskbar');
      expect(window.frames.last.width, 64);
      t.desktop.settings.companionOnTaskbar = true;
      await elapse(tester, 0.5);
      expect(stroll.home, isNotNull);
    });

    duoTest('no stretch roomy enough for both: Patch stays off the taskbar; a snug one: Mochi sits right by him', (tester) async {
      final reading = FakeTaskbar.bottomTaskbar();
      final crowded = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading, group: 1360));
      final (stroll, companion) = await start(tester, info: crowded);
      session('SessionStart');
      await elapse(tester, 0.5);
      expect((companion.present, stroll.placement, stroll.home), (true, PetPlacement.taskbar, null));
      expect(window.frames.last.width, 64, reason: 'Mochi strolls on its own');
      crowded.measured = FakeTaskbar.windows11Buttons(reading, group: 1300);
      await elapse(tester, 7);
      final home = stroll.home!;
      expect((home.roomy, home.potter), (false, 0));
      await elapse(tester, 60, step: 0.5, each: () => expect(stroll.sample()!.x, closeTo(home.petHome, 0.5)));
    });

    duoTest('a full-screen app hides both; animation effects off: Mochi fades over to Patch and stays', (tester) async {
      var reduced = false;
      final motion = SystemMotion(read: () => reduced);
      disposables.add(motion.dispose);
      final (stroll, _) = await start(tester, motion: motion);
      session('SessionStart');
      await elapse(tester, 0.5);
      taskbar.busy = true;
      await elapse(tester, 2.5);
      expect((stroll.placement, stroll.home, shell.shown.last), (PetPlacement.hidden, null, Surface.hidden));
      taskbar.busy = false;
      await elapse(tester, 2.5);
      expect(stroll.home, isNotNull);
      reduced = true;
      motion.refresh();
      stroll.mood = PetMood.relaxed;
      await elapse(tester, 12);
      final home = stroll.home!;
      await elapse(tester, 60, step: 0.5, each: () => expect(stroll.sample()!.x, closeTo(home.petHome, 0.5)));
      expect(window.moves, isEmpty);
    });
  });

  group("The pet's window with Patch", () {
    late TestDesktop t;
    late FakeShell shell;
    late FakeTaskbar taskbar;

    setUp(() {
      t = TestDesktop.make();
      shell = FakeShell(petWindow: FakePetWindow());
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    });

    tearDown(() => t.dispose());

    testWidgets('Patch is drawn beside Mochi and named in the bubble and the spoken label; a click on him opens the popover', (tester) async {
      t.desktop.settings.companionName = 'Byte';
      tester.view.physicalSize = SurfaceSizes.pet;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: shell,
          taskbar: taskbar,
          library: Future.value(library),
          strollClock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
          strollRandom: Random(4),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
      t.desktop.sessions.apply(hook('SessionStart', at: DateTime.now()));
      await tester.pump(const Duration(milliseconds: 500));
      final stroll = state.stroll;
      final frame = stroll.frame!;
      // The window as the stroll made it (the fake shell doesn't resize the test's view).
      tester.view.physicalSize = Size(frame.width.toDouble(), frame.height.toDouble());
      await tester.pump(const Duration(milliseconds: 100));
      final view = tester.widget<MochiView>(find.byType(MochiView));
      expect(view.duo?.call(), stroll.duo);
      expect(view.companion, state.companion);
      expect((view.theme, view.deskAccessory), (OfficeTheme.cozyDesk, Accessory.plant));
      expect(find.bySemanticsLabel(RegExp(r'Byte (is|and Mochi)')), findsOneWidget);

      // Claude asks for permission: Patch asks for your OK, by his name.
      t.desktop.sessions.apply(hook('PreToolUse', tool: 'Bash', toolUseId: 'b1', at: DateTime.now()));
      t.desktop.sessions.apply(hook('Notification', notificationType: 'permission_prompt', at: DateTime.now()));
      await tester.pump(const Duration(seconds: 6));
      // The mood reaches the bubble a frame later.
      await tester.pump();
      expect(find.text('Byte needs your OK in web'), findsOneWidget);

      // A click on Patch (as on Mochi) opens the popover, above the taskbar where Mochi is.
      final body = stroll.duo!.companionBody(stroll.box.height * (1 - SurfaceSizes.taskbarFeet));
      final box = tester.getRect(find.byType(MochiView));
      await tester.tapAt(box.topLeft + body.center);
      // The window takes the popover's size (the fake shell leaves that to the test).
      tester.view.physicalSize = SurfaceSizes.popover;
      await tester.pump();
      expect(state.surface, Surface.popover);
      final shown = shell.shows.last;
      expect(shown.surface, Surface.popover);
      expect(shown.position!.dy + shown.size.height, lessThanOrEqualTo(taskbar.reading!.bounds.top.toDouble()), reason: 'never over the taskbar');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
