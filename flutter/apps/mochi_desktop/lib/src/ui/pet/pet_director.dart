import 'dart:math' as math;

import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';

import '../../core/pc_rhythm.dart';
import '../../core/pet_cues.dart';
import '../../core/session_store.dart';
import '../../core/sessions.dart';
import 'stroller.dart';

/// Mochi's mood, from what Claude is doing (TamagotchiCore's EventToAnimationMapper picks the same loops).
enum PetMood {
  /// Nothing happening for a while.
  napping,

  /// No session at work.
  relaxed,

  /// Claude is working.
  watching,

  /// A session waits for you.
  needsYou,

  /// A turn just finished.
  happy,

  /// A turn just ended with an error.
  concerned;

  /// What a screen reader says, and the tooltip.
  String get description => describe('Mochi');

  /// [description] with the pet's own name.
  String describe(String name) => switch (this) {
    napping => '$name is napping',
    relaxed => '$name is relaxing',
    watching => '$name is watching Claude work',
    needsYou => 'Claude needs you',
    happy => 'Claude finished',
    concerned => 'Claude hit a snag',
  };

  /// Mochi's loop for the mood.
  PetAnimation get loop => switch (this) {
    napping => PetAnimation.sleep,
    watching => PetAnimation.watch,
    needsYou => PetAnimation.waveGently,
    relaxed || happy || concerned => PetAnimation.idle,
  };

  /// Mochi's mood for [sessions] at [now]: the primary session's phase, or else a nap: with the PC's [rhythm], while
  /// the PC rests (Settings › Characters › Naps); without it, after [napAfter] with nothing going on (counted from
  /// [lastActivity]: the last hook event, pet or launch).
  static PetMood of(
    SessionStore sessions, {
    required DateTime now,
    required DateTime lastActivity,
    Duration napAfter = const Duration(minutes: 30),
    PcRhythm? rhythm,
  }) {
    final primary = sessions.primary;
    if (primary != null && primary.isLive && !primary.isStale(now)) {
      switch (primary.phase) {
        case SessionPhase.waitingForUser:
          return needsYou;
        case SessionPhase.promptSubmitted || SessionPhase.thinking || SessionPhase.runningTool:
          return watching;
        case SessionPhase.turnCompleted
            when now.difference(primary.lastTurnCompletedAt ?? primary.lastEventAt) < const Duration(minutes: 2):
          return happy;
        case SessionPhase.turnFailed when now.difference(primary.lastEventAt) < const Duration(minutes: 5):
          return concerned;
        default:
          break;
      }
    }
    if (rhythm != null) return rhythm.asleep(now: now, lastActivity: lastActivity) ? napping : relaxed;
    return now.difference(lastActivity) >= napAfter ? napping : relaxed;
  }
}

/// Which animation Mochi plays: the mood's loop, with one-shots over it for moments (a pet, a finished turn), as the
/// pocket's SceneDirector does for the phone's room.
class PetDirector {
  PetDirector({math.Random? random}) : _random = random ?? math.Random();

  final math.Random _random;

  PetMood mood = PetMood.relaxed;
  ({PetAnimation animation, int variant, double start})? shot;

  void follow(PetMood next, {required double time}) {
    if (next == mood) return;
    if (mood == PetMood.napping) _play(PetAnimation.wakeUp, time);
    mood = next;
  }

  void cue(PetCue cue, {required double time}) {
    switch (cue) {
      case PetCue.pet:
        _play(PetAnimation.petted, time, variants: 3);
      case PetCue.play:
        _play(PetAnimation.play, time, variants: 4);
      case PetCue.treat:
        _play(PetAnimation.treat, time, variants: 4);
      case PetCue.sending:
        _play(PetAnimation.nod, time);
      case PetCue.working:
        if (!_interacting(time)) _play(PetAnimation.lookAround, time);
      case PetCue.replied || PetCue.finished:
        _play(PetAnimation.happyBounce, time);
      case PetCue.failed || PetCue.snag:
        _play(PetAnimation.concerned, time);
      case PetCue.needsYou:
        _play(PetAnimation.wave, time);
      case PetCue.greet:
        if (!_interacting(time)) _play(PetAnimation.greet, time);
      case PetCue.goodbye:
        if (!_interacting(time)) _play(PetAnimation.wave, time);
      case PetCue.attend:
        if (!_busy(time)) _play(PetAnimation.leanForward, time);
      case PetCue.nod:
        // Tool calls come thick and fast: a nod only now and then, and never over another moment (the Mac plays it at
        // ambient priority).
        if (!_busy(time) && time - _lastNod >= nodGap) {
          _lastNod = time;
          _play(PetAnimation.nod, time);
        }
      case PetCue.puzzled:
        if (!_interacting(time)) _play(PetAnimation.confusedTilt, time);
      case PetCue.cheer:
        _play(PetAnimation.happyBounce, time);
      case PetCue.worry:
        _play(PetAnimation.concerned, time);
      case PetCue.celebrate:
        _play(PetAnimation.victory, time);
      case PetCue.updateReady:
        if (!_interacting(time)) _play(PetAnimation.wave, time);
      case PetCue.updated:
        _play(PetAnimation.happyBounce, time);
    }
  }

  /// The least time between two nods for tool calls (seconds).
  static const double nodGap = 20;
  double _lastNod = -1e9;

  /// Any moment is still playing (for the small ones, which never cut another short).
  bool _busy(double time) {
    final current = shot;
    return current != null && time - current.start < 2.5;
  }

  /// A pet, play or treat is still playing: news doesn't cut it short.
  bool _interacting(double time) {
    final current = shot;
    if (current == null) return false;
    final interaction =
        current.animation == PetAnimation.petted || current.animation == PetAnimation.play || current.animation == PetAnimation.treat;
    return interaction && time - current.start < 3;
  }

  /// A one-shot is playing at [time].
  bool playing(PoseLibrary? library, double time) {
    final current = shot;
    if (current == null || library == null) return false;
    final track = library.petTrack(current.animation, current.variant);
    return track != null && time - current.start < track.length;
  }

  void _play(PetAnimation animation, double time, {int variants = 1}) {
    shot = (animation: animation, variant: variants > 1 ? _random.nextInt(variants) : 0, start: time);
  }

  /// Mochi's pose at [time]: calmer (slower, smaller) when [calm]. On the taskbar, [roam] says what Mochi is doing
  /// there (walking, sitting, napping…) and which way it faces; a one-shot (a pet, a finished turn) still plays over it.
  PetPose pose(PoseLibrary? library, double time, {bool calm = false, StrollSample? roam}) {
    final pose = _pose(library, time, calm: calm, roam: roam);
    return roam == null ? pose : _strolling(pose, roam);
  }

  PetPose _pose(PoseLibrary? library, double time, {required bool calm, StrollSample? roam}) {
    if (library == null) return roam == null ? PetPose() : _bob(PetPose(), roam);
    final current = shot;
    if (current != null) {
      final track = library.petTrack(current.animation, current.variant);
      if (track != null && time - current.start < track.length) return track.calmed(time - current.start, calm: calm, oneShot: true);
      shot = null;
    }
    if (roam != null) {
      final track = library.petTrack(roam.animation);
      if (track != null) return track.calmed(roam.animationTime, calm: calm, oneShot: roam.oneShot);
      // No recorded walk: a gentle bob on the idle loop.
      final idle = library.petTrack(PetAnimation.idle);
      return _bob(idle == null ? PetPose() : idle.calmed(time, calm: calm), roam);
    }
    final loop = library.petTrack(mood.loop);
    return loop == null ? PetPose() : loop.calmed(time, calm: calm);
  }

  static PetPose _bob(PetPose pose, StrollSample roam) {
    if (roam.travelling) pose.y += 0.05 * math.sin(math.pi * 2 * roam.animationTime).abs();
    return pose;
  }

  /// Mochi's pose turned the way it walks (the recorded tracks face right), with the stroll's accents (the Mac's
  /// attentive and notice styles).
  static PetPose _strolling(PetPose input, StrollSample roam) {
    final pose = roam.facing < 0 ? input.mirrored() : input;
    // Fading out and in, hopping to another stretch of the taskbar.
    pose.opacity *= roam.opacity;
    switch (roam.style) {
      case StrollStyle.attentive:
        pose
          ..lookX = 0.02
          ..lookY = -0.12
          ..earPerk = math.max(pose.earPerk, 0.4);
        if (pose.eyes == PetEyes.happy) pose.eyes = PetEyes.open;
      case StrollStyle.notice:
        pose
          ..earPerk = math.max(pose.earPerk, 0.85)
          ..lookX = 0.85 * roam.facing
          ..lookY = -0.05;
      case StrollStyle.plain:
        break;
    }
    return pose;
  }
}
