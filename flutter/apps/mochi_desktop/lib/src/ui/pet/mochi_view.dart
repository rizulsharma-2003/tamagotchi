import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';

import '../../core/pet_cues.dart';
import '../../core/session_store.dart';
import 'pet_director.dart';

/// Mochi, alive: drawn by mochi_art's renderer from the recorded animations, following Claude's sessions and reacting
/// to [cues]. With animations off (Windows' Animation effects, macOS' Reduce Motion), Mochi keeps living, calmer.
class MochiView extends StatefulWidget {
  const MochiView({
    super.key,
    required this.sessions,
    required this.cues,
    required this.library,
    required this.lastActivity,
    this.onMood,
    this.fill = 0.82,
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

  @override
  State<MochiView> createState() => _MochiViewState();
}

class _MochiViewState extends State<MochiView> with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _clock = ValueNotifier(0);
  final PetDirector _director = PetDirector();
  late final Ticker _ticker;
  StreamSubscription<PetCue>? _cues;
  Timer? _moodTimer;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) => _clock.value = elapsed.inMicroseconds / 1e6)..start();
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

  void _cue(PetCue cue) {
    _director.cue(cue, time: _clock.value);
    _follow();
  }

  void _follow() {
    final mood = PetMood.of(widget.sessions, now: widget.sessions.now, lastActivity: widget.lastActivity());
    if (mood == _director.mood) return;
    _director.follow(mood, time: _clock.value);
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
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calm = MediaQuery.disableAnimationsOf(context);
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
  }) : super(repaint: clock);

  final PetDirector director;
  final PoseLibrary? library;
  final ValueNotifier<double> clock;
  final bool calm;
  final bool dark;
  final double fill;

  @override
  void paint(Canvas canvas, Size size) {
    final pose = director.pose(library, clock.value, calm: calm);
    final scale = size.height * fill / 66;
    PetRenderer.draw(
      pose,
      GContext(canvas),
      Offset(size.width / 2, size.height - size.height * 0.06),
      scale,
      PetPalette(PetColor.cream),
      dark: dark,
    );
  }

  @override
  bool shouldRepaint(_MochiPainter old) =>
      old.library != library || old.director != director || old.calm != calm || old.dark != dark || old.fill != fill;
}
