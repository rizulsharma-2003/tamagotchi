// Where Mochi goes in the taskbar: its box at 100%, 150% and 200%, the free stretches between the buttons (measured
// by UI Automation, or estimated from Explorer's settings), and when there's no stroll at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';

import 'support/fakes.dart';

void main() {
  group('Mochi\'s box in the taskbar', () {
    for (final (scale, width, height) in [(1.0, 1920, 1080), (1.5, 2880, 1620), (2.0, 3840, 2160)]) {
      test('at ${(scale * 100).round()}%: the size of the taskbar, vertically centred, growing upwards for a bubble', () {
        final reading = FakeTaskbar.bottomTaskbar(width: width, height: height, scale: scale);
        final stage = TaskbarStage.of(reading, buttons: FakeTaskbar.windows11Buttons(reading)).stage!;
        final bar = reading.bounds;
        expect(bar.height, (48 * scale).round());
        expect(stage.box, const Size(64, 40), reason: 'the same logical size at every scale');

        final frame = stage.frame(400, stage.box);
        expect(frame.width, (64 * scale).round());
        expect(frame.height, (40 * scale).round());
        expect(frame.left + frame.width / 2, closeTo(400 * scale, 1), reason: 'centred on Mochi');
        // Inside the taskbar, with the same room above and below.
        expect(frame.top - bar.top, bar.bottom - frame.bottom);
        expect(frame.top, greaterThan(bar.top));
        expect(frame.bottom, lessThan(bar.bottom));

        // A bubble: wider, taller, the bottom where it was (so Mochi doesn't move), the top above the taskbar.
        final bubble = stage.frame(400, const Size(176, 96));
        expect(bubble.bottom, frame.bottom);
        expect(bubble.width, (176 * scale).round());
        expect(bubble.top, lessThan(bar.top));
        expect(bubble.left + bubble.width / 2, closeTo(400 * scale, 1));

        // Mochi's body takes the clicks: inside the box, at its centre.
        final body = stage.body(frame);
        expect(body.left, greaterThanOrEqualTo(frame.left));
        expect(body.right, lessThanOrEqualTo(frame.right));
        expect(body.bottom, frame.bottom);
        expect(body.contains(frame.left + frame.width ~/ 2, frame.top + frame.height ~/ 2), isTrue);
        expect(body.contains(frame.left + 1, frame.top + 1), isFalse, reason: 'the corners let clicks through');
        expect(stage.logical(frame).dx, closeTo(frame.left / scale, 0.001));
      });
    }

    test('a small taskbar gets a smaller Mochi, a big one a bigger one (within limits)', () {
      TaskbarStage stageFor(int barHeight) {
        final reading = TaskbarReading(
          edge: TaskbarEdge.bottom,
          bounds: PixelRect(0, 1080 - barHeight, 1920, 1080),
          monitor: const PixelRect(0, 0, 1920, 1080),
          workArea: PixelRect(0, 0, 1920, 1080 - barHeight),
          autoHide: false,
          scale: 1,
        );
        return TaskbarStage.of(reading).stage!;
      }

      expect(stageFor(40).box.height, 32);
      expect(stageFor(30).box.height, 24, reason: 'never smaller than 24');
      expect(stageFor(72).box.height, 48, reason: 'never bigger than 48');
    });
  });

  group('The free stretches', () {
    test('between the widgets tile and the buttons, and between the buttons and the tray (UI Automation)', () {
      final reading = FakeTaskbar.bottomTaskbar();
      final buttons = FakeTaskbar.windows11Buttons(reading);
      final stage = TaskbarStage.of(reading, buttons: buttons).stage!;
      expect(stage.measured, isTrue);
      expect(stage.zones, hasLength(2));
      final (left, right) = (stage.zones.first, stage.zones.last);
      // Widgets end at 150, the buttons run 720–1196, the tray starts at 1640; Mochi's box is 64 wide, 8 clear.
      expect(left.minX, 150 + 8 + 32);
      expect(left.maxX, 720 - 8 - 32);
      expect(right.minX, 1196 + 8 + 32);
      expect(right.maxX, 1640 - 8 - 32);
      // No spot in either stretch puts Mochi's box over a button.
      for (final zone in stage.zones) {
        for (final x in [zone.minX, (zone.minX + zone.maxX) / 2, zone.maxX]) {
          final frame = stage.frame(x, stage.box);
          for (final button in TaskbarZones.buttonsIn(reading.bounds, buttons)) {
            expect(frame.left >= button.right || frame.right <= button.left, isTrue, reason: 'x $x overlaps $button');
          }
        }
      }
    });

    test('the same stretches (in logical pixels) at 150% and 200%', () {
      final base = TaskbarStage.of(FakeTaskbar.bottomTaskbar(), buttons: FakeTaskbar.windows11Buttons(FakeTaskbar.bottomTaskbar())).stage!;
      for (final (scale, width, height) in [(1.5, 2880, 1620), (2.0, 3840, 2160)]) {
        final reading = FakeTaskbar.bottomTaskbar(width: width, height: height, scale: scale);
        final stage = TaskbarStage.of(reading, buttons: FakeTaskbar.windows11Buttons(reading)).stage!;
        expect(stage.zones, hasLength(2));
        for (var i = 0; i < 2; i++) {
          expect(stage.zones[i].minX, closeTo(base.zones[i].minX, 1));
          expect(stage.zones[i].maxX, closeTo(base.zones[i].maxX, 1));
        }
      }
    });

    test('UI Automation\'s containers and the taskbar itself are not buttons', () {
      final bar = const PixelRect(0, 1032, 1920, 1080);
      final buttons = TaskbarZones.buttonsIn(bar, [
        bar,
        const PixelRect(0, 1032, 1900, 1080), // a frame across the taskbar
        const PixelRect(0, 0, 40, 40), // somewhere else on the screen
        const PixelRect(700, 1036, 744, 1076), // a button
        const PixelRect(800, 1050, 900, 1052), // a thin line, not a button
        const PixelRect(10, 1040, 10, 1070), // empty
      ]);
      expect(buttons, [const PixelRect(700, 1036, 744, 1076)]);
    });

    test('Mochi keeps its bubble on screen: the stretches stay clear of the screen\'s sides', () {
      final reading = FakeTaskbar.bottomTaskbar(widgets: false);
      // Nothing on the left at all: the stretch starts 92 in, so a 176-wide bubble centred on Mochi fits.
      final stage = TaskbarStage.of(reading, buttons: [const PixelRect(720, 1036, 1196, 1076), reading.tray!]).stage!;
      expect(stage.zones.first.minX, 92);
      expect(stage.zones.first.minX - 176 / 2, greaterThanOrEqualTo(0));
    });

    group('estimated when UI Automation can\'t say', () {
      test('centred buttons with the widgets tile', () {
        final stage = TaskbarStage.of(FakeTaskbar.bottomTaskbar()).stage!;
        expect(stage.measured, isFalse);
        // Widgets 0–160, a 55% band for the buttons (432–1488), the tray from 1640.
        expect(stage.zones.map((zone) => (zone.minX, zone.maxX)), [(160 + 40.0, 432 - 40.0), (1488 + 40.0, 1640 - 40.0)]);
      });

      test('centred buttons without widgets: the left stretch reaches to the screen\'s edge margin', () {
        final stage = TaskbarStage.of(FakeTaskbar.bottomTaskbar(widgets: false)).stage!;
        expect(stage.zones.first.minX, 92);
        expect(stage.zones.first.maxX, 392);
      });

      test('left-aligned buttons: one stretch on the right, before the widgets tile next to the tray', () {
        final withWidgets = TaskbarStage.of(FakeTaskbar.bottomTaskbar(centred: false)).stage!;
        expect(withWidgets.zones.map((zone) => (zone.minX, zone.maxX)), [(960 + 40.0, 1480 - 40.0)]);
        final without = TaskbarStage.of(FakeTaskbar.bottomTaskbar(centred: false, widgets: false)).stage!;
        expect(without.zones.map((zone) => (zone.minX, zone.maxX)), [(960 + 40.0, 1640 - 40.0)]);
      });

      test('the right-hand part is the tray when it has no window', () {
        final reading = FakeTaskbar.bottomTaskbar();
        final noTray = TaskbarReading(
          edge: reading.edge,
          bounds: reading.bounds,
          monitor: reading.monitor,
          workArea: reading.workArea,
          autoHide: false,
          scale: 1,
        );
        final occupied = TaskbarZones.estimate(noTray);
        expect(occupied.first, const PixelRect(1920 - 280, 1032, 1920, 1080));
      });
    });
  });

  group('No stroll', () {
    test('a taskbar at the top or a side, one that hides itself, or none', () {
      for (final edge in [TaskbarEdge.top, TaskbarEdge.left, TaskbarEdge.right]) {
        expect(TaskbarStage.of(FakeTaskbar.bottomTaskbar(edge: edge)).block, RoamBlock.notAtBottom);
      }
      expect(TaskbarStage.of(FakeTaskbar.bottomTaskbar(autoHide: true)).block, RoamBlock.autoHides);
      expect(TaskbarStage.of(null).block, RoamBlock.unreadable);
      final reading = FakeTaskbar.bottomTaskbar();
      final odd = TaskbarReading(
        edge: TaskbarEdge.bottom,
        bounds: reading.bounds,
        monitor: reading.monitor,
        workArea: reading.workArea,
        autoHide: false,
        scale: 0,
      );
      expect(TaskbarStage.of(odd).block, RoamBlock.unreadable);
    });

    test('a taskbar full of buttons', () {
      final reading = FakeTaskbar.bottomTaskbar(width: 800);
      final buttons = [for (var x = 0; x < 800; x += 44) PixelRect(x, 1036, x + 44, 1076)];
      expect(TaskbarStage.of(reading, buttons: buttons).block, RoamBlock.crowded);
    });

    test('every reason has something to say in Settings', () {
      for (final block in RoamBlock.values) {
        expect(block.note, isNotEmpty);
      }
    });
  });
}
