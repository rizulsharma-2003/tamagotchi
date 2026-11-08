// A fake WindowMover for the window nudges (X2): windows with a rect and the flags the rules read, every SetWindowPos it was
// asked for, and the ways Windows misbehaves (a refusing window, moves that land late or never).

import 'package:mochi_desktop/src/core/window_nudge.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect;

class FakeWin {
  FakeWin(this.rect, {this.pid = 100, this.process = 'notepad.exe'});

  PixelRect rect;
  int pid;
  String? process;
  bool visible = true, iconic = false, zoomed = false, cloaked = false, ours = false, shell = false;
  bool child = false, caption = true, toolWindow = false, topmost = false, noActivate = false, owned = false;
  bool? arranged = false;
  bool hung = false, moving = false;
}

class FakeMover implements WindowMover {
  FakeMover([Map<int, FakeWin>? windows]) : windows = windows ?? {};

  final Map<int, FakeWin> windows;
  PixelRect monitor = const PixelRect(0, 0, 1920, 1080);
  PixelRect work = const PixelRect(0, 0, 1920, 1032);
  int foregroundHwnd = 0;
  bool mouse = false;

  /// Windows that refuse SetWindowPos, and how many more calls succeed before every call is refused (null: no limit).
  final Set<int> refuse = {};
  int? succeedFor;

  /// Moves wait until [land] (the async flag) instead of landing at once; [lose] drops them (a window that never obeys).
  bool deferred = false;
  bool lose = false;
  final List<(int, int, int)> pending = [];

  /// Every successful call, every call, and what the journal said at each (set by tests).
  final List<(int, int, int)> moves = [];
  final List<(int, int, int)> attempts = [];
  void Function(int hwnd, int x, int y)? onMove;

  /// Told when a window actually changes place (the stage tests keep the frames in step).
  void Function(int hwnd, int dx, int dy)? moved;

  List<(int, int)> movesOf(int hwnd) => [
    for (final (h, x, y) in moves)
      if (h == hwnd) (x, y),
  ];

  /// The moves queued by [deferred] land.
  void land() {
    for (final (h, x, y) in List.of(pending)) {
      _place(h, x, y);
    }
    pending.clear();
  }

  void _place(int hwnd, int x, int y) {
    final win = windows[hwnd];
    if (win == null) return;
    final dx = x - win.rect.left, dy = y - win.rect.top;
    win.rect = win.rect.shifted(dx, dy);
    moved?.call(hwnd, dx, dy);
  }

  @override
  WindowInfo? info(int hwnd) {
    final w = windows[hwnd];
    if (w == null) return null;
    return WindowInfo(
      hwnd: hwnd,
      rect: w.rect,
      frame: w.rect,
      monitor: monitor,
      work: work,
      visible: w.visible,
      iconic: w.iconic,
      zoomed: w.zoomed,
      cloaked: w.cloaked,
      ours: w.ours,
      shell: w.shell,
      child: w.child,
      caption: w.caption,
      toolWindow: w.toolWindow,
      topmost: w.topmost,
      noActivate: w.noActivate,
      owned: w.owned,
      arranged: w.arranged,
      hung: w.hung,
      moving: w.moving,
    );
  }

  @override
  PixelRect? rect(int hwnd) => windows[hwnd]?.rect;

  @override
  bool move(int hwnd, int x, int y) {
    attempts.add((hwnd, x, y));
    if (!windows.containsKey(hwnd) || refuse.contains(hwnd)) return false;
    final left = succeedFor;
    if (left != null) {
      if (left <= 0) return false;
      succeedFor = left - 1;
    }
    onMove?.call(hwnd, x, y);
    moves.add((hwnd, x, y));
    if (lose) return true;
    if (deferred) {
      pending.add((hwnd, x, y));
    } else {
      _place(hwnd, x, y);
    }
    return true;
  }

  @override
  int? pid(int hwnd) => windows[hwnd]?.pid;

  @override
  int foreground() => foregroundHwnd;

  @override
  bool mouseDown() => mouse;

  @override
  String? processName(int hwnd) => windows[hwnd]?.process;
}
