import 'dart:convert';

import 'hook_sanitizer.dart';
import 'wire_event.dart';
import 'wire_text.dart';

/// Why a line from the bridge was refused (Swift `EventSchemaValidator.Rejection`).
class WireRejection implements Exception {
  const WireRejection(this.code, this.detail);

  /// The short reason in the bridge's answer: too-large · malformed · unsupported-version · invalid-field ·
  /// bad-timestamp.
  final String code;
  final String detail;

  @override
  String toString() => 'WireRejection($code: $detail)';
}

/// Validates wire lines before anything else in the app sees them (Swift `EventSchemaValidator`).
abstract final class EventValidator {
  /// Upper bound on one line. Sanitized events are well under 2 KB; a summary can be 4 KB.
  static const int maxLineBytes = 32 * 1024;

  static const Duration maxAge = Duration(days: 7);

  static WireEvent decode(String line, {DateTime? now, Duration maxAge = maxAge}) {
    final size = utf8.encode(line).length;
    if (size > maxLineBytes) throw WireRejection('too-large', 'event too large ($size bytes)');
    Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      throw const WireRejection('malformed', 'not JSON');
    }
    final event = WireEvent.fromJson(json);
    if (event == null) throw const WireRejection('malformed', 'missing or mistyped fields');
    validate(event, now: now, maxAge: maxAge);
    return event;
  }

  static void validate(WireEvent event, {DateTime? now, Duration maxAge = maxAge}) {
    // Newer helpers may add fields; a newer major schema is refused.
    if (event.v < 1 || event.v > WireEvent.currentSchemaVersion) {
      throw WireRejection('unsupported-version', 'unsupported schema version ${event.v}');
    }
    void identifier(String? value, int max, String field, {bool required = false}) {
      if (value == null && !required) return;
      if (WireText.identifier(value, maxLength: max) == null) throw WireRejection('invalid-field', "invalid field '$field'");
    }

    void length(String? value, int max, String field) {
      if (value != null && value.runes.length > max) throw WireRejection('invalid-field', "invalid field '$field'");
    }

    identifier(event.id, 96, 'id', required: true);
    identifier(event.event, 40, 'event', required: true);
    identifier(event.session, 128, 'session');
    identifier(event.tool, 96, 'tool');
    identifier(event.toolUseId, 96, 'toolUseId');
    identifier(event.host, 96, 'host');
    length(event.project, 64, 'project');
    length(event.projectKey, 32, 'projectKey');
    length(event.projectPath, 4096, 'projectPath');
    length(event.message, 200, 'message');
    length(event.notificationType, 40, 'notificationType');
    length(event.agentType, 48, 'agentType');
    length(event.agentId, 64, 'agentId');
    length(event.source, 24, 'source');
    length(event.reason, 48, 'reason');
    length(event.model, 64, 'model');
    length(event.report?.label, 80, 'report.label');
    length(event.summary, HookPayloadSanitizer.maxSummaryLength, 'summary');
    length(event.file, 96, 'file');
    if ((event.batchTools?.length ?? 0) > 16) throw const WireRejection('invalid-field', "invalid field 'batchTools'");
    final path = event.projectPath;
    if (path != null && !WirePath.isAbsolute(path)) throw const WireRejection('invalid-field', "invalid field 'projectPath'");

    final at = event.ts * 1000;
    final clock = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (!event.ts.isFinite || at <= clock - maxAge.inMilliseconds || at >= clock + 300 * 1000) {
      throw const WireRejection('bad-timestamp', 'timestamp outside the accepted window');
    }
    if (event.origin == WireOrigin.report) {
      final report = event.report;
      if (report == null || !WireReport.kinds.contains(report.kind) || !WireReport.statuses.contains(report.status)) {
        throw const WireRejection('invalid-field', "invalid field 'report'");
      }
    }
  }
}
