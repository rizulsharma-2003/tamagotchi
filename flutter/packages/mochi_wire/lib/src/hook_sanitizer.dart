import 'dart:convert';

import 'classifiers.dart';
import 'wire_event.dart';
import 'wire_text.dart';

/// Turns a raw Claude Code hook payload (the JSON Claude Code writes to the hook's stdin) into a minimal [WireEvent]
/// (Swift `HookPayloadSanitizer`).
///
/// This is an allow-list: only the fields below are read, and free text such as `prompt`, `tool_input`,
/// `tool_response`, `error`, `transcript_path` and `custom_instructions` is never copied. Claude's
/// `last_assistant_message` and the name of a changed file are copied only with `includeSummary` (the user shares
/// summaries with their phone).
abstract final class HookPayloadSanitizer {
  /// Payloads larger than this (a huge `Write`) aren't parsed; the event is still reported from a bounded scan of the
  /// payload's head.
  static const int maxParsedBytes = 8 * 1024 * 1024;
  static const int headScanBytes = 64 * 1024;

  /// Room for a long closing message; the app condenses it.
  static const int maxSummaryLength = 4000;

  static WireEvent sanitize(
    List<int> raw, {
    String? argumentEvent,
    Map<String, String> environment = const {},
    bool includeSummary = false,
    DateTime? now,
  }) {
    final id = hexDigest(raw);
    final ts = (now ?? DateTime.now()).microsecondsSinceEpoch / 1e6;
    Map<String, Object?>? payload;
    if (raw.length <= maxParsedBytes) {
      try {
        final decoded = jsonDecode(utf8.decode(raw));
        if (decoded is Map<String, Object?>) payload = decoded;
      } on FormatException {
        payload = null;
      }
    }
    final fallbackEvent = WireText.identifier(argumentEvent, maxLength: 40);

    if (payload == null) {
      // Unparseable or oversized: only what a bounded scan of the head can find.
      final head = utf8.decode(raw.take(headScanBytes).toList(), allowMalformed: true);
      final name = WireText.identifier(scanString('hook_event_name', head), maxLength: 40) ?? fallbackEvent ?? 'Unknown';
      final event = WireEvent(id: id, ts: ts, origin: WireOrigin.hook, event: name)
        ..session = WireText.identifier(scanString('session_id', head), maxLength: 128)
        ..tool = WireText.identifier(scanString('tool_name', head), maxLength: 96)
        ..host = hostApp(environment)
        ..helperVersion = HelperInfo.version;
      event.toolCategory = event.tool == null ? null : ToolCategoryClassifier.category(event.tool!);
      _applyProject(event, scanString('cwd', head), environment);
      return event;
    }

    String? text(String key) => payload![key] is String ? payload[key] as String : null;
    final name = WireText.identifier(text('hook_event_name'), maxLength: 40) ?? fallbackEvent ?? 'Unknown';
    final event = WireEvent(id: id, ts: ts, origin: WireOrigin.hook, event: name)
      ..helperVersion = HelperInfo.version
      ..session = WireText.identifier(text('session_id'), maxLength: 128)
      ..permissionMode = WireText.identifier(text('permission_mode'), maxLength: 32)
      ..host = hostApp(environment);
    _applyProject(event, text('cwd'), environment);
    event.agentId = WireText.identifier(text('agent_id'), maxLength: 64);
    event.agentType = WireText.clean(text('agent_type'), maxLength: 40);

    switch (name) {
      case 'SessionStart':
        event.source = WireText.identifier(text('source'), maxLength: 24);
        event.model = WireText.clean(_modelName(payload['model']), maxLength: 48);
      case 'SessionEnd':
        event.reason = WireText.identifier(text('reason'), maxLength: 40);
      case 'Stop':
        if (includeSummary) event.summary = WireText.paragraphs(text('last_assistant_message'), maxLength: maxSummaryLength);
      case 'StopFailure':
        event.reason = WireText.identifier(text('error'), maxLength: 40);
      case 'Notification':
        event.notificationType = WireText.identifier(text('notification_type'), maxLength: 40);
        event.message = WireText.clean(text('message'), maxLength: 160);
      case 'PreToolUse' || 'PostToolUse' || 'PostToolUseFailure' || 'PermissionRequest' || 'PermissionDenied':
        _applyTool(event, payload);
        if (includeSummary && name == 'PostToolUse') event.file = changedFile(event.tool, payload);
      case 'PostToolBatch':
        final calls = payload['tool_calls'];
        if (calls is List) {
          event.batchCount = calls.length;
          final names = <String>[];
          for (final call in calls) {
            final tool = call is Map
                ? WireText.identifier(call['tool_name'] is String ? call['tool_name'] as String : null, maxLength: 96)
                : null;
            if (tool == null) continue;
            if (!names.contains(tool)) names.add(tool);
            if (names.length == 8) break;
          }
          event.batchTools = names;
        }
    }
    // The common agent_id/agent_type fields are only present when the hook fires inside a subagent.
    if (name != 'SubagentStart' && name != 'SubagentStop' && event.agentId != null) event.inSubagent = true;
    return event;
  }

  /// `model` is a string in older Claude Code and `{id, display_name}` in newer ones.
  static String? _modelName(Object? model) {
    if (model is String) return model;
    if (model is Map) {
      final display = model['display_name'] ?? model['id'];
      return display is String ? display : null;
    }
    return null;
  }

  static void _applyTool(WireEvent event, Map<String, Object?> payload) {
    final tool = WireText.identifier(payload['tool_name'] is String ? payload['tool_name'] as String : null, maxLength: 96);
    if (tool == null) return;
    event.tool = tool;
    event.toolCategory = ToolCategoryClassifier.category(tool);
    event.toolUseId = WireText.identifier(payload['tool_use_id'] is String ? payload['tool_use_id'] as String : null, maxLength: 96);
    final duration = payload['duration_ms'];
    if (duration is num) event.durationMs = duration.toInt().clamp(0, 86400000);
    final interrupted = payload['is_interrupt'];
    if (interrupted is bool) event.isInterrupt = interrupted;
    final error = payload['error'];
    if (error is String) event.exitCode = leadingExitCode(error);
    final input = payload['tool_input'];
    if ((tool == 'Bash' || tool == 'PowerShell') && input is Map) {
      final background = input['run_in_background'] == true;
      if (background) event.backgrounded = true;
      final command = input['command'];
      if (command is String) {
        final result = CommandClassifier.classify(command);
        if (result.kind != null) {
          event.commandKind = result.kind;
          event.commandReliable = result.reliable && !background;
        }
      }
    }
  }

  /// The name of the file an editing tool changed: never its folder or contents.
  static String? changedFile(String? tool, Map<String, Object?> payload) {
    if (tool == null || !const ['Edit', 'Write', 'MultiEdit', 'NotebookEdit'].contains(tool)) return null;
    final input = payload['tool_input'];
    if (input is! Map) return null;
    final path = input['file_path'] ?? input['notebook_path'];
    if (path is! String || path.isEmpty) return null;
    return WireText.clean(path.split(RegExp(r'[\\/]')).last, maxLength: 96);
  }

  /// Claude Code sets CLAUDE_PROJECT_DIR for hooks: the project root even after Claude changes directory.
  static void _applyProject(WireEvent event, String? cwd, Map<String, String> environment) {
    final fromEnvironment = environment['CLAUDE_PROJECT_DIR'];
    final path = fromEnvironment != null && fromEnvironment.isNotEmpty ? fromEnvironment : cwd;
    if (path == null || !WirePath.isAbsolute(path) || utf8.encode(path).length >= 4096) return;
    event.project = ProjectIdentity.displayName(path);
    event.projectKey = ProjectIdentity.key(path);
    event.projectPath = WirePath.standardize(path);
  }

  /// macOS sets `__CFBundleIdentifier` for processes started from an app; on Windows, terminals and editors that set
  /// `TERM_PROGRAM` (VS Code, WezTerm) say who they are that way.
  static String? hostApp(Map<String, String> environment) =>
      WireText.identifier(environment['__CFBundleIdentifier'], maxLength: 96) ??
      WireText.identifier(environment['TERM_PROGRAM'], maxLength: 96);

  /// Claude Code formats shell failures with a leading "Exit code N" line.
  static int? leadingExitCode(String error) {
    final head = error.length > 32 ? error.substring(0, 32) : error;
    const prefix = 'Exit code ';
    if (!head.startsWith(prefix)) return null;
    final digits = RegExp(r'^-?\d+').firstMatch(head.substring(prefix.length))?.group(0);
    return digits == null ? null : int.tryParse(digits);
  }

  /// Finds `"key": "value"` in a JSON fragment without parsing all of it; null for escaped values.
  static String? scanString(String key, String text) {
    final start = text.indexOf('"$key"');
    if (start < 0) return null;
    var index = start + key.length + 2;
    while (index < text.length && ' :\n\t'.contains(text[index])) {
      index++;
    }
    if (index >= text.length || text[index] != '"') return null;
    index++;
    final value = StringBuffer();
    while (index < text.length && text[index] != '"' && value.length < 512) {
      if (text[index] == r'\') return null;
      value.write(text[index]);
      index++;
    }
    return value.toString();
  }
}
