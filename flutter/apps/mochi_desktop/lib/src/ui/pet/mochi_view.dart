import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';

import '../../core/pet_cues.dart';
import '../../core/session_store.dart';
import 'pet_director.dart';
import 'stroller.dart';

/// Mochi, alive: drawn by mochi_art's renderer from the recorded animations, following Claude's sessions and reacting
/// to [cues]. With animations off (Windows' Animation effects, macOS' Reduce Motion), Mochi keeps living, calmer.
///
/// It's drawn only as often as what it's doing needs ([frameRate], as the Mac's menu-bar stage does): smooth while
/// it walks or plays a moment, a calm 12 frames a second otherwise, 6 asleep.
class MochiView extends StatefulWidget {
  const MochiView({
    super.key,
    required this.sessions,
    required this.cues,
    required this.library,
    required this.lastActivity,
    this.onMood,
    this.fill = 0.82,
    this.feet = 0.06,
    this.stroll,
    this.detail = RenderDetail.standard,
  });

  final SessionStore sessions;
  final Stream<PetCue> cues;

  /// The recorded animations (null while they load: Mochi stands still).
  final PoseLibrary? library;

  /// The last hook event, pet or launch: a long quiet stretch sends Mochi to sleep.
  final DateTime Function() lastActivity;

  /// Called when the mood changes.
  final ValueChanged<PetMood>? onMood;

  /// How much of the height Mochi fills.
  final double fill;

  /// How high its feet are above the bottom edge, as a part of the height.
  final double feet;

  /// On the taskbar: what Mochi is doing there right now (it walks, turns, sits and naps by it).
  final StrollSample? Function()? stroll;

  /// The drawing's detail: [RenderDetail.tiny] at taskbar size (bolder lines, small hops, no shadow), as in the Mac's
  /// menu bar.
  final RenderDetail detail;

  @override
  State<MochiView> createState() => _MochiViewState();

  /// Frames a second for Mochi doing this: 25 while it walks (the window moves as often), 24 for a moment (a pet, a
  /// finished turn, a stretch), 12 for a calm loop (a blink still shows), 6 asleep; at most 10 with animations off.
  static double frameRate({required PetMood mood, StrollSample? roam, bool oneShot = false, bool calm = false}) {
    final double rate;
    if (roam?.travelling ?? false) {
      rate = 25;
    } else if (oneShot || (roam?.oneShot ?? false)) {
      rate = 24;
    } else {
      final loop = roam?.animation ?? mood.loop;
      rate = loop == PetAnimation.sleep || loop == PetAnimation.curl ? 6 : 12;
    }
    return calm ? math.min(rate, 10) : rate;
  }
}

class _MochiViewState extends State<MochiView> {
  final ValueNotifier<double> _clock = ValueNotifier(0);
  final Stopwatch _watch = Stopwatch()..start();
  final PetDirector _director = PetDirector();
  StreamSubscription<PetCue>? _cues;
  Timer? _moodTimer;
  Timer? _frames;
  double _fps = 0;
  bool _calm = false;

  double get _time => _watch.elapsedMicroseconds / 1e6;

  @override
  void initState() {
    super.initState();
    _frame();
    _cues = widget.cues.listen(_cue);
    widget.sessions.addListener(_follow);
    // The mood also changes with time alone (a finish fades, a nap begins).
    _moodTimer = Timer.periodic(const Duration(seconds: 5), (_) => _follow());
    _follow();
  }

  @override
  void didUpdateWidget(MochiView old) {
    super.didUpdateWidget(old);
    if (old.sessions != widget.sessions) {
      old.sessions.removeListener(_follow);
      widget.sessions.addListener(_follow);
    }
    if (old.cues != widget.cues) {
      unawaited(_cues?.cancel());
      _cues = widget.cues.listen(_cue);
    }
  }

  /// One frame: Mochi's clock moves on (so it's repainted), and the frame rate follows what it's doing.
  void _frame() {
    final time = _time;
    _clock.value = time;
    final fps = MochiView.frameRate(
      mood: _director.mood,
      roam: widget.stroll?.call(),
      oneShot: _director.playing(widget.library, time),
      calm: _calm,
    );
    if (fps == _fps) return;
    _fps = fps;
    _frames?.cancel();
    _frames = Timer.periodic(Duration(microseconds: (1e6 / fps).round()), (_) => _frame());
  }

  void _cue(PetCue cue) {
    _director.cue(cue, time: _time);
    _follow();
    _frame();
  }

  void _follow() {
    final mood = PetMood.of(widget.sessions, now: widget.sessions.now, lastActivity: widget.lastActivity());
    if (mood == _director.mood) return;
    _director.follow(mood, time: _time);
    if (mounted) _frame();
    // Never during a build (the first call comes from initState).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onMood?.call(_director.mood);
    });
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.sessions.removeListener(_follow);
    unawaited(_cues?.cancel());
    _moodTimer?.cancel();
    _frames?.cancel();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calm = MediaQuery.disableAnimationsOf(context);
    if (calm != _calm) {
      _calm = calm;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _frame();
      });
    }
    return Semantics(
      container: true,
      label: _director.mood.description,
      image: true,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _MochiPainter(
            director: _director,
            library: widget.library,
            clock: _clock,
            calm: calm,
            dark: Theme.of(context).brightness == Brightness.dark,
            fill: widget.fill,
            feet: widget.feet,
            stroll: widget.stroll,
            detail: widget.detail,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _MochiPainter extends CustomPainter {
  _MochiPainter({
    required this.director,
    required this.library,
    required this.clock,
    required this.calm,
    required this.dark,
    required this.fill,
    required this.feet,
    required this.stroll,
    required this.detail,
  }) : super(repaint: clock);

  final PetDirector director;
  final PoseLibrary? library;
  final ValueNotifier<double> clock;
  final bool calm;
  final bool dark;
  final double fill;
  final double feet;
  final StrollSample? Function()? stroll;
  final RenderDetail detail;

  @override
  void paint(Canvas canvas, Size size) {
    final pose = director.pose(library, clock.value, calm: calm, roam: stroll?.call());
    final scale = size.height * fill / 66;
    PetRenderer.draw(
      pose,
      GContext(canvas),
      Offset(size.width / 2, size.height - size.height * feet),
      scale,
      PetPalette(PetColor.cream),
      dark: dark,
      detail: detail,
    );
  }

  @override
  bool shouldRepaint(_MochiPainter old) =>
      old.library != library ||
      old.director != director ||
      old.calm != calm ||
      old.dark != dark ||
      old.fill != fill ||
      old.feet != feet ||
      old.stroll != stroll ||
      old.detail != detail;
}
