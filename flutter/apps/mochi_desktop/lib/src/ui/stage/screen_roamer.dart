// Multi-monitor roaming (docs/SPRINT_2.md X8): with Mischief and Roams your screens on, Mochi now and then walks along
// the bottom of the screen to its edge and on to the next display, stands there a while and comes home; and when you
// have been working on another display for a couple of minutes it goes there and stays until you switch back. It's the
// same Mochi, drawn on the native stage (N1), as it is for the cursor buddy.
//
// - Every display has its own scale: Mochi is drawn again at the scale of the display it's on (the same size in logical
//   pixels), and a display with a taskbar along its bottom gets Mochi standing on that taskbar, else on its bottom edge.
// - A display unplugged on the way (or while it's there): Mochi is home on the main display's taskbar at once.
// - Cheap: while Mischief may run, the displays and the foreground window's display are read every [watchEvery]
//   (two cheap Win32 calls; nothing more with one display); no timer at all while nobody can see the screen (Mochi
//   waits where it was). It walks at 30 frames a second and stands at 8; a frame is sent only when something changes.
// - Never during a full-screen app, quiet hours or a focus session (MischiefGate): it goes home at once for a
//   full-screen app or Mochi's window opening, at a walk otherwise.

import 'dart:async';
import 'dart:math' as math;

import 'package:mochi_art/mochi_art.dart' show PetAnimation;

import '../../core/mischief.dart';
import '../../platform/displays.dart';
import '../pet/stroller.dart';
import '../pet/taskbar_stroll.dart' show PetHome;
import 'stage_pet.dart';

/// What Mochi is doing out on the displays.
enum RoamPhase { going, staying, coming }

class _Leg {
  const _Leg(this.x, this.y, this.display, {this.jump = false});

  /// Where its feet go (physical pixels) on [display]; a jump is the step from one display's edge onto the next.
  final double x, y;
  final DisplayArea display;
  final bool jump;
}

class ScreenRoamer {
  ScreenRoamer({
    required this.pet,
    required this.home,
    required this.gate,
    required this.displays,
    required this.time,
    required this.shown,
    this.reacting = _never,
    math.Random? random,
  }) : _random = random ?? math.Random();

  final StagePet pet;
  final PetHome home;
  final MischiefGate gate;
  final Displays displays;
  final double Function() time;
  final bool Function() shown;
  final bool Function() reacting;
  final math.Random _random;

  static bool _never() => false;

  /// How often the displays and the foreground window are looked at.
  static const Duration watchEvery = Duration(seconds: 4);

  /// Frames while it walks, and while it stands.
  static const Duration walkEvery = Duration(milliseconds: 33);
  static const Duration standEvery = Duration(milliseconds: 125);

  /// A walk of its own: a few times an hour; it stays this long, then comes home.
  static const double wandersPerHour = 3;
  static const double lingerFor = 25;

  /// The foreground window must be on another display this long before Mochi goes there, and back on the main one this
  /// long before it comes home.
  static const double followAfter = 120;
  static const double returnAfter = 8;

  /// Speeds (logical pixels a second): a stroll for its own walks, a run to follow you.
  static const double stroll = 120;
  static const double run = 320;

  /// Coming home takes at most this long; then it hops the rest of the way.
  static const double homeAtMost = 60;

  bool _started = false;
  bool _out = false;
  bool _paused = false;
  bool _follow = false;
  RoamPhase _phase = RoamPhase.going;
  double _x = 0, _y = 0, _facing = 1, _odometer = 0, _lastTick = 0, _since = 0, _lingerUntil = 0, _speed = 0;
  double _unit = 0.95;
  DisplayArea? _on;
  DisplayArea? _homeDisplay;
  DisplayArea? _target;
  (int, int)? _homeFeet;
  List<_Leg> _legs = [];
  String? _fgKey;
  double _fgSince = 0;
  int _ticks = 0;
  Timer? _timer, _watch;
  Duration? _every;
  StreamSubscription<void>? _changes;

  bool get active => _out;
  bool get paused => _paused;
  RoamPhase get phase => _phase;

  /// The display Mochi is on (null while it isn't out).
  DisplayArea? get on => _out ? _on : null;
  (int, int) get feet => (_x.round(), _y.round());

  /// How often the displays are looked at now (null: not at all), and how often Mochi is drawn.
  Duration? get watching => _watch == null ? null : watchEvery;
  Duration? get every => _timer == null ? null : _every;

  void start() {
    if (_started) return;
    _started = true;
    gate.addListener(consider);
    home.addListener(consider);
    _changes = pet.stage.displaysChanged.listen((_) => _displaysChanged());
    consider();
  }

  /// Looks again: whether it watches, waits for the screen, keeps going, or goes home.
  void consider() {
    if (!_started) return;
    final why = gate.why(MischiefExtra.roamScreens);
    if (why == MischiefPause.unseen) {
      _stopWatch();
      if (_out) _pause();
      return;
    }
    if (_out && (!shown() || why == MischiefPause.fullScreen)) {
      _stopWatch();
      return _homeNow();
    }
    if (_out && _paused) _resume();
    if (why != null || !shown()) {
      _stopWatch();
      if (_out && _phase != RoamPhase.coming) _goBack();
      return;
    }
    _watch ??= Timer.periodic(watchEvery, (_) => _look());
  }

  void _stopWatch() {
    _watch?.cancel();
    _watch = null;
    _fgKey = null;
  }

  void _pause() {
    if (_paused) return;
    _paused = true;
    _stopTimer();
    pet.hide();
  }

  void _resume() {
    _paused = false;
    _lastTick = time();
    _tick();
  }

  // ---- the decisions, every few seconds ----

  void _look() {
    if (!_started || gate.why(MischiefExtra.roamScreens) != null) return;
    final list = displays.list();
    if (list.length < 2) {
      _fgKey = null;
      return;
    }
    final now = time();
    final front = displays.foreground();
    if (front?.key != _fgKey) {
      _fgKey = front?.key;
      _fgSince = now;
    }
    final steady = now - _fgSince;
    if (!_out) {
      if (!shown() || !home.canGoOut) return;
      if (front != null && !front.primary && steady >= followAfter) {
        _go(_known(list, front), follow: true);
      } else if (_random.nextDouble() < wandersPerHour * watchEvery.inSeconds / 3600) {
        _go(_neighbour(list), follow: false);
      }
      return;
    }
    if (!_follow || _paused || _phase == RoamPhase.coming) return;
    if (front == null) return;
    if (front.primary) {
      if (steady >= returnAfter) _goBack();
    } else if (front.key != _target?.key && steady >= followAfter) {
      _replan(_known(list, front));
    }
  }

  DisplayArea _known(List<DisplayArea> list, DisplayArea front) => list.firstWhere((d) => d.key == front.key, orElse: () => front);

  /// A display next to the main one (a random one if there are two).
  DisplayArea _neighbour(List<DisplayArea> list) {
    final main = PetPlacing.primaryOf(list);
    final sorted = _sorted(list);
    final i = sorted.indexOf(main);
    final next = [if (i > 0) sorted[i - 1], if (i < sorted.length - 1) sorted[i + 1]];
    return next[_random.nextInt(next.length)];
  }

  static List<DisplayArea> _sorted(List<DisplayArea> list) => [...list]..sort((a, b) => a.monitor.left.compareTo(b.monitor.left));

  // ---- going out and coming back ----

  void _go(DisplayArea target, {required bool follow}) {
    final departure = home.departure();
    if (departure == null) return;
    final list = displays.list();
    final here = _displayAt(list, departure.x.toDouble(), departure.y.toDouble());
    if (here == null || here.key == target.key) return;
    final now = time();
    _out = true;
    _paused = false;
    _follow = follow;
    _x = departure.x.toDouble();
    _y = departure.y.toDouble();
    _facing = departure.facing;
    _unit = departure.unit;
    _homeFeet = (departure.x, departure.y);
    _homeDisplay = here;
    _on = here;
    _target = target;
    _odometer = 0;
    _lastTick = now;
    _since = now;
    _phase = RoamPhase.going;
    _legs = _route(list, here, target, _stand(target), _floor(target));
    home.goOut();
    _tick();
  }

  /// To another display from where it is (it's already out).
  void _replan(DisplayArea target) {
    _target = target;
    _phase = RoamPhase.going;
    _legs = _route(displays.list(), _on!, target, _stand(target), _floor(target));
    _tick();
  }

  /// Walks back to the taskbar, where it left from.
  void _goBack() {
    final back = _homeFeet, here = _homeDisplay;
    if (!_out || back == null || here == null) return _homeNow();
    _phase = RoamPhase.coming;
    _since = time();
    _legs = _route(displays.list(), _on!, here, back.$1.toDouble(), back.$2.toDouble());
    _tick();
  }

  /// Home on the taskbar at once (a full-screen app, a display gone, Mochi's window opening, or it's there).
  void _homeNow() {
    _stopTimer();
    pet.hide();
    final back = _homeFeet;
    final keep = _homeDisplay != null && displays.list().any((d) => d.key == _homeDisplay!.key);
    _out = false;
    _paused = false;
    _legs = [];
    _target = null;
    home.comeBack(x: keep ? back?.$1 : null);
  }

  /// Another extra takes Mochi over (an adventure you asked for): the roamer lets go where Mochi stands, which stays out
  /// (the new owner brings it home). Returns where its feet are, or null when it wasn't out.
  (int, int)? release() {
    if (!_out) return null;
    final feet = (_x.round(), _y.round());
    _stopTimer();
    _out = false;
    _paused = false;
    _legs = [];
    _target = null;
    return feet;
  }

  void _displaysChanged() {
    if (_out && !_paused && _lost(displays.list())) _homeNow();
  }

  /// A display Mochi needs (home, where it is, where it's going, or one on the way) has gone.
  bool _lost(List<DisplayArea> list) {
    final needed = {?_homeDisplay?.key, ?_on?.key, ?_target?.key, for (final leg in _legs) leg.display.key};
    return needed.any((key) => !list.any((d) => d.key == key));
  }

  // ---- places ----

  static DisplayArea? _displayAt(List<DisplayArea> list, double x, double y) {
    if (list.isEmpty) return null;
    for (final display in list) {
      if (display.monitor.contains(x.round(), y.round())) return display;
    }
    return PetPlacing.primaryOf(list);
  }

  /// Where its feet stand on [display]: on its taskbar if that runs along the bottom, else on its bottom edge.
  static double _floor(DisplayArea display) {
    final bar = display.monitor.bottom - display.workArea.bottom;
    return bar > 0 ? display.workArea.bottom + bar * 0.75 : display.monitor.bottom - 2.0 * display.scale;
  }

  static double _stand(DisplayArea display) => display.monitor.left + display.monitor.width * 0.4;

  /// Along each display's floor to its edge, across to the next display's, and so on to [x], [y] on [to].
  static List<_Leg> _route(List<DisplayArea> list, DisplayArea from, DisplayArea to, double x, double y) {
    final sorted = _sorted(list);
    var i = sorted.indexWhere((d) => d.key == from.key), j = sorted.indexWhere((d) => d.key == to.key);
    if (i < 0) i = 0;
    if (j < 0) j = i;
    final legs = <_Leg>[];
    final step = j >= i ? 1 : -1;
    for (var k = i; k != j; k += step) {
      final a = sorted[k], b = sorted[k + step];
      final double exit, entry;
      if (b.monitor.left >= a.monitor.right) {
        exit = a.monitor.right - 1.0;
        entry = b.monitor.left.toDouble();
      } else if (b.monitor.right <= a.monitor.left) {
        exit = a.monitor.left.toDouble();
        entry = b.monitor.right - 1.0;
      } else {
        exit = entry = (math.max(a.monitor.left, b.monitor.left) + math.min(a.monitor.right, b.monitor.right)) / 2;
      }
      legs
        ..add(_Leg(exit, _floor(a), a))
        ..add(_Leg(entry, _floor(b), b, jump: true));
    }
    legs.add(_Leg(x, y, to));
    return legs;
  }

  // ---- the walk ----

  void _tick() {
    if (!_out || _paused) return;
    final now = time();
    final dt = (now - _lastTick).clamp(0.0, 0.1);
    _lastTick = now;
    _ticks++;
    if (_lost(displays.list())) return _homeNow();
    _speed = 0;
    if (_legs.isEmpty) {
      // There: it stands (a walk of its own ends after a while).
      if (_phase == RoamPhase.going) {
        _phase = RoamPhase.staying;
        _lingerUntil = now + lingerFor;
      } else if (_phase == RoamPhase.coming) {
        return _homeNow();
      } else if (!_follow && now >= _lingerUntil) {
        return _goBack();
      }
    } else if (_phase == RoamPhase.coming && now - _since > homeAtMost) {
      return _homeNow();
    } else if (!reacting()) {
      _step(dt);
    }
    final moving = _speed > 0;
    pet.draw(
      time: now,
      motion: _motion(now, moving),
      feet: (_x.round(), _y.round()),
      ratio: _on!.scale,
      unit: _unit,
      quantum: 1 / 15,
      clickThrough: true,
    );
    if (_ticks % (moving ? 60 : 40) == 0) pet.raise();
    _schedule(moving);
  }

  void _step(double dt) {
    var leg = _legs.first;
    if (leg.jump) {
      _x = leg.x;
      _y = leg.y;
      _on = leg.display;
      _legs.removeAt(0);
      if (_legs.isEmpty) return;
      leg = _legs.first;
    }
    final scale = _on!.scale;
    final dx = leg.x - _x, dy = leg.y - _y;
    final distance = math.sqrt(dx * dx + dy * dy);
    if (distance <= 1.5 * scale) {
      _x = leg.x;
      _y = leg.y;
      _legs.removeAt(0);
      return;
    }
    final speed = (_follow ? run : stroll) * scale;
    final step = math.min(distance, speed * dt);
    _x += dx / distance * step;
    _y += dy / distance * step;
    _odometer += step / scale;
    _speed = speed / scale;
    if (dx.abs() > 1) _facing = dx > 0 ? 1 : -1;
  }

  StrollSample _motion(double now, bool moving) {
    if (!moving) {
      return StrollSample(x: 0, facing: _facing, animation: PetAnimation.idle, animationTime: now, activity: StrollActivity.watch);
    }
    final fast = _speed >= run;
    return StrollSample(
      x: 0,
      facing: _facing,
      animation: fast ? PetAnimation.run : PetAnimation.walk,
      animationTime: _odometer / (fast ? const StrollTuning().runGait : const StrollTuning().walkGait),
      activity: StrollActivity.trot,
      travelling: true,
    );
  }

  void _schedule(bool moving) {
    final every = moving ? walkEvery : standEvery;
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

  /// What it's up to, for the perf meter.
  String? perfState() => !_out
      ? null
      : _paused
      ? 'roaming screens (waiting for the screen)'
      : 'roaming screens (${switch (_phase) {
          RoamPhase.going => 'walking',
          RoamPhase.staying => 'on another screen',
          RoamPhase.coming => 'coming home',
        }})';

  void stop() {
    if (_started) {
      gate.removeListener(consider);
      home.removeListener(consider);
    }
    _started = false;
    unawaited(_changes?.cancel());
    _changes = null;
    _stopWatch();
    if (_out) _homeNow();
    _stopTimer();
  }
}
