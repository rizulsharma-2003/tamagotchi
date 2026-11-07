// Port of Sources/TamagotchiCore/World/CompanionWorld.swift (with WorldModels.swift, SystemActivity.swift and the
// Speech/Focus/Adventure extensions): Claude Code's sessions, both characters, their interactions and everything a
// scene shows. The Mac's menu-bar roamer (MenuBarRoamer) is not part of it: a host with its own roaming (Windows walks
// the taskbar) drives that itself, and the world behaves as the Mac's does with no roam zone (the iPhone's case).

import 'dart:math' as math;

import '../animation/character_animator.dart';
import '../animation/companion_pose_evaluator.dart';
import '../animation/pet_pose_evaluator.dart';
import '../events/events.dart';
import '../events/sessions.dart';
import '../interactions/interaction_library.dart';
import '../interactions/interaction_scheduler.dart';
import '../model/animations.dart';
import '../model/json.dart';
import '../model/poses.dart';
import '../model/random.dart';
import '../progress/progress.dart';
import 'policy.dart';
import 'reactions.dart';
import 'settings.dart';

/// Side effects the world asks the host to perform. Every method has an empty default.
abstract class WorldEffects {
  void play(SoundCue sound) {}
  void postBanner(BannerContent content, NotificationCategory category, String? sessionID) {}

  /// A live event went through the reaction pipeline (for speech and similar flourishes).
  void worldDidReact(CompanionEvent event, SessionSnapshot? session) {}

  /// The user petted, played with or fed the pet.
  void userDidInteract(PetInteraction kind) {}
}

/// How the computer is being used, sampled every few seconds (Swift `SystemActivity`): how long since the last input
/// (the duration only), whether the displays are asleep, whether something keeps them on, and how busy the processor
/// is.
class SystemActivity {
  const SystemActivity({required this.idleSeconds, this.displaysAsleep = false, this.keepsDisplayAwake = false, this.cpuLoad = 0});

  final double idleSeconds;
  final bool displaysAsleep;
  final bool keepsDisplayAwake;

  /// 0…1 across all cores, smoothed over about a minute.
  final double cpuLoad;

  /// Above this the computer counts as busy, even with nobody at it (a build, an export).
  static const double busyLoad = 0.6;

  /// Someone is at the computer right now.
  bool get userActive => !displaysAsleep && idleSeconds < 30;

  /// The computer is resting: its displays are asleep, or nobody has touched it for `restAfter` seconds while nothing
  /// keeps the screen on and the processor is calm.
  bool isResting(double restAfter) => displaysAsleep || (idleSeconds >= restAfter && !keepsDisplayAwake && cpuLoad < busyLoad);
}

enum AttentionBadgeKind { needsYou, toolError, apiError, buildFailed }

class AttentionBadge {
  const AttentionBadge({required this.kind, required this.level, this.sessionID, required this.summary, required this.at});
  final AttentionBadgeKind kind;
  final AttentionLevel level;
  final String? sessionID;
  final String summary;
  final DateTime at;
}

class ResultCard {
  const ResultCard({
    required this.id,
    required this.sessionID,
    required this.projectName,
    this.projectPath,
    required this.completedAt,
    required this.statusLine,
    this.buildTest,
    this.observedTurnDuration,
    required this.isSimulated,
  });

  final String id;
  final String sessionID;
  final String projectName;
  final String? projectPath;
  final DateTime completedAt;
  final String statusLine;
  final BuildTestOutcome? buildTest;

  /// Only set when both ends of the turn were observed live.
  final double? observedTurnDuration;
  final bool isSimulated;
}

class SceneCaption {
  const SceneCaption({required this.text, required this.until, required this.isSimulated});
  final String text;
  final double until;
  final bool isSimulated;
}

class CelebrationBurst {
  const CelebrationBurst({required this.startedAt, required this.big});
  final double startedAt;
  final bool big;
}

class MissedEventsNotice {
  const MissedEventsNotice({required this.delivered, required this.dropped, required this.at});
  final int delivered;
  final int dropped;
  final DateTime at;
}

class WorldToast {
  const WorldToast({required this.title, required this.detail, required this.until});
  final String title;
  final String detail;
  final double until;
}

class WorldDiagnostics {
  int duplicatesIgnored = 0;
  int unknownEvents = 0;
  String? lastUnknownName;
  int lateEvents = 0;
  int simulatedEvents = 0;
}

enum SpeechSpeaker { pet, companion }

/// A short line one of the characters is saying right now.
class SpeechBubble {
  const SpeechBubble({required this.id, required this.text, required this.speaker, required this.startedAt, required this.duration});
  final int id;
  final String text;
  final SpeechSpeaker speaker;

  /// World time (uptime) the bubble appeared.
  final double startedAt;
  final double duration;

  bool isVisible(double time) => time >= startedAt && time < startedAt + duration;
}

enum FocusPhase { focus, shortBreak, longBreak }

/// The focus buddy's current phase (Swift `FocusStatus`). The world reads [phase] and [petNaps]; `FocusTimer.status`
/// fills in the rest for a timer display.
class FocusStatus {
  const FocusStatus({required this.phase, required this.petNaps, this.startedAt, this.duration = 0, this.cycle = 1});
  final FocusPhase phase;

  /// Mochi naps through this phase.
  final bool petNaps;

  /// When the phase began (null when a host reports only the phase).
  final DateTime? startedAt;

  /// The phase's length in seconds.
  final double duration;

  /// 1-based focus block number.
  final int cycle;

  /// Seconds left at [date] (the whole [duration] without a [startedAt]).
  double remaining(DateTime date) {
    final start = startedAt;
    if (start == null) return duration;
    return math.max(0, duration - date.difference(start).inMicroseconds / 1e6);
  }

  /// 0…1 through the phase at [date].
  double progress(DateTime date) {
    final start = startedAt;
    if (duration <= 0) return 1;
    if (start == null) return 0;
    return math.min(1, math.max(0, date.difference(start).inMicroseconds / 1e6 / duration));
  }

  @override
  bool operator ==(Object other) =>
      other is FocusStatus &&
      other.phase == phase &&
      other.petNaps == petNaps &&
      other.startedAt == startedAt &&
      other.duration == duration &&
      other.cycle == cycle;

  @override
  int get hashCode => Object.hash(phase, petNaps, startedAt, duration, cycle);
}

/// The scene's overall mood (Swift `MenuBarMood`): for a tray icon, a taskbar badge or a widget.
enum WorldMood { content, sleeping, watching, waiting, concerned, celebrating, offline, paused }

class WorldStatus {
  const WorldStatus({
    required this.mood,
    required this.companionVisible,
    required this.companionWorking,
    this.badge,
    this.celebrationStartedAt,
    required this.simulated,
  });

  final WorldMood mood;
  final bool companionVisible;
  final bool companionWorking;
  final AttentionLevel? badge;
  final double? celebrationStartedAt;
  final bool simulated;
}

/// What became of a request to start an interaction.
enum InteractionRequest { started, deferred, refused }

/// Both characters and the scene props at one moment (what the Mac's SceneRenderer draws).
class WorldFrame {
  WorldFrame({
    required this.pet,
    required this.companion,
    required this.props,
    required this.companionVisible,
    this.companionVelocity = 0,
    this.subagents = 0,
    this.petAway = false,
    this.reducedMotion = false,
  });

  final PetPose pet;
  final CompanionPose companion;
  final List<SceneProp> props;

  /// Patch is here (draw him; otherwise the desk is empty).
  final bool companionVisible;

  /// Patch's horizontal speed in path units per second while an interaction moves him.
  final double companionVelocity;
  final int subagents;

  /// Mochi is out on a desktop adventure.
  final bool petAway;
  final bool reducedMotion;
}

/// Mochi's world (Swift `CompanionWorld`): Claude Code's sessions, Mochi and Patch, their interactions and everything a
/// scene shows. Deterministic for a [seed] and the injected [clock] (wall time) and [uptime] (monotonic seconds).
///
/// Drive it with [tick] a few times a second (the Mac and the iPhone use 4 Hz), feed it Claude's hook events with
/// [ingestWire] and the user's petting, play and treats with [interact], and draw [frame].
class MochiWorld {
  MochiWorld({
    WorldSettings settings = const WorldSettings(),
    AchievementEngine? achievements,
    int? seed,
    DateTime Function()? clock,
    double Function()? uptime,
    this.calendar = const WorldCalendar.local(),
    this.effects,
    this.isKnownEvent,
    this.onRecord,
    String Function()? newID,
  }) : _settings = settings,
       achievements = achievements ?? AchievementEngine(calendar: calendar),
       seed = seed ?? _randomSeed(),
       _clock = clock ?? DateTime.now,
       _uptime = uptime ?? _stopwatchUptime(),
       _newID = newID ?? _randomID {
    final now = _uptime();
    pet = CharacterAnimator<PetAnimation>(base: PetAnimation.idle, at: now);
    companion = CharacterAnimator<CompanionAnimation>(base: CompanionAnimation.absent, at: now);
    _scheduler = InteractionScheduler(seed: this.seed, now: now);
    final date = _clock();
    _lastUserInteractionAt = date;
    _lastLiveActivityAt = date;
    if (settings.companionVisibility == CompanionVisibility.always) {
      companionPresent = true;
      companion.setBase(CompanionAnimation.idleAtDesk, at: now);
    }
  }

  static int _randomSeed() {
    final r = math.Random.secure();
    final seed = (r.nextInt(1 << 32) << 32) | r.nextInt(1 << 32);
    return seed == 0 ? 1 : seed;
  }

  static double Function() _stopwatchUptime() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds / 1e6;
  }

  static String _randomID() {
    final r = math.Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  // MARK: Dependencies

  final AchievementEngine achievements;
  WorldEffects? effects;
  final WorldCalendar calendar;

  /// The host's own history (the Mac's journal): an event it already has is a duplicate.
  final bool Function(String id)? isKnownEvent;

  /// Called for every real, non-restored event, where the Mac appends to its journal (keep it for history, the daily
  /// recap and [restore]).
  final void Function(CompanionEvent event)? onRecord;

  final DateTime Function() _clock;
  final double Function() _uptime;
  final String Function() _newID;
  late InteractionScheduler _scheduler;
  final List<String> _recentIDs = [];
  final Set<String> _recentIDSet = {};
  final BannerCoalescer _bannerCoalescer = BannerCoalescer();
  final Map<SoundCue, double> _lastSoundAt = {};
  double _lastPruneAt = 0;
  late DateTime _lastUserInteractionAt;
  late DateTime _lastLiveActivityAt;
  DateTime? _lastSessionEndedAt;
  bool _departing = false;

  /// The seed (a UInt64's bit pattern) behind every ambient choice and the characters' blinks and glances.
  final int seed;

  // MARK: State

  WorldSettings _settings;
  WorldSettings get settings => _settings;

  /// Changes the settings (the world reacts as the Mac's does when its settings store changes).
  set settings(WorldSettings value) {
    final old = _settings;
    _settings = value;
    _settingsChanged(old);
  }

  final SessionRegistry registry = SessionRegistry();
  late final CharacterAnimator<PetAnimation> pet;
  late final CharacterAnimator<CompanionAnimation> companion;
  InteractionPlayback? interaction;
  bool companionPresent = false;
  bool petAsleep = false;

  /// The computer is resting (see [updateSystem]); the pet sleeps through it unless Claude is working.
  bool systemResting = false;
  SystemActivity? _system;
  final List<CompanionEvent> timeline = [];

  /// Real events of the last few hours, kept for [toJson] (the Mac's journal, which [restore] replays).
  final List<CompanionEvent> _history = [];

  /// The bridge to Claude Code is broken (Patch sits at a dark screen with a plug).
  String? bridgeError;
  DateTime? lastEventAt;
  DateTime? lastPingAt;
  AttentionBadge? attention;
  final Map<String, ResultCard> resultCards = {};
  SceneCaption? caption;
  CelebrationBurst? burst;
  WorldToast? toast;
  MissedEventsNotice? missed;
  final WorldDiagnostics diagnostics = WorldDiagnostics();

  /// The user is looking at Mochi's window (the Mac's popover): no banners or badges then.
  bool windowVisible = false;
  bool systemReducedMotion = false;

  /// Mochi is out exploring the desktop, away from home.
  bool adventureActive = false;

  /// The focus buddy's current phase, while a focus session runs.
  FocusStatus? focus;

  /// What one of the characters is saying right now.
  SpeechBubble? speech;

  ProgressState get progress => achievements.state;

  // MARK: Derived state

  double get now => _uptime();
  DateTime get date => _clock();

  bool get reducedMotion => switch (_settings.reducedMotion) {
    ReducedMotionPreference.system => systemReducedMotion,
    ReducedMotionPreference.always => true,
    ReducedMotionPreference.never => false,
  };

  List<SessionSnapshot> get sessions => registry.all;

  SessionSnapshot? get primarySession => registry.primarySession(pinned: _settings.pinnedSessionID, now: _clock());

  List<SessionSnapshot> get liveSessions {
    final date = _clock();
    return registry.all.where((s) => s.phase != SessionPhase.ended || _seconds(date, s.endedAt ?? s.lastEventAt) < 600).toList();
  }

  ResultCard? get latestResult {
    ResultCard? latest;
    for (final card in resultCards.values) {
      if (latest == null || latest.completedAt.isBefore(card.completedAt)) latest = card;
    }
    return latest;
  }

  SceneCaption? get activeCaption => caption != null && caption!.until > _uptime() ? caption : null;

  WorldToast? get activeToast => toast != null && toast!.until > _uptime() ? toast : null;

  bool get _companionAvailable => companionPresent && companion.current.animation != CompanionAnimation.absent && !_departing;

  CompanionDetail get companionDetail {
    final session = primarySession;
    return CompanionDetail(waitingFor: session?.waitingFor, subagents: session?.activeSubagents.length ?? 0);
  }

  /// The scene's mood (the Mac's menu-bar status).
  WorldStatus get status {
    final session = primarySession;
    final date = _clock();
    final celebrating = burst != null && _uptime() - burst!.startedAt < 2.5;
    var mood = WorldMood.content;
    if (_settings.pauseReactions) {
      mood = WorldMood.paused;
    } else if (bridgeError != null) {
      mood = WorldMood.offline;
    } else if (celebrating) {
      mood = WorldMood.celebrating;
    } else if (session != null && !session.isStale(date)) {
      switch (session.phase) {
        case SessionPhase.waitingForUser:
          mood = WorldMood.waiting;
        case SessionPhase.promptSubmitted || SessionPhase.thinking || SessionPhase.runningTool:
          final failure = session.lastFailureAt;
          mood = failure != null && _seconds(date, failure) < 20 ? WorldMood.concerned : WorldMood.watching;
        case SessionPhase.turnFailed:
          mood = WorldMood.concerned;
        default:
          mood = petAsleep ? WorldMood.sleeping : WorldMood.content;
      }
    } else if (petAsleep) {
      mood = WorldMood.sleeping;
    }
    final working = session != null && session.phase.isWorking && !session.isStale(date);
    return WorldStatus(
      mood: mood,
      companionVisible: companionPresent,
      companionWorking: working,
      badge: attention?.level,
      celebrationStartedAt: celebrating ? burst?.startedAt : null,
      simulated: session?.isSimulated ?? false,
    );
  }

  static double _seconds(DateTime later, DateTime earlier) => later.difference(earlier).inMicroseconds / 1e6;

  // MARK: Event intake

  /// Entry point for Claude Code's hook events: a wire event's JSON (mochi_wire's `WireEvent.toJson()`).
  void ingestWire(Map<String, Object?> wire, {EventDelivery delivery = EventDelivery.live}) {
    if (EventNormalizer.isPing(wire)) {
      lastPingAt = _clock();
      return;
    }
    final source = _settings.keepNotificationText ? wire : (Map<String, Object?>.of(wire)..remove('message'));
    final event = EventNormalizer.normalize(source, receivedAt: _clock(), delivery: delivery);
    if (event != null) ingest(event);
  }

  void ingest(CompanionEvent event) {
    if (!_rememberID(event.id)) {
      diagnostics.duplicatesIgnored += 1;
      return;
    }
    if (event.isSimulated) diagnostics.simulatedEvents += 1;
    if (event.delivery == EventDelivery.late) diagnostics.lateEvents += 1;
    final date = _clock();

    if (event.kind == EventKind.unknown) {
      diagnostics.unknownEvents += 1;
      diagnostics.lastUnknownName = event.rawName;
      _appendTimeline(event);
      return;
    }
    if (!event.isSimulated && event.delivery != EventDelivery.restored) {
      onRecord?.call(event);
      _keep(event, date);
      // Only live events say anything about the connection right now.
      if (event.origin == EventOrigin.claudeHook && event.delivery == EventDelivery.live) lastEventAt = date;
    }

    final previousPrimary = primarySession?.id;
    final transition = registry.apply(event);
    final session = transition == null ? null : registry[transition.sessionID];
    _appendTimeline(event);

    var unlocked = const <AchievementID>[];
    if (event.delivery == EventDelivery.live) {
      unlocked = achievements.record(event, transition: transition, session: session);
      _lastLiveActivityAt = date;
      _scheduler.postpone(now: _uptime());
    }
    if (event.kind == EventKind.sessionEnded && !registry.hasLiveSessions(date)) _lastSessionEndedAt = date;

    _updateAttention(event, session);
    if (event.kind == EventKind.turnCompleted && event.delivery == EventDelivery.live && session != null) {
      _recordResult(event, session, transition);
    }

    if (event.delivery == EventDelivery.live) {
      if (petAsleep && !_settings.pauseReactions && session?.id == primarySession?.id) {
        petAsleep = false;
        pet.play(PetAnimation.wakeUp, priority: AnimationPriority.reaction, at: _uptime(), ignoreCooldown: true);
      }
      final primaryID = primarySession?.id;
      final context = MapperContext(
        companionPresent: companionPresent || _settings.companionVisibility != CompanionVisibility.never,
        isPrimary: session == null || session.id == primaryID || previousPrimary == null,
        multipleLiveSessions: registry.sessions.values.where((s) => s.phase != SessionPhase.ended).length > 1,
        celebrateCommandResults: _settings.celebrateCommandResults,
        longTurnThreshold: (_settings.longTurnMinutes * 60).toDouble(),
        firstMilestone: unlocked.contains(AchievementID.firstMilestone),
      );
      // Presence first, so a session start becomes a proper arrival.
      _updatePresence();
      final reaction = EventToAnimationMapper.reaction(event, transition: transition, session: session, context: context);
      if (reaction != null) _perform(reaction, event, session);
      if (!_settings.pauseReactions) effects?.worldDidReact(event, session);
      for (final id in unlocked) {
        _announce(id);
      }
    }
    _updateBases();
  }

  /// Late events are history: shown and stored, never animated.
  void noteSpoolDrained({required int delivered, required int dropped}) {
    if (delivered <= 0 && dropped <= 0) return;
    missed = MissedEventsNotice(delivered: delivered, dropped: dropped, at: _clock());
  }

  void dismissMissedNotice() => missed = null;

  /// Rebuilds session state from recent history after a restart (Swift `restoreFromJournal`). No reactions.
  void restoreHistory(Iterable<CompanionEvent> history, {double window = 3 * 3600}) {
    final date = _clock();
    final since = date.subtract(Duration(microseconds: (window * 1e6).round()));
    final recent = history.where((e) => !e.timestamp.isBefore(since)).toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final original in recent) {
      final event = original.withDelivery(EventDelivery.restored);
      // These ids are in the history by definition; only skip ones already applied.
      if (_recentIDSet.contains(event.id)) continue;
      _markSeen(event.id);
      registry.apply(event);
    }
    _history
      ..clear()
      ..addAll(recent.where((e) => !e.isSimulated));
    timeline
      ..clear()
      ..addAll(recent.skip(math.max(0, recent.length - 40)).map((e) => e.withDelivery(EventDelivery.restored)));
    registry.prune(date);
    _updatePresence(animated: false);
    _updateBases();
  }

  // MARK: Reactions

  void _perform(Reaction reaction, CompanionEvent event, SessionSnapshot? session) {
    final date = _clock();
    final decision = NotificationPolicy.decide(
      reaction.category,
      settings: _settings,
      context: NotificationContext(
        now: date,
        popoverVisible: windowVisible,
        reducedMotion: reducedMotion,
        isSimulated: event.isSimulated,
        isLate: event.delivery != EventDelivery.live,
        focusing: focus?.phase == FocusPhase.focus,
      ),
      calendar: calendar,
    );
    final t = _uptime();
    if (decision.animate) {
      var started = false;
      if (reaction.interaction case final id?) {
        final request = requestInteraction(
          id,
          priority: AnimationPriority.max(reaction.priority, AnimationPriority.reaction),
          variant: unsignedMod(_scheduler.rng.state, 1000),
          label: session?.displayName,
          fallback: reaction.pet,
        );
        started = request != InteractionRequest.refused;
      }
      if (!started) {
        if (reaction.pet case final animation?) pet.play(animation, priority: reaction.priority, at: t);
        if (reaction.companion case final animation?
            when companionPresent && !_departing && companion.current.animation != CompanionAnimation.absent) {
          companion.play(animation, priority: reaction.priority, at: t);
        }
      }
      if (reaction.burst) burst = CelebrationBurst(startedAt: t, big: reaction.interaction != InteractionID.highFive);
      if (reaction.caption case final text?) caption = SceneCaption(text: text, until: t + 6, isSimulated: event.isSimulated);
    }
    if (decision.sound && reaction.sound != null) _playSound(reaction.sound!);
    if (decision.badge && reaction.attention != null) {
      final level = reaction.attention!;
      final kind = switch (event.kind) {
        EventKind.permissionRequested || EventKind.attentionNeeded => AttentionBadgeKind.needsYou,
        EventKind.turnFailed => AttentionBadgeKind.apiError,
        EventKind.report => AttentionBadgeKind.buildFailed,
        _ => event.buildTestOutcome != null ? AttentionBadgeKind.buildFailed : AttentionBadgeKind.toolError,
      };
      final current = attention;
      if (current == null || level >= current.level || current.kind == kind) {
        attention = AttentionBadge(kind: kind, level: level, sessionID: session?.id, summary: event.summary, at: date);
      }
    }
    if (decision.banner && reaction.banner != null) {
      final key = '${reaction.category.name}-${session?.id ?? 'none'}';
      final suppressed = _bannerCoalescer.register(key, date);
      if (suppressed != null) {
        var content = reaction.banner!;
        if (suppressed > 0) content = content.withBody('${content.body} (+$suppressed similar)');
        effects?.postBanner(content, reaction.category, session?.id);
      }
    }
  }

  void _updateAttention(CompanionEvent event, SessionSnapshot? session) {
    final current = attention;
    if (current == null) return;
    // Badges for sessions that are gone go away with them.
    if (current.sessionID != null && registry[current.sessionID!] == null) {
      attention = null;
      return;
    }
    if (!(current.sessionID == null || current.sessionID == session?.id)) return;
    switch (current.kind) {
      case AttentionBadgeKind.needsYou:
        if (session?.phase != SessionPhase.waitingForUser) attention = null;
      case AttentionBadgeKind.toolError || AttentionBadgeKind.buildFailed:
        if (const {EventKind.turnCompleted, EventKind.promptSubmitted, EventKind.sessionEnded}.contains(event.kind)) attention = null;
      case AttentionBadgeKind.apiError:
        if (const {EventKind.promptSubmitted, EventKind.sessionEnded}.contains(event.kind)) attention = null;
    }
  }

  void _recordResult(CompanionEvent event, SessionSnapshot session, SessionTransition? transition) {
    final duration = transition?.turnDurationTrusted == true ? transition?.turnDuration : null;
    resultCards[session.id] = ResultCard(
      id: event.id,
      sessionID: session.id,
      projectName: session.displayName,
      projectPath: session.project?.path,
      completedAt: event.timestamp,
      statusLine: 'Claude finished responding',
      buildTest: session.buildTestThisTurn,
      observedTurnDuration: duration,
      isSimulated: event.isSimulated,
    );
    if (resultCards.length > 12) {
      ResultCard? oldest;
      for (final card in resultCards.values) {
        if (oldest == null || card.completedAt.isBefore(oldest.completedAt)) oldest = card;
      }
      resultCards.remove(oldest!.sessionID);
    }
  }

  void _announce(AchievementID id) {
    final t = _uptime();
    final reward = id.reward == null ? '' : ' · unlocked ${id.reward!.title}';
    toast = WorldToast(title: 'Achievement: ${id.title}', detail: id.criteria + reward, until: t + 7);
    final decision = NotificationPolicy.decide(
      NotificationCategory.achievement,
      settings: _settings,
      context: NotificationContext(now: _clock(), popoverVisible: windowVisible, focusing: focus?.phase == FocusPhase.focus),
      calendar: calendar,
    );
    if (decision.animate && interaction == null) pet.play(PetAnimation.excitedJump, priority: AnimationPriority.reaction, at: t);
    if (decision.sound) _playSound(SoundCue.achievement);
    if (decision.banner) {
      effects?.postBanner(
        BannerContent(title: 'Achievement unlocked: ${id.title}', body: id.criteria),
        NotificationCategory.achievement,
        null,
      );
    }
  }

  void _playSound(SoundCue cue) {
    final t = _uptime();
    final minimumGap = cue == SoundCue.keyboard ? 4.0 : 1.5;
    final last = _lastSoundAt[cue];
    if (last != null && t - last < minimumGap) return;
    _lastSoundAt[cue] = t;
    effects?.play(cue);
  }

  // MARK: Interactions

  /// Starts an interaction. Returns true when it started.
  bool startInteraction(InteractionID id, {AnimationPriority priority = AnimationPriority.interaction, int variant = 0, String? label}) =>
      requestInteraction(id, priority: priority, variant: variant, label: label) != InteractionRequest.refused;

  /// Like [startInteraction], saying whether it started. (On the Mac an interaction can also wait for Mochi to run
  /// home along the menu bar; without a roamer it starts at once or is refused.) `fallback` is kept for parity.
  InteractionRequest requestInteraction(
    InteractionID id, {
    AnimationPriority priority = AnimationPriority.interaction,
    int variant = 0,
    String? label,
    PetAnimation? fallback,
  }) {
    final script = InteractionLibrary.script(id, variant: variant);
    if (script.requiresCompanion && !_companionAvailable) return InteractionRequest.refused;
    // Mochi is out on a desktop adventure: nobody beside Patch.
    if (script.requiresCompanion && adventureActive) return InteractionRequest.refused;
    return _beginInteraction(id, priority: priority, variant: variant, label: label)
        ? InteractionRequest.started
        : InteractionRequest.refused;
  }

  bool _beginInteraction(InteractionID id, {required AnimationPriority priority, required int variant, String? label}) {
    final script = InteractionLibrary.script(id, variant: variant);
    if (script.requiresCompanion && !_companionAvailable) return false;
    final t = _uptime();
    final playback = InteractionPlayback(
      id: id,
      startedAt: t,
      variant: variant,
      companionLoop: _companionLoopForScripts(),
      sessionLabel: label,
    );
    final petResult = pet.play(
      PetAnimation.scripted,
      priority: priority,
      at: t,
      duration: script.duration,
      scriptID: id.name,
      ignoreCooldown: true,
    );
    if (petResult is! PlayStarted) return false;
    final companionResult = companion.play(
      CompanionAnimation.scripted,
      priority: priority,
      at: t,
      duration: script.duration,
      scriptID: id.name,
      ignoreCooldown: true,
    );
    if (companionResult is! PlayStarted) {
      pet.cancel(petResult.token, at: t);
      return false;
    }
    playback.petToken = petResult.token;
    playback.companionToken = companionResult.token;
    interaction = playback;
    if (petAsleep) petAsleep = false;
    _scheduler.noteTriggered(id, now: t);
    return true;
  }

  CompanionAnimation _companionLoopForScripts() {
    final base = companion.base;
    return base == CompanionAnimation.absent || base == CompanionAnimation.sleep ? CompanionAnimation.idleAtDesk : base;
  }

  // MARK: User interactions

  /// The user petted, played with or fed Mochi.
  void interact(PetInteraction kind) {
    final date = _clock();
    _lastUserInteractionAt = date;
    final t = _uptime();
    _scheduler.postpone(now: t, by: 40);
    final result = achievements.recordInteraction(kind, date);
    final wasAsleep = petAsleep;
    petAsleep = false;
    final animation = switch (kind) {
      PetInteraction.pet => wasAsleep ? PetAnimation.wakeUp : PetAnimation.petted,
      PetInteraction.play => PetAnimation.play,
      PetInteraction.treat => PetAnimation.treat,
    };
    if (!_settings.pauseReactions) {
      pet.play(animation, priority: AnimationPriority.user, at: t, ignoreCooldown: true);
      if (companionPresent &&
          kind != PetInteraction.pet &&
          companion.current.animation.isLoop &&
          companion.base != CompanionAnimation.waiting) {
        companion.play(CompanionAnimation.nod, priority: AnimationPriority.ambient, at: t + 0.01);
      }
      if (_settings.soundEnabled && !NotificationPolicy.isQuiet(_settings, date, calendar: calendar)) {
        _playSound(kind == PetInteraction.pet ? SoundCue.pop : SoundCue.greeting);
      }
      effects?.userDidInteract(kind);
    }
    if (result.levelUp) {
      toast = WorldToast(
        title: 'Friendship level ${progress.friendshipLevel}',
        detail: '${_settings.petName} is happy you\'re here.',
        until: t + 6,
      );
    }
    for (final id in result.unlocked) {
      _announce(id);
    }
    _updateBases();
  }

  /// A milestone the user marks by hand. Recorded as a real, user-originated event.
  void markMilestone({String? label}) {
    final date = _clock();
    final primary = primarySession;
    final cleaned = _clean(label, 60);
    final wire = <String, Object?>{
      'v': 1,
      'id': 'manual-${_newID()}',
      'ts': date.microsecondsSinceEpoch / 1e6,
      'origin': 'report',
      'event': 'Report',
      'report': {'kind': 'milestone', 'status': 'reached', 'label': cleaned ?? 'Marked by you'},
      'session': ?(primary != null && primary.phase != SessionPhase.ended && !primary.isSimulated ? primary.id : null),
      'project': ?primary?.project?.displayName,
      'projectKey': ?primary?.project?.key,
    };
    _lastUserInteractionAt = date;
    ingestWire(wire);
  }

  /// Swift `WireText.clean`: whitespace runs become one space, control characters go, at most [maxLength] characters.
  static String? _clean(String? value, int maxLength) {
    if (value == null) return null;
    final buffer = StringBuffer();
    var lastWasSpace = false;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      if (char.trim().isEmpty) {
        if (!lastWasSpace && buffer.isNotEmpty) buffer.write(' ');
        lastWasSpace = true;
        continue;
      }
      if (rune < 0x20 || (rune >= 0x7F && rune < 0xA0)) continue;
      buffer.write(char);
      lastWasSpace = false;
    }
    var text = buffer.toString().trim();
    if (text.isEmpty) return null;
    if (text.runes.length > maxLength) text = String.fromCharCodes(text.runes.take(maxLength)).trim();
    return text;
  }

  /// The user clicked the companion: a small, purely cosmetic hello.
  void pokeCompanion() {
    if (!companionPresent || _departing || _settings.pauseReactions || interaction != null) return;
    final t = _uptime();
    _lastUserInteractionAt = _clock();
    _scheduler.postpone(now: t, by: 30);
    switch (companion.base) {
      case CompanionAnimation.sleep:
        companion.play(CompanionAnimation.wakeUp, priority: AnimationPriority.user, at: t, ignoreCooldown: true);
      case CompanionAnimation.waiting:
        return;
      default:
        companion.play(
          companion.base.isWorking ? CompanionAnimation.nod : CompanionAnimation.greet,
          priority: AnimationPriority.user,
          at: t,
          ignoreCooldown: true,
        );
    }
  }

  void acknowledgeAttention() {
    if (attention?.kind != AttentionBadgeKind.needsYou) attention = null;
  }

  void dismissResult(String sessionID) => resultCards.remove(sessionID);

  /// The user opened or closed Mochi's window (the Mac's popover).
  void setWindowVisible(bool visible) {
    windowVisible = visible;
    if (visible) acknowledgeAttention();
  }

  void setSystemReducedMotion(bool value) => systemReducedMotion = value;

  /// Mochi left home to explore the desktop (true) or is back (false).
  void setAdventureActive(bool active) => adventureActive = active;

  /// The focus buddy reports its phase (null when no focus session runs).
  void updateFocus(FocusStatus? status) => focus = status;

  // MARK: Speech

  /// Shows a short speech bubble for one of the characters.
  void say(String text, {SpeechSpeaker speaker = SpeechSpeaker.pet, double duration = 4.5}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !_settings.speechEnabled) return;
    speech = SpeechBubble(id: (speech?.id ?? 0) + 1, text: trimmed, speaker: speaker, startedAt: _uptime(), duration: duration);
  }

  /// Removes the bubble once it has had its time (only that bubble, not a newer one).
  void clearSpeech(int id) {
    if (speech?.id == id) speech = null;
  }

  /// The bubble that should be on screen now, if any.
  SpeechBubble? get activeSpeech {
    final bubble = speech;
    if (bubble == null || !bubble.isVisible(_uptime())) return null;
    return bubble;
  }

  // MARK: Connection

  /// The bridge to Claude Code broke (an error) or works again (null).
  void setBridgeError(String? error) {
    bridgeError = error;
    _updateBases();
  }

  // MARK: Maintenance

  void clearHistory() {
    timeline.removeWhere((e) => !e.isSimulated);
    resultCards.removeWhere((_, card) => !card.isSimulated);
  }

  void clearSimulated() {
    registry.removeWhere((s) => s.isSimulated);
    timeline.removeWhere((e) => e.isSimulated);
    resultCards.removeWhere((_, card) => card.isSimulated);
    if (attention?.sessionID case final id? when registry[id] == null) attention = null;
    if (_settings.pinnedSessionID case final pinned? when registry[pinned] == null) {
      _settings = _settings.copyWith(pinnedSessionID: () => null);
    }
    _updatePresence();
    _updateBases();
  }

  void pin(String? sessionID) {
    _settings = _settings.copyWith(pinnedSessionID: () => sessionID);
    _updateBases();
  }

  /// Development helpers (the Mac's simulator panel).
  void previewPet(PetAnimation animation) {
    petAsleep = false;
    pet.play(animation, priority: AnimationPriority.critical, at: _uptime(), ignoreCooldown: true);
  }

  void previewCompanion(CompanionAnimation animation) {
    if (!companionPresent) return;
    companion.play(animation, priority: AnimationPriority.critical, at: _uptime(), ignoreCooldown: true);
  }

  // MARK: Feature hooks

  /// Plays a one-shot for the pet on behalf of a feature (focus breaks, games, seasons, adventures).
  bool playPet(PetAnimation animation, {AnimationPriority priority = AnimationPriority.user}) {
    if (_settings.pauseReactions) return false;
    if (animation != PetAnimation.sleep) petAsleep = false;
    pet.play(animation, priority: priority, at: _uptime(), ignoreCooldown: true);
    return true;
  }

  /// Plays a one-shot for the companion on behalf of a feature, if it is here.
  bool playCompanion(CompanionAnimation animation, {AnimationPriority priority = AnimationPriority.user}) {
    if (!companionPresent || _departing || _settings.pauseReactions) return false;
    companion.play(animation, priority: priority, at: _uptime(), ignoreCooldown: true);
    return true;
  }

  /// A short note at the top of the scene.
  void showToast({required String title, required String detail, double seconds = 6}) {
    toast = WorldToast(title: title, detail: detail, until: _uptime() + seconds);
  }

  // MARK: Ticking

  /// Advances animations, interactions and ambient behaviour. Call a few times a second.
  void tick() {
    final t = _uptime();
    final date = _clock();

    final completion = companion.update(t);
    if (completion != null && completion.animation == CompanionAnimation.depart) {
      companionPresent = false;
      _departing = false;
      companion.setBase(CompanionAnimation.absent, at: t);
    } else if (_departing && companion.current.animation != CompanionAnimation.depart) {
      // Something interrupted the departure: finish leaving rather than lingering.
      companion.play(CompanionAnimation.depart, priority: AnimationPriority.critical, at: t, ignoreCooldown: true);
    }
    pet.update(t);

    final playback = interaction;
    if (playback != null) {
      final petIntact = pet.current.token == playback.petToken;
      final companionIntact = companion.current.token == playback.companionToken;
      if (!petIntact || !companionIntact) {
        // One side was interrupted by something more important: end cleanly.
        if (petIntact && playback.petToken != null) pet.cancel(playback.petToken!, at: t);
        if (companionIntact && playback.companionToken != null) companion.cancel(playback.companionToken!, at: t);
        interaction = null;
      } else if (playback.isFinished(t)) {
        interaction = null;
      }
    }

    if (caption != null && caption!.until <= t) caption = null;
    if (toast != null && toast!.until <= t) toast = null;
    if (burst != null && t - burst!.startedAt > 4) burst = null;

    if (t - _lastPruneAt > 60) {
      _lastPruneAt = t;
      registry.prune(date);
      if (_settings.pinnedSessionID case final pinned? when registry[pinned] == null) {
        _settings = _settings.copyWith(pinnedSessionID: () => null);
      }
      resultCards.removeWhere((_, card) => !(_seconds(date, card.completedAt) < 3600));
    }

    _updatePresence();
    _updateNap(date, t);
    _scheduleAmbient(date, t);
    _updateBases();
  }

  AmbientActivity _activity(DateTime date) {
    final session = primarySession;
    if (session == null || session.isStale(date)) return AmbientActivity.idle;
    if (session.phase == SessionPhase.waitingForUser) return AmbientActivity.waiting;
    return session.phase.isWorking ? AmbientActivity.working : AmbientActivity.idle;
  }

  /// How the computer is being used: with "follow my computer" on, the pet sleeps while it rests and wakes with a
  /// stretch when you're back.
  void updateSystem(SystemActivity activity) {
    _system = activity;
    systemResting = activity.isResting(math.max(1, _settings.restAfterMinutes) * 60.0);
  }

  void _updateNap(DateTime date, double t) {
    final followsSystem = _settings.followSystem && _system != null;
    if (followsSystem && petAsleep && !systemResting && _system?.userActive == true && interaction == null && !_settings.pauseReactions) {
      petAsleep = false;
      pet.play(PetAnimation.wakeUp, priority: AnimationPriority.reaction, at: t, ignoreCooldown: true);
      return;
    }
    if (petAsleep || interaction != null || pet.isPlayingOneShot || _settings.pauseReactions) return;
    final idleFor = _seconds(date, _lastUserInteractionAt.isAfter(_lastLiveActivityAt) ? _lastUserInteractionAt : _lastLiveActivityAt);
    if (followsSystem) {
      // Asleep while the computer rests, unless Claude is at work or you just played with it.
      if (!(systemResting && idleFor > 60 && _activity(date) == AmbientActivity.idle)) return;
    } else {
      final napAfter = 8 * 60 * _settings.animationIntensity.gapMultiplier;
      if (!(idleFor > napAfter && _activity(date) == AmbientActivity.idle)) return;
    }
    pet.play(PetAnimation.yawn, priority: AnimationPriority.ambient, at: t, ignoreCooldown: true);
    petAsleep = true;
  }

  void _scheduleAmbient(DateTime date, double t) {
    final idleSeconds = _seconds(date, _lastUserInteractionAt.isAfter(_lastLiveActivityAt) ? _lastUserInteractionAt : _lastLiveActivityAt);
    final context = SchedulerContext(
      companionPresent: companionPresent && !_departing && companion.current.animation != CompanionAnimation.absent,
      activity: _activity(date),
      idleSeconds: idleSeconds,
      charactersBusy: interaction != null || pet.isPlayingOneShot || companion.isPlayingOneShot,
      paused: _settings.pauseReactions,
      reducedMotion: reducedMotion,
      intensity: _settings.animationIntensity,
      petAsleep: petAsleep,
    );
    final next = _scheduler.nextInteraction(now: t, day: calendar.dayNumber(date), context: context);
    if (next != null) {
      startInteraction(next.$1, priority: AnimationPriority.interaction, variant: next.$2);
      return;
    }
    final solo = _scheduler.nextSolo(now: t, context: context);
    if (solo != null) pet.play(solo, priority: AnimationPriority.ambient, at: t);
  }

  // MARK: Presence and base loops

  void _updatePresence({bool animated = true}) {
    final date = _clock();
    final t = _uptime();
    final bool wantsCompanion;
    switch (_settings.companionVisibility) {
      case CompanionVisibility.always:
        wantsCompanion = true;
      case CompanionVisibility.never:
        wantsCompanion = false;
      case CompanionVisibility.duringSessions:
        final ended = _lastSessionEndedAt;
        final lingering = ended != null && _seconds(date, ended) < _settings.companionLingerMinutes * 60;
        wantsCompanion = registry.hasLiveSessions(date) || lingering;
    }

    if (wantsCompanion && (!companionPresent || _departing)) {
      companionPresent = true;
      _departing = false;
      final loop = EventToAnimationMapper.companionLoop(primarySession, now: date, sleepAfter: _sleepAfter, offline: false);
      companion.setBase(loop == CompanionAnimation.sleep ? CompanionAnimation.idleAtDesk : loop, at: t);
      if (animated && !_settings.pauseReactions) {
        if (!startInteraction(InteractionID.welcome, priority: AnimationPriority.user)) {
          companion.play(CompanionAnimation.arrive, priority: AnimationPriority.user, at: t, ignoreCooldown: true);
        }
      }
    } else if (!wantsCompanion && companionPresent && !_departing) {
      if (!animated || _settings.pauseReactions) {
        companionPresent = false;
        companion.setBase(CompanionAnimation.absent, at: t);
        return;
      }
      if (companion.play(CompanionAnimation.depart, priority: AnimationPriority.reaction, at: t, ignoreCooldown: true) is PlayStarted) {
        _departing = true;
      }
    }
  }

  double get _sleepAfter => math.max(1, _settings.companionSleepAfterMinutes) * 60.0;

  void _updateBases() {
    final date = _clock();
    final t = _uptime();
    final session = primarySession;
    if (companionPresent && !_departing) {
      final loop = EventToAnimationMapper.companionLoop(session, now: date, sleepAfter: _sleepAfter, offline: bridgeError != null);
      if (companion.base == CompanionAnimation.sleep &&
          loop != CompanionAnimation.sleep &&
          !companion.isPlayingOneShot &&
          !_settings.pauseReactions) {
        companion.play(CompanionAnimation.wakeUp, priority: AnimationPriority.ambient, at: t);
      }
      companion.setBase(loop, at: t);
    } else if (!companionPresent) {
      companion.setBase(CompanionAnimation.absent, at: t);
    }
    pet.setBase(
      EventToAnimationMapper.petLoop(session, now: date, asleep: petAsleep || (focus?.petNaps ?? false)),
      at: t,
    );
    if (_settings.pauseReactions && interaction?.petToken != null) pet.cancel(interaction!.petToken!, at: t);
  }

  void _settingsChanged(WorldSettings old) {
    if (old.companionVisibility != _settings.companionVisibility || old.pauseReactions != _settings.pauseReactions) _updatePresence();
    if (!old.pauseReactions && _settings.pauseReactions) {
      final t = _uptime();
      pet.cancelOneShot(at: t);
      companion.cancelOneShot(at: t);
      interaction = null;
    }
  }

  // MARK: Drawing

  /// Both characters and the scene props at [time] (world time, defaulting to now): Swift's `SceneRenderer.poses`.
  WorldFrame frame([double? time]) {
    final at = time ?? _uptime();
    final (petPose, companionPose, props) = _poses(at);
    final visible = companionPresent && companion.current.animation != CompanionAnimation.absent;
    var velocity = 0.0;
    if (visible && interaction != null) velocity = (companionPose.x - _poses(at - 0.06).$2.x) / 0.06;
    return WorldFrame(
      pet: petPose,
      companion: companionPose,
      props: props,
      companionVisible: visible,
      companionVelocity: velocity,
      subagents: companionDetail.subagents,
      petAway: adventureActive,
      reducedMotion: reducedMotion,
    );
  }

  (PetPose, CompanionPose, List<SceneProp>) _poses(double time) {
    final reduced = reducedMotion;
    final intensity = _settings.animationIntensity;
    final detail = companionDetail;
    final petContext = PoseContext(time: time, reducedMotion: reduced, intensity: intensity, seed: seed);
    final companionContext = PoseContext(time: time, reducedMotion: reduced, intensity: intensity, seed: seed + 0x5EED);
    PetPose singlePet() {
      final current = pet.current;
      final animation = current.animation == PetAnimation.scripted ? PetAnimation.idle : current.animation;
      final context = petContext.copy()..returnLoop = pet.base;
      return PetPoseEvaluator.pose(animation, elapsed: current.elapsed(time), duration: current.duration, context: context);
    }

    CompanionPose singleCompanion() {
      final current = companion.current;
      final animation = current.animation == CompanionAnimation.scripted ? CompanionAnimation.idleAtDesk : current.animation;
      return CompanionPoseEvaluator.pose(
        animation,
        elapsed: current.elapsed(time),
        duration: current.duration,
        context: companionContext,
        detail: detail,
      );
    }

    final playback = interaction;
    if (playback != null && (pet.current.scriptID == playback.id.name || companion.current.scriptID == playback.id.name)) {
      final frame = InteractionLibrary.frame(
        playback,
        elapsed: time - playback.startedAt,
        petContext: petContext,
        companionContext: companionContext,
        detail: detail,
      );
      // A side that was interrupted plays its own animation, not the script.
      final p = pet.current.scriptID != playback.id.name ? singlePet() : frame.pet;
      final c = companion.current.scriptID != playback.id.name ? singleCompanion() : frame.companion;
      return (p, c, frame.props);
    }
    return (singlePet(), singleCompanion(), const <SceneProp>[]);
  }

  // MARK: Persistence

  /// What to keep across launches (as the Mac keeps progress.json and its event journal): friendship and achievements,
  /// and the recent real events, from which [restore] rebuilds Claude's sessions. The animation and scheduler state
  /// isn't kept: like the Mac, a new launch starts calm.
  Map<String, Object?> toJson() => {
    'v': 1,
    'progress': progress.toJson(),
    'history': [for (final e in _history) eventToJson(e)],
  };

  /// Restores what [toJson] kept: the progress (unless an engine with its own state was given), then rebuilds sessions
  /// from the history (no reactions).
  void restore(Map<String, Object?> json, {bool progressToo = true}) {
    if (progressToo && json['progress'] is Map) achievements.state = ProgressState.fromJson(json['progress']);
    final history = [
      for (final e in (json['history'] is List ? json['history'] as List : const []))
        if (eventFromJson(e) case final event?) event,
    ];
    restoreHistory(history);
  }

  // MARK: Helpers

  bool _rememberID(String id) {
    if (_recentIDSet.contains(id) || (isKnownEvent?.call(id) ?? false)) return false;
    _markSeen(id);
    return true;
  }

  void _markSeen(String id) {
    _recentIDs.add(id);
    _recentIDSet.add(id);
    if (_recentIDs.length > 1024) _recentIDSet.remove(_recentIDs.removeAt(0));
  }

  void _keep(CompanionEvent event, DateTime date) {
    _history.add(event);
    final since = date.subtract(const Duration(hours: 3));
    _history.removeWhere((e) => e.timestamp.isBefore(since));
    if (_history.length > 4000) _history.removeRange(0, _history.length - 4000);
  }

  void _appendTimeline(CompanionEvent event) {
    timeline.add(event);
    if (timeline.length > 120) timeline.removeRange(0, timeline.length - 120);
  }
}

/// A normalized event as JSON (for [MochiWorld.toJson] and a host's own history).
Map<String, Object?> eventToJson(CompanionEvent e) => {
  'id': e.id,
  'kind': e.kind.name,
  'rawName': e.rawName,
  'timestamp': e.timestamp.toUtc().microsecondsSinceEpoch / 1e6,
  'receivedAt': e.receivedAt.toUtc().microsecondsSinceEpoch / 1e6,
  'sessionID': ?e.sessionID,
  if (e.project case final p?) 'project': {'displayName': p.displayName, 'key': p.key},
  'toolName': ?e.toolName,
  'toolCategory': ?e.toolCategory?.name,
  'toolUseID': ?e.toolUseID,
  'attention': ?e.attention?.name,
  if (e.report case final r?) 'report': {'kind': r.kind.name, 'status': r.status.name, 'label': ?r.label},
  'commandKind': ?e.commandKind?.name,
  if (e.commandReliable) 'commandReliable': true,
  'exitCode': ?e.exitCode,
  if (e.interrupted) 'interrupted': true,
  if (e.inSubagent) 'inSubagent': true,
  if (e.metadata.isNotEmpty) 'metadata': e.metadata,
  'message': ?e.message,
  'origin': e.origin.name,
  'delivery': e.delivery.name,
  'schemaVersion': e.schemaVersion,
  'confidence': e.confidence.name,
  'summary': e.summary,
};

CompanionEvent? eventFromJson(Object? json) {
  final j = asMap(json);
  final kind = enumByName(EventKind.values, j['kind']);
  final origin = enumByName(EventOrigin.values, j['origin']);
  final id = string(j, 'id');
  if (kind == null || origin == null || id == null || j['timestamp'] is! num) return null;
  DateTime date(Object? seconds) => DateTime.fromMicrosecondsSinceEpoch(((seconds as num) * 1e6).round(), isUtc: true);
  final p = asMap(j['project']);
  final r = asMap(j['report']);
  final reportKind = enumByName(ReportKind.values, r['kind']);
  final reportStatus = enumByName(ReportStatus.values, r['status']);
  return CompanionEvent(
    id: id,
    kind: kind,
    rawName: string(j, 'rawName') ?? '',
    timestamp: date(j['timestamp']),
    receivedAt: j['receivedAt'] is num ? date(j['receivedAt']) : date(j['timestamp']),
    sessionID: string(j, 'sessionID'),
    project: string(p, 'key') == null ? null : ProjectRef(displayName: string(p, 'displayName') ?? 'Project', key: string(p, 'key')!),
    toolName: string(j, 'toolName'),
    toolCategory: enumByName(ToolCategory.values, j['toolCategory']),
    toolUseID: string(j, 'toolUseID'),
    attention: enumByName(AttentionKind.values, j['attention']),
    report: reportKind == null || reportStatus == null
        ? null
        : ExplicitReport(kind: reportKind, status: reportStatus, label: string(r, 'label')),
    commandKind: enumByName(CommandKind.values, j['commandKind']),
    commandReliable: boolean(j, 'commandReliable', false),
    exitCode: j['exitCode'] is num ? (j['exitCode'] as num).toInt() : null,
    interrupted: boolean(j, 'interrupted', false),
    inSubagent: boolean(j, 'inSubagent', false),
    metadata: {
      for (final e in asMap(j['metadata']).entries)
        if (e.value is String) e.key: e.value as String,
    },
    message: string(j, 'message'),
    origin: origin,
    delivery: enumByName(EventDelivery.values, j['delivery']) ?? EventDelivery.live,
    schemaVersion: integer(j, 'schemaVersion', 1),
    confidence: enumByName(EventConfidence.values, j['confidence']) ?? EventConfidence.reported,
    summary: string(j, 'summary') ?? '',
  );
}
