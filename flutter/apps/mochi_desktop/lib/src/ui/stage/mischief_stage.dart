// Mischief out on the native stage (docs/SPRINT_2.md, "Windows extras: crazier than the Mac"): the extras that draw on
// N1, wired to Mochi's world and the PC. Each asks MischiefGate (core/mischief.dart) before it does anything, and stops
// when it says no.
//
// - X10 full-screen celebrations: confetti for G2's big wins (graduation, a milestone, green tests or build: real,
//   live events only), fireworks for streak milestones (core/streaks.dart).
// - X4 the cursor buddy: Mochi out with your pointer (cursor_buddy.dart), from the taskbar or the desktop ([home]).
//
// Development: `MOCHI_DESKTOP_MISCHIEF_DEMO` ("confetti:20,fireworks:45") repeats a preview every so many seconds
// while the screen can be seen, for checking and measuring on a PC (with the `perf-debug` meter).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/mischief.dart';
import '../../desktop.dart';
import '../../platform/displays.dart';
import '../../platform/native_stage.dart';
import '../pet/taskbar_stroll.dart' show PetHome;
import 'celebrations.dart';
import 'cursor_buddy.dart';
import 'stage_cast.dart';
import 'stage_pet.dart';
import 'stage_sprites.dart';

class MischiefStage extends ChangeNotifier {
  MischiefStage({
    required this.desktop,
    required this.stage,
    required this.displays,
    required this.cursor,
    this.home,
    bool Function()? shown,
    bool Function()? dark,
    void Function(int x, int y)? onMenu,
    double Function()? clock,
    this.demo = const {},
  }) : cast = StageCast(stage),
       _shown = shown ?? (() => true) {
    celebrations = StageCelebrations(stage: stage, cast: cast, gate: desktop.mischief, displays: displays, cursor: cursor, clock: clock);
    final home = this.home;
    if (home != null) {
      pet = StagePet(stage: stage, cast: cast, sprites: StageSprites(stage), world: desktop.world, settings: desktop.settings, dark: dark ?? () => false);
      buddy = CursorBuddy(
        pet: pet!,
        home: home,
        gate: desktop.mischief,
        rhythm: desktop.rhythm,
        displays: displays,
        cursor: cursor,
        time: desktop.world.now,
        shown: _shown,
        reacting: () => desktop.world.reacting,
        asleep: () => desktop.world.asleep,
        onPet: () => desktop.interact('pet'),
        onMenu: onMenu,
      );
    }
  }

  final MochiDesktop desktop;
  final NativeStage stage;
  final Displays displays;

  /// Where the pointer is now (physical pixels), or null.
  final (int, int)? Function() cursor;

  /// Development: previews to repeat, every so often.
  final Map<CelebrationKind, Duration> demo;

  /// What every extra's actors last showed.
  final StageCast cast;

  /// X10.
  late final StageCelebrations celebrations;

  /// Where Mochi lives when it isn't out (the taskbar stroll), and Mochi out on the stage (null without a home: tests
  /// of the celebrations alone).
  final PetHome? home;
  StagePet? pet;

  /// X4.
  CursorBuddy? buddy;

  final bool Function() _shown;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  final List<Timer> _demoTimers = [];
  bool _started = false;

  MischiefGate get gate => desktop.mischief;

  /// The stage can show anything here (Windows).
  bool get supported => stage.supported;

  void start() {
    if (_started) return;
    _started = true;
    _subscriptions
      ..add(desktop.world.celebrated.listen(_celebrated))
      ..add(desktop.streaks.reached.listen((_) => celebrations.celebrate(CelebrationKind.fireworks)));
    buddy?.start();
    for (final MapEntry(key: kind, value: every) in demo.entries) {
      _demoTimers.add(
        Timer.periodic(every, (_) {
          if (!desktop.rhythm.unseen) celebrations.celebrate(kind, preview: true);
        }),
      );
    }
  }

  /// G2's celebrations: confetti for the big wins only (a high five for a finished turn stays on the taskbar).
  void _celebrated(w.Celebration celebration) {
    final kind = switch (celebration.reason) {
      w.CelebrationReason.firstMilestone => CelebrationKind.bigConfetti,
      w.CelebrationReason.milestone || w.CelebrationReason.buildTestPassed => CelebrationKind.confetti,
      _ => null,
    };
    if (kind != null) celebrations.celebrate(kind);
  }

  /// Settings' "Try it": a preview of [kind] now.
  bool preview(CelebrationKind kind) => celebrations.celebrate(kind, preview: true);

  /// The app's window changed form (Mochi's window or the popover opened, or the pet is back): Mochi comes home or may
  /// go out again.
  void surfaceChanged() => buddy?.consider();

  /// What's on the stage, for the perf meter (null: nothing).
  String? perfState() {
    if (celebrations.running) return 'celebration (${celebrations.playing!.name})';
    return buddy?.perfState();
  }

  /// A development switch: `MOCHI_DESKTOP_MISCHIEF_DEMO=confetti:20,fireworks:45`.
  static Map<CelebrationKind, Duration> demoFrom(String? value) {
    final demo = <CelebrationKind, Duration>{};
    for (final part in (value ?? '').split(',')) {
      final pieces = part.trim().split(':');
      if (pieces.length != 2) continue;
      final kind = CelebrationKind.values.where((kind) => kind.name == pieces[0].trim()).firstOrNull;
      final seconds = int.tryParse(pieces[1].trim());
      if (kind != null && seconds != null && seconds >= 5) demo[kind] = Duration(seconds: seconds);
    }
    return demo;
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final timer in _demoTimers) {
      timer.cancel();
    }
    buddy?.stop();
    pet?.dispose();
    pet?.sprites.dispose();
    celebrations.dispose();
    stage.dispose();
    super.dispose();
  }
}
