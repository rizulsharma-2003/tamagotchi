// Explore the desktop (docs/SPRINT_2.md W19; the Mac's AdventureController): Mochi leaves the taskbar, walks along the
// tops of your windows, hops from one to the next, comes down to the taskbar for a sit, climbs the edge of the screen and
// hops home. It's the same Mochi (its world plays over all of it), drawn on the native stage (N1), and the route is the
// Mac's own (mochi_world's AdventurePlanner), planned in one display's logical pixels with y up (see [AdventureSpace]).
//
// When it sets off:
// - you choose Explore (the popover's Fun row, the tray menu, Settings › Fun › Adventures › Explore Now, or ask: "go
//   explore"); the same choices call it home while it's out;
// - you drag it up off the taskbar (with Adventures on, it falls from where you let go onto whatever is below);
// - now and then by itself ([AdventureScheduler]: about every 45–60 minutes at "sometimes", 2–3 hours at "rarely"), counted
//   only while it's eligible: no Claude session working or waiting, Mochi showing on the taskbar (not in its window or
//   the popover), and the rules below.
// It's a Mac feature, on by default, so it isn't behind the Mischief switches; but it keeps every extra's rules
// (MischiefGate.whyAdventure): no full-screen app, quiet hours, paused reactions, a focus session, Windows' animation
// effects off, or an unseen screen. An adventure you ask for takes Mochi from the cursor buddy or the screen roamer.
//
// While it's out:
// - Only the display it left from is its world: the floor is the top of that display's taskbar (the taskbar's stretch
//   by the middle is the Mac's "dock": where it sits), and ledges are the tops of other windows there, read three
//   times a second (platform/window_frames.dart: frames only, never titles or contents) and never otherwise, nor while the
//   screen is unseen. Windows that move, close or are covered re-route it (AdventurePlanner.adapt).
// - Pressing on it and dragging lifts it by the scruff (the Mac's carry, swinging from the pointer); let go and it falls to
//   the surface below and carries on; let go on the taskbar and it's home. A click pets it (it stops for a happy
//   bounce); a right-click opens the menu, as with the cursor buddy.
// - A full-screen app, Mochi's window or the popover opening, a display going, the screen going unseen, or Windows'
//   animation effects turning off send it home at once; Claude needing you, Patch arriving, or Adventures turned off
//   hurry it home (one big leap); quiet hours, paused reactions or a focus session do the same.
// - Cheap: 30 frames a second while it moves, 8 while it holds still, nothing while the screen is unseen (it goes home
//   first); a frame is sent only when the picture or the place changes; the actor is topmost.
// - Home is PetHome.comeBack(x:): the hop out of the top of the screen ends with Mochi on the taskbar where it left.
//
// Not done yet (known gaps): Mochi's speech bubbles don't show while it's out (the plan's lines are skipped), and
// the carry swings around Mochi's feet rather than its scruff.
//
// Development: `MOCHI_DESKTOP_ADVENTURE_DEMO=<seconds>` sets off every so many seconds while the screen can be seen, for
// checking and measuring on a PC (with the `perf-debug` meter).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_art/mochi_art.dart' show PetAnimation, PetEyes, PetPose, Brows;
import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/desktop_settings.dart';
import '../../core/mischief.dart';
import '../../core/pc_rhythm.dart';
import '../../platform/displays.dart';
import '../../platform/native_stage.dart';
import '../../platform/taskbar.dart' show PixelRect;
import '../../platform/window_frames.dart';
import '../pet/stroller.dart';
import '../pet/taskbar_stroll.dart' show PetHome;
import 'stage_pet.dart';

/// One display as the planner sees it: logical pixels (the display's scale taken out), x to the right and y up from the
/// display's bottom edge. The one place physical pixels (what Windows and the stage speak) and the planner's numbers
/// meet, both ways.
class AdventureSpace {
  const AdventureSpace(this.display);

  final DisplayArea display;

  double get scale => display.scale;
  PixelRect get monitor => display.monitor;

  /// The physical pixel ([px], [py]) as a planner point.
  w.AdventurePoint point(num px, num py) => w.AdventurePoint((px - monitor.left) / scale, (monitor.bottom - py) / scale);

  /// A planner point as a physical pixel.
  (int, int) feet(w.AdventurePoint point) => ((monitor.left + point.x * scale).round(), (monitor.bottom - point.y * scale).round());

  /// A physical rectangle as a planner one.
  w.AdventureRect rect(PixelRect r) => w.AdventureRect((r.left - monitor.left) / scale, (monitor.bottom - r.bottom) / scale, r.width / scale, r.height / scale);

  /// The whole display.
  w.AdventureRect get screen => rect(monitor);

  /// Where Mochi may be: the display without its taskbar.
  w.AdventureRect get bounds => rect(display.workArea);

  /// The taskbar runs along this display's bottom (its top is the floor).
  bool get taskbarAtBottom => monitor.bottom - display.workArea.bottom > 0 && display.workArea.top == monitor.top;

  /// What Mochi can walk on here: the floor is the top of the taskbar when it runs along the bottom (its middle stretch
  /// is the Mac's "dock"), else the work area's bottom; the ledges are the tops of [windows] (front to back).
  w.AdventureTerrain terrain(List<PixelRect> windows, w.AdventureMetrics metrics) {
    final area = bounds;
    final width = monitor.width / scale;
    final dock = taskbarAtBottom ? w.AdventureSpan(width * 0.22, width * 0.78) : null;
    return w.AdventureTerrain(bounds: area, floorY: area.minY, dock: dock, windows: [for (final window in windows) rect(window)], headroom: metrics.height + 6);
  }
}

/// How asking for an adventure went.
enum AdventureStart {
  /// Off it goes.
  started,

  /// It was out: it's on its way home.
  headingHome,

  /// Adventures are off (Settings › Fun).
  off,

  /// A rule says no now ([DesktopAdventure.why]).
  resting,

  /// Mochi isn't showing on the taskbar, or there's no display to go out on.
  nowhere,
}

/// Mochi hanging from the pointer by the scruff.
class _Carry {
  _Carry({required this.startedAt, required this.facing, required this.lastX, required this.lastTime});

  final double startedAt;
  final double facing;
  double swing = 0;
  double swingSpeed = 0;
  double lastX;
  double lastTime;
}

/// One trip off the taskbar.
class _Outing {
  _Outing({
    required this.space,
    required this.terrain,
    required this.metrics,
    required this.seed,
    required this.homeFeet,
    required this.patchWasHere,
  });

  final AdventureSpace space;
  w.AdventureTerrain terrain;
  final w.AdventureMetrics metrics;
  w.AdventurePlan? plan;
  _Carry? carry;
  int seed;

  /// Where Mochi comes home to (physical pixels), when this display is the taskbar's.
  (int, int)? homeFeet;
  final bool patchWasHere;
  bool hurrying = false;

  /// The windows at the last survey, front to back (what a ledge's window number points into).
  List<WindowFrame> windows = const [];
}

class DesktopAdventure extends ChangeNotifier {
  DesktopAdventure({
    required this.pet,
    required this.home,
    required this.gate,
    required this.rhythm,
    required this.displays,
    required this.windows,
    required this.settings,
    required this.world,
    required this.time,
    required this.shown,
    required this.cursor,
    this.busy = _never,
    this.needsYou = _never,
    this.asleep = _never,
    this.patchHere = _never,
    this.yielding = _nobody,
    this.onMenu,
    this.onPet,
    this.demo,
    int? seed,
  }) : scheduler = w.AdventureScheduler(seed: seed ?? world.seed, frequency: settings.adventure.spontaneous);

  final StagePet pet;
  final PetHome home;
  final MischiefGate gate;
  final PcRhythm rhythm;
  final Displays displays;
  final WindowFrames windows;
  final DesktopSettings settings;
  final w.MochiWorld world;

  /// The world's clock (seconds): Mochi's poses and the plan's times.
  final double Function() time;

  /// The pet shows (not Mochi's window or the popover, and not hidden).
  final bool Function() shown;

  /// Where the pointer is (physical pixels; read only).
  final (int, int)? Function() cursor;

  /// A Claude session is working or waiting; one waits for you.
  final bool Function() busy;
  final bool Function() needsYou;

  /// Mochi's world says it's napping.
  final bool Function() asleep;

  /// Patch is around (he arriving sends Mochi home, as on the Mac).
  final bool Function() patchHere;

  /// The cursor buddy or the screen roamer lets go of Mochi where it stands (it stays out) and says where; null when
  /// neither had it.
  final (int, int)? Function() yielding;

  /// A right-click on Mochi, and a click that pets it.
  final void Function(int x, int y)? onMenu;
  final void Function()? onPet;

  /// Development: sets off every so often while the screen can be seen.
  final Duration? demo;

  /// When it sets off by itself.
  final w.AdventureScheduler scheduler;

  static bool _never() => false;
  static (int, int)? _nobody() => null;

  /// How often windows are read while Mochi is out (per second), and how often it is drawn moving and holding.
  static const double surveyRate = 3;
  static const Duration moveEvery = Duration(milliseconds: 33);
  static const Duration holdEvery = Duration(milliseconds: 125);

  /// How often the rules are looked at while Mochi is out, and how often quiet time is counted for a spontaneous start.
  static const Duration checkEvery = Duration(seconds: 2);
  static const Duration countEvery = Duration(seconds: 5);

  /// How big Mochi is out here (logical pixels per art unit: about 50 tall at 100%, as the cursor buddy).
  static const double unit = 0.95;

  /// A press that moves this far (logical pixels) lifts Mochi.
  static const double liftAfter = 6;

  _Outing? _outing;
  bool _started = false;
  int _ticks = 0;
  Timer? _frames, _survey, _check, _count, _demo;
  Duration? _every;
  StreamSubscription<StagePointer>? _clicks;
  StreamSubscription<void>? _changes;
  (int, int)? _pressedAt;
  bool _lifted = false;
  (int, int)? _pointer;
  MischiefPause? _why;

  /// Surveys of other windows' frames so far (tests, the perf meter).
  int surveys = 0;

  /// Mochi is out on an adventure.
  bool get active => _outing != null;

  /// Mochi is hanging from the pointer.
  bool get carried => _outing?.carry != null;

  /// The adventure's plan (tests).
  w.AdventurePlan? get plan => _outing?.plan;

  /// What it can walk on now (tests).
  w.AdventureTerrain? get terrain => _outing?.terrain;

  /// The display it's on, as the planner sees it (tests).
  AdventureSpace? get space => _outing?.space;

  /// Where its feet are now (physical pixels), or null while it isn't out.
  (int, int)? get feet => active ? pet.feet : null;

  /// How often it's drawn now (null: not at all), and whether windows are being read.
  Duration? get every => _frames == null ? null : _every;
  bool get surveying => _survey != null;

  /// Quiet time is being counted towards setting off by itself (tests: no timer while it can't happen).
  bool get counting => _count != null;

  /// The rule that said no at the last asking (null: none did).
  MischiefPause? get why => _why;

  /// Starts watching for when Mochi may set off by itself.
  void start() {
    if (_started) return;
    _started = true;
    gate.settings.addListener(consider);
    rhythm.addListener(consider);
    gate.motion.addListener(consider);
    home.addListener(consider);
    final demo = this.demo;
    if (demo != null) {
      _demo = Timer.periodic(demo, (_) {
        if (!rhythm.unseen && !active) explore();
      });
    }
    consider();
  }

  // ---- ways to set off ----

  /// Explore from the popover, the tray menu or Settings, or "go explore"; while Mochi is out, the same call brings it home.
  AdventureStart explore() {
    if (active) {
      comeHome();
      return AdventureStart.headingHome;
    }
    if (!settings.adventure.enabled) return AdventureStart.off;
    final blocked = _why = gate.whyAdventure();
    if (blocked != null) return AdventureStart.resting;
    return _setOff() ? AdventureStart.started : AdventureStart.nowhere;
  }

  /// Mochi hurries home (one big leap up out of the screen, then it's on the taskbar). False when it isn't out.
  bool comeHome() {
    final outing = _outing;
    if (outing == null) return false;
    if (outing.carry != null) {
      _finish(null);
      return true;
    }
    final plan = outing.plan;
    if (plan == null || outing.hurrying) return true;
    outing.plan = w.AdventurePlanner.hurryHome(plan, at: time(), terrain: outing.terrain, metrics: outing.metrics);
    outing.hurrying = true;
    _schedule(moveEvery);
    notifyListeners();
    return true;
  }

  /// Mochi was dropped off the taskbar with its feet at [x], [y] (physical pixels): with Adventures on, it falls from there
  /// onto what's below and explores. False when it doesn't (the drop is left to the taskbar as before).
  bool dropped(int x, int y) {
    if (active || !settings.adventure.enabled) return false;
    if ((_why = gate.whyAdventure()) != null) return false;
    return _setOff(from: (x, y), drop: true);
  }

  /// The wording for [start], for Ask Mochi and the notices ([pet] is Mochi's name).
  static String say(AdventureStart start, String pet, MischiefPause? why) => switch (start) {
    AdventureStart.started => 'Off to explore your desktop!',
    AdventureStart.headingHome => 'Coming home!',
    AdventureStart.off => 'Adventures are off. Turn them on in Settings › Fun to let $pet explore.',
    AdventureStart.resting => why?.note(pet) ?? '$pet stays home.',
    AdventureStart.nowhere => '$pet can only set off from the taskbar while it’s showing.',
  };

  /// Sets Mochi off from [from] (physical pixels; where it stands on the taskbar when null, or where another extra had
  /// it). [drop]: it was just let go off the taskbar.
  bool _setOff({(int, int)? from, bool drop = false}) {
    if (active) return false;
    final list = displays.list();
    if (list.isEmpty) return false;
    final departure = home.departure();
    (int, int)? start = from;
    var taken = false;
    if (!drop) {
      final other = yielding();
      if (other != null) {
        start = other;
        taken = true;
      } else if (!shown() || !home.canGoOut || departure == null) {
        return false;
      }
    }
    start ??= departure == null ? null : (departure.x, departure.y);
    if (start == null) return false;
    final here = _displayAt(list, start.$1, start.$2);
    if (here == null) return false;
    final space = AdventureSpace(here);
    final metrics = w.AdventureMetrics();
    final frames = windows.list();
    if (w.AdventureTerrain.looksFullScreen(windows: [for (final frame in frames) space.rect(frame.frame)], screen: space.screen)) return false;
    final terrain = space.terrain([for (final frame in frames) frame.frame], metrics);
    // Home is where it left the taskbar, when that is on this display.
    (int, int)? homeFeet;
    if (departure != null) {
      final left = _displayAt(list, departure.x, departure.y);
      if (left != null && left.key == here.key) homeFeet = (departure.x, departure.y);
    }
    final homeX = homeFeet == null ? space.point(start.$1, start.$2).x : space.point(homeFeet.$1, homeFeet.$2).x;
    final bounds = space.bounds;
    final bar = w.AdventureSpan(math.max(bounds.minX + metrics.halfWidth, homeX - 60), math.min(bounds.maxX - metrics.halfWidth, homeX + 60));
    final now = time();
    final outing = _Outing(
      space: space,
      terrain: terrain,
      metrics: metrics,
      seed: world.seed + (now * 1000).round(),
      homeFeet: homeFeet,
      patchWasHere: patchHere(),
    );
    final point = space.point(start.$1, start.$2);
    // Out of the taskbar: a little hop up and down; from a hand or another extra: from where it is.
    final begin = drop || taken ? point : w.AdventurePoint(point.x, terrain.floorY + metrics.height * 0.6);
    outing.plan = w.AdventurePlanner.plan(
      from: begin,
      at: now,
      terrain: terrain,
      bar: bar,
      seed: outing.seed,
      metrics: metrics,
      facing: departure?.facing ?? 1,
    );
    _outing = outing;
    outing.windows = frames;
    _pointer = null;
    _pressedAt = null;
    _lifted = false;
    scheduler.reset();
    world.setAdventureActive(true);
    if (!taken) home.goOut();
    _clicks = pet.stage.pointer.where((event) => event.actor == pet.actor).listen(_pointerEvent);
    _changes = pet.stage.displaysChanged.listen((_) => _displaysChanged());
    _survey = Timer.periodic(Duration(milliseconds: (1000 / surveyRate).round()), (_) => _look());
    _check = Timer.periodic(checkEvery, (_) => consider());
    _count?.cancel();
    _count = null;
    _tick();
    notifyListeners();
    return true;
  }

  // ---- by itself ----

  /// Looks again: whether quiet time is being counted, whether Mochi goes on, or goes home.
  void consider() {
    if (!_started) return;
    final outing = _outing;
    if (outing == null) {
      _watchForSpontaneity();
      return;
    }
    final blocked = _why = gate.whyAdventure();
    final adventure = settings.adventure;
    if (blocked == MischiefPause.unseen ||
        blocked == MischiefPause.fullScreen ||
        blocked == MischiefPause.calm ||
        blocked == MischiefPause.unsupported ||
        !shown()) {
      return _homeNow();
    }
    final arrived = patchHere() && !outing.patchWasHere;
    if (blocked != null || needsYou() || arrived || !adventure.enabled) comeHome();
  }

  /// Counts eligible time every few seconds while it might set off by itself; no timer otherwise (never, off, or the screen
  /// is unseen).
  void _watchForSpontaneity() {
    final adventure = settings.adventure;
    final counting = _started && gate.supported && adventure.enabled && adventure.spontaneous != w.AdventureFrequency.never && !rhythm.unseen;
    if (!counting) {
      _count?.cancel();
      _count = null;
      return;
    }
    _count ??= Timer.periodic(countEvery, (_) => _counted());
  }

  void _counted() {
    final adventure = settings.adventure;
    final eligible =
        adventure.enabled &&
        !active &&
        !home.out &&
        !busy() &&
        !asleep() &&
        shown() &&
        home.canGoOut &&
        (_why = gate.whyAdventure()) == null;
    if (scheduler.tick(now: time(), eligible: eligible, frequency: adventure.spontaneous)) _setOff();
  }

  // ---- the walk ----

  void _tick() {
    final outing = _outing;
    if (outing == null) return;
    final now = time();
    _ticks++;
    final space = outing.space;
    final carry = outing.carry;
    if (carry != null) {
      _drawCarried(outing, carry, now);
      _schedule(moveEvery);
      return;
    }
    final plan = outing.plan;
    if (plan == null) return;
    final sample = plan.sample(now);
    final top = outing.terrain.bounds.maxY;
    if (sample.finished || (sample.phase == w.AdventurePhase.returning && sample.isAirborne && sample.point.y > top + outing.metrics.height * 0.15)) {
      _finish(plan.homeX);
      return;
    }
    pet.draw(
      time: now,
      motion: _motion(sample, now),
      feet: space.feet(sample.point),
      ratio: space.scale,
      unit: unit,
      quantum: 1 / 15,
      accent: (pose) => accent(pose, sample),
    );
    if (_ticks % 60 == 0) pet.raise();
    final still = sample.move == w.AdventureMove.hold && (sample.style == w.AdventureStyle.plain);
    _schedule(still ? holdEvery : moveEvery);
  }

  /// What Mochi does at [sample], as the director wants it: gaits locked to the distance walked, one-shots from their
  /// start, loops on the clock.
  StrollSample _motion(w.AdventureSample sample, double now) {
    final animation = sample.animation;
    if (animation == PetAnimation.walk || animation == PetAnimation.run) {
      final gait = animation == PetAnimation.run ? const StrollTuning().runGait : const StrollTuning().walkGait;
      return StrollSample(
        x: 0,
        facing: sample.facing,
        animation: animation,
        animationTime: sample.odometer / gait,
        activity: StrollActivity.trot,
        travelling: true,
      );
    }
    if (animation.isLoop) {
      return StrollSample(
        x: 0,
        facing: sample.facing,
        animation: animation,
        animationTime: now,
        activity: animation == PetAnimation.sit ? StrollActivity.rest : StrollActivity.watch,
      );
    }
    return StrollSample(
      x: 0,
      facing: sample.facing,
      animation: animation,
      animationTime: sample.elapsed,
      activity: StrollActivity.react,
      oneShot: true,
    );
  }

  /// The body language the plan's styles ask for (crouches, take-offs, flight, landings, the climb), on a coarse grid so
  /// each different pose is not a new picture (the Mac's AdventureLook.accent).
  @visibleForTesting
  static void accent(PetPose pose, w.AdventureSample sample) {
    double grid(double value, double step) => (value / step).round() * step;
    final p = sample.progress;
    switch (sample.style) {
      case w.AdventureStyle.crouch:
        final amount = grid(w.Ease.smooth(w.Ease.segment(p, 0, 0.6)), 0.25);
        pose.scaleY *= 1 - 0.1 * amount;
        pose.scaleX *= 1 + 0.06 * amount;
        pose.earPerk = math.min(pose.earPerk, -0.2);
      case w.AdventureStyle.launch:
        final push = grid(math.max(0, 1 - sample.elapsed / 0.16), 0.5);
        pose.scaleY *= 1 + 0.08 * push;
        pose.scaleX *= 1 - 0.05 * push;
        pose.earPerk = math.max(pose.earPerk, 0.6);
        pose.leftArm = math.max(pose.leftArm, 0.5);
        pose.rightArm = math.max(pose.rightArm, 0.5);
      case w.AdventureStyle.drop:
        pose.scaleY *= 1.06;
        pose.scaleX *= 0.96;
        pose.leftArm = math.max(pose.leftArm, 0.55);
        pose.rightArm = math.max(pose.rightArm, 0.55);
        pose.earPerk = 0.9;
        pose.eyes = PetEyes.wide;
      case w.AdventureStyle.land:
        final squash = grid(math.pow(1 - p, 1.5).toDouble(), 0.25);
        pose.scaleY *= 1 - 0.14 * squash;
        pose.scaleX *= 1 + 0.1 * squash;
      case w.AdventureStyle.notice:
        pose.earPerk = math.max(pose.earPerk, 0.85);
        pose.brows = Brows.raised;
        if (p < 0.6) pose.eyes = PetEyes.wide;
      case w.AdventureStyle.plain:
        break;
    }
    if (sample.move == w.AdventureMove.climb) {
      // Paw over paw up the edge, looking up where it is going.
      final phase = grid(sample.odometer / 10 % (2 * math.pi), math.pi / 4);
      pose.leftArm = 0.78 + 0.22 * math.sin(phase);
      pose.rightArm = 0.78 - 0.22 * math.sin(phase);
      pose.y += 0.035 * math.sin(phase).abs();
      pose.lookX = 0.35 * sample.facing;
      pose.lookY = -0.55;
      pose.earPerk = math.max(pose.earPerk, 0.5);
    }
    pose.rotation = grid(sample.rotation, 0.02);
    if (sample.isAirborne) pose.shadow = 0.3;
    if (sample.phase == w.AdventurePhase.climbing || sample.phase == w.AdventurePhase.returning) pose.shadow = 0;
  }

  void _schedule(Duration every) {
    if (every == _every && _frames != null) return;
    _frames?.cancel();
    _every = every;
    _frames = Timer.periodic(every, (_) => _tick());
  }

  void _stopFrames() {
    _frames?.cancel();
    _frames = null;
    _every = null;
  }

  // ---- windows ----

  /// A few times a second while out: windows moved, opened or closed? Re-route if the ground changed.
  void _look() {
    final outing = _outing;
    if (outing == null || rhythm.unseen) return;
    surveys++;
    final frames = windows.list();
    final space = outing.space;
    if (w.AdventureTerrain.looksFullScreen(windows: [for (final frame in frames) space.rect(frame.frame)], screen: space.screen)) {
      _homeNow();
      return;
    }
    outing.windows = frames;
    final terrain = space.terrain([for (final frame in frames) frame.frame], outing.metrics);
    if (terrain == outing.terrain) return;
    outing.terrain = terrain;
    final plan = outing.plan;
    if (plan == null) return;
    final adapted = w.AdventurePlanner.adapt(plan, at: time(), to: terrain, metrics: outing.metrics);
    if (adapted != null) {
      outing.plan = adapted;
      _schedule(moveEvery);
    }
  }

  // ---- ending ----

  /// Home on the taskbar at once.
  void _homeNow() => _finish(null);

  void _displaysChanged() {
    final outing = _outing;
    if (outing == null) return;
    final now = displays.list();
    if (!now.any((display) => display.key == outing.space.display.key)) _homeNow();
  }

  /// Back on the taskbar: the stage closes and every timer stops. [homeX] (the planner's x on this display) is where Mochi
  /// stands there; null: where it left.
  void _finish(double? homeX, {int? px}) {
    final outing = _outing;
    if (outing == null) return;
    _outing = null;
    _pressedAt = null;
    _lifted = false;
    _stopFrames();
    _survey?.cancel();
    _survey = null;
    _check?.cancel();
    _check = null;
    unawaited(_clicks?.cancel());
    _clicks = null;
    unawaited(_changes?.cancel());
    _changes = null;
    pet.hide();
    world.setAdventureActive(false);
    int? x = px;
    if (x == null && homeX != null && outing.homeFeet != null) x = outing.space.feet(w.AdventurePoint(homeX, 0)).$1;
    home.comeBack(x: x ?? outing.homeFeet?.$1);
    _watchForSpontaneity();
    notifyListeners();
  }

  // ---- the carry ----

  /// Hanging from the pointer by the scruff, legs paddling, swinging behind the pointer's sideways moves.
  void _drawCarried(_Outing outing, _Carry carry, double now) {
    final space = outing.space;
    final pointer = cursor() ?? _pointer;
    if (pointer == null) return;
    _pointer = pointer;
    // A pendulum: Mochi swings behind the pointer's sideways moves and settles.
    final dt = math.max(1 / 120, math.min(0.1, now - carry.lastTime));
    final velocity = (pointer.$1 - carry.lastX) / space.scale / dt;
    final target = math.max(-0.6, math.min(0.6, velocity * 0.0012));
    carry.swingSpeed += ((target - carry.swing) * 70 - carry.swingSpeed * 9) * dt;
    carry.swing += carry.swingSpeed * dt;
    carry.lastX = pointer.$1.toDouble();
    carry.lastTime = now;
    // The scruff is at the pointer; the feet hang below it, swung round.
    final hang = outing.metrics.height * 0.95 * space.scale;
    final swing = carry.swing;
    final feet = ((pointer.$1 - hang * math.sin(swing)).round(), (pointer.$2 + hang * math.cos(swing)).round());
    final held = now - carry.startedAt;
    pet.draw(
      time: now,
      motion: StrollSample(x: 0, facing: carry.facing, animation: PetAnimation.idle, animationTime: now, activity: StrollActivity.watch),
      feet: feet,
      ratio: space.scale,
      unit: unit,
      quantum: 1 / 15,
      accent: (pose) {
        double grid(double value, double step) => (value / step).round() * step;
        pose.eyes = held < 0.7 ? PetEyes.wide : PetEyes.happy;
        pose.earPerk = 0.7;
        pose.leftArm = 0.35;
        pose.rightArm = 0.35;
        pose.step = grid(0.5 * math.sin(held * 7).abs(), 0.125);
        pose.tailWag += grid(1.5 * math.sin(now * 5), 0.25);
        pose.shadow = 0;
        pose.effects = [];
        pose.rotation = grid(swing, 0.03);
      },
    );
    if (_ticks % 60 == 0) pet.raise();
  }

  /// Let go at [at] (physical pixels): on the taskbar it's home; anywhere else it falls to what's below and carries on.
  void _release((int, int) at) {
    final outing = _outing;
    final carry = outing?.carry;
    if (outing == null || carry == null) return;
    final space = outing.space;
    final display = space.display;
    // Over the taskbar of the display it came from: home.
    if (space.taskbarAtBottom && outing.homeFeet != null && display.monitor.contains(at.$1, at.$2) && at.$2 >= display.workArea.bottom) {
      _finish(null, px: at.$1);
      return;
    }
    if (!display.monitor.contains(at.$1, at.$2)) {
      _finish(null);
      return;
    }
    final scruff = space.point(at.$1, at.$2);
    final feet = w.AdventurePoint(scruff.x, scruff.y - outing.metrics.height * 0.95);
    outing.seed += 0x9E37;
    final bounds = space.bounds;
    final homeX = outing.homeFeet == null ? scruff.x : space.point(outing.homeFeet!.$1, outing.homeFeet!.$2).x;
    final bar = w.AdventureSpan(math.max(bounds.minX + outing.metrics.halfWidth, homeX - 60), math.min(bounds.maxX - outing.metrics.halfWidth, homeX + 60));
    outing.terrain = space.terrain([for (final frame in windows.list()) frame.frame], outing.metrics);
    outing.plan = w.AdventurePlanner.plan(
      from: feet,
      at: time(),
      terrain: outing.terrain,
      bar: bar,
      seed: outing.seed,
      metrics: outing.metrics,
      length: (25, 45),
      facing: carry.facing,
    );
    outing.carry = null;
    outing.hurrying = false;
    _lifted = false;
    _tick();
  }

  /// Clicks on Mochi out on the desktop: a click pets it, a drag lifts it, a right-click is its menu.
  void _pointerEvent(StagePointer event) {
    final outing = _outing;
    if (outing == null) return;
    final at = (event.screenX, event.screenY);
    switch (event.kind) {
      case StagePointerKind.down:
        _pressedAt = at;
        _lifted = false;
      case StagePointerKind.move:
        final pressed = _pressedAt;
        if (pressed == null) return;
        if (outing.carry != null) {
          _pointer = at;
          return;
        }
        final far = ((at.$1 - pressed.$1).abs() + (at.$2 - pressed.$2).abs()) > liftAfter * outing.space.scale;
        if (_lifted || !far || outing.plan == null) return;
        _lifted = true;
        outing.carry = _Carry(startedAt: time(), facing: outing.plan!.sample(time()).facing, lastX: at.$1.toDouble(), lastTime: time());
        outing.plan = null;
        _pointer = at;
        _tick();
      case StagePointerKind.up:
        final pressed = _pressedAt;
        _pressedAt = null;
        if (pressed == null) return;
        if (_lifted) {
          _lifted = false;
          _release(at);
          return;
        }
        onPet?.call();
        final plan = outing.plan;
        if (plan != null) {
          final petted = w.AdventurePlanner.interject(PetAnimation.happyBounce, into: plan, at: time());
          if (petted != null) {
            outing.plan = petted;
            _schedule(moveEvery);
          }
        }
      case StagePointerKind.rightUp:
        onMenu?.call(event.screenX, event.screenY);
      case StagePointerKind.cancel:
        _pressedAt = null;
        if (_lifted) {
          _lifted = false;
          _release(_pointer ?? at);
        }
      default:
        break;
    }
  }

  // ---- places ----

  static DisplayArea? _displayAt(List<DisplayArea> list, int x, int y) {
    if (list.isEmpty) return null;
    for (final display in list) {
      if (display.monitor.contains(x, y)) return display;
    }
    return PetPlacing.primaryOf(list);
  }

  /// What it's up to, for the perf meter (null: not out).
  String? perfState() {
    final outing = _outing;
    if (outing == null) return null;
    if (outing.carry != null) return 'adventure (carried)';
    final plan = outing.plan;
    if (plan == null) return 'adventure';
    if (outing.hurrying) return 'adventure (heading home)';
    return 'adventure (${plan.sample(time()).phase.title})';
  }

  void stop() {
    if (_started) {
      gate.settings.removeListener(consider);
      rhythm.removeListener(consider);
      gate.motion.removeListener(consider);
      home.removeListener(consider);
    }
    _started = false;
    _demo?.cancel();
    _demo = null;
    _count?.cancel();
    _count = null;
    if (active) _finish(null);
  }
}
