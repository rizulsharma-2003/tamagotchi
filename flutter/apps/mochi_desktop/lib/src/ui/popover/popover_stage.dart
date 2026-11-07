// The popover's window, from Mochi's click on the taskbar to Mochi landing back on it.
//
// The OS window is never animated: it's set once to its final rect (the panel, plus the stretch of taskbar Mochi
// leaps from and to) while everything in it is still where it was on screen, and the transitions run inside it,
// driven by the display's vsync:
//
// - Opening (450 ms genie, Mochi landing in the room at 500 ms): the panel genies out of Mochi's spot (genie.dart: a
//   mesh warp of one picture of the panel, taken before anything moves), and Mochi leaps up from the taskbar into its
//   place in the room; Patch's desk on the taskbar fades.
// - Open: the live popover.
// - Closing (380 ms genie, Mochi landing at ~0.6 s): the panel funnels back into Mochi's spot while Mochi leaps out of
//   the room in an arc, squashes on landing with a puff of dust, exactly on its spot at taskbar size; Patch's desk
//   fades back in. Only then does the window go back to the taskbar's size (by then the drawing is already where the
//   taskbar pet draws it, so nothing moves).
// - Animation effects off: a quick fade in and out (120 ms), no genie and no leap.
//
// While a transition runs nothing is rebuilt or laid out: each frame only repaints the transition's painter, which
// reads the ticker's time itself; the live panel stays painted out of sight with its own animations paused.
//
// Everything here is drawn in screen coordinates made local to the window, and the window's origin is told from its
// size (the popover's rect, or still the pet's before the move lands), so no frame ever puts anything in the wrong place.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../desktop.dart';
import '../../platform/taskbar.dart' show HomeStage;
import '../pet/companion_director.dart';
import 'frame_meter.dart';
import 'genie.dart';
import 'popover_view.dart';

/// Where the popover goes, and what it comes out of (screen coordinates, logical pixels).
@immutable
class PopoverGeometry {
  const PopoverGeometry({
    required this.window,
    required this.panel,
    required this.petWindow,
    this.mochi,
    this.mochiScale = 0.56,
    this.facing = 1,
    this.home,
  });

  /// The window while the popover shows: the panel, and the stretch of taskbar Mochi leaps from and back to.
  final Rect window;

  /// The panel itself.
  final Rect panel;

  /// The pet's window before the popover opened: the window goes back to that after Mochi lands.
  final Rect petWindow;

  /// Mochi's feet on the taskbar, its size there and which way it faces (null: it wasn't on the taskbar).
  final Offset? mochi;
  final double mochiScale;
  final double facing;

  /// Patch's spot, while he was on the taskbar with Mochi (his desk is drawn at Mochi's baseline).
  final HomeStage? home;

  /// [rect] in the window (from its top-left).
  Rect local(Rect rect, Offset origin) => rect.shift(-origin);
}

enum PopoverPhase {
  opening,
  open,

  /// About to close: the live panel without Mochi in its room, and Mochi (drawn for its leap) in its place.
  leaving,
  closing,
}

class PopoverStage extends StatefulWidget {
  const PopoverStage({
    super.key,
    required this.geometry,
    required this.closing,
    required this.leapBack,
    required this.desktop,
    required this.companion,
    required this.library,
    required this.panel,
    required this.onOpened,
    required this.onClosed,
    this.ready,
    this.meter,
  });

  /// Completes once the window is in place for the popover (null: it already is). The genie starts after that.
  final Future<void>? ready;

  /// Development: times the transitions' frames (with the stroll's debug log on).
  final FrameMeter? meter;

  final PopoverGeometry geometry;

  /// The popover should close (Escape, a click elsewhere, a second click on Mochi's spot).
  final bool closing;

  /// Mochi goes back to its spot on the taskbar when it closes (otherwise it stays in the panel as it goes).
  final bool leapBack;
  final MochiDesktop desktop;
  final CompanionDirector companion;
  final PoseLibrary? library;

  /// The popover's contents; [hidePet] while Mochi leaps in or out of its room.
  final Widget Function(bool hidePet) panel;

  final VoidCallback onOpened;

  /// Mochi has landed (or the fade is done): the window can go back to the taskbar.
  final VoidCallback onClosed;

  /// The transitions' lengths.
  static const Duration opening = Duration(milliseconds: 500);
  static const Duration genieIn = Duration(milliseconds: 450);
  static const Duration closingLength = Duration(milliseconds: 640);
  static const Duration genieOut = Duration(milliseconds: 380);
  static const Duration fade = Duration(milliseconds: 120);

  /// How long the panel's picture may take (the first time, the panel is drawn for the first time too) before the genie
  /// warps its plain shape instead.
  static const Duration pictureWait = Duration(milliseconds: 400);

  @override
  State<PopoverStage> createState() => PopoverStageState();
}

class PopoverStageState extends State<PopoverStage> with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this);
  final GlobalKey _panelKey = GlobalKey();
  PopoverPhase _phase = PopoverPhase.opening;
  ui.Image? _picture;
  bool _calm = false;
  bool _started = false;
  final Stopwatch _clock = Stopwatch()..start();

  /// The live panel, built once for each [PopoverStage.panel] and hidePet (nothing in it is rebuilt while Mochi leaps).
  Widget? _live;
  Widget Function(bool hidePet)? _liveFrom;
  bool? _liveHidesPet;

  PopoverPhase get phase => _phase;

  /// Windows wakes Flutter for a frame with a timer that never fires sooner than 10 ms (USER_TIMER_MINIMUM), so a frame
  /// due sooner starts late and often misses its vsync. While a transition runs, a 1 ms timer keeps Flutter's task
  /// runner awake (each Dart timer posts it a message) and each frame starts on time; the stroll makes Windows' timers
  /// precise meanwhile.
  Timer? _pump;

  void _pumping(bool on) {
    if (on != (_pump != null)) widget.meter?.log('1 ms pump: ${on ? 'on' : 'off'}');
    _pump?.cancel();
    _pump = on && Platform.isWindows ? Timer.periodic(const Duration(milliseconds: 1), (_) {}) : null;
  }

  Future<void> _run() async {
    _pumping(true);
    try {
      await _motion.forward(from: 0).orCancel;
    } on TickerCanceled {
      // Gone (disposed).
    } finally {
      _pumping(false);
    }
  }

  @override
  void initState() {
    super.initState();
    // Each frame of a transition only repaints the stage's painter (it listens to the ticker itself): no rebuild, no
    // layout, nothing else repainted.
    final meter = widget.meter;
    if (meter != null) _motion.addListener(meter.tick);
    meter?.mark('stage');
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void didUpdateWidget(PopoverStage old) {
    super.didUpdateWidget(old);
    if (widget.closing && !old.closing) _close();
  }

  bool get _still => MediaQuery.disableAnimationsOf(context);

  Future<void> _ready() => (widget.ready ?? Future<void>.value()).catchError((Object _) {});

  Future<void> _open() async {
    if (!mounted || _started) return;
    _started = true;
    _calm = _still;
    final meter = widget.meter;
    if (_calm) {
      await _ready();
      if (!mounted) return;
      _motion.duration = PopoverStage.fade;
      setState(() {});
      await _run();
    } else {
      // One picture of the panel (taken while the window is still being put in place), then the genie warps only that.
      meter?.mark('capture');
      final (picture, _) = await (_capture(), _ready()).wait;
      _picture = picture;
      if (!mounted) return;
      final captured =
          'picture ${picture == null ? 'none' : '${picture.width}x${picture.height}'}, ready ${meter?.since('capture').round()} ms after the stage';
      _motion.duration = PopoverStage.opening;
      setState(() {});
      meter?.start('open');
      await _run();
      meter?.stop(captured);
    }
    if (!mounted) return;
    setState(() => _phase = PopoverPhase.open);
    widget.onOpened();
    if (widget.closing) _close();
  }

  Future<void> _close() async {
    if (_phase != PopoverPhase.open) return;
    _calm = _still;
    _picture?.dispose();
    _picture = null;
    _motion.value = 0;
    final meter = widget.meter;
    if (!_calm) {
      // Mochi steps out of the room for its leap (drawn in its very place), then the panel's picture is taken.
      setState(() => _phase = PopoverPhase.leaving);
      meter?.mark('capture');
      _picture = await _capture();
      if (!mounted) return;
    }
    final captured =
        'picture ${_picture == null ? 'none' : '${_picture!.width}x${_picture!.height}'} in ${meter?.since('capture').round()} ms';
    _motion.duration = _calm ? PopoverStage.fade : PopoverStage.closingLength;
    setState(() => _phase = PopoverPhase.closing);
    meter?.start('close');
    await _run();
    meter?.stop(captured);
    if (mounted) widget.onClosed();
  }

  /// A picture of the panel as it is now (laid out and painted, though not shown, during the transitions). Null if it
  /// can't be had (the genie then warps the panel's plain shape).
  Future<ui.Image?> _capture() async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary = _panelKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !mounted) return null;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final done = Completer<ui.Image?>();
    final timeout = Timer(PopoverStage.pictureWait, () {
      if (!done.isCompleted) done.complete(null);
    });
    unawaited(
      boundary
          .toImage(pixelRatio: ratio)
          .then(
            (image) => done.isCompleted ? image.dispose() : done.complete(image),
            onError: (Object _) => done.isCompleted ? null : done.complete(null),
          ),
    );
    final image = await done.future;
    timeout.cancel();
    return image;
  }

  @override
  void dispose() {
    _pumping(false);
    _motion.dispose();
    _picture?.dispose();
    super.dispose();
  }

  Widget _livePanel(bool hidePet) {
    if (_live == null || !identical(_liveFrom, widget.panel) || _liveHidesPet != hidePet) {
      _live = widget.panel(hidePet);
      _liveFrom = widget.panel;
      _liveHidesPet = hidePet;
    }
    return _live!;
  }

  /// The live panel's opacity: a fade with animation effects off, otherwise all or (out of sight) nothing.
  Animation<double> get _fade => switch (_phase) {
    PopoverPhase.opening when _calm => _motion,
    PopoverPhase.closing when _calm => ReverseAnimation(_motion),
    _ => kAlwaysCompleteAnimation,
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final g = widget.geometry;
      final size = constraints.biggest;
      // Until the move lands the window is still the pet's: draw where things were.
      final settled = (size.width - g.window.width).abs() < 2 && (size.height - g.window.height).abs() < 2;
      final origin = settled ? g.window.topLeft : g.petWindow.topLeft;
      final panel = g.local(g.panel, origin);
      final open = _phase == PopoverPhase.open;
      final calm = _calm;
      // The live panel: shown when open (and in a fade); laid out and painted but out of sight otherwise, for its
      // picture, with its own animations (the room) paused.
      final shown = open || _phase == PopoverPhase.leaving || (calm && _started);
      final hidePet =
          !calm && widget.leapBack && (_phase == PopoverPhase.opening || _phase == PopoverPhase.leaving || _phase == PopoverPhase.closing);
      return Stack(
        children: [
          Positioned.fromRect(
            rect: panel,
            child: IgnorePointer(
              ignoring: !open,
              // (A clipper also limits where clicks land, so the shown panel has none.)
              child: ClipRect(
                clipper: shown ? null : const _Nothing(),
                clipBehavior: shown ? Clip.none : Clip.hardEdge,
                child: FadeTransition(
                  opacity: _fade,
                  child: RepaintBoundary(
                    key: _panelKey,
                    child: TickerMode(enabled: open, child: _livePanel(hidePet)),
                  ),
                ),
              ),
            ),
          ),
          if (!open)
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _TransitionPainter(
                      motion: _motion,
                      geometry: g,
                      origin: origin,
                      phase: _phase,
                      calm: calm,
                      picture: _picture,
                      leapBack: widget.leapBack,
                      showPanel: settled,
                      library: widget.library,
                      companion: widget.companion,
                      desktop: widget.desktop,
                      dark: Theme.of(context).brightness == Brightness.dark,
                      surface: context.palette.surface,
                      clock: _clock,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Clips to nothing: the child is painted (so its picture can be taken) but never seen.
class _Nothing extends CustomClipper<Rect> {
  const _Nothing();

  @override
  Rect getClip(Size size) => Rect.zero;

  @override
  bool shouldReclip(_Nothing old) => false;
}

/// One frame of a transition: the panel's genie, Mochi's leap, Patch's desk fading. It repaints with the ticker
/// ([motion]) and reads the time itself, so a frame that comes late still shows where things are at that moment.
class _TransitionPainter extends CustomPainter {
  _TransitionPainter({
    required this.motion,
    required this.geometry,
    required this.origin,
    required this.phase,
    required this.calm,
    required this.picture,
    required this.leapBack,
    required this.showPanel,
    required this.library,
    required this.companion,
    required this.desktop,
    required this.dark,
    required this.surface,
    required this.clock,
  }) : super(repaint: motion);

  final AnimationController motion;
  final PopoverGeometry geometry;
  final Offset origin;
  final PopoverPhase phase;
  final bool calm;
  final ui.Image? picture;
  final bool leapBack;
  final bool showPanel;
  final PoseLibrary? library;
  final CompanionDirector companion;
  final MochiDesktop desktop;
  final bool dark;
  final Color surface;
  final Stopwatch clock;

  static double _clamp(double x) => x.clamp(0.0, 1.0).toDouble();

  /// Milliseconds into the running transition.
  double get _elapsed => motion.value * (motion.duration?.inMicroseconds ?? 0) / 1000;

  double get _time => clock.elapsedMicroseconds / 1e6;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final elapsed = _elapsed;
    final opening = phase == PopoverPhase.opening;
    final panel = g.local(g.panel, origin);
    final mochi = g.mochi?.translate(-origin.dx, -origin.dy);
    final spot = mochi ?? Offset(panel.center.dx, panel.bottom);
    if (calm) {
      // A quick fade: Mochi fades on the taskbar as the panel fades in (the live panel's own opacity).
      final t = _clamp(elapsed / PopoverStage.fade.inMilliseconds);
      if (mochi != null) _taskbar(canvas, mochi, opening ? 1 - t : t);
      return;
    }
    if (phase == PopoverPhase.leaving) {
      // The live panel is up; only Mochi, where it stands in the room, ready to leap.
      final room = PopoverView.petInRoom(g.panel.width);
      final inRoom = panel.topLeft + room.feet;
      if (mochi != null && leapBack) {
        _mochi(canvas, Leap(from: inRoom, to: mochi, fromScale: room.scale, toScale: g.mochiScale), 0, facing: 1);
      }
      return;
    }
    // The genie: out with an ease-out (quick, then settling), back in with an ease-in (gathering speed into Mochi).
    if (showPanel) {
      final t = opening
          ? _clamp(elapsed / PopoverStage.genieIn.inMilliseconds)
          : 1 - _clamp(elapsed / PopoverStage.genieOut.inMilliseconds);
      if (t > 0) _genie(canvas, Genie(panel: panel, spot: Offset(spot.dx, spot.dy - 6)), t);
    }
    if (mochi == null) return;
    // Patch's desk on the taskbar fades out as the popover opens, and back in as Mochi comes home.
    final duo = opening ? 1 - _clamp(elapsed / 150) : (leapBack ? _clamp((elapsed - 220) / 220) : 0.0);
    // Mochi's leap.
    final room = PopoverView.petInRoom(g.panel.width);
    final inRoom = panel.topLeft + room.feet;
    if (opening) {
      final leap = Leap(from: mochi, to: inRoom, fromScale: g.mochiScale, toScale: room.scale);
      final p = _clamp(elapsed / PopoverStage.opening.inMilliseconds);
      _duo(canvas, mochi, duo);
      _mochi(canvas, leap, p, facing: inRoom.dx >= mochi.dx ? 1 : -1);
    } else if (leapBack) {
      final leap = Leap(from: inRoom, to: mochi, fromScale: room.scale, toScale: g.mochiScale);
      final p = _clamp(elapsed / (PopoverStage.closingLength.inMilliseconds - 60));
      _duo(canvas, mochi, duo);
      _mochi(canvas, leap, p, facing: mochi.dx >= inRoom.dx ? 1 : -1, landingFacing: g.facing);
    }
  }

  void _genie(Canvas canvas, Genie genie, double t) {
    final alpha = Genie.opacity(t);
    final image = picture;
    // Bilinear, no mipmaps: plenty while it moves, and cheap for a PC drawing without a graphics card. The fade-in is
    // the paint's own alpha (no offscreen layer).
    final paint = Paint()
      ..filterQuality = FilterQuality.low
      ..color = Color.fromRGBO(0, 0, 0, alpha);
    if (image != null) {
      final ratio = image.width / math.max(1, genie.panel.width);
      paint.shader = ImageShader(image, TileMode.clamp, TileMode.clamp, Matrix4.identity().storage, filterQuality: FilterQuality.low);
      final vertices = genie.vertices(t, Size(genie.panel.width * ratio, genie.panel.height * ratio));
      canvas.drawVertices(vertices, BlendMode.srcOver, paint);
      vertices.dispose();
    } else {
      // No picture: the panel's plain shape.
      paint.color = surface.withValues(alpha: alpha);
      final vertices = genie.vertices(t, genie.panel.size);
      canvas.drawVertices(vertices, BlendMode.srcOver, paint);
      vertices.dispose();
    }
  }

  /// Mochi at [p] through [leap].
  void _mochi(Canvas canvas, Leap leap, double p, {required double facing, double? landingFacing}) {
    final settings = desktop.settings;
    var pose = library?.petTrack(PetAnimation.idle)?.at(_time) ?? PetPose();
    final (sx, sy) = leap.squash(p);
    pose
      ..scaleX *= sx
      ..scaleY *= sy;
    final face = p > 1 - Leap.land && landingFacing != null ? landingFacing : facing;
    if (face < 0) pose = pose.mirrored();
    final feet = leap.feet(p);
    final scale = leap.scale(p);
    final g = GContext(canvas);
    PetRenderer.draw(
      pose,
      g,
      feet,
      scale,
      PetPalette(settings.petColor),
      accessory: settings.wornByPet(desktop.sessions.now),
      dark: dark,
      detail: scale < 0.8 ? RenderDetail.tiny : RenderDetail.standard,
    );
    final dust = leap.dust(p);
    if (dust > 0) {
      for (final side in [-1.0, 1.0]) {
        EffectRenderer.drawProp(
          SceneProp(ScenePropKind.dust, scale: 0.9 + 0.5 * dust, opacity: 0.8 * (1 - dust), variant: side > 0 ? 1 : 0),
          g,
          feet + Offset(side * (14 + 10 * dust) * scale / 0.56, -2),
          scale,
          dark,
        );
      }
    }
  }

  /// Mochi standing on the taskbar (the fade with animation effects off).
  void _taskbar(Canvas canvas, Offset feet, double opacity) {
    if (opacity <= 0) return;
    final settings = desktop.settings;
    final g = GContext(canvas)..opacity = opacity;
    final pose = library?.petTrack(PetAnimation.idle)?.at(_time) ?? PetPose();
    PetRenderer.draw(
      geometry.facing < 0 ? pose.mirrored() : pose,
      g,
      feet,
      geometry.mochiScale,
      PetPalette(settings.petColor),
      accessory: settings.wornByPet(desktop.sessions.now),
      dark: dark,
      detail: RenderDetail.tiny,
    );
    _duo(canvas, feet, opacity);
  }

  /// Patch at his desk on the taskbar, at [opacity].
  void _duo(Canvas canvas, Offset feet, double opacity) {
    final home = geometry.home;
    if (home == null || opacity <= 0 || !companion.visible) return;
    final settings = desktop.settings;
    final now = desktop.sessions.now;
    final g = GContext(canvas)..opacity = opacity;
    final desk = Offset(home.deskX - origin.dx, feet.dy);
    final pose = companion.pose(library, companion.time);
    CompanionRenderer.draw(
      pose,
      g,
      desk,
      home.unit,
      accessory: settings.wornByCompanion(now),
      dark: dark,
      time: 100 + _time,
      deskFront: (front) => ThemeRenderer.deskFront(settings.officeTheme, front, dark: dark, accessory: settings.deskAccessory),
    );
  }

  @override
  bool shouldRepaint(_TransitionPainter old) => true;
}

/// Test hook: the stage's phase, for the tests that drive it.
@visibleForTesting
PopoverPhase? popoverPhaseOf(Element element) =>
    element is StatefulElement && element.state is PopoverStageState ? (element.state as PopoverStageState).phase : null;
