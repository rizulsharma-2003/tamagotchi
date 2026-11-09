// Mochi's agent, what it tells and remembers: VIPs, what's new in a digest (and how Mochi says it), what Mochi has
// already mentioned and what's waiting for you (the Pending card), when to look, and the phone alert that carries the
// card. The Mac's AgentVIP, AgentNews, AgentMemory, AgentSchedule and PhoneAlertPayload.agentNews
// (Sources/TamagotchiCore/Agent/MochiAgent.swift). Pure Dart; the wire models (AgentNote, AgentPending, AgentDoneList)
// are mochi_link's.

import 'package:mochi_link/mochi_link.dart' show AgentDoneList, AgentNote, AgentPending, AgentSource;

import '../notifications.dart' show AttentionLevel;
import 'agent_command.dart';
import 'agent_settings.dart';

/// People whose mail always rings through.
abstract final class AgentVIP {
  /// An entry with "@" is an address, or a domain when it starts with "@"; anything else is part of a name.
  static bool matches(AgentEmail email, List<String> vips) {
    final address = email.address?.toLowerCase() ?? '';
    final name = email.from.toLowerCase();
    return vips.any((raw) {
      final vip = raw.trim().toLowerCase();
      if (vip.isEmpty) return false;
      if (vip.startsWith('@')) return address.endsWith(vip);
      if (vip.contains('@')) return address == vip;
      return name.contains(vip);
    });
  }

  /// The same list as a Gmail search: from:("Amogh Sharma" OR a@b.com OR insideedge.club).
  static String? gmailQuery(List<String> vips) {
    final terms = [
      for (final vip in vips.map((vip) => vip.trim()).where((vip) => vip.isNotEmpty))
        if ((vip.startsWith('@') ? vip.substring(1) : vip) case final term)
          term.contains(' ') ? '"${term.replaceAll('"', '')}"' : term,
    ];
    return terms.isEmpty ? null : 'from:(${terms.join(' OR ')})';
  }
}

/// A list sorted by [compare], keeping the order of equal items (Dart's sort isn't stable).
List<T> _stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final indexed = [for (final (index, item) in items.indexed) (index, item)];
  indexed.sort((a, b) {
    final order = compare(a.$2, b.$2);
    return order != 0 ? order : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

/// What's new in a digest: everything Mochi hasn't mentioned yet.
class AgentNews {
  AgentNews({List<AgentEmail> emails = const [], this.events = const [], this.tasks = const [], this.vips = const []})
    : emails = _stableSorted(emails, (a, b) {
        final va = AgentVIP.matches(a, vips), vb = AgentVIP.matches(b, vips);
        if (va != vb) return va ? -1 : 1;
        return b.rank.compareTo(a.rank);
      });

  final List<AgentEmail> emails;
  final List<AgentEvent> events;
  final List<AgentTask> tasks;

  /// With VIPs, only their mail rings; the rest waits for the summaries.
  final List<String> vips;

  bool isVIP(AgentEmail email) => vips.isNotEmpty && AgentVIP.matches(email, vips);

  bool get isEmpty => emails.isEmpty && events.isEmpty && tasks.isEmpty;

  /// How loudly Mochi should say it: nothing for newsletters alone.
  AttentionLevel? get attention {
    if (vips.isNotEmpty) {
      if (emails.any(isVIP) || events.isNotEmpty) return AttentionLevel.attention;
      return tasks.isEmpty ? null : AttentionLevel.info;
    }
    if (emails.any((email) => email.important) || events.isNotEmpty) return AttentionLevel.attention;
    if (tasks.isNotEmpty || emails.any((email) => email.urgency != 'low')) return AttentionLevel.info;
    return null;
  }

  /// Worth buzzing the phones for.
  bool worthPhone({required bool skippingLow}) {
    if (!skippingLow) return !isEmpty;
    return attention != null;
  }

  /// The parts of what Mochi says, most important first.
  List<String> parts([AgentZone zone = AgentZone.utc]) {
    final urgent = <String>[];
    final rest = <String>[];
    if (emails.isNotEmpty) {
      final top = emails.first;
      final count = emails.length;
      String text;
      if (emails.every((email) => email.urgency == 'low')) {
        text = count == 1 ? 'New email from ${top.from}, nothing urgent' : '$count new emails, nothing urgent';
      } else {
        text = count == 1 ? 'New email from ${top.from}: ${top.gist}' : '$count new emails · ${top.from}: ${top.gist}';
        if (top.needsReply) text += ' (needs a reply)';
      }
      (top.important ? urgent : rest).add(text);
    }
    if (events.isNotEmpty) {
      final event = events.first;
      var text = event.title;
      final start = event.startDate;
      if (start != null) text += ' at ${zone.clock(start)}';
      if (events.length > 1) text += ' (+${events.length - 1} more)';
      urgent.add(text);
    }
    if (tasks.isNotEmpty) {
      rest.insert(0, tasks.length == 1 ? 'Due in Notion: ${tasks.first.title}' : '${tasks.length} Notion tasks due · ${tasks.first.title}');
    }
    return [...urgent, ...rest];
  }

  /// Mochi's speech bubble: the most important part, kept short.
  String line([AgentZone zone = AgentZone.utc]) {
    final all = parts(zone);
    if (all.isEmpty) return '';
    final more = all.length > 1 ? ' · and more' : '';
    return clip(all.first, 120 - more.length) + more;
  }

  /// The phone notification: a title and a few lines.
  ({String title, String body}) notification([AgentZone zone = AgentZone.utc]) {
    final all = parts(zone);
    final String title;
    if (emails.isNotEmpty && events.isEmpty && tasks.isEmpty) {
      title = emails.length == 1 ? 'New email' : '${emails.length} new emails';
    } else if (events.isNotEmpty && emails.isEmpty && tasks.isEmpty) {
      title = 'Coming up';
    } else if (tasks.isNotEmpty && emails.isEmpty && events.isEmpty) {
      title = 'Due in Notion';
    } else {
      title = 'Mochi has news';
    }
    final lines = [for (final part in all.take(3)) clip(part, 140)];
    for (final email in emails.skip(1).where((email) => email.important).take(2)) {
      lines.add(clip('${email.from}: ${email.gist}', 140));
    }
    return (title: title, body: lines.join('\n'));
  }

  List<AgentNote> notes(DateTime date, [AgentZone zone = AgentZone.utc]) {
    final at = (date.millisecondsSinceEpoch / 1000).roundToDouble();
    return [
      for (final email in emails)
        AgentNote(
          id: 'mail:${email.id}',
          source: AgentSource.gmail,
          title: email.from,
          detail: email.gist.isEmpty ? email.subject : email.gist,
          important: email.important || isVIP(email),
          at: at,
          link: gmailLink(email.id),
          subject: email.subject.isEmpty || email.gist.isEmpty ? null : email.subject,
          vip: isVIP(email) ? true : null,
        ),
      for (final event in events)
        AgentNote(
          id: 'event:${event.id}',
          source: AgentSource.calendar,
          title: event.title,
          detail: (event.startDate == null ? event.start : zone.clock(event.startDate!)) + (event.place == null ? '' : ' · ${event.place}'),
          important: true,
          at: at,
          due: event.startDate == null ? null : event.startDate!.millisecondsSinceEpoch / 1000,
          link: event.link,
        ),
      for (final task in tasks)
        AgentNote(
          id: 'task:${task.id}',
          source: AgentSource.notion,
          title: task.title,
          detail: task.due == null ? 'Open' : 'Due ${task.due}',
          important: false,
          at: at,
          link: task.url != null && task.url!.startsWith('https://') ? task.url : null,
        ),
    ];
  }

  /// Gmail on the web (or the Gmail app) at that thread, in the default account.
  static String? gmailLink(String threadID) {
    if (threadID.isEmpty || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(threadID)) return null;
    return 'https://mail.google.com/mail/#all/$threadID';
  }

  /// [text] in at most [length] characters, ending in "…" when it was cut.
  static String clip(String text, int length) {
    final runes = text.runes.toList();
    if (runes.length <= length) return text;
    final cut = String.fromCharCodes(runes.take(length - 1 < 1 ? 1 : length - 1)).trimRight();
    return '$cut…';
  }
}

/// The Pending card in the phone apps, small enough to ride in a notification (APNs allows 4 KB): fewer items,
/// shorter words (the Mac's `AgentPending.compact`).
AgentPending compactPending(AgentPending card) => AgentPending(
  enabled: card.enabled,
  headline: card.headline == null ? null : AgentNews.clip(card.headline!, 120),
  items: [
    for (final item in card.items.take(6))
      AgentNote(
        id: item.id,
        source: item.source,
        title: AgentNews.clip(item.title, 60),
        detail: AgentNews.clip(item.detail, 90),
        important: item.important,
        at: item.at,
        due: item.due,
        link: item.link != null && item.link!.length > 200 ? null : item.link,
        subject: item.subject == null ? null : AgentNews.clip(item.subject!, 70),
        vip: item.vip,
      ),
  ],
  lookedAt: card.lookedAt,
  updatedAt: card.updatedAt,
  origin: card.origin,
);

/// The most notes the Pending card holds.
const int agentPendingMax = 8;

/// The phone notification for Mochi's news (the Mac's `PhoneAlertPayload.agentNews`, as the relay seals it): the
/// notification's own title and body, and the Pending card riding along in `userInfo` (it lands before the app opens),
/// with `quietIfKnown`: one that brings nothing already told arrives without a sound or banner.
abstract final class AgentAlert {
  static const String category = 'mochi-agent';

  /// The thread notifications of this kind group in.
  static const String threadId = 'mochi-agent';

  static Map<String, Object?> inner({required String title, required String body, AgentPending? pending, bool quietIfKnown = false}) => {
    'title': title,
    'body': body,
    'userInfo': {'kind': 'agent', 'quietIfKnown': quietIfKnown, 'pending': ?(pending == null ? null : compactPending(pending).toJson())},
  };
}

/// What Mochi has already mentioned (so nothing is said twice) and when it last looked: `agent.json`.
class AgentMemory {
  AgentMemory();

  /// "mail:<id>", "event:<id>" or "task:<id>:<day>" → when Mochi first mentioned it (Unix time).
  Map<String, double> seen = {};
  double? lastCheckAt;
  String? lastBriefingDay;

  /// Newest first.
  List<AgentNote> notes = [];

  /// What's waiting for you now (the Pending card), in the order it's shown.
  List<AgentNote> pending = [];
  String? pendingHeadline;

  /// What you marked done, here or on a phone (item id → when): it never comes back.
  Map<String, double> done = {};

  /// Gmail threads already marked read after you marked them done (W23b: kept as the Mac keeps it).
  Map<String, double> markedRead = {};

  static const double keepDays = 14;
  static const int maxNotes = 40;

  /// Mail and tasks leave the Pending card after this long, unless a briefing brings them back.
  static const double pendingHours = 30;

  factory AgentMemory.fromJson(Object? json) {
    final memory = AgentMemory();
    if (json is! Map) return memory;
    Map<String, double> numbers(Object? value) => value is Map
        ? {
            for (final entry in value.entries)
              if (entry.key is String && entry.value is num) entry.key as String: (entry.value as num).toDouble(),
          }
        : {};
    List<AgentNote> list(Object? value) => value is List ? [for (final item in value) ?AgentNote.fromJson(item)] : [];
    memory
      ..seen = numbers(json['seen'])
      ..lastCheckAt = json['lastCheckAt'] is num ? (json['lastCheckAt'] as num).toDouble() : null
      ..lastBriefingDay = json['lastBriefingDay'] is String ? json['lastBriefingDay'] as String : null
      ..notes = list(json['notes'])
      ..pending = list(json['pending'])
      ..pendingHeadline = json['pendingHeadline'] is String ? json['pendingHeadline'] as String : null
      ..done = numbers(json['done'])
      ..markedRead = numbers(json['markedRead']);
    return memory;
  }

  Map<String, Object?> toJson() => {
    'seen': seen,
    'lastCheckAt': ?lastCheckAt,
    'lastBriefingDay': ?lastBriefingDay,
    'notes': [for (final note in notes) note.toJson()],
    'pending': [for (final note in pending) note.toJson()],
    'pendingHeadline': ?pendingHeadline,
    'done': done,
    'markedRead': markedRead,
  };

  /// Done items leave the Pending card and won't be mentioned again. Returns whether anything was new.
  bool markDone(Map<String, double> ids) {
    final fresh = {
      for (final entry in ids.entries)
        if (done[entry.key] == null) entry.key: entry.value,
    };
    if (fresh.isEmpty) return false;
    fresh.forEach((id, at) {
      done[id] = at;
      seen[id] = seen[id] ?? at;
    });
    pending.removeWhere((note) => done[note.id] != null);
    if (pending.isEmpty) pendingHeadline = null;
    return true;
  }

  /// Done Gmail threads that still need marking read. Only ids shaped like Gmail's (letters, digits, `-` and `_`) go: an
  /// id comes from Claude's reading of your mail or from a phone, and it is pasted into the one run that may change
  /// labels, so no id may carry words.
  List<String> get threadsToMarkRead =>
      [
        for (final id in done.keys)
          if (id.startsWith('mail:') && isThreadId(id.substring(5)) && markedRead[id.substring(5)] == null) id.substring(5),
      ]..sort();

  static final RegExp _threadId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// Whether [id] looks like a Gmail thread id (and so is safe to put in the mark-read prompt).
  static bool isThreadId(String id) => _threadId.hasMatch(id);

  /// A briefing replaces the Pending card; a check adds what's new to it.
  void updatePending(List<AgentNote> found, {required bool replacing, String? headline, required DateTime now}) {
    final notes = [
      for (final note in found)
        if (done[note.id] == null) note,
    ];
    if (replacing) {
      pending = notes;
      pendingHeadline = headline;
    } else if (notes.isNotEmpty) {
      final ids = {for (final note in notes) note.id};
      pending = [
        ...notes,
        for (final note in pending)
          if (!ids.contains(note.id)) note,
      ];
    }
    prunePending(now: now);
  }

  /// Events go once they've started (plus ten minutes), the rest after [pendingHours]. Returns whether anything changed.
  bool prunePending({required DateTime now}) {
    final before = [for (final note in pending) note.id];
    final time = now.millisecondsSinceEpoch / 1000;
    pending = ordered([
      for (final note in pending)
        if (note.due != null ? note.due! > time - 600 : note.at > time - pendingHours * 3600) note,
    ]).take(agentPendingMax).toList();
    if (pending.isEmpty && before.isNotEmpty) pendingHeadline = null;
    final after = [for (final note in pending) note.id];
    return after.length != before.length || Iterable<int>.generate(after.length).any((i) => after[i] != before[i]);
  }

  /// Coming events first (soonest first), then what needs you, then tasks, then the rest (newest first).
  static List<AgentNote> ordered(List<AgentNote> notes) {
    int group(AgentNote note) {
      if (note.source == AgentSource.calendar) return 0;
      if (note.important) return 1;
      return note.source == AgentSource.notion ? 2 : 3;
    }

    return _stableSorted(notes, (a, b) {
      final ga = group(a), gb = group(b);
      if (ga != gb) return ga.compareTo(gb);
      if (ga == 0) return (a.due ?? double.infinity).compareTo(b.due ?? double.infinity);
      return b.at.compareTo(a.at);
    });
  }

  /// The digest's items Mochi hasn't mentioned yet; they count as mentioned from now on. Notion tasks come back once a
  /// day while they stay open.
  AgentNews news(AgentDigest digest, {required DateTime now, List<String> vips = const []}) {
    final day = AgentSchedule.dayKey(now);
    final at = now.millisecondsSinceEpoch / 1000;
    bool fresh(String key, String item) {
      if (seen[key] != null || done[item] != null) return false;
      seen[key] = at;
      return true;
    }

    return AgentNews(
      emails: [
        for (final email in digest.emails)
          if (fresh('mail:${email.id}', 'mail:${email.id}')) email,
      ],
      events: [
        for (final event in digest.events)
          if (fresh('event:${event.id}', 'event:${event.id}')) event,
      ],
      tasks: [
        for (final task in digest.tasks)
          if (fresh('task:${task.id}:$day', 'task:${task.id}')) task,
      ],
      vips: vips,
    );
  }

  /// Marks everything in a briefing as mentioned, so the next check doesn't repeat it.
  void markSeen(AgentDigest digest, {required DateTime now}) => news(digest, now: now);

  void remember(List<AgentNote> found) {
    final ids = {for (final note in found) note.id};
    notes = [
      ...found,
      for (final note in notes)
        if (!ids.contains(note.id)) note,
    ].take(maxNotes).toList();
  }

  void prune({required DateTime now}) {
    final cutoff = now.millisecondsSinceEpoch / 1000 - keepDays * 86400;
    seen = {
      for (final entry in seen.entries)
        if (entry.value >= cutoff) entry.key: entry.value,
    };
    notes = [
      for (final note in notes)
        if (note.at >= cutoff) note,
    ];
    done = {
      for (final entry in done.entries)
        if (entry.value >= cutoff) entry.key: entry.value,
    };
    markedRead = {
      for (final entry in markedRead.entries)
        if (entry.value >= cutoff) entry.key: entry.value,
    };
  }
}

/// The newest marks from the last week, few enough for one link value (Swift `AgentDoneList.trimmed`, as mochi_link's).
AgentDoneList doneList(AgentMemory memory, {DateTime? now}) => AgentDoneList(ids: memory.done).trimmed(now: now);

// MARK: When to look

abstract final class AgentSchedule {
  /// [now] is the PC's local time.
  static bool checkDue(AgentSettings settings, {DateTime? lastCheck, required DateTime now}) {
    if (!settings.enabled || settings.quietHours.isActive(now)) return false;
    if (lastCheck == null) return true;
    final interval = settings.intervalMinutes < 5 ? 5 : settings.intervalMinutes;
    return now.difference(lastCheck).inMilliseconds / 1000 >= interval * 60 - 5;
  }

  /// Once a day, from the chosen time until three hours later (a PC that slept through it still briefs).
  static bool briefingDue(AgentSettings settings, {String? lastBriefingDay, required DateTime now}) {
    if (!settings.enabled || !settings.briefingEnabled || settings.quietHours.isActive(now) || dayKey(now) == lastBriefingDay) return false;
    final minute = now.hour * 60 + now.minute;
    return minute >= settings.briefingMinute && minute < settings.briefingMinute + 180;
  }

  /// Where a check picks up: a little before the last one, so nothing slips between them.
  static DateTime since({DateTime? lastCheck, required DateTime now}) {
    if (lastCheck == null || now.difference(lastCheck) >= const Duration(hours: 24)) return now.subtract(const Duration(hours: 2));
    return lastCheck.subtract(const Duration(seconds: 120));
  }

  /// "2026-11-03", in the PC's local time.
  static String dayKey(DateTime date) {
    final local = date.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}
