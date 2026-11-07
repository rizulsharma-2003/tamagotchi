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
// - Patch on the taskbar (while he's around and "Patch on the taskbar" is on, ui/pet/companion_director.dart): his
//   desk takes a spot in a free stretch, with Mochi's place beside it, as mini Patch sits beside Mochi's bed in the
//   Mac's menu bar. The window then covers both (Mochi stays near him, as on the Mac), it doesn't move while Mochi
//   potters about inside it, and clicks reach both of them (only their bodies). With no stretch roomy enough for both,
//   Patch stays off the taskbar and Mochi has it to itself. For a moment together, Mochi trots over first.
// - The taskbar is looked at again every 10 seconds and after display or DPI changes.
//
// - Clicking Mochi (or Patch) opens the popover (the Mac's menu-bar popover) above the taskbar where Mochi is, inside
//   the work area: Mochi's taskbar presence pauses while it's open (the popover shows it in the room), and when it
//   closes Mochi is back on the very spot it left, and carries on from there.
//
// Every change to the window, the main window's included, goes through `show` and one queue here, so a pet placement
// never interleaves with the main window opening.
//
// The macOS development build has no taskbar (and no Win32 window), so the pet stands still there; the stroll itself
// is tested with fakes (test/stroll_test.dart).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/desktop_settings.dart';
import '../../core/pet_cues.dart';
import '../../platform/system.dart';
import '../../platform/taskbar.dart';
import '../popover/popover_stage.dart' show PopoverGeometry;
import '../shell.dart';
import 'companion_director.dart';
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

/// Where things are in the pet's window while Patch is on the taskbar.
@immutable
class DuoLayout {
  const DuoLayout({required this.home, required this.originX});

  /// Patch's spot and Mochi's place beside it (logical pixels along the taskbar).
  final HomeStage home;

  /// The window's left edge (logical): a spot's x in the window is `x - originX`.
  final double originX;

  double local(double x) => x - originX;

  /// Patch's body in the window (logical, measured up from Mochi's feet at [baseline]).
  Rect companionBody(double baseline) {
    final k = home.unit;
    final centre = local(home.deskX + HomeStage.bodyX * k);
    return Rect.fromLTRB(
      centre - HomeStage.bodyHalfWidth * k,
      baseline - HomeStage.bodyTop * k,
      centre + HomeStage.bodyHalfWidth * k,
      baseline - HomeStage.bodyBottom * k + 2,
    );
  }

  @override
  bool operator ==(Object other) => other is DuoLayout && other.home == home && other.originX == originX;

  @override
  int get hashCode => Object.hash(home, originX);
}

class TaskbarStroll extends ChangeNotifier with WidgetsBindingObserver {
  TaskbarStroll({
    required this.shell,
    required this.taskbar,
    required this.settings,
    required this.motion,
    required Stream<PetCue> cues,
    this.companion,
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
    Future<void> Function()? drawn,
  }) : _drawn = drawn ?? _nextFrame,
       _idle = idle ?? (() => Duration.zero),
       _clock = clock ?? _monotonic(),
       stroller = Stroller(random: random, tuning: tuning),
       _roaming = settings.roamTaskbar {
    _cues = cues.listen(_cue);
    settings.addListener(_settingsChanged);
    motion.addListener(_motionChanged);
    companion?.addListener(_companionChanged);
    _companionOnTaskbar = settings.companionOnTaskbar;
  }

  final DesktopShell shell;
  final TaskbarInfo taskbar;
  final DesktopSettings settings;
  final SystemMotion motion;
  final Stroller stroller;

  /// Patch (null: Mochi on its own, as in tests of the stroll alone).
  final CompanionDirector? companion;

  /// How often the window moves while Mochi walks.
  final Duration frameInterval;

  /// How often the pointer is checked (click-through, staying on top) while Mochi is on the taskbar.
  final Duration pointerInterval;

  /// How often full-screen apps are checked for; the taskbar is read every [taskbarChecks] of these, and its buttons
  /// measured every [measureChecks].
  final Duration checkInterval;
  final int taskbarChecks;
  final int measureChecks;

  /// How often the window goes back over the taskbar (seconds), besides at once when the taskbar was clicked.
  static const double raisePeriod = 0.5;

  /// How often the pointer is checked while it's near Mochi or Patch: a click that comes right after the pointer
  /// gets there still reaches them (the Mac polls faster near the bar too).
  static const Duration nearPointerInterval = Duration(milliseconds: 33);

  /// How close counts as near (logical pixels around their bodies).
  static const double nearMargin = 90;

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
  HomeStage? _home;

  /// Patch's spot before Mochi left the taskbar (kept for its return), and the spot Mochi left from (for the popover).
  HomeStage? _lastHome;
  double? _resumeX;
  bool _patchWanted = false;
  bool _companionOnTaskbar = true;
  double? _homeNear;
  Timer? _summonTimer;
  int _checks = 0;
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

  /// The art's scale on the taskbar (logical pixels per art unit): Mochi fills its box as in the Mac's menu bar, and
  /// Patch is drawn at the same scale.
  double get unit => box.height * SurfaceSizes.taskbarFill / 66;

  /// Patch's spot on the taskbar, while he's there with Mochi.
  HomeStage? get home => onTaskbar ? _home : null;

  /// Where things are in the window while Patch is on the taskbar.
  DuoLayout? get duo {
    final home = this.home;
    final stage = _stage;
    final frame = _frame;
    if (home == null || stage == null || frame == null) return null;
    return DuoLayout(home: home, originX: frame.left / stage.scale);
  }

  /// The window's size on the taskbar right now: Mochi's box (or Patch's and Mochi's stage), or taller with a bubble
  /// above it (and at least as wide as the bubble).
  Size get windowSize {
    final home = _home;
    final stage = _stage;
    if (home != null && stage != null) {
      final width = stage.homeWidth(home);
      return _atLeast(
        _bubble ? Size(math.max(width, SurfaceSizes.taskbarBubbleWidth), box.height + SurfaceSizes.bubble) : Size(width, box.height),
      );
    }
    return _atLeast(_bubble ? Size(SurfaceSizes.taskbarBubbleWidth, box.height + SurfaceSizes.bubble) : box);
  }

  /// The smallest the window turned out to be able to get (logical; null: as small as asked). Windows keeps a window
  /// with a title bar at least 136 × 39 at 100% unless the runner lets it be smaller (windows/runner/flutter_window.cpp);
  /// if it ever is bigger than asked, the stroll goes by its real size, so Mochi is drawn, and clicked, where it is.
  Size? _floor;

  Size _atLeast(Size size) {
    final floor = _floor;
    return floor == null ? size : Size(math.max(size.width, floor.width), math.max(size.height, floor.height));
  }

  /// The frame for Mochi at [x] (or for Patch's stage) at [size].
  PixelRect _frameFor(TaskbarStage stage, double x, Size size) {
    final home = _home;
    return home != null ? stage.homeFrame(home, size) : stage.frame(x, size);
  }

  /// Patch wants a spot on the taskbar: he's around (or leaving) and "Patch on the taskbar" is on.
  bool get _wantsPatch => (companion?.visible ?? false) && settings.companionOnTaskbar;

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

  /// Shows [surface]: the main window or nothing as before, the pet in the taskbar or standing where it was left, or
  /// the popover above where Mochi is ([popoverFrame]).
  Future<void> show(Surface surface) {
    log?.call('show: ${surface.name}');
    _surface = surface;
    if (surface == Surface.pet) {
      _popoverTimer?.cancel();
      _popoverTimer = null;
      _start();
      return _enqueue(() async {
        try {
          await _place();
        } finally {
          await _uncover();
        }
      });
    }
    if (surface == Surface.popover) {
      final geometry = popover ??= popoverGeometry(SurfaceSizes.popover);
      // Mochi comes back to this very spot when the popover closes.
      _resumeX = onTaskbar && stroller.isPlaced ? stroller.sample(_clock()).x : null;
      final scale = _stage?.scale ?? 1;
      _stop();
      // Nothing else runs while the genie plays (the walk, the pointer, UI Automation, the raise), and frames come on time.
      shell.petWindow?.preciseTimers(true);
      return _enqueue(() async {
        // Off the taskbar; the window lets every click through until the popover is all the way out.
        _halt();
        _nearPointer = false;
        _lastHome = _home ?? _lastHome;
        _home = null;
        _placement = PetPlacement.away;
        final window = shell.petWindow;
        final watch = Stopwatch()..start();
        final steps = <String>[];
        void step(String name) => steps.add('$name ${watch.elapsedMilliseconds}');
        try {
          if (window != null) {
            _clickThrough = true;
            window.setClickThrough(true);
            // Once, straight to its final rect, out of sight behind a still picture of Mochi: everything in it is
            // drawn where it was on screen.
            _covered = window.cover();
            step('covered');
            await window.setFrame(_physical(geometry.window, scale));
            step('resized');
          }
          await shell.show(Surface.popover, petPosition: geometry.window.topLeft, petSize: geometry.window.size);
          step('shown');
          if (_surface != Surface.popover || _disposed) return;
          _popoverOpen = false;
          _popoverScale = scale;
        } finally {
          await _uncover();
          step('uncovered');
          log?.call('popover window (ms): ${steps.join(', ')}');
        }
      });
    }
    _resumeX = null;
    popover = null;
    _stop();
    shell.petWindow?.preciseTimers(false);
    return _enqueue(() async {
      _leaveTaskbar();
      _placement = PetPlacement.away;
      try {
        await shell.show(surface, petPosition: settings.petPosition);
      } finally {
        await _uncover();
      }
    });
  }

  /// Whether the window is out of sight behind a picture of itself while it changes size ([PetWindow.cover]).
  bool _covered = false;

  /// Waits until Flutter has drawn the window at its new size, and as it should look there: a resize completes once a
  /// frame at the new size is on its way to the screen (Flutter's Windows embedder waits for it), so one more frame
  /// (after the surface changed, say) is enough.
  final Future<void> Function() _drawn;

  static Future<void> _nextFrame() => SchedulerBinding.instance.endOfFrame;

  /// The window back on screen once it's drawn at its new size.
  Future<void> _uncover() async {
    if (!_covered) return;
    _covered = false;
    await _drawn();
    shell.petWindow?.uncover();
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

  /// The popover's geometry while it's up (the app works it out as it opens it).
  PopoverGeometry? popover;
  Timer? _popoverTimer;
  bool _popoverOpen = false;
  double _popoverScale = 1;

  static PixelRect _physical(Rect rect, double scale) =>
      PixelRect((rect.left * scale).round(), (rect.top * scale).round(), (rect.right * scale).round(), (rect.bottom * scale).round());

  /// The popover's window and panel, and Mochi's spot (screen, logical pixels): the panel above the taskbar where
  /// Mochi is ([popoverFrame]), and the window around it and the pet's own window, so Mochi can leap between them.
  PopoverGeometry popoverGeometry(Size wanted) {
    final frame = popoverFrame(wanted);
    final stage = _stage;
    final pet = _frame;
    final scale = stage?.scale ?? 1;
    final panel = _physical(frame.position & frame.size, scale);
    Rect logical(PixelRect r) => Rect.fromLTRB(r.left / scale, r.top / scale, r.right / scale, r.bottom / scale);
    if (!onTaskbar || stage == null || pet == null || !stroller.isPlaced) {
      final rect = logical(panel);
      return PopoverGeometry(window: rect, panel: rect, petWindow: rect);
    }
    final window = PixelRect(
      math.min(panel.left, pet.left),
      math.min(panel.top, pet.top),
      math.max(panel.right, pet.right),
      math.max(panel.bottom, pet.bottom),
    );
    final sample = stroller.sample(_clock());
    return PopoverGeometry(
      window: logical(window),
      panel: logical(panel),
      petWindow: logical(pet),
      mochi: Offset(sample.x, stage.boxBottom / scale - box.height * SurfaceSizes.taskbarFeet),
      mochiScale: unit,
      facing: sample.facing,
      home: _home,
    );
  }

  /// The popover is all the way out: clicks reach it, and pass through the rest of the window to the taskbar.
  void popoverOpened() {
    _popoverOpen = true;
    shell.petWindow?.preciseTimers(false);
    _popoverTimer?.cancel();
    _popoverTimer = Timer.periodic(nearPointerInterval, (_) => _popoverPointer());
    _popoverPointer();
  }

  /// The popover is going: every click passes through until Mochi is back, and nothing else runs meanwhile.
  void popoverClosing() {
    _popoverOpen = false;
    _popoverTimer?.cancel();
    _popoverTimer = null;
    _setClickThrough(true);
    shell.petWindow?.preciseTimers(true);
  }

  /// Mochi has landed: the window goes back to the pet's own rect (where the pet draws Mochi just as it was drawn).
  Future<void> returnFromPopover() async {
    final geometry = popover;
    final window = shell.petWindow;
    _popoverTimer?.cancel();
    _popoverTimer = null;
    window?.preciseTimers(false);
    if (geometry == null || window == null || geometry.mochi == null) return;
    // Out of sight behind a still picture of Mochi on its spot until the pet has drawn it there ([show]).
    _covered = window.cover();
    await window.setFrame(_physical(geometry.petWindow, _popoverScale));
  }

  void _popoverPointer() {
    final geometry = popover;
    if (geometry == null || _surface != Surface.popover) return;
    if (!_popoverOpen) return _setClickThrough(true);
    final cursor = taskbar.cursor();
    final panel = _physical(geometry.panel, _popoverScale);
    _setClickThrough(!(cursor != null && panel.contains(cursor.$1, cursor.$2)));
  }

  /// Where the popover goes (logical pixels): above the taskbar, centred on Mochi where it can be, and inside the work
  /// area (so it never covers the taskbar), at most [wanted] big. Off the taskbar, above where the pet stands.
  ({Offset position, Size size}) popoverFrame(Size wanted) {
    final reading = taskbar.available ? taskbar.read() : null;
    final standing = settings.petPosition;
    double? centre = onTaskbar && stroller.isPlaced ? stroller.sample(_clock()).x : null;
    if (centre == null && standing != null) centre = standing.dx + SurfaceSizes.pet.width / 2;
    if (reading == null || !(reading.scale > 0) || reading.workArea.isEmpty) {
      // No taskbar to go by (the macOS build): above where the pet stands.
      final x = (centre ?? 200) - wanted.width / 2;
      final y = (standing?.dy ?? wanted.height) + SurfaceSizes.pet.height - wanted.height;
      return (position: Offset(math.max(8, x), math.max(8, y)), size: wanted);
    }
    final scale = reading.scale;
    final work = reading.workArea;
    final left = work.left / scale, right = work.right / scale, top = work.top / scale, bottom = work.bottom / scale;
    final size = Size(math.min(wanted.width, right - left - 16), math.min(wanted.height, bottom - top - 16));
    final x = ((centre ?? left + size.width / 2 + 8) - size.width / 2).clamp(left + 8, math.max(left + 8, right - size.width - 8));
    return (position: Offset(x.roundToDouble(), (bottom - size.height - 8).roundToDouble()), size: size);
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
        // Where Mochi was in the window: its centre (on Patch's stage, wherever it was standing in it).
        final mochi = _home == null ? size.width / 2 : stroller.sample(_clock()).x - frame.left / stage.scale;
        final feet = Offset(to.dx + mochi, to.dy + size.height);
        if (feet.dy * stage.scale > stage.bar.top + stage.bar.height / 2) {
          // Still on the taskbar: carry on from there (Patch's desk moves along, if there's room for it there).
          _frame = PixelRect.ltwh((to.dx * stage.scale).round(), (to.dy * stage.scale).round(), frame.width, frame.height);
          if (_home != null) {
            _home = null;
            _homeNear = feet.dx;
            stroller.place(_zones(stage), now: _clock(), x: feet.dx, mode: _mode, idleSeconds: _idleSeconds);
            unawaited(_enqueue(() => _onto(stage, near: feet.dx)));
            return;
          }
          stroller.place(_zones(stage), now: _clock(), x: feet.dx, mode: _mode, idleSeconds: _idleSeconds);
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
    final patch = _wantsPatch;
    final patchChanged = patch != _patchWanted;
    _patchWanted = patch;
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
    } else if (_placement != PetPlacement.taskbar || stage != _stage || patchChanged) {
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
  /// buttons now fill), or under where it stood. With Patch around, his desk takes a spot ([TaskbarStage.home]: where
  /// it was if it still fits, else near Mochi, or [near] after a drag) and Mochi keeps him company beside it.
  Future<void> _onto(TaskbarStage stage, {double? near}) async {
    final now = _clock();
    final arriving = _placement != PetPlacement.taskbar;
    final standing = settings.petPosition;
    final placed = stroller.isPlaced;
    // Back from the popover: the very spot Mochi left.
    final resume = arriving ? _resumeX : null;
    _resumeX = null;
    final current = resume ?? (placed ? stroller.sample(now).x : (standing == null ? null : standing.dx + SurfaceSizes.pet.width / 2));
    final previous = _home ?? _lastHome;
    final unit = stage.box.height * SurfaceSizes.taskbarFill / 66;
    final home = _wantsPatch ? stage.home(unit: unit, near: near ?? _homeNear ?? current, previous: previous) : null;
    _homeNear = null;
    final before = _home;
    _home = home;
    if (home != null) {
      // Beside Patch: the little stretch from Mochi's furthest potter to its place by the desk.
      if (arriving || !placed || home != before || stroller.home != home.petHome) {
        stroller.place(
          [StrollLine(home.minX, home.petHome)],
          now: now,
          x: current,
          mode: _mode,
          idleSeconds: _idleSeconds,
          home: home.petHome,
        );
      }
    } else if (arriving || !placed || stroller.home != null) {
      // Out on the taskbar on its own (Patch left, or there's no room for him): from where Mochi is.
      stroller.place(_zones(stage), now: now, x: current, mode: _mode, idleSeconds: _idleSeconds);
    } else {
      stroller.rezone(_zones(stage), now: now);
    }
    _stage = stage;
    final frame = _frameFor(stage, stroller.sample(now).x, windowSize);
    if (arriving) {
      await shell.show(Surface.pet, petPosition: stage.logical(frame), petSize: windowSize);
      if (_surface != Surface.pet) return;
    }
    // Exactly in physical pixels (window_manager rounds through logical ones).
    log?.call('onto: frame=$frame box=${stage.box} arriving=$arriving home=$home');
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
    _summon();
  }

  /// Off the taskbar: the window takes clicks again and nothing watches the pointer.
  void _leaveTaskbar() {
    _halt();
    _nearPointer = false;
    _lastHome = _home ?? _lastHome;
    _home = null;
    _summonTimer?.cancel();
    _summonTimer = null;
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
    final frame = _frameFor(stage, stroller.sample(_clock()).x, windowSize);
    if (frame != _frame) await _setFrame(frame);
  }

  Future<void> _setFrame(PixelRect frame) async {
    final window = shell.petWindow;
    if (window == null) return;
    _resizing = true;
    try {
      await window.setFrame(frame);
      var actual = frame;
      final real = window.frame();
      final stage = _stage;
      if (real != null && stage != null && !real.sameSize(frame) && real.width >= frame.width && real.height >= frame.height) {
        // Bigger than asked: centred where it was meant to be (so Mochi, drawn in the middle, is on its spot), sitting
        // on the same bottom edge, and asked for at that size from now on.
        _floor = Size(real.width / stage.scale, real.height / stage.scale);
        actual = PixelRect.ltwh(frame.left - (real.width - frame.width) ~/ 2, frame.bottom - real.height, real.width, real.height);
        log?.call('the window is bigger than asked: $real for $frame');
        if (actual.left != real.left || actual.top != real.top) window.move(actual.left, actual.top);
      }
      _frame = actual;
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
    // Beside Patch the window covers both: Mochi moves inside it.
    if (stage == null || frame == null || window == null || _resizing || _home != null) return;
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
    final now = _clock();
    final inFront = taskbar.taskbarInFront();
    if ((inFront && !_taskbarWasInFront) || now - _lastRaise >= raisePeriod) {
      window.raise();
      _lastRaise = now;
    }
    _taskbarWasInFront = inFront;
    final cursor = taskbar.cursor();
    _setClickThrough(!(_dragging || (cursor != null && _overBody(stage, frame, cursor.$1, cursor.$2))));
    // Faster while the pointer is near them, the usual pace otherwise.
    final margin = (nearMargin * stage.scale).round();
    final near =
        cursor != null &&
        bodies().any(
          (body) =>
              PixelRect(body.left - margin, body.top - margin, body.right + margin, body.bottom + margin).contains(cursor.$1, cursor.$2),
        );
    if (near != _nearPointer && _pointerTimer != null) {
      _nearPointer = near;
      _pointerTimer?.cancel();
      _pointerTimer = Timer.periodic(near ? nearPointerInterval : pointerInterval, (_) => _pointer());
    }
  }

  bool _nearPointer = false;
  double _lastRaise = double.negativeInfinity;

  /// The pointer is being checked often (it's near Mochi or Patch).
  bool get pointerNear => _nearPointer;

  /// The pointer is over Mochi (or Patch, at his desk on the taskbar).
  bool _overBody(TaskbarStage stage, PixelRect frame, int x, int y) => bodies().any((body) => body.contains(x, y));

  /// Mochi's body (and Patch's, at his desk) right now, in physical pixels: what takes clicks.
  List<PixelRect> bodies() {
    final stage = _stage;
    final frame = _frame;
    if (!onTaskbar || stage == null || frame == null) return const [];
    final home = _home;
    if (home == null) return [stage.body(frame)];
    return [stage.bodyAt(stroller.sample(_clock()).x), if (companion?.visible ?? false) stage.companionBody(home)];
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
      PetCue.celebrate => 2.6,
      PetCue.cheer => 2.0,
      PetCue.worry => 2.4,
      PetCue.greet => 1.6,
      PetCue.goodbye => 1.4,
      _ => null,
    };
    // A moment with Patch is the reaction itself: Mochi is on its way over to him, or already there.
    final together = companion?.pending != null || companion?.interaction != null;
    if (hold == null || !onTaskbar || _dragging || together) return;
    const news = {PetCue.finished, PetCue.snag, PetCue.replied, PetCue.celebrate, PetCue.cheer, PetCue.worry, PetCue.greet};
    stroller.react(_clock(), hold, attentive: news.contains(cue));
    _tick();
  }

  void _settingsChanged() {
    if (settings.companionOnTaskbar != _companionOnTaskbar) {
      _companionOnTaskbar = settings.companionOnTaskbar;
      unawaited(refresh());
    }
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

  /// Patch arrived, left, or wants Mochi over for a moment together.
  void _companionChanged() {
    if (_disposed) return;
    if (_wantsPatch != _patchWanted && _surface == Surface.pet) unawaited(_enqueue(_place));
    _summon();
  }

  /// A moment together is waiting: Mochi trots over to Patch, and it starts when Mochi gets there. Where Patch isn't
  /// on the taskbar (no room, or it's off) there's nobody to see it, so it starts (and ends) at once.
  void _summon() {
    final companion = this.companion;
    final id = companion?.pending;
    if (companion == null || id == null || _summonTimer != null || _surface != Surface.pet) return;
    final now = _clock();
    final besidePatch = onTaskbar && !_dragging && !_fullscreen && _home != null;
    final arrival = besidePatch ? stroller.summon(now, companion.lengthOf(id)) : null;
    if (arrival == null) {
      companion.startPending();
      return;
    }
    _tick();
    _summonTimer = Timer(Duration(microseconds: ((arrival - now) * 1e6).ceil()), () {
      _summonTimer = null;
      if (companion.pending == id) companion.startPending();
    });
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
    _popoverTimer?.cancel();
    _popoverTimer = null;
    _summonTimer?.cancel();
    _summonTimer = null;
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
    shell.petWindow?.preciseTimers(false);
    if (_covered) shell.petWindow?.uncover();
    unawaited(_cues.cancel());
    settings.removeListener(_settingsChanged);
    motion.removeListener(_motionChanged);
    companion?.removeListener(_companionChanged);
    super.dispose();
  }
}
