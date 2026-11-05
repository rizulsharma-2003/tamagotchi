import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/pocket_model.dart';
import '../theme.dart';
import 'pose_library.dart';
import 'scene_director.dart';

/// Mochi's room, the same scene as the Mac's panel and the iPhone's (iOS/MochiPocket/RoomView.swift): the look the Mac
/// shares, Patch at the desk doing what Claude does, and Mochi. Tap Mochi to pet it.
class RoomView extends StatefulWidget {
  const RoomView({super.key, required this.model, required this.library, required this.onPet});

  final PocketModel model;

  /// The recorded animations (null while they load: everyone stands still).
  final PoseLibrary? library;
  final VoidCallback onPet;

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
                  painter: _RoomPainter(
                    config: _config,
                    director: _director,
                    library: widget.library,
                    clock: _clock,
                    calm: calm,
                    dark: context.palette.isDark,
                  ),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: pet,
              child: Semantics(
                button: true,
                label: '${widget.model.petName}. Tap to pet.',
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onPet),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _RoomPainter extends CustomPainter {
  _RoomPainter({
    required this.config,
    required this.director,
    required this.library,
    required this.clock,
    required this.calm,
    required this.dark,
  }) : super(repaint: clock);

  final SceneConfig config;
  final SceneDirector director;
  final PoseLibrary? library;
  final ValueNotifier<double> clock;

  /// Animations are off: calmer, not frozen.
  final bool calm;

  /// The room's night colours, with the dark theme.
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final time = clock.value;
    final poses = director.poses(library, time, calm: calm);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    SceneRenderer.draw(
      config,
      SceneFrame(pet: poses.pet, companion: poses.companion),
      SceneLayout.phone(size),
      GContext(canvas),
      // The art's own clock (blinks, steam, the laptop cursor) starts well past zero, as in the gallery.
      time: 100 + (calm ? time * SceneDirector.calmSpeed : time),
      dark: dark,
      hour: DateTime.now().hour,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RoomPainter old) =>
      old.config != config || old.library != library || old.director != director || old.calm != calm || old.dark != dark;
}
