import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart' show ClaudeMirror;
import 'package:mochi_wire/mochi_wire.dart';

import 'sessions.dart';

/// One event in a session's recent history (the Mac popover's "Recent" list).
class RecentEvent {
  const RecentEvent({
    required this.sessionId,
    required this.kind,
    required this.summary,
    required this.at,
    this.category,
    this.late = false,
    this.failed = false,
  });

  final String sessionId;
  final EventKind kind;

  /// What happened, in words (Swift `EventNormalizer.summary(for:)`).
  final String summary;
  final DateTime at;

  /// The tool's category (read · search · edit · shell · web · agent · plan · ask · mcp · skill · other).
  final String? category;

  /// It came in late, from the spool (Mochi wasn't running): the Mac's LATE tag.
  final bool late;

  /// A tool error, a failed build or test, or an API error.
  final bool failed;

  /// [event]'s summary, as the Mac words it.
  static String describe(WireEvent event, EventKind kind) {
    final tool = ClaudeSession.friendlyToolName(event.tool ?? 'a tool');
    final outcome = SessionRegistry.buildTestOutcome(event, failed: kind == EventKind.toolFailed);
    return switch (kind) {
      EventKind.sessionStarted => switch (event.source) {
        'resume' => 'Session resumed',
        'clear' => 'Session cleared and restarted',
        'compact' => 'Context compacted; session continues',
        'fork' => 'Session forked',
        _ => 'Claude Code session started',
      },
      EventKind.promptSubmitted => 'A prompt was submitted',
      EventKind.toolStarting => event.backgrounded == true ? 'Starting $tool in the background' : 'About to use $tool',
      EventKind.toolSucceeded => outcome ?? '$tool finished',
      EventKind.toolFailed =>
        event.isInterrupt == true
            ? '$tool was interrupted'
            : outcome != null
            ? '$outcome${event.exitCode == null ? '' : ' (exit code ${event.exitCode})'}'
            : event.exitCode != null
            ? '$tool reported an error (exit code ${event.exitCode})'
            : '$tool reported an error',
      EventKind.toolBatchFinished => event.batchCount == 1 ? '1 tool call finished' : '${event.batchCount ?? 0} tool calls finished',
      EventKind.permissionRequested => 'Claude is asking permission to use $tool',
      EventKind.permissionDenied => 'Auto mode declined a $tool call',
      EventKind.attentionNeeded => switch (EventKind.attentionOf(event)) {
        Attention.permission => event.message ?? 'Claude needs your permission',
        Attention.input => 'Claude is waiting for your input',
        Attention.mcpDialog => 'An MCP server is asking for input',
        Attention.backgroundAgent => 'A background agent needs input',
        null => event.message ?? 'Claude needs your attention',
      },
      EventKind.notification => switch (event.notificationType) {
        'auth_success' => 'Authentication succeeded',
        'agent_completed' => 'A background agent finished',
        _ => event.message ?? 'Notification from Claude Code',
      },
      EventKind.subagentStarted => event.agentType == null || event.agentType!.isEmpty ? 'Subagent started' : 'Subagent started (${event.agentType})',
      EventKind.subagentStopped => 'Subagent finished',
      EventKind.turnCompleted => 'Claude finished responding',
      EventKind.turnFailed => event.reason == null ? 'Turn ended with an API error' : 'Turn ended with an API error (${event.reason!.replaceAll('_', ' ')})',
      EventKind.sessionEnded => 'Claude Code session ended',
      EventKind.report => event.report == null ? 'A report from your script' : SessionRegistry.reportSummary(event.report!),
      EventKind.unknown => 'Unknown event',
    };
  }
}

/// The app's Claude sessions: hook events in, the session list and every change out.
class SessionStore extends ChangeNotifier {
  SessionStore({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final SessionRegistry registry = SessionRegistry();
  final StreamController<SessionTransition> _transitions = StreamController.broadcast(sync: true);

  /// Every applied event, live or late.
  Stream<SessionTransition> get transitions => _transitions.stream;

  DateTime get now => _clock();

  /// Sessions that haven't ended, newest first.
  List<ClaudeSession> get live => registry.live;
  List<ClaudeSession> get all => registry.all;

  /// The session Mochi follows: the one you chose (the popover's session menu) while it's open, else the most
  /// relevant (the Mac's `primarySession` with `pinnedSessionID`).
  ClaudeSession? get primary {
    final pinned = _pinned == null ? null : registry[_pinned!];
    if (pinned != null && pinned.isLive) return pinned;
    return registry.primary(now);
  }

  String? _pinned;

  /// The session you chose to follow (null: the most relevant, automatically).
  String? get pinned {
    final pinned = _pinned == null ? null : registry[_pinned!];
    return pinned != null && pinned.isLive ? _pinned : null;
  }

  /// Follow [id] (null: the most relevant again).
  void pin(String? id) {
    if (id == _pinned) return;
    _pinned = id;
    notifyListeners();
  }

  /// The newest events first, at most [recentLimit] (in memory only: never saved).
  final List<RecentEvent> recent = [];
  static const int recentLimit = 60;

  /// Result cards you dismissed (`session@completedAt`), so they stay dismissed.
  final Set<String> dismissedResults = {};

  void dismissResult(String key) {
    if (dismissedResults.add(key)) notifyListeners();
  }

  /// [session]'s recent events, newest first (sessions are never mixed).
  List<RecentEvent> recentFor(String session, {int limit = 5}) =>
      recent.where((event) => event.sessionId == session).take(limit).toList();

  /// Events that came in late from the spool (the app wasn't running), and how many the spool had to drop.
  int lateEvents = 0;
  int droppedEvents = 0;

  /// When the last hook event arrived (null: none since launch).
  DateTime? lastEventAt;

  ClaudeMirror mirror({bool resting = false}) => registry.mirror(resting: resting, now: now);

  void apply(WireEvent event, {Delivery delivery = Delivery.live}) {
    final transition = registry.apply(event, delivery: delivery);
    if (transition == null) return;
    if (transition.kind != EventKind.unknown && transition.kind != EventKind.toolBatchFinished) {
      recent.insert(
        0,
        RecentEvent(
          sessionId: transition.session.id,
          kind: transition.kind,
          summary: RecentEvent.describe(event, transition.kind),
          at: DateTime.fromMicrosecondsSinceEpoch((event.ts * 1e6).round()),
          category: event.toolCategory,
          late: delivery == Delivery.late,
          failed: transition.kind == EventKind.toolFailed && event.isInterrupt != true || transition.kind == EventKind.turnFailed,
        ),
      );
      if (recent.length > recentLimit) recent.removeRange(recentLimit, recent.length);
    }
    if (delivery == Delivery.late) {
      lateEvents++;
    } else {
      lastEventAt = now;
    }
    _transitions.add(transition);
    notifyListeners();
  }

  /// Drops ended and long-idle sessions.
  void prune() {
    final before = registry.all.length;
    registry.prune(now);
    if (registry.all.length != before) notifyListeners();
  }

  /// Something about a session changed outside the hooks (a summary arrived).
  void touched() => notifyListeners();

  /// "web is working (3 min) · api is waiting for you." (Swift `AssistantController.sessionsSummary`).
  String statusSummary() {
    final sessions = live.take(5).toList();
    if (sessions.isEmpty) return 'No Claude sessions right now.';
    return '${sessions.map((session) => '${session.project ?? 'A session'} is ${stateText(session)}').join(' · ')}.';
  }

  String stateText(ClaudeSession session) {
    switch (session.phase) {
      case SessionPhase.promptSubmitted || SessionPhase.thinking || SessionPhase.runningTool:
        final start = session.turnStartedAt;
        final minutes = start == null ? null : (now.difference(start).inSeconds / 60).floor().clamp(1, 1 << 20);
        return minutes == null ? 'working' : 'working ($minutes min)';
      case SessionPhase.waitingForUser:
        return 'waiting for you';
      case SessionPhase.turnFailed:
        return 'stopped with an error';
      case SessionPhase.turnCompleted || SessionPhase.idle:
        return 'idle';
      case SessionPhase.ended:
        return 'ended';
    }
  }

  @override
  void dispose() {
    unawaited(_transitions.close());
    super.dispose();
  }
}
