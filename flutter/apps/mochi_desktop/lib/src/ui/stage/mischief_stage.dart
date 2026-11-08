// Mischief out on the native stage (docs/SPRINT_2.md, "Windows extras: crazier than the Mac"): the extras that draw on
// N1, wired to Mochi's world and the PC. Each asks MischiefGate (core/mischief.dart) before it does anything, and stops
// when it says no.
//
// - X10 full-screen celebrations: confetti for G2's big wins (graduation, a milestone, green tests or build: real,
//   live events only), fireworks for streak milestones (core/streaks.dart).
// - X4 the cursor buddy: Mochi out with your pointer (cursor_buddy.dart), from the taskbar or the desktop ([home]).
// - X8 roaming screens (screen_roamer.dart): Mochi walks to the next display and follows you to the one you work on.
// - X9 sticky notes (sticky_notes.dart): green tests; Claude finishing or needing you while you're away from the PC; a
//   stretch break after the best part of an hour at it; a streak milestone.
//
// Development: `MOCHI_DESKTOP_MISCHIEF_DEMO` ("confetti:20,fireworks:45") repeats a preview every so many seconds
// while the screen can be seen, for checking and measuring on a PC (with the `perf-debug` meter).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/json_store.dart';
import '../../core/mischief.dart';
import '../../core/pet_cues.dart';
import '../../desktop.dart';
import '../../platform/displays.dart';
import '../../platform/native_stage.dart';
import '../pet/taskbar_stroll.dart' show PetHome;
import 'celebrations.dart';
import 'cursor_buddy.dart';
import 'screen_roamer.dart';
import 'stage_cast.dart';
import 'stage_pet.dart';
import 'stage_sprites.dart';
import 'sticky_notes.dart';

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
    void Function()? onOpen,
    JsonStore? notesStore,
    double Function()? clock,
    math.Random? random,
    this.demo = const {},
  }) : cast = StageCast(stage),
       _shown = shown ?? (() => true) {
    celebrations = StageCelebrations(stage: stage, cast: cast, gate: desktop.mischief, displays: displays, cursor: cursor, clock: clock);
    notes = StickyNotes(
      stage: stage,
      cast: cast,
      gate: desktop.mischief,
      rhythm: desktop.rhythm,
      displays: displays,
      settings: desktop.settings,
      store: notesStore ?? MemoryJsonStore(),
      onOpen: onOpen,
      clock: () => desktop.sessions.now,
      seconds: clock,
    );
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
      roamer = ScreenRoamer(
        pet: pet!,
        home: home,
        gate: desktop.mischief,
        displays: displays,
        time: desktop.world.now,
        shown: _shown,
        reacting: () => desktop.world.reacting,
        random: random,
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

  /// X8.
  ScreenRoamer? roamer;

  /// X9.
  late final StickyNotes notes;

  /// Minutes in a row at the PC (for the stretch break), and whether this is gone.
  int _activeMinutes = 0;
  bool _disposed = false;

  /// After this many minutes at the PC without a five-minute break, a stretch note.
  static const int stretchAfter = 55;

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
      ..add(desktop.streaks.reached.listen(_streak))
      ..add(desktop.cues.listen(_cue));
    notes.start();
    desktop.world.everyMinute(_minute);
    buddy?.start();
    roamer?.start();
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
    if (celebration.reason == w.CelebrationReason.buildTestPassed) {
      notes.leave(NoteKind.testsPassed, NoteWords.testsPassed(desktop.sessions.primary?.project));
    }
  }

  void _streak(int days) {
    celebrations.celebrate(CelebrationKind.fireworks);
    notes.leave(NoteKind.streak, NoteWords.streak(days));
  }

  /// Claude finished, or needs you, while you're away from the PC: a note for when you're back.
  void _cue(PetCue cue) {
    if (desktop.rhythm.away != true) return;
    final project = desktop.sessions.primary?.project;
    switch (cue) {
      case PetCue.finished:
        notes.leave(NoteKind.finishedAway, NoteWords.finishedAway(project));
      case PetCue.needsYou:
        notes.leave(NoteKind.needsYouAway, NoteWords.needsYouAway(project));
      default:
        break;
    }
  }

  /// Once a minute (only while the screen can be seen): the best part of an hour at the PC without a five-minute
  /// break, and a stretch note.
  void _minute() {
    if (_disposed) return;
    final activity = desktop.rhythm.activity;
    if (activity == null) return;
    if (activity.idleSeconds >= 300) {
      _activeMinutes = 0;
    } else if (activity.idleSeconds < 120) {
      _activeMinutes++;
    }
    if (_activeMinutes >= stretchAfter) {
      _activeMinutes = 0;
      notes.leave(NoteKind.stretch, NoteWords.stretch);
    }
  }

  /// The minutes at the PC counted so far (tests).
  int get activeMinutes => _activeMinutes;

  /// Settings' "Leave a note".
  StickyNote? previewNote() => notes.leave(NoteKind.hello, NoteWords.hello, preview: true);

  /// Settings' "Try it": a preview of [kind] now.
  bool preview(CelebrationKind kind) => celebrations.celebrate(kind, preview: true);

  /// The app's window changed form (Mochi's window or the popover opened, or the pet is back): Mochi comes home or may
  /// go out again.
  void surfaceChanged() {
    buddy?.consider();
    roamer?.consider();
  }

  /// What's on the stage, for the perf meter (null: nothing).
  String? perfState() {
    if (celebrations.running) return 'celebration (${celebrations.playing!.name})';
    return buddy?.perfState() ?? roamer?.perfState() ?? (notes.notes.isEmpty || notes.hidden ? null : 'notes up (${notes.notes.length})');
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
    _disposed = true;
    notes.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final timer in _demoTimers) {
      timer.cancel();
    }
    buddy?.stop();
    roamer?.stop();
    pet?.dispose();
    pet?.sprites.dispose();
    celebrations.dispose();
    stage.dispose();
    super.dispose();
  }
}
