// Port of Sources/TamagotchiCore/Events/CompanionEvent.swift and EventNormalizer.swift: what actually happened,
// normalized from a Claude Code hook event (mochi_wire's WireEvent, given here as its JSON) or an explicit report.

import '../model/random.dart' show unsignedString;

/// What actually happened. These kinds are intentionally not interchangeable: a successful tool call is not a finished
/// turn, and a finished turn says nothing about builds or tests.
enum EventKind {
  sessionStarted,
  promptSubmitted,
  toolStarting,
  toolSucceeded,
  toolFailed,
  toolBatchFinished,
  permissionRequested,
  permissionDenied,

  /// Claude Code is waiting on the user (permission prompt, idle input, MCP dialog).
  attentionNeeded,

  /// Informational notification (e.g. auth success, background agent finished).
  notification,
  subagentStarted,
  subagentStopped,

  /// `Stop`: Claude finished responding to the turn.
  turnCompleted,

  /// `StopFailure`: the turn ended because of an API error.
  turnFailed,
  sessionEnded,

  /// An explicit build/test/milestone/commit result.
  report,

  /// Recognized wire envelope, unknown event name. Recorded for diagnostics only.
  unknown,
}

enum EventOrigin { claudeHook, explicitReport, simulator }

enum EventDelivery {
  /// Delivered while it happened.
  live,

  /// Spooled while the app was not running and delivered afterwards.
  late,

  /// Replayed from history at launch to rebuild session state.
  restored,
}

/// How much the event says on its own.
enum EventConfidence { reported, derived }

enum ToolCategory {
  read,
  search,
  edit,
  shell,
  web,
  agent,
  plan,
  ask,
  skill,
  mcp,
  other;

  static ToolCategory fromWire(String? wire) => values.firstWhere((c) => c.name == wire, orElse: () => ToolCategory.other);
}

enum AttentionKind { permission, input, mcpDialog, backgroundAgent }

enum CommandKind { build, test }

enum ReportKind { build, test, milestone, commit }

enum ReportStatus { passed, failed, reached }

class ExplicitReport {
  const ExplicitReport({required this.kind, required this.status, this.label});

  final ReportKind kind;
  final ReportStatus status;
  final String? label;

  bool get isSuccess => status != ReportStatus.failed;

  @override
  bool operator ==(Object other) => other is ExplicitReport && other.kind == kind && other.status == status && other.label == label;

  @override
  int get hashCode => Object.hash(kind, status, label);
}

class ProjectRef {
  const ProjectRef({required this.displayName, required this.key, this.path});

  final String displayName;
  final String key;

  /// Full path, held in memory only.
  final String? path;

  @override
  bool operator ==(Object other) => other is ProjectRef && other.displayName == displayName && other.key == key && other.path == path;

  @override
  int get hashCode => Object.hash(displayName, key, path);
}

enum BuildTestSource {
  /// Sent by the user's script with `report`.
  explicitReport,

  /// A shell command Claude ran, recognized as a build/test, with a trustworthy exit status.
  claudeCommand,
}

class BuildTestOutcome {
  const BuildTestOutcome({required this.kind, required this.passed, required this.source, this.label, required this.at});

  final CommandKind kind;
  final bool passed;
  final BuildTestSource source;
  final String? label;
  final DateTime at;

  String get summary {
    final noun = kind == CommandKind.test ? 'Test' : 'Build';
    switch (source) {
      case BuildTestSource.explicitReport:
        final name = label == null ? '' : ' ($label)';
        return passed ? '$noun passed$name — reported by your script' : '$noun failed$name — reported by your script';
      case BuildTestSource.claudeCommand:
        return passed
            ? 'A ${noun.toLowerCase()} command Claude ran exited successfully'
            : 'A ${noun.toLowerCase()} command Claude ran exited with an error';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BuildTestOutcome &&
      other.kind == kind &&
      other.passed == passed &&
      other.source == source &&
      other.label == label &&
      other.at == at;

  @override
  int get hashCode => Object.hash(kind, passed, source, label, at);
}

/// One normalized event (Swift `CompanionEvent`).
class CompanionEvent {
  CompanionEvent({
    required this.id,
    required this.kind,
    required this.rawName,
    required this.timestamp,
    required this.receivedAt,
    this.sessionID,
    this.project,
    this.toolName,
    this.toolCategory,
    this.toolUseID,
    this.attention,
    this.report,
    this.commandKind,
    this.commandReliable = false,
    this.exitCode,
    this.interrupted = false,
    this.inSubagent = false,
    this.metadata = const {},
    this.message,
    required this.origin,
    this.delivery = EventDelivery.live,
    this.schemaVersion = 1,
    this.confidence = EventConfidence.reported,
    this.summary = '',
  });

  final String id;
  final EventKind kind;
  final String rawName;
  final DateTime timestamp;
  final DateTime receivedAt;
  final String? sessionID;
  final ProjectRef? project;
  final String? toolName;
  final ToolCategory? toolCategory;
  final String? toolUseID;
  final AttentionKind? attention;
  final ExplicitReport? report;
  final CommandKind? commandKind;

  /// Whether the command's exit status reflects the build/test result.
  final bool commandReliable;
  final int? exitCode;
  final bool interrupted;
  final bool inSubagent;

  /// Small, sanitized extras such as `source`, `reason`, `notificationType`, `agentType`, `model`.
  final Map<String, String> metadata;

  /// Claude Code's short notification text, if any.
  final String? message;
  final EventOrigin origin;
  EventDelivery delivery;
  final int schemaVersion;
  final EventConfidence confidence;

  /// A short, honest description of what was observed.
  String summary;

  bool get isSimulated => origin == EventOrigin.simulator;

  /// A build/test outcome this event genuinely carries, if any.
  BuildTestOutcome? get buildTestOutcome {
    final report = this.report;
    if (report != null && (report.kind == ReportKind.build || report.kind == ReportKind.test)) {
      return BuildTestOutcome(
        kind: report.kind == ReportKind.build ? CommandKind.build : CommandKind.test,
        passed: report.status != ReportStatus.failed,
        source: BuildTestSource.explicitReport,
        label: report.label,
        at: timestamp,
      );
    }
    final commandKind = this.commandKind;
    if (commandKind != null && commandReliable && (kind == EventKind.toolSucceeded || kind == EventKind.toolFailed) && !interrupted) {
      return BuildTestOutcome(
        kind: commandKind,
        passed: kind == EventKind.toolSucceeded,
        source: BuildTestSource.claudeCommand,
        at: timestamp,
      );
    }
    return null;
  }

  CompanionEvent withDelivery(EventDelivery delivery) => CompanionEvent(
    id: id,
    kind: kind,
    rawName: rawName,
    timestamp: timestamp,
    receivedAt: receivedAt,
    sessionID: sessionID,
    project: project,
    toolName: toolName,
    toolCategory: toolCategory,
    toolUseID: toolUseID,
    attention: attention,
    report: report,
    commandKind: commandKind,
    commandReliable: commandReliable,
    exitCode: exitCode,
    interrupted: interrupted,
    inSubagent: inSubagent,
    metadata: metadata,
    message: message,
    origin: origin,
    delivery: delivery,
    schemaVersion: schemaVersion,
    confidence: confidence,
    summary: summary,
  );
}

/// Converts wire events (the JSON of mochi_wire's `WireEvent` / Swift's `WireEvent`) into [CompanionEvent]s with honest
/// summaries (Swift `EventNormalizer`).
abstract final class EventNormalizer {
  /// [wire] is a WireEvent's JSON (`WireEvent.toJson()` in mochi_wire). Returns null for a ping (which only says the
  /// connection is alive) or for JSON without the envelope's required fields.
  static CompanionEvent? normalize(Map<String, Object?> wire, {required DateTime receivedAt, EventDelivery delivery = EventDelivery.live}) {
    final id = wire['id'], ts = wire['ts'], originName = wire['origin'], name = wire['event'];
    if (id is! String || ts is! num || originName is! String || name is! String) return null;
    final origin = switch (originName) {
      'hook' || 'ping' => EventOrigin.claudeHook,
      'report' => EventOrigin.explicitReport,
      'simulator' => EventOrigin.simulator,
      _ => null,
    };
    if (origin == null) return null;
    String? s(String key) => wire[key] is String ? wire[key] as String : null;
    bool? b(String key) => wire[key] is bool ? wire[key] as bool : null;
    int? n(String key) => wire[key] is num ? (wire[key] as num).toInt() : null;

    final projectPath = s('projectPath');
    final key = s('projectKey') ?? (projectPath == null ? null : projectKeyForPath(projectPath));
    final project = key == null
        ? null
        : ProjectRef(displayName: s('project') ?? (projectPath == null ? null : displayNameForPath(projectPath)) ?? 'Project', key: key, path: projectPath);

    final metadata = <String, String>{};
    void put(String key, String? value) {
      if (value != null) metadata[key] = value;
    }

    put('source', s('source'));
    put('reason', s('reason'));
    put('notificationType', s('notificationType'));
    put('agentType', s('agentType'));
    put('agentId', s('agentId'));
    put('model', s('model'));
    put('permissionMode', s('permissionMode'));
    put('host', s('host'));
    if (n('batchCount') case final count?) metadata['batchCount'] = '$count';
    if (wire['batchTools'] case final List<Object?> tools when tools.isNotEmpty) metadata['batchTools'] = tools.whereType<String>().join(',');
    if (n('durationMs') case final duration?) metadata['durationMs'] = '$duration';
    if (b('backgrounded') == true) metadata['background'] = 'true';

    final report = switch (wire['report']) {
      final Map<Object?, Object?> r => _report(r),
      _ => null,
    };
    final hasReport = wire['report'] is Map;
    final kind = _kind(origin: originName, event: name, hasReport: hasReport, notificationType: s('notificationType'));
    final tool = s('tool');
    final commandKind = switch (s('commandKind')) {
      'build' => CommandKind.build,
      'test' => CommandKind.test,
      _ => null,
    };
    final event = CompanionEvent(
      id: id,
      kind: kind,
      rawName: name,
      timestamp: _date(ts.toDouble()),
      receivedAt: receivedAt,
      sessionID: s('session'),
      project: project,
      toolName: tool,
      toolCategory: tool == null ? null : ToolCategory.fromWire(s('toolCategory')),
      toolUseID: s('toolUseId'),
      attention: _attention(name, s('notificationType')),
      report: report,
      commandKind: commandKind,
      commandReliable: b('commandReliable') == true && b('backgrounded') != true,
      exitCode: n('exitCode'),
      interrupted: b('isInterrupt') == true,
      inSubagent: b('inSubagent') == true,
      metadata: metadata,
      message: s('message'),
      origin: origin,
      delivery: delivery,
      schemaVersion: n('v') ?? 1,
      confidence: commandKind != null ? EventConfidence.derived : EventConfidence.reported,
    );
    event.summary = summary(event);
    return event;
  }

  /// True for a ping (Swift's `WireOrigin.ping`): it only refreshes the connection.
  static bool isPing(Map<String, Object?> wire) => wire['origin'] == 'ping';

  static DateTime _date(double seconds) => DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round(), isUtc: true);

  static ExplicitReport? _report(Map<Object?, Object?> r) {
    final kind = switch (r['kind']) {
      'build' => ReportKind.build,
      'test' => ReportKind.test,
      'milestone' => ReportKind.milestone,
      'commit' => ReportKind.commit,
      _ => null,
    };
    final status = switch (r['status']) {
      'passed' => ReportStatus.passed,
      'failed' => ReportStatus.failed,
      'reached' => ReportStatus.reached,
      _ => null,
    };
    if (kind == null || status == null) return null;
    final label = r['label'];
    return ExplicitReport(kind: kind, status: status, label: label is String ? label : null);
  }

  static EventKind _kind({required String origin, required String event, required bool hasReport, String? notificationType}) {
    if (origin == 'report' || (event == 'Report' && hasReport)) return EventKind.report;
    return switch (event) {
      'SessionStart' => EventKind.sessionStarted,
      'UserPromptSubmit' => EventKind.promptSubmitted,
      'PreToolUse' => EventKind.toolStarting,
      'PostToolUse' => EventKind.toolSucceeded,
      'PostToolUseFailure' => EventKind.toolFailed,
      'PostToolBatch' => EventKind.toolBatchFinished,
      'PermissionRequest' => EventKind.permissionRequested,
      'PermissionDenied' => EventKind.permissionDenied,
      'Notification' => _attention(event, notificationType) != null ? EventKind.attentionNeeded : EventKind.notification,
      'SubagentStart' => EventKind.subagentStarted,
      'SubagentStop' => EventKind.subagentStopped,
      'Stop' => EventKind.turnCompleted,
      'StopFailure' => EventKind.turnFailed,
      'SessionEnd' => EventKind.sessionEnded,
      _ => EventKind.unknown,
    };
  }

  static AttentionKind? _attention(String event, String? notificationType) {
    switch (event) {
      case 'PermissionRequest':
        return AttentionKind.permission;
      case 'Notification':
        return switch (notificationType) {
          'permission_prompt' => AttentionKind.permission,
          'idle_prompt' => AttentionKind.input,
          'elicitation_dialog' || 'elicitation_url_dialog' => AttentionKind.mcpDialog,
          'agent_needs_input' => AttentionKind.backgroundAgent,
          _ => null,
        };
      default:
        return null;
    }
  }

  static String summary(CompanionEvent event) {
    final tool = event.toolName == null ? 'a tool' : friendlyToolName(event.toolName!);
    final meta = event.metadata;
    switch (event.kind) {
      case EventKind.sessionStarted:
        return switch (meta['source']) {
          'resume' => 'Session resumed',
          'clear' => 'Session cleared and restarted',
          'compact' => 'Context compacted; session continues',
          'fork' => 'Session forked',
          _ => 'Claude Code session started',
        };
      case EventKind.promptSubmitted:
        return 'A prompt was submitted';
      case EventKind.toolStarting:
        if (meta['background'] == 'true') return 'Starting $tool in the background';
        return 'About to use $tool';
      case EventKind.toolSucceeded:
        if (meta['background'] == 'true') return '$tool started a background task';
        if (event.buildTestOutcome case final outcome?) return outcome.summary;
        return '$tool finished';
      case EventKind.toolFailed:
        if (event.interrupted) return '$tool was interrupted';
        if (event.buildTestOutcome case final outcome?) {
          return outcome.summary + (event.exitCode == null ? '' : ' (exit code ${event.exitCode})');
        }
        if (event.exitCode case final code?) return '$tool reported an error (exit code $code)';
        return '$tool reported an error';
      case EventKind.toolBatchFinished:
        final count = int.tryParse(meta['batchCount'] ?? '') ?? 0;
        return count == 1 ? '1 tool call finished' : '$count tool calls finished';
      case EventKind.permissionRequested:
        return 'Claude is asking permission to use $tool';
      case EventKind.permissionDenied:
        return 'Auto mode declined a $tool call';
      case EventKind.attentionNeeded:
        return switch (event.attention) {
          AttentionKind.permission => event.message ?? 'Claude needs your permission',
          AttentionKind.input => 'Claude is waiting for your input',
          AttentionKind.mcpDialog => 'An MCP server is asking for input',
          AttentionKind.backgroundAgent => 'A background agent needs input',
          null => event.message ?? 'Claude needs your attention',
        };
      case EventKind.notification:
        return switch (meta['notificationType']) {
          'auth_success' => 'Authentication succeeded',
          'agent_completed' => 'A background agent finished',
          _ => event.message ?? 'Notification from Claude Code',
        };
      case EventKind.subagentStarted:
        final type = meta['agentType'];
        return type != null && type.isNotEmpty ? 'Subagent started ($type)' : 'Subagent started';
      case EventKind.subagentStopped:
        final type = meta['agentType'];
        return type != null && type.isNotEmpty ? 'Subagent finished ($type)' : 'Subagent finished';
      case EventKind.turnCompleted:
        return 'Claude finished responding';
      case EventKind.turnFailed:
        final reason = meta['reason'];
        return reason != null ? 'Turn ended with an API error (${reason.replaceAll('_', ' ')})' : 'Turn ended with an API error';
      case EventKind.sessionEnded:
        return switch (meta['reason']) {
          'clear' => 'Session cleared',
          'resume' => 'Switched to another session',
          'logout' => 'Logged out; session ended',
          'prompt_input_exit' => 'Session exited',
          _ => 'Session ended',
        };
      case EventKind.report:
        final report = event.report;
        if (report == null) return 'Report received';
        final label = report.label == null ? '' : ' — ${report.label}';
        return switch ((report.kind, report.status)) {
          (ReportKind.build, ReportStatus.failed) => 'Build failed$label',
          (ReportKind.build, _) => 'Build passed$label',
          (ReportKind.test, ReportStatus.failed) => 'Tests failed$label',
          (ReportKind.test, _) => 'Tests passed$label',
          (ReportKind.milestone, _) => 'Milestone reached$label',
          (ReportKind.commit, _) => 'Commit recorded$label',
        };
      case EventKind.unknown:
        return 'Unrecognized event “${event.rawName}”';
    }
  }

  static String friendlyToolName(String name) {
    if (name.startsWith('mcp__')) {
      final parts = name.split('__').where((p) => p.isNotEmpty).toList();
      if (parts.length >= 3) return '${parts.sublist(2).join('_')} (MCP)';
      return 'an MCP tool';
    }
    return name;
  }

  /// Swift `ProjectIdentity.displayName(forPath:)`: the folder's name.
  static String displayNameForPath(String path) {
    final trimmed = path.endsWith('/') || path.endsWith(r'\') ? path.substring(0, path.length - 1) : path;
    final parts = trimmed.split(RegExp(r'[/\\]'));
    return parts.isEmpty || parts.last.isEmpty ? 'Project' : parts.last;
  }

  /// A stand-in key when a wire event carries a path but no key (the hook helpers always send `projectKey`, the
  /// SHA-256 one): a 64-bit FNV-1a of the path, so the path itself is never kept as a key.
  static String projectKeyForPath(String path) {
    var hash = 0xcbf29ce484222325;
    for (final unit in path.codeUnits) {
      hash ^= unit;
      hash *= 0x100000001b3;
    }
    return unsignedString(hash).padLeft(20, '0').substring(0, 10);
  }
}
