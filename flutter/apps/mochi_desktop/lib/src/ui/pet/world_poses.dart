// Mochi's and Patch's poses from Mochi's world (mochi_world's evaluators, the Mac's), for the taskbar pet and the
// desktop pet, drawn so the pictures of poses (pose_sprites.dart, W30) keep paying off:
//
// - A loop (idle, watching, asleep, sitting, walking…) is played on a ring of [WorldPoses.ring] seconds: the same 5 s
//   of the world's loop, for this install's seed, come round again and again, as the recordings did, so on the
//   animation grid its poses repeat exactly and each is drawn once. The ring is seamless (its last half second blends
//   into its start) and 5 s holds whole steps of the walk and the run.
// - One of the world's moments (Claude's news, a pet, a game with Patch) carries on from where the ring was when it
//   started, so it eases out of the loop and back into it without a jump; it's drawn from the art (it doesn't repeat).
// - A little moment of the stroll's own (a sniff, a scratch) plays from a fixed start, so it repeats and is kept.
//
// The room in Mochi's window and the popover draws `MochiWorld.frame` as it is (room_view.dart).

import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_world/mochi_world.dart' as w;

/// A pose and whether it repeats (so its picture is worth keeping).
typedef PetFrame = ({PetPose pose, bool repeats});
typedef CompanionFrame = ({CompanionPose pose, bool repeats});

class WorldPoses {
  const WorldPoses(this.world);

  final w.MochiWorld world;

  /// Seconds a loop takes to come round (a multiple of the walk's and the run's steps).
  static const double ring = 5;

  /// The ring's last stretch, blended into its start.
  static const double seam = 0.5;

  /// Where the stroll's own moments start on the clock.
  static const double strollOrigin = 1000;

  /// [t] on the ring (0 ≤ r < [ring]); with a [quantum], on its grid, as the very same number each time round.
  static double ringTime(double t, [double? quantum]) {
    if (!t.isFinite) return 0;
    final r = t - (t / ring).floorToDouble() * ring;
    if (quantum == null || quantum <= 0) return r;
    final steps = (ring / quantum).round();
    final n = (r / quantum).round() % steps;
    return n * quantum;
  }

  /// [seconds] on the [quantum]'s grid.
  static double quantize(double seconds, double? quantum) =>
      quantum == null || !seconds.isFinite ? seconds : (seconds / quantum).roundToDouble() * quantum;

  w.PoseContext _pet(double time, [PetAnimation returnLoop = PetAnimation.idle]) => w.PoseContext(
    time: time,
    reducedMotion: world.reducedMotion,
    intensity: world.settings.animationIntensity,
    seed: world.seed,
    returnLoop: returnLoop,
  );

  w.PoseContext _companion(double time) =>
      w.PoseContext(time: time, reducedMotion: world.reducedMotion, intensity: world.settings.animationIntensity, seed: world.seed + 0x5EED);

  // MARK: Mochi

  /// Mochi's [loop] at [t] on the ring (exactly repeating on a [quantum]'s grid).
  PetPose petLoop(PetAnimation loop, double t, {double? quantum}) {
    final r = ringTime(t, quantum);
    PetPose at(double time) => w.PetPoseEvaluator.pose(loop, elapsed: time, context: _pet(time, loop), variant: 0);
    final pose = at(r);
    if (r < ring - seam) return pose;
    return PetPose.lerp(pose, at(r - ring), Ease.smooth((r - (ring - seam)) / seam));
  }

  /// Mochi at [t] (the world's clock): the world's moment if one plays, else [hold] (what the stroll has it doing,
  /// with its own time), else the world's loop. A moment together with Patch shows only where he's drawn beside Mochi
  /// ([withPatch]; [scene] has it): elsewhere Mochi carries on as it was.
  PetFrame pet(double t, {({PetAnimation animation, double time, bool oneShot})? hold, double? quantum, bool withPatch = false}) {
    final animator = world.pet;
    final current = animator.current;
    final scripted = current.animation == PetAnimation.scripted;
    if (animator.isPlayingOneShot && !scripted) {
      final returnLoop = hold != null && !hold.oneShot && hold.animation.isLoop ? hold.animation : animator.base;
      return (pose: oneShot(current, t, returnLoop: returnLoop), repeats: false);
    }
    if (scripted && withPatch) {
      final frame = scene(t);
      if (frame != null) return (pose: frame.pet, repeats: false);
    }
    if (hold != null) {
      if (hold.oneShot) {
        final elapsed = quantize(hold.time, quantum);
        final pose = w.PetPoseEvaluator.pose(hold.animation, elapsed: elapsed, context: _pet(strollOrigin + elapsed), variant: 0);
        return (pose: pose, repeats: true);
      }
      return (pose: petLoop(hold.animation, hold.time, quantum: quantum), repeats: true);
    }
    final base = animator.base;
    return (pose: petLoop(base == PetAnimation.scripted ? PetAnimation.idle : base, t, quantum: quantum), repeats: true);
  }

  /// One of the world's one-shots at [t], its living base carrying on from the ring where it started.
  PetPose oneShot(w.Playing<PetAnimation> current, double t, {required PetAnimation returnLoop}) {
    final elapsed = current.elapsed(t);
    final life = ringTime(current.startedAt) + elapsed;
    return w.PetPoseEvaluator.pose(
      current.animation,
      elapsed: elapsed,
      duration: current.duration,
      context: _pet(life, returnLoop),
      variant: w.PetPoseEvaluator.variant(current.animation, startedAt: current.startedAt, seed: world.seed),
    );
  }

  // MARK: Patch

  /// Patch's [loop] at [t] on the ring.
  CompanionPose companionLoop(CompanionAnimation loop, double t, {double? quantum}) {
    final r = ringTime(t, quantum);
    final detail = world.companionDetail;
    CompanionPose at(double time) => w.CompanionPoseEvaluator.pose(loop, elapsed: time, context: _companion(time), detail: detail);
    final pose = at(r);
    if (r < ring - seam) return pose;
    return CompanionPose.lerp(pose, at(r - ring), Ease.smooth((r - (ring - seam)) / seam));
  }

  /// Patch at [t]: his moment (arriving, a wave, packing up…) or his loop. In a moment together, [scene] has him.
  CompanionFrame companion(double t, {double? quantum}) {
    final animator = world.companion;
    final current = animator.current;
    if (animator.isPlayingOneShot && current.animation != CompanionAnimation.scripted) {
      final elapsed = current.elapsed(t);
      final life = ringTime(current.startedAt) + elapsed;
      final pose = w.CompanionPoseEvaluator.pose(
        current.animation,
        elapsed: elapsed,
        duration: current.duration,
        context: _companion(life),
        detail: world.companionDetail,
      );
      return (pose: pose, repeats: false);
    }
    final base = animator.base;
    final loop = base == CompanionAnimation.scripted || base == CompanionAnimation.absent ? CompanionAnimation.idleAtDesk : base;
    return (pose: companionLoop(loop, t, quantum: quantum), repeats: true);
  }

  // MARK: Together

  /// Mochi and Patch in a moment together at [t] (their `x` in path units: 0 at Mochi's spot, 1 at Patch's), and the
  /// props; null when none plays. A side that something more important interrupted plays its own animation, as the
  /// world's own frame does.
  SceneFrame? scene(double t) {
    final playback = world.interaction;
    if (playback == null) return null;
    final name = playback.id.name;
    final petIn = world.pet.current.scriptID == name;
    final companionIn = world.companion.current.scriptID == name;
    if (!petIn && !companionIn) return null;
    final elapsed = t - playback.startedAt;
    final life = ringTime(playback.startedAt) + elapsed;
    final frame = w.InteractionLibrary.frame(
      playback,
      elapsed: elapsed,
      petContext: _pet(life),
      companionContext: _companion(life),
      detail: world.companionDetail,
    );
    return SceneFrame(
      pet: petIn ? frame.pet : pet(t).pose,
      companion: companionIn ? frame.companion : companion(t).pose,
      props: frame.props,
      subagents: world.companionDetail.subagents,
    );
  }
}
