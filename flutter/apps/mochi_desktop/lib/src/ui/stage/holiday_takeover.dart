// Holiday takeover (docs/SPRINT_2.md X11, Mischief): on a day whose occasion has a takeover, a small decoration on the
// window you're using, or on the taskbar. Which occasion is today's is the holiday service's (core/holidays.dart:
// mochi_world's SeasonTracker, honouring Settings › Fun › Holidays), and only three have one:
//
// - Diwali: a string of little lights draped along the top edge of the window you're using. They twinkle at 3 a second
//   (never more than 4) and not at all with Windows' animation effects off.
// - Christmas: a thin cap of snow resting on that edge.
// - Halloween: two or three small pumpkins on the taskbar, in a free stretch between its buttons (the stroll's zones,
//   ui/pet/taskbar_stroll.dart), never over a button.
// - Any other occasion (a birthday, New Year, Valentine's Day): nothing.
//
// Never intrusive:
// - Only the window with the focus is decorated, and not a maximised, full-screen, minimised, cloaked or tiny (< 300 logical
//   pixels wide) one, not Mochi's own windows, the desktop or the taskbar, and not one whose top edge is within 12 logical
//   pixels of the display's top (no room above it).
// - The decoration sits above the window's top edge and dips at most 6 logical pixels into the frame. The right 150 logical
//   pixels of the edge stay bare (minimise, maximise, close). Every actor is click-through.
// - While the window moves or resizes the decoration is hidden, and comes back once its frame has been still for half a
//   second. When the focus moves to another window the decoration follows.
// - The actors are in the normal band of windows (not topmost): raised to its top when placed, they stay under always-on-top
//   windows. The pumpkins are on the taskbar's level, topmost like Mochi.
// - Only while the occasion has a takeover, MischiefGate allows it and the screen can be seen: the foreground window and its
//   frame are read three times a second (the calls Peekaboo's and the adventure's survey already make; nothing new), the
//   pumpkins' stretch every two seconds from a field the stroll keeps. Otherwise there is no timer at all.
//
// Settings › Mischief › "Try it" previews an occasion for 20 seconds. `MOCHI_DESKTOP_TAKEOVER=diwali|christmas|halloween`
// forces an occasion (for checking on a PC).

import 'dart:async';
import 'dart:math' as math;

import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/holidays.dart';
import '../../core/mischief.dart';
import '../../core/pc_rhythm.dart';
import '../../platform/displays.dart';
import '../../platform/foreground_window.dart';
import '../../platform/native_stage.dart';
import '../../platform/taskbar.dart' show PixelRect, TaskbarStage;
import '../../platform/window_frames.dart';
import 'stage_cast.dart';
import 'stage_sprites.dart';
import 'takeover_art.dart';

class HolidayTakeover {
  HolidayTakeover({
    required this.stage,
    required this.cast,
    required this.gate,
    required this.rhythm,
    required this.holidays,
    required this.displays,
    required this.frames,
    required this.foreground,
    this.taskbar,
    this.force,
    bool Function()? dark,
    double Function()? seconds,
  }) : sprites = StageSprites(stage, budget: 6 << 20),
       _dark = dark ?? (() => false),
       _seconds = seconds ?? _monotonic();

  final NativeStage stage;
  final StageCast cast;
  final MischiefGate gate;
  final PcRhythm rhythm;
  final DesktopHolidays holidays;
  final Displays displays;
  final WindowFrames frames;
  final ForegroundWindows foreground;
  final StageSprites sprites;

  /// The main taskbar as the stroll last measured it (null: Mochi isn't on one), for the pumpkins.
  final TaskbarStage? Function()? taskbar;

  /// Development: this occasion whatever the calendar says (`MOCHI_DESKTOP_TAKEOVER`).
  final w.SeasonalEvent? force;
  final bool Function() _dark;
  final double Function() _seconds;

  static double Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds / 1e6;
  }

  /// The windows are read this often a second.
  static const double rate = 3;

  /// The taskbar's free stretch is looked at every this many seconds, for the pumpkins.
  static const Duration pumpkinLook = Duration(seconds: 2);

  /// A window's frame must have been still this long (seconds) before the decoration comes back.
  static const double settle = 0.5;

  /// The right part of the top edge left bare (logical pixels): the caption buttons.
  static const double captionGap = 150;

  /// Where along the edge the decoration starts, and the narrowest and widest strips (logical pixels).
  static const double inset = 12;
  static const double narrowest = 96;
  static const double widest = 1600;

  /// Windows narrower than this (logical pixels) and with their top edge nearer the display's top than [roomAbove] are left
  /// alone.
  static const double tiny = 300;
  static const double roomAbove = 12;

  /// A preview lasts this long.
  static const Duration previewLasts = Duration(seconds: 20);

  /// Pumpkins: the space each takes (logical pixels) and the most there are.
  static const double pumpkinPitch = 30;
  static const int pumpkinsAtMost = 3;

  /// The occasions that have a takeover.
  static bool takes(w.SeasonalEvent? event) =>
      event == w.SeasonalEvent.diwali || event == w.SeasonalEvent.christmas || event == w.SeasonalEvent.halloween;

  bool _started = false;
  bool _disposed = false;
  w.SeasonalEvent? _event;
  w.SeasonalEvent? _preview;
  Timer? _previewTimer;
  Timer? _timer;
  bool _timerForPumpkins = false;

  final List<int> _actors = [];

  // The window being decorated.
  int? _hwnd;
  PixelRect? _frame;
  double _movedAt = 0;
  int _beat = 0;
  (int, int, int, int, int)? _raised;

  /// Reads of the foreground window so far (tests, the perf meter).
  int looks = 0;

  /// The occasion being shown now (null: none).
  w.SeasonalEvent? get active => _event;

  /// A timer is running (tests: none while it's closed, the screen is unseen, or there's no occasion).
  bool get watching => _timer != null;

  /// The actors showing now.
  List<int> get showing => [for (final actor in _actors) if (cast.showing(actor)) actor];

  void start() {
    if (_started) return;
    _started = true;
    gate.addListener(update);
    gate.onStop(_gateStopped);
    holidays.addListener(update);
    rhythm.addListener(update);
    update();
  }

  /// The gate was stopped (the app is closing): nothing runs, and nothing is showing.
  void _gateStopped() {
    if (_disposed) return;
    _event = null;
    _timer?.cancel();
    _timer = null;
    _forget();
    _hide();
  }

  /// The occasion to show now, or null: the gate says no, the screen can't be seen, or today has no takeover.
  w.SeasonalEvent? _occasion() {
    if (!_started || _disposed || rhythm.unseen) return null;
    final preview = _preview;
    if (preview != null) {
      final why = gate.why(MischiefExtra.holidayTakeover);
      return {MischiefPause.unsupported, MischiefPause.unseen, MischiefPause.fullScreen}.contains(why) ? null : preview;
    }
    if (!gate.may(MischiefExtra.holidayTakeover)) return null;
    final event = force ?? holidays.event;
    return takes(event) ? event : null;
  }

  /// The switches, the holiday, the gate or the screen changed: start, change or stop.
  void update() {
    final event = _occasion();
    if (event == null) {
      _event = null;
      _timer?.cancel();
      _timer = null;
      _forget();
      _hide();
      return;
    }
    final pumpkins = event == w.SeasonalEvent.halloween;
    if (event != _event || _timer == null || pumpkins != _timerForPumpkins) {
      if (_event != event) _hide();
      _event = event;
      _timerForPumpkins = pumpkins;
      _timer?.cancel();
      _timer = Timer.periodic(pumpkins ? pumpkinLook : Duration(milliseconds: (1000 / rate).round()), (_) => look());
    }
    look();
  }

  /// Settings' "Try it": [event]'s takeover for 20 seconds (even when it isn't that day, and during quiet hours: you asked).
  bool preview(w.SeasonalEvent event) {
    if (!_started || !takes(event)) return false;
    final why = gate.why(MischiefExtra.holidayTakeover);
    if ({MischiefPause.unsupported, MischiefPause.unseen, MischiefPause.fullScreen}.contains(why)) return false;
    _previewTimer?.cancel();
    _preview = event;
    _previewTimer = Timer(previewLasts, () {
      _previewTimer = null;
      _preview = null;
      update();
    });
    update();
    return _event != null;
  }

  /// One look: the foreground window (or the taskbar) and the decoration to match.
  void look() {
    if (_disposed || _event == null) return;
    if (_event == w.SeasonalEvent.halloween) {
      _pumpkins();
    } else {
      _window(_event!);
    }
  }

  // MARK: The window you're using

  void _window(w.SeasonalEvent event) {
    looks++;
    final front = foreground.read();
    if (front == null || front.kind != ForegroundKind.app) {
      _forget();
      return _hide();
    }
    final window = frames.frame(front.hwnd);
    if (window == null) {
      _forget();
      return _hide();
    }
    final now = _seconds();
    if (_hwnd != window.hwnd) {
      // Another window has the focus: the decoration moves to it (a window not yet seen isn't moving).
      _hwnd = window.hwnd;
      _frame = window.frame;
      _movedAt = now - settle;
    } else if (_frame != window.frame) {
      // Moving or resizing: hidden until it has been still for a moment.
      _frame = window.frame;
      _movedAt = now;
      return _hide();
    }
    final display = _displayOf(window.frame);
    if (display == null || window.zoomed || _skip(window.frame, display)) return _hide();
    if (now - _movedAt < settle) return _hide();
    _show(event, window, display);
  }

  /// The display most of the window's top edge is on.
  DisplayArea? _displayOf(PixelRect frame) {
    final x = (frame.left + frame.right) ~/ 2, y = frame.top + 1;
    for (final display in displays.list()) {
      if (display.monitor.contains(x, y)) return display;
    }
    return null;
  }

  /// A window that gets none: covering its display (full screen), narrower than 300 logical pixels, or with no room above.
  bool _skip(PixelRect frame, DisplayArea display) {
    final scale = display.scale;
    final monitor = display.monitor;
    if (frame.left <= monitor.left && frame.top <= monitor.top && frame.right >= monitor.right && frame.bottom >= monitor.bottom) return true;
    if (frame.width / scale < tiny) return true;
    return (frame.top - monitor.top) / scale < roomAbove;
  }

  void _show(w.SeasonalEvent event, WindowFrame window, DisplayArea display) {
    final scale = display.scale;
    final usable = window.frame.width / scale - inset - captionGap;
    final width = math.min(widest, (usable / 24).floor() * 24.0);
    if (width < narrowest) return _hide();
    final dark = _dark();
    sprites.use('takeover|$scale|$dark');
    final diwali = event == w.SeasonalEvent.diwali;
    final frames = diwali ? TakeoverArt.twinkleFrames : 1;
    // Twinkling steps through its frames as the windows are read; with animation effects off the lights stay as they are.
    final twinkle = diwali && !gate.motion.reduced;
    final frame = twinkle ? _beat++ % frames : 0;
    String key(int f) => '${event.name}|${width.round()}|$f';
    SpriteRecipe recipe(int f) => SpriteRecipe(
      bounds: TakeoverArt.stripBounds(width),
      ratio: scale,
      paint: (canvas) => diwali
          ? TakeoverArt.lights(canvas, width, frame: twinkle ? f : -1, dark: dark)
          : TakeoverArt.snow(canvas, width, dark: dark),
    );
    final ready = sprites.lookup(key(frame));
    if (ready == null) {
      // Drawn once (all of the twinkle's frames together); shown from the next look.
      unawaited(sprites.prepare({for (var f = 0; f < frames; f++) key(f): recipe(f)}));
      return;
    }
    final actor = _actor(0);
    final left = window.frame.left + (inset * scale).round();
    cast.place(ready.at(actor, left, window.frame.top, clickThrough: true, topmost: false));
    cast.flush();
    // At the top of the normal band when it's placed or the window moved, not on every twinkle.
    final place = (window.hwnd, left, window.frame.top, width.round(), actor);
    if (_raised != place) {
      _raised = place;
      stage.raise([actor]);
    }
  }

  // MARK: The taskbar

  void _pumpkins() {
    final bar = taskbar?.call();
    if (bar == null || !bar.measured || bar.zones.isEmpty) return _hide();
    var zone = bar.zones.first;
    for (final candidate in bar.zones) {
      if (candidate.maxX - candidate.minX > zone.maxX - zone.minX) zone = candidate;
    }
    final room = zone.maxX - zone.minX;
    final count = math.min(pumpkinsAtMost, ((room - 14) / pumpkinPitch).floor() + 1);
    if (count < 2) return _hide();
    final scale = bar.scale;
    final dark = _dark();
    sprites.use('pumpkins|$scale|$dark');
    String key(int face) => 'pumpkin|$face';
    final ready = [for (var i = 0; i < count; i++) sprites.lookup(key(i))];
    if (ready.any((sprite) => sprite == null)) {
      unawaited(
        sprites.prepare({
          for (var i = 0; i < count; i++)
            key(i): SpriteRecipe(
              bounds: TakeoverArt.pumpkinBounds,
              ratio: scale,
              paint: (canvas) => TakeoverArt.pumpkin(canvas, face: i, dark: dark),
            ),
        }),
      );
      return;
    }
    // Standing on the stretch's right end, on Mochi's feet line.
    final feet = bar.boxBottom - (bar.box.height * 0.03 * scale).round();
    for (var i = 0; i < count; i++) {
      final x = ((zone.maxX - 14 - i * pumpkinPitch) * scale).round();
      cast.place(ready[i]!.at(_actor(i), x, feet, clickThrough: true, topmost: true));
    }
    for (var i = count; i < _actors.length; i++) {
      cast.hide(_actors[i]);
    }
    cast.flush();
  }

  // MARK: Putting it away

  int _actor(int index) {
    while (_actors.length <= index) {
      _actors.add(stage.newActor());
    }
    return _actors[index];
  }

  void _forget() {
    _hwnd = null;
    _frame = null;
  }

  void _hide() {
    _raised = null;
    var any = false;
    for (final actor in _actors) {
      if (cast.showing(actor)) {
        cast.hide(actor);
        any = true;
      }
    }
    if (any) cast.flush();
  }

  /// What's on, for the perf meter.
  String? perfState() => _event == null ? null : 'holiday takeover (${_event!.name}${cast.actors.any(_actors.contains) ? '' : ', resting'})';

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _previewTimer?.cancel();
    if (_started) {
      gate.removeListener(update);
      holidays.removeListener(update);
      rhythm.removeListener(update);
    }
    if (_actors.isNotEmpty) cast.remove(_actors);
    sprites.dispose();
  }
}
