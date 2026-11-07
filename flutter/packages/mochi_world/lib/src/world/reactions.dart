// Port of Sources/TamagotchiCore/Mapping/EventToAnimationMapper.swift: what the characters (and the notification
// layer) do about one event, and which loops represent a session's phase.

import 'dart:convert';

import '../events/events.dart';
import '../events/sessions.dart';
import '../interactions/interaction_library.dart';
import '../model/animations.dart';
import '../model/ease.dart';
import 'settings.dart';

enum SoundCue { greeting, keyboard, success, celebration, sleep, attention, investigate, pop, achievement }

enum AttentionLevel implements Comparable<AttentionLevel> {
  info,
  attention,
  alert;

  @override
  int compareTo(AttentionLevel other) => index - other.index;

  bool operator >=(AttentionLevel other) => index >= other.index;
}

class BannerContent {
  const BannerContent({required this.title, required this.body});
  final String title;
  final String body;

  BannerContent withBody(String body) => BannerContent(title: title, body: body);

  Map<String, Object?> toJson() => {'title': title, 'body': body};
}

/// What the characters (and the notification layer) should do about one event. These are visual responses, not
/// claims about Claude's reasoning: detailed animations are only chosen when the event itself carries that information.
class Reaction {
  const Reaction({
    required this.category,
    this.pet,
    this.companion,
    this.interaction,
    this.priority = AnimationPriority.reaction,
    this.sound,
    this.attention,
    this.banner,
    this.caption,
    this.burst = false,
    this.resultCard = false,
  });

  final NotificationCategory category;
  final PetAnimation? pet;
  final CompanionAnimation? companion;
  final InteractionID? interaction;
  final AnimationPriority priority;
  final SoundCue? sound;
  final AttentionLevel? attention;
  final BannerContent? banner;
  final String? caption;

  /// Sparkle burst (the Mac's menu bar).
  final bool burst;
  final bool resultCard;

  Map<String, Object?> toJson() => {
    'category': category.name,
    'pet': ?pet?.name,
    'companion': ?companion?.name,
    'interaction': ?interaction?.name,
    'priority': priority.name,
    'sound': ?sound?.name,
    'attention': ?attention?.name,
    'banner': ?banner?.toJson(),
    'caption': ?caption,
    'burst': burst,
    'resultCard': resultCard,
  };
}

class MapperContext {
  const MapperContext({
    required this.companionPresent,
    required this.isPrimary,
    this.multipleLiveSessions = false,
    this.celebrateCommandResults = true,
    this.longTurnThreshold = 600,
    this.firstMilestone = false,
  });

  final bool companionPresent;
  final bool isPrimary;
  final bool multipleLiveSessions;
  final bool celebrateCommandResults;

  /// Seconds.
  final double longTurnThreshold;

  /// True if this milestone just unlocked the graduation achievement.
  final bool firstMilestone;
}

abstract final class EventToAnimationMapper {
  /// The looping animation that represents a session's current phase.
  static CompanionAnimation companionLoop(SessionSnapshot? session, {required DateTime now, required double sleepAfter, required bool offline}) {
    if (offline) return CompanionAnimation.offline;
    if (session == null) return CompanionAnimation.idleAtDesk;
    final quietFor = now.difference(session.lastEventAt).inMicroseconds / 1e6;
    if (session.isStale(now)) return quietFor > sleepAfter ? CompanionAnimation.sleep : CompanionAnimation.idleAtDesk;
    switch (session.phase) {
      case SessionPhase.promptSubmitted || SessionPhase.thinking:
        if (session.isInvestigating) return CompanionAnimation.detective;
        return session.activeSubagents.isEmpty ? CompanionAnimation.thinking : CompanionAnimation.delegating;
      case SessionPhase.runningTool:
        if (session.isInvestigating) return CompanionAnimation.detective;
        return workLoop(session.currentTool?.category);
      case SessionPhase.waitingForUser:
        return CompanionAnimation.waiting;
      case SessionPhase.idle || SessionPhase.turnCompleted || SessionPhase.turnFailed:
        return quietFor > sleepAfter ? CompanionAnimation.sleep : CompanionAnimation.idleAtDesk;
      case SessionPhase.ended:
        return quietFor > sleepAfter ? CompanionAnimation.sleep : CompanionAnimation.rest;
    }
  }

  /// Generic work unless the tool name genuinely says what kind of work it is.
  static CompanionAnimation workLoop(ToolCategory? category) => switch (category) {
    ToolCategory.read => CompanionAnimation.reading,
    ToolCategory.search => CompanionAnimation.searching,
    ToolCategory.edit || ToolCategory.plan => CompanionAnimation.typing,
    ToolCategory.shell => CompanionAnimation.runningCommand,
    ToolCategory.web => CompanionAnimation.browsing,
    ToolCategory.agent => CompanionAnimation.delegating,
    ToolCategory.ask => CompanionAnimation.waiting,
    _ => CompanionAnimation.typing,
  };

  static PetAnimation petLoop(SessionSnapshot? session, {required DateTime now, required bool asleep}) {
    if (asleep) return PetAnimation.sleep;
    if (session == null || session.isStale(now)) return PetAnimation.idle;
    return switch (session.phase) {
      SessionPhase.promptSubmitted || SessionPhase.thinking => PetAnimation.watch,
      SessionPhase.runningTool => session.currentTool?.category == ToolCategory.ask ? PetAnimation.waveGently : PetAnimation.watch,
      SessionPhase.waitingForUser => PetAnimation.waveGently,
      _ => PetAnimation.idle,
    };
  }

  /// Swift's `stableHash` of an event id for the milestone dance: a 31-multiplier over its UTF-8 bytes, 32 bits.
  static int stableHash(String id) => utf8.encode(id).fold(0, (h, byte) => (h * 31 + byte) & 0xFFFFFFFF);

  static Reaction? reaction(CompanionEvent event, {SessionTransition? transition, SessionSnapshot? session, required MapperContext context}) {
    final label = session?.displayName ?? event.project?.displayName;
    final prefix = (context.multipleLiveSessions || !context.isPrimary) ? (label == null ? '' : '$label · ') : '';
    final bannerBody = label ?? 'Claude Code';

    switch (event.kind) {
      case EventKind.sessionStarted:
        if (event.metadata['source'] == 'compact') return null;
        return Reaction(
          category: NotificationCategory.sessionLifecycle,
          pet: PetAnimation.greet,
          companion: context.companionPresent ? CompanionAnimation.greet : null,
          sound: SoundCue.greeting,
          banner: BannerContent(title: event.summary, body: bannerBody),
          caption: prefix + (event.metadata['source'] == 'resume' ? 'session resumed' : 'session started'),
        );

      case EventKind.promptSubmitted:
        if (!context.isPrimary) return null;
        return const Reaction(category: NotificationCategory.toolActivity, pet: PetAnimation.leanForward, companion: CompanionAnimation.readTaskCard);

      case EventKind.toolStarting:
        if (!context.isPrimary) return null;
        final typing = event.toolCategory == ToolCategory.edit || event.toolCategory == ToolCategory.shell;
        return Reaction(category: NotificationCategory.toolActivity, priority: AnimationPriority.ambient, sound: typing ? SoundCue.keyboard : null);

      case EventKind.toolSucceeded:
        if (!context.isPrimary) return null;
        final outcome = event.buildTestOutcome;
        if (context.celebrateCommandResults && outcome != null && outcome.passed) {
          return Reaction(
            category: NotificationCategory.buildTest,
            pet: PetAnimation.happyBounce,
            companion: CompanionAnimation.nod,
            sound: SoundCue.success,
            caption: prefix + (outcome.kind == CommandKind.test ? 'test command passed' : 'build command succeeded'),
          );
        }
        return const Reaction(category: NotificationCategory.toolActivity, pet: PetAnimation.nod, priority: AnimationPriority.ambient);

      case EventKind.toolFailed:
        if (event.interrupted) {
          if (!context.isPrimary) return null;
          return Reaction(category: NotificationCategory.toolActivity, pet: PetAnimation.confusedTilt, caption: '${prefix}tool interrupted');
        }
        final outcome = event.buildTestOutcome;
        final category = outcome != null && context.celebrateCommandResults ? NotificationCategory.buildTest : NotificationCategory.toolFailure;
        final tool = event.toolName == null ? 'A tool' : EventNormalizer.friendlyToolName(event.toolName!);
        final caption = outcome != null
            ? prefix + (outcome.kind == CommandKind.test ? 'a test command failed' : 'a build command failed')
            : '$prefix$tool reported an error';
        final banner = BannerContent(title: outcome?.summary ?? '$tool reported an error', body: '$bannerBody — Claude may still be working on it.');
        if (transition?.startedInvestigating == true && context.isPrimary) {
          return Reaction(
            category: category,
            interaction: InteractionID.detectiveHat,
            sound: SoundCue.investigate,
            attention: AttentionLevel.info,
            banner: banner,
            caption: '${prefix}several tool errors — investigating',
          );
        }
        return Reaction(
          category: category,
          pet: context.isPrimary ? PetAnimation.concerned : null,
          companion: context.isPrimary ? CompanionAnimation.concerned : null,
          sound: SoundCue.investigate,
          attention: AttentionLevel.info,
          banner: banner,
          caption: caption,
        );

      case EventKind.toolBatchFinished:
        return null;

      case EventKind.permissionRequested || EventKind.attentionNeeded:
        // PermissionRequest and its Notification arrive together: react once.
        if (transition?.previousPhase == SessionPhase.waitingForUser) return null;
        final level = event.attention == AttentionKind.input ? AttentionLevel.info : AttentionLevel.attention;
        final title = switch (event.attention) {
          AttentionKind.permission => 'Claude needs your permission',
          AttentionKind.input => 'Claude is waiting for your input',
          AttentionKind.mcpDialog => 'An MCP server needs your input',
          AttentionKind.backgroundAgent => 'A background agent needs input',
          null => 'Claude Code needs your attention',
        };
        final detail = event.kind == EventKind.permissionRequested
            ? (event.toolName == null ? null : 'Wants to use ${EventNormalizer.friendlyToolName(event.toolName!)}')
            : event.message;
        return Reaction(
          category: NotificationCategory.needsAttention,
          pet: PetAnimation.wave,
          priority: AnimationPriority.attention,
          sound: SoundCue.attention,
          attention: level,
          banner: BannerContent(title: title, body: [bannerBody, ?detail].join(' — ')),
          caption: prefix + (event.attention == AttentionKind.permission ? 'waiting for permission' : 'waiting for you'),
        );

      case EventKind.permissionDenied:
        if (!context.isPrimary) return null;
        return Reaction(category: NotificationCategory.toolActivity, pet: PetAnimation.confusedTilt, caption: '${prefix}auto mode declined a call');

      case EventKind.notification:
        if (event.metadata['notificationType'] == 'agent_completed') {
          return Reaction(category: NotificationCategory.turnCompleted, pet: PetAnimation.happyBounce, caption: '${prefix}background agent finished');
        }
        return null;

      case EventKind.subagentStarted:
        if (!context.isPrimary) return null;
        return const Reaction(category: NotificationCategory.toolActivity, pet: PetAnimation.lookAround, priority: AnimationPriority.ambient);

      case EventKind.subagentStopped:
        if (!context.isPrimary) return null;
        return const Reaction(category: NotificationCategory.toolActivity, companion: CompanionAnimation.nod, priority: AnimationPriority.ambient);

      case EventKind.turnCompleted:
        final buildTest = session?.buildTestThisTurn;
        final summary = buildTest?.summary ?? 'No build or test result was received this turn.';
        final banner = BannerContent(title: 'Claude finished responding', body: '$bannerBody — $summary');
        if (!context.isPrimary) {
          // Another session is in focus: acknowledge without hijacking the scene.
          return Reaction(
            category: NotificationCategory.turnCompleted,
            pet: PetAnimation.happyBounce,
            sound: SoundCue.success,
            banner: banner,
            caption: '${prefix}turn complete',
            burst: true,
            resultCard: true,
          );
        }
        InteractionID interaction;
        var sound = SoundCue.success;
        if (session?.investigatedThisTurn == true) {
          interaction = InteractionID.caseClosed;
        } else if (buildTest != null && buildTest.passed && (buildTest.source == BuildTestSource.explicitReport || context.celebrateCommandResults)) {
          interaction = InteractionID.trophyCelebration;
          sound = SoundCue.celebration;
        } else if (transition?.turnDurationTrusted == true &&
            transition?.turnDuration != null &&
            transition!.turnDuration! >= context.longTurnThreshold) {
          interaction = InteractionID.victoryDance;
          sound = SoundCue.celebration;
        } else {
          interaction = InteractionID.highFive;
        }
        return Reaction(
          category: NotificationCategory.turnCompleted,
          pet: PetAnimation.victory,
          interaction: interaction,
          sound: sound,
          banner: banner,
          caption: '${prefix}turn complete',
          burst: true,
          resultCard: true,
        );

      case EventKind.turnFailed:
        final reason = event.metadata['reason']?.replaceAll('_', ' ');
        return Reaction(
          category: NotificationCategory.turnError,
          pet: PetAnimation.concerned,
          companion: context.isPrimary ? CompanionAnimation.concerned : null,
          sound: SoundCue.investigate,
          attention: AttentionLevel.alert,
          banner: BannerContent(title: 'Turn ended with an API error', body: [bannerBody, ?reason].join(' — ')),
          caption: '${prefix}API error${reason == null ? '' : ' ($reason)'}',
        );

      case EventKind.sessionEnded:
        return Reaction(
          category: NotificationCategory.sessionLifecycle,
          pet: PetAnimation.wave,
          companion: context.isPrimary ? CompanionAnimation.packUp : null,
          banner: BannerContent(title: event.summary, body: bannerBody),
          caption: '${prefix}session ended',
        );

      case EventKind.report:
        final report = event.report;
        if (report == null) return null;
        final labelText = report.label == null ? '' : ' — ${report.label}';
        switch ((report.kind, report.status)) {
          case (ReportKind.build || ReportKind.test, ReportStatus.failed):
            return Reaction(
              category: NotificationCategory.buildTest,
              pet: PetAnimation.concerned,
              companion: CompanionAnimation.concerned,
              sound: SoundCue.investigate,
              attention: AttentionLevel.info,
              banner: BannerContent(title: event.summary, body: 'Reported by your script'),
              caption: (report.kind == ReportKind.test ? 'tests failed' : 'build failed') + labelText,
            );
          case (ReportKind.build || ReportKind.test, _):
            return Reaction(
              category: NotificationCategory.buildTest,
              pet: PetAnimation.excitedJump,
              interaction: InteractionID.trophyCelebration,
              sound: SoundCue.celebration,
              banner: BannerContent(title: event.summary, body: 'Reported by your script'),
              caption: (report.kind == ReportKind.test ? 'tests passed' : 'build passed') + labelText,
              burst: true,
            );
          case (ReportKind.milestone, _):
            final rare = Ease.hash(stableHash(event.id), 7) < 0.34;
            final interaction = context.firstMilestone ? InteractionID.graduation : (rare ? InteractionID.syncDance : InteractionID.victoryDance);
            return Reaction(
              category: NotificationCategory.milestone,
              pet: PetAnimation.victory,
              interaction: interaction,
              priority: AnimationPriority.user,
              sound: SoundCue.celebration,
              banner: BannerContent(title: 'Milestone reached', body: report.label ?? 'Nice work!'),
              caption: 'milestone$labelText',
              burst: true,
            );
          case (ReportKind.commit, _):
            return Reaction(
              category: NotificationCategory.milestone,
              pet: PetAnimation.happyBounce,
              interaction: InteractionID.highFive,
              sound: SoundCue.success,
              caption: 'commit recorded$labelText',
              burst: true,
            );
        }

      case EventKind.unknown:
        return null;
    }
  }
}
