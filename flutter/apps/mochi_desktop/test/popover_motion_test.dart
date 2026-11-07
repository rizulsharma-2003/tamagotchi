// The popover's motion (ui/popover/genie.dart, popover_stage.dart): the genie's mesh maths, Mochi's leap, and the
// sequence with a fake window: the window is set once to its final rect before anything moves, never resized while
// the genie and the leap run, and goes back to the pet's rect only after Mochi has landed on its exact spot. With
// animation effects off, a quick fade and no genie or leap.

import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/popover/genie.dart';
import 'package:mochi_desktop/src/ui/popover/popover_stage.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

void main() {
  group('The genie', () {
    const panel = Rect.fromLTWH(100, 300, 360, 540);
    const spot = Offset(250, 900);
    const genie = Genie(panel: panel, spot: spot);

    test('folded into Mochi’s spot at the start, the whole panel at the end', () {
      for (var i = 0; i <= 20; i++) {
        final v = i / 20;
        final start = genie.row(v, 0);
        expect((start.left, start.right, start.y), (spot.dx, spot.dx, spot.dy), reason: 'row $v at t = 0');
        final end = genie.row(v, 1);
        expect((end.left, end.right), (panel.left, panel.right), reason: 'row $v at t = 1');
        expect(end.y, closeTo(panel.top + v * panel.height, 1e-9));
      }
      expect(genie.bounds(1), panel);
      expect((Genie.opacity(0), Genie.opacity(1)), (0, 1));
    });

    test('it only ever grows: each row widens and the panel rises, steadily', () {
      for (var i = 0; i <= 10; i++) {
        final v = i / 10;
        var width = 0.0, top = double.infinity;
        for (var k = 0; k <= 100; k++) {
          final t = k / 100;
          final row = genie.row(v, t);
          expect(row.right - row.left, greaterThanOrEqualTo(width - 1e-9), reason: 'row $v at $t');
          width = row.right - row.left;
          final (rise, _) = genie.span(t);
          expect(rise, lessThanOrEqualTo(top + 1e-9));
          top = rise;
          expect(row.left, inInclusiveRange(panel.left, spot.dx));
          expect(row.right, inInclusiveRange(spot.dx, panel.right));
        }
      }
    });

    test('mid-way it is a funnel: the rows nearest Mochi are the narrowest (the neck)', () {
      const t = 0.5;
      double width(double v) => genie.row(v, t).right - genie.row(v, t).left;
      expect(width(0), greaterThan(width(0.5)));
      expect(width(0.5), greaterThan(width(1)));
      expect(width(1), lessThan(panel.width * 0.2), reason: 'a thin neck at Mochi');
    });

    test('the mesh: one strip per step, sampling the picture top to bottom', () {
      final vertices = genie.vertices(0.6, const Size(720, 1080));
      expect(vertices, isA<Vertices>());
      vertices.dispose();
    });
  });

  group("Mochi's leap", () {
    const leap = Leap(from: Offset(250, 900), to: Offset(200, 450), fromScale: 0.56, toScale: 1.06);

    test('from its spot to its place in the room, at each end’s size, over an arc', () {
      expect(leap.feet(0), leap.from);
      expect(leap.feet(1), leap.to);
      expect((leap.scale(0), leap.scale(1)), (leap.fromScale, leap.toScale));
      final top = [for (var k = 0; k <= 100; k++) leap.feet(k / 100).dy].reduce(min);
      expect(top, lessThan(leap.to.dy - 20), reason: 'it rises above where it lands');
    });

    test('squashed to take off and to land, stretched in the air, then still; dust once it lands', () {
      expect(leap.squash(0), (1.0, 1.0));
      final (cx, cy) = leap.squash(Leap.crouch / 2);
      expect((cx > 1, cy < 1), (true, true), reason: 'crouching');
      final (ax, ay) = leap.squash(0.5);
      expect((ax < 1, ay > 1), (true, true), reason: 'in the air');
      final (lx, ly) = leap.squash(1 - Leap.land / 2);
      expect((lx > 1, ly < 1), (true, true), reason: 'landing');
      expect(leap.squash(1).$1, closeTo(1, 1e-9));
      expect(leap.dust(0.5), 0);
      expect(leap.dust(1), closeTo(1, 1e-9));
    });
  });

  group('The sequence', () {
    late PoseLibrary library;
    late TestDesktop t;
    late FakeShell shell;
    late FakePetWindow window;
    late FakeTaskbar taskbar;

    setUpAll(() => library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync()));

    setUp(() {
      t = TestDesktop.make();
      window = FakePetWindow();
      shell = FakeShell(petWindow: window);
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    });

    tearDown(() => t.dispose());

    /// The view takes the window's size, as Windows would (the fake window doesn't resize the test's view).
    void follow(WidgetTester tester) {
      final frame = window.current!;
      tester.view.physicalSize = Size(frame.width.toDouble(), frame.height.toDouble());
    }

    Future<void> frames(WidgetTester tester, int ms) async {
      for (var elapsed = 0; elapsed < ms; elapsed += 16) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    PopoverPhase? phase(WidgetTester tester) {
      final stage = find.byType(PopoverStage);
      return stage.evaluate().isEmpty ? null : popoverPhaseOf(stage.evaluate().single);
    }

    Future<DesktopAppState> start(WidgetTester tester) async {
      tester.view.physicalSize = const Size(64, 40);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: shell,
          taskbar: taskbar,
          library: Future.value(library),
          strollClock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
          strollRandom: Random(5),
        ),
      );
      await frames(tester, 200);
      return tester.state<DesktopAppState>(find.byType(DesktopApp));
    }

    testWidgets('open: the window goes once to its final rect, the genie plays in it, nothing resizes', (tester) async {
      final state = await start(tester);
      final pet = window.current!;
      final mochi = state.stroll.sample()!.x;
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pump();
      final geometry = state.popoverGeometry!;
      expect(geometry.mochi!.dx, mochi, reason: 'it comes out of Mochi’s spot');
      expect(geometry.window.contains(geometry.panel.center) && geometry.window.bottom >= pet.bottom, isTrue);
      final framesAtOpen = window.frames.length;
      final rect = window.current!;
      expect((rect.width, rect.height), (geometry.window.width.round(), geometry.window.height.round()), reason: 'its final rect at once');
      expect(window.clickThrough.last, isTrue, reason: 'clicks pass through while it comes out');
      follow(tester);
      await frames(tester, 200);
      expect(phase(tester), PopoverPhase.opening);
      await frames(tester, 500);
      expect(phase(tester), PopoverPhase.open);
      expect(window.frames.length, framesAtOpen, reason: 'no resize while it opened');
      expect(window.moves, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('close: the genie and the leap play in the same window, which goes back to the pet’s rect only after the landing', (
      tester,
    ) async {
      final state = await start(tester);
      final pet = window.current!;
      final spot = state.stroll.sample()!.x;
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pump();
      follow(tester);
      await frames(tester, 800);
      expect(phase(tester), PopoverPhase.open);
      final open = window.frames.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(state.popoverClosing, isTrue);
      expect(window.clickThrough.last, isTrue, reason: 'clicks pass through while it goes');
      await frames(tester, 300);
      expect([PopoverPhase.leaving, PopoverPhase.closing], contains(phase(tester)));
      expect(window.frames.length, open, reason: 'still the popover’s rect mid-leap');
      expect(state.surface, Surface.popover);
      await frames(tester, 700);
      expect(state.surface, Surface.pet, reason: 'landed');
      expect(window.frames[open], pet, reason: 'then, and only then, back to the pet’s rect: the very spot');
      follow(tester);
      await frames(tester, 100);
      expect(state.stroll.sample()!.x, spot, reason: 'Mochi carries on from where it landed');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('animation effects off: a quick fade, in and out, with no genie and no leap', (tester) async {
      // Windows' "Animation effects" off.
      t.desktop.motion.value = true;
      final state = await start(tester);
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pump();
      follow(tester);
      await frames(tester, 160);
      expect(phase(tester), PopoverPhase.open, reason: 'in 120 ms');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await frames(tester, 200);
      expect(state.surface, Surface.pet, reason: 'out in 120 ms, no leap');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
