// Window nudges (docs/SPRINT_2.md X2, Mischief): the one extra that moves OTHER apps' windows, so it is small, rare and
// always undone. This file is the whole of the "put-back contract", with no Windows in it ([WindowMover] is the adapter;
// platform/window_mover.dart is the Win32 one, tests use a fake):
//
// - Which windows may be moved at all ([NudgeRules.why]): ordinary, visible, captioned top-level windows that are not
//   the one you are using, not snapped, maximised, full-screen, hung or being dragged, with no mouse button held. Read
//   only at the moment a nudge is about to start. Never anything about a window's title, class or contents.
// - The three motions ([NudgeMotion]): a wobble (3 px down, back, 1 px down, back), a shove (8 px the way Mochi
//   faces, held, back) and a tug (±6 px three times). Every one ends exactly at home.
// - [WindowNudger] runs one nudge at a time:
//   * `home` is the window's rect at the start (GetWindowRect space, physical pixels), `placed` the last position it set.
//   * Before every step, the last one included, the rect is read. If it is somewhere this nudge never put it (not home,
//     not any position it sent, or another size) somebody else moved or resized the window: the nudge stops at once,
//     puts nothing back and never touches that window again.
//   * The moves are asynchronous (SWP_ASYNCWINDOWPOS): Windows posts them to the window's own thread, which applies them
//     in order, so a busy window can lag behind. A window at one of the nudge's own earlier positions is lagging, not
//     moved by you: the nudge waits for it, and after [WindowNudger.lagLimit] sends it home (queued after the rest, so
//     it ends at home).
//   * Once any move has been sent, every ending sends a move to exactly `home` (the last in the window's queue), even
//     when the window still reads at home (the earlier moves may not have landed yet); about 100 ms later the rect is
//     read back: still at one of the nudge's positions, it is moved home once more; somewhere else, it is left.
//   * A `SetWindowPos` that fails (a window of a higher integrity level) ends the nudge; that window is skipped for the
//     rest of the session.
//   * Abort paths go home at once (one move, if the rect is still at `placed`): a mouse button goes down, the window
//     becomes the foreground, the gate closes, the extra or Mischief is turned off, the adventure ends, the app quits
//     ([putBack]) and Windows' session ends.
//   * The journal (`nudge.json`: hwnd, pid, home, placed) is written before the first move, updated before each move
//     and deleted once the window is home (or the nudge ended without moving it). At launch, and before any new nudge,
//     a window that is still at `placed` (same pid) is moved to `home` ([recover]).
// - One line per nudge to the stroll-debug log: "nudge: wobble|shove|tug, home ok|left (moved by you)|failed".

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../platform/taskbar.dart' show PixelRect;
import 'json_store.dart';

/// The three motions.
enum NudgeKind {
  /// Mochi lands on the window: it dips and springs back.
  wobble,

  /// Mochi shoves the window the way it faces.
  shove,

  /// Claude needs you: the terminal or editor shakes a little.
  tug,
}

/// A development switch, `MOCHI_DESKTOP_NUDGE=wobble|shove|tug`: that motion happens at every qualifying moment (the gate
/// and the window rules still apply).
enum NudgeForce {
  wobble,
  shove,
  tug;

  static NudgeForce? from(String? value) {
    final name = (value ?? '').trim().toLowerCase();
    for (final force in values) {
      if (force.name == name) return force;
    }
    return null;
  }
}

/// How one motion moves a window, in offsets from home (physical pixels).
class NudgeMotion {
  NudgeMotion._(this.kind, this.duration, this._at);

  /// Down [3] logical px, back, down 1, back, over 350 ms.
  factory NudgeMotion.wobble({double scale = 1}) {
    const keys = <(double, double)>[(0, 0), (0.09, 3), (0.18, 0), (0.24, 1), (0.30, 0), (0.35, 0)];
    return NudgeMotion._(NudgeKind.wobble, 0.35, (t) => (0, (_keyed(keys, t) * scale).round()));
  }

  /// 8 logical px the way Mochi faces ([facing]: 1 right, -1 left) over 200 ms, held 1.2 s, back over 200 ms.
  factory NudgeMotion.shove({double scale = 1, double facing = 1}) {
    final side = facing >= 0 ? 1 : -1;
    const keys = <(double, double)>[(0, 0), (0.2, 8), (1.4, 8), (1.6, 0)];
    return NudgeMotion._(NudgeKind.shove, 1.6, (t) => ((_keyed(keys, t) * scale * side).round(), 0));
  }

  /// ±6 logical px left and right, three times, over 450 ms.
  factory NudgeMotion.tug({double scale = 1}) =>
      NudgeMotion._(NudgeKind.tug, 0.45, (t) => ((6 * scale * math.sin(2 * math.pi * 3 * t / 0.45)).round(), 0));

  final NudgeKind kind;

  /// Seconds; the last step (at or after this) is home.
  final double duration;
  final (int, int) Function(double) _at;

  /// The offset from home [t] seconds in; (0, 0) from [duration] on.
  (int, int) at(double t) => t >= duration || t <= 0 ? (0, 0) : _at(t);

  /// Eased linear interpolation through (seconds, value) keys.
  static double _keyed(List<(double, double)> keys, double t) {
    if (t <= keys.first.$1) return keys.first.$2;
    for (var i = 1; i < keys.length; i++) {
      final (t1, v1) = keys[i];
      if (t <= t1) {
        final (t0, v0) = keys[i - 1];
        final k = (t - t0) / (t1 - t0);
        final eased = k * k * (3 - 2 * k);
        return v0 + (v1 - v0) * eased;
      }
    }
    return keys.last.$2;
  }
}

/// What one read of a window says, for the rules below (the adapter fills it in; nothing here is a title or a class
/// name: [shell] is the one class comparison, made by the adapter against the shell's four classes).
@immutable
class WindowInfo {
  const WindowInfo({
    required this.hwnd,
    required this.rect,
    required this.frame,
    required this.monitor,
    required this.work,
    this.visible = true,
    this.iconic = false,
    this.zoomed = false,
    this.cloaked = false,
    this.ours = false,
    this.shell = false,
    this.child = false,
    this.caption = true,
    this.toolWindow = false,
    this.topmost = false,
    this.noActivate = false,
    this.owned = false,
    this.arranged,
    this.hung = false,
    this.moving = false,
  });

  final int hwnd;

  /// GetWindowRect (what SetWindowPos takes), and the visible frame (DWM's extended frame bounds), physical pixels.
  final PixelRect rect;
  final PixelRect frame;

  /// Its monitor, and that monitor's work area.
  final PixelRect monitor;
  final PixelRect work;

  final bool visible, iconic, zoomed, cloaked;

  /// One of Mochi's own windows, or the shell's (the desktop, the taskbars).
  final bool ours, shell;

  /// WS_CHILD; WS_CAPTION; WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_NOACTIVATE; it has an owner (a dialog).
  final bool child, caption, toolWindow, topmost, noActivate, owned;

  /// IsWindowArranged (snapped); null where Windows has no such call.
  final bool? arranged;

  /// IsHungAppWindow; its thread is in a move or size loop (GUI_INMOVESIZE).
  final bool hung, moving;
}

/// Why a window may not be nudged.
enum NudgeSkip {
  gone,
  hidden,
  minimised,
  maximised,
  cloaked,
  ours,
  shell,
  child,
  noCaption,
  toolWindow,
  topmost,
  noActivate,
  owned,
  arranged,
  fullHeight,
  fullScreen,
  hung,
  moving,
  mouse,
  foreground,
  wontMove,
}

abstract final class NudgeRules {
  /// Within this many pixels counts as spanning the work area's height.
  static const int heightSlack = 2;

  /// Why [info] (null: not a window) may not be nudged now, or null: it may.
  static NudgeSkip? why(WindowInfo? info, {required int foreground, required bool mouseDown, Set<int> wontMove = const {}}) {
    if (info == null) return NudgeSkip.gone;
    if (!info.visible) return NudgeSkip.hidden;
    if (info.iconic) return NudgeSkip.minimised;
    if (info.zoomed) return NudgeSkip.maximised;
    if (info.cloaked) return NudgeSkip.cloaked;
    if (info.ours) return NudgeSkip.ours;
    if (info.shell) return NudgeSkip.shell;
    if (info.child) return NudgeSkip.child;
    if (!info.caption) return NudgeSkip.noCaption;
    if (info.toolWindow) return NudgeSkip.toolWindow;
    if (info.topmost) return NudgeSkip.topmost;
    if (info.noActivate) return NudgeSkip.noActivate;
    if (info.owned) return NudgeSkip.owned;
    final arranged = info.arranged;
    if (arranged == true) return NudgeSkip.arranged;
    if (arranged == null) {
      // Older Windows 10 has no IsWindowArranged: a window as tall as the work area is taken to be snapped.
      if ((info.frame.top - info.work.top).abs() <= heightSlack && (info.frame.bottom - info.work.bottom).abs() <= heightSlack) {
        return NudgeSkip.fullHeight;
      }
    }
    final frame = info.frame, monitor = info.monitor;
    if (frame.left <= monitor.left && frame.top <= monitor.top && frame.right >= monitor.right && frame.bottom >= monitor.bottom) {
      return NudgeSkip.fullScreen;
    }
    if (info.hung) return NudgeSkip.hung;
    if (info.moving) return NudgeSkip.moving;
    if (mouseDown) return NudgeSkip.mouse;
    if (info.hwnd == foreground) return NudgeSkip.foreground;
    if (wontMove.contains(info.hwnd)) return NudgeSkip.wontMove;
    return null;
  }
}

/// The few things the nudges ask of Windows (platform/window_mover.dart is the Win32 version).
abstract interface class WindowMover {
  /// What [hwnd] is like now (null: not a window).
  WindowInfo? info(int hwnd);

  /// GetWindowRect now (null: gone).
  PixelRect? rect(int hwnd);

  /// SetWindowPos to ([x], [y]) with the same size, z-order and focus; false when Windows refused (the window never moved).
  bool move(int hwnd, int x, int y);

  /// The process id of [hwnd], or null when it isn't a window.
  int? pid(int hwnd);

  /// The foreground window's handle (0: none).
  int foreground();

  /// A mouse button is held down.
  bool mouseDown();

  /// [hwnd]'s process file name ("WindowsTerminal.exe"), or null.
  String? processName(int hwnd);
}

/// Where the nudges can't run (the macOS development build): nothing is a window.
class NoWindowMover implements WindowMover {
  const NoWindowMover();

  @override
  WindowInfo? info(int hwnd) => null;

  @override
  PixelRect? rect(int hwnd) => null;

  @override
  bool move(int hwnd, int x, int y) => false;

  @override
  int? pid(int hwnd) => null;

  @override
  int foreground() => 0;

  @override
  bool mouseDown() => false;

  @override
  String? processName(int hwnd) => null;
}

/// What a nudge in flight was doing, as the journal keeps it.
@immutable
class NudgeRecord {
  const NudgeRecord({required this.hwnd, required this.pid, required this.home, required this.placed});

  final int hwnd;
  final int pid;
  final (int, int) home;
  final (int, int) placed;

  Map<String, Object?> toJson() => {
    'hwnd': hwnd,
    'pid': pid,
    'home': [home.$1, home.$2],
    'placed': [placed.$1, placed.$2],
  };

  static NudgeRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    (int, int)? point(Object? value) => value is List && value.length == 2 && value[0] is int && value[1] is int ? (value[0] as int, value[1] as int) : null;
    final hwnd = json['hwnd'], pid = json['pid'], home = point(json['home']), placed = point(json['placed']);
    if (hwnd is! int || pid is! int || home == null || placed == null) return null;
    return NudgeRecord(hwnd: hwnd, pid: pid, home: home, placed: placed);
  }
}

enum NudgePhase { idle, moving, verifying }

/// One nudge at a time, with the put-back contract above.
class WindowNudger {
  WindowNudger({
    required this.mover,
    required JsonStore store,
    required this.allowed,
    required this.clock,
    this.log,
    this.tickEvery = const Duration(milliseconds: 33),
    this.verifyAfter = const Duration(milliseconds: 100),
  }) : _store = store;

  final WindowMover mover;
  final JsonStore _store;

  /// The gate says the extra may run now.
  final bool Function() allowed;

  /// Seconds.
  final double Function() clock;

  /// The stroll-debug log, when it is on.
  void Function(String)? log;

  /// Up to 30 steps a second, only while a nudge runs (which is at most 2 s).
  final Duration tickEvery;

  /// How long after the last step the window is read back.
  final Duration verifyAfter;

  /// A window still behind the nudge's moves after this long (seconds) is sent home at once.
  static const double lagLimit = 0.3;

  NudgePhase _phase = NudgePhase.idle;
  int _hwnd = 0;
  int _pid = 0;
  NudgeKind _kind = NudgeKind.wobble;
  late NudgeMotion _motion;
  late PixelRect _home;
  late (int, int) _homeAt;
  late (int, int) _placed;

  /// Every position this nudge has sent (top-left; home is not in it): where a lagging window may still be.
  final Set<(int, int)> _sent = {};
  double? _lateSince;
  bool _moved = false;
  double _startedAt = 0;
  Timer? _timer;
  Timer? _verify;

  /// Windows that refused to move this session.
  final Set<int> _wontMove = {};

  /// Nudges started so far, and every move sent (tests, the perf meter).
  int started = 0;
  int moves = 0;

  /// A nudge is running (moving, or being read back).
  bool get running => _phase != NudgePhase.idle;
  NudgePhase get phase => _phase;
  int get hwnd => _hwnd;
  NudgeKind get kind => _kind;

  /// The windows that refused to move.
  Set<int> get wontMove => Set.unmodifiable(_wontMove);

  /// Where the window is now asked to be, relative to home (physical pixels); (0, 0) when nothing runs.
  (int, int) get offset => running && _phase == NudgePhase.moving ? (_placed.$1 - _homeAt.$1, _placed.$2 - _homeAt.$2) : (0, 0);

  /// The offsets [hwnd]'s frame may be at while it is nudged: home and every position the nudge has sent (async moves
  /// land late, in order). Empty for any other window.
  List<(int, int)> offsetsOf(int hwnd) {
    if (!running || hwnd != _hwnd) return const [];
    return [(0, 0), for (final at in _sent) (at.$1 - _homeAt.$1, at.$2 - _homeAt.$2)];
  }

  /// [rect] is somewhere this nudge put the window (or home): the same size, at home or a position it sent.
  bool _ours(PixelRect rect) {
    if (rect.width != _home.width || rect.height != _home.height) return false;
    final at = (rect.left, rect.top);
    return at == _homeAt || _sent.contains(at);
  }

  /// [read] is [before] moved by this nudge (Mochi's own doing, not the user dragging it).
  bool expects(int hwnd, PixelRect before, PixelRect read) => offsetsOf(hwnd).any((o) => before.shifted(o.$1, o.$2) == read);

  /// Why [hwnd] may not be nudged now, or null.
  NudgeSkip? qualify(int hwnd) => NudgeRules.why(mover.info(hwnd), foreground: mover.foreground(), mouseDown: mover.mouseDown(), wontMove: _wontMove);

  PixelRect _rectAt((int, int) at) => PixelRect.ltwh(at.$1, at.$2, _home.width, _home.height);

  // ---- starting ----

  /// Starts [kind] on [hwnd] if the extra may run, nothing else is running and the window qualifies; [scale] is the
  /// display's, [facing] Mochi's (a shove goes that way).
  bool start(int hwnd, NudgeKind kind, {double scale = 1, double facing = 1}) {
    if (_phase != NudgePhase.idle) return false;
    if (!allowed()) return false;
    recover();
    if (qualify(hwnd) != null) return false;
    final rect = mover.rect(hwnd), pid = mover.pid(hwnd);
    if (rect == null || pid == null) return false;
    _hwnd = hwnd;
    _pid = pid;
    _kind = kind;
    _motion = switch (kind) {
      NudgeKind.wobble => NudgeMotion.wobble(scale: scale),
      NudgeKind.shove => NudgeMotion.shove(scale: scale, facing: facing),
      NudgeKind.tug => NudgeMotion.tug(scale: scale),
    };
    _home = rect;
    _homeAt = (rect.left, rect.top);
    _placed = _homeAt;
    _sent.clear();
    _lateSince = null;
    _moved = false;
    _startedAt = clock();
    _phase = NudgePhase.moving;
    started++;
    _write(_placed);
    _timer = Timer.periodic(tickEvery, (_) => tick());
    tick();
    return true;
  }

  // ---- stepping ----

  /// One step: the abort checks, the rect check, then the motion's next position (or home, at the end).
  void tick() {
    if (_phase != NudgePhase.moving) return;
    if (!allowed()) return _goHome();
    if (mover.mouseDown()) return _goHome();
    if (mover.foreground() == _hwnd) return _goHome();
    final current = mover.rect(_hwnd);
    if (current == null) return _finish('gone');
    if (current != _rectAt(_placed)) {
      if (!_ours(current)) return _finish('left (moved by you)');
      // One of the nudge's own moves still to land: wait for it; a window that lags too long goes home now.
      final since = _lateSince ??= clock();
      if (clock() - since >= lagLimit) return _goHome();
      return;
    }
    _lateSince = null;
    final t = clock() - _startedAt;
    if (t >= _motion.duration) return _finalStep();
    final offset = _motion.at(t);
    final target = (_homeAt.$1 + offset.$1, _homeAt.$2 + offset.$2);
    if (target != _placed) _step(target);
  }

  /// A move to [target]; the journal knows first.
  void _step((int, int) target) {
    _write(target);
    moves++;
    if (!mover.move(_hwnd, target.$1, target.$2)) return _refused();
    _placed = target;
    if (target != _homeAt) {
      _sent.add(target);
      _moved = true;
    }
  }

  /// The last step: always a move to exactly home, then a look at it a moment later.
  void _finalStep() => _sendHome();

  /// SetWindowPos said no: the window did not move. Nothing is put back for a window that never moved; one that had
  /// already moved gets one try at home.
  void _refused() {
    _wontMove.add(_hwnd);
    var stranded = false;
    if (_moved) {
      // Earlier moves may still be landing, so home goes last even when the window reads at home.
      final current = mover.rect(_hwnd);
      if (current != null && _ours(current)) {
        moves++;
        stranded = !mover.move(_hwnd, _homeAt.$1, _homeAt.$2);
      }
    }
    // A window that took moves and now refuses home keeps the journal: the next start tries again.
    _finish('failed', keepJournal: stranded);
  }

  /// Home (one move) and the look back; the journal stays until the window is read at home.
  void _sendHome() {
    _timer?.cancel();
    _timer = null;
    moves++;
    if (!mover.move(_hwnd, _homeAt.$1, _homeAt.$2)) {
      // Home is not reachable: the window stays (it refused). The journal stays too, for the next try.
      _wontMove.add(_hwnd);
      _finish('failed', keepJournal: _placed != _homeAt);
      return;
    }
    _phase = NudgePhase.verifying;
    _verify = Timer(verifyAfter, () => _read(closing: false));
  }

  /// The read back: at home, done; still where it was, home once more; anywhere else, left alone.
  void _read({required bool closing}) {
    if (_phase != NudgePhase.verifying) return;
    _verify?.cancel();
    _verify = null;
    final current = mover.rect(_hwnd);
    if (current == null) return _finish('gone');
    if (current == _home) return _finish('home ok');
    if (_ours(current)) {
      // Still at one of the nudge's positions (the home move hasn't landed): home once more, queued after it. Quitting
      // can't wait to see it land, so the journal stays for the next start.
      if (closing) return _finish('home ok', keepJournal: true);
      moves++;
      mover.move(_hwnd, _homeAt.$1, _homeAt.$2);
      return _finish('home ok');
    }
    _finish('left (moved by you)');
  }

  // ---- ending early ----

  /// Everything that sends a window home at once: if the window is home or at one of the nudge's positions, one move
  /// home (once anything was sent: an earlier move may still be on its way, and home must be the last); if somebody else
  /// moved it, it stays where they put it.
  void _goHome() {
    if (_phase != NudgePhase.moving) return;
    _timer?.cancel();
    _timer = null;
    final current = mover.rect(_hwnd);
    if (current == null) return _finish('gone');
    if (!_ours(current)) return _finish('left (moved by you)');
    if (!_moved) return _finish('home ok');
    _sendHome();
  }

  /// Sends the window home now: a mouse button went down, the window took the focus, the adventure ended, Mochi was
  /// turned off... Nothing running: nothing happens.
  void abort() => _goHome();

  /// The gate or the switches changed: a nudge that may no longer run goes home.
  void recheck() {
    if (running && !allowed()) abort();
  }

  /// Quitting, or Windows ending the session: home at once, and no timers left. Not waiting for a read back: the journal
  /// stays when the window could not be seen at home yet, so the next start finishes the job.
  void putBack() {
    if (_phase == NudgePhase.moving) _goHome();
    if (_phase == NudgePhase.verifying) _read(closing: true);
    _timer?.cancel();
    _timer = null;
    _verify?.cancel();
    _verify = null;
  }

  /// Ends the nudge: the journal goes unless the window may still be displaced ([keepJournal]).
  void _finish(String result, {bool keepJournal = false}) {
    _timer?.cancel();
    _timer = null;
    _verify?.cancel();
    _verify = null;
    if (!keepJournal) _store.delete();
    log?.call('nudge: ${_kind.name}, $result');
    _phase = NudgePhase.idle;
    _hwnd = 0;
    _sent.clear();
    _lateSince = null;
  }

  // ---- the journal ----

  void _write((int, int) placed) => _store.write(NudgeRecord(hwnd: _hwnd, pid: _pid, home: _homeAt, placed: placed).toJson());

  /// A nudge that was cut short (a crash, a kill, a power cut) leaves its journal: a window that is still at `placed` (the
  /// same process owns it) goes back to `home`; the journal goes either way. True when a window was moved.
  bool recover() {
    if (_phase != NudgePhase.idle) return false;
    final json = _store.read();
    if (json == null) return false;
    final record = NudgeRecord.fromJson(json);
    var moved = false;
    if (record != null && mover.pid(record.hwnd) == record.pid) {
      final rect = mover.rect(record.hwnd);
      if (rect != null && rect.left == record.placed.$1 && rect.top == record.placed.$2 && record.placed != record.home) {
        moves++;
        moved = mover.move(record.hwnd, record.home.$1, record.home.$2);
        log?.call('nudge: recovered a window (${moved ? 'home ok' : 'failed'})');
      }
    }
    _store.delete();
    return moved;
  }

  void dispose() {
    putBack();
  }
}
