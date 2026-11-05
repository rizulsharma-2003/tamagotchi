// Mochi strolling inside Windows' taskbar, as it walks inside the menu bar on the Mac (MenuBarOverlayController,
// MenuBarStageView): the glue between the stroll's plan (stroller.dart), the taskbar (platform/taskbar.dart) and the
// pet's window.
//
// - Mochi roams while "Roam along the taskbar" is on and the main screen's taskbar is at the bottom and doesn't hide
//   itself. Otherwise the pet stands still where it was left (bottom left at first), as before.
// - On the taskbar Mochi is drawn at the taskbar's size (40 pixels tall in a 48-pixel taskbar, scaled with the
//   display), and the window is just Mochi's box, vertically centred in the taskbar. A speech bubble grows the window
//   upwards, above the taskbar, and it shrinks back after.
// - It walks only in the taskbar's empty stretches (between the widgets tile and the buttons, and between the buttons
//   and the tray), measured with UI Automation every few seconds; it hops between stretches, never over a button.
// - The window lets clicks through to the taskbar everywhere but on Mochi itself: the pointer is checked 10 times a
//   second, and the window takes clicks only while it's over Mochi (to pet, open or drag it). The same check puts the
//   window back on top of the taskbar every half second, and at once when the taskbar is clicked (it rises over other
//   always-on-top windows then). Nothing here ever takes the focus.
// - While Mochi walks, the window moves 25 times a second (Win32 SetWindowPos, without activating it); while it sits,
//   watches or naps there's no frame timer at all, only a wake-up for when it next sets off.
// - Dragging Mochi along the taskbar moves it there; dragging it off the taskbar turns roaming off and leaves it where
//   it's dropped, until roaming is turned on again (Settings, or "Back to the taskbar" in the tray menu).
// - Animation effects off: Mochi stays put on the taskbar (expressions only).
// - A full-screen app or a presentation (SHQueryUserNotificationState) hides the pet until it's over.
// - The taskbar is looked at again every 10 seconds and after display or DPI changes.
//
// Every change to the window, the main window's included, goes through `show` and one queue here, so a pet placement
// never interleaves with the main window opening.
//
// The macOS development build has no taskbar (and no Win32 window), so the pet stands still there; the stroll itself
// is tested with fakes (test/stroll_test.dart).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../core/desktop_settings.dart';
import '../../core/pet_cues.dart';
import '../../platform/system.dart';
import '../../platform/taskbar.dart';
import '../shell.dart';
import 'pet_director.dart';
import 'stroller.dart';

/// Where the pet's window is.
enum PetPlacement {
  /// The pet isn't showing (the main window, or nothing).
  away,

  /// Standing still where it was left.
  standing,

  /// Strolling inside the taskbar.
  taskbar,

  /// Out of the way of a full-screen app or a presentation.
  hidden,
}

class TaskbarStroll extends ChangeNotifier with WidgetsBindingObserver {
  TaskbarStroll({
    required this.shell,
    required this.taskbar,
    required this.settings,
    required this.motion,
    required Stream<PetCue> cues,
    Duration Function()? idle,
    double Function()? clock,
    math.Random? random,
    StrollTuning tuning = const StrollTuning(),
    this.frameInterval = const Duration(milliseconds: 40),
    this.pointerInterval = const Duration(milliseconds: 100),
    this.checkInterval = const Duration(seconds: 2),
    this.taskbarChecks = 5,
    this.measureChecks = 3,
    this.log,
  }) : _idle = idle ?? (() => Duration.zero),
       _clock = clock ?? _monotonic(),
       stroller = Stroller(random: random, tuning: tuning),
       _roaming = settings.roamTaskbar {
    _cues = cues.listen(_cue);
    settings.addListener(_settingsChanged);
    motion.addListener(_motionChanged);
  }

  final DesktopShell shell;
  final TaskbarInfo taskbar;
  final DesktopSettings settings;
  final SystemMotion motion;
  final Stroller stroller;

  /// How often the window moves while Mochi walks.
  final Duration frameInterval;

  /// How often the pointer is checked (click-through, staying on top) while Mochi is on the taskbar.
  final Duration pointerInterval;

  /// How often full-screen apps are checked for; the taskbar is read every [taskbarChecks] of these, and its buttons
  /// measured every [measureChecks].
  final Duration checkInterval;
  final int taskbarChecks;
  final int measureChecks;

  /// The pointer checks between two raises of the window over the taskbar.
  static const int raiseEvery = 5;

  /// Development: what the stroll sees and does (a `stroll-debug` file in Mochi's folder turns it on).
  final void Function(String message)? log;

  final Duration Function() _idle;
  final double Function() _clock;
  late final StreamSubscription<PetCue> _cues;

  Surface _surface = Surface.hidden;
  PetPlacement _placement = PetPlacement.away;
  RoamBlock? _block;
  TaskbarStage? _stage;
  PixelRect? _frame;
  List<PixelRect>? _buttons;
  bool _measured = false;
  bool _measuring = false;
  PetMood _mood = PetMood.relaxed;
  bool _roaming;
  bool _bubble = false;
  bool _dragging = false;
  bool _parking = false;
  bool _fullscreen = false;
  bool _resizing = false;
  bool _observing = false;
  bool _disposed = false;
  bool? _clickThrough;
  bool _taskbarWasInFront = false;
  int _checks = 0;
  int _pointerChecks = 0;
  Timer? _frameTimer;
  Timer? _wakeTimer;
  Timer? _pointerTimer;
  Timer? _checkTimer;
  Timer? _metricsTimer;
  Future<void> _queue = Future.value();

  static double Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds / 1e6;
  }

  PetPlacement get placement => _placement;
  bool get onTaskbar => _placement == PetPlacement.taskbar;

  /// Why Mochi isn't roaming (null while it is, or could: a full-screen app only hides it for a while).
  RoamBlock? get block => _block;

  /// The taskbar as Mochi's stage, while it's on it.
  TaskbarStage? get stage => onTaskbar ? _stage : null;

  /// Mochi's box on the taskbar (logical pixels): its window without a bubble.
  Size get box => _stage?.box ?? const Size(64, 40);

  /// The window's size on the taskbar right now: Mochi's box, or wider and taller with a bubble above it.
  Size get windowSize => _bubble ? Size(SurfaceSizes.taskbarBubbleWidth, box.height + SurfaceSizes.bubble) : box;

  /// Where the window is on the taskbar (physical pixels), while it's there.
  PixelRect? get frame => onTaskbar ? _frame : null;

  /// Clicks go through the window right now (null before Mochi was first on the taskbar).
  bool? get clickThrough => _clickThrough;

  /// The timers that are running, for tests: moving Mochi, waiting for its next move, watching the pointer.
  bool get moving => _frameTimer != null;
  bool get waiting => _wakeTimer != null;
  bool get watchingPointer => _pointerTimer != null;

  double now() => _clock();

  /// Mochi on the taskbar right now (null while it isn't there).
  StrollSample? sample() => onTaskbar && stroller.isPlaced ? stroller.sample(_clock()) : null;

  /// Shows [surface]: the main window or nothing as before, the pet in the taskbar or standing where it was left.
  Future<void> show(Surface surface) {
    _surface = surface;
    if (surface == Surface.pet) {
      _start();
      return _enqueue(_place);
    }
    _stop();
    return _enqueue(() async {
      _leaveTaskbar();
      _placement = PetPlacement.away;
      await shell.show(surface, petPosition: settings.petPosition);
    });
  }

  /// Mochi's mood (from the pet's view): what it does on the taskbar.
  set mood(PetMood mood) {
    if (mood == _mood) return;
    _mood = mood;
    if (onTaskbar) _tick();
  }

  /// A speech bubble shows above Mochi: the window grows upwards to make room for it, and shrinks back after.
  set bubble(bool shown) {
    if (shown == _bubble) return;
    _bubble = shown;
    if (onTaskbar) unawaited(_enqueue(_resize));
  }

  /// Mochi is being dragged: it holds still (and nothing else moves the window) until [dragEnded].
  void dragStarted() {
    _dragging = true;
    _halt();
    _setClickThrough(false);
    if (onTaskbar) stroller.react(_clock(), double.infinity);
  }

  /// The drag ended with the window's top-left at [to] (logical pixels, as window_manager reports it). Dropped on the
  /// taskbar, Mochi carries on from there (in the nearest free stretch); dropped off it, roaming turns off and Mochi
  /// stays where it was dropped. A nudge that left it where it was just carries on.
  void dragEnded(Offset? to) {
    _dragging = false;
    if (onTaskbar) {
      final stage = _stage;
      final frame = _frame;
      if (to != null && stage != null && frame != null && (to - stage.logical(frame)).distance > 6) {
        final size = Size(frame.width / stage.scale, frame.height / stage.scale);
        final feet = Offset(to.dx + size.width / 2, to.dy + size.height);
        if (feet.dy * stage.scale > stage.bar.top + stage.bar.height / 2) {
          // Still on the taskbar: carry on from there.
          stroller.place(_zones(stage), now: _clock(), x: feet.dx, mode: _mode, idleSeconds: _idleSeconds);
          _frame = PixelRect.ltwh((to.dx * stage.scale).round(), (to.dy * stage.scale).round(), frame.width, frame.height);
          unawaited(_enqueue(_resize));
          _tick();
          return;
        }
        _parking = true;
        try {
          settings.petPosition = standingSpot(feet, stage);
          settings.roamTaskbar = false;
        } finally {
          _parking = false;
        }
        return;
      }
      stroller.resume(_clock());
      _tick();
    } else if (to != null && _placement == PetPlacement.standing) {
      settings.petPosition = to;
    }
  }

  /// The standing pet's window position (logical) with Mochi's feet at [feet], never lower than standing on the
  /// taskbar's top edge (the standing pet is bigger and would cover it).
  static Offset standingSpot(Offset feet, TaskbarStage stage) {
    final standingFeet = SurfaceSizes.pet.height - SurfaceSizes.petStage * SurfaceSizes.standingFeet;
    final top = math.min(feet.dy - standingFeet, stage.bar.top / stage.scale - SurfaceSizes.pet.height);
    return Offset(feet.dx - SurfaceSizes.pet.width / 2, top);
  }

  /// Looks at the taskbar and the settings again.
  Future<void> refresh() => _surface == Surface.pet ? _enqueue(_place) : Future.value();

  // MARK: Placing the window

  Future<void> _enqueue(Future<void> Function() change) {
    final next = _queue.then((_) => change()).catchError((Object error) {
      debugPrint('Mochi: the pet window could not be placed (${error.runtimeType})');
    });
    _queue = next;
    return next;
  }

  /// A full-screen app or a presentation has the screen (asked only where the pet's window is a Win32 one).
  bool _fullscreenBusy() => taskbar.available && shell.petWindow != null && taskbar.fullscreenBusy();

  /// Roaming is on and there's a taskbar and a window to move.
  bool get _canRoam => settings.roamTaskbar && taskbar.available && shell.petWindow != null;

  ({TaskbarStage? stage, RoamBlock? block}) _evaluate() {
    if (!settings.roamTaskbar) return (stage: null, block: RoamBlock.turnedOff);
    if (!taskbar.available || shell.petWindow == null) return (stage: null, block: RoamBlock.unsupported);
    return TaskbarStage.of(taskbar.read(), buttons: _buttons);
  }

  Future<void> _place() async {
    if (_surface != Surface.pet || _disposed) return;
    // The first time, find the buttons before choosing where Mochi goes (an estimate stands in if that's slow).
    if (!_measured && _canRoam) {
      await _measure().timeout(const Duration(seconds: 2), onTimeout: () {});
      if (_surface != Surface.pet || _disposed) return;
    }
    final (:stage, :block) = _evaluate();
    final changed = block != _block;
    _block = block;
    if (changed || stage != _stage) log?.call('place: $stage block=$block buttons=${_buttons?.length} fullscreen=$_fullscreen');
    if (_fullscreen) {
      if (_placement != PetPlacement.hidden) {
        _leaveTaskbar();
        _placement = PetPlacement.hidden;
        await shell.show(Surface.hidden);
        _notify();
      }
    } else if (stage == null) {
      if (_placement != PetPlacement.standing) {
        _leaveTaskbar();
        stroller.clear();
        _stage = null;
        _placement = PetPlacement.standing;
        await shell.show(Surface.pet, petPosition: settings.petPosition);
        _notify();
      } else if (changed) {
        _notify();
      }
    } else if (_placement != PetPlacement.taskbar || stage != _stage) {
      await _onto(stage);
    } else if (changed) {
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static List<StrollLine> _zones(TaskbarStage stage) => [for (final zone in stage.zones) StrollLine(zone.minX, zone.maxX)];

  /// Puts Mochi in the taskbar: carrying on where it was if it was already strolling (hopping out of a stretch that
  /// buttons now fill), or under where it stood.
  Future<void> _onto(TaskbarStage stage) async {
    final now = _clock();
    final arriving = _placement != PetPlacement.taskbar;
    if (arriving || !stroller.isPlaced) {
      final standing = settings.petPosition;
      final x = stroller.isPlaced || standing == null ? null : standing.dx + SurfaceSizes.pet.width / 2;
      stroller.place(_zones(stage), now: now, x: x, mode: _mode, idleSeconds: _idleSeconds);
    } else {
      stroller.rezone(_zones(stage), now: now);
    }
    _stage = stage;
    final frame = stage.frame(stroller.sample(now).x, windowSize);
    if (arriving) {
      await shell.show(Surface.pet, petPosition: stage.logical(frame), petSize: windowSize);
      if (_surface != Surface.pet) return;
    }
    // Exactly in physical pixels (window_manager rounds through logical ones).
    log?.call('onto: frame=$frame box=${stage.box} arriving=$arriving');
    if (frame != _frame || arriving) await _setFrame(frame);
    if (_disposed || _surface != Surface.pet || _fullscreen) return;
    if (arriving) {
      _placement = PetPlacement.taskbar;
      _pointerTimer ??= Timer.periodic(pointerInterval, (_) => _pointer());
      shell.petWindow?.raise();
      _pointer();
    }
    _notify();
    _tick();
  }

  /// Off the taskbar: the window takes clicks again and nothing watches the pointer.
  void _leaveTaskbar() {
    _halt();
    _pointerTimer?.cancel();
    _pointerTimer = null;
    if (_clickThrough != null) {
      _clickThrough = null;
      shell.petWindow?.settle();
    }
  }

  Future<void> _resize() async {
    final stage = _stage;
    if (!onTaskbar || stage == null) return;
    final frame = stage.frame(stroller.sample(_clock()).x, windowSize);
    if (frame != _frame) await _setFrame(frame);
  }

  Future<void> _setFrame(PixelRect frame) async {
    final window = shell.petWindow;
    if (window == null) return;
    _resizing = true;
    try {
      await window.setFrame(frame);
      _frame = frame;
    } finally {
      _resizing = false;
    }
  }

  /// The taskbar's buttons, through UI Automation (off the UI thread); a change moves Mochi's free stretches.
  Future<void> _measure() async {
    if (_measuring) return;
    _measuring = true;
    try {
      final started = _clock();
      final buttons = await taskbar.buttons();
      log?.call('measure: ${buttons?.length} elements in ${((_clock() - started) * 1000).round()} ms');
      _measured = true;
      if (!_sameRects(buttons, _buttons)) {
        _buttons = buttons;
        if (_surface == Surface.pet) unawaited(_enqueue(_place));
      }
    } finally {
      _measuring = false;
    }
  }

  static bool _sameRects(List<PixelRect>? a, List<PixelRect>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // MARK: Walking

  StrollMode get _mode => StrollMode.of(_mood, reducedMotion: motion.reduced);
  double get _idleSeconds => _idle().inMilliseconds / 1000;

  void _tick() {
    if (_disposed || _surface != Surface.pet || _placement != PetPlacement.taskbar || _dragging) {
      _halt();
      return;
    }
    final now = _clock();
    stroller.update(now, mode: _mode, idleSeconds: _idleSeconds);
    _step(now);
    _schedule(now);
  }

  /// Moves the window under Mochi (a resize on its way does the move itself).
  void _step(double now) {
    final stage = _stage;
    final frame = _frame;
    final window = shell.petWindow;
    if (stage == null || frame == null || window == null || _resizing) return;
    final next = stage.frame(stroller.sample(now).x, windowSize);
    if (next == frame || !next.sameSize(frame)) return;
    window.move(next.left, next.top);
    _frame = next;
  }

  /// A frame timer while Mochi travels; otherwise a single wake-up for when it next sets off (or none).
  void _schedule(double now) {
    if (stroller.travellingAt(now)) {
      _wakeTimer?.cancel();
      _wakeTimer = null;
      _frameTimer ??= Timer.periodic(frameInterval, (_) => _tick());
      return;
    }
    _frameTimer?.cancel();
    _frameTimer = null;
    _wakeTimer?.cancel();
    final at = stroller.nextChange(now);
    _wakeTimer = at == null ? null : Timer(Duration(microseconds: ((at - now) * 1e6).ceil() + 2000), _tick);
  }

  void _halt() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _wakeTimer?.cancel();
    _wakeTimer = null;
  }

  // MARK: The pointer

  /// 10 times a second on the taskbar: clicks reach Mochi only while the pointer is over it (the rest of the window
  /// lets them through to the taskbar), and the window goes back over the taskbar every half second, or at once when
  /// the taskbar was just clicked.
  void _pointer() {
    final window = shell.petWindow;
    final stage = _stage;
    final frame = _frame;
    if (window == null || stage == null || frame == null || !onTaskbar) return;
    _pointerChecks++;
    final inFront = taskbar.taskbarInFront();
    if ((inFront && !_taskbarWasInFront) || _pointerChecks % raiseEvery == 0) window.raise();
    _taskbarWasInFront = inFront;
    final cursor = taskbar.cursor();
    final over = _dragging || (cursor != null && stage.body(frame).contains(cursor.$1, cursor.$2));
    _setClickThrough(!over);
  }

  void _setClickThrough(bool through) {
    if (through == _clickThrough || (_clickThrough == null && !through)) return;
    _clickThrough = through;
    shell.petWindow?.setClickThrough(through);
    log?.call('click-through: $through');
  }

  // MARK: What happens around Mochi

  void _cue(PetCue cue) {
    // Real moments hold Mochi still while they play: news faces you.
    final hold = switch (cue) {
      PetCue.pet => 3.2,
      PetCue.play => 5.0,
      PetCue.treat => 4.4,
      PetCue.finished => 2.6,
      PetCue.snag => 2.4,
      PetCue.replied => 1.0,
      _ => null,
    };
    if (hold == null || !onTaskbar || _dragging) return;
    stroller.react(
      _clock(),
      hold,
      attentive: cue == PetCue.finished || cue == PetCue.snag || cue == PetCue.replied,
    );
    _tick();
  }

  void _settingsChanged() {
    if (settings.roamTaskbar == _roaming) return;
    _roaming = settings.roamTaskbar;
    // Roaming turned off: Mochi stands just above the taskbar where it was (a drag has already said where it went).
    final stage = _stage;
    final frame = _frame;
    if (!_roaming && !_parking && onTaskbar && stage != null && frame != null) {
      final feet = Offset((frame.left + frame.width / 2) / stage.scale, frame.bottom / stage.scale);
      settings.petPosition = standingSpot(feet, stage);
    }
    if (_canRoam) unawaited(_measure());
    unawaited(refresh());
  }

  void _motionChanged() {
    if (onTaskbar) _tick();
  }

  void _start() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    _fullscreen = _fullscreenBusy();
    _checkTimer = Timer.periodic(checkInterval, (_) => _check());
  }

  void _stop() {
    _halt();
    _pointerTimer?.cancel();
    _pointerTimer = null;
    _checkTimer?.cancel();
    _checkTimer = null;
    _metricsTimer?.cancel();
    _metricsTimer = null;
    _fullscreen = false;
    if (_observing) {
      _observing = false;
      WidgetsBinding.instance.removeObserver(this);
    }
  }

  /// Every couple of seconds: a full-screen app; every [taskbarChecks]: the taskbar (it may have moved); every
  /// [measureChecks]: its buttons (an app opened or closed).
  void _check() {
    if (_dragging) return;
    _checks++;
    final busy = _fullscreenBusy();
    if (busy != _fullscreen) {
      _fullscreen = busy;
      unawaited(_enqueue(_place));
      return;
    }
    if (_checks % measureChecks == 0 && _canRoam && !_fullscreen) unawaited(_measure());
    if (_checks % taskbarChecks == 0) unawaited(_enqueue(_place));
  }

  // A display or its scale changed (or the window's own size): look at the taskbar again once things settle.
  @override
  void didChangeMetrics() {
    _metricsTimer?.cancel();
    _metricsTimer = Timer(const Duration(milliseconds: 400), () {
      if (_dragging) return;
      if (_canRoam) unawaited(_measure());
      unawaited(refresh());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    unawaited(_cues.cancel());
    settings.removeListener(_settingsChanged);
    motion.removeListener(_motionChanged);
    super.dispose();
  }
}
