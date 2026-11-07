import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';

import '../../core/pet_cues.dart';
import '../../desktop.dart';
import 'companion_director.dart';
import 'pet_director.dart';

/// Mochi's room in Mochi's window, as the phones' home screens show it (mochi_pocket's RoomView, the iPhone's
/// RoomView.swift): the room's style and today's holiday, Patch at his desk doing what Claude does (his desk empty
/// while he's away), and Mochi, watching Claude work, waving when Claude needs you, napping after a quiet while and
/// reacting to you. They share Claude's moments: a high five when a turn finishes, a coffee or a game now and then.
/// Click Mochi to pet it, or Patch for a wave.
///
/// It's drawn only as often as what's happening needs (as the taskbar's Mochi is): smooth for a moment together, a
/// calm 10–12 frames a second otherwise, fewer while both nap; calmer still with animations off.
class RoomView extends StatefulWidget {
  const RoomView({
    super.key,
    required this.desktop,
    required this.companion,
    required this.library,
    required this.lastActivity,
    this.layout = SceneLayout.phone,
  });

  final MochiDesktop desktop;
  final CompanionDirector companion;

  /// The recorded animations (null while they load: everyone stands still).
  final PoseLibrary? library;

  /// The last hook event, pet or launch: a long quiet stretch sends Mochi to sleep.
  final DateTime Function() lastActivity;

  /// The room's proportions: the phone's (Mochi's window) or the Mac popover's.
  final SceneLayout Function(Size size) layout;

  @override
  State<RoomView> createState() => _RoomViewState();

  /// Frames a second for the room: Mochi's needs and Patch's, at most 10 with animations off.
  static double frameRate({required PetMood mood, required bool petMoment, required double companion, bool calm = false}) {
    final pet = petMoment ? 24.0 : (mood == PetMood.napping ? 6.0 : 12.0);
    final rate = math.max(pet, companion);
    return calm ? math.min(rate, 10) : rate;
  }
}

class _RoomViewState extends State<RoomView> {
  final ValueNotifier<double> _clock = ValueNotifier(0);
  final PetDirector _pet = PetDirector();
  StreamSubscription<PetCue>? _cues;
  Timer? _moodTimer;
  Timer? _frames;
  double _fps = 0;
  bool _calm = false;

  CompanionDirector get companion => widget.companion;
  double get _time => companion.time;

  @override
  void initState() {
    super.initState();
    _cues = widget.desktop.cues.listen(_cue);
    widget.desktop.sessions.addListener(_follow);
    companion.addListener(_companionChanged);
    _moodTimer = Timer.periodic(const Duration(seconds: 5), (_) => _follow());
    _follow();
    _companionChanged();
  }

  void _cue(PetCue cue) {
    _pet.cue(cue, time: _time);
    _frame();
  }

  void _follow() {
    final sessions = widget.desktop.sessions;
    final mood = PetMood.of(sessions, now: sessions.now, lastActivity: widget.lastActivity());
    if (mood != _pet.mood) {
      _pet.follow(mood, time: _time);
      if (mounted) setState(() {});
    }
    _frame();
  }

  /// Patch's news: in the room he and Mochi are always side by side, so a moment together starts at once.
  void _companionChanged() {
    if (companion.pending != null) companion.startPending();
    _frame();
    if (mounted) setState(() {});
  }

  /// One frame (the clock moves on, so the room is repainted), at the rate what's happening needs.
  void _frame() {
    if (!mounted) return;
    final time = _time;
    _clock.value = time;
    final fps = RoomView.frameRate(
      mood: _pet.mood,
      petMoment: _pet.playing(widget.library, time),
      companion: companion.visible ? companion.frameRate(time) : 0,
      calm: _calm,
    );
    if (fps == _fps) return;
    _fps = fps;
    _frames?.cancel();
    _frames = Timer.periodic(Duration(microseconds: (1e6 / fps).round()), (_) => _frame());
  }

  /// Everyone at [time]: a moment together, or each at what they're doing.
  SceneFrame _scene(double time) {
    final library = widget.library;
    final helpers = math.min(3, widget.desktop.sessions.primary?.activeSubagents.length ?? 0);
    final together = companion.scene(time);
    if (together != null) {
      return SceneFrame(pet: together.pet, companion: together.companion, props: together.props, subagents: helpers);
    }
    return SceneFrame(
      pet: _pet.pose(library, time, calm: _calm),
      companion: companion.pose(library, time, calm: _calm),
      companionVisible: companion.visible,
      subagents: companion.visible ? helpers : 0,
    );
  }

  @override
  void dispose() {
    unawaited(_cues?.cancel());
    widget.desktop.sessions.removeListener(_follow);
    companion.removeListener(_companionChanged);
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
      WidgetsBinding.instance.addPostFrameCallback((_) => _frame());
    }
    final settings = widget.desktop.settings;
    final now = widget.desktop.sessions.now;
    final pet = settings.petName;
    final patch = settings.companionName;
    final config = SceneConfig(
      theme: settings.officeTheme,
      petColor: settings.petColor,
      petAccessory: settings.petAccessory,
      companionAccessory: settings.companionAccessory,
      deskAccessory: settings.deskAccessory,
      season: settings.holidayOn(now),
      reducedMotion: calm,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = widget.layout(constraints.biggest);
        return Semantics(
          container: true,
          label: "$pet's room. ${_pet.mood.describe(pet)}. ${companion.describe(patch)}.",
          child: Stack(
            children: [
              Positioned.fill(
                child: ExcludeSemantics(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: LiveRoomPainter(
                        config: config,
                        frame: _scene,
                        clock: _clock,
                        calm: calm,
                        dark: dark,
                        hour: now.hour,
                        layout: widget.layout,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: layout.petFrame.inflate(10),
                child: Semantics(
                  button: true,
                  label: '$pet. Click to pet.',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => widget.desktop.interact('pet')),
                  ),
                ),
              ),
              if (companion.present)
                Positioned.fromRect(
                  rect: layout.companionFrame,
                  child: Semantics(
                    button: true,
                    label: '$patch. Click for a wave.',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: companion.greet),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

