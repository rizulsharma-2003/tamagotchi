// Where Windows' taskbar is and what's on it, for Mochi's stroll inside it (ui/pet/taskbar_stroll.dart), as Mochi
// walks inside the menu bar on the Mac.
//
// Rectangles are in physical pixels, as Win32 reports them (the app is per-monitor DPI aware). Mochi's position along
// the taskbar is in logical pixels (physical ÷ the screen's scale), so it looks and walks the same at 100%, 150% or
// 200%.
//
// Mochi only walks in the taskbar's empty stretches: between the widgets tile and the centred buttons, and between the
// buttons and the tray. They come from the buttons UI Automation finds on the taskbar or, if it can't, from an
// estimate (the tray's own window, Explorer's alignment and widgets settings, a generous middle band for the buttons).

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

import 'win32_taskbar.dart';

/// A rectangle in physical pixels.
@immutable
class PixelRect {
  const PixelRect(this.left, this.top, this.right, this.bottom);

  const PixelRect.ltwh(int left, int top, int width, int height) : this(left, top, left + width, top + height);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;
  bool get isEmpty => width <= 0 || height <= 0;
  bool sameSize(PixelRect other) => width == other.width && height == other.height;
  bool contains(int x, int y) => x >= left && x < right && y >= top && y < bottom;
  bool overlaps(PixelRect other) => left < other.right && other.left < right && top < other.bottom && other.top < bottom;

  @override
  bool operator ==(Object other) =>
      other is PixelRect && other.left == left && other.top == top && other.right == right && other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'PixelRect($left, $top, $right, $bottom)';
}

/// The screen edge the taskbar is docked to.
enum TaskbarEdge { left, top, right, bottom }

/// What Windows says about the taskbar on the main screen.
@immutable
class TaskbarReading {
  const TaskbarReading({
    required this.edge,
    required this.bounds,
    required this.monitor,
    required this.workArea,
    required this.autoHide,
    required this.scale,
    this.tray,
    this.centred = true,
    this.widgets = true,
  });

  final TaskbarEdge edge;

  /// The taskbar itself.
  final PixelRect bounds;

  /// The main screen, and the part of it apps get (without the taskbar).
  final PixelRect monitor;
  final PixelRect workArea;

  /// "Automatically hide the taskbar" is on.
  final bool autoHide;

  /// The main screen's display scale: 1 at 100%, 1.5 at 150%.
  final double scale;

  /// The notification area (the tray's `TrayNotifyWnd`), if Windows has one.
  final PixelRect? tray;

  /// The buttons are centred (Windows 11's `TaskbarAl`, 1 unless set to 0); otherwise they start at the left.
  final bool centred;

  /// The widgets tile is shown (`TaskbarDa`).
  final bool widgets;

  @override
  bool operator ==(Object other) =>
      other is TaskbarReading &&
      other.edge == edge &&
      other.bounds == bounds &&
      other.monitor == monitor &&
      other.workArea == workArea &&
      other.autoHide == autoHide &&
      other.scale == scale &&
      other.tray == tray &&
      other.centred == centred &&
      other.widgets == widgets;

  @override
  int get hashCode => Object.hash(edge, bounds, monitor, workArea, autoHide, scale, tray, centred, widgets);
}

/// The taskbar and the screen's state, behind an interface so the stroll can be tested (and so the macOS development
/// build, which has no taskbar, just answers "none").
abstract interface class TaskbarInfo {
  /// False where there's no taskbar at all (macOS).
  bool get available;

  /// The taskbar on the main screen, or null if it can't be read right now. Quick: read every few seconds.
  TaskbarReading? read();

  /// Where the taskbar's buttons are (UI Automation, off the UI thread), or null if they can't be found.
  Future<List<PixelRect>?> buttons();

  /// A full-screen app (a game, a video) or a presentation has the screen: the pet keeps out of the way.
  bool fullscreenBusy();

  /// The taskbar is the foreground window (it was just clicked, and rises over other always-on-top windows).
  bool taskbarInFront();

  /// The mouse pointer (physical pixels), or null.
  (int, int)? cursor();
}

/// Win32 on Windows, nothing elsewhere.
TaskbarInfo systemTaskbar() => Platform.isWindows ? Win32TaskbarInfo() : const NoTaskbar();

/// The pet's native window, placed in physical pixels without ever taking the focus.
abstract interface class PetWindow {
  /// Moves the window, keeping its size: cheap enough for every step of a walk.
  void move(int left, int top);

  /// Moves and resizes the window; completes once it has the new size.
  Future<void> setFrame(PixelRect frame);

  /// Where the window is now (null if it can't be read).
  PixelRect? frame();

  /// Back on top of the always-on-top windows (the taskbar rises over Mochi when it's clicked), without the focus.
  void raise();

  /// Clicks go through the window to whatever is under it (the taskbar), or not.
  void setClickThrough(bool through);

  /// Back to an ordinary window (off the taskbar): takes clicks, not layered.
  void settle();
}

/// No taskbar (the macOS development build): the pet stays still where it was left.
class NoTaskbar implements TaskbarInfo {
  const NoTaskbar();

  @override
  bool get available => false;

  @override
  TaskbarReading? read() => null;

  @override
  Future<List<PixelRect>?> buttons() async => null;

  @override
  bool fullscreenBusy() => false;

  @override
  bool taskbarInFront() => false;

  @override
  (int, int)? cursor() => null;
}

/// Why Mochi isn't strolling along the taskbar.
enum RoamBlock {
  /// "Roam along the taskbar" is off (or Mochi was dragged off it).
  turnedOff,

  /// No Windows taskbar here (the macOS development build).
  unsupported,

  /// Windows didn't say where the taskbar is.
  unreadable,

  /// The taskbar is at the top or a side of the screen.
  notAtBottom,

  /// The taskbar hides itself until the pointer reaches it.
  autoHides,

  /// The taskbar's buttons fill it: no free stretch to walk in.
  crowded;

  /// What Settings says about it.
  String get note => switch (this) {
    turnedOff => 'Mochi stays where you put it.',
    unsupported => 'Mochi roams the taskbar on Windows. Here it stays where you put it.',
    unreadable => 'Mochi can’t find the taskbar right now, so it stays where you put it.',
    notAtBottom => 'Mochi only roams a taskbar at the bottom of the screen, so it stays where you put it for now.',
    autoHides => 'The taskbar hides itself, so Mochi stays where you put it. Turn off “Automatically hide the taskbar” to let it roam.',
    crowded => 'The taskbar has no free room between its buttons, so Mochi stays where you put it for now.',
  };
}

/// A stretch of the taskbar Mochi's centre may walk along (logical pixels).
typedef TaskbarZone = ({double minX, double maxX});

/// Where the taskbar's buttons are and where the free room is.
abstract final class TaskbarZones {
  /// The widgets tile's width (logical pixels) when the buttons are found by estimate.
  static const double widgetsWidth = 160;

  /// The tray's width (logical pixels) when it has no window of its own.
  static const double trayWidth = 280;

  /// The share of the taskbar the centred buttons are assumed to fill, when they can't be found.
  static const double centredBand = 0.55;
  static const double leftBand = 0.5;

  /// The free stretches of [bar] around [occupied] (the buttons, the tray), as ranges for the centre of a Mochi
  /// [mochiWidth] logical pixels wide that stays [padding] away from every button and [edge] away from the screen's
  /// sides (so its speech bubble fits on screen), and only stretches with at least [minRoom] to walk.
  static List<TaskbarZone> free({
    required PixelRect bar,
    required double scale,
    required List<PixelRect> occupied,
    required double mochiWidth,
    double padding = 8,
    double edge = 92,
    double minRoom = 36,
  }) {
    final spans =
        [
          for (final rect in occupied)
            if (!rect.isEmpty && rect.right > bar.left && rect.left < bar.right && rect.bottom > bar.top && rect.top < bar.bottom)
              (math.max(rect.left, bar.left), math.min(rect.right, bar.right)),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
    final zones = <TaskbarZone>[];
    // Mochi's centre stays [edge] from the screen's sides, and its box [padding] from every button.
    final lowest = bar.left / scale + edge;
    final highest = bar.right / scale - edge;
    void add(int start, int end) {
      final minX = math.max(lowest, start / scale + padding + mochiWidth / 2);
      final maxX = math.min(highest, end / scale - padding - mochiWidth / 2);
      if (maxX - minX >= minRoom) zones.add((minX: minX, maxX: maxX));
    }

    // The gaps between the occupied spans (overlapping ones merge as the cursor passes them).
    var cursor = bar.left;
    for (final (start, end) in spans) {
      if (start > cursor) add(cursor, start);
      cursor = math.max(cursor, end);
    }
    if (cursor < bar.right) add(cursor, bar.right);
    return zones;
  }

  /// Where the buttons probably are when UI Automation can't say: the tray (its window, or the right-hand
  /// [trayWidth]), the widgets tile, and a generous band for the buttons (centred, or from the left).
  static List<PixelRect> estimate(TaskbarReading reading) {
    final bar = reading.bounds;
    final scale = reading.scale;
    int px(double logical) => (logical * scale).round();
    final tray = reading.tray != null && reading.tray!.overlaps(bar)
        ? reading.tray!
        : PixelRect(bar.right - px(trayWidth), bar.top, bar.right, bar.bottom);
    final occupied = <PixelRect>[tray];
    if (reading.centred) {
      final half = (bar.width * centredBand / 2).round();
      final centre = bar.left + bar.width ~/ 2;
      occupied.add(PixelRect(centre - half, bar.top, centre + half, bar.bottom));
      if (reading.widgets) occupied.add(PixelRect(bar.left, bar.top, bar.left + px(widgetsWidth), bar.bottom));
    } else {
      occupied.add(PixelRect(bar.left, bar.top, bar.left + (bar.width * leftBand).round(), bar.bottom));
      // Left-aligned, the widgets tile sits just before the tray.
      if (reading.widgets) occupied.add(PixelRect(tray.left - px(widgetsWidth), bar.top, tray.left, bar.bottom));
    }
    return occupied;
  }

  /// The buttons UI Automation reported that matter: inside [bar], not the taskbar itself or a container spanning
  /// most of it.
  static List<PixelRect> buttonsIn(PixelRect bar, Iterable<PixelRect> elements) => [
    for (final rect in elements)
      if (!rect.isEmpty && rect.overlaps(bar) && rect.width < bar.width * 0.5 && rect.height >= bar.height * 0.3) rect,
  ];
}

/// The taskbar as a stage for Mochi: its free stretches, and where the pet's window goes for a spot in them — Mochi's
/// box inside the taskbar, vertically centred (like the Mac's menu-bar Mochi), growing upwards for a speech bubble.
@immutable
class TaskbarStage {
  const TaskbarStage({required this.bar, required this.scale, required this.zones, this.measured = false});

  /// The taskbar (physical pixels).
  final PixelRect bar;

  /// Physical pixels per logical pixel.
  final double scale;

  /// Where Mochi's centre may walk (logical pixels), left to right.
  final List<TaskbarZone> zones;

  /// The zones come from UI Automation (rather than an estimate).
  final bool measured;

  /// Mochi's box (logical): a little shorter than the taskbar, so Mochi sits inside it with its feet near the
  /// bottom (40 tall on a standard 48-pixel taskbar).
  Size get box {
    final height = (bar.height / scale - 8).clamp(24.0, 48.0);
    return Size((height * 1.6).roundToDouble(), height.roundToDouble());
  }

  /// The stage for [reading], with the buttons UI Automation found ([buttons]; null: estimate them), or why there's
  /// none.
  static ({TaskbarStage? stage, RoamBlock? block}) of(TaskbarReading? reading, {List<PixelRect>? buttons}) {
    if (reading == null || reading.bounds.isEmpty || reading.monitor.isEmpty || !(reading.scale > 0)) {
      return (stage: null, block: RoamBlock.unreadable);
    }
    if (reading.edge != TaskbarEdge.bottom) return (stage: null, block: RoamBlock.notAtBottom);
    if (reading.autoHide) return (stage: null, block: RoamBlock.autoHides);
    final bar = reading.bounds;
    final measured = buttons != null && buttons.isNotEmpty;
    final occupied = measured
        ? [...TaskbarZones.buttonsIn(bar, buttons), if (reading.tray != null) reading.tray!]
        : TaskbarZones.estimate(reading);
    final shape = TaskbarStage(bar: bar, scale: reading.scale, zones: const []);
    final zones = TaskbarZones.free(bar: bar, scale: reading.scale, occupied: occupied, mochiWidth: shape.box.width);
    if (zones.isEmpty) return (stage: null, block: RoamBlock.crowded);
    return (stage: TaskbarStage(bar: bar, scale: reading.scale, zones: zones, measured: measured), block: null);
  }

  /// The bottom of Mochi's box (physical pixels): its window grows upwards from here.
  int get boxBottom {
    final height = (box.height * scale).round();
    return bar.top + ((bar.height - height) / 2).round() + height;
  }

  /// The window of [size] (logical: Mochi's [box], or wider and taller with a bubble above) with Mochi's centre at [x].
  PixelRect frame(double x, Size size) {
    final width = (size.width * scale).round();
    final height = (size.height * scale).round();
    return PixelRect.ltwh((x * scale - width / 2).round(), boxBottom - height, width, height);
  }

  /// Mochi's body in a window at [frame]: the part that takes clicks (the rest lets them through to the taskbar).
  PixelRect body(PixelRect frame) {
    final height = (box.height * scale).round();
    final width = (box.height * 0.95 * scale).round();
    final centre = frame.left + frame.width ~/ 2;
    return PixelRect(centre - width ~/ 2, frame.bottom - height, centre + width ~/ 2, frame.bottom);
  }

  /// [frame]'s top-left in logical pixels (window_manager's coordinates on this screen).
  Offset logical(PixelRect frame) => Offset(frame.left / scale, frame.top / scale);

  @override
  bool operator ==(Object other) =>
      other is TaskbarStage &&
      other.bar == bar &&
      other.scale == scale &&
      other.measured == measured &&
      listEquals(other.zones, zones);

  @override
  int get hashCode => Object.hash(bar, scale, measured, Object.hashAll(zones));

  @override
  String toString() => 'TaskbarStage($bar ×$scale, zones: $zones${measured ? '' : ', estimated'})';
}
