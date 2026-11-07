// The PC's displays, for the desktop pet's place on each (docs/SPRINT_2.md W7; the Mac's DesktopPetController keeps
// its position per screen): EnumDisplayMonitors and GetMonitorInfo (each display's device name, rectangle and work
// area, physical pixels) and GetDpiForMonitor (its scale). Nothing elsewhere: the macOS development build places the pet
// through window_manager, as before.

import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import '../core/desktop_settings.dart' show PetPlace;
import 'taskbar.dart' show PixelRect;

/// One display.
@immutable
class DisplayArea {
  const DisplayArea({required this.key, required this.monitor, required this.workArea, required this.scale, this.primary = false});

  /// Which display it is: its device name and size ("\\.\DISPLAY2 2560x1440"), so a place is kept for each display,
  /// and a display that changes resolution counts as another.
  final String key;

  /// The whole display, and the part windows get (without the taskbar), in physical pixels.
  final PixelRect monitor;
  final PixelRect workArea;

  /// Its display scale: 1 at 100%, 1.5 at 150%.
  final double scale;

  /// The main display (the one with the Start menu's taskbar).
  final bool primary;

  @override
  bool operator ==(Object other) =>
      other is DisplayArea &&
      other.key == key &&
      other.monitor == monitor &&
      other.workArea == workArea &&
      other.scale == scale &&
      other.primary == primary;

  @override
  int get hashCode => Object.hash(key, monitor, workArea, scale, primary);

  @override
  String toString() => 'DisplayArea($key, $workArea, ×$scale${primary ? ', primary' : ''})';
}

abstract interface class Displays {
  /// Every display now (empty where they can't be read).
  List<DisplayArea> list();
}

class NoDisplays implements Displays {
  const NoDisplays();

  @override
  List<DisplayArea> list() => const [];
}

Displays systemDisplays() => Platform.isWindows ? Win32Displays() : const NoDisplays();

/// Where the desktop pet goes, and where it was left, on the displays there are.
abstract final class PetPlacing {
  /// The display a window at [frame] is on: the one its centre is on, else the one it overlaps most, else the main one.
  static DisplayArea? displayOf(List<DisplayArea> displays, PixelRect frame) {
    if (displays.isEmpty) return null;
    final cx = frame.left + frame.width ~/ 2, cy = frame.top + frame.height ~/ 2;
    for (final display in displays) {
      if (display.monitor.contains(cx, cy)) return display;
    }
    int overlap(DisplayArea display) {
      final m = display.monitor;
      final w = math.min(m.right, frame.right) - math.max(m.left, frame.left);
      final h = math.min(m.bottom, frame.bottom) - math.max(m.top, frame.top);
      return w > 0 && h > 0 ? (w * h).toInt() : 0;
    }

    final best = displays.reduce((a, b) => overlap(b) > overlap(a) ? b : a);
    return overlap(best) > 0 ? best : primaryOf(displays);
  }

  static DisplayArea primaryOf(List<DisplayArea> displays) => displays.firstWhere((d) => d.primary, orElse: () => displays.first);

  /// How much of the window ([size], physical) must stay inside the work area: all of it across, and the pet's own box
  /// ([box] tall, at the bottom) down; the room for a bubble above it may go past the top.
  static PixelRect _room(DisplayArea display, (int, int) size, int box) {
    final work = display.workArea;
    return PixelRect(work.left, work.top - (size.$2 - box), math.max(work.left, work.right - size.$1), math.max(work.top, work.bottom - size.$2));
  }

  /// The place [frame] is at on [display].
  static PetPlace placeOf(DisplayArea display, PixelRect frame, {required int box}) {
    final room = _room(display, (frame.width, frame.height), box);
    double share(int value, int from, int to) => to <= from ? 0 : ((value - from) / (to - from)).clamp(0, 1).toDouble();
    return PetPlace(share(frame.left, room.left, room.right), share(frame.top, room.top, room.bottom));
  }

  /// The frame for the desktop pet [size] (logical) big, with its box [box] (logical) tall: on the display it was last
  /// left on if it's there (else the main one), at its place there; else (never placed on any display yet) where
  /// [legacy] (the old single position, logical, on the main display) says; else at the bottom left, just above the
  /// taskbar.
  static ({DisplayArea display, PixelRect frame}) frameFor(
    List<DisplayArea> displays, {
    required Map<String, PetPlace> places,
    required String? last,
    required Size size,
    required double box,
    Offset? legacy,
  }) {
    final display = displays.where((d) => d.key == last).firstOrNull ?? primaryOf(displays);
    final width = (size.width * display.scale).round(), height = (size.height * display.scale).round();
    final boxHeight = (box * display.scale).round();
    final room = _room(display, (width, height), boxHeight);
    final place = places[display.key];
    int at(double share, int from, int to) => (from + (to - from) * share).round();
    var left = room.left, top = room.bottom;
    if (place != null) {
      left = at(place.x, room.left, room.right);
      top = at(place.y, room.top, room.bottom);
    } else if (legacy != null && display.primary && places.isEmpty) {
      left = (legacy.dx * display.scale).round().clamp(room.left, room.right).toInt();
      top = (legacy.dy * display.scale).round().clamp(room.top, room.bottom).toInt();
    }
    return (display: display, frame: PixelRect.ltwh(left, top, width, height));
  }
}

/// The displays through Win32.
class Win32Displays implements Displays {
  static final List<DisplayArea> _found = [];
  static final Pointer<NativeFunction<MONITORENUMPROC>> _visit = Pointer.fromFunction<MONITORENUMPROC>(_monitor, 0);

  @override
  List<DisplayArea> list() {
    _found.clear();
    try {
      EnumDisplayMonitors(NULL, nullptr, _visit, 0);
      return List.of(_found);
    } on Object {
      return const [];
    } finally {
      _found.clear();
    }
  }

  static int _monitor(int monitor, int dc, Pointer rect, int data) {
    final info = calloc<MONITORINFOEX>();
    final dpiX = calloc<Uint32>();
    final dpiY = calloc<Uint32>();
    try {
      info.ref.monitorInfo.cbSize = sizeOf<MONITORINFOEX>();
      if (GetMonitorInfo(monitor, info.cast()) == 0) return 1;
      final m = info.ref.monitorInfo.rcMonitor, w = info.ref.monitorInfo.rcWork;
      final scale = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, dpiX, dpiY) == S_OK && dpiX.value > 0 ? dpiX.value / 96 : 1.0;
      final whole = PixelRect(m.left, m.top, m.right, m.bottom);
      _found.add(
        DisplayArea(
          key: '${info.ref.szDevice} ${whole.width}x${whole.height}',
          monitor: whole,
          workArea: PixelRect(w.left, w.top, w.right, w.bottom),
          scale: scale,
          primary: info.ref.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0,
        ),
      );
    } finally {
      calloc.free(info);
      calloc.free(dpiX);
      calloc.free(dpiY);
    }
    return 1;
  }
}
