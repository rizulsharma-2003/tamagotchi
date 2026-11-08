// Where other apps' windows are, for Mochi's desktop adventures (docs/SPRINT_2.md W19, X1): only rectangles, never what
// a window is called or shows.
//
// - The windows on screen, front to back: EnumWindows (which walks the top-level windows in z-order) keeps those that are
//   IsWindowVisible, not IsIconic (minimised), not cloaked (DwmGetWindowAttribute(DWMWA_CLOAKED): another virtual
//   desktop, a suspended store app), not WS_EX_TOOLWINDOW (palettes, tooltips), not Mochi's own (GetWindowThreadProcessId
//   against GetCurrentProcessId: the pet's window, its popover and the stage's actors) and not the shell's (the
//   desktop's Progman and WorkerW, the taskbars Shell_TrayWnd and Shell_SecondaryTrayWnd: the one class-name read, and
//   only compared against those four, never kept).
// - Each one's rectangle is DWMWA_EXTENDED_FRAME_BOUNDS: where the window is drawn, without the invisible resize border
//   Windows 10 and 11 put around it (GetWindowRect includes it), in physical pixels; and whether it's maximised
//   (IsZoomed).
// - [WindowFrames.frame] reads one window the same way (X1 follows the window Mochi stands on every frame): null when it
//   is gone, minimised, cloaked or no longer visible.
// - Nothing is ever moved, raised or focused. Titles, class names of apps' windows and contents are never read.
//
// The macOS development build has none ([NoWindowFrames]); tests use a fake (test/support/fakes.dart).

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import 'taskbar.dart' show PixelRect;

/// One window's frame.
@immutable
class WindowFrame {
  const WindowFrame({required this.hwnd, required this.frame, this.zoomed = false});

  /// Its handle (only for asking about it again: [WindowFrames.frame]).
  final int hwnd;

  /// Where it is drawn, in physical pixels.
  final PixelRect frame;

  /// It is maximised.
  final bool zoomed;

  @override
  bool operator ==(Object other) => other is WindowFrame && other.hwnd == hwnd && other.frame == frame && other.zoomed == zoomed;

  @override
  int get hashCode => Object.hash(hwnd, frame, zoomed);

  @override
  String toString() => 'WindowFrame($hwnd, $frame${zoomed ? ', maximised' : ''})';
}

abstract interface class WindowFrames {
  /// The windows on screen now, front to back (empty where they can't be read).
  List<WindowFrame> list();

  /// One window's frame now, or null when it is gone, minimised, cloaked or hidden.
  WindowFrame? frame(int hwnd);
}

class NoWindowFrames implements WindowFrames {
  const NoWindowFrames();

  @override
  List<WindowFrame> list() => const [];

  @override
  WindowFrame? frame(int hwnd) => null;
}

WindowFrames systemWindowFrames() => Platform.isWindows ? Win32WindowFrames() : const NoWindowFrames();

/// The windows through Win32.
class Win32WindowFrames implements WindowFrames {
  /// The shell's own windows: not ground to walk on.
  static const Set<String> _shell = {'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd'};

  static final Pointer<NativeFunction<WNDENUMPROC>> _visit = Pointer.fromFunction<WNDENUMPROC>(_enumerate, 0);

  // The walk's scratch space and result, for the callback (which can't capture anything).
  static final List<WindowFrame> _found = [];
  static Pointer<Int32>? _int;
  static Pointer<RECT>? _rect;
  static Pointer<Uint32>? _pid;
  static Pointer<Uint16>? _name;
  static int _self = 0;

  @override
  List<WindowFrame> list() {
    _found.clear();
    _open();
    try {
      EnumWindows(_visit, 0);
      return List.of(_found);
    } on Object {
      return const [];
    } finally {
      _close();
      _found.clear();
    }
  }

  @override
  WindowFrame? frame(int hwnd) {
    if (hwnd == 0) return null;
    _open();
    try {
      if (IsWindow(hwnd) == 0) return null;
      return _read(hwnd, shellCheck: false);
    } on Object {
      return null;
    } finally {
      _close();
    }
  }

  static void _open() {
    _int = calloc<Int32>();
    _rect = calloc<RECT>();
    _pid = calloc<Uint32>();
    _name = calloc<Uint16>(40);
    _self = GetCurrentProcessId();
  }

  static void _close() {
    for (final pointer in [_int, _rect, _pid, _name]) {
      if (pointer != null) calloc.free(pointer);
    }
    _int = null;
    _rect = null;
    _pid = null;
    _name = null;
  }

  static int _enumerate(int hwnd, int _) {
    final window = _read(hwnd, shellCheck: true);
    if (window != null) _found.add(window);
    return 1;
  }

  /// [hwnd]'s frame if it's a window to walk on (the shell's are left out when [shellCheck]).
  static WindowFrame? _read(int hwnd, {required bool shellCheck}) {
    final flag = _int!, rect = _rect!, pid = _pid!;
    if (IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0) return null;
    if (GetWindowLongPtr(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW != 0) return null;
    if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, flag, sizeOf<Int32>()) == S_OK && flag.value != 0) return null;
    if (shellCheck) {
      GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == _self) return null;
      final length = GetClassName(hwnd, _name!.cast<Utf16>(), 40);
      if (length > 0 && _shell.contains(_name!.cast<Utf16>().toDartString())) return null;
    }
    if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, rect, sizeOf<RECT>()) != S_OK) return null;
    final r = rect.ref;
    if (r.right <= r.left || r.bottom <= r.top) return null;
    return WindowFrame(hwnd: hwnd, frame: PixelRect(r.left, r.top, r.right, r.bottom), zoomed: IsZoomed(hwnd) != 0);
  }
}
