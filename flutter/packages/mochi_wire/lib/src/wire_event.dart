import 'dart:convert';

/// Where a wire event came from (Swift `WireOrigin`). Only `hook` and `report` events are real activity.
enum WireOrigin {
  /// Forwarded by `mochi_hook claude-hook` from a Claude Code hook.
  hook,

  /// An explicit build/test/milestone result sent with `mochi_hook report`.
  report,

  /// Made up by a development tool. Never shown as Claude's activity.
  simulator,

  /// A connectivity check from `mochi_hook ping`.
  ping;

  static WireOrigin? tryParse(Object? raw) {
    for (final origin in values) {
      if (origin.name == raw) return origin;
    }
    return null;
  }
}

/// An explicit result reported by the user's own scripts (Swift `WireReport`).
class WireReport {
  const WireReport({required this.kind, required this.status, this.label});

  /// build · test · milestone · commit
  final String kind;

  /// passed · failed · reached
  final String status;
  final String? label;

  static const List<String> kinds = ['build', 'test', 'milestone', 'commit'];
  static const List<String> statuses = ['passed', 'failed', 'reached'];

  Map<String, Object?> toJson() => {'kind': kind, 'label': ?label, 'status': status};

  static WireReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'], status = json['status'], label = json['label'];
    if (kind is! String || status is! String || (label != null && label is! String)) return null;
    return WireReport(kind: kind, status: status, label: label as String?);
  }

  @override
  bool operator ==(Object other) => other is WireReport && other.kind == kind && other.status == status && other.label == label;

  @override
  int get hashCode => Object.hash(kind, status, label);
}

/// The sanitized envelope the hook helper sends the app over the local bridge: Swift `WireEvent`, field for field and
/// with the same JSON (sorted keys, nulls left out).
///
/// It has no fields for prompts, tool inputs, tool output, file contents or transcript paths: the helper drops those
/// before anything leaves the hook process. Claude's closing message ([summary]) and the names of changed files
/// ([file]) are sent only while the user shares summaries with their phone.
class WireEvent {
  WireEvent({
    this.v = currentSchemaVersion,
    required this.id,
    required this.ts,
    required this.origin,
    required this.event,
    this.session,
    this.project,
    this.projectKey,
    this.projectPath,
    this.tool,
    this.toolUseId,
    this.toolCategory,
    this.commandKind,
    this.commandReliable,
    this.backgrounded,
    this.exitCode,
    this.isInterrupt,
    this.durationMs,
    this.notificationType,
    this.message,
    this.agentType,
    this.agentId,
    this.inSubagent,
    this.source,
    this.reason,
    this.model,
    this.permissionMode,
    this.host,
    this.batchCount,
    this.batchTools,
    this.report,
    this.helperVersion,
    this.summary,
    this.file,
  });

  static const int currentSchemaVersion = 1;

  int v;

  /// A digest of the raw hook payload, so a duplicated delivery of one hook invocation has the same id.
  String id;

  /// Unix time (seconds) at which the helper saw the event.
  double ts;
  WireOrigin origin;

  /// The hook event name ("PreToolUse"), or "Report" / "Ping".
  String event;

  String? session;

  /// The project folder's name, for display.
  String? project;

  /// A short one-way hash of the project path.
  String? projectKey;

  /// The project's full path (kept in memory only).
  String? projectPath;

  String? tool;
  String? toolUseId;
  String? toolCategory;

  /// "test" / "build" when a shell command is recognizably one; the command itself is never sent.
  String? commandKind;
  bool? commandReliable;
  bool? backgrounded;
  int? exitCode;
  bool? isInterrupt;
  int? durationMs;

  String? notificationType;

  /// Claude Code's own short notification text ("Claude needs your permission to use Bash").
  String? message;

  String? agentType;
  String? agentId;
  bool? inSubagent;

  /// SessionStart `source` (startup/resume/clear/compact/fork).
  String? source;

  /// SessionEnd `reason`, or StopFailure's error type.
  String? reason;
  String? model;
  String? permissionMode;

  /// The app the session runs in, when the environment says (a macOS bundle id, or `TERM_PROGRAM` on Windows).
  String? host;

  int? batchCount;
  List<String>? batchTools;

  WireReport? report;
  String? helperVersion;

  /// Claude's last message of a turn (Stop), only while summaries are shared. Never spooled.
  String? summary;

  /// The name (never the folder or contents) of a file an editing tool changed, only while summaries are shared.
  String? file;

  /// The event without the summary fields, for anything that is kept.
  WireEvent get withoutSummary => copy()
    ..summary = null
    ..file = null;

  WireEvent copy() => WireEvent.fromJson(toJson())!;

  /// Sorted keys, nulls left out (Swift's `JSONEncoder` with `.sortedKeys`). A whole-number [ts] keeps its `.0`
  /// dropped as Swift writes it.
  Map<String, Object?> toJson() {
    final map = <String, Object?>{
      'agentId': agentId,
      'agentType': agentType,
      'backgrounded': backgrounded,
      'batchCount': batchCount,
      'batchTools': batchTools,
      'commandKind': commandKind,
      'commandReliable': commandReliable,
      'durationMs': durationMs,
      'event': event,
      'exitCode': exitCode,
      'file': file,
      'helperVersion': helperVersion,
      'host': host,
      'id': id,
      'inSubagent': inSubagent,
      'isInterrupt': isInterrupt,
      'message': message,
      'model': model,
      'notificationType': notificationType,
      'origin': origin.name,
      'permissionMode': permissionMode,
      'project': project,
      'projectKey': projectKey,
      'projectPath': projectPath,
      'reason': reason,
      'report': report?.toJson(),
      'session': session,
      'source': source,
      'summary': summary,
      'tool': tool,
      'toolCategory': toolCategory,
      'toolUseId': toolUseId,
      'ts': ts == ts.roundToDouble() && ts.abs() < 1e15 ? ts.toInt() : ts,
      'v': v,
    };
    map.removeWhere((_, value) => value == null);
    return map;
  }

  /// One line for the bridge: the JSON and a newline.
  String encodeLine() => '${jsonEncode(toJson())}\n';

  /// Null when a required field is missing or any field has the wrong type (as Swift's `Decodable` would refuse it).
  static WireEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    T? field<T>(String key) {
      final value = json[key];
      if (value is T) return value;
      if (value == null) return null;
      throw const FormatException('wrong type');
    }

    try {
      final v = field<int>('v'), id = field<String>('id'), ts = field<num>('ts');
      final origin = WireOrigin.tryParse(json['origin']), event = field<String>('event');
      if (v == null || id == null || ts == null || origin == null || event == null) return null;
      final tools = json['batchTools'];
      if (tools != null && (tools is! List || tools.any((tool) => tool is! String))) return null;
      final report = json['report'] == null ? null : WireReport.fromJson(json['report']);
      if (json['report'] != null && report == null) return null;
      return WireEvent(
        v: v,
        id: id,
        ts: ts.toDouble(),
        origin: origin,
        event: event,
        session: field<String>('session'),
        project: field<String>('project'),
        projectKey: field<String>('projectKey'),
        projectPath: field<String>('projectPath'),
        tool: field<String>('tool'),
        toolUseId: field<String>('toolUseId'),
        toolCategory: field<String>('toolCategory'),
        commandKind: field<String>('commandKind'),
        commandReliable: field<bool>('commandReliable'),
        backgrounded: field<bool>('backgrounded'),
        exitCode: field<int>('exitCode'),
        isInterrupt: field<bool>('isInterrupt'),
        durationMs: field<int>('durationMs'),
        notificationType: field<String>('notificationType'),
        message: field<String>('message'),
        agentType: field<String>('agentType'),
        agentId: field<String>('agentId'),
        inSubagent: field<bool>('inSubagent'),
        source: field<String>('source'),
        reason: field<String>('reason'),
        model: field<String>('model'),
        permissionMode: field<String>('permissionMode'),
        host: field<String>('host'),
        batchCount: field<int>('batchCount'),
        batchTools: tools == null ? null : List<String>.from(tools as List),
        report: report,
        helperVersion: field<String>('helperVersion'),
        summary: field<String>('summary'),
        file: field<String>('file'),
      );
    } on FormatException {
      return null;
    }
  }

  static WireEvent? decode(String line) {
    try {
      return fromJson(jsonDecode(line));
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is WireEvent && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => 'WireEvent($event, ${origin.name}${session == null ? '' : ', $session'})';
}

/// The helper's name and version (Swift `HelperInfo`).
abstract final class HelperInfo {
  static const String version = '1.1.0';

  /// The helper's file name without `.exe`. Together with [hookSubcommand] it marks a hook entry as Mochi's, so
  /// removing them never touches anything else (and never the Mac app's `mactamagotchi-hook` entries).
  static const String executableName = 'mochi_hook';

  /// The subcommand in installed hook commands.
  static const String hookSubcommand = 'claude-hook';
}
