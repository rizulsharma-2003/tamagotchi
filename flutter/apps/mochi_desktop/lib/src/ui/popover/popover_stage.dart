// The popover's window, from Mochi's click on the taskbar to Mochi landing back on it.
//
// The OS window is never animated: it's set once to its final rect (the panel, plus the stretch of taskbar Mochi
// leaps from and to) while everything in it is still where it was on screen, and the transitions run inside it,
// driven by the display's vsync:
//
// - Opening (380 ms): the panel genies out of Mochi's spot (genie.dart: a mesh warp of one picture of the panel), and
//   Mochi hops up from the taskbar into its place in the room; Patch's desk on the taskbar fades.
// - Open: the live popover.
// - Closing (320 ms genie, Mochi landing at ~0.5 s): the panel funnels back into Mochi's spot while Mochi leaps out of
//   the room in an arc, squashes on landing with a puff of dust, exactly on its spot at taskbar size; Patch's desk
//   fades back in. Only then does the window go back to the taskbar's size (by then the drawing is already where the
//   taskbar pet draws it, so nothing moves).
// - Animation effects off: a quick fade in and out (120 ms), no genie and no leap.
//
// Everything here is drawn in screen coordinates made local to the window, and the window's origin is told from its
// size (the popover's rect, or still the pet's before the move lands), so no frame ever puts anything in the wrong place.

import 'dart:async';
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
  });

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

  PopoverPhase get phase => _phase;

  /// Milliseconds into the running transition.
  double get _elapsed => _motion.value * (_motion.duration?.inMicroseconds ?? 0) / 1000;

  @override
  void initState() {
    super.initState();
    _motion.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void didUpdateWidget(PopoverStage old) {
    super.didUpdateWidget(old);
    if (widget.closing && !old.closing) _close();
  }

  bool get _still => MediaQuery.disableAnimationsOf(context);

  Future<void> _open() async {
    if (!mounted || _started) return;
    _started = true;
    _calm = _still;
    if (_calm) {
      _motion.duration = PopoverStage.fade;
      await _motion.forward(from: 0).orCancel.catchError((_) {});
    } else {
      _picture = await _capture();
      if (!mounted) return;
      _motion.duration = PopoverStage.opening;
      await _motion.forward(from: 0).orCancel.catchError((_) {});
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
    if (!_calm) {
      // Mochi steps out of the room for its leap (drawn in its very place), then the panel's picture is taken.
      setState(() => _phase = PopoverPhase.leaving);
      _picture = await _capture();
      if (!mounted) return;
    }
    setState(() => _phase = PopoverPhase.closing);
    _motion.duration = _calm ? PopoverStage.fade : PopoverStage.closingLength;
    await _motion.forward(from: 0).orCancel.catchError((_) {});
    if (mounted) widget.onClosed();
  }

  /// A picture of the panel as it is now (drawn, though not shown, during the transitions). Null if it can't be had
  /// quickly: the genie then warps the panel's plain shape.
  Future<ui.Image?> _capture() async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary = _panelKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !mounted) return null;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final done = Completer<ui.Image?>();
    final timeout = Timer(const Duration(milliseconds: 120), () {
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
    _motion.dispose();
    _picture?.dispose();
    super.dispose();
  }

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
      final ms = _elapsed;
      final calm = _calm;
      // The live panel: shown when open (and in a fade); drawn but out of sight otherwise, for its picture.
      final double liveOpacity = switch (_phase) {
        PopoverPhase.open || PopoverPhase.leaving => 1,
        PopoverPhase.opening when calm => _motion.value,
        PopoverPhase.closing when calm => 1 - _motion.value,
        _ => 0,
      };
      final hidePet =
          !calm && widget.leapBack && (_phase == PopoverPhase.opening || _phase == PopoverPhase.leaving || _phase == PopoverPhase.closing);
      final live = RepaintBoundary(key: _panelKey, child: widget.panel(hidePet));
      return Stack(
        children: [
          if (settled)
            Positioned.fromRect(
              rect: panel,
              child: liveOpacity >= 1
                  ? live
                  : liveOpacity > 0
                  ? Opacity(
                      opacity: liveOpacity,
                      child: IgnorePointer(child: live),
                    )
                  : IgnorePointer(
                      child: ClipRect(clipper: const _Nothing(), child: live),
                    ),
            ),
          if (!open)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TransitionPainter(
                    geometry: g,
                    origin: origin,
                    phase: _phase,
                    elapsed: ms,
                    calm: calm,
                    picture: _picture,
                    pictureSize: panel.size * MediaQuery.devicePixelRatioOf(context),
                    leapBack: widget.leapBack,
                    showPanel: settled,
                    library: widget.library,
                    companion: widget.companion,
                    desktop: widget.desktop,
                    dark: Theme.of(context).brightness == Brightness.dark,
                    surface: context.palette.surface,
                    time: _clock.elapsedMicroseconds / 1e6,
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

/// One frame of a transition: the panel's genie, Mochi's leap, Patch's desk fading.
class _TransitionPainter extends CustomPainter {
  _TransitionPainter({
    required this.geometry,
    required this.origin,
    required this.phase,
    required this.elapsed,
    required this.calm,
    required this.picture,
    required this.pictureSize,
    required this.leapBack,
    required this.showPanel,
    required this.library,
    required this.companion,
    required this.desktop,
    required this.dark,
    required this.surface,
    required this.time,
  });

  final PopoverGeometry geometry;
  final Offset origin;
  final PopoverPhase phase;
  final double elapsed;
  final bool calm;
  final ui.Image? picture;
  final Size pictureSize;
  final bool leapBack;
  final bool showPanel;
  final PoseLibrary? library;
  final CompanionDirector companion;
  final MochiDesktop desktop;
  final bool dark;
  final Color surface;
  final double time;

  static double _clamp(double x) => x.clamp(0.0, 1.0).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
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
    // The genie.
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
    final paint = Paint()..filterQuality = FilterQuality.medium;
    if (image != null) {
      final ratio = image.width / math.max(1, genie.panel.width);
      paint.shader = ImageShader(image, TileMode.clamp, TileMode.clamp, Matrix4.identity().storage);
      final vertices = genie.vertices(t, Size(genie.panel.width * ratio, genie.panel.height * ratio));
      if (alpha < 1) canvas.saveLayer(genie.bounds(t).inflate(2), Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
      canvas.drawVertices(vertices, BlendMode.srcOver, paint);
      if (alpha < 1) canvas.restore();
      vertices.dispose();
    } else {
      // No picture (yet): the panel's plain shape.
      paint.color = surface.withValues(alpha: alpha);
      final vertices = genie.vertices(t, genie.panel.size);
      canvas.drawVertices(vertices, BlendMode.srcOver, paint);
      vertices.dispose();
    }
  }

  /// Mochi at [p] through [leap].
  void _mochi(Canvas canvas, Leap leap, double p, {required double facing, double? landingFacing}) {
    final settings = desktop.settings;
    var pose = library?.petTrack(PetAnimation.idle)?.at(time) ?? PetPose();
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
    final pose = library?.petTrack(PetAnimation.idle)?.at(time) ?? PetPose();
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
      time: 100 + time,
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
