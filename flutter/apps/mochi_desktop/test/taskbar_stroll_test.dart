// The taskbar stroll's controller (ui/pet/taskbar_stroll.dart) with a fake taskbar, a fake window and the test's
// clock: Mochi goes into the taskbar's free stretches and walks there, the window lets clicks through except on Mochi
// and stays over the taskbar, the stroll falls back to the still pet when it can't roam, hides for full-screen apps,
// and a drag off the taskbar parks Mochi. Plus "Roam along the taskbar" in the app: the setting and the tray.

import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:tray_manager/tray_manager.dart';

import 'support/fakes.dart';

void main() {
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

  // Every stroll (and its timers) goes before the test ends: the test checks for pending timers before tear-downs.
  final strolls = <TaskbarStroll>[];
  final disposables = <void Function()>[];
  void strollTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final stroll in strolls) {
        stroll.dispose();
      }
      strolls.clear();
      for (final dispose in disposables) {
        dispose();
      }
      disposables.clear();
    }
  });

  /// The stroll on the test's clock, showing the pet.
  Future<TaskbarStroll> start(WidgetTester tester, {SystemMotion? motion, TaskbarInfo? info, int seed = 7}) async {
    final stroll = TaskbarStroll(
      shell: shell,
      taskbar: info ?? taskbar,
      settings: t.desktop.settings,
      motion: motion ?? t.desktop.motion,
      cues: t.desktop.cues,
      clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
      random: Random(seed),
    );
    strolls.add(stroll);
    unawaited(stroll.show(Surface.pet));
    await tester.pump();
    return stroll;
  }

  /// Advances the clock (and every timer) by [seconds], a step at a time.
  Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.1, void Function()? each}) async {
    for (var s = 0.0; s < seconds; s += step) {
      await tester.pump(Duration(microseconds: (step * 1e6).round()));
      each?.call();
    }
  }

  strollTest('Mochi goes into the taskbar: its box, vertically centred, in a free stretch', (tester) async {
    final stroll = await start(tester);
    expect(stroll.placement, PetPlacement.taskbar);
    expect(stroll.block, isNull);
    expect(taskbar.measures, greaterThan(0), reason: 'UI Automation was asked where the buttons are');
    final stage = stroll.stage!;
    expect(stage.measured, isTrue);
    expect((shell.shows.last.surface, shell.shows.last.size), (Surface.pet, const Size(64, 40)));
    final frame = window.frames.last;
    expect(frame, stroll.frame);
    final bar = taskbar.reading!.bounds;
    expect((frame.top - bar.top, bar.bottom - frame.bottom), (4, 4));
    final centre = (frame.left + frame.width / 2) / stage.scale;
    expect(stage.zones.any((zone) => centre >= zone.minX - 1 && centre <= zone.maxX + 1), isTrue);
    expect(window.raises, greaterThan(0), reason: 'over the taskbar from the start');
  });

  strollTest('walks: the window moves only inside the free stretches, and no timer runs while Mochi rests', (tester) async {
    final stroll = await start(tester, seed: 3);
    var rested = false;
    await elapse(
      tester,
      240,
      step: 0.5,
      each: () {
        if (!stroll.moving && stroll.sample()?.travelling == false) rested = true;
      },
    );
    expect(window.moves, isNotEmpty, reason: 'Mochi walked');
    final stage = stroll.stage!;
    for (final move in window.moves) {
      // (The window grows upwards for a toy in play, so its feet stay where they are.)
      expect(move.bottom, window.frames.first.bottom, reason: 'it stays at the same height');
      final centre = (move.left + move.width / 2) / stage.scale;
      expect(stage.zones.any((zone) => centre >= zone.minX - 1 && centre <= zone.maxX + 1), isTrue, reason: '$move');
    }
    expect(rested, isTrue, reason: 'the frame timer stops while Mochi rests');
  });

  strollTest('clicks go through except on Mochi; the window goes back over the taskbar when it\'s clicked', (tester) async {
    final stroll = await start(tester);
    taskbar.pointer = (10, 10);
    await elapse(tester, 0.2);
    expect(window.clickThrough.last, isTrue);
    expect(stroll.clickThrough, isTrue);

    // Over Mochi: it takes clicks (to pet, open or drag it).
    final body = stroll.stage!.body(stroll.frame!);
    taskbar.pointer = (body.left + body.width ~/ 2, body.top + body.height ~/ 2);
    await elapse(tester, 0.2);
    expect(window.clickThrough.last, isFalse);

    // Away again (just past Mochi's body, still inside its box): through.
    taskbar.pointer = (body.right + 2, body.top + 2);
    await elapse(tester, 0.2);
    expect(window.clickThrough.last, isTrue);

    // Every half second it goes back on top; at once when the taskbar is clicked.
    final raises = window.raises;
    await elapse(tester, 1);
    expect(window.raises - raises, inInclusiveRange(1, 3));
    final before = window.raises;
    taskbar.inFront = true;
    await tester.pump(const Duration(milliseconds: 100));
    expect(window.raises, before + 1);
  });

  strollTest('a drag holds the clicks on Mochi; dropped off the taskbar, Mochi stays there and roaming turns off', (tester) async {
    final stroll = await start(tester);
    stroll.dragStarted();
    expect(window.clickThrough.lastOrNull, isNot(true));
    expect(stroll.moving, isFalse);
    stroll.dragEnded(const Offset(500, 300));
    await tester.pump();
    final settings = t.desktop.settings;
    expect(settings.roamTaskbar, isFalse);
    // Mochi's feet where they were dropped: the bigger standing pet's window around them.
    final feet = const Offset(500 + 32, 300 + 40);
    expect(settings.petPosition, TaskbarStroll.standingSpot(feet, TaskbarStage.of(taskbar.reading, buttons: taskbar.measured).stage!));
    await tester.pump();
    expect(stroll.placement, PetPlacement.standing);
    expect((shell.shows.last.surface, shell.shows.last.position, shell.shows.last.size), (Surface.pet, settings.petPosition, SurfaceSizes.pet));
    expect(window.settles, greaterThan(0), reason: 'an ordinary window again');
    expect(stroll.watchingPointer, isFalse);

    // Back to the taskbar.
    settings.roamTaskbar = true;
    await tester.pump();
    await tester.pump();
    expect(stroll.placement, PetPlacement.taskbar);
  });

  strollTest('dropped along the taskbar, Mochi carries on from there (or the nearest free spot)', (tester) async {
    final stroll = await start(tester);
    stroll.dragStarted();
    // Over the buttons in the middle: it lands in the nearest free stretch.
    stroll.dragEnded(const Offset(1300 - 32, 1036));
    await tester.pump();
    expect(t.desktop.settings.roamTaskbar, isTrue);
    expect(stroll.placement, PetPlacement.taskbar);
    expect(stroll.sample()!.x, closeTo(1300, 1));
    // A nudge: it just carries on.
    final x = stroll.sample()!.x;
    stroll.dragStarted();
    stroll.dragEnded(Offset(stroll.frame!.left + 2, stroll.frame!.top.toDouble()));
    expect(stroll.sample()!.x, closeTo(x, 30));
    expect(t.desktop.settings.roamTaskbar, isTrue);
  });

  strollTest('a speech bubble grows the window upwards (Mochi stays put) and it shrinks back', (tester) async {
    final stroll = await start(tester);
    stroll.mood = PetMood.needsYou;
    final box = window.current!;
    stroll.bubble = true;
    await tester.pump();
    final grown = window.current!;
    expect((grown.width, grown.height), (176, 96));
    expect(grown.bottom, box.bottom);
    expect(grown.left + grown.width / 2, closeTo(box.left + box.width / 2, 1));
    expect(grown.top, lessThan(taskbar.reading!.bounds.top), reason: 'the bubble is above the taskbar');
    stroll.bubble = false;
    await tester.pump();
    expect((window.current!.width, window.current!.height), (64, 40));
  });

  strollTest('Claude needs you: Mochi stops where it is and faces you', (tester) async {
    final stroll = await start(tester, seed: 5);
    await elapse(tester, 30, step: 0.5);
    stroll.mood = PetMood.needsYou;
    final x = stroll.sample()!.x;
    final moves = window.moves.length;
    await elapse(tester, 60, step: 0.5, each: () {
      expect(stroll.sample()!.travelling, isFalse);
      expect(stroll.sample()!.style, StrollStyle.attentive);
    });
    expect(stroll.sample()!.x, x);
    expect(window.moves.length, moves);
  });

  strollTest('a finished turn: Mochi holds still facing you for a moment', (tester) async {
    final stroll = await start(tester);
    await elapse(tester, 10, step: 0.5);
    t.desktop.cue(PetCue.finished);
    await tester.pump();
    expect(stroll.sample()!.activity, StrollActivity.react);
    expect(stroll.sample()!.style, StrollStyle.attentive);
    await elapse(tester, 3);
    expect(stroll.sample()!.activity, isNot(StrollActivity.react));
  });

  strollTest('animation effects off: Mochi stays put on the taskbar', (tester) async {
    final motion = SystemMotion(read: () => true);
    disposables.add(motion.dispose);
    final stroll = await start(tester, motion: motion);
    expect(stroll.placement, PetPlacement.taskbar);
    await elapse(tester, 300, step: 1);
    expect(window.moves, isEmpty);
  });

  group('The still pet instead', () {
    strollTest('a taskbar at the top, or one that hides itself', (tester) async {
      taskbar.reading = FakeTaskbar.bottomTaskbar(edge: TaskbarEdge.top);
      final stroll = await start(tester);
      expect((stroll.placement, stroll.block), (PetPlacement.standing, RoamBlock.notAtBottom));
      expect(shell.shows.last.size, SurfaceSizes.pet);

      // It's moved to the bottom: Mochi goes into it at the next look (every 10 s).
      taskbar.reading = FakeTaskbar.bottomTaskbar();
      await elapse(tester, 10.5, step: 0.5);
      expect(stroll.placement, PetPlacement.taskbar);

      taskbar.reading = FakeTaskbar.bottomTaskbar(autoHide: true);
      await elapse(tester, 10.5, step: 0.5);
      expect((stroll.placement, stroll.block), (PetPlacement.standing, RoamBlock.autoHides));
      expect(window.settles, greaterThan(0));
    });

    strollTest('no taskbar (the macOS build) or no window to move', (tester) async {
      final stroll = await start(tester, info: const NoTaskbar());
      expect((stroll.placement, stroll.block), (PetPlacement.standing, RoamBlock.unsupported));
      expect(window.frames, isEmpty);
    });

    strollTest('roaming turned off: Mochi stands just above the taskbar where it was', (tester) async {
      final stroll = await start(tester);
      final frame = stroll.frame!;
      t.desktop.settings.roamTaskbar = false;
      await tester.pump();
      expect(stroll.placement, PetPlacement.standing);
      final spot = t.desktop.settings.petPosition!;
      expect(spot.dx + SurfaceSizes.pet.width / 2, closeTo(frame.left + frame.width / 2, 1));
      expect(spot.dy + SurfaceSizes.pet.height, lessThanOrEqualTo(taskbar.reading!.bounds.top));
    });

    strollTest('UI Automation finds nothing: the stretches are estimated', (tester) async {
      taskbar.measured = null;
      final stroll = await start(tester);
      expect(stroll.placement, PetPlacement.taskbar);
      expect(stroll.stage!.measured, isFalse);
    });
  });

  strollTest('a full-screen app hides the pet, and it comes back after', (tester) async {
    final stroll = await start(tester);
    taskbar.busy = true;
    await elapse(tester, 2.5, step: 0.5);
    expect(stroll.placement, PetPlacement.hidden);
    expect(shell.shown.last, Surface.hidden);
    taskbar.busy = false;
    await elapse(tester, 2.5, step: 0.5);
    expect(stroll.placement, PetPlacement.taskbar);
    expect(shell.shown.last, Surface.pet);
  });

  strollTest('the main window: the pet\'s window takes clicks again and nothing watches it', (tester) async {
    final stroll = await start(tester);
    taskbar.pointer = (0, 0);
    await elapse(tester, 0.3);
    await stroll.show(Surface.main);
    expect(shell.shown.last, Surface.main);
    expect(stroll.placement, PetPlacement.away);
    expect(window.settles, greaterThan(0));
    expect((stroll.moving, stroll.waiting, stroll.watchingPointer), (false, false, false));
  });

  group('Where Mochi lives', () {
    test('roaming the taskbar by default; off the taskbar is the classic tray icon, and back is the style it had', () {
      final document = MemorySettingsDocument();
      final settings = DesktopSettings(document);
      expect((settings.petStyle, settings.roamTaskbar), (DesktopStyle.roam, true));
      settings.petStyle = DesktopStyle.spot;
      settings.roamTaskbar = false;
      expect((settings.petStyle, document.json!['roamTaskbar'], document.json!['petStyle']), (DesktopStyle.icon, false, 'icon'));
      expect(DesktopSettings(document).roamTaskbar, isFalse);
      settings.roamTaskbar = true;
      expect(settings.petStyle, DesktopStyle.spot, reason: 'back the way it was on the taskbar');
      expect(DesktopSettings(document).petStyle, DesktopStyle.spot);
      // A file from before version 5 had only "Roam along the taskbar".
      expect(DesktopSettings(MemorySettingsDocument({'roamTaskbar': false})).petStyle, DesktopStyle.icon);
      expect(DesktopSettings(MemorySettingsDocument({'roamTaskbar': true})).petStyle, DesktopStyle.roam);
    });

    test('the tray menu ticks where Mochi lives, as the Mac\'s status menu lists its styles', () {
      MenuItem item(List<MenuItem> items, ShellAction action) => items.firstWhere((item) => item.key == action.name);
      for (final style in DesktopStyle.values) {
        final items = NativeShell.trayItems(style: style);
        final ticks = {
          for (final action in [ShellAction.roamTaskbar, ShellAction.playInSpot, ShellAction.trayIcon]) item(items, action).label: item(items, action).checked,
        };
        expect(ticks, {
          'Roams the taskbar': style == DesktopStyle.roam,
          'Plays in its spot': style == DesktopStyle.spot,
          'Classic tray icon': style == DesktopStyle.icon,
        });
        expect(item(items, ShellAction.roamTaskbar).type, 'checkbox');
      }
    });

    testWidgets('the tray\'s styles: the classic icon takes Mochi off the taskbar, a taskbar style puts it (and the pet) back', (tester) async {
      tester.view.physicalSize = SurfaceSizes.pet;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(desktop: t.desktop, shell: shell, taskbar: taskbar, library: Future<PoseLibrary?>.value()),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
      expect(state.stroll.placement, PetPlacement.taskbar);
      expect(shell.trayStyles.last, DesktopStyle.roam);

      shell.controller.add(ShellAction.trayIcon);
      await tester.pump();
      expect(t.desktop.settings.roamTaskbar, isFalse);
      expect(shell.trayStyles.last, DesktopStyle.icon);
      await tester.pump();
      expect(state.stroll.placement, PetPlacement.standing);

      t.desktop.settings.showPet = false;
      await tester.pump();
      shell.controller.add(ShellAction.playInSpot);
      await tester.pump();
      await tester.pump();
      expect((t.desktop.settings.petStyle, t.desktop.settings.showPet), (DesktopStyle.spot, true));
      expect(shell.trayStyles.last, DesktopStyle.spot);
      expect(state.stroll.placement, PetPlacement.taskbar);

      // A right-click on Mochi in the taskbar shows the tray's menu (its window is too small for its own).
      await tester.tap(find.byType(GestureDetector).first, buttons: kSecondaryButton);
      await tester.pump();
      expect(shell.menus, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a drag on the pet goes through the stroll: off the taskbar, with Adventures off, it parks Mochi', (tester) async {
      // With Adventures on (the default) and a native stage (Windows), the drop starts an adventure instead
      // (desktop_pet_test.dart covers that hook).
      t.desktop.settings.adventure = t.desktop.settings.adventure.copyWith(enabled: false);
      tester.view.physicalSize = SurfaceSizes.pet;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(desktop: t.desktop, shell: shell, taskbar: taskbar, library: Future<PoseLibrary?>.value()),
      );
      await tester.pump(const Duration(milliseconds: 100));
      shell.dropAt = const Offset(400, 200);
      await tester.drag(find.byType(GestureDetector).first, const Offset(0, -60));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(shell.drags, 1);
      expect(t.desktop.settings.roamTaskbar, isFalse);
      expect(t.desktop.settings.petPosition, isNotNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

