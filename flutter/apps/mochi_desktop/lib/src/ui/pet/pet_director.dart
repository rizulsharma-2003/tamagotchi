import 'dart:math' as math;

import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';

import '../../core/pet_cues.dart';
import '../../core/session_store.dart';
import '../../core/sessions.dart';

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
  String get description => switch (this) {
    napping => 'Mochi is napping',
    relaxed => 'Mochi is relaxing',
    watching => 'Mochi is watching Claude work',
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

  /// Mochi's mood for [sessions] at [now]: the primary session's phase, or a nap after [napAfter] with nothing going
  /// on (counted from [lastActivity]: the last hook event, pet or launch).
  static PetMood of(
    SessionStore sessions, {
    required DateTime now,
    required DateTime lastActivity,
    Duration napAfter = const Duration(minutes: 30),
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
    }
  }

  /// A pet, play or treat is still playing: news doesn't cut it short.
  bool _interacting(double time) {
    final current = shot;
    if (current == null) return false;
    final interaction =
        current.animation == PetAnimation.petted || current.animation == PetAnimation.play || current.animation == PetAnimation.treat;
    return interaction && time - current.start < 3;
  }

  void _play(PetAnimation animation, double time, {int variants = 1}) {
    shot = (animation: animation, variant: variants > 1 ? _random.nextInt(variants) : 0, start: time);
  }

  /// Mochi's pose at [time]: calmer (slower, smaller) when [calm].
  PetPose pose(PoseLibrary? library, double time, {bool calm = false}) {
    if (library == null) return PetPose();
    final current = shot;
    if (current != null) {
      final track = library.petTrack(current.animation, current.variant);
      if (track != null && time - current.start < track.length) return track.calmed(time - current.start, calm: calm, oneShot: true);
      shot = null;
    }
    final loop = library.petTrack(mood.loop);
    return loop == null ? PetPose() : loop.calmed(time, calm: calm);
  }
}
