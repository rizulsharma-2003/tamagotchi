// Mischief out on the native stage (docs/SPRINT_2.md, "Windows extras: crazier than the Mac"): the extras that draw on
// N1, wired to Mochi's world and the PC. Each asks MischiefGate (core/mischief.dart) before it does anything, and stops
// when it says no.
//
// - X10 full-screen celebrations: confetti for G2's big wins (graduation, a milestone, green tests or build: real,
//   live events only), fireworks for streak milestones (core/streaks.dart).
// - X4 the cursor buddy lives on the taskbar now (ui/pet/taskbar_stroll.dart), not here.
// - X8 roaming screens (screen_roamer.dart): Mochi walks to the next display and follows you to the one you work on.
// - X9 sticky notes (sticky_notes.dart): green tests; Claude finishing or needing you while you're away from the PC; a
//   stretch break after the best part of an hour at it; a streak milestone.
// - X3 Peekaboo (stage_behind.dart): out on the stage, Mochi sits just below the window you're using and peeks out from
//   behind it (the taskbar's hide-while-you're-away is in ui/pet/taskbar_stroll.dart).
// - W19 desktop adventures (adventure.dart): the Mac's explore-the-desktop, on the same stage and the same StagePet. It's
//   a Mac feature, so it isn't behind the Mischief switches (only the rules every extra keeps); of the roamer and the
//   adventure only one has Mochi out at a time, and an adventure you asked for takes Mochi from the roamer.
//
// Development: `MOCHI_DESKTOP_MISCHIEF_DEMO` ("confetti:20,fireworks:45") repeats a preview every so many seconds
// while the screen can be seen, for checking and measuring on a PC (with the `perf-debug` meter);
// `MOCHI_DESKTOP_ADVENTURE_DEMO=60` sets Mochi off on an adventure every 60 seconds (at least 5) the same way.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/json_store.dart';
import '../../core/mischief.dart';
import '../../core/pet_cues.dart';
import '../../core/sessions.dart' show SessionPhase;
import '../../desktop.dart';
import '../../platform/displays.dart';
import '../../platform/foreground_window.dart';
import '../../platform/native_stage.dart';
import '../../platform/window_frames.dart';
import '../pet/taskbar_stroll.dart' show PetHome;
import 'adventure.dart';
import 'celebrations.dart';
import 'screen_roamer.dart';
import 'stage_behind.dart';
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
    this.frames = const NoWindowFrames(),
    this.foreground = const NoForegroundWindow(),
    this.adventureDemo,
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
      pet = StagePet(
        stage: stage,
        cast: cast,
        sprites: StageSprites(stage),
        world: desktop.world,
        settings: desktop.settings,
        dark: dark ?? () => false,
        behind: StageBehind(stage: stage, gate: desktop.mischief, rhythm: desktop.rhythm, foreground: foreground),
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
      adventure = DesktopAdventure(
        pet: pet!,
        home: home,
        gate: desktop.mischief,
        rhythm: desktop.rhythm,
        displays: displays,
        windows: frames,
        settings: desktop.settings,
        world: desktop.world.world,
        time: desktop.world.now,
        shown: _shown,
        cursor: cursor,
        busy: _claudeBusy,
        needsYou: _claudeWaits,
        asleep: () => desktop.world.asleep,
        patchHere: () => desktop.world.world.companionPresent,
        yielding: () => roamer?.release(),
        onPet: () => desktop.interact('pet'),
        onMenu: onMenu,
        demo: adventureDemo,
      );
    }
  }

  /// A Claude session is working or waiting for you (the Mac's "context.activity != .idle").
  bool _claudeBusy() {
    final session = desktop.sessions.primary;
    if (session == null || session.isStale(desktop.sessions.now)) return false;
    return session.phase == SessionPhase.waitingForUser || session.phase.isWorking;
  }

  /// A session waits for you.
  bool _claudeWaits() {
    final session = desktop.sessions.primary;
    return session != null && !session.isStale(desktop.sessions.now) && session.phase == SessionPhase.waitingForUser;
  }

  final MochiDesktop desktop;
  final NativeStage stage;
  final Displays displays;

  /// Where the pointer is now (physical pixels), or null.
  final (int, int)? Function() cursor;

  /// Development: previews to repeat, every so often.
  final Map<CelebrationKind, Duration> demo;

  /// Where other apps' windows are (W19, X1), the window with the focus (X3), and the development switch that sets
  /// Mochi off every so often.
  final WindowFrames frames;
  final ForegroundWindows foreground;
  final Duration? adventureDemo;

  /// What every extra's actors last showed.
  final StageCast cast;

  /// X10.
  late final StageCelebrations celebrations;

  /// Where Mochi lives when it isn't out (the taskbar stroll), and Mochi out on the stage (null without a home: tests
  /// of the celebrations alone).
  final PetHome? home;
  StagePet? pet;

  /// X8.
  ScreenRoamer? roamer;

  /// W19.
  DesktopAdventure? adventure;

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
    roamer?.start();
    adventure?.start();
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
    adventure?.consider();
    roamer?.consider();
  }

  /// What's on the stage, for the perf meter (null: nothing).
  String? perfState() {
    if (celebrations.running) return 'celebration (${celebrations.playing!.name})';
    return adventure?.perfState() ?? roamer?.perfState() ?? (notes.notes.isEmpty || notes.hidden ? null : 'notes up (${notes.notes.length})');
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

  /// A development switch: `MOCHI_DESKTOP_ADVENTURE_DEMO=60` (seconds, at least 5).
  static Duration? adventureDemoFrom(String? value) {
    final seconds = int.tryParse((value ?? '').trim());
    return seconds == null || seconds < 5 ? null : Duration(seconds: seconds);
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
    adventure?.stop();
    roamer?.stop();
    pet?.dispose();
    pet?.sprites.dispose();
    celebrations.dispose();
    stage.dispose();
    super.dispose();
  }
}
