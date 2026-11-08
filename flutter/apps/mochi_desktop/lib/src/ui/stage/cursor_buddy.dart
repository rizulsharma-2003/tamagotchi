// The cursor buddy (docs/SPRINT_2.md X4): with Mischief and Cursor buddy on, Mochi hops off the taskbar (or the desktop)
// and keeps your pointer company: it chases it when it moves, pounces beside it when it stops, sits by it while you
// read, and curls up for a nap beside it while you're away. It's the same Mochi (its world plays over all of it: a pet,
// Claude's news), drawn on the native stage (N1).
//
// - The pointer is only ever read (GetCursorPos), never moved, hidden or clicked. Mochi lets every click through while
//   it runs, so it never gets in your way; sitting still, a click pets it and a right-click is its menu.
// - Cheap: the pointer is read 30 times a second only while Mochi runs, 8 while it sits, 6 while it naps, and not at
//   all while nobody can see the screen (Mochi stays where it was and carries on when the screen is back). Each pose is
//   drawn once (the run and the sit come round on the ring) and a frame is sent only when the picture or the place
//   changes.
// - It goes home whenever Mischief says no: at once for a full-screen app or Mochi's window opening, at a run
//   otherwise (quiet hours, the switch turned off), back to the spot on the taskbar it left from.

import 'dart:async';
import 'dart:math' as math;

import 'package:mochi_art/mochi_art.dart' show PetAnimation;

import '../../core/mischief.dart';
import '../../core/pc_rhythm.dart';
import '../../platform/displays.dart';
import '../../platform/native_stage.dart';
import '../pet/stroller.dart';
import '../pet/taskbar_stroll.dart' show PetHome;
import 'stage_pet.dart';

/// What the cursor buddy is doing.
enum BuddyMode {
  /// Running (or walking, close by) to the pointer.
  chase,

  /// A pounce beside the pointer that just stopped.
  pounce,

  /// Sitting by the pointer.
  sit,

  /// Asleep by the pointer (you've been away a while, or the PC rests).
  nap,

  /// Going back to the taskbar.
  home,
}

class CursorBuddy {
  CursorBuddy({
    required this.pet,
    required this.home,
    required this.gate,
    required this.rhythm,
    required this.displays,
    required this.cursor,
    required this.time,
    required this.shown,
    this.reacting = _never,
    this.asleep = _never,
    this.onPet,
    this.onMenu,
  });

  final StagePet pet;
  final PetHome home;
  final MischiefGate gate;
  final PcRhythm rhythm;
  final Displays displays;

  /// Where the pointer is (physical pixels; read only).
  final (int, int)? Function() cursor;

  /// The world's clock (seconds): Mochi's poses and its moves.
  final double Function() time;

  /// The pet shows (not Mochi's window or the popover, and not hidden): only then can Mochi be out.
  final bool Function() shown;

  /// Mochi's world is playing a moment (Mochi holds still for it, as on the taskbar).
  final bool Function() reacting;

  /// Mochi's world says it's napping (the PC rests).
  final bool Function() asleep;

  /// A click on Mochi (sitting), and a right-click.
  final void Function()? onPet;
  final void Function(int x, int y)? onMenu;

  static bool _never() => false;

  /// How big Mochi is out here (logical pixels per art unit: about 50 tall at 100%).
  static const double unit = 0.95;

  /// Where Mochi goes beside the pointer (logical pixels from its tip to Mochi's feet).
  static const double besideX = 40;
  static const double belowY = 36;

  /// Speeds (logical pixels a second): a dash when far, a trot, a walk when close.
  static const double dash = 620;
  static const double trot = 320;
  static const double amble = 140;

  /// How long the pointer stays still before Mochi sits (after a pounce) and before it naps.
  static const double sitAfter = 0.35;
  static const double napAfter = 90;

  /// How often the pointer is read and Mochi drawn: running, sitting, napping.
  static const Duration runEvery = Duration(milliseconds: 33);
  static const Duration sitEvery = Duration(milliseconds: 125);
  static const Duration napEvery = Duration(milliseconds: 166);

  /// Going home takes at most this long; then Mochi hops the rest of the way.
  static const double homeAtMost = 6;

  bool _out = false;
  bool _paused = false;
  bool _started = false;
  double _x = 0, _y = 0;
  double _facing = 1;
  double _side = 1;
  double _odometer = 0;
  BuddyMode _mode = BuddyMode.chase;
  double _modeSince = 0;
  double _chaseSince = 0;
  double _lastTick = 0;
  (int, int)? _pointer;
  double _pointerMovedAt = 0;
  (int, int)? _homeFeet;
  double _speed = 0;
  int _ticks = 0;
  Timer? _timer;
  Duration? _every;
  StreamSubscription<StagePointer>? _clicks;
  (int, int)? _pressedAt;

  /// Mochi is out with the pointer.
  bool get active => _out;

  /// The screen can't be seen: Mochi waits where it was, with no timer.
  bool get paused => _paused;

  /// What it's doing.
  BuddyMode get mode => _mode;

  /// Where its feet are (physical pixels).
  (int, int) get feet => (_x.round(), _y.round());

  /// How often the pointer is read now (null: not at all).
  Duration? get every => _timer == null ? null : _every;

  /// Starts watching for when Mochi may go out.
  void start() {
    if (_started) return;
    _started = true;
    gate.addListener(consider);
    home.addListener(consider);
    rhythm.addListener(consider);
    _clicks = pet.stage.pointer.where((event) => event.actor == pet.actor).listen(_pointerEvent);
    consider();
  }

  /// Looks again: whether Mochi goes out, keeps going, waits for the screen, or goes home.
  void consider() {
    if (!_started) return;
    final why = gate.why(MischiefExtra.cursorBuddy);
    if (!_out) {
      if (why == null && shown() && home.canGoOut) _goOut();
      return;
    }
    if (why == MischiefPause.unseen) return _pause();
    if (_paused) _resume();
    if (!shown() || why == MischiefPause.fullScreen) return _homeNow();
    if (why != null && _mode != BuddyMode.home) _goHome();
  }

  void _goOut() {
    final departure = home.departure();
    if (departure == null) return;
    final now = time();
    _out = true;
    _paused = false;
    _x = departure.x.toDouble();
    _y = departure.y.toDouble();
    _homeFeet = (departure.x, departure.y);
    _facing = departure.facing;
    _odometer = 0;
    _pointer = cursor();
    _pointerMovedAt = now;
    _lastTick = now;
    _setMode(BuddyMode.chase, now);
    _chaseSince = now;
    home.goOut();
    _tick();
  }

  void _pause() {
    if (_paused) return;
    _paused = true;
    _stopTimer();
    pet.hide();
  }

  void _resume() {
    _paused = false;
    final now = time();
    _lastTick = now;
    _pointerMovedAt = now;
    _tick();
  }

  /// Walks (runs) back to where it left from, then it's on the taskbar again.
  void _goHome() {
    _setMode(BuddyMode.home, time());
    _tick();
  }

  /// Back on the taskbar at once.
  void _homeNow() {
    _stopTimer();
    pet.hide();
    final back = _homeFeet;
    _out = false;
    _paused = false;
    home.comeBack(x: back?.$1);
  }

  void _setMode(BuddyMode mode, double now) {
    if (mode == _mode && _modeSince != 0) return;
    _mode = mode;
    _modeSince = now;
  }

  /// The display at a point (else the main one).
  DisplayArea? _displayAt(double x, double y) {
    final list = displays.list();
    if (list.isEmpty) return null;
    for (final display in list) {
      if (display.monitor.contains(x.round(), y.round())) return display;
    }
    return PetPlacing.primaryOf(list);
  }

  void _tick() {
    if (!_out || _paused) return;
    final now = time();
    final dt = (now - _lastTick).clamp(0.0, 0.1);
    _lastTick = now;
    _ticks++;
    final pointer = cursor();
    if (pointer != null) {
      final last = _pointer;
      if (last == null || (pointer.$1 - last.$1).abs() + (pointer.$2 - last.$2).abs() > 2) _pointerMovedAt = now;
      _pointer = pointer;
    }
    final at = _pointer ?? (_x.round(), _y.round());
    final display = _displayAt(at.$1.toDouble(), at.$2.toDouble()) ?? _displayAt(_x, _y);
    if (display == null) return _homeNow();
    final scale = display.scale;

    // Where Mochi wants to be: beside the pointer, or home.
    final double tx, ty;
    if (_mode == BuddyMode.home) {
      final back = _homeFeet ?? (at.$1, display.workArea.bottom);
      tx = back.$1.toDouble();
      ty = back.$2.toDouble();
    } else {
      (tx, ty) = _beside(at, display);
    }
    final dx = tx - _x, dy = ty - _y;
    final distance = math.sqrt(dx * dx + dy * dy);
    final still = now - _pointerMovedAt;
    final hold = reacting();

    switch (_mode) {
      case BuddyMode.home:
        if (distance < 4 * scale || now - _modeSince > homeAtMost) {
          _homeNow();
          return;
        }
      case BuddyMode.pounce:
        if (now - _modeSince >= PetAnimation.pounce.defaultDuration) _setMode(distance > 8 * scale ? BuddyMode.chase : BuddyMode.sit, now);
      case BuddyMode.chase:
        if (distance <= 3 * scale) {
          // Arrived: a pounce after a real chase (once the pointer has stopped), else just a sit.
          if (still >= sitAfter) _setMode(now - _chaseSince > 0.6 ? BuddyMode.pounce : BuddyMode.sit, now);
        }
      case BuddyMode.sit || BuddyMode.nap:
        if (distance > 8 * scale) {
          _setMode(BuddyMode.chase, now);
          _chaseSince = now;
        } else if (_mode == BuddyMode.sit && (still >= napAfter || asleep())) {
          _setMode(BuddyMode.nap, now);
        } else if (_mode == BuddyMode.nap && still < 1 && !asleep()) {
          _setMode(BuddyMode.sit, now);
        }
    }

    // Moving: fast when far, slower when close; never while the world plays a moment.
    final moving = _mode == BuddyMode.chase || _mode == BuddyMode.home;
    _speed = 0;
    if (moving && !hold && distance > 0.5) {
      final logical = distance / scale;
      final speed = (_mode == BuddyMode.home || logical > 260 ? dash : (logical > 70 ? trot : amble)) * scale;
      final step = math.min(distance, speed * dt);
      _x += dx / distance * step;
      _y += dy / distance * step;
      _odometer += step / scale;
      _speed = speed / scale;
      if (dx.abs() > 1) _facing = dx > 0 ? 1 : -1;
    } else if (!moving) {
      // Facing the pointer.
      final across = at.$1 - _x;
      if (across.abs() > 6 * scale) _facing = across > 0 ? 1 : -1;
    }

    final here = _displayAt(_x, _y) ?? display;
    pet.draw(
      time: now,
      motion: _motion(now),
      feet: (_x.round(), _y.round()),
      ratio: here.scale,
      unit: unit,
      // Its poses change 15 times a second (half the pictures of a 30 a second walk) while it moves 30 times.
      quantum: 1 / 15,
      clickThrough: moving,
    );
    // Back over other always-on-top windows now and then (the taskbar rises when it's clicked).
    if (_ticks % 60 == 0) pet.raise();
    _schedule();
  }

  /// Mochi's feet beside the pointer at [at], on [display]: on the side it's on, unless that's off the screen.
  (double, double) _beside((int, int) at, DisplayArea display) {
    final scale = display.scale;
    final area = display.monitor;
    final margin = 30 * scale;
    var side = _side;
    double x(double side) => at.$1 + side * besideX * scale;
    if (x(side) < area.left + margin || x(side) > area.right - margin) side = -side;
    // Keep to the side Mochi is on (it doesn't hop over the pointer for a little move).
    if ((_x - at.$1).abs() > besideX * scale * 2) side = _x < at.$1 ? -1 : 1;
    if (x(side) < area.left + margin || x(side) > area.right - margin) side = -side;
    _side = side;
    final y = (at.$2 + belowY * scale).clamp(area.top + 60 * scale, area.bottom - 2.0);
    return (x(side).clamp(area.left + margin, area.right - margin), y);
  }

  StrollSample _motion(double now) {
    switch (_mode) {
      case BuddyMode.chase || BuddyMode.home:
        if (_speed <= 0) {
          return StrollSample(x: 0, facing: _facing, animation: PetAnimation.idle, animationTime: now, activity: StrollActivity.watch);
        }
        final run = _speed >= trot;
        return StrollSample(
          x: 0,
          facing: _facing,
          animation: run ? PetAnimation.run : PetAnimation.walk,
          animationTime: _odometer / (run ? const StrollTuning().runGait : const StrollTuning().walkGait),
          activity: StrollActivity.trot,
          travelling: true,
        );
      case BuddyMode.pounce:
        return StrollSample(
          x: 0,
          facing: _facing,
          animation: PetAnimation.pounce,
          animationTime: now - _modeSince,
          activity: StrollActivity.react,
          oneShot: true,
          style: StrollStyle.notice,
        );
      case BuddyMode.sit:
        return StrollSample(x: 0, facing: _facing, animation: PetAnimation.sit, animationTime: now, activity: StrollActivity.rest);
      case BuddyMode.nap:
        return StrollSample(x: 0, facing: _facing, animation: PetAnimation.sleep, animationTime: now, activity: StrollActivity.sleep);
    }
  }

  void _schedule() {
    final every = switch (_mode) {
      BuddyMode.chase || BuddyMode.pounce || BuddyMode.home => runEvery,
      BuddyMode.sit => sitEvery,
      BuddyMode.nap => napEvery,
    };
    if (every == _every && _timer != null) return;
    _timer?.cancel();
    _every = every;
    _timer = Timer.periodic(every, (_) => _tick());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _every = null;
  }

  /// A click on Mochi while it sits (it lets clicks through while it runs).
  void _pointerEvent(StagePointer event) {
    switch (event.kind) {
      case StagePointerKind.down:
        _pressedAt = (event.screenX, event.screenY);
      case StagePointerKind.up:
        final pressed = _pressedAt;
        _pressedAt = null;
        if (pressed != null && (event.screenX - pressed.$1).abs() + (event.screenY - pressed.$2).abs() < 8) onPet?.call();
      case StagePointerKind.rightUp:
        onMenu?.call(event.screenX, event.screenY);
      case StagePointerKind.cancel || StagePointerKind.leave:
        if (event.kind == StagePointerKind.cancel) _pressedAt = null;
      default:
        break;
    }
  }

  /// What it's up to, for the perf meter.
  String? perfState() => !_out
      ? null
      : _paused
      ? 'cursor buddy (waiting for the screen)'
      : 'cursor buddy (${switch (_mode) {
          BuddyMode.chase => 'chasing',
          BuddyMode.pounce => 'pouncing',
          BuddyMode.sit => 'sitting',
          BuddyMode.nap => 'napping',
          BuddyMode.home => 'going home',
        }})';

  void stop() {
    if (_started) {
      gate.removeListener(consider);
      home.removeListener(consider);
      rhythm.removeListener(consider);
    }
    _started = false;
    unawaited(_clicks?.cancel());
    _clicks = null;
    if (_out) _homeNow();
    _stopTimer();
  }
}
