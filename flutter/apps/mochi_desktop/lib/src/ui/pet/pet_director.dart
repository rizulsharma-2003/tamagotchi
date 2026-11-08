import 'dart:math' as math;

import 'package:mochi_art/mochi_art.dart';

import '../../core/desktop_world.dart';
import '../../core/pc_rhythm.dart';
import '../../core/session_store.dart';
import '../../core/sessions.dart';
import 'stroller.dart';
import 'world_poses.dart';

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

  /// Mochi's mood for [sessions] at [now]: the primary session's phase, or else a nap: [asleep] when Mochi's world says
  /// (the Mac's nap rules: while the PC rests, or after a quiet while); otherwise with the PC's [rhythm], while the PC
  /// rests (Settings › Characters › Naps); without it, after [napAfter] with nothing going on (counted from
  /// [lastActivity]: the last hook event, pet or launch).
  static PetMood of(
    SessionStore sessions, {
    required DateTime now,
    required DateTime lastActivity,
    Duration napAfter = const Duration(minutes: 30),
    PcRhythm? rhythm,
    bool? asleep,
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
    if (asleep != null) return asleep ? napping : relaxed;
    if (rhythm != null) return rhythm.asleep(now: now, lastActivity: lastActivity) ? napping : relaxed;
    return now.difference(lastActivity) >= napAfter ? napping : relaxed;
  }
}

/// Mochi's pose on the taskbar and the desktop, from its world (world_poses.dart): the world's moment if one plays, else
/// what the stroll has it doing there, else the world's loop. [mood] (from Claude's sessions and the world's nap) is
/// what the stroll and the frame rate go by.
class PetDirector {
  PetDirector(this.host) : poses = WorldPoses(host.world);

  final DesktopWorld host;
  final WorldPoses poses;

  PetMood mood = PetMood.relaxed;

  /// The mood changed (the world wakes Mochi itself, with a stretch, when it's back from a nap).
  void follow(PetMood next) => mood = next;

  /// One of the world's moments is playing for Mochi (a pet, Claude's news, a moment with Patch).
  bool get playing => host.world.pet.isPlayingOneShot;

  /// Mochi's pose at [time] (the world's clock), and whether it repeats (its picture is worth keeping). On the taskbar,
  /// [roam] says what Mochi is doing there and which way it faces; the world's moments still play over it. A moment
  /// together with Patch shows only [withPatch] (Patch beside Mochi).
  ///
  /// With a [quantum] (seconds), loops are played on its grid, so their poses repeat exactly as the ring comes round. A
  /// loop drawn less often than the grid never skips a blink: a pose with the eyes shut since the last one drawn shows,
  /// rather than the nearest one.
  PetFrame pose(double time, {StrollSample? roam, double? quantum, bool withPatch = false}) {
    final animator = host.world.pet;
    final scripted = animator.current.animation == PetAnimation.scripted;
    final PetFrame frame;
    if ((animator.isPlayingOneShot && !scripted) || (scripted && withPatch)) {
      frame = poses.pet(time, hold: _hold(roam), withPatch: withPatch);
    } else if (roam != null && (roam.oneShot || roam.travelling)) {
      frame = poses.pet(time, hold: _hold(roam), quantum: quantum);
    } else {
      final loop = roam?.animation ?? (animator.base == PetAnimation.scripted ? PetAnimation.idle : animator.base);
      frame = (pose: _loop(loop, roam?.animationTime ?? time, quantum), repeats: true);
    }
    return roam == null ? frame : (pose: _strolling(frame.pose, roam), repeats: frame.repeats);
  }

  static ({PetAnimation animation, double time, bool oneShot})? _hold(StrollSample? roam) =>
      roam == null ? null : (animation: roam.animation, time: roam.animationTime, oneShot: roam.oneShot);

  /// The loop time the last frame was drawn at.
  double? _lastLoop;

  /// The eyes are shut (a blink, a happy squint): a moment a frame shouldn't skip.
  static bool _shut(PetPose pose) => pose.eyes != PetEyes.open || pose.eyeOpenness < 0.5;

  /// A loop's pose at [time] on the [quantum]'s grid, or a pose with the eyes shut since the last one drawn.
  PetPose _loop(PetAnimation loop, double time, double? quantum) {
    final since = _lastLoop;
    _lastLoop = time;
    final pose = poses.petLoop(loop, time, quantum: quantum);
    final at = quantize(time, quantum);
    if (quantum == null || since == null || since > time || _shut(pose) || at - since <= quantum) return pose;
    // The grid's poses since the last drawn one (a few at most: the loops are drawn 6 to 12 times a second).
    for (var g = quantize(since, quantum) + quantum, n = 0; g < at - quantum / 2 && n < 4; g += quantum, n++) {
      final skipped = poses.petLoop(loop, g, quantum: quantum);
      if (_shut(skipped)) return skipped;
    }
    return pose;
  }

  /// [seconds] on the [quantum]'s grid.
  static double quantize(double seconds, double? quantum) => WorldPoses.quantize(seconds, quantum);

  /// Mochi's pose turned the way it walks (the poses face right), with the stroll's accents (the Mac's attentive and
  /// notice styles).
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
      case StrollStyle.hang:
        // Holding on to the clock's edge with both paws, swinging gently (a slow sway about its feet, a hair of tail).
        final t = roam.animationTime;
        pose
          ..leftArm = 1
          ..rightArm = 1
          ..eyes = PetEyes.open
          ..earPerk = math.max(pose.earPerk, 0.2)
          ..lookX = 0.25 * math.sin(t * 1.1)
          ..lookY = -0.05
          ..rotation = 0.09 * math.sin(t * 2.2)
          ..tailWag = 0.5 * math.sin(t * 2.2 + 1);
      case StrollStyle.plain:
        break;
    }
    return pose;
  }
}
