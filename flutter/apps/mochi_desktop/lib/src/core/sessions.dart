// Claude Code sessions as Mochi sees them through the hooks: the Dart port of TamagotchiCore's SessionRegistry
// (Sessions/SessionRegistry.swift) and the part of EventNormalizer that turns a hook event into a kind of change.
// Each session is tracked on its own; events are only ever applied to the session they carry.

import 'package:mochi_link/mochi_link.dart' show ClaudeMirror, TurnSummary;
import 'package:mochi_wire/mochi_wire.dart';

/// The observed phase of one Claude Code session (Swift `SessionPhase`).
enum SessionPhase {
  /// Detected; no turn in progress.
  idle,

  /// A prompt was submitted; no tool yet.
  promptSubmitted,

  /// A turn is in progress and no tool is running.
  thinking,

  /// At least one tool call started and hasn't reported back.
  runningTool,

  /// Claude Code is waiting on the user (a permission, an answer).
  waitingForUser,

  /// `Stop`: the turn finished.
  turnCompleted,

  /// `StopFailure`: the turn ended with an API error.
  turnFailed,
  ended;

  bool get isWorking => this == promptSubmitted || this == thinking || this == runningTool;
}

/// What a session is waiting for (Swift `AttentionKind`).
enum Attention { permission, input, mcpDialog, backgroundAgent }

/// How an event arrived: as it happened, or later from the spool (the app wasn't running). Late events update the
/// sessions but never play reactions or send notifications.
enum Delivery { live, late }

/// The kind of change a hook event is (Swift `EventKind`).
enum EventKind {
  sessionStarted,
  promptSubmitted,
  toolStarting,
  toolSucceeded,
  toolFailed,
  toolBatchFinished,
  permissionRequested,
  permissionDenied,
  attentionNeeded,
  notification,
  subagentStarted,
  subagentStopped,
  turnCompleted,
  turnFailed,
  sessionEnded,
  report,
  unknown;

  /// Swift `EventNormalizer.kind(for:)`.
  static EventKind of(WireEvent wire) {
    if (wire.origin == WireOrigin.report || (wire.event == 'Report' && wire.report != null)) return report;
    return switch (wire.event) {
      'SessionStart' => sessionStarted,
      'UserPromptSubmit' => promptSubmitted,
      'PreToolUse' => toolStarting,
      'PostToolUse' => toolSucceeded,
      'PostToolUseFailure' => toolFailed,
      'PostToolBatch' => toolBatchFinished,
      'PermissionRequest' => permissionRequested,
      'PermissionDenied' => permissionDenied,
      'Notification' => attentionOf(wire) != null ? attentionNeeded : notification,
      'SubagentStart' => subagentStarted,
      'SubagentStop' => subagentStopped,
      'Stop' => turnCompleted,
      'StopFailure' => turnFailed,
      'SessionEnd' => sessionEnded,
      _ => unknown,
    };
  }

  /// Swift `EventNormalizer.attentionKind(for:)`.
  static Attention? attentionOf(WireEvent wire) => switch (wire.event) {
    'PermissionRequest' => Attention.permission,
    'Notification' => switch (wire.notificationType) {
      'permission_prompt' => Attention.permission,
      'idle_prompt' => Attention.input,
      'elicitation_dialog' || 'elicitation_url_dialog' => Attention.mcpDialog,
      'agent_needs_input' => Attention.backgroundAgent,
      _ => null,
    },
    _ => null,
  };
}

class RunningTool {
  const RunningTool({required this.name, required this.category, required this.startedAt});

  final String name;

  /// read · search · edit · shell · web · agent · plan · ask · skill · mcp · other
  final String category;
  final DateTime startedAt;
}

/// One Claude Code session (Swift `SessionSnapshot`, the parts the desktop app uses).
class ClaudeSession {
  ClaudeSession({required this.id, required this.firstSeen, required this.lastEventAt, this.project, this.projectKey, this.projectPath});

  final String id;
  String? project;
  String? projectKey;
  String? projectPath;
  SessionPhase phase = SessionPhase.idle;
  final Map<String, RunningTool> runningTools = {};
  RunningTool? currentTool;
  Attention? waitingFor;
  String? waitingTool;
  final DateTime firstSeen;
  DateTime lastEventAt;
  bool startObserved = false;
  DateTime? turnStartedAt;
  DateTime? lastTurnCompletedAt;
  int turnsCompleted = 0;
  int toolCallsThisTurn = 0;
  int consecutiveFailures = 0;
  DateTime? lastFailureAt;
  final Set<String> activeSubagents = {};
  String? model;
  String? host;
  String? endedReason;
  DateTime? endedAt;
  int lateEvents = 0;
  String? turnFailureReason;

  /// "Tests passed — unit" from a build/test the session ran, or a `mochi_hook report`.
  String? lastBuildTest;

  /// Claude's summary of the last finished turn, while summaries are shared.
  TurnSummary? summary;
  DateTime? summaryAt;

  /// Names of files changed in the summarized turn.
  List<String> summaryFiles = const [];

  /// "mac-Tamagotchi", or "Session 1a2b3c" before the project is known.
  String get displayName => project ?? 'Session ${id.length > 6 ? id.substring(0, 6) : id}';

  bool get isLive => phase != SessionPhase.ended && endedAt == null;

  static const Duration staleAfter = Duration(minutes: 20);

  bool isStale(DateTime now) => (phase.isWorking || phase == SessionPhase.waitingForUser) && now.difference(lastEventAt) > staleAfter;

  /// working · waiting · done · error · idle: the phone's words (Swift `LiveActivityPlanner.phase(of:)`).
  String get phoneSessionPhase => switch (phase) {
    SessionPhase.promptSubmitted || SessionPhase.thinking || SessionPhase.runningTool => 'working',
    SessionPhase.waitingForUser => 'waiting',
    SessionPhase.turnCompleted => 'done',
    SessionPhase.turnFailed => 'error',
    SessionPhase.idle || SessionPhase.ended => 'idle',
  };

  /// When the current phase began (stable while it lasts).
  DateTime get phaseSince => switch (phase) {
    SessionPhase.promptSubmitted || SessionPhase.thinking || SessionPhase.runningTool => turnStartedAt ?? lastEventAt,
    SessionPhase.turnCompleted => lastTurnCompletedAt ?? lastEventAt,
    _ => lastEventAt,
  };

  /// A plain status line ("Running Bash", "Waiting for your permission (Bash)").
  String statusLine(DateTime now) {
    if (isStale(now)) return 'No events for a while: the session may have closed';
    switch (phase) {
      case SessionPhase.idle:
        return startObserved ? 'Session open' : 'Session detected';
      case SessionPhase.promptSubmitted:
        return 'Prompt received';
      case SessionPhase.thinking:
        return consecutiveFailures >= SessionRegistry.detectiveFailureThreshold ? 'Working after several tool errors' : 'Working';
      case SessionPhase.runningTool:
        if (runningTools.length > 1) return 'Running ${runningTools.length} tools';
        return 'Running ${friendlyToolName(currentTool?.name ?? 'a tool')}';
      case SessionPhase.waitingForUser:
        return switch (waitingFor) {
          Attention.permission =>
            waitingTool == null ? 'Waiting for your permission' : 'Waiting for your permission (${friendlyToolName(waitingTool!)})',
          Attention.input => 'Waiting for your input',
          Attention.mcpDialog => 'An MCP server is waiting for input',
          Attention.backgroundAgent => 'A background agent needs input',
          null => 'Waiting for you',
        };
      case SessionPhase.turnCompleted:
        return 'Turn complete';
      case SessionPhase.turnFailed:
        return turnFailureReason == null
            ? 'Turn ended with an API error'
            : 'Turn ended with an API error (${turnFailureReason!.replaceAll('_', ' ')})';
      case SessionPhase.ended:
        return 'Session ended';
    }
  }

  /// "github (MCP)" for `mcp__github__…`.
  static String friendlyToolName(String name) {
    if (!name.startsWith('mcp__')) return name;
    final parts = name.split('__').where((part) => part.isNotEmpty).toList();
    return parts.length >= 3 ? '${parts.sublist(2).join('_')} (MCP)' : 'an MCP tool';
  }
}

/// What changed when an event was applied.
class SessionTransition {
  const SessionTransition({
    required this.session,
    required this.previous,
    required this.kind,
    required this.isNew,
    required this.delivery,
    this.turnDuration,
  });

  final ClaudeSession session;
  final SessionPhase? previous;
  final EventKind kind;
  final bool isNew;
  final Delivery delivery;
  final Duration? turnDuration;

  SessionPhase get phase => session.phase;
  bool get phaseChanged => previous != session.phase;
}

/// Tracks each session independently (Swift `SessionRegistry`).
class SessionRegistry {
  static const int detectiveFailureThreshold = 3;
  static const Duration endedRetention = Duration(minutes: 30);
  static const Duration idleRetention = Duration(hours: 6);

  final Map<String, ClaudeSession> _sessions = {};

  /// Newest activity first.
  List<ClaudeSession> get all => _sessions.values.toList()..sort((a, b) => b.lastEventAt.compareTo(a.lastEventAt));

  /// Sessions that haven't ended, newest first.
  List<ClaudeSession> get live => all.where((session) => session.isLive).toList();

  ClaudeSession? operator [](String id) => _sessions[id];

  /// Reports without a session attach to the newest session of the same project.
  String? _sessionId(WireEvent event) {
    if (event.session != null) return event.session;
    if (EventKind.of(event) != EventKind.report || event.projectKey == null) return null;
    final candidates = _sessions.values.where((s) => s.projectKey == event.projectKey && s.phase != SessionPhase.ended).toList()
      ..sort((a, b) => b.lastEventAt.compareTo(a.lastEventAt));
    return candidates.firstOrNull?.id;
  }

  SessionTransition? apply(WireEvent event, {Delivery delivery = Delivery.live}) {
    if (event.origin == WireOrigin.ping || event.origin == WireOrigin.simulator) return null;
    final id = _sessionId(event);
    if (id == null) return null;
    final at = DateTime.fromMicrosecondsSinceEpoch((event.ts * 1e6).round());
    final kind = EventKind.of(event);
    final isNew = !_sessions.containsKey(id);
    final session = _sessions[id] ??= ClaudeSession(
      id: id,
      firstSeen: at,
      lastEventAt: at,
      project: event.project,
      projectKey: event.projectKey,
      projectPath: event.projectPath,
    );
    final previous = isNew ? null : session.phase;
    session.project ??= event.project;
    session.projectKey ??= event.projectKey;
    if (event.projectPath != null && session.projectKey == event.projectKey) session.projectPath = event.projectPath;
    // Late events update history but never move a session backwards in time.
    final outOfOrder = at.isBefore(session.lastEventAt.subtract(const Duration(seconds: 1)));
    if (at.isAfter(session.lastEventAt)) session.lastEventAt = at;
    if (event.host != null) session.host = event.host;
    if (delivery == Delivery.late) session.lateEvents++;
    Duration? turnDuration;

    if (!outOfOrder || isNew) {
      switch (kind) {
        case EventKind.sessionStarted:
          session.startObserved = true;
          session.model = event.model ?? session.model;
          if (event.source != 'compact') {
            session.phase = SessionPhase.idle;
            session.runningTools.clear();
            session.currentTool = null;
            session.waitingFor = null;
            session.endedAt = null;
            session.endedReason = null;
          }
        case EventKind.promptSubmitted:
          session.phase = SessionPhase.promptSubmitted;
          session.turnStartedAt = at;
          session.runningTools.clear();
          session.currentTool = null;
          session.waitingFor = null;
          session.waitingTool = null;
          session.toolCallsThisTurn = 0;
          session.consecutiveFailures = 0;
          session.turnFailureReason = null;
        case EventKind.toolStarting:
          final tool = RunningTool(name: event.tool ?? 'tool', category: event.toolCategory ?? 'other', startedAt: at);
          session.runningTools[event.toolUseId ?? 'tool-${event.id}'] = tool;
          session.currentTool = tool;
          session.toolCallsThisTurn++;
          session.waitingFor = null;
          session.waitingTool = null;
          session.phase = SessionPhase.runningTool;
        case EventKind.toolSucceeded || EventKind.toolFailed:
          final useId = event.toolUseId;
          if (useId != null) {
            session.runningTools.remove(useId);
          } else if (event.tool != null) {
            final key = session.runningTools.entries.where((entry) => entry.value.name == event.tool).firstOrNull?.key;
            if (key != null) session.runningTools.remove(key);
          }
          session.currentTool = session.runningTools.values.fold<RunningTool?>(
            null,
            (newest, tool) => newest == null || tool.startedAt.isAfter(newest.startedAt) ? tool : newest,
          );
          session.waitingFor = null;
          session.waitingTool = null;
          if (kind == EventKind.toolFailed && event.isInterrupt != true) {
            session.consecutiveFailures++;
            session.lastFailureAt = at;
          } else if (kind == EventKind.toolSucceeded) {
            session.consecutiveFailures = 0;
          }
          final outcome = buildTestOutcome(event, failed: kind == EventKind.toolFailed);
          if (outcome != null) session.lastBuildTest = outcome;
          if (session.phase != SessionPhase.turnCompleted && session.phase != SessionPhase.ended) {
            session.phase = session.runningTools.isEmpty ? SessionPhase.thinking : SessionPhase.runningTool;
          }
        case EventKind.toolBatchFinished:
          session.runningTools.clear();
          session.currentTool = null;
          if (session.phase == SessionPhase.runningTool || session.phase == SessionPhase.waitingForUser) {
            session.phase = SessionPhase.thinking;
          }
          session.waitingFor = null;
        case EventKind.permissionRequested || EventKind.attentionNeeded:
          session.phase = SessionPhase.waitingForUser;
          session.waitingFor = EventKind.attentionOf(event) ?? Attention.permission;
          if (event.tool != null) session.waitingTool = event.tool;
        case EventKind.subagentStarted:
          session.activeSubagents.add(event.agentId ?? event.id);
          if (session.phase == SessionPhase.idle || session.phase == SessionPhase.turnCompleted) session.phase = SessionPhase.thinking;
        case EventKind.subagentStopped:
          if (event.agentId != null) {
            session.activeSubagents.remove(event.agentId);
          } else if (session.activeSubagents.isNotEmpty) {
            session.activeSubagents.remove(session.activeSubagents.first);
          }
        case EventKind.turnCompleted:
          final start = session.turnStartedAt;
          if (start != null) turnDuration = at.difference(start);
          session.phase = SessionPhase.turnCompleted;
          session.lastTurnCompletedAt = at;
          session.turnsCompleted++;
          session.runningTools.clear();
          session.currentTool = null;
          session.waitingFor = null;
          session.waitingTool = null;
          session.activeSubagents.clear();
        case EventKind.turnFailed:
          session.phase = SessionPhase.turnFailed;
          session.turnFailureReason = event.reason;
          session.runningTools.clear();
          session.currentTool = null;
          session.waitingFor = null;
        case EventKind.sessionEnded:
          session.phase = SessionPhase.ended;
          session.endedAt = at;
          session.endedReason = event.reason;
          session.runningTools.clear();
          session.currentTool = null;
          session.waitingFor = null;
          session.activeSubagents.clear();
        case EventKind.report:
          final report = event.report;
          if (report != null) session.lastBuildTest = reportSummary(report);
        case EventKind.permissionDenied || EventKind.notification || EventKind.unknown:
          break;
      }
    }
    return SessionTransition(
      session: session,
      previous: previous,
      kind: kind,
      isNew: isNew,
      delivery: delivery,
      turnDuration: turnDuration,
    );
  }

  /// "Tests passed" / "Build failed" for a recognised build or test command whose exit status can be trusted.
  static String? buildTestOutcome(WireEvent event, {required bool failed}) {
    final kind = event.commandKind;
    if (kind == null || event.commandReliable != true || event.backgrounded == true) return null;
    final what = kind == 'test' ? 'Tests' : 'Build';
    return failed ? '$what failed' : '$what passed';
  }

  static String reportSummary(WireReport report) {
    final label = report.label == null ? '' : ' (${report.label})';
    return switch ((report.kind, report.status)) {
      ('build', 'failed') => 'Build failed$label',
      ('build', _) => 'Build passed$label',
      ('test', 'failed') => 'Tests failed$label',
      ('test', _) => 'Tests passed$label',
      ('milestone', _) => 'Milestone reached$label',
      _ => 'Commit recorded$label',
    };
  }

  /// Drops ended and long-idle sessions.
  void prune(DateTime now) {
    _sessions.removeWhere((_, session) {
      if (session.phase == SessionPhase.ended) return now.difference(session.endedAt ?? session.lastEventAt) >= endedRetention;
      return now.difference(session.lastEventAt) >= idleRetention;
    });
  }

  void clear() => _sessions.clear();

  /// The session Mochi represents (Swift `primarySession`): waiting for you › failed recently › working › finished
  /// in the last 5 minutes › idle › recently ended; ties go to the newest.
  ClaudeSession? primary(DateTime now) {
    ClaudeSession? best;
    for (final session in _sessions.values) {
      if (best == null) {
        best = session;
        continue;
      }
      final a = rank(session, now), b = rank(best, now);
      if (a > b || (a == b && session.lastEventAt.isAfter(best.lastEventAt))) best = session;
    }
    return best;
  }

  static int rank(ClaudeSession session, DateTime now) {
    final stale = session.isStale(now);
    switch (session.phase) {
      case SessionPhase.waitingForUser:
        return stale ? 2 : 6;
      case SessionPhase.turnFailed:
        return now.difference(session.lastEventAt) < const Duration(minutes: 5) ? 5 : 2;
      case SessionPhase.promptSubmitted || SessionPhase.thinking || SessionPhase.runningTool:
        if (stale) return 2;
        final failure = session.lastFailureAt;
        if (failure != null && now.difference(failure) < const Duration(minutes: 1)) return 5;
        return 4;
      case SessionPhase.turnCompleted:
        return now.difference(session.lastTurnCompletedAt ?? session.lastEventAt) < const Duration(minutes: 5) ? 3 : 2;
      case SessionPhase.idle:
        return 2;
      case SessionPhase.ended:
        return now.difference(session.endedAt ?? session.lastEventAt) < const Duration(minutes: 2) ? 1 : 0;
    }
  }

  /// What Claude is doing, for the phones' room (Swift `ClaudeMirror.from(sessions:)`): the newest live session's
  /// phase and kind of tool, never what it's working on.
  ClaudeMirror mirror({bool resting = false, DateTime? now}) {
    final session = live.firstOrNull;
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000;
    if (session == null) return ClaudeMirror(phase: 'none', resting: resting, at: at);
    return switch (session.phase) {
      SessionPhase.promptSubmitted || SessionPhase.thinking => ClaudeMirror(phase: 'working', category: 'think', resting: resting, at: at),
      SessionPhase.runningTool => ClaudeMirror(
        phase: 'working',
        category: session.currentTool?.category ?? 'other',
        resting: resting,
        at: at,
      ),
      SessionPhase.waitingForUser => ClaudeMirror(phase: 'waiting', resting: resting, at: at),
      SessionPhase.turnCompleted => ClaudeMirror(phase: 'done', resting: resting, at: at),
      SessionPhase.turnFailed => ClaudeMirror(phase: 'error', resting: resting, at: at),
      SessionPhase.idle || SessionPhase.ended => ClaudeMirror(phase: 'idle', resting: resting, at: at),
    };
  }
}
