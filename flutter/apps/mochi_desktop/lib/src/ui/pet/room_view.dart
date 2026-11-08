import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:mochi_art/mochi_art.dart';

import '../../desktop.dart';
import 'companion_director.dart';
import 'pet_director.dart';
import 'purr_hold.dart';
import 'room_editor.dart';
import '../../core/purr.dart';
import 'speech_bubble.dart';

/// Mochi's room in Mochi's window, as the phones' home screens show it (mochi_pocket's RoomView, the iPhone's
/// RoomView.swift): the room's style and today's holiday, Patch at his desk doing what Claude does (his desk empty
/// while he's away), and Mochi, watching Claude work, waving when Claude needs you, napping after a quiet while and
/// reacting to you. They share Claude's moments: a high five when a turn finishes, a coffee or a game now and then.
/// Everyone is drawn as Mochi's world has them (`MochiWorld.frame`, the Mac's scene), with a bubble over whoever is
/// talking (W11) and the world's note at the top (an achievement, a new friendship level, growing up). Click Mochi to
/// pet it, or Patch for a wave.
///
/// It's drawn only as often as what's happening needs (as the taskbar's Mochi is): smooth for a moment together, a
/// calm 10–12 frames a second otherwise, fewer while both nap; calmer still with animations off.
class RoomView extends StatefulWidget {
  const RoomView({
    super.key,
    required this.desktop,
    required this.companion,
    required this.lastActivity,
    this.layout = SceneLayout.phone,
    this.hidePet = false,
  });

  final MochiDesktop desktop;
  final CompanionDirector companion;

  /// The last hook event, pet or launch: a long quiet stretch sends Mochi to sleep.
  final DateTime Function() lastActivity;

  /// The room's proportions: the phone's (Mochi's window) or the Mac popover's.
  final SceneLayout Function(Size size) layout;

  /// Mochi is somewhere else for now (leaping in or out of the popover): the room without it.
  final bool hidePet;

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
  PetMood _mood = PetMood.relaxed;
  Timer? _moodTimer;
  Timer? _frames;
  double _fps = 0;
  bool _calm = false;

  CompanionDirector get companion => widget.companion;
  double get _time => companion.time;

  @override
  void initState() {
    super.initState();
    widget.desktop.sessions.addListener(_follow);
    widget.desktop.purr.addListener(_frame);
    widget.desktop.room.addListener(_decorating);
    companion.addListener(_companionChanged);
    _moodTimer = Timer.periodic(const Duration(seconds: 5), (_) => _follow());
    _follow();
    _companionChanged();
  }

  void _follow() {
    final desktop = widget.desktop;
    final sessions = desktop.sessions;
    final mood = PetMood.of(
      sessions,
      now: sessions.now,
      lastActivity: widget.lastActivity(),
      rhythm: desktop.rhythm,
      asleep: desktop.world.asleep,
    );
    if (mood != _mood) {
      _mood = mood;
      if (mounted) setState(() {});
    }
    _frame();
  }

  /// Decorating began or ended, or a piece was picked up (the scene leaves it out while it's carried).
  void _decorating() {
    if (mounted) setState(() {});
  }

  /// The world's news (a moment, Patch coming or going, a nap).
  void _companionChanged() {
    _follow();
    if (mounted) setState(() {});
  }

  /// One frame (the clock moves on, so the room is repainted), at the rate what's happening needs.
  void _frame() {
    if (!mounted) return;
    final time = _time;
    _clock.value = time;
    final fps = RoomView.frameRate(
      mood: _mood,
      petMoment: widget.desktop.world.world.pet.isPlayingOneShot || widget.desktop.purr.active,
      companion: companion.visible ? companion.frameRate(time) : 0,
      calm: _calm,
    );
    if (fps == _fps) return;
    _fps = fps;
    _frames?.cancel();
    _frames = Timer.periodic(Duration(microseconds: (1e6 / fps).round()), (_) => _frame());
  }

  /// Everyone at [time], as the world has them (a moment together, or each at what they're doing).
  SceneFrame _scene(double time) {
    final frame = widget.desktop.world.world.frame(time);
    final purr = widget.desktop.purr;
    return SceneFrame(
      pet: purr.active ? PurrSession.decorate(frame.pet, time, calm: _calm) : frame.pet,
      companion: frame.companion,
      props: frame.props,
      companionVisible: frame.companionVisible,
      companionVelocity: frame.companionVelocity,
      subagents: frame.companionVisible ? math.min(3, frame.subagents) : 0,
    );
  }

  @override
  void dispose() {
    widget.desktop.sessions.removeListener(_follow);
    widget.desktop.purr.removeListener(_frame);
    widget.desktop.room.removeListener(_decorating);
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
      petAway: widget.hidePet,
      room: settings.room,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = widget.layout(constraints.biggest);
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: "$pet's room. ${_mood.describe(pet)}. ${companion.describe(patch)}.",
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
              // What Mochi or Patch is saying, over whoever speaks (the Mac's SceneSpeechOverlay).
              ValueListenableBuilder(
                valueListenable: widget.desktop.world.speechNow,
                builder: (context, speech, _) {
                  final byPatch = speech?.speaker.name == 'companion';
                  if (speech == null || (byPatch && !companion.visible)) return const SizedBox.shrink();
                  final frame = byPatch ? layout.companionFrame : layout.petFrame;
                  const half = MochiBubble.maxWidth / 2;
                  final x = frame.center.dx.clamp(half, math.max(half, constraints.maxWidth - half));
                  final bottom = math.max(40.0, frame.top + (byPatch ? -4 : 4));
                  return Positioned(
                    left: x - half,
                    width: MochiBubble.maxWidth,
                    bottom: math.max(0.0, constraints.maxHeight - bottom),
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: MochiBubble(key: ObjectKey(speech), text: speech.text),
                      ),
                    ),
                  );
                },
              ),
              // The world's note at the top of the scene.
              ValueListenableBuilder(
                valueListenable: widget.desktop.world.toastNow,
                builder: (context, note, _) => note == null
                    ? const SizedBox.shrink()
                    : Positioned(
                        top: 6,
                        left: 8,
                        right: 8,
                        child: IgnorePointer(
                          child: Center(
                            child: SceneNote(title: note.title, detail: note.detail),
                          ),
                        ),
                      ),
              ),
              Positioned.fromRect(
                rect: layout.petFrame.inflate(10),
                child: Semantics(
                  container: true,
                  button: true,
                  label: '$pet. Click to pet, press and hold to keep it purring.',
                  customSemanticsActions: {CustomSemanticsAction(label: 'Purr'): widget.desktop.purr.pulse},
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: PurrHold(
                      purr: widget.desktop.purr,
                      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => widget.desktop.interact('pet')),
                    ),
                  ),
                ),
              ),
              if (companion.present)
                Positioned.fromRect(
                  rect: layout.companionFrame,
                  child: Semantics(
                    container: true,
                    button: true,
                    label: '$patch. Click for a wave.',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: companion.greet),
                    ),
                  ),
                ),
              // Decorating (W18): the tray and the pieces over the room; nobody is petted meanwhile.
              if (widget.desktop.room.isEditing) Positioned.fill(child: RoomEditorOverlay(desktop: widget.desktop, layout: layout)),
            ],
          ),
        );
      },
    );
  }
}
