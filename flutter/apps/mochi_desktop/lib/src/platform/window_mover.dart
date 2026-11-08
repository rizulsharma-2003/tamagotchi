// What Window nudges (docs/SPRINT_2.md X2, core/window_nudge.dart) asks of Windows, through dart:ffi. Moving other apps'
// windows is the most delicate thing Mochi does, so this file is small and says exactly what it calls:
//
// - Reading a window to see whether it may be nudged ([Win32WindowMover.info]), only when a nudge is about to start:
//   IsWindow, IsWindowVisible, IsIconic, IsZoomed, DwmGetWindowAttribute (DWMWA_CLOAKED, and
//   DWMWA_EXTENDED_FRAME_BOUNDS for the visible frame), GetWindowThreadProcessId against GetCurrentProcessId (Mochi's own
//   windows), GetClassName compared against the shell's four classes and never kept, GetWindowLongPtr (GWL_STYLE:
//   WS_CHILD, WS_CAPTION; GWL_EXSTYLE: WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_NOACTIVATE), GetWindow (GW_OWNER),
//   IsWindowArranged (looked up in user32.dll at run time: older Windows 10 has none), GetWindowRect, MonitorFromWindow
//   with GetMonitorInfo (the monitor and its work area), IsHungAppWindow and GetGUIThreadInfo (GUI_INMOVESIZE). Titles,
//   other class names and contents are never read.
// - Before each step: GetWindowRect ([rect]), and GetForegroundWindow and GetAsyncKeyState (the three mouse buttons).
// - The move: SetWindowPos with SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS: the
//   window's place changes and nothing else (not its size, its z-order or the focus). Asynchronous, so a window that does
//   not answer can never stall Mochi.
// - The program's file name for the terminal tug ([processName], reacts_readers.dart's read of any window).
//
// The macOS development build has none ([NoWindowMover]); tests use a fake.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../core/window_nudge.dart';
import 'reacts_readers.dart' show windowProcessName;
import 'taskbar.dart' show PixelRect;

WindowMover systemWindowMover() => Platform.isWindows ? Win32WindowMover() : const NoWindowMover();

/// The windows through Win32.
class Win32WindowMover implements WindowMover {
  /// The shell's own windows: never moved.
  static const Set<String> _shell = {'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd'};

  /// `IsWindowArranged` (is the window snapped or arranged), or null where this Windows has no such call.
  static final int Function(int)? _arranged = _lookupArranged();

  static int Function(int)? _lookupArranged() {
    try {
      return DynamicLibrary.open('user32.dll').lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowArranged');
    } on Object {
      return null;
    }
  }

  @override
  WindowInfo? info(int hwnd) {
    if (hwnd == 0) return null;
    final flag = calloc<Int32>();
    final rect = calloc<RECT>();
    final pid = calloc<Uint32>();
    final name = calloc<Uint16>(40);
    final monitor = calloc<MONITORINFO>();
    final gui = calloc<GUITHREADINFO>();
    try {
      if (IsWindow(hwnd) == 0) return null;
      final thread = GetWindowThreadProcessId(hwnd, pid);
      final ours = pid.value == GetCurrentProcessId();
      final length = GetClassName(hwnd, name.cast<Utf16>(), 40);
      final shell = length > 0 && _shell.contains(name.cast<Utf16>().toDartString());
      final cloaked = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, flag, sizeOf<Int32>()) == S_OK && flag.value != 0;
      if (GetWindowRect(hwnd, rect) == 0) return null;
      final window = PixelRect(rect.ref.left, rect.ref.top, rect.ref.right, rect.ref.bottom);
      var frame = window;
      if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, rect, sizeOf<RECT>()) == S_OK) {
        frame = PixelRect(rect.ref.left, rect.ref.top, rect.ref.right, rect.ref.bottom);
      }
      var bounds = frame, work = frame;
      monitor.ref.cbSize = sizeOf<MONITORINFO>();
      final handle = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      if (handle != 0 && GetMonitorInfo(handle, monitor) != 0) {
        final m = monitor.ref;
        bounds = PixelRect(m.rcMonitor.left, m.rcMonitor.top, m.rcMonitor.right, m.rcMonitor.bottom);
        work = PixelRect(m.rcWork.left, m.rcWork.top, m.rcWork.right, m.rcWork.bottom);
      }
      gui.ref.cbSize = sizeOf<GUITHREADINFO>();
      final moving = GetGUIThreadInfo(thread, gui) != 0 && (gui.ref.flags & GUI_INMOVESIZE) != 0;
      final style = GetWindowLongPtr(hwnd, GWL_STYLE);
      final exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
      final arranged = _arranged;
      return WindowInfo(
        hwnd: hwnd,
        rect: window,
        frame: frame,
        monitor: bounds,
        work: work,
        visible: IsWindowVisible(hwnd) != 0,
        iconic: IsIconic(hwnd) != 0,
        zoomed: IsZoomed(hwnd) != 0,
        cloaked: cloaked,
        ours: ours,
        shell: shell,
        child: style & WS_CHILD != 0,
        // WS_CAPTION is WS_BORDER | WS_DLGFRAME: both bits are a title bar.
        caption: style & WS_CAPTION == WS_CAPTION,
        toolWindow: exStyle & WS_EX_TOOLWINDOW != 0,
        topmost: exStyle & WS_EX_TOPMOST != 0,
        noActivate: exStyle & WS_EX_NOACTIVATE != 0,
        owned: GetWindow(hwnd, GW_OWNER) != 0,
        arranged: arranged == null ? null : arranged(hwnd) != 0,
        hung: IsHungAppWindow(hwnd) != 0,
        moving: moving,
      );
    } on Object {
      return null;
    } finally {
      calloc.free(flag);
      calloc.free(rect);
      calloc.free(pid);
      calloc.free(name);
      calloc.free(monitor);
      calloc.free(gui);
    }
  }

  @override
  PixelRect? rect(int hwnd) {
    if (hwnd == 0) return null;
    final rect = calloc<RECT>();
    try {
      if (IsWindow(hwnd) == 0 || GetWindowRect(hwnd, rect) == 0) return null;
      return PixelRect(rect.ref.left, rect.ref.top, rect.ref.right, rect.ref.bottom);
    } on Object {
      return null;
    } finally {
      calloc.free(rect);
    }
  }

  @override
  bool move(int hwnd, int x, int y) {
    try {
      return SetWindowPos(hwnd, 0, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS) != 0;
    } on Object {
      return false;
    }
  }

  @override
  int? pid(int hwnd) {
    if (hwnd == 0) return null;
    final pid = calloc<Uint32>();
    try {
      if (IsWindow(hwnd) == 0) return null;
      GetWindowThreadProcessId(hwnd, pid);
      return pid.value == 0 ? null : pid.value;
    } on Object {
      return null;
    } finally {
      calloc.free(pid);
    }
  }

  @override
  int foreground() {
    try {
      return GetForegroundWindow();
    } on Object {
      return 0;
    }
  }

  @override
  bool mouseDown() {
    try {
      for (final button in const [VK_LBUTTON, VK_RBUTTON, VK_MBUTTON]) {
        if (GetAsyncKeyState(button) & 0x8000 != 0) return true;
      }
      return false;
    } on Object {
      // Can't tell: assume it is, so nothing moves.
      return true;
    }
  }

  @override
  String? processName(int hwnd) => windowProcessName(hwnd);
}
