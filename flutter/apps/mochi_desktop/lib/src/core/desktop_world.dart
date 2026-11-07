// Mochi's world on this PC (docs/SPRINT_2.md G1, docs/MOCHI_WORLD.md): one `MochiWorld` (mochi_world, the Mac's
// CompanionWorld in Dart) for the whole app, as the Mac runs one CompanionWorld. It decides what Mochi and Patch do
// (their loops, Claude's moments, petting, the games they play together, naps, celebrations), keeps the friendship and
// achievements, and says when Mochi talks and grows up. The taskbar pet, the desktop pet, the popover and Mochi's
// window all draw it (ui/pet/world_poses.dart).
//
// What goes in:
// - Claude Code's hook events from the bridge (live), and the ones the helper kept while Mochi wasn't running (late:
//   history, never a reaction).
// - The PC's rhythm (W2): how long since the last input, the display, what keeps the screen on, the processor. With
//   "Sleep while my PC rests" on, Mochi naps while the PC rests and wakes with a stretch when you're back.
// - Settings (the Mac's keys), Windows' "Animation effects", and whether Mochi's window or popover is open.
// - This PC's own moments: petting, play and treats (here or from a phone), Ask Mochi, updates.
//
// Celebrations (G2) come only from Claude's real moments, live: a high five for a finished turn, a victory dance for a
// long one (both ends seen live), the tiny trophy for a real build or test result, detective mode after repeated tool
// errors and case closed when that turn ends, graduation for the first milestone. Never for late events (the spool) or
// restored ones (the last hours, rebuilt at launch), and simulated activity (a development tool) doesn't reach Mochi
// here at all, as it doesn't reach the sessions.
//
// What comes out: the poses (drawn by the views), a speech bubble (W11), a note at the top of the scene (achievements,
// a new friendship level, growing up), and sounds and Windows notifications for the world's own moments
// (achievements, petting, growing up) through the app's sounds and toasts, with the Mac's rules. Claude's moments keep
// their notifications, sounds and badge from Reactions (W1, the same Mac rules): the world only animates them, so
// nothing is said twice.
//
// It ticks four times a second (as the Mac and the iPhone do) while the screen can be seen, and not at all while it
// can't (the display off, the PC locked or asleep). Progress and the last three hours of Claude's events are kept in
// `world.json` in Mochi's folder, so Mochi picks up where it was after a restart: event names, session ids, project
// folder names and their hashes, tool names; never paths, prompts or Claude Code's notification text. It's saved at
// the next tick after progress changes, every few minutes and on quit.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_art/mochi_art.dart' show PetRenderer;
import 'package:mochi_wire/mochi_wire.dart' show WireEvent, WireOrigin;
import 'package:mochi_world/mochi_world.dart' as w;

import 'desktop_settings.dart';
import 'notifications.dart' as n;
import 'pc_rhythm.dart';
import 'pet_cues.dart';
import 'sounds.dart';
import 'toasts.dart';

/// Where the world's state is kept (a file in Mochi's folder; memory in tests).
abstract interface class WorldStore {
  Map<String, Object?>? read();
  void write(Map<String, Object?> json);
}

class FileWorldStore implements WorldStore {
  FileWorldStore(this.path);

  final String path;

  @override
  Map<String, Object?>? read() {
    try {
      final json = jsonDecode(File(path).readAsStringSync());
      return json is Map<String, Object?> ? json : null;
    } on Object {
      return null;
    }
  }

  @override
  void write(Map<String, Object?> json) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temporary = File('$path.tmp');
    temporary.writeAsStringSync(jsonEncode(json), flush: true);
    temporary.renameSync(path);
  }
}

class MemoryWorldStore implements WorldStore {
  MemoryWorldStore([this.json]);

  Map<String, Object?>? json;

  @override
  Map<String, Object?>? read() => json;

  @override
  void write(Map<String, Object?> json) => this.json = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
}

class DesktopWorld extends ChangeNotifier {
  DesktopWorld({
    required this.settings,
    required this.rhythm,
    required this.sounds,
    required this.toasts,
    WorldStore? store,
    w.FreshLineWriter? freshLines,
    bool Function()? reducedMotion,
    DateTime Function()? clock,
    double Function()? uptime,
    int? seed,
    w.WorldCalendar calendar = const w.WorldCalendar.local(),
    this.tickInterval = const Duration(milliseconds: 250),
    this.saveInterval = const Duration(minutes: 5),
  }) : store = store ?? MemoryWorldStore(),
       _reducedMotion = reducedMotion ?? (() => false),
       _clock = clock ?? DateTime.now {
    final saved = this.store.read() ?? const <String, Object?>{};
    final savedSeed = saved['seed'];
    final chosen = seed ?? (savedSeed is int && savedSeed != 0 ? savedSeed : null);
    final savedWorld = saved['world'] is Map ? (saved['world']! as Map).cast<String, Object?>() : const <String, Object?>{};
    final progress = savedWorld['progress'] is Map ? w.ProgressState.fromJson(savedWorld['progress']) : null;
    world = w.MochiWorld(
      settings: worldSettings(settings),
      achievements: w.AchievementEngine(state: progress, calendar: calendar, onChange: (_) => _progressChanged()),
      seed: chosen,
      clock: _clock,
      uptime: uptime,
      calendar: calendar,
      effects: _WorldEffects(this),
    );
    world.setSystemReducedMotion(_reducedMotion());
    celebrations = w.Celebrations(
      settings: world.settings,
      milestoneReached: world.progress.unlockedIDs.contains(w.AchievementID.firstMilestone),
    );
    if (savedWorld.isNotEmpty) {
      world.restore(savedWorld, progressToo: false);
      // The classifier knows the restored sessions too (restored events never celebrate).
      final history = savedWorld['history'];
      for (final json in history is List ? history : const []) {
        if (w.eventFromJson(json) case final event?) celebrations.observe(event.withDelivery(w.EventDelivery.restored));
      }
    }
    speech = w.SpeechDirector(world, writer: freshLines);
    _growth(announce: false);
    _signature = _currentSignature();
    _lifeStagesSeen = settings.lifeStages;
    settings.addListener(_settingsChanged);
    rhythm.addListener(_rhythmChanged);
    // The first launch: keep the seed, so Mochi's habits stay its own.
    if (savedSeed != world.seed) save();
  }

  final DesktopSettings settings;
  final PcRhythm rhythm;
  final MochiSounds sounds;
  final ToastService toasts;
  final WorldStore store;
  final bool Function() _reducedMotion;
  final DateTime Function() _clock;

  /// How often the world moves on (the Mac's 4 Hz).
  final Duration tickInterval;

  /// How often progress and recent events are saved besides when progress changes.
  final Duration saveInterval;

  late final w.MochiWorld world;

  /// When Mochi and Patch speak (W11).
  late final w.SpeechDirector speech;

  /// What Mochi or Patch is saying right now (W11), for the bubbles on the taskbar, the desktop and in the room.
  final ValueNotifier<w.SpeechBubble?> speechNow = ValueNotifier(null);

  /// The note at the top of the scene right now (an achievement, a new friendship level, growing up), for the room
  /// and the pet's bubble.
  final ValueNotifier<w.WorldToast?> toastNow = ValueNotifier(null);

  /// Why Claude's real moments celebrate (G2), fed every event in order.
  late final w.Celebrations celebrations;

  /// The last celebration a real, live event earned (and when, on the world's clock).
  ({w.Celebration celebration, double at})? lastCelebration;

  final StreamController<w.Celebration> _celebrated = StreamController.broadcast(sync: true);

  /// Each celebration as a real, live event earns it (for the screen reader, and "Patch only for interesting moments").
  Stream<w.Celebration> get celebrated => _celebrated.stream;

  /// What a celebration is, in plain words, by the names you gave them (the screen reader says it as it plays).
  static String describeCelebration(w.Celebration celebration, {required String pet, required String patch}) =>
      switch (celebration.reason) {
        w.CelebrationReason.turnFinished => '$pet and $patch high-five: Claude finished',
        w.CelebrationReason.longTurn => '$pet and $patch do a victory dance: a long turn is done',
        w.CelebrationReason.buildTestPassed => '$patch holds up a tiny trophy: a real build or test passed',
        w.CelebrationReason.investigating => '$patch puts on his detective hat: a few tool errors in a row',
        w.CelebrationReason.caseClosed => 'Case closed! Claude got past the errors',
        w.CelebrationReason.firstMilestone => '$pet and $patch graduate: your first milestone',
        w.CelebrationReason.milestone => '$pet and $patch celebrate a milestone',
        w.CelebrationReason.commit => '$pet and $patch high-five: a commit',
      };

  Timer? _ticker;
  bool _dirty = false;
  bool _started = false;
  bool _disposed = false;
  DateTime? _lastGrowthCheck;
  DateTime? _lastSave;
  w.LifeStage _stage = w.LifeStage.grownUp;
  Object? _signature;

  /// Where the world is kept (Settings › Privacy), or null in memory.
  String? get file => switch (store) {
    final FileWorldStore file => file.path,
    _ => null,
  };

  /// The world's clock (seconds, monotonic): what the views draw by.
  double now() => world.now;

  /// Mochi is napping (the PC rests, or a long quiet stretch).
  bool get asleep => world.petAsleep || (world.focus?.petNaps ?? false);

  /// Mochi's stage right now (grown-up with "grows up" off).
  w.LifeStage get stage => _stage;

  /// The world is ticking (tests: nothing runs while the screen can't be seen).
  bool get ticking => _ticker != null;

  /// The world is reacting right now (the Mac's roamer freezes for it): a moment together with Patch, or one of Mochi's
  /// moments of at least a reaction's priority (Claude's news, a pet, a game).
  bool get reacting {
    if (world.interaction != null) return true;
    final pet = world.pet;
    return pet.isPlayingOneShot && pet.current.priority >= w.AnimationPriority.reaction;
  }

  /// Seconds the current moment still has to play (0 when nothing's playing).
  double get reactionLeft {
    final t = world.now;
    final playback = world.interaction;
    if (playback != null) return math.max(0, playback.startedAt + playback.duration - t);
    final current = world.pet.current;
    final duration = current.duration;
    return duration == null ? 0 : math.max(0, current.startedAt + duration - t);
  }

  /// Starts ticking (while the screen can be seen).
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _rhythmChanged();
  }

  /// Stops ticking (tests; quitting disposes instead).
  void stop() {
    _started = false;
    _ticker?.cancel();
    _ticker = null;
  }

  // MARK: What goes in

  /// One of Claude Code's hook events: live from the bridge, or [late] from the helper's spool (history only). Simulated
  /// activity never reaches Mochi here, as it never reaches the sessions.
  void ingest(WireEvent event, {bool late = false}) {
    if (event.origin == WireOrigin.simulator) return;
    final wire = event.toJson();
    if (w.EventNormalizer.isPing(wire)) return world.ingestWire(wire);
    final source = world.settings.keepNotificationText ? wire : (Map<String, Object?>.of(wire)..remove('message'));
    final normalized = w.EventNormalizer.normalize(source, receivedAt: _clock(), delivery: late ? w.EventDelivery.late : w.EventDelivery.live);
    if (normalized == null) return;
    final duplicates = world.diagnostics.duplicatesIgnored;
    world.ingest(normalized);
    // A duplicate the world ignored isn't news for the classifier either.
    if (world.diagnostics.duplicatesIgnored == duplicates) {
      final celebration = celebrations.observe(normalized);
      if (celebration != null) {
        lastCelebration = (celebration: celebration, at: world.now);
        if (!_celebrated.isClosed) _celebrated.add(celebration);
      }
    }
    _changed();
  }

  /// The spool was drained at launch: [delivered] came in late, [dropped] were lost.
  void noteSpoolDrained({required int delivered, required int dropped}) => world.noteSpoolDrained(delivered: delivered, dropped: dropped);

  /// Petting, play or a treat on this PC or from a phone (friendship points with the Mac's daily caps).
  void interact(String kind) {
    world.interact(switch (kind) {
      'pet' => w.PetInteraction.pet,
      'play' => w.PetInteraction.play,
      _ => w.PetInteraction.treat,
    });
    _changed();
  }

  /// This PC's own moments (Claude's moments come in as hook events instead, see [ingest]).
  void cue(PetCue cue) {
    switch (cue) {
      case PetCue.pet:
        interact('pet');
        return;
      case PetCue.play:
        interact('play');
        return;
      case PetCue.treat:
        interact('treat');
        return;
      case PetCue.sending:
        world.playPet(w.PetAnimation.nod);
      case PetCue.working:
        world.playPet(w.PetAnimation.lookAround, priority: w.AnimationPriority.ambient);
      case PetCue.replied || PetCue.updated:
        world.playPet(w.PetAnimation.happyBounce);
      case PetCue.failed:
        world.playPet(w.PetAnimation.concerned);
      case PetCue.updateReady:
        world.playPet(w.PetAnimation.wave);
      default:
        return;
    }
    _changed();
  }

  /// Mochi's window or popover is open: no badges or banners from the world, and greetings can be said.
  void setWindowVisible(bool visible) {
    if (world.windowVisible == visible) return;
    world.setWindowVisible(visible);
    speech.windowVisible = visible;
  }

  /// You clicked Patch: a little wave back.
  void pokeCompanion() {
    world.pokeCompanion();
    _changed();
  }

  // MARK: Ticking

  void _rhythmChanged() {
    _feedSystem();
    if (rhythm.unseen) {
      if (_ticker == null) return;
      _ticker?.cancel();
      _ticker = null;
      // Nothing is drawn meanwhile; what was learned is kept.
      if (_dirty) save();
    } else if (_started && !_disposed) {
      _ticker ??= Timer.periodic(tickInterval, (_) => tick());
    }
  }

  SystemActivity? _fed;

  void _feedSystem() {
    final activity = rhythm.activity;
    if (activity == null || identical(activity, _fed)) return;
    _fed = activity;
    world.updateSystem(
      w.SystemActivity(
        idleSeconds: activity.idleSeconds,
        displaysAsleep: activity.displaysAsleep,
        keepsDisplayAwake: activity.keepsDisplayAwake,
        cpuLoad: activity.cpuLoad,
      ),
    );
  }

  /// One step (the timer's; tests and tools step it themselves).
  void tick() {
    if (_disposed) return;
    _feedSystem();
    final reduced = _reducedMotion();
    if (reduced != world.systemReducedMotion) world.setSystemReducedMotion(reduced);
    world.tick();
    speech.tick();
    final date = _clock();
    if (_lastGrowthCheck == null || date.difference(_lastGrowthCheck!) >= const Duration(minutes: 1)) _growth();
    if (_dirty || _lastSave == null || date.difference(_lastSave!) >= saveInterval) save();
    _changed();
  }

  // MARK: Growing up (W12)

  /// The Mac's GrowthController: the stage every minute, "Meet kitten Mochi!" the first time and "Mochi grew up!" once
  /// per stage after that. With [announce] false (at launch) the stage is only drawn; the next check announces.
  void _growth({bool announce = true}) {
    final date = _clock();
    _lastGrowthCheck = date;
    final update = w.Growth.check(
      world.progress,
      date,
      lifeStages: settings.lifeStages,
      seen: settings.lifeStageSeen,
      petName: settings.petName,
    );
    _setStage(update.stage);
    if (!announce) return;
    if (update.seen != settings.lifeStageSeen) settings.lifeStageSeen = update.seen;
    update.moment?.applyTo(world);
  }

  void _setStage(w.LifeStage stage) {
    _stage = stage;
    // The renderers draw Mochi at this age everywhere (the taskbar, the room, the previews).
    PetRenderer.stage = stage;
  }

  // MARK: Settings

  /// The Mac's AppSettings, as this PC's Settings have them. Claude's moments keep their sounds and Windows
  /// notifications in Reactions (W1), so the world plays and posts only its own (achievements, petting, growing up).
  static w.WorldSettings worldSettings(DesktopSettings s) {
    final deliveries = <String, w.CategoryDelivery>{};
    for (final category in w.NotificationCategory.values) {
      final mine = s.delivery(n.NotificationCategory.values.byName(category.name));
      final own = category == w.NotificationCategory.achievement;
      deliveries[category.name] = w.CategoryDelivery(
        animate: mine.animate,
        badge: mine.badge,
        banner: own && mine.banner,
        sound: own && mine.sound,
      );
    }
    return w.WorldSettings(
      pauseReactions: s.pauseReactions,
      quietMode: s.quietMode,
      quietHours: w.QuietHours(enabled: s.quietHours.enabled, startMinute: s.quietHours.startMinute, endMinute: s.quietHours.endMinute),
      petName: s.petName,
      companionName: s.companionName,
      companionVisibility: w.CompanionVisibility.values.byName(s.companionVisibility.name),
      companionLingerMinutes: s.companionLingerMinutes,
      companionSleepAfterMinutes: s.companionSleepAfterMinutes,
      followSystem: s.followSystem,
      restAfterMinutes: s.restAfterMinutes,
      categoryDelivery: deliveries,
      soundEnabled: s.soundEnabled,
      workSounds: s.workSounds,
      speechEnabled: s.speechEnabled,
      chattiness: s.chattiness,
      speechFreshLines: s.speechFreshLines,
      lifeStages: s.lifeStages,
    );
  }

  /// "Grows up" as last seen (a change re-checks the stage at once).
  late bool _lifeStagesSeen;

  void _settingsChanged() {
    final pinned = world.settings.pinnedSessionID;
    world.settings = worldSettings(settings).copyWith(pinnedSessionID: () => pinned);
    celebrations.settings = world.settings;
    // Growing up turned on or off: the stage changes at once.
    if (settings.lifeStages != _lifeStagesSeen) {
      _lifeStagesSeen = settings.lifeStages;
      _growth();
    }
    _changed();
  }

  // MARK: Progress (W13)

  /// Settings › Characters › Reset Progress: friendship and achievements start again.
  void resetProgress() {
    world.achievements.reset();
    _growth(announce: false);
    _changed(force: true);
  }

  /// Progress changed: it's saved at the next tick (or when the screen goes off, or on quit).
  void _progressChanged() => _dirty = true;

  // MARK: Persistence

  /// Writes the seed, the progress and the last hours of Claude's events.
  void save() {
    _dirty = false;
    _lastSave = _clock();
    try {
      final json = world.toJson();
      // Claude Code's notification text stays in memory: what's kept are the events, not what they said.
      final history = json['history'];
      if (history is List) json['history'] = [for (final e in history) e is Map ? (Map<String, Object?>.of(e.cast<String, Object?>())..remove('message')) : e];
      store.write({'v': 1, 'seed': world.seed, 'world': json});
    } on Object catch (error) {
      debugPrint('Mochi: its world could not be saved (${error.runtimeType})');
    }
  }

  // MARK: Telling the views

  /// What the views show changed (a new moment, a bubble, a note, progress, the stage, Patch arriving): listeners hear
  /// about it once, not every tick.
  void _changed({bool force = false}) {
    // By identity: a bubble's id starts again at 1 once the last one was cleared.
    final speaking = world.activeSpeech;
    if (!identical(speaking, speechNow.value)) speechNow.value = speaking;
    final toast = world.activeToast;
    if (toast?.title != toastNow.value?.title || toast?.until != toastNow.value?.until) toastNow.value = toast;
    final signature = _currentSignature();
    if (!force && signature == _signature) return;
    _signature = signature;
    if (!_disposed) notifyListeners();
  }

  Object _currentSignature() {
    final pet = world.pet;
    final companion = world.companion;
    final progress = world.progress;
    return (
      pet.current.token,
      pet.base,
      companion.current.token,
      companion.base,
      world.interaction?.startedAt,
      world.companionPresent,
      asleep,
      world.activeSpeech,
      world.activeToast?.title,
      world.burst?.startedAt,
      (progress.affectionPoints, progress.unlocked.length),
      _stage,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (_started) save();
    _disposed = true;
    _ticker?.cancel();
    settings.removeListener(_settingsChanged);
    rhythm.removeListener(_rhythmChanged);
    unawaited(_celebrated.close());
    speechNow.dispose();
    toastNow.dispose();
    super.dispose();
  }
}

/// The world's side effects, through this PC's sounds and Windows notifications.
class _WorldEffects extends w.WorldEffects {
  _WorldEffects(this.host);

  final DesktopWorld host;

  @override
  void play(w.SoundCue sound) => host.sounds.play(n.SoundCue.values.byName(sound.name));

  @override
  void postBanner(w.BannerContent content, w.NotificationCategory category, String? sessionID) {
    final group = '${category.name}-${sessionID ?? 'none'}';
    final toast = Toast(
      title: content.title,
      body: content.body,
      target: sessionID == null ? ToastTarget.main : ToastTarget.session(sessionID),
      group: group,
    );
    host.toasts.show(toast).ignore();
  }

  @override
  void worldDidReact(w.CompanionEvent event, w.SessionSnapshot? session) => host.speech.react(event, session);

  @override
  void userDidInteract(w.PetInteraction kind) => host.speech.interacted(kind);
}
