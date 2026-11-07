import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/pocket_model.dart';
import '../talk/talk_model.dart';
import '../theme.dart';
import 'pose_library.dart';
import 'scene_director.dart';

/// Mochi's room, the same scene as the Mac's panel and the iPhone's (iOS/MochiPocket/RoomView.swift): the look the Mac
/// shares, Patch at the desk doing what Claude does, and Mochi. Tap Mochi to pet it; press and hold Mochi to talk: it
/// turns its right ear and shoulder towards you and listens, with sound arriving at that ear. Let go to send; slide
/// your finger away first to cancel. While Mochi is busy with what you said, a tap stops it.
class RoomView extends StatefulWidget {
  const RoomView({super.key, required this.model, required this.library, required this.onPet, this.talk});

  final PocketModel model;

  /// The recorded animations (null while they load: everyone stands still).
  final PoseLibrary? library;
  final VoidCallback onPet;

  /// Hold to talk (none: Mochi can only be petted).
  final TalkModel? talk;

  /// How far your finger may slide from where it pressed before letting go cancels.
  static const double cancelDistance = 90;

  @override
  State<RoomView> createState() => _RoomViewState();
}

class _RoomViewState extends State<RoomView> with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _clock = ValueNotifier(0);
  final SceneDirector _director = SceneDirector();
  late final Ticker _ticker;
  StreamSubscription<PetCue>? _cues;
  SceneConfig _config = SceneConfig();
  PetLook? _look;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) => _clock.value = elapsed.inMicroseconds / 1e6)..start();
    _listen();
    widget.model.addListener(_modelChanged);
    _modelChanged();
  }

  @override
  void didUpdateWidget(RoomView old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_modelChanged);
      widget.model.addListener(_modelChanged);
      unawaited(_cues?.cancel());
      _listen();
      _modelChanged();
    }
  }

  void _listen() => _cues = widget.model.cues.listen((cue) => _director.cue(cue, time: _clock.value));

  void _modelChanged() {
    _director.follow(widget.model.claude, time: _clock.value);
    final look = widget.model.look;
    if (look != _look) {
      _look = look;
      _config = sceneConfig(look);
    }
  }

  /// The Mac's look as the renderers take it. A missing desk accessory in the look means none (Swift `PetLook`).
  static SceneConfig sceneConfig(PetLook? look) => look == null
      ? SceneConfig(deskAccessory: Accessory.plant)
      : SceneConfig.fromJson({
          'theme': look.theme,
          'petColor': look.petColor,
          'petAccessory': look.petAccessory,
          'companionAccessory': look.companionAccessory,
          'deskAccessory': look.deskAccessory,
          'room': look.room,
        });

  @override
  void dispose() {
    widget.model.removeListener(_modelChanged);
    unawaited(_cues?.cancel());
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  /// Everyone's poses at [time] on the room's clock (calmer with animations off). Talking turns Mochi to listen where it
  /// stands (the iPhone's `ListeningPose`); afterwards the room's cues (a nod, a look around, a happy bounce) play.
  SceneFrame _frame(double time) {
    final poses = _director.poses(widget.library, time, calm: _config.reducedMotion);
    var pet = poses.pet;
    final talk = widget.talk;
    if (talk != null && talk.isHolding) {
      // Built on Mochi awake (the idle loop, as the iPhone's `ListeningPose` evaluates it), even if it was napping.
      final idle = widget.library?.petTrack(PetAnimation.idle)?.at(time) ?? PetPose();
      pet = ListeningPose.pose(idle, elapsed: talk.elapsed(), listening: talk.phase == TalkPhase.listening, time: time);
    }
    return SceneFrame(pet: pet, companion: poses.companion);
  }

  void _tapped() {
    final talk = widget.talk;
    if (talk != null && talk.isBusy) {
      talk.cancel();
    } else {
      widget.onPet();
    }
  }

  /// Tap and press-and-hold on Mochi; the hold starts after 0.35 s, as on the iPhone.
  Map<Type, GestureRecognizerFactory> _gestures() {
    final talk = widget.talk;
    return {
      TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
        TapGestureRecognizer.new,
        (recognizer) => recognizer.onTap = _tapped,
      ),
      if (talk != null)
        LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 350)),
          (recognizer) => recognizer
            ..onLongPressStart = ((_) => unawaited(talk.earHeld()))
            ..onLongPressMoveUpdate = ((details) => talk.slid(away: details.offsetFromOrigin.distance > RoomView.cancelDistance))
            ..onLongPressEnd = ((_) => unawaited(talk.earReleased()))
            ..onLongPressCancel = talk.fingerLost,
        ),
    };
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final layout = SceneLayout.phone(size);
      final pet = layout.petFrame.inflate(12);
      final calm = MediaQuery.disableAnimationsOf(context);
      _config.reducedMotion = calm;
      return Semantics(
        label: "${widget.model.petName}'s room",
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: LiveRoomPainter(config: _config, frame: _frame, clock: _clock, calm: calm, dark: context.palette.isDark),
                ),
              ),
            ),
            if (widget.talk case final talk?)
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _SoundWaves(talk: talk, clock: _clock, tint: context.palette.tint),
                    ),
                  ),
                ),
              ),
            Positioned.fromRect(
              rect: pet,
              child: Semantics(
                button: true,
                label: widget.talk == null
                    ? '${widget.model.petName}. Tap to pet.'
                    : '${widget.model.petName}. Tap to pet, press and hold to talk.',
                onTap: _tapped,
                customSemanticsActions: {
                  if (widget.talk case final talk?)
                    CustomSemanticsAction(label: 'Talk to ${widget.model.petName}'): () => unawaited(talk.earHeld(byTap: true)),
                },
                child: RawGestureDetector(behavior: HitTestBehavior.opaque, gestures: _gestures(), excludeFromSemantics: true),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Sound arriving at Mochi's listening ear while you hold it (the iPhone's `drawSoundWaves`), fading in as Mochi turns.
class _SoundWaves extends CustomPainter {
  _SoundWaves({required this.talk, required this.clock, required this.tint}) : super(repaint: clock);

  final TalkModel talk;
  final ValueListenable<double> clock;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    if (!talk.isHolding) return;
    final appear = talk.phase == TalkPhase.listening ? 1.0 : (talk.elapsed() / ListeningPose.turnDuration).clamp(0.0, 1.0);
    ListeningPose.drawSoundWaves(GContext(canvas), SceneLayout.phone(size), clock.value, appear, tint: tint);
  }

  @override
  bool shouldRepaint(_SoundWaves old) => old.talk != talk || old.tint != tint;
}
