// Mochi strolling inside Windows' taskbar, as it walks inside the menu bar on the Mac (MenuBarOverlayController,
// MenuBarStageView): the glue between the stroll's plan (stroller.dart), the taskbar (platform/taskbar.dart) and the
// pet's window.
//
// - Mochi is on the taskbar while it lives there (Settings › Desktop Pet: "Roams the taskbar" or "Plays in its spot")
//   and the main screen's taskbar is at the bottom and doesn't hide itself. Otherwise the pet stands still where it was
//   left on the desktop (bottom left at first), as the Mac's desktop pet does: at its size, above other windows or not,
//   taking clicks or letting them through, at the place it was left on the display it was left on (each display keeps
//   its own place; a display that's gone puts it on the main one).
// - "Plays in its spot" (the Mac's "Play in the status item"): Mochi keeps to a little stretch of the taskbar (its
//   room: small, medium or large), beside the notification area at first; dragging it along the taskbar moves its spot.
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
// - Dragging Mochi along the taskbar moves it there; dragging it off the taskbar starts an adventure from where it's
//   dropped when Adventures are on (W19, ui/stage/adventure.dart), else turns roaming off and leaves it where it's
//   dropped, until roaming is turned on again (Settings, or "Back to the taskbar" in the tray menu).
// - Animation effects off: Mochi stays put on the taskbar (expressions only).
// - A full-screen app or a presentation (SHQueryUserNotificationState) hides the pet until it's over.
// - Patch on the taskbar (while he's around and "Patch on the taskbar" is on, ui/pet/companion_director.dart): his
//   desk takes a spot in a free stretch, with Mochi's place beside it, as mini Patch sits beside Mochi's bed in the
//   Mac's menu bar. The window then covers both (Mochi stays near him, as on the Mac), it doesn't move while Mochi
//   potters about inside it, and clicks reach both of them (only their bodies). With no stretch roomy enough for both,
//   Patch stays off the taskbar and Mochi has it to itself. A moment together runs from where Mochi is to his desk.
// - While Mochi's world reacts (a moment together, Claude's news, a pet: the Mac's roamer freezes for these), Mochi holds
//   still where it is until it's over.
// - The taskbar is looked at again every 10 seconds and after display or DPI changes. Its buttons are measured with UI
//   Automation only when something on it may have moved (TaskbarInfo.fingerprint: the app windows that have buttons,
//   the tray's width), or once a minute, and not while Mochi naps.
// - While nobody can see the screen (the display is off, the PC is locked or asleep: PcRhythm.unseen) nothing runs at
//   all: no frames, no pointer checks, no taskbar checks. Mochi carries on from where it was when the screen is back.
//
// - Clicking Mochi (or Patch) opens the popover (the Mac's menu-bar popover) above the taskbar where Mochi is, inside
//   the work area: Mochi's taskbar presence pauses while it's open (the popover shows it in the room), and when it
//   closes Mochi is back on the very spot it left, and carries on from there.
//
// - Mochi out on the desktop (Mischief: the cursor buddy, roaming the screens; ui/stage/): the native stage draws it
//   ([out]), so here it's away: Patch stays at his desk if he's on the taskbar (the window shows only him), otherwise
//   the window hides until Mochi comes back, where the stage left it ([comeBack]).
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
import '../../core/pc_rhythm.dart';
import '../../platform/displays.dart';
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

/// Where Mochi lives when it isn't out on the desktop: Mischief's extras take it out from here and bring it back
/// (TaskbarStroll; a fake in tests).
abstract interface class PetHome implements Listenable {
  /// Mochi is out on the desktop (drawn by the native stage).
  bool get out;

  /// Mochi can go out from here now: it shows on the taskbar or the desktop (not in its window or the popover), and
  /// nobody is dragging it.
  bool get canGoOut;

  /// Where Mochi stands on the screen now: its feet (physical pixels), the display's scale, which way it faces and how
  /// big it's drawn (logical pixels per art unit). Null when it isn't showing.
  ({int x, int y, double scale, double facing, double unit})? departure();

  /// Mochi leaves (the stage draws it from now on).
  void goOut();

  /// Mochi is back, with its feet at [x] (physical pixels; on the taskbar, the nearest free spot) or where it left.
  void comeBack({int? x});
}

class TaskbarStroll extends ChangeNotifier with WidgetsBindingObserver implements PetHome {
  TaskbarStroll({
    required this.shell,
    required this.taskbar,
    required this.settings,
    required this.motion,
    required Stream<PetCue> cues,
    this.companion,
    this.rhythm,
    this.displays = const NoDisplays(),
    Duration Function()? idle,
    double Function()? clock,
    math.Random? random,
    StrollTuning tuning = const StrollTuning(),
    this.frameInterval = const Duration(milliseconds: 40),
    this.pointerInterval = pointerIntervalDefault,
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
    _celebrations = companion?.host.celebrated.listen((_) => _celebrated());
    settings.addListener(_settingsChanged);
    motion.addListener(_motionChanged);
    companion?.addListener(_companionChanged);
    companion?.host.addListener(_holdForWorld);
    rhythm?.addListener(_rhythmChanged);
    _companionOnTaskbar = settings.companionOnTaskbar;
    _onlyMoments = settings.companionOnlyMoments;
    _spotSeen = _spotOf(settings);
    _standingSeen = _standingOf(settings);
  }

  final DesktopShell shell;
  final TaskbarInfo taskbar;
  final DesktopSettings settings;
  final SystemMotion motion;
  final Stroller stroller;

  /// Patch (null: Mochi on its own, as in tests of the stroll alone).
  final CompanionDirector? companion;

  /// The PC's rhythm: while nobody can see the screen, nothing runs (null: always seen).
  final PcRhythm? rhythm;

  /// The displays, for the desktop pet's place on each (none: placed through window_manager, the macOS build).
  final Displays displays;

  /// How long a moment keeps Patch on the taskbar with "only for interesting moments" (the Mac's captions), and how
  /// often he's looked at again meanwhile.
  static const double momentLength = 8;
  static const Duration momentCheck = Duration(seconds: 2);

  /// The buttons are measured again at least this often, even when nothing seems to have changed.
  static const Duration measureAtLeast = Duration(minutes: 1);

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
  StreamSubscription<Object?>? _celebrations;

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
  bool _out = false;
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
  Object? _heldFor;
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

  /// Patch wants a spot on the taskbar: he's around (or leaving) and "Patch on the taskbar" is on, and with "only for
  /// interesting moments", something interesting is going on.
  bool get _wantsPatch =>
      (companion?.visible ?? false) && settings.companionOnTaskbar && (!settings.companionOnlyMoments || interesting);

  /// Something Patch comes out for (the Mac's desktop pet): Claude waiting for you, a moment with Mochi or one of his own
  /// (arriving, an error, a celebration), or one of Mochi's news moments in the last [momentLength] seconds.
  bool get interesting {
    final patch = companion;
    if (patch == null) return false;
    final t = patch.time;
    return patch.busyAt(t) || patch.waiting || _clock() < _momentUntil;
  }

  double _momentUntil = double.negativeInfinity;
  Timer? _momentTimer;

  /// Where the window is on the taskbar (physical pixels), while it's there.
  PixelRect? get frame => onTaskbar ? _frame : null;

  /// The desktop pet's window (logical pixels), at its size.
  Size get standingSize => SurfaceSizes.standing(settings.petSize);

  /// Clicks pass through the desktop pet right now ("Let clicks pass through").
  bool get standingClickThrough => _standingThrough;

  /// Clicks go through the window right now (null before Mochi was first on the taskbar).
  bool? get clickThrough => _clickThrough;

  /// The timers that are running, for tests: moving Mochi, waiting for its next move, watching the pointer, checking
  /// the taskbar.
  bool get moving => _frameTimer != null;
  bool get waiting => _wakeTimer != null;
  bool get watchingPointer => _pointerTimer != null;
  bool get checking => _checkTimer != null;

  /// Any of the stroll's timers.
  bool get anyTimer => moving || waiting || watchingPointer || checking || _popoverTimer != null || _momentTimer != null;

  /// Nobody can see the screen: everything waits.
  bool get _unseen => rhythm?.unseen ?? false;
  bool _paused = false;

  /// Paused while nobody can see the screen.
  bool get paused => _paused;

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
      // Back from the popover however it closed (to the taskbar or to the desktop): Windows' timers back to normal.
      _precise(false);
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
      _precise(true);
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
    _precise(false);
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

  /// Windows' timers to the millisecond (timeBeginPeriod) only while the popover's transitions run.
  bool _preciseOn = false;
  bool get preciseTimers => _preciseOn;

  void _precise(bool on) {
    if (on != _preciseOn) log?.call('precise timers: ${on ? 'on' : 'off'}');
    _preciseOn = on;
    shell.petWindow?.preciseTimers(on);
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
  PetMood get mood => _mood;
  set mood(PetMood mood) {
    if (mood == _mood) return;
    final woke = _mood == PetMood.napping;
    _mood = mood;
    if (woke && _canRoam && !_paused) unawaited(_measure());
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
    _precise(false);
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
    _precise(true);
  }

  /// Mochi has landed: the window goes back to the pet's own rect (where the pet draws Mochi just as it was drawn).
  Future<void> returnFromPopover() async {
    final geometry = popover;
    final window = shell.petWindow;
    _popoverTimer?.cancel();
    _popoverTimer = null;
    _precise(false);
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
    if (centre == null && standing != null) centre = standing.dx + standingSize.width / 2;
    if (reading == null || !(reading.scale > 0) || reading.workArea.isEmpty) {
      // No taskbar to go by (the macOS build): above where the pet stands.
      final x = (centre ?? 200) - wanted.width / 2;
      final y = (standing?.dy ?? wanted.height) + standingSize.height - wanted.height;
      return (position: Offset(math.max(8, x), math.max(8, y)), size: wanted);
    }
    final scale = reading.scale;
    final work = reading.workArea;
    final left = work.left / scale, right = work.right / scale, top = work.top / scale, bottom = work.bottom / scale;
    final size = Size(math.min(wanted.width, right - left - 16), math.min(wanted.height, bottom - top - 16));
    final x = ((centre ?? left + size.width / 2 + 8) - size.width / 2).clamp(left + 8, math.max(left + 8, right - size.width - 8));
    return (position: Offset(x.roundToDouble(), (bottom - size.height - 8).roundToDouble()), size: size);
  }

  /// Mochi was let go off the taskbar with its feet at x, y (physical pixels): true when an adventure takes it from
  /// there (W19), so it isn't parked. Null: no adventures (it's parked, with roaming turned off).
  bool Function(int x, int y)? onDropOff;

  /// A logical x on the taskbar's display as physical pixels.
  static int feetX(double x, TaskbarStage stage) => (x * stage.scale).round();

  /// Mochi is being dragged: it holds still (and nothing else moves the window) until [dragEnded].
  void dragStarted() {
    _dragging = true;
    _halt();
    _setClickThrough(false);
    if (onTaskbar) stroller.react(_clock(), double.infinity);
  }

  /// The drag ended with the window's top-left at [to] (logical pixels, as window_manager reports it). Dropped on the
  /// taskbar, Mochi carries on from there (in the nearest free stretch); dropped off it, an adventure starts from there
  /// (W19, with Adventures on: [onDropOff]), else roaming turns off and Mochi stays where it was dropped. A nudge that left it where it was just carries on.
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
          // Still on the taskbar: carry on from there (Patch's desk moves along, if there's room for it there). Playing
          // in its spot, that's its spot now.
          if (settings.petStyle == DesktopStyle.spot) {
            _spotSeen = (DesktopStyle.spot, feet.dx, settings.spotRoom);
            settings.spotX = feet.dx;
          }
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
        // With Adventures on, an adventure starts from where Mochi was let go (W19: it falls onto what's below).
        final drop = onDropOff;
        if (drop != null && drop(feetX(feet.dx, stage), ((feet.dy - box.height * SurfaceSizes.taskbarFeet) * stage.scale).round())) return;
        _parking = true;
        try {
          _park(feet, stage);
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
      _rememberPlace();
    }
  }

  /// Mochi leaves the taskbar with its feet at [feet] (logical): the desktop pet stands just above where it was, on the
  /// taskbar's display.
  void _park(Offset feet, TaskbarStage stage) {
    final spot = standingSpot(feet, stage, size: standingSize, box: settings.petSize.stage);
    settings.petPosition = spot;
    final size = standingSize;
    _rememberPlace(
      PixelRect.ltwh(
        (spot.dx * stage.scale).round(),
        (spot.dy * stage.scale).round(),
        (size.width * stage.scale).round(),
        (size.height * stage.scale).round(),
      ),
    );
  }

  /// The desktop pet is at [frame] (physical; its window's frame now if not given): that's its place on that display.
  void _rememberPlace([PixelRect? frame]) {
    final at = frame ?? shell.petWindow?.frame();
    final list = displays.list();
    if (at == null || list.isEmpty) return;
    final display = PetPlacing.displayOf(list, at)!;
    settings.placePet(display.key, PetPlacing.placeOf(display, at, box: (settings.petSize.stage * display.scale).round()));
  }

  /// The standing pet's window position (logical) with Mochi's feet at [feet], never lower than standing on the
  /// taskbar's top edge (the standing pet is bigger and would cover it). [size] is its window, [box] its stage.
  static Offset standingSpot(Offset feet, TaskbarStage stage, {Size size = SurfaceSizes.pet, double box = SurfaceSizes.petStage}) {
    final standingFeet = size.height - box * SurfaceSizes.standingFeet;
    final top = math.min(feet.dy - standingFeet, stage.bar.top / stage.scale - size.height);
    return Offset(feet.dx - size.width / 2, top);
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

  // MARK: Out on the desktop (Mischief)

  @override
  bool get out => _out;

  @override
  bool get canGoOut =>
      !_out &&
      !_dragging &&
      !_paused &&
      _surface == Surface.pet &&
      shell.petWindow != null &&
      (_placement == PetPlacement.taskbar || _placement == PetPlacement.standing);

  @override
  ({int x, int y, double scale, double facing, double unit})? departure() {
    final stage = _stage;
    final frame = _frame;
    if (onTaskbar && stage != null && frame != null && stroller.isPlaced) {
      final sample = stroller.sample(_clock());
      final feet = stage.boxBottom - (box.height * SurfaceSizes.taskbarFeet * stage.scale).round();
      return (x: (sample.x * stage.scale).round(), y: feet, scale: stage.scale, facing: sample.facing, unit: unit);
    }
    if (_placement == PetPlacement.standing) {
      final window = shell.petWindow?.frame();
      if (window == null) return null;
      final list = displays.list();
      final scale = list.isEmpty ? 1.0 : PetPlacing.displayOf(list, window)!.scale;
      final box = settings.petSize.stage;
      final feet = window.bottom - (box * SurfaceSizes.standingFeet * scale).round();
      return (x: window.left + window.width ~/ 2, y: feet, scale: scale, facing: 1.0, unit: box * SurfaceSizes.standingFill / 66);
    }
    return null;
  }

  @override
  void goOut() {
    if (_out) return;
    _out = true;
    log?.call('out on the desktop');
    // Its plan holds while it's away (it carries on from where it comes back).
    if (onTaskbar && stroller.isPlaced) stroller.react(_clock(), double.infinity);
    _halt();
    unawaited(_enqueue(_place));
    _notify();
  }

  @override
  void comeBack({int? x}) {
    if (!_out) return;
    _out = false;
    log?.call('back from the desktop at $x');
    final stage = _stage;
    final home = _home;
    if (x != null && stage != null) {
      final logical = x / stage.scale;
      if (onTaskbar && home != null) {
        // Back beside Patch, in its little stretch by his desk.
        stroller.place([StrollLine(home.minX, home.petHome)], now: _clock(), x: logical.clamp(home.minX, home.petHome), mode: _mode, idleSeconds: _idleSeconds, home: home.petHome);
      } else if (onTaskbar) {
        stroller.place(_zones(stage), now: _clock(), x: logical, mode: _mode, idleSeconds: _idleSeconds);
      } else {
        _resumeX = logical;
      }
    } else if (onTaskbar && stroller.isPlaced) {
      stroller.resume(_clock());
    }
    unawaited(_enqueue(_place));
    _notify();
    if (onTaskbar) _tick();
  }

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
    _watchMoments();
    if (changed || stage != _stage) log?.call('place: $stage block=$block buttons=${_buttons?.length} fullscreen=$_fullscreen');
    // Mochi out on the desktop with nobody left here (no Patch at his desk on the taskbar): the window hides.
    final away = _out && !(patch && stage != null);
    if (_fullscreen || away) {
      if (_placement != PetPlacement.hidden) {
        _leaveTaskbar();
        _placement = PetPlacement.hidden;
        await shell.show(Surface.hidden);
        _notify();
      }
    } else if (stage == null) {
      if (_placement != PetPlacement.standing || _standingDirty) {
        _standingDirty = false;
        if (_placement != PetPlacement.standing) {
          _leaveTaskbar();
          stroller.clear();
          _stage = null;
          _placement = PetPlacement.standing;
        }
        await _stand();
        _notify();
      } else if (changed) {
        _notify();
      }
    } else if (_placement != PetPlacement.taskbar || stage != _stage || patchChanged || _respot) {
      final respot = _respot;
      _respot = false;
      await _onto(stage, respot: respot);
    } else if (changed) {
      _notify();
    }
  }

  /// The desktop pet's look or place changed (its size, always on top, clicks passing through, the displays).
  bool _standingDirty = false;

  /// Mochi's spot on the taskbar moved, or its room changed.
  bool _respot = false;
  bool _standingThrough = false;

  /// Shows the desktop pet standing on the desktop: at its size, at its place on the display it was left on (or bottom
  /// left), above other windows or not, and taking clicks or letting every one of them through.
  Future<void> _stand() async {
    final size = standingSize;
    final window = shell.petWindow;
    final list = displays.list();
    final place = list.isEmpty || window == null
        ? null
        : PetPlacing.frameFor(
            list,
            places: settings.petPlaces,
            last: settings.petDisplay,
            size: size,
            box: settings.petSize.stage,
            legacy: settings.petPosition,
          );
    log?.call('stand: ${place?.frame} on ${place?.display.key} size=$size onTop=${settings.petOnTop} through=${settings.petClickThrough}');
    // Onto a display at another scale: there first at the size it has, so Windows rescales it (WM_DPICHANGED) before
    // it's given its size there; otherwise the new size would be scaled again.
    final current = window?.frame();
    if (place != null && window != null && current != null) {
      final from = PetPlacing.displayOf(list, current);
      if (from != null && from.scale != place.display.scale) {
        await window.setFrame(PixelRect.ltwh(place.frame.left, place.frame.top, current.width, current.height));
      }
    }
    await shell.show(Surface.pet, petPosition: settings.petPosition, petSize: size, onTop: settings.petOnTop, petFrame: place?.frame);
    if (_surface != Surface.pet || _disposed || window == null) return;
    final through = settings.petClickThrough;
    if (through) {
      window.setClickThrough(true);
    } else if (_standingThrough) {
      window.settle();
    }
    _standingThrough = through;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Where Mochi may go on [stage]: every free stretch, or (playing in its spot) its room around the spot.
  List<StrollLine> _zones(TaskbarStage stage) {
    final zones = [for (final zone in stage.zones) StrollLine(zone.minX, zone.maxX)];
    if (settings.petStyle != DesktopStyle.spot || zones.isEmpty) return zones;
    return [spotLine(zones, settings.spotX, settings.spotRoom.spotRoom)];
  }

  /// Mochi's room around its spot [spotX] (null: at the end of the stretch beside the notification area), [room] wide
  /// all told, inside the free stretch nearest the spot.
  static StrollLine spotLine(List<StrollLine> zones, double? spotX, double room) {
    final sorted = [...zones]..sort((a, b) => a.minX.compareTo(b.minX));
    final spot = spotX ?? sorted.last.maxX - room / 2;
    var zone = sorted.first;
    for (final candidate in sorted) {
      if ((candidate.clamp(spot) - spot).abs() < (zone.clamp(spot) - spot).abs()) zone = candidate;
    }
    final width = zone.maxX - zone.minX;
    if (width <= room) return zone;
    final centre = spot.clamp(zone.minX + room / 2, zone.maxX - room / 2);
    return StrollLine(centre - room / 2, centre + room / 2);
  }

  /// Puts Mochi in the taskbar: carrying on where it was if it was already strolling (hopping out of a stretch that
  /// buttons now fill), or under where it stood. With Patch around, his desk takes a spot ([TaskbarStage.home]: where
  /// it was if it still fits, else near Mochi, or [near] after a drag) and Mochi keeps him company beside it.
  Future<void> _onto(TaskbarStage stage, {double? near, bool respot = false}) async {
    final now = _clock();
    final arriving = _placement != PetPlacement.taskbar;
    final standing = settings.petPosition;
    final placed = stroller.isPlaced;
    // Back from the popover: the very spot Mochi left.
    final resume = arriving ? _resumeX : null;
    _resumeX = null;
    final current = resume ?? (placed ? stroller.sample(now).x : (standing == null ? null : standing.dx + standingSize.width / 2));
    final previous = _home ?? _lastHome;
    final unit = stage.box.height * SurfaceSizes.taskbarFill / 66;
    // Playing in its spot, Patch's desk goes by the spot.
    final spot = settings.petStyle == DesktopStyle.spot ? _zones(stage).first : null;
    final home = _wantsPatch
        ? stage.home(
            unit: unit,
            near: near ?? _homeNear ?? (spot == null ? current : (spot.minX + spot.maxX) / 2),
            previous: spot == null || _respotHome ? previous : null,
          )
        : null;
    _respotHome = false;
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
    } else if (arriving || !placed || stroller.home != null || respot) {
      // Out on the taskbar on its own (Patch left, or there's no room for him): from where Mochi is.
      stroller.place(_zones(stage), now: now, x: current, mode: _mode, idleSeconds: _idleSeconds);
    } else {
      stroller.rezone(_zones(stage), now: now);
    }
    _stage = stage;
    final frame = _frameFor(stage, stroller.sample(now).x, windowSize);
    if (arriving) {
      if (_standingThrough) {
        _standingThrough = false;
        shell.petWindow?.settle();
      }
      await shell.show(Surface.pet, petPosition: stage.logical(frame), petSize: windowSize);
      if (_surface != Surface.pet) return;
    }
    // Exactly in physical pixels (window_manager rounds through logical ones).
    log?.call('onto: frame=$frame box=${stage.box} arriving=$arriving home=$home');
    if (frame != _frame || arriving) await _setFrame(frame);
    if (_disposed || _surface != Surface.pet || _fullscreen) return;
    if (arriving) {
      _placement = PetPlacement.taskbar;
      if (!_paused && _pointerTimer == null) {
        _pointerTimer = Timer.periodic(pointerInterval, (_) => _pointer());
        _pointerEvery = pointerInterval;
      }
      shell.petWindow?.raise();
      _pointer();
    }
    _notify();
    _tick();
    _holdForWorld();
  }

  /// Off the taskbar (or off the desktop): the window takes clicks again and nothing watches the pointer.
  void _leaveTaskbar() {
    if (_standingThrough) {
      _standingThrough = false;
      shell.petWindow?.settle();
    }
    _halt();
    _nearPointer = false;
    _lastHome = _home ?? _lastHome;
    _home = null;
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
      _fingerprint = taskbar.fingerprint();
      final buttons = await taskbar.buttons();
      log?.call('measure: ${buttons?.length} elements in ${((_clock() - started) * 1000).round()} ms');
      _measured = true;
      _measuredAt = _clock();
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
    // Out on the desktop, Mochi's stroll here waits (Patch, if he's here, carries on in his own frames).
    if (_disposed || _surface != Surface.pet || _placement != PetPlacement.taskbar || _dragging || _paused || _out) {
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
    // While Mochi naps and the pointer hasn't moved (you're away), twice a second is enough; it moves, and the usual
    // pace is back at once.
    final still = cursor != null && cursor == _lastCursor;
    _lastCursor = cursor;
    final interval = near
        ? nearPointerInterval
        : (_mood == PetMood.napping && still ? napPointerInterval : pointerInterval);
    if (near != _nearPointer || interval != _pointerEvery) {
      _nearPointer = near;
      if (_pointerTimer != null) {
        _pointerTimer?.cancel();
        _pointerTimer = Timer.periodic(interval, (_) => _pointer());
      }
      _pointerEvery = interval;
    }
  }

  /// The pointer's usual pace (tests).
  static const Duration pointerIntervalDefault = Duration(milliseconds: 100);

  /// How often the pointer is checked while Mochi naps and it doesn't move.
  static const Duration napPointerInterval = Duration(milliseconds: 500);
  (int, int)? _lastCursor;
  Duration? _pointerEvery;

  /// How often the pointer is checked now.
  Duration? get pointerEvery => _pointerTimer == null ? null : _pointerEvery ?? pointerInterval;

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
    if (home == null) return _out ? const [] : [stage.body(frame)];
    return [if (!_out) stage.bodyAt(stroller.sample(_clock()).x), if (companion?.visible ?? false) stage.companionBody(home)];
  }

  void _setClickThrough(bool through) {
    if (through == _clickThrough || (_clickThrough == null && !through)) return;
    _clickThrough = through;
    shell.petWindow?.setClickThrough(through);
    log?.call('click-through: $through');
  }

  // MARK: What happens around Mochi

  void _cue(PetCue cue) {
    _moment(cue);
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
    // A moment with Patch is the reaction itself: the world holds Mochi for it ([_holdForWorld]).
    final together = companion?.together ?? false;
    if (hold == null || !onTaskbar || _dragging || together) return;
    const news = {PetCue.finished, PetCue.snag, PetCue.replied, PetCue.celebrate, PetCue.cheer, PetCue.worry, PetCue.greet};
    stroller.react(_clock(), hold, attentive: news.contains(cue));
    _tick();
  }

  /// One of Mochi's news moments (the Mac's captions: greetings, finishes, snags, worries, celebrations, Claude needing
  /// you): with "only for interesting moments", Patch comes out for it.
  void _moment(PetCue cue) {
    const moments = {
      PetCue.greet,
      PetCue.goodbye,
      PetCue.finished,
      PetCue.snag,
      PetCue.cheer,
      PetCue.worry,
      PetCue.celebrate,
      PetCue.puzzled,
      PetCue.needsYou,
    };
    if (!moments.contains(cue)) return;
    _momentUntil = _clock() + momentLength;
    if (settings.companionOnlyMoments) _companionChanged();
  }

  /// A real Claude moment earned a celebration (G2): with "only for interesting moments", Patch comes out for it.
  void _celebrated() {
    _momentUntil = _clock() + momentLength;
    if (settings.companionOnlyMoments) _companionChanged();
  }

  /// With "only for interesting moments", Patch is looked at again every couple of seconds while he's out, so he goes
  /// when the moment is over.
  void _watchMoments() {
    final watch = settings.companionOnlyMoments && _patchWanted && _surface == Surface.pet && !_disposed;
    if (!watch) {
      _momentTimer?.cancel();
      _momentTimer = null;
    } else {
      _momentTimer ??= Timer.periodic(momentCheck, (_) => _companionChanged());
    }
  }

  static (DesktopStyle, double?, PetSize) _spotOf(DesktopSettings settings) => (settings.petStyle, settings.spotX, settings.spotRoom);
  static (PetSize, bool, bool) _standingOf(DesktopSettings settings) => (settings.petSize, settings.petOnTop, settings.petClickThrough);
  late (DesktopStyle, double?, PetSize) _spotSeen;
  late (PetSize, bool, bool) _standingSeen;

  /// Patch's desk moves along with a new spot.
  bool _respotHome = false;

  void _settingsChanged() {
    var refreshing = false;
    if (settings.companionOnTaskbar != _companionOnTaskbar) {
      _companionOnTaskbar = settings.companionOnTaskbar;
      refreshing = true;
    }
    final spot = _spotOf(settings);
    if (spot != _spotSeen) {
      _spotSeen = spot;
      _respot = true;
      _respotHome = true;
      refreshing = true;
    }
    final standing = _standingOf(settings);
    if (standing != _standingSeen) {
      _standingSeen = standing;
      _standingDirty = true;
      refreshing = true;
    }
    if (settings.companionOnlyMoments != _onlyMoments) {
      _onlyMoments = settings.companionOnlyMoments;
      refreshing = true;
    }
    if (refreshing && settings.roamTaskbar == _roaming) unawaited(refresh());
    if (settings.roamTaskbar == _roaming) return;
    _roaming = settings.roamTaskbar;
    // Off the taskbar: Mochi stands just above the taskbar where it was (a drag has already said where it went).
    final stage = _stage;
    final frame = _frame;
    if (!_roaming && !_parking && onTaskbar && stage != null && frame != null) {
      final x = _home == null ? (frame.left + frame.width / 2) / stage.scale : stroller.sample(_clock()).x;
      _park(Offset(x, frame.bottom / stage.scale), stage);
    }
    if (_canRoam) unawaited(_measure());
    unawaited(refresh());
  }

  void _motionChanged() {
    if (onTaskbar) _tick();
  }

  bool _onlyMoments = false;

  /// Patch arrived or left, Mochi's world started a moment (or, with "only for interesting moments", a moment began or
  /// ended).
  void _companionChanged() {
    if (_disposed) return;
    if (_wantsPatch != _patchWanted && _surface == Surface.pet) unawaited(_enqueue(_place));
  }

  /// While Mochi's world reacts (a moment together with Patch, Claude's news, a pet: the Mac's roamer freezes for
  /// these), Mochi holds still where it is, once per moment, for as long as the moment has left.
  void _holdForWorld() {
    final world = companion?.host;
    if (_disposed || world == null || !world.reacting || !onTaskbar || _dragging || _surface != Surface.pet || !stroller.isPlaced) return;
    final moment = world.world.interaction?.startedAt ?? world.world.pet.current.token;
    if (moment == _heldFor) return;
    _heldFor = moment;
    stroller.react(_clock(), world.reactionLeft);
    _tick();
  }

  void _start() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    _fullscreen = _fullscreenBusy();
    _paused = _unseen;
    if (!_paused) _checkTimer = Timer.periodic(checkInterval, (_) => _check());
  }

  /// The screen went out of sight (the display off, the PC locked or asleep) or came back.
  void _rhythmChanged() {
    final unseen = _unseen;
    if (unseen == _paused || !_observing || _disposed) return;
    _paused = unseen;
    log?.call(unseen ? 'paused: nobody can see the screen' : 'resumed: the screen is back');
    if (unseen) {
      _halt();
      _pointerTimer?.cancel();
      _pointerTimer = null;
      _checkTimer?.cancel();
      _checkTimer = null;
      return;
    }
    _checkTimer ??= Timer.periodic(checkInterval, (_) => _check());
    if (onTaskbar) {
      if (_pointerTimer == null) {
        _pointerTimer = Timer.periodic(pointerInterval, (_) => _pointer());
        _pointerEvery = pointerInterval;
      }
      _nearPointer = false;
      // From where Mochi is now (its plan ran on while nobody saw it).
      stroller.resume(_clock());
      _pointer();
      _tick();
    }
    // The taskbar may have changed meanwhile.
    _fingerprint = null;
    _check();
  }

  /// When the buttons were last measured (the stroll's clock), and what the taskbar looked like then.
  double _measuredAt = double.negativeInfinity;
  Object? _fingerprint;

  /// Whether to measure the buttons now: something on the taskbar may have moved (its fingerprint changed), or it's
  /// been a while. Never while Mochi naps (nothing changes for it then); it measures when it wakes.
  bool _shouldMeasure() {
    if (!_canRoam || _fullscreen || _mood == PetMood.napping) return false;
    final fingerprint = taskbar.fingerprint();
    return fingerprint == null || fingerprint != _fingerprint || _clock() - _measuredAt >= measureAtLeast.inMicroseconds / 1e6;
  }

  /// The desktop pet isn't where its place says (on the displays there are now).
  bool _standingMoved() {
    final list = displays.list();
    final window = shell.petWindow;
    if (list.isEmpty || window == null) return false;
    final want = PetPlacing.frameFor(
      list,
      places: settings.petPlaces,
      last: settings.petDisplay,
      size: standingSize,
      box: settings.petSize.stage,
      legacy: settings.petPosition,
    ).frame;
    return window.frame() != want;
  }

  void _stop() {
    _momentTimer?.cancel();
    _momentTimer = null;
    _halt();
    _popoverTimer?.cancel();
    _popoverTimer = null;
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
    if (_dragging || _paused) return;
    _checks++;
    final busy = _fullscreenBusy();
    if (busy != _fullscreen) {
      _fullscreen = busy;
      unawaited(_enqueue(_place));
      return;
    }
    if (_checks % measureChecks == 0 && _shouldMeasure()) unawaited(_measure());
    if (_checks % taskbarChecks == 0) unawaited(_enqueue(_place));
  }

  // A display or its scale changed (or the window's own size): look at the taskbar again once things settle.
  @override
  void didChangeMetrics() {
    _metricsTimer?.cancel();
    _metricsTimer = Timer(const Duration(milliseconds: 400), () {
      if (_dragging) return;
      // A display came or went, or changed its scale: the desktop pet goes to its place there.
      if (_placement == PetPlacement.standing && _standingMoved()) _standingDirty = true;
      if (_canRoam) unawaited(_measure());
      unawaited(refresh());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    _precise(false);
    if (_covered) shell.petWindow?.uncover();
    unawaited(_cues.cancel());
    unawaited(_celebrations?.cancel());
    settings.removeListener(_settingsChanged);
    motion.removeListener(_motionChanged);
    companion?.removeListener(_companionChanged);
    companion?.host.removeListener(_holdForWorld);
    rhythm?.removeListener(_rhythmChanged);
    super.dispose();
  }
}
