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
// - X11 holiday takeover (holiday_takeover.dart): on Diwali lights, at Christmas snow along the top of the window you're
//   using; at Halloween pumpkins on the taskbar.
// - X12 weather and time moods (core/moods.dart): the morning coffee with Patch; the umbrella while it rains (drawn by the
//   pet's own view on the taskbar, not here).
// - X2 window nudges (core/window_nudge.dart, with adventure.dart for the wobble and the shove): the terminal tug is here,
//   when Claude needs you and you're at the PC. One WindowNudger runs them all, one nudge at a time; quitting puts a
//   nudged window back (desktop.dispose reaches it, and so does dispose here).
// - W26 Mochi on the taskbar while Mochi's window is open (stage_stand.dart): the stroll goes on, drawn by the stage.
//
// Development: `MOCHI_DESKTOP_MISCHIEF_DEMO` ("confetti:20,fireworks:45") repeats a preview every so many seconds
// while the screen can be seen, for checking and measuring on a PC (with the `perf-debug` meter);
// `MOCHI_DESKTOP_ADVENTURE_DEMO=60` sets Mochi off on an adventure every 60 seconds (at least 5) the same way;
// `MOCHI_DESKTOP_NUDGE=wobble|shove|tug` makes that nudge happen at every qualifying moment (with the adventure demo every
// landing wobbles; `tug` shakes the front-most editor or terminal 10 seconds after start and every 60 seconds while the
// screen can be seen). The gate and the window rules still apply.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/json_store.dart';
import '../../core/moods.dart';
import '../../core/mischief.dart';
import '../../core/pet_cues.dart';
import '../../core/reacts.dart' show EditorApps;
import '../../core/sessions.dart' show SessionPhase;
import '../../core/window_nudge.dart';
import '../../desktop.dart';
import '../../platform/displays.dart';
import '../../platform/foreground_window.dart';
import '../../platform/native_stage.dart';
import '../../platform/taskbar.dart' show PixelRect, TaskbarStage;
import '../../platform/window_frames.dart';
import '../pet/taskbar_stroll.dart' show PetHome;
import 'adventure.dart';
import 'celebrations.dart';
import 'holiday_takeover.dart';
import 'screen_roamer.dart';
import 'stage_behind.dart';
import 'stage_cast.dart';
import 'stage_pet.dart';
import 'stage_sprites.dart';
import 'stage_stand.dart';
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
    this.taskbar,
    this.takeoverOccasion,
    bool Function()? patchOnTaskbar,
    http.Client Function()? weatherClient,
    bool? weather,
    WindowMover? mover,
    JsonStore? nudgeStore,
    this.nudgeForce,
    void Function(String)? nudgeLog,
  }) : cast = StageCast(stage),
       _shown = shown ?? (() => true),
       _clock = clock {
    nudger = WindowNudger(
      mover: mover ?? const NoWindowMover(),
      store: nudgeStore ?? MemoryJsonStore(),
      allowed: () => desktop.mischief.may(MischiefExtra.windowNudges),
      clock: clock ?? desktop.world.now,
      log: nudgeLog,
    );
    _mover = mover ?? const NoWindowMover();
    // The gate changing (a rule, a switch) sends a nudged window home at once; quitting does too.
    desktop.mischief.addListener(nudger.recheck);
    desktop.addExitHook(nudger.putBack);
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
    moods = DesktopMoods(
      settings: desktop.settings,
      world: desktop.world,
      rhythm: desktop.rhythm,
      gate: desktop.mischief,
      patchOnTaskbar: patchOnTaskbar ?? (() => false),
      client: weatherClient,
      forced: weather,
    );
    takeover = HolidayTakeover(
      stage: stage,
      cast: cast,
      gate: desktop.mischief,
      rhythm: desktop.rhythm,
      holidays: desktop.holidays,
      displays: displays,
      frames: frames,
      foreground: foreground,
      taskbar: taskbar,
      force: takeoverOccasion,
      dark: dark,
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
      // Mochi on the taskbar while Mochi's window is open (W26): its own actor, drawn from the same pictures, and never hiding
      // behind the window you're using. A click is the tray icon's click: Mochi's own page.
      stand = StageStand(
        pet: StagePet(stage: stage, cast: cast, sprites: pet!.sprites, world: desktop.world, settings: desktop.settings, dark: dark ?? () => false),
        time: desktop.world.now,
        onTap: onOpen,
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
        nudger: nudger,
        nudgeForce: nudgeForce,
        random: random,
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

  /// X2: the one nudge that may run at a time, the development switch, and what Windows says about windows.
  late final WindowNudger nudger;
  final NudgeForce? nudgeForce;
  late final WindowMover _mover;
  final double Function()? _clock;

  /// When the terminal last tugged (seconds on the nudger's clock); null: not yet this session.
  double? _lastTug;

  /// A tug at most this often (seconds).
  static const double tugEvery = 120;

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

  /// The main taskbar as the stroll last measured it (X11's pumpkins stand in a free stretch of it), and the development
  /// switch that forces a holiday's takeover (`MOCHI_DESKTOP_TAKEOVER`).
  final TaskbarStage? Function()? taskbar;
  final w.SeasonalEvent? takeoverOccasion;

  /// What every extra's actors last showed.
  final StageCast cast;

  /// X10.
  late final StageCelebrations celebrations;

  /// Where Mochi lives when it isn't out (the taskbar stroll), and Mochi out on the stage (null without a home: tests
  /// of the celebrations alone).
  final PetHome? home;
  StagePet? pet;

  /// Mochi on the taskbar while Mochi's window is open (W26; null without a home).
  StageStand? stand;

  /// X8.
  ScreenRoamer? roamer;

  /// W19.
  DesktopAdventure? adventure;

  /// X9.
  late final StickyNotes notes;

  /// X11.
  late final HolidayTakeover takeover;

  /// X12: the morning coffee with Patch, and the umbrella when it rains ([DesktopMoods.umbrella]).
  late final DesktopMoods moods;

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
    // A nudge cut short by a crash or a kill left its journal: that window goes home first.
    nudger.recover();
    _subscriptions
      ..add(desktop.world.celebrated.listen(_celebrated))
      ..add(desktop.streaks.reached.listen(_streak))
      ..add(desktop.cues.listen(_cue));
    notes.start();
    takeover.start();
    moods.start();
    desktop.world.everyMinute(_minute);
    roamer?.start();
    adventure?.start();
    if (nudgeForce == NudgeForce.tug) {
      // Development: the tug 10 seconds after start and every 60 seconds while the screen can be seen.
      _demoTimers.add(
        Timer(const Duration(seconds: 10), () {
          _forcedTug();
          _demoTimers.add(Timer.periodic(const Duration(seconds: 60), (_) => _forcedTug()));
        }),
      );
    }
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
    if (cue == PetCue.needsYou) tug();
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

  /// Claude needs you and you're at the PC (not away): the front-most editor or terminal window that isn't the one you're
  /// using gets a little shake, once per needs-you and at most once every two minutes. True when one did. Windows nudges
  /// only; the Windows notification for "needs you" is untouched.
  bool tug({bool force = false}) {
    if (_disposed || nudger.running || !gate.may(MischiefExtra.windowNudges)) return false;
    if (nudgeForce != null && nudgeForce != NudgeForce.tug && !force) return false;
    if (!force) {
      if (desktop.rhythm.away != false) return false;
      final last = _lastTug;
      if (last != null && _seconds() - last < tugEvery) return false;
    }
    for (final frame in frames.list()) {
      if (nudger.qualify(frame.hwnd) != null || !EditorApps.matches(_mover.processName(frame.hwnd))) continue;
      final started = nudger.start(frame.hwnd, NudgeKind.tug, scale: _scaleOf(frame.frame));
      if (started) _lastTug = _seconds();
      return started;
    }
    return false;
  }

  void _forcedTug() {
    if (!desktop.rhythm.unseen) tug(force: true);
  }

  double _seconds() => (_clock ?? desktop.world.now)();

  /// The scale of the display most of [window] is on.
  double _scaleOf(PixelRect window) {
    final x = (window.left + window.right) ~/ 2, y = (window.top + window.bottom) ~/ 2;
    for (final display in displays.list()) {
      if (display.monitor.contains(x, y)) return display.scale;
    }
    return 1;
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

  /// Settings' "Try it" for the holiday takeover: [event]'s decoration for 20 seconds.
  bool previewTakeover(w.SeasonalEvent event) => takeover.preview(event);

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
    return takeover.perfState() ?? adventure?.perfState() ?? roamer?.perfState() ?? (notes.notes.isEmpty || notes.hidden ? null : 'notes up (${notes.notes.length})');
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

  /// A development switch: `MOCHI_DESKTOP_NUDGE=wobble|shove|tug`.
  static NudgeForce? nudgeFrom(String? value) => NudgeForce.from(value);

  /// A development switch: `MOCHI_DESKTOP_WEATHER=rain|clear` forces the weather (and skips the network).
  static bool? weatherFrom(String? value) => switch ((value ?? '').trim().toLowerCase()) {
    'rain' => true,
    'clear' => false,
    _ => null,
  };

  /// A development switch: `MOCHI_DESKTOP_TAKEOVER=diwali|christmas|halloween` forces that occasion's takeover.
  static w.SeasonalEvent? takeoverFrom(String? value) {
    final name = (value ?? '').trim().toLowerCase();
    return [w.SeasonalEvent.diwali, w.SeasonalEvent.christmas, w.SeasonalEvent.halloween].where((event) => event.name == name).firstOrNull;
  }

  /// A development switch: `MOCHI_DESKTOP_ADVENTURE_DEMO=60` (seconds, at least 5).
  static Duration? adventureDemoFrom(String? value) {
    final seconds = int.tryParse((value ?? '').trim());
    return seconds == null || seconds < 5 ? null : Duration(seconds: seconds);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      desktop.mischief.removeListener(nudger.recheck);
    } on FlutterError {
      // The gate went with the app (quitting disposes it first).
    }
    desktop.removeExitHook(nudger.putBack);
    nudger.dispose();
    notes.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final timer in _demoTimers) {
      timer.cancel();
    }
    adventure?.stop();
    roamer?.stop();
    stand?.dispose();
    pet?.dispose();
    pet?.sprites.dispose();
    takeover.dispose();
    moods.dispose();
    celebrations.dispose();
    stage.dispose();
    super.dispose();
  }
}
