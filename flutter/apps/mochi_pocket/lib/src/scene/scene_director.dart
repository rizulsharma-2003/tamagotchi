import 'dart:math' as math;

import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/pocket_model.dart';
import 'pose_library.dart';

/// Which animation Mochi and Patch play, from what Claude is doing on the Mac and what just happened here. The Mac's
/// rules (TamagotchiCore `EventToAnimationMapper.companionLoop`, `workLoop`, `petLoop`) pick the loops; pets, plays,
/// treats and replies play once over them. The iPhone runs the whole pet world; until that's ported, this is the
/// small part a pocket needs.
class SceneDirector {
  SceneDirector({math.Random? random}) : _random = random ?? math.Random();

  final math.Random _random;

  PetAnimation petLoop = PetAnimation.idle;
  CompanionAnimation companionLoop = CompanionAnimation.idleAtDesk;
  ({PetAnimation animation, int variant, double start})? petShot;
  ({CompanionAnimation animation, double start})? companionShot;
  String? _phase;

  /// Patch's work loop for a tool category (`workLoop(for:)`).
  static CompanionAnimation workLoop(String? category) => switch (category) {
    'think' => CompanionAnimation.thinking,
    'read' => CompanionAnimation.reading,
    'search' => CompanionAnimation.searching,
    'shell' => CompanionAnimation.runningCommand,
    'web' => CompanionAnimation.browsing,
    'agent' => CompanionAnimation.delegating,
    _ => CompanionAnimation.typing,
  };

  /// Follows Claude on the Mac: Patch works while Claude works, Mochi watches, both sleep while the Mac rests, and a
  /// finished or failed turn gets a reaction.
  void follow(ClaudeMirror? claude, {required double time}) {
    final phase = claude?.phase ?? 'none';
    final resting = claude?.resting ?? false;
    petLoop = resting
        ? PetAnimation.sleep
        : switch (phase) {
            'working' => PetAnimation.watch,
            'waiting' => PetAnimation.waveGently,
            _ => PetAnimation.idle,
          };
    companionLoop = resting
        ? CompanionAnimation.sleep
        : switch (phase) {
            'working' => workLoop(claude?.category),
            'waiting' => CompanionAnimation.waiting,
            _ => CompanionAnimation.idleAtDesk,
          };
    final previous = _phase;
    _phase = phase;
    if (previous == null || previous == phase || resting) return;
    if (phase == 'done') {
      _pet(PetAnimation.happyBounce, time);
      companionShot = (animation: CompanionAnimation.celebrate, start: time);
    } else if (phase == 'error') {
      _pet(PetAnimation.concerned, time);
      companionShot = (animation: CompanionAnimation.concerned, start: time);
    }
  }

  /// Something just happened: a pet, play or treat (here or on the Mac), or news about a request.
  void cue(PetCue cue, {required double time}) {
    switch (cue) {
      case PetCue.pet:
        _pet(PetAnimation.petted, time, variants: 3);
        companionShot = (animation: CompanionAnimation.pat, start: time);
      case PetCue.play:
        _pet(PetAnimation.play, time, variants: 4);
      case PetCue.treat:
        _pet(PetAnimation.treat, time, variants: 4);
      case PetCue.sending:
        _pet(PetAnimation.nod, time);
      case PetCue.working:
        if (!_playing(time)) _pet(PetAnimation.lookAround, time);
      case PetCue.replied:
        _pet(PetAnimation.happyBounce, time);
        companionShot = (animation: CompanionAnimation.nod, start: time);
      case PetCue.failed:
        _pet(PetAnimation.concerned, time);
    }
  }

  /// A pet, play or treat is still playing: news about a request doesn't cut it short.
  bool _playing(double time) {
    final shot = petShot;
    if (shot == null) return false;
    final interaction =
        shot.animation == PetAnimation.petted || shot.animation == PetAnimation.play || shot.animation == PetAnimation.treat;
    return interaction && time - shot.start < 3;
  }

  void _pet(PetAnimation animation, double time, {int variants = 1}) {
    petShot = (animation: animation, variant: variants > 1 ? _random.nextInt(variants) : 0, start: time);
  }

  /// With animations turned off (Android's "Remove animations"), everyone keeps living, calmer: loops play at half
  /// speed and every pose moves only a third of the way from the track's resting frame, as the iPhone calms Mochi's
  /// idle life under Reduce Motion instead of freezing it.
  static const double calmSpeed = 0.5;
  static const double calmAmount = 0.35;

  /// [track] at [time]; calmed as above when [calm] (a one-shot keeps its timing so it still ends on time).
  static T calmed<T>(PoseTrack<T> track, double time, {required bool calm, bool oneShot = false}) {
    if (!calm) return track.at(time);
    return track.blend(track.at(0), track.at(oneShot ? time : time * calmSpeed), calmAmount);
  }

  /// Mochi's and Patch's poses at [time] (seconds on the room's clock).
  ({PetPose pet, CompanionPose companion}) poses(PoseLibrary? library, double time, {bool calm = false}) {
    if (library == null) return (pet: PetPose(), companion: CompanionPose());
    PetPose? pet;
    final shot = petShot;
    if (shot != null) {
      final track = library.petTrack(shot.animation, shot.variant);
      if (track != null && time - shot.start < track.length) {
        pet = calmed<PetPose>(track, time - shot.start, calm: calm, oneShot: true);
      } else {
        petShot = null;
      }
    }
    final petTrack = library.petTrack(petLoop);
    pet ??= petTrack == null ? PetPose() : calmed<PetPose>(petTrack, time, calm: calm);
    CompanionPose? companion;
    final companionShot = this.companionShot;
    if (companionShot != null) {
      final track = library.companionTrack(companionShot.animation);
      if (track != null && time - companionShot.start < track.length) {
        companion = calmed<CompanionPose>(track, time - companionShot.start, calm: calm, oneShot: true);
      } else {
        this.companionShot = null;
      }
    }
    final companionTrack = library.companionTrack(companionLoop);
    companion ??= companionTrack == null ? CompanionPose() : calmed<CompanionPose>(companionTrack, time, calm: calm);
    return (pet: pet, companion: companion);
  }
}
