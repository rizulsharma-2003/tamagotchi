// Mochi's agent, running Claude: the `claude -p` command, its environment, the prompt for each mode, and what comes
// back (the digest, why a run failed, the connections probe). The Mac's AgentCommand, AgentDigest, AgentEmail,
// AgentEvent, AgentTask and AgentConnections (Sources/TamagotchiCore/Agent/MochiAgent.swift). Pure Dart.

import 'dart:convert';
import 'dart:io';

import 'package:mochi_link/mochi_link.dart' show AgentSource;
import 'package:mochi_wire/mochi_wire.dart' show WireText;

import 'agent_settings.dart';

/// This PC's time zone for the prompts: its IANA name and its offset from UTC (the Mac's `TimeZone.current`).
class AgentZone {
  const AgentZone(this.name, this.offset);

  /// "Asia/Kolkata", "UTC".
  final String name;
  final Duration offset;

  static const AgentZone utc = AgentZone('UTC', Duration.zero);

  /// [moment] as that zone's wall clock, in a UTC-flagged DateTime (read only its fields).
  DateTime wall(DateTime moment) => moment.toUtc().add(offset);

  /// "+05:30".
  String get offsetText {
    final minutes = offset.inMinutes;
    final sign = minutes < 0 ? '-' : '+';
    return '$sign${(minutes.abs() ~/ 60).toString().padLeft(2, '0')}:${(minutes.abs() % 60).toString().padLeft(2, '0')}';
  }

  /// "2026-11-03T11:00:00+05:30" (Z for a zone at UTC), as the Mac's ISO8601DateFormatter writes it.
  String iso(DateTime moment) {
    final wall = this.wall(moment);
    final text = '${_four(wall.year)}-${_two(wall.month)}-${_two(wall.day)}T${_two(wall.hour)}:${_two(wall.minute)}:${_two(wall.second)}';
    return offset == Duration.zero ? '${text}Z' : '$text$offsetText';
  }

  /// "Tuesday 2026-11-03 09:30".
  String localTime(DateTime moment) {
    final wall = this.wall(moment);
    return '${_weekdays[wall.weekday - 1]} ${_four(wall.year)}-${_two(wall.month)}-${_two(wall.day)} ${_two(wall.hour)}:${_two(wall.minute)}';
  }

  /// The last second of [moment]'s day here.
  DateTime endOfDay(DateTime moment) {
    final wall = this.wall(moment);
    final next = DateTime.utc(wall.year, wall.month, wall.day + 1);
    return next.subtract(offset).subtract(const Duration(seconds: 1));
  }

  /// "5:00 PM".
  String clock(DateTime moment) {
    final wall = this.wall(moment);
    final hour = wall.hour % 12 == 0 ? 12 : wall.hour % 12;
    return '$hour:${_two(wall.minute)} ${wall.hour < 12 ? 'AM' : 'PM'}';
  }

  static const List<String> _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _four(int n) => n.toString().padLeft(4, '0');
}

sealed class AgentMode {
  const AgentMode();
}

/// What arrived since the last check, and what starts soon.
class AgentCheck extends AgentMode {
  const AgentCheck(this.since);

  final DateTime since;
}

/// The day at a glance: the morning briefing, or "what's pending?".
class AgentBriefing extends AgentMode {
  const AgentBriefing();
}

abstract final class AgentCommand {
  static const String model = 'haiku';

  /// `claude -p` reading the prompt from stdin. `dontAsk` refuses every tool not listed here, so the run can read and
  /// nothing else; none of the user's settings or hooks load and nothing is saved.
  static List<String> arguments(List<AgentSource> sources) => [
    '-p',
    '--model',
    model,
    '--output-format',
    'json',
    '--setting-sources',
    'project',
    '--no-session-persistence',
    '--permission-mode',
    'dontAsk',
    '--tools',
    'ToolSearch',
    '--allowedTools',
    'ToolSearch',
    for (final source in sources) ...source.readTools,
    '--json-schema',
    schema,
  ];

  /// The one tool the agent may use to change anything in Gmail: take a label off a thread. Only the mark-read run is
  /// allowed it, and only with "Mark the email read when I mark it done" on (the Mac's `markReadTool`).
  static const String markReadTool = 'mcp__claude_ai_Gmail__unlabel_thread';

  /// A run that may only remove the UNREAD label from the threads the user marked done: the flags of a check, but with
  /// this one tool allowed and no read tool. No check ever allows [markReadTool].
  static List<String> get markReadArguments => [
    '-p',
    '--model',
    model,
    '--output-format',
    'json',
    '--setting-sources',
    'project',
    '--no-session-persistence',
    '--permission-mode',
    'dontAsk',
    '--tools',
    'ToolSearch',
    '--allowedTools',
    'ToolSearch',
    markReadTool,
  ];

  /// Thread ids only (at most 20): nothing else about the mail goes into the prompt.
  static String markReadPrompt(List<String> threadIds) =>
      'Mark these Gmail threads as read: for each thread id, call unlabel_thread with labelIds ["UNREAD"]. Do nothing else; '
      'if the tool isn\'t loaded yet, use tool search to load it. Thread ids: ${threadIds.join(', ')}. '
      'Finish with one line saying how many you marked.';

  /// The mark-read run finished without an error (the Mac's `markReadSucceeded`).
  static bool markReadSucceeded(String output) {
    final result = _resultObject(output);
    return result != null && result['is_error'] != true && result['result'] != null;
  }

  /// The user's claude.ai connectors load in `-p` runs only when asked for, and otherwise connect in the background,
  /// racing the model, which then finds no tools. Waiting for them first makes every run see them. An API key in the
  /// environment would bill the run to the API instead of the user's subscription: never pass one on.
  static Map<String, String> environment(Map<String, String> base) {
    final environment = Map<String, String>.of(base);
    for (final key in const ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX']) {
      environment.remove(key);
    }
    environment['ENABLE_CLAUDEAI_MCP_SERVERS'] = 'true';
    environment['MCP_CONNECTION_NONBLOCKING'] = 'false';
    return environment;
  }

  static String prompt({required AgentMode mode, required List<AgentSource> sources, required DateTime now, AgentZone zone = AgentZone.utc}) {
    final lines = <String>[
      'You are the background checker for Mochi, a desktop pet that tells its owner what needs their attention. '
          'Read only: never send, change or delete anything.',
      'The Gmail, Calendar and Notion tools can take a few seconds to connect; if one isn\'t loaded yet, use tool search to load it.',
      'Now: ${zone.localTime(now)} (${zone.name}, UTC${zone.offsetText}).',
    ];
    final briefing = mode is AgentBriefing;
    if (sources.contains(AgentSource.gmail)) {
      final query = mode is AgentCheck
          ? 'is:unread in:inbox after:${mode.since.millisecondsSinceEpoch ~/ 1000}'
          : 'is:unread in:inbox newer_than:1d';
      lines.add(
        'Gmail: search_threads with the query "$query" (at most 15 threads). For each give the thread id, the '
        'sender\'s display name as the From line shows it ("VFDF via Figma", "Google") — never the email address — '
        'and, separately, the sender\'s email address, the subject, a gist of at most 12 words, urgency (high: a person needs something from the '
        'owner soon; low: newsletters, promotions, receipts and other automated mail; normal: the rest) and whether '
        'it needs a reply. Judge from the search results; open a thread only when the snippet isn\'t enough, at most 3 times.',
      );
    } else {
      lines.add('Gmail is not part of this check: return an empty emails list.');
    }
    if (sources.contains(AgentSource.calendar)) {
      final until = briefing ? zone.endOfDay(now) : now.add(const Duration(minutes: 90));
      lines.add(
        'Google Calendar: list_events on the primary calendar from now until ${zone.iso(until)}. Skip all-day '
        'events and events the owner declined. Give each event\'s id, title, start and end (ISO 8601 with offset) '
        'and place if any, and the video call link (Google Meet, Zoom or Teams URL) as link if any.',
      );
    } else {
      lines.add('Google Calendar is not part of this check: return an empty events list.');
    }
    if (sources.contains(AgentSource.notion)) {
      final window = briefing ? 'due today, overdue, or due within the next 2 days' : 'due today or overdue';
      lines.add(
        'Notion: find open task-like items (not done) assigned to the owner that are $window: notion-get-self, '
        'then notion-search. At most 4 Notion calls; if nothing obvious turns up, return an empty tasks list.',
      );
    } else {
      lines.add('Notion is not part of this check: return an empty tasks list.');
    }
    lines.add(
      briefing
          ? 'Headline: at most 110 characters, a friendly summary of the owner\'s day, the most important thing first.'
          : 'Headline: at most 110 characters, the most important new thing first, e.g. "3 new emails — the invoice from Acme needs a reply today".',
    );
    lines.add('Use ids exactly as the tools return them. Reply with the JSON only.');
    return lines.join('\n');
  }

  static const String schema =
      '{"type":"object","additionalProperties":false,"required":["headline","emails","events","tasks"],"properties":{'
      '"headline":{"type":"string"},'
      '"emails":{"type":"array","items":{"type":"object","additionalProperties":false,'
      '"required":["id","from","subject","gist","urgency","needs_reply"],"properties":{"id":{"type":"string"},"from":{"type":"string"},'
      '"address":{"type":"string"},'
      '"subject":{"type":"string"},"gist":{"type":"string"},"urgency":{"type":"string","enum":["high","normal","low"]},'
      '"needs_reply":{"type":"boolean"}}}},'
      '"events":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","title","start"],'
      '"properties":{"id":{"type":"string"},"title":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"},'
      '"where":{"type":"string"},"link":{"type":"string"}}}},'
      '"tasks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","title"],'
      '"properties":{"id":{"type":"string"},"title":{"type":"string"},"due":{"type":"string"},"status":{"type":"string"},'
      '"url":{"type":"string"}}}}}}';
}

// MARK: What Claude found

/// What `claude -p --output-format json` printed, as its result object (a run's output is one object; some versions
/// print a list of events, whose last `result` is the one).
Map<String, Object?>? _resultObject(String output) {
  Object? decoded;
  try {
    decoded = jsonDecode(output);
  } on FormatException {
    return null;
  }
  if (decoded is List) {
    for (final item in decoded.reversed) {
      if (item is Map && item['type'] == 'result') return item.cast<String, Object?>();
    }
    return null;
  }
  return decoded is Map ? decoded.cast<String, Object?>() : null;
}

class AgentDigest {
  const AgentDigest({required this.headline, this.emails = const [], this.events = const [], this.tasks = const []});

  final String headline;
  final List<AgentEmail> emails;
  final List<AgentEvent> events;
  final List<AgentTask> tasks;

  /// The digest in `claude -p --output-format json`'s `structured_output`, cleaned up; null when the run failed.
  static AgentDigest? parse(String output) {
    final result = _resultObject(output);
    if (result == null || result['is_error'] == true) return null;
    final structured = result['structured_output'];
    if (structured is! Map) return null;
    final headline = structured['headline'];
    final emails = structured['emails'], events = structured['events'], tasks = structured['tasks'];
    if (headline is! String || emails is! List || events is! List || tasks is! List) return null;
    return AgentDigest(
      headline: headline,
      emails: [for (final item in emails) ?AgentEmail.fromJson(item)],
      events: [for (final item in events) ?AgentEvent.fromJson(item)],
      tasks: [for (final item in tasks) ?AgentTask.fromJson(item)],
    )._cleaned();
  }

  /// Why a run failed, in Claude Code's words, when it says.
  static String? failure(String output) {
    final result = _resultObject(output);
    if (result == null) return null;
    if (result['is_error'] == true) {
      final text = result['result'];
      return WireText.clean(text is String ? text : null, maxLength: 200) ?? 'Claude reported an error.';
    }
    if (result['structured_output'] == null) return 'Claude didn\'t return a digest.';
    return null;
  }

  AgentDigest _cleaned() {
    String text(String value, int length) => WireText.clean(value, maxLength: length) ?? '';
    return AgentDigest(
      headline: text(headline, 140),
      emails: [
        for (final email in emails.take(20))
          if (email.id.isNotEmpty)
            AgentEmail(
              id: email.id,
              from: text(AgentEmail.senderName(email.from), 60),
              subject: text(email.subject, 120),
              gist: text(email.gist, 120),
              urgency: const ['high', 'normal', 'low'].contains(email.urgency) ? email.urgency : 'normal',
              needsReply: email.needsReply,
              address: AgentEmail.plainAddress(email.address ?? email.from),
            ),
      ],
      events: [
        for (final event in events.take(20))
          if (event.id.isNotEmpty)
            AgentEvent(
              id: event.id,
              title: text(event.title, 100),
              start: text(event.start, 40),
              end: event.end == null ? null : text(event.end!, 40),
              place: event.place == null ? null : WireText.clean(event.place, maxLength: 120),
              link: event.link != null && event.link!.startsWith('https://') && event.link!.length <= 200 && !event.link!.contains(' ')
                  ? event.link
                  : null,
            ),
      ],
      tasks: [
        for (final task in tasks.take(20))
          if (task.id.isNotEmpty)
            AgentTask(
              id: task.id,
              title: text(task.title, 120),
              due: task.due == null ? null : WireText.clean(task.due, maxLength: 40),
              status: task.status == null ? null : WireText.clean(task.status, maxLength: 40),
              url: task.url,
            ),
      ],
    );
  }
}

class AgentEmail {
  const AgentEmail({
    required this.id,
    required this.from,
    required this.subject,
    required this.gist,
    this.urgency = 'normal',
    this.needsReply = false,
    this.address,
  });

  final String id;
  final String from;
  final String subject;
  final String gist;

  /// high · normal · low
  final String urgency;
  final bool needsReply;

  /// The sender's email address, for VIPs (never shown).
  final String? address;

  static AgentEmail? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    String text(String key) => json[key] is String ? json[key] as String : '';
    return AgentEmail(
      id: json['id'] as String,
      from: text('from'),
      subject: text('subject'),
      gist: text('gist'),
      urgency: text('urgency').isEmpty ? 'normal' : text('urgency'),
      needsReply: json['needs_reply'] == true,
      address: json['address'] is String ? json['address'] as String : null,
    );
  }

  /// Needs the owner: urgent, or someone waiting for an answer.
  bool get important => urgency == 'high' || needsReply;

  int get rank => (urgency == 'high'
      ? 2
      : urgency == 'normal'
      ? 1
      : 0) + (needsReply ? 1 : 0);

  /// The plain address in "Name <a@b.com>" or "a@b.com", lowercased.
  static String? plainAddress(String raw) {
    var text = raw;
    final open = text.indexOf('<'), close = text.lastIndexOf('>');
    if (open >= 0 && close > open) text = text.substring(open + 1, close);
    text = _trim(text, ' "\'').toLowerCase();
    if (!text.contains('@') || text.contains(' ') || text.length > 120) return null;
    return text;
  }

  /// The name people know a sender by: "VFDF via Figma <comments-…@email.figma.com>" → "VFDF via Figma", and a bare
  /// address → its company ("no-reply@accounts.google.com" → "Google").
  static String senderName(String raw) {
    const quotes = ' "\'';
    var text = _trim(raw, ' \t');
    final open = text.indexOf('<');
    if (open >= 0) {
      final name = _trim(text.substring(0, open), quotes);
      if (name.isNotEmpty) return name;
      text = _trim(text.substring(open + 1), '> ');
    }
    final paren = text.indexOf('(');
    if (paren >= 0 && text.contains('@')) {
      final before = _trim(text.substring(0, paren), quotes);
      final inside = _trim(text.substring(paren + 1), ') "\'');
      if (before.isNotEmpty && !before.contains('@')) return before;
      if (inside.isNotEmpty && !inside.contains('@')) return inside;
      text = before;
    }
    text = _trim(text, quotes);
    if (!text.contains('@') || text.contains(' ')) return text;
    final parts = text.split('@').where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) return text;
    final labels = parts.last.toLowerCase().split('.').where((label) => label.isNotEmpty).toList();
    // "shop.co.uk": the name sits before a two-part ending.
    if (labels.length >= 3 && labels.last.length == 2 && const ['co', 'com', 'org', 'net', 'ac', 'gov'].contains(labels[labels.length - 2])) {
      labels.removeLast();
    }
    final company = labels.length >= 2 ? labels[labels.length - 2] : (labels.isEmpty ? text : labels.first);
    return knownNames[company] ?? (company.isEmpty ? company : company[0].toUpperCase() + company.substring(1));
  }

  static const Map<String, String> knownNames = {
    'clevertap': 'CleverTap',
    'github': 'GitHub',
    'linkedin': 'LinkedIn',
    'youtube': 'YouTube',
    'paypal': 'PayPal',
    'hubspot': 'HubSpot',
    'openai': 'OpenAI',
    'icloud': 'iCloud',
    'zoho': 'Zoho',
    'whatsapp': 'WhatsApp',
    'facebookmail': 'Facebook',
    'amazonses': 'Amazon',
  };

  static String _trim(String text, String characters) {
    var start = 0, end = text.length;
    while (start < end && characters.contains(text[start])) {
      start++;
    }
    while (end > start && characters.contains(text[end - 1])) {
      end--;
    }
    return text.substring(start, end);
  }
}

class AgentEvent {
  const AgentEvent({required this.id, required this.title, required this.start, this.end, this.place, this.link});

  final String id;
  final String title;

  /// ISO 8601 with offset.
  final String start;
  final String? end;
  final String? place;

  /// The video call to join (Google Meet, Zoom, Teams).
  final String? link;

  static AgentEvent? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    String? text(String key) => json[key] is String ? json[key] as String : null;
    return AgentEvent(
      id: json['id'] as String,
      title: text('title') ?? '',
      start: text('start') ?? '',
      end: text('end'),
      place: text('where'),
      link: text('link'),
    );
  }

  DateTime? get startDate => DateTime.tryParse(start);
}

class AgentTask {
  const AgentTask({required this.id, required this.title, this.due, this.status, this.url});

  final String id;
  final String title;
  final String? due;
  final String? status;
  final String? url;

  static AgentTask? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    String? text(String key) => json[key] is String ? json[key] as String : null;
    return AgentTask(id: json['id'] as String, title: text('title') ?? '', due: text('due'), status: text('status'), url: text('url'));
  }
}

// MARK: Connections

enum AgentConnection {
  connected,
  needsSignIn,
  failed,
  unavailable;

  String get title => switch (this) {
    connected => 'Connected',
    needsSignIn => 'Needs sign-in',
    failed => 'Couldn\'t connect',
    unavailable => 'Not connected',
  };
}

abstract final class AgentConnections {
  /// Where the user connects these services: their Claude account's connectors.
  static final Uri connectURL = Uri.parse('https://claude.ai/customize/connectors');

  /// Claude Code fetches the claude.ai connectors in the background, after its first report, so the only reliable way
  /// to know is to ask: a tiny Haiku run that looks for each connector's tools and calls none.
  static List<String> get probeArguments => [
    '-p',
    '--model',
    AgentCommand.model,
    '--output-format',
    'json',
    '--setting-sources',
    'project',
    '--no-session-persistence',
    '--permission-mode',
    'dontAsk',
    '--tools',
    'ToolSearch',
    '--allowedTools',
    'ToolSearch',
    '--json-schema',
    probeSchema,
  ];

  static const String probePrompt =
      'Find out which of these connectors\' tools are available to you, using tool search only: Gmail (tools named '
      'mcp__claude_ai_Gmail__…), Google Calendar (mcp__claude_ai_Google_Calendar__…) and Notion (mcp__claude_ai_Notion__…). '
      'Connectors can take a few seconds to connect: if one isn\'t found, search for it once more. Don\'t call any of their tools. '
      'If you have no tool search tool at all, no connector is available: answer false for each. '
      'Reply with the JSON only: true for each connector with at least one tool available.';

  static const String probeSchema =
      '{"type":"object","additionalProperties":false,"required":["gmail","calendar","notion"],'
      '"properties":{"gmail":{"type":"boolean"},"calendar":{"type":"boolean"},"notion":{"type":"boolean"}}}';

  /// Whether the probe finished cleanly but Claude answered in words instead of the JSON (seen on a PC with no connectors:
  /// without any, Claude Code has no tool search, and Haiku sometimes won't fill in the form). Worth one more try.
  static bool answeredWithoutSchema(String output) {
    final result = _resultObject(output);
    return result != null && result['is_error'] != true && result['subtype'] == 'success' && result['structured_output'] == null;
  }

  /// Each source's state from the probe's output; null when the run failed.
  static Map<AgentSource, AgentConnection>? parse(String output) {
    final result = _resultObject(output);
    if (result == null || result['is_error'] == true) return null;
    final found = result['structured_output'];
    if (found is! Map) return null;
    return {for (final source in AgentSource.values) source: found[source.name] == true ? AgentConnection.connected : AgentConnection.unavailable};
  }

  /// Claude Code's note of connectors that needed signing in (`~/.claude/mcp-needs-auth-cache.json`, or under
  /// `CLAUDE_CONFIG_DIR`).
  static File signInNotesFile(Map<String, String> environment, {required bool windows}) {
    final configured = environment['CLAUDE_CONFIG_DIR'];
    final home = (windows ? environment['USERPROFILE'] : environment['HOME']) ?? '';
    final separator = windows ? r'\' : '/';
    final directory = configured != null && configured.isNotEmpty ? configured : '$home$separator.claude';
    return File('$directory${separator}mcp-needs-auth-cache.json');
  }

  /// Claude Code remembers a connector that needed signing in and skips it in `-p` runs for a while, even after the
  /// user has connected it. Forgets that note for these sources only (the Mac's three), before a fresh look.
  static bool forgetSignInNotes(File cacheFile) {
    try {
      final decoded = jsonDecode(cacheFile.readAsStringSync());
      if (decoded is! Map) return false;
      final names = {for (final source in AgentSource.values) source.connectorName};
      final kept = {
        for (final entry in decoded.entries)
          if (!names.contains(entry.key)) entry.key: entry.value,
      };
      if (kept.length == decoded.length) return false;
      final temporary = File('${cacheFile.path}.tmp');
      temporary.writeAsStringSync(jsonEncode(kept), flush: true);
      temporary.renameSync(cacheFile.path);
      return true;
    } on Object {
      return false;
    }
  }
}
