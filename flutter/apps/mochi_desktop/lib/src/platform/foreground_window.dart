// The window you're using, for Peekaboo (docs/SPRINT_2.md X3): Mochi's actor sits just below it in the window stack, so
// it hides behind it and peeks out from behind its edges. Only its handle and what kind of window it is are read:
// GetForegroundWindow, then (for the kind) GetWindowThreadProcessId against GetCurrentProcessId (Mochi's own windows)
// and one GetClassName compared against the shell's four classes (Progman and WorkerW: the desktop; Shell_TrayWnd and
// Shell_SecondaryTrayWnd: the taskbars), never kept. Titles, other class names and contents are never read, and
// nothing is ever moved, raised or focused.
//
// The macOS development build has none ([NoForegroundWindow]); tests use a fake (test/support/fakes.dart).

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// What kind of window has the focus.
enum ForegroundKind {
  /// An app's window: Mochi hides behind it.
  app,

  /// One of Mochi's own windows (the pet's, the popover, Settings).
  ours,

  /// The desktop or the taskbar, or no window at all.
  shell,
}

/// The window with the focus.
@immutable
class ForegroundWindow {
  const ForegroundWindow(this.hwnd, this.kind);

  final int hwnd;
  final ForegroundKind kind;

  @override
  bool operator ==(Object other) => other is ForegroundWindow && other.hwnd == hwnd && other.kind == kind;

  @override
  int get hashCode => Object.hash(hwnd, kind);

  @override
  String toString() => 'ForegroundWindow($hwnd, ${kind.name})';
}

abstract interface class ForegroundWindows {
  /// The window with the focus now, or null where it can't be read.
  ForegroundWindow? read();
}

class NoForegroundWindow implements ForegroundWindows {
  const NoForegroundWindow();

  @override
  ForegroundWindow? read() => null;
}

ForegroundWindows systemForegroundWindow() => Platform.isWindows ? Win32ForegroundWindow() : const NoForegroundWindow();

/// The foreground window through Win32.
class Win32ForegroundWindow implements ForegroundWindows {
  /// The shell's own windows.
  static const Set<String> _shell = {'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd'};

  @override
  ForegroundWindow? read() {
    final pid = calloc<Uint32>();
    final name = calloc<Uint16>(40);
    try {
      final hwnd = GetForegroundWindow();
      if (hwnd == 0) return const ForegroundWindow(0, ForegroundKind.shell);
      GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == GetCurrentProcessId()) return ForegroundWindow(hwnd, ForegroundKind.ours);
      final length = GetClassName(hwnd, name.cast<Utf16>(), 40);
      if (length > 0 && _shell.contains(name.cast<Utf16>().toDartString())) return ForegroundWindow(hwnd, ForegroundKind.shell);
      return ForegroundWindow(hwnd, ForegroundKind.app);
    } on Object {
      return null;
    } finally {
      calloc.free(pid);
      calloc.free(name);
    }
  }
}
