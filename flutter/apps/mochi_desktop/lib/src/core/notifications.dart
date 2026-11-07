// How Claude's moments reach you on this PC: the Dart port of TamagotchiCore's Notifications/NotificationPolicy.swift,
// Settings/QuietHours.swift, the notification parts of Settings/AppSettings.swift (NotificationCategory,
// CategoryDelivery) and Mapping/EventToAnimationMapper.swift (which category, sound, badge, banner and caption each
// event gets). Mochi's own animations are PetCues here; the Mac's are its world's animations.

import '../core/pet_cues.dart';
import 'session_store.dart' show RecentEvent;
import 'sessions.dart';

/// The kinds of moment, each with its own way of reaching you (Settings › Notifications › Per category).
enum NotificationCategory {
  needsAttention,
  turnCompleted,
  toolFailure,
  turnError,
  buildTest,
  sessionLifecycle,
  toolActivity,
  milestone,
  achievement;

  String get title => switch (this) {
    needsAttention => 'Claude needs you',
    turnCompleted => 'Turn completed',
    toolFailure => 'Tool errors',
    turnError => 'API errors',
    buildTest => 'Build & test results',
    sessionLifecycle => 'Session start & end',
    toolActivity => 'Tool activity',
    milestone => 'Milestones',
    achievement => 'Achievements',
  };

  String get explanation => switch (this) {
    needsAttention => 'Permission prompts, idle input requests and MCP dialogs.',
    turnCompleted => 'Claude finished responding. Says nothing about builds or tests.',
    toolFailure => 'A tool call reported an error. The turn usually continues.',
    turnError => 'A turn ended because of an API error (rate limit, overload…).',
    buildTest => 'Explicit reports, or build/test commands with a trustworthy exit status.',
    sessionLifecycle => 'A Claude Code session started or ended.',
    toolActivity => 'Individual tool calls. Never sent as notifications.',
    milestone => 'Milestones you mark or report.',
    achievement => 'Friendship achievements unlocked.',
  };

  /// Tool activity is far too frequent for banners or badges.
  bool get allowsBanner => this != toolActivity;
  bool get allowsBadge => this != toolActivity && this != sessionLifecycle;

  /// Mochi for Windows has no friendship achievements yet (Settings › Characters says so), so nothing is ever in this
  /// category here: its row is shown, tagged, and can't be changed.
  bool get availableOnWindows => this != achievement;

  CategoryDelivery get defaultDelivery => switch (this) {
    needsAttention => const CategoryDelivery(badge: true, sound: true),
    turnCompleted => const CategoryDelivery(sound: true),
    toolFailure => const CategoryDelivery(badge: true),
    turnError => const CategoryDelivery(badge: true),
    buildTest => const CategoryDelivery(sound: true),
    sessionLifecycle => const CategoryDelivery(sound: true),
    toolActivity => const CategoryDelivery(),
    milestone => const CategoryDelivery(sound: true),
    achievement => const CategoryDelivery(sound: true),
  };
}

/// How one category may reach you: Mochi animates, a badge on Mochi, a Windows notification, a sound.
class CategoryDelivery {
  const CategoryDelivery({this.animate = true, this.badge = false, this.banner = false, this.sound = false});

  final bool animate;
  final bool badge;
  final bool banner;
  final bool sound;

  CategoryDelivery copyWith({bool? animate, bool? badge, bool? banner, bool? sound}) => CategoryDelivery(
    animate: animate ?? this.animate,
    badge: badge ?? this.badge,
    banner: banner ?? this.banner,
    sound: sound ?? this.sound,
  );

  Map<String, Object?> toJson() => {'animate': animate, 'badge': badge, 'banner': banner, 'sound': sound};

  /// A saved one; a missing or damaged field takes [fallback]'s.
  static CategoryDelivery fromJson(Object? json, CategoryDelivery fallback) {
    if (json is! Map) return fallback;
    bool flag(String key, bool value) => json[key] is bool ? json[key] as bool : value;
    return CategoryDelivery(
      animate: flag('animate', fallback.animate),
      badge: flag('badge', fallback.badge),
      banner: flag('banner', fallback.banner),
      sound: flag('sound', fallback.sound),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CategoryDelivery && other.animate == animate && other.badge == badge && other.banner == banner && other.sound == sound;

  @override
  int get hashCode => Object.hash(animate, badge, banner, sound);

  @override
  String toString() => 'CategoryDelivery(animate: $animate, badge: $badge, banner: $banner, sound: $sound)';
}

/// A daily quiet window, e.g. 22:00–08:00 (wrapping past midnight works).
class QuietHours {
  const QuietHours({this.enabled = false, int startMinute = 22 * 60, int endMinute = 8 * 60})
    : startMinute = ((startMinute % 1440) + 1440) % 1440,
      endMinute = ((endMinute % 1440) + 1440) % 1440;

  final bool enabled;

  /// Minutes after midnight.
  final int startMinute;
  final int endMinute;

  bool isActive(DateTime date) {
    if (!enabled || startMinute == endMinute) return false;
    final minute = date.hour * 60 + date.minute;
    if (startMinute < endMinute) return minute >= startMinute && minute < endMinute;
    return minute >= startMinute || minute < endMinute;
  }

  QuietHours copyWith({bool? enabled, int? startMinute, int? endMinute}) =>
      QuietHours(enabled: enabled ?? this.enabled, startMinute: startMinute ?? this.startMinute, endMinute: endMinute ?? this.endMinute);

  /// "22:00".
  static String format(int minute) => '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  Map<String, Object?> toJson() => {'enabled': enabled, 'startMinute': startMinute, 'endMinute': endMinute};

  static QuietHours fromJson(Object? json) {
    if (json is! Map) return const QuietHours();
    return QuietHours(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : false,
      startMinute: json['startMinute'] is int ? json['startMinute'] as int : 22 * 60,
      endMinute: json['endMinute'] is int ? json['endMinute'] as int : 8 * 60,
    );
  }

  @override
  bool operator ==(Object other) => other is QuietHours && other.enabled == enabled && other.startMinute == startMinute && other.endMinute == endMinute;

  @override
  int get hashCode => Object.hash(enabled, startMinute, endMinute);
}

/// What the policy reads from the settings (DesktopSettings, or a test's own).
abstract interface class NotificationPreferences {
  CategoryDelivery delivery(NotificationCategory category);
  bool get soundEnabled;
  bool get workSounds;
  bool get pauseReactions;
  bool get quietMode;
  QuietHours get quietHours;
}

/// The resolved way one reaction may reach you.
class DeliveryDecision {
  const DeliveryDecision({required this.animate, required this.badge, required this.banner, required this.sound, required this.quiet});

  final bool animate;
  final bool badge;
  final bool banner;
  final bool sound;

  /// Quiet hours or quiet mode are softening this delivery.
  final bool quiet;

  static const DeliveryDecision none = DeliveryDecision(animate: false, badge: false, banner: false, sound: false, quiet: false);

  @override
  bool operator ==(Object other) =>
      other is DeliveryDecision &&
      other.animate == animate &&
      other.badge == badge &&
      other.banner == banner &&
      other.sound == sound &&
      other.quiet == quiet;

  @override
  int get hashCode => Object.hash(animate, badge, banner, sound, quiet);

  @override
  String toString() => 'DeliveryDecision(animate: $animate, badge: $badge, banner: $banner, sound: $sound, quiet: $quiet)';
}

class NotificationContext {
  const NotificationContext({required this.now, this.lookingAtMochi = false, this.isSimulated = false, this.isLate = false, this.focusing = false});

  final DateTime now;

  /// Mochi's window or its popover is open: you're already looking (the Mac's `popoverVisible`).
  final bool lookingAtMochi;
  final bool isSimulated;
  final bool isLate;

  /// A focus block is running: only sounds for things that need you still play.
  final bool focusing;
}

abstract final class NotificationPolicy {
  static bool isQuiet(NotificationPreferences settings, DateTime at) => settings.quietMode || settings.quietHours.isActive(at);

  static DeliveryDecision decide(NotificationCategory category, NotificationPreferences settings, NotificationContext context) {
    final preference = settings.delivery(category);
    final quiet = isQuiet(settings, context.now);
    // Late (spooled) events are history, not news: no reactions or alerts.
    if (context.isLate) return DeliveryDecision.none;
    var animate = preference.animate, badge = preference.badge, banner = preference.banner;
    var sound = preference.sound && settings.soundEnabled;
    if (category == NotificationCategory.toolActivity) sound = sound && settings.workSounds;
    if (settings.pauseReactions) {
      animate = false;
      sound = false;
      banner = false;
    }
    if (quiet) {
      sound = false;
      banner = false;
    }
    if (context.focusing && category != NotificationCategory.needsAttention) sound = false;
    // You're already looking at Mochi.
    if (context.lookingAtMochi) {
      banner = false;
      badge = false;
    }
    // Simulated activity never reaches the notification centre.
    if (context.isSimulated) banner = false;
    return DeliveryDecision(animate: animate, badge: badge, banner: banner, sound: sound, quiet: quiet);
  }
}

/// Batches repetitive banners: within the window only the first banner per key is shown and later ones are counted,
/// then summarized in the next banner ("(+2 similar)").
class BannerCoalescer {
  BannerCoalescer({this.window = const Duration(seconds: 45)});

  final Duration window;
  final Map<String, DateTime> _lastShown = {};
  final Map<String, int> _suppressed = {};

  /// Null: hold this one back. Otherwise show it, with how many were held back since the last one shown.
  int? register(String key, DateTime now) {
    final last = _lastShown[key];
    if (last != null && now.difference(last) < window) {
      _suppressed[key] = (_suppressed[key] ?? 0) + 1;
      return null;
    }
    _lastShown[key] = now;
    final count = _suppressed[key] ?? 0;
    _suppressed[key] = 0;
    return count;
  }
}

/// Mochi's little sounds (the Mac's SoundCue).
enum SoundCue { greeting, keyboard, success, celebration, sleep, attention, investigate, pop, achievement }

enum AttentionLevel {
  info,
  attention,
  alert;

  bool operator >=(AttentionLevel other) => index >= other.index;
}

/// A Windows notification's words.
class BannerContent {
  const BannerContent({required this.title, required this.body});

  final String title;
  final String body;

  @override
  bool operator ==(Object other) => other is BannerContent && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  @override
  String toString() => 'BannerContent($title · $body)';
}

/// The dot on Mochi while something waits for you (the Mac's menu-bar badge).
class AttentionBadge {
  const AttentionBadge({required this.kind, required this.level, required this.sessionId, required this.summary, required this.at});

  final AttentionKind kind;
  final AttentionLevel level;
  final String? sessionId;
  final String summary;
  final DateTime at;
}

enum AttentionKind { needsYou, toolError, apiError, buildFailed }

/// What Mochi (and the notification layer) does about one event (the Mac's `Reaction`, with Mochi's PetCue in place
/// of the world's animations).
class Reaction {
  const Reaction({required this.category, this.cue, this.sound, this.attention, this.banner, this.caption});

  final NotificationCategory category;

  /// Mochi's moment, when "Animate" is on.
  final PetCue? cue;
  final SoundCue? sound;
  final AttentionLevel? attention;
  final BannerContent? banner;

  /// What Mochi says in its bubble.
  final String? caption;

  @override
  String toString() => 'Reaction(${category.name}, cue: ${cue?.name}, sound: ${sound?.name}, attention: ${attention?.name}, banner: $banner, caption: $caption)';
}

/// The Mac's EventToAnimationMapper.reaction: which category an event is, and how Mochi answers it.
abstract final class ReactionMapper {
  /// The Mac's "long turn" (Settings › Claude Code there; its default).
  static const Duration longTurn = Duration(minutes: 10);

  static Reaction? reaction(SessionTransition transition, {required bool isPrimary, required bool multipleLiveSessions}) {
    final event = transition.event;
    if (event == null) return null;
    final session = transition.session;
    final label = session.project ?? event.project;
    final prefix = (multipleLiveSessions || !isPrimary) && label != null ? '$label · ' : '';
    final bannerBody = label ?? 'Claude Code';
    final tool = ClaudeSession.friendlyToolName(event.tool ?? '');
    final toolName = event.tool == null ? 'A tool' : tool;
    final outcome = BuildTestResult.ofCommand(event, failed: transition.kind == EventKind.toolFailed);

    switch (transition.kind) {
      case EventKind.sessionStarted:
        if (event.source == 'compact') return null;
        return Reaction(
          category: NotificationCategory.sessionLifecycle,
          cue: PetCue.greet,
          sound: SoundCue.greeting,
          banner: BannerContent(title: RecentEvent.describe(event, transition.kind), body: bannerBody),
          caption: prefix + (event.source == 'resume' ? 'session resumed' : 'session started'),
        );
      case EventKind.promptSubmitted:
        if (!isPrimary) return null;
        return const Reaction(category: NotificationCategory.toolActivity, cue: PetCue.attend);
      case EventKind.toolStarting:
        if (!isPrimary) return null;
        final typing = event.toolCategory == 'edit' || event.toolCategory == 'shell';
        return Reaction(category: NotificationCategory.toolActivity, sound: typing ? SoundCue.keyboard : null);
      case EventKind.toolSucceeded:
        if (!isPrimary) return null;
        if (outcome != null && outcome.passed) {
          return Reaction(
            category: NotificationCategory.buildTest,
            cue: PetCue.cheer,
            sound: SoundCue.success,
            caption: prefix + (outcome.kind == 'test' ? 'test command passed' : 'build command succeeded'),
          );
        }
        return const Reaction(category: NotificationCategory.toolActivity, cue: PetCue.nod);
      case EventKind.toolFailed:
        if (event.isInterrupt == true) {
          if (!isPrimary) return null;
          return Reaction(category: NotificationCategory.toolActivity, cue: PetCue.puzzled, caption: '${prefix}tool interrupted');
        }
        final category = outcome != null ? NotificationCategory.buildTest : NotificationCategory.toolFailure;
        final caption = outcome != null
            ? prefix + (outcome.kind == 'test' ? 'a test command failed' : 'a build command failed')
            : '$prefix$toolName reported an error';
        final banner = BannerContent(
          title: outcome?.summary ?? '$toolName reported an error',
          body: '$bannerBody — Claude may still be working on it.',
        );
        if (transition.startedInvestigating && isPrimary) {
          return Reaction(
            category: category,
            cue: PetCue.worry,
            sound: SoundCue.investigate,
            attention: AttentionLevel.info,
            banner: banner,
            caption: '${prefix}several tool errors — investigating',
          );
        }
        return Reaction(
          category: category,
          cue: isPrimary ? PetCue.worry : null,
          sound: SoundCue.investigate,
          attention: AttentionLevel.info,
          banner: banner,
          caption: caption,
        );
      case EventKind.toolBatchFinished:
        return null;
      case EventKind.permissionRequested || EventKind.attentionNeeded:
        // PermissionRequest and its Notification arrive together: react once.
        if (transition.previous == SessionPhase.waitingForUser) return null;
        final attention = EventKind.attentionOf(event);
        final level = attention == Attention.input ? AttentionLevel.info : AttentionLevel.attention;
        final title = switch (attention) {
          Attention.permission => 'Claude needs your permission',
          Attention.input => 'Claude is waiting for your input',
          Attention.mcpDialog => 'An MCP server needs your input',
          Attention.backgroundAgent => 'A background agent needs input',
          null => 'Claude Code needs your attention',
        };
        final detail = transition.kind == EventKind.permissionRequested ? (event.tool == null ? null : 'Wants to use $tool') : event.message;
        return Reaction(
          category: NotificationCategory.needsAttention,
          cue: PetCue.needsYou,
          sound: SoundCue.attention,
          attention: level,
          banner: BannerContent(title: title, body: [bannerBody, ?detail].join(' — ')),
          caption: prefix + (attention == Attention.permission ? 'waiting for permission' : 'waiting for you'),
        );
      case EventKind.permissionDenied:
        if (!isPrimary) return null;
        return Reaction(category: NotificationCategory.toolActivity, cue: PetCue.puzzled, caption: '${prefix}auto mode declined a call');
      case EventKind.notification:
        if (event.notificationType == 'agent_completed') {
          return Reaction(category: NotificationCategory.turnCompleted, cue: PetCue.cheer, caption: '${prefix}background agent finished');
        }
        return null;
      case EventKind.subagentStarted:
        if (!isPrimary) return null;
        return const Reaction(category: NotificationCategory.toolActivity, cue: PetCue.working);
      case EventKind.subagentStopped:
        if (!isPrimary) return null;
        return const Reaction(category: NotificationCategory.toolActivity);
      case EventKind.turnCompleted:
        final buildTest = session.buildTestThisTurn;
        final summary = buildTest?.summary ?? 'No build or test result was received this turn.';
        final banner = BannerContent(title: 'Claude finished responding', body: '$bannerBody — $summary');
        // A trophy for a passing build or test, a victory dance for a long turn (both ends seen live); after an
        // investigation, case closed (the Mac's choice of interaction, and its sound).
        final big = buildTest != null && buildTest.passed || (transition.turnDuration ?? Duration.zero) >= longTurn;
        return Reaction(
          category: NotificationCategory.turnCompleted,
          cue: PetCue.finished,
          sound: isPrimary && big && !session.investigatedThisTurn ? SoundCue.celebration : SoundCue.success,
          banner: banner,
          caption: '${prefix}turn complete',
        );
      case EventKind.turnFailed:
        final reason = event.reason?.replaceAll('_', ' ');
        return Reaction(
          category: NotificationCategory.turnError,
          cue: PetCue.snag,
          sound: SoundCue.investigate,
          attention: AttentionLevel.alert,
          banner: BannerContent(title: 'Turn ended with an API error', body: [bannerBody, ?reason].join(' — ')),
          caption: '${prefix}API error${reason == null ? '' : ' ($reason)'}',
        );
      case EventKind.sessionEnded:
        return Reaction(
          category: NotificationCategory.sessionLifecycle,
          cue: PetCue.goodbye,
          banner: BannerContent(title: RecentEvent.describe(event, transition.kind), body: bannerBody),
          caption: '${prefix}session ended',
        );
      case EventKind.report:
        final report = event.report;
        if (report == null) return null;
        final labelText = report.label == null ? '' : ' — ${report.label}';
        final title = SessionRegistry.reportSummary(report);
        final failed = report.status == 'failed';
        switch (report.kind) {
          case 'build' || 'test':
            if (failed) {
              return Reaction(
                category: NotificationCategory.buildTest,
                cue: PetCue.worry,
                sound: SoundCue.investigate,
                attention: AttentionLevel.info,
                banner: BannerContent(title: title, body: 'Reported by your script'),
                caption: (report.kind == 'test' ? 'tests failed' : 'build failed') + labelText,
              );
            }
            return Reaction(
              category: NotificationCategory.buildTest,
              cue: PetCue.celebrate,
              sound: SoundCue.celebration,
              banner: BannerContent(title: title, body: 'Reported by your script'),
              caption: (report.kind == 'test' ? 'tests passed' : 'build passed') + labelText,
            );
          case 'milestone':
            return Reaction(
              category: NotificationCategory.milestone,
              cue: PetCue.celebrate,
              sound: SoundCue.celebration,
              banner: BannerContent(title: 'Milestone reached', body: report.label ?? 'Nice work!'),
              caption: 'milestone$labelText',
            );
          default:
            return Reaction(category: NotificationCategory.milestone, cue: PetCue.cheer, sound: SoundCue.success, caption: 'commit recorded$labelText');
        }
      case EventKind.unknown:
        return null;
    }
  }

  /// The badge an event with [level] puts on Mochi (the Mac's `perform`).
  static AttentionKind badgeKind(SessionTransition transition) => switch (transition.kind) {
    EventKind.permissionRequested || EventKind.attentionNeeded => AttentionKind.needsYou,
    EventKind.turnFailed => AttentionKind.apiError,
    EventKind.report => AttentionKind.buildFailed,
    _ => transition.event != null && BuildTestResult.ofCommand(transition.event!, failed: true) != null ? AttentionKind.buildFailed : AttentionKind.toolError,
  };

  /// The badge after [transition] (the Mac's `updateAttention`): a badge for a session that's gone goes with it, "needs
  /// you" goes once the session stops waiting, a tool error or failed build once the turn ends or a new one starts, an
  /// API error once a new turn starts.
  static AttentionBadge? afterEvent(AttentionBadge? current, SessionTransition transition, {required bool Function(String id) exists}) {
    if (current == null) return null;
    final id = current.sessionId;
    if (id != null && !exists(id)) return null;
    if (id != null && id != transition.session.id) return current;
    final kind = transition.kind;
    return switch (current.kind) {
      AttentionKind.needsYou => transition.session.phase != SessionPhase.waitingForUser ? null : current,
      AttentionKind.toolError || AttentionKind.buildFailed =>
        kind == EventKind.turnCompleted || kind == EventKind.promptSubmitted || kind == EventKind.sessionEnded ? null : current,
      AttentionKind.apiError => kind == EventKind.promptSubmitted || kind == EventKind.sessionEnded ? null : current,
    };
  }
}
