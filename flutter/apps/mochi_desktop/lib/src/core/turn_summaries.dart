// Claude's finished turns as short notes for the phones: the Dart port of TamagotchiCore's Phone/TurnSummaries.swift
// (SessionReports, TurnSummarizer). Built only while the user shares summaries, and held in memory only.

import 'dart:convert';

import 'package:mochi_link/mochi_link.dart' show TurnSummary;
import 'package:mochi_wire/mochi_wire.dart';

/// What Claude did in one turn of a session: its closing message and the files it changed.
class TurnReport {
  const TurnReport({required this.sessionId, required this.project, required this.message, required this.files, required this.at});

  final String sessionId;
  final String project;
  final String? message;
  final List<String> files;
  final DateTime at;
}

/// Follows hook events to collect each turn's changed files, and hands over the turn when Claude stops.
class SessionReports {
  static const int maxFiles = 30;
  final Map<String, List<String>> _files = {};

  TurnReport? record(WireEvent wire, {DateTime? now}) {
    final session = wire.session;
    if (wire.origin != WireOrigin.hook || session == null) return null;
    switch (wire.event) {
      case 'UserPromptSubmit':
        _files[session] = [];
      case 'PostToolUse':
        final file = wire.file;
        if (file == null) break;
        final list = _files[session] ??= [];
        if (!list.contains(file) && list.length < maxFiles) list.add(file);
      case 'Stop':
        final changed = _files.remove(session) ?? const <String>[];
        return TurnReport(
          sessionId: session,
          project: wire.project ?? 'Claude',
          message: wire.summary,
          files: changed,
          at: now ?? DateTime.now(),
        );
      case 'SessionEnd':
        _files.remove(session);
    }
    return null;
  }

  void clear() => _files.clear();
}

/// Turns Claude's closing message into a short note with a one-off `claude -p` (Haiku, no tools, none of the user's
/// settings, nothing saved), or without it when Claude Code isn't there (Swift `TurnSummarizer`).
abstract final class TurnSummarizer {
  static const String model = 'haiku';

  static const String systemPrompt =
      'You write short notes for a phone about what Claude, a coding assistant, just did in one of the user\'s '
      'projects, so the user can decide what to ask next. Reply with JSON only, no code fence: '
      '{"done": "...", "session": "...", "next": ["..."]} '
      '- done: at most 160 characters. What Claude did or found this turn, the most important part first. '
      'Plain words: no markdown, no file paths. '
      '- session: at most 110 characters. What this session is working on overall, using the earlier notes. '
      '- next: up to 2 requests of at most 40 characters the user could send next, in the user\'s voice '
      '("Run the tests", "Yes, do the migration too"). If Claude asked a question, offer the likely answers. '
      'Never invent work the message doesn\'t mention.';

  static List<String> get arguments => [
    '-p',
    '--model',
    model,
    '--output-format',
    'json',
    '--setting-sources',
    'project',
    '--tools',
    '',
    '--strict-mcp-config',
    '--no-session-persistence',
    '--system-prompt',
    systemPrompt,
  ];

  /// What the summarizer reads: the project, the changed files, earlier notes and Claude's message.
  static String prompt(TurnReport report, {List<String> earlier = const []}) {
    final parts = ['Project: ${report.project}'];
    if (report.files.isNotEmpty) parts.add('Files changed: ${report.files.take(20).join(', ')}');
    if (earlier.isNotEmpty) {
      final notes = earlier.length > 3 ? earlier.sublist(earlier.length - 3) : earlier;
      parts.add('Earlier notes on this session:\n${notes.map((note) => '- $note').join('\n')}');
    }
    parts.add("Claude's last message:\n${report.message ?? '(none)'}");
    return parts.join('\n\n');
  }

  /// The text of `claude -p --output-format json`'s result.
  static String? result(String output) {
    try {
      final json = jsonDecode(output.trim());
      if (json is! Map || json['is_error'] == true) return null;
      final result = json['result'];
      return result is String ? result : null;
    } on FormatException {
      return null;
    }
  }

  /// The note in the model's reply, tolerating a code fence or words around the JSON.
  static TurnSummary? parse(String text) {
    final start = text.indexOf('{'), end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    Object? json;
    try {
      json = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final done = WireText.clean(json['done'] is String ? json['done'] as String : null, maxLength: 200);
    if (done == null) return null;
    final next = <String>[];
    final raw = json['next'];
    if (raw is List) {
      for (final item in raw) {
        final cleaned = WireText.clean(item is String ? item : null, maxLength: 60);
        if (cleaned != null && next.length < 2) next.add(cleaned);
      }
    }
    return TurnSummary(
      done: done,
      session: WireText.clean(json['session'] is String ? json['session'] as String : null, maxLength: 140),
      next: next,
    );
  }

  /// Without the summarizer: the start of Claude's message, or the files it changed.
  static TurnSummary fallback(TurnReport report) {
    final text = plainText(report.message ?? '');
    if (text.isNotEmpty) return TurnSummary(done: firstSentences(text, maxLength: 160));
    if (report.files.isNotEmpty) return TurnSummary(done: 'Changed ${fileList(report.files)}.');
    return const TurnSummary(done: 'Claude finished.');
  }

  /// "A.swift, B.swift, C.swift and 2 more".
  static String fileList(List<String> files, {int shown = 3}) {
    final named = files.take(shown).join(', ');
    return files.length > shown ? '$named and ${files.length - shown} more' : named;
  }

  /// Markdown as plain sentences: code blocks and tables go, links keep their words, list items and headings become
  /// sentences.
  static String plainText(String markdown) {
    final sentences = <String>[];
    var inFence = false;
    for (final raw in markdown.split('\n')) {
      var line = raw.trim();
      if (line.startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence || line.startsWith('|') || line.isEmpty) continue;
      while (line.startsWith('#') || line.startsWith('>')) {
        line = line.substring(1);
      }
      line = line.trim();
      for (final marker in const ['- ', '* ', '• ', '+ ']) {
        if (line.startsWith(marker)) line = line.substring(marker.length);
      }
      final numbered = RegExp(r'^\d+\.').firstMatch(line);
      if (numbered != null) line = line.substring(numbered.end);
      line = _inlinePlain(line).trim();
      if (line.isEmpty) continue;
      if (!'.!?:…'.contains(line[line.length - 1])) line = '$line.';
      sentences.add(line);
    }
    return sentences.join(' ');
  }

  static String _inlinePlain(String text) {
    var line = text.replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (match) => match.group(1) ?? '');
    for (final marker in const ['**', '__', '~~', '`', '*']) {
      line = line.replaceAll(marker, '');
    }
    return line;
  }

  /// Whole sentences while they fit in [maxLength], or the first one clipped.
  static String firstSentences(String text, {required int maxLength}) {
    if (text.length <= maxLength) return text;
    var kept = '';
    var start = 0;
    for (var index = 0; index < text.length; index++) {
      final next = index + 1;
      if ('.!?'.contains(text[index]) && (next == text.length || text[next] == ' ')) {
        final candidate = kept + text.substring(start, next);
        if (candidate.trim().length > maxLength) break;
        kept = candidate;
        start = next;
      }
    }
    final trimmed = kept.trim();
    return trimmed.isEmpty ? '${text.substring(0, maxLength - 1).trim()}…' : trimmed;
  }
}
