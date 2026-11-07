// Patch, Mochi's coding companion (the little pixel Claude at the desk), as Mochi's world runs him (core/desktop_world.dart:
// the Mac's CompanionWorld in Dart, mochi_world):
//
// - He's around while a Claude Code session is open and for a while after the last one ends (Settings › Characters:
//   "Show Patch", "Stays … after the last session ends"), always, or never. He arrives with a welcome for Mochi, packs
//   up when a session ends, and leaves when his time is up.
// - At his desk he does what Claude does: thinks, types, reads, searches, watches a command, browses, hands work to
//   helpers, waits with you when Claude needs you, idles between turns, and naps after a quiet while (Settings ›
//   Characters: "Naps after…").
// - Claude's real moments, live (never simulated, late or restored ones, G2): a finished turn is a high five with Mochi,
//   a victory dance after a long turn (both ends seen live), a tiny trophy for a real build or test that passed, detective
//   mode after repeated errors and case closed when that turn finishes, graduation for a first milestone; a burst of
//   confetti for the big ones.
// - Now and then, with nothing urgent going on, he and Mochi do something together: a coffee delivery, show and tell,
//   a ball, rock-paper-scissors, keeping watch while Mochi naps… (the Mac's scheduler, with its weights, cooldowns,
//   daily caps and this install's seed).
//
// This is the view's side of him: whether he's drawn, what he's doing, his pose (world_poses.dart) and how often he
// needs drawing. One director serves both of Patch's places, the taskbar (beside Mochi, ui/pet/taskbar_stroll.dart) and
// the room in Mochi's window (ui/pet/room_view.dart); only one shows at a time. Times are seconds on the world's clock.

import 'package:flutter/foundation.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/desktop_world.dart';
import 'world_poses.dart';

class CompanionDirector extends ChangeNotifier {
  CompanionDirector(this.host) : poses = WorldPoses(host.world) {
    _seen = _signature;
    host.addListener(_changed);
  }

  final DesktopWorld host;
  final WorldPoses poses;

  w.MochiWorld get world => host.world;

  /// Seconds on the world's clock.
  double get time => host.now();

  /// Patch is drawn: around, or leaving.
  bool get visible => world.companionPresent;

  /// Patch is on his way out (packing up and leaving): still drawn until he's gone.
  bool get departing => visible && world.companion.current.animation == CompanionAnimation.depart;

  /// Patch is around (settled in, not on his way out).
  bool get present => visible && !departing;

  /// Patch's loop right now.
  CompanionAnimation get loop => world.companion.base;

  /// He's waiting with you (Claude needs you).
  bool get waiting => present && loop == CompanionAnimation.waiting;

  /// The moment Mochi and Patch are playing together, if any.
  w.InteractionPlayback? get interaction => world.interaction;

  /// Mochi and Patch are in a moment together.
  bool get together => world.interaction != null;

  /// The confetti burst (a celebration): when it started on the world's clock, and whether it's a big one.
  ({double start, bool big})? get burst {
    final b = world.burst;
    return b == null ? null : (start: b.startedAt, big: b.big);
  }

  /// Seconds into the confetti burst at [t], while it lasts.
  double? burstAt(double t) {
    final b = world.burst;
    if (b == null) return null;
    final elapsed = t - b.startedAt;
    return elapsed >= 0 && elapsed < CelebrationArt.length ? elapsed : null;
  }

  /// The moment together at [t] (Mochi's and Patch's poses, their `x` in path units, and the props), while one plays.
  SceneFrame? scene(double t) => poses.scene(t);

  /// Patch's pose at [t]: his moment or his loop (on the [quantum]'s grid, so his loop's pictures repeat).
  CompanionPose pose(double t, {double? quantum}) => poses.companion(t, quantum: quantum).pose;

  /// Patch's pose at [t], and whether it repeats (worth keeping as a picture).
  CompanionFrame frame(double t, {double? quantum}) => poses.companion(t, quantum: quantum);

  /// Something is playing that needs smooth frames (one of his moments, a moment together, the burst).
  bool busyAt(double t) => visible && (together || world.companion.isPlayingOneShot || burstAt(t) != null);

  /// Frames a second Patch needs at [t]: 24 for a moment, 12 at work (the screen scrolls), 10 idle (blinks), 6 asleep.
  double frameRate(double t) {
    if (!visible) return burstAt(t) != null ? 24 : 0;
    if (busyAt(t)) return 24;
    return switch (loop) {
      CompanionAnimation.sleep || CompanionAnimation.rest || CompanionAnimation.offline => 6,
      CompanionAnimation.idleAtDesk || CompanionAnimation.waiting => 10,
      _ => 12,
    };
  }

  /// What a screen reader says about him ("Patch is typing at his desk").
  String describe(String name) {
    if (!visible) return '$name is away';
    if (departing) return '$name is heading off';
    final current = interaction;
    if (current != null) return '$name and ${world.settings.petName}: ${current.id.title.toLowerCase()}';
    return switch (loop) {
      CompanionAnimation.idleAtDesk => '$name is at his desk',
      CompanionAnimation.thinking => '$name is thinking',
      CompanionAnimation.typing => '$name is typing at his desk',
      CompanionAnimation.reading => '$name is reading',
      CompanionAnimation.searching => '$name is searching',
      CompanionAnimation.runningCommand => '$name is watching a command run',
      CompanionAnimation.browsing => '$name is browsing the web',
      CompanionAnimation.delegating => '$name is handing work to helpers',
      CompanionAnimation.waiting => '$name is waiting for you',
      CompanionAnimation.detective => '$name is investigating',
      CompanionAnimation.rest => '$name is resting',
      CompanionAnimation.sleep => '$name is napping at his desk',
      final other => '$name is ${other.title.toLowerCase()}',
    };
  }

  /// You clicked Patch: he waves back (or nods, at work).
  void greet() => host.pokeCompanion();

  bool _disposed = false;
  Object? _seen;

  /// What his views go by: whether he's here or leaving, his loop and moment, a moment together, the burst.
  Object get _signature => (
    world.companionPresent,
    world.companion.base,
    world.companion.current.token,
    world.interaction?.startedAt,
    world.burst?.startedAt,
  );

  /// Mochi's world changed: listeners hear only about Patch's news.
  void _changed() {
    final signature = _signature;
    if (_disposed || signature == _seen) return;
    _seen = signature;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    host.removeListener(_changed);
    super.dispose();
  }
}
