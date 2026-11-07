// Port of Sources/TamagotchiCore/Sessions/SessionRegistry.swift: each Claude Code session's observed phase, its turn
// (start seen live, duration, tool errors in a row, detective mode, build/test results) and which session the scene
// represents.

import 'events.dart';

/// The observed phase of one Claude Code session.
enum SessionPhase {
  /// Session detected; no turn in progress.
  idle,

  /// A prompt was submitted; Claude has not used a tool yet.
  promptSubmitted,

  /// A turn is in progress and no tool is currently running.
  thinking,

  /// At least one tool call has started and not yet reported back.
  runningTool,

  /// Claude Code reported it is waiting on the user.
  waitingForUser,

  /// `Stop` received: the turn finished.
  turnCompleted,

  /// `StopFailure` received: the turn ended with an API error.
  turnFailed,
  ended;

  bool get isWorking => this == promptSubmitted || this == thinking || this == runningTool;
}

class RunningTool {
  const RunningTool({required this.name, required this.category, required this.startedAt});
  final String name;
  final ToolCategory category;
  final DateTime startedAt;
}

double _since(DateTime now, DateTime then) => now.difference(then).inMicroseconds / 1e6;

class SessionSnapshot {
  SessionSnapshot({required this.id, this.project, required this.firstSeen, required this.lastEventAt, required this.isSimulated});

  final String id;
  ProjectRef? project;
  SessionPhase phase = SessionPhase.idle;

  /// Insertion-ordered (Swift's dictionary order is unspecified; nothing observable depends on it).
  Map<String, RunningTool> runningTools = {};

  /// The most recently started tool, for display.
  RunningTool? currentTool;
  AttentionKind? waitingFor;
  String? waitingTool;
  final DateTime firstSeen;
  DateTime lastEventAt;

  /// True when this session's SessionStart was observed (not joined mid-way).
  bool startObserved = false;
  DateTime? turnStartedAt;

  /// The turn's prompt was observed live (not late or restored), so its duration can be trusted for "long turn"
  /// celebrations.
  bool turnStartObservedLive = false;
  DateTime? lastTurnCompletedAt;
  int turnsCompleted = 0;
  int toolCallsThisTurn = 0;
  int failuresThisTurn = 0;
  int consecutiveFailures = 0;

  /// Detective mode was entered at some point during the current turn.
  bool investigatedThisTurn = false;
  DateTime? lastFailureAt;
  String? lastFailureSummary;
  Set<String> activeSubagents = {};

  /// A build/test outcome actually received during the current (or last) turn.
  BuildTestOutcome? lastBuildTest;
  BuildTestOutcome? buildTestThisTurn;
  String lastEventSummary = '';
  EventKind? lastEventKind;
  String? model;

  /// The app the session runs in (VS Code, Terminal, …), when known.
  String? hostApp;
  String? endedReason;
  DateTime? endedAt;
  final bool isSimulated;
  int lateEvents = 0;
  String? turnFailureReason;

  String get displayName => project?.displayName ?? 'Session ${id.length > 6 ? id.substring(0, 6) : id}';

  /// Detective mode: several tool failures in the current turn while it continues.
  bool get isInvestigating => phase.isWorking && consecutiveFailures >= SessionRegistry.detectiveFailureThreshold;

  bool isStale(DateTime now, {double after = SessionRegistry.staleAfter}) =>
      (phase.isWorking || phase == SessionPhase.waitingForUser) && _since(now, lastEventAt) > after;

  /// Plain-language status line, e.g. "Running Bash" or "Waiting for your permission".
  String statusLine(DateTime now) {
    if (isStale(now)) return 'No events for a while — the session may have closed';
    switch (phase) {
      case SessionPhase.idle:
        return startObserved ? 'Session open' : 'Session detected';
      case SessionPhase.promptSubmitted:
        return 'Prompt received';
      case SessionPhase.thinking:
        return isInvestigating ? 'Working after several tool errors' : 'Working';
      case SessionPhase.runningTool:
        final name = currentTool == null ? 'a tool' : EventNormalizer.friendlyToolName(currentTool!.name);
        if (runningTools.length > 1) return 'Running ${runningTools.length} tools';
        return 'Running $name';
      case SessionPhase.waitingForUser:
        return switch (waitingFor) {
          AttentionKind.permission =>
            waitingTool == null ? 'Waiting for your permission' : 'Waiting for your permission (${EventNormalizer.friendlyToolName(waitingTool!)})',
          AttentionKind.input => 'Waiting for your input',
          AttentionKind.mcpDialog => 'An MCP server is waiting for input',
          AttentionKind.backgroundAgent => 'A background agent needs input',
          null => 'Waiting for you',
        };
      case SessionPhase.turnCompleted:
        return 'Turn complete';
      case SessionPhase.turnFailed:
        return 'Turn ended with an API error';
      case SessionPhase.ended:
        return 'Session ended';
    }
  }
}

/// What changed when an event was applied.
class SessionTransition {
  const SessionTransition({
    required this.sessionID,
    this.previousPhase,
    required this.phase,
    required this.isNewSession,
    required this.startedInvestigating,
    this.turnDuration,
    required this.turnDurationTrusted,
  });

  final String sessionID;
  final SessionPhase? previousPhase;
  final SessionPhase phase;
  final bool isNewSession;

  /// The event was the first of a new run of tool failures reaching the detective threshold.
  final bool startedInvestigating;
  final double? turnDuration;
  final bool turnDurationTrusted;
}

/// Tracks each session independently. Events are only ever applied to the session they carry, so activity from
/// different projects is never merged.
class SessionRegistry {
  static const int detectiveFailureThreshold = 3;
  static const double staleAfter = 20 * 60;
  static const double endedRetention = 30 * 60;
  static const double idleRetention = 6 * 3600;

  final Map<String, SessionSnapshot> sessions = {};

  /// Explicit reports that arrive without a session are attached to the most recently active session of the same
  /// project, or kept here.
  final List<CompanionEvent> unattachedReports = [];

  /// Most recent first.
  List<SessionSnapshot> get all => sessions.values.toList()..sort((a, b) => b.lastEventAt.compareTo(a.lastEventAt));

  SessionSnapshot? operator [](String id) => sessions[id];

  /// Resolves which session an event belongs to (explicit reports may carry none).
  String? sessionIDFor(CompanionEvent event) {
    if (event.sessionID != null) return event.sessionID;
    final key = event.project?.key;
    if (event.kind != EventKind.report || key == null) return null;
    SessionSnapshot? best;
    for (final s in sessions.values) {
      if (s.project?.key != key || s.phase == SessionPhase.ended || s.isSimulated != event.isSimulated) continue;
      if (best == null || best.lastEventAt.isBefore(s.lastEventAt)) best = s;
    }
    return best?.id;
  }

  SessionTransition? apply(CompanionEvent event) {
    final id = sessionIDFor(event);
    if (id == null) {
      if (event.kind == EventKind.report) {
        unattachedReports.add(event);
        if (unattachedReports.length > 20) unattachedReports.removeAt(0);
      }
      return null;
    }
    final isNew = sessions[id] == null;
    final session = sessions[id] ??
        SessionSnapshot(id: id, project: event.project, firstSeen: event.timestamp, lastEventAt: event.timestamp, isSimulated: event.isSimulated);
    final previous = isNew ? null : session.phase;
    session.project ??= event.project;
    if (event.project?.path != null && session.project?.key == event.project?.key) session.project = event.project;
    // Late events update history but never move a session backwards in time.
    final isOutOfOrder = event.timestamp.isBefore(session.lastEventAt.subtract(const Duration(seconds: 1)));
    if (event.timestamp.isAfter(session.lastEventAt)) session.lastEventAt = event.timestamp;
    session.lastEventSummary = event.summary;
    session.lastEventKind = event.kind;
    if (event.metadata['host'] case final host?) session.hostApp = host;
    if (event.delivery == EventDelivery.late) session.lateEvents += 1;

    var startedInvestigating = false;
    double? turnDuration;
    var turnDurationTrusted = false;

    if (!isOutOfOrder || isNew) {
      switch (event.kind) {
        case EventKind.sessionStarted:
          session.startObserved = true;
          session.model = event.metadata['model'] ?? session.model;
          if (event.metadata['source'] != 'compact') {
            session.phase = SessionPhase.idle;
            session.runningTools = {};
            session.currentTool = null;
            session.waitingFor = null;
            session.endedAt = null;
            session.endedReason = null;
          }

        case EventKind.promptSubmitted:
          session.phase = SessionPhase.promptSubmitted;
          session.turnStartedAt = event.timestamp;
          session.turnStartObservedLive = event.delivery == EventDelivery.live;
          session.runningTools = {};
          session.currentTool = null;
          session.waitingFor = null;
          session.waitingTool = null;
          session.toolCallsThisTurn = 0;
          session.failuresThisTurn = 0;
          session.consecutiveFailures = 0;
          session.investigatedThisTurn = false;
          session.buildTestThisTurn = null;
          session.turnFailureReason = null;

        case EventKind.toolStarting:
          final tool = RunningTool(name: event.toolName ?? 'tool', category: event.toolCategory ?? ToolCategory.other, startedAt: event.timestamp);
          session.runningTools[event.toolUseID ?? 'tool-${event.id}'] = tool;
          session.currentTool = tool;
          session.toolCallsThisTurn += 1;
          session.waitingFor = null;
          session.waitingTool = null;
          session.phase = SessionPhase.runningTool;

        case EventKind.toolSucceeded || EventKind.toolFailed:
          if (event.toolUseID case final toolUseID?) {
            session.runningTools.remove(toolUseID);
          } else if (event.toolName case final name?) {
            final key = session.runningTools.entries.where((e) => e.value.name == name).map((e) => e.key).firstOrNull;
            if (key != null) session.runningTools.remove(key);
          }
          RunningTool? latest;
          for (final tool in session.runningTools.values) {
            if (latest == null || latest.startedAt.isBefore(tool.startedAt)) latest = tool;
          }
          session.currentTool = latest;
          session.waitingFor = null;
          session.waitingTool = null;
          if (event.kind == EventKind.toolFailed && !event.interrupted) {
            session.failuresThisTurn += 1;
            session.consecutiveFailures += 1;
            session.lastFailureAt = event.timestamp;
            session.lastFailureSummary = event.summary;
            startedInvestigating = session.consecutiveFailures == detectiveFailureThreshold;
            if (startedInvestigating) session.investigatedThisTurn = true;
          } else if (event.kind == EventKind.toolSucceeded) {
            session.consecutiveFailures = 0;
          }
          if (event.buildTestOutcome case final outcome?) {
            session.lastBuildTest = outcome;
            session.buildTestThisTurn = outcome;
          }
          if (session.phase != SessionPhase.turnCompleted && session.phase != SessionPhase.ended) {
            session.phase = session.runningTools.isEmpty ? SessionPhase.thinking : SessionPhase.runningTool;
          }

        case EventKind.toolBatchFinished:
          session.runningTools = {};
          session.currentTool = null;
          if (session.phase == SessionPhase.runningTool || session.phase == SessionPhase.waitingForUser) session.phase = SessionPhase.thinking;
          session.waitingFor = null;

        case EventKind.permissionRequested || EventKind.attentionNeeded:
          session.phase = SessionPhase.waitingForUser;
          session.waitingFor = event.attention ?? AttentionKind.permission;
          if (event.toolName case final tool?) session.waitingTool = tool;

        case EventKind.subagentStarted:
          session.activeSubagents.add(event.metadata['agentId'] ?? event.id);
          if (session.phase == SessionPhase.idle || session.phase == SessionPhase.turnCompleted) session.phase = SessionPhase.thinking;

        case EventKind.subagentStopped:
          if (event.metadata['agentId'] case final agent?) {
            session.activeSubagents.remove(agent);
          } else if (session.activeSubagents.isNotEmpty) {
            session.activeSubagents.remove(session.activeSubagents.first);
          }

        case EventKind.turnCompleted:
          if (session.turnStartedAt case final start?) {
            turnDuration = _since(event.timestamp, start);
            turnDurationTrusted = session.turnStartObservedLive && event.delivery == EventDelivery.live;
          }
          session.phase = SessionPhase.turnCompleted;
          session.lastTurnCompletedAt = event.timestamp;
          session.turnsCompleted += 1;
          session.runningTools = {};
          session.currentTool = null;
          session.waitingFor = null;
          session.waitingTool = null;
          session.activeSubagents = {};

        case EventKind.turnFailed:
          session.phase = SessionPhase.turnFailed;
          session.turnFailureReason = event.metadata['reason'];
          session.runningTools = {};
          session.currentTool = null;
          session.waitingFor = null;

        case EventKind.sessionEnded:
          session.phase = SessionPhase.ended;
          session.endedAt = event.timestamp;
          session.endedReason = event.metadata['reason'];
          session.runningTools = {};
          session.currentTool = null;
          session.waitingFor = null;
          session.activeSubagents = {};

        case EventKind.report:
          if (event.buildTestOutcome case final outcome?) {
            session.lastBuildTest = outcome;
            session.buildTestThisTurn = outcome;
          }

        case EventKind.permissionDenied || EventKind.notification || EventKind.unknown:
          break;
      }
    }

    sessions[id] = session;
    return SessionTransition(
      sessionID: id,
      previousPhase: previous,
      phase: session.phase,
      isNewSession: isNew,
      startedInvestigating: startedInvestigating,
      turnDuration: turnDuration,
      turnDurationTrusted: turnDurationTrusted,
    );
  }

  /// Drops ended and long-idle sessions.
  void prune(DateTime now) {
    sessions.removeWhere((_, session) {
      if (session.phase == SessionPhase.ended) return !(_since(now, session.endedAt ?? session.lastEventAt) < endedRetention);
      return !(_since(now, session.lastEventAt) < idleRetention);
    });
  }

  void removeWhere(bool Function(SessionSnapshot) predicate) => sessions.removeWhere((_, s) => predicate(s));

  void removeAll() {
    sessions.clear();
    unattachedReports.clear();
  }

  // MARK: Primary session

  /// The documented rule for which session the scene represents:
  ///
  /// 1. A session the user pinned, while it has not ended.
  /// 2. Otherwise the highest-ranked session: waiting for the user › turn failed or tool failure in the last minute ›
  ///    working › turn completed in the last 5 minutes › open/idle › recently ended.
  /// 3. Ties go to the session with the most recent event.
  ///
  /// Stale sessions (working but silent for 20 minutes) rank as idle.
  SessionSnapshot? primarySession({String? pinned, required DateTime now}) {
    if (pinned != null) {
      final session = sessions[pinned];
      if (session != null && session.phase != SessionPhase.ended) return session;
    }
    SessionSnapshot? best;
    var bestRank = -1;
    for (final s in sessions.values) {
      final r = rank(s, now);
      if (best == null || r > bestRank || (r == bestRank && best.lastEventAt.isBefore(s.lastEventAt))) {
        best = s;
        bestRank = r;
      }
    }
    return best;
  }

  static int rank(SessionSnapshot session, DateTime now) {
    final stale = session.isStale(now);
    switch (session.phase) {
      case SessionPhase.waitingForUser:
        return stale ? 2 : 6;
      case SessionPhase.turnFailed:
        return _since(now, session.lastEventAt) < 300 ? 5 : 2;
      case SessionPhase.promptSubmitted || SessionPhase.thinking || SessionPhase.runningTool:
        if (stale) return 2;
        if (session.lastFailureAt case final failure? when _since(now, failure) < 60) return 5;
        return 4;
      case SessionPhase.turnCompleted:
        final completed = session.lastTurnCompletedAt ?? session.lastEventAt;
        return _since(now, completed) < 300 ? 3 : 2;
      case SessionPhase.idle:
        return 2;
      case SessionPhase.ended:
        return _since(now, session.endedAt ?? session.lastEventAt) < 120 ? 1 : 0;
    }
  }

  /// Sessions that should keep the companion around.
  bool hasLiveSessions(DateTime now) => sessions.values.any((s) => s.phase != SessionPhase.ended && _since(now, s.lastEventAt) < 3600);
}
