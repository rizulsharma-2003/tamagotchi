import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_link/mochi_link.dart' show PetLook;
import 'package:mochi_world/mochi_world.dart' show PetPoseEvaluator, PoseContext, SeasonCalendar;

import '../model/pocket_model.dart';
import '../talk/talk_model.dart';
import '../theme.dart';
import 'phone_world.dart';

/// Mochi's room, the same scene as the Mac's panel and the iPhone's (iOS/MochiPocket/RoomView.swift): the look the
/// computer shares (the room's style, colours, things to wear, today's holiday), Patch at the desk doing what Claude
/// does, and Mochi, everyone as Mochi's world has them ([PhoneWorld], the Mac's engine). Tap Mochi to pet it; press and
/// hold Mochi to talk: it turns its right ear and shoulder towards you and listens, with sound arriving at that ear. Let
/// go to send; slide your finger away first to cancel. While Mochi is busy with what you said, a tap stops it, and
/// Mochi's pose says how it's going (the iPhone's `RoomView.pose`).
///
/// Light on the battery: drawn only while it can be seen (the app in front, this screen showing, the room scrolled into
/// view); every display frame only for your moments (a pet, play or treat, talking), 30 frames a second for the others
/// (Claude's news, a moment together), a calm 15 for the loops, 6 while both nap, at most 10 with animations off. The
/// world ticks only while the room can be seen.
class RoomView extends StatefulWidget {
  const RoomView({super.key, required this.model, required this.world, required this.onPet, this.talk});

  final PocketModel model;

  /// Mochi's world: what everyone does.
  final PhoneWorld world;
  final VoidCallback onPet;

  /// Hold to talk (none: Mochi can only be petted).
  final TalkModel? talk;

  /// How far your finger may slide from where it pressed before letting go cancels.
  static const double cancelDistance = 90;

  /// Every display frame.
  static const double smooth = double.infinity;

  /// Frames a second the room needs: every display frame for a moment that's [yours] (a pet, play or treat, talking),
  /// 30 for the others ([moment]: Claude's news, a moment together, a stretch), 15 for the loops, 6 while both are
  /// [napping]; with animations off ([calm]) at most 10.
  static double frameRate({required bool moment, bool yours = false, required bool napping, bool calm = false}) {
    if (napping && !moment && !yours) return 6;
    if (calm) return 10;
    if (yours) return smooth;
    return moment ? 30 : 15;
  }

  /// Mochi's pose while you talk to it (the iPhone's `RoomView.pose`): it turns to listen where it stands, then nods,
  /// looks around while it waits, bounces at the answer and keeps smiling, or looks worried when it didn't work.
  static PetPose talkPose(PetPose pose, TalkPhase phase, {required double elapsed, required double time}) {
    PoseContext context() => PoseContext(time: time, seed: 7);
    switch (phase) {
      case TalkPhase.approaching || TalkPhase.listening:
        final idle = PetPoseEvaluator.pose(PetAnimation.idle, elapsed: time, context: context());
        return ListeningPose.pose(idle, elapsed: elapsed, listening: phase == TalkPhase.listening, time: time);
      case TalkPhase.sending:
        return PetPoseEvaluator.pose(PetAnimation.nod, elapsed: math.min(elapsed, 0.9), duration: 1, context: context())..earPerk = 0.8;
      case TalkPhase.waiting:
        return PetPoseEvaluator.pose(PetAnimation.lookAround, elapsed: elapsed.remainder(2.6), context: context())..earPerk = 0.7;
      case TalkPhase.replied:
        if (elapsed < 1) return PetPoseEvaluator.pose(PetAnimation.happyBounce, elapsed: elapsed, duration: 1, context: context());
        return pose.copy()
          ..eyes = PetEyes.happy
          ..mouth = PetMouth.smile
          ..blush = 0.85;
      case TalkPhase.failed:
        return PetPoseEvaluator.pose(PetAnimation.concerned, elapsed: math.min(elapsed, 2.2), context: context());
      case TalkPhase.idle:
        return pose;
    }
  }

  /// The computer's look as the renderers take it, with today's holiday. A missing desk accessory in the look means
  /// none (Swift `PetLook`).
  static SceneConfig sceneConfig(PetLook? look, {SeasonalEvent? season}) => look == null
      ? SceneConfig(deskAccessory: Accessory.plant, season: season)
      : (SceneConfig.fromJson({
          'theme': look.theme,
          'petColor': look.petColor,
          'petAccessory': look.petAccessory,
          'companionAccessory': look.companionAccessory,
          'deskAccessory': look.deskAccessory,
          'room': look.room,
        })..season = season);

  @override
  State<RoomView> createState() => RoomViewState();
}

class RoomViewState extends State<RoomView> with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _clock = ValueNotifier(0);
  late final Ticker _ticker;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onStateChange: _lifecycleChanged);
  Timer? _frames;
  double _fps = 0;
  bool _foreground = true;
  bool _visible = false;
  bool _calm = false;
  double _screenHeight = double.infinity;
  ValueListenable<bool>? _routeShown;
  ScrollPosition? _scroll;
  SceneConfig _config = RoomView.sceneConfig(null);
  (String?, SeasonalEvent?)? _configFor;
  String _described = '';

  PhoneWorld get world => widget.world;

  /// Frames a second the room is drawn at right now: 0 while it can't be seen, [RoomView.smooth] for every frame.
  @visibleForTesting
  double get framesPerSecond => _fps;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || _inFront(state);
    _ticker = createTicker((_) => _frame());
    _lifecycle;
    _listen(widget);
    _clock.value = world.now;
    _lookChanged(rebuild: false);
    _described = world.describe();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shown = TickerMode.getNotifier(context);
    if (shown != _routeShown) {
      _routeShown?.removeListener(_check);
      _routeShown = shown..addListener(_check);
    }
    final scroll = Scrollable.maybeOf(context)?.position;
    if (scroll != _scroll) {
      _scroll?.removeListener(_scrolled);
      _scroll = scroll?..addListener(_scrolled);
    }
    _screenHeight = MediaQuery.sizeOf(context).height;
    final calm = MediaQuery.disableAnimationsOf(context);
    if (calm != _calm) {
      _calm = calm;
      world.setReducedMotion(calm);
      _pace();
    }
    // Once laid out: is the room on screen?
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didUpdateWidget(RoomView old) {
    super.didUpdateWidget(old);
    if (old.world != widget.world || old.talk != widget.talk || old.model != widget.model) {
      _unlisten(old);
      if (old.world != widget.world) {
        old.world.roomVisible(false);
        widget.world.setReducedMotion(_calm);
        // Decided again once built.
        _visible = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => _check());
      }
      _listen(widget);
      _lookChanged(rebuild: false);
      _pace();
    }
  }

  void _listen(RoomView view) {
    view.world.addListener(_worldChanged);
    view.talk?.addListener(_pace);
    view.model.addListener(_lookChanged);
  }

  void _unlisten(RoomView view) {
    view.world.removeListener(_worldChanged);
    view.talk?.removeListener(_pace);
    view.model.removeListener(_lookChanged);
  }

  @override
  void dispose() {
    _unlisten(widget);
    world.roomVisible(false);
    _routeShown?.removeListener(_check);
    _scroll?.removeListener(_scrolled);
    _lifecycle.dispose();
    _frames?.cancel();
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  // MARK: Whether it can be seen

  /// In front, or in front behind a system dialog (the microphone question, the notification shade): still seen.
  static bool _inFront(AppLifecycleState state) => state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  void _lifecycleChanged(AppLifecycleState state) {
    _foreground = _inFront(state);
    _check();
  }

  /// Any of the room within the screen (it scrolls with the home screen).
  bool _onScreen() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    return top < _screenHeight && top + box.size.height > 0;
  }

  /// The home screen scrolled: once it's laid out where it scrolled to, is the room still on screen?
  void _scrolled() {
    if (_checkAfterFrame) return;
    _checkAfterFrame = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAfterFrame = false;
      _check();
    });
  }

  bool _checkAfterFrame = false;

  void _check() {
    if (!mounted) return;
    // Told while the tree is being built (the screen's route covered or uncovered): decide once it's built.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
      return;
    }
    final visible = _foreground && (_routeShown?.value ?? true) && _onScreen();
    if (visible == _visible) return;
    _visible = visible;
    world.roomVisible(visible);
    _pace();
  }

  // MARK: Drawing

  void _worldChanged() {
    _lookChanged();
    _pace();
    final described = world.describe();
    if (described != _described && mounted) setState(() => _described = described);
  }

  /// The look or the holiday changed: the room's colours, things to wear and decorations.
  void _lookChanged({bool rebuild = true}) {
    final look = widget.model.look;
    final key = (look?.toValue(), world.season);
    if (key == _configFor) return;
    _configFor = key;
    SeasonRenderContext.newYear = SeasonCalendar.newYear(DateTime.now());
    _config = RoomView.sceneConfig(look, season: key.$2)..reducedMotion = _calm;
    if (rebuild && mounted) setState(() {});
  }

  /// Picks the frame rate for what's happening, and starts or stops drawing.
  void _pace() {
    if (!mounted) return;
    final talking = widget.talk?.phase.overridesPet ?? false;
    final fps = _visible ? RoomView.frameRate(moment: world.busy, yours: world.yours || talking, napping: world.napping, calm: _calm) : 0.0;
    if (fps == _fps) return;
    _fps = fps;
    _frames?.cancel();
    _frames = null;
    if (fps == RoomView.smooth) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) _ticker.stop();
      if (fps > 0) _frames = Timer.periodic(Duration(microseconds: (1e6 / fps).round()), (_) => _frame());
    }
    if (fps > 0) _frame();
  }

  /// One frame: the clock moves on, so the room is painted again.
  void _frame() => _clock.value = world.now;

  /// Everyone at [time], as the world has them; talking takes over Mochi's pose (the iPhone's `petOverride`).
  SceneFrame _scene(double time) {
    final frame = world.world.frame(time);
    var pet = frame.pet;
    final talk = widget.talk;
    if (talk != null && talk.phase.overridesPet) pet = RoomView.talkPose(pet, talk.phase, elapsed: talk.elapsed(), time: time);
    return SceneFrame(
      pet: pet,
      companion: frame.companion,
      props: frame.props,
      companionVisible: frame.companionVisible,
      companionVelocity: frame.companionVelocity,
      subagents: frame.companionVisible ? math.min(3, frame.subagents) : 0,
    );
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
      _config.reducedMotion = _calm;
      // The room says what everyone is doing; Mochi is a button of its own inside it.
      return Semantics(
        container: true,
        explicitChildNodes: true,
        label: "${widget.model.petName}'s room. $_described.",
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: LiveRoomPainter(config: _config, frame: _scene, clock: _clock, calm: _calm, dark: context.palette.isDark),
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
                container: true,
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
