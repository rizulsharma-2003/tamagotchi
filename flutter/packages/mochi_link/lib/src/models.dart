// The values the apps share, in the exact shapes the Swift apps write (link-spec/fixtures). Field names are the
// Swift Codable names. `fromJson`/`fromValue` return null where Swift's decoding would fail (a required field
// missing or of the wrong type); `toValue` gives what to pass to `RelayLink.set`: a JSON string for the keys the
// Swift apps store that way (look, sessions, agent, macDone, phoneDone), a map for the rest.

import 'dart:convert';

import 'json.dart';
import 'link_key.dart';

Map<String, Object?> _numbers(Map<String, Object?> json) =>
    json.map((key, value) => MapEntry(key, value is num ? jsonNumber(value) : value));

// MARK: look

/// The pet's look (`look`, a JSON string): Swift `PetLook`. [room] and [seasonal] stay JSON (read them with
/// mochi_art's `RoomLayout.fromJson`); enum values are their Swift raw values (`cream`, `cozyDesk`, `plant`).
class PetLook {
  const PetLook({
    required this.petName,
    required this.companionName,
    required this.petColor,
    this.petAccessory,
    this.companionAccessory,
    this.deskAccessory,
    required this.theme,
    this.room = const {'items': <Object?>[]},
    this.seasonal = const {'enabled': true, 'decorateMenuBar': true},
    required this.friendshipLevel,
  });

  final String petName;
  final String companionName;

  /// cream · peach · mint · sky · lavender · cocoa · midnight
  final String petColor;
  final String? petAccessory;
  final String? companionAccessory;
  final String? deskAccessory;

  /// cozyDesk · cyberpunk · spaceStation · gardenOffice
  final String theme;

  /// `{items: [{id, kind, x, y, flipped}]}`
  final Map<String, Object?> room;

  /// `{enabled, birthdayMonth?, birthdayDay?, decorateMenuBar}`
  final Map<String, Object?> seasonal;
  final int friendshipLevel;

  static PetLook? fromJson(Object? json) {
    final j = asJsonMap(json);
    if (j == null) return null;
    final petName = jsonString(j['petName']), companionName = jsonString(j['companionName']);
    final petColor = jsonString(j['petColor']), theme = jsonString(j['theme']);
    final room = asJsonMap(j['room']), seasonal = asJsonMap(j['seasonal']), friendshipLevel = jsonInt(j['friendshipLevel']);
    if (petName == null || companionName == null || petColor == null || theme == null) return null;
    if (room == null || room['items'] is! List || seasonal == null || friendshipLevel == null) return null;
    return PetLook(
      petName: petName,
      companionName: companionName,
      petColor: petColor,
      petAccessory: jsonString(j['petAccessory']),
      companionAccessory: jsonString(j['companionAccessory']),
      deskAccessory: jsonString(j['deskAccessory']),
      theme: theme,
      room: room,
      seasonal: seasonal,
      friendshipLevel: friendshipLevel,
    );
  }

  /// From the stored value (its JSON string) or an already-decoded object.
  static PetLook? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => {
    'petName': petName,
    'companionName': companionName,
    'petColor': petColor,
    'petAccessory': ?petAccessory,
    'companionAccessory': ?companionAccessory,
    'deskAccessory': ?deskAccessory,
    'theme': theme,
    'room': room,
    'seasonal': seasonal,
    'friendshipLevel': friendshipLevel,
  };

  /// A JSON string, as the Mac stores it.
  String toValue() => jsonEncode(toJson());
}

// MARK: claude

/// What Claude is doing on the computer (`claude`, a map): Swift `ClaudeMirror` plus the `at` the Mac adds. Only
/// the phase and the kind of tool, never what it's working on.
class ClaudeMirror {
  const ClaudeMirror({required this.phase, this.category, this.resting = false, this.at});

  /// none · idle · working · waiting · done · error
  final String phase;

  /// think · edit · read · search · shell · web · agent · other
  final String? category;

  /// The computer is resting, so Mochi sleeps on the phone too.
  final bool resting;
  final double? at;

  static ClaudeMirror? fromJson(Object? json) {
    final j = asJsonMap(json);
    final phase = jsonString(j?['phase']);
    if (j == null || phase == null) return null;
    return ClaudeMirror(
      phase: phase,
      category: jsonString(j['category']),
      resting: jsonBool(j['resting']) ?? false,
      at: jsonDouble(j['at']),
    );
  }

  static ClaudeMirror? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => _numbers({'phase': phase, 'category': ?category, 'resting': resting, 'at': ?at});

  Map<String, Object?> toValue() => toJson();
}

// MARK: sessions

/// A finished turn as the phone shows it: Swift `TurnSummary`.
class TurnSummary {
  const TurnSummary({required this.done, this.session, this.next = const []});

  /// What Claude did or found this turn.
  final String done;

  /// What the session is working on overall.
  final String? session;

  /// Short requests the user might send next.
  final List<String> next;

  static TurnSummary? fromJson(Object? json) {
    final j = asJsonMap(json);
    final done = jsonString(j?['done']), next = jsonStrings(j?['next']);
    if (j == null || done == null || next == null) return null;
    return TurnSummary(done: done, session: jsonString(j['session']), next: next);
  }

  Map<String, Object?> toJson() => {'done': done, 'session': ?session, 'next': next};
}

/// A Claude session as Mochi Pocket lists it: Swift `PhoneSessionCard`.
class PhoneSessionCard {
  const PhoneSessionCard({
    required this.id,
    required this.project,
    required this.phase,
    this.summary,
    this.files = const [],
    this.finishedAt,
    this.phaseSince,
  });

  final String id;
  final String project;

  /// working · waiting · done · error · idle
  final String phase;
  final TurnSummary? summary;
  final List<String> files;

  /// When Claude finished the summarized turn (Unix time).
  final double? finishedAt;

  /// When the current phase began.
  final double? phaseSince;

  static PhoneSessionCard? fromJson(Object? json) {
    final j = asJsonMap(json);
    if (j == null) return null;
    final id = jsonString(j['id']), project = jsonString(j['project']), phase = jsonString(j['phase']), files = jsonStrings(j['files']);
    if (id == null || project == null || phase == null || files == null) return null;
    final summary = TurnSummary.fromJson(j['summary']);
    if (j['summary'] != null && summary == null) return null;
    return PhoneSessionCard(
      id: id,
      project: project,
      phase: phase,
      summary: summary,
      files: files,
      finishedAt: jsonDouble(j['finishedAt']),
      phaseSince: jsonDouble(j['phaseSince']),
    );
  }

  Map<String, Object?> toJson() => _numbers({
    'id': id,
    'project': project,
    'phase': phase,
    'summary': ?summary?.toJson(),
    'files': files,
    'finishedAt': ?finishedAt,
    'phaseSince': ?phaseSince,
  });
}

/// The computer's Claude sessions (`sessions`, a JSON string): Swift `PhoneSessions`.
class PhoneSessions {
  const PhoneSessions({required this.enabled, this.sessions = const [], this.updatedAt});

  /// The computer shares summaries.
  final bool enabled;
  final List<PhoneSessionCard> sessions;
  final double? updatedAt;

  static PhoneSessions? fromJson(Object? json) {
    final j = asJsonMap(json);
    final enabled = jsonBool(j?['enabled']), raw = j?['sessions'];
    if (j == null || enabled == null || raw is! List) return null;
    final sessions = raw.map(PhoneSessionCard.fromJson).toList();
    if (sessions.contains(null)) return null;
    return PhoneSessions(
      enabled: enabled,
      sessions: sessions.whereType<PhoneSessionCard>().toList(),
      updatedAt: jsonDouble(j['updatedAt']),
    );
  }

  static PhoneSessions? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => _numbers({
    'enabled': enabled,
    'sessions': [for (final card in sessions) card.toJson()],
    'updatedAt': ?updatedAt,
  });

  String toValue() => jsonEncode(toJson());
}

// MARK: agent

/// Where an agent note came from: Swift `AgentSource`.
enum AgentSource {
  gmail,
  calendar,
  notion;

  static AgentSource? tryParse(Object? raw) {
    for (final source in values) {
      if (source.name == raw) return source;
    }
    return null;
  }
}

/// One thing Mochi told the user: Swift `AgentNote`.
class AgentNote {
  const AgentNote({
    required this.id,
    required this.source,
    required this.title,
    required this.detail,
    required this.important,
    required this.at,
    this.due,
    this.link,
    this.subject,
    this.vip,
  });

  final String id;
  final AgentSource source;
  final String title;
  final String detail;
  final bool important;
  final double at;

  /// When an event starts (Unix time).
  final double? due;

  /// The Gmail thread or the Notion page.
  final String? link;

  /// An email's subject line.
  final String? subject;

  /// From one of your VIPs.
  final bool? vip;

  /// A Gmail thread's id, for "mail:<id>" notes.
  String? get threadId => source == AgentSource.gmail && id.startsWith('mail:') ? id.substring(5) : null;

  static AgentNote? fromJson(Object? json) {
    final j = asJsonMap(json);
    if (j == null) return null;
    final id = jsonString(j['id']), source = AgentSource.tryParse(j['source']), title = jsonString(j['title']);
    final detail = jsonString(j['detail']), important = jsonBool(j['important']), at = jsonDouble(j['at']);
    if (id == null || source == null || title == null || detail == null || important == null || at == null) return null;
    return AgentNote(
      id: id,
      source: source,
      title: title,
      detail: detail,
      important: important,
      at: at,
      due: jsonDouble(j['due']),
      link: jsonString(j['link']),
      subject: jsonString(j['subject']),
      vip: jsonBool(j['vip']),
    );
  }

  Map<String, Object?> toJson() => _numbers({
    'id': id,
    'source': source.name,
    'title': title,
    'detail': detail,
    'important': important,
    'at': at,
    'due': ?due,
    'link': ?link,
    'subject': ?subject,
    'vip': ?vip,
  });
}

/// What's waiting for you as of the computer's last look (`agent`, a JSON string): Swift `AgentPending`.
class AgentPending {
  const AgentPending({required this.enabled, this.headline, this.items = const [], this.lookedAt, this.updatedAt, this.origin});

  final bool enabled;
  final String? headline;
  final List<AgentNote> items;
  final double? lookedAt;
  final double? updatedAt;

  /// Null from the computer; "cloud" from an hourly Mochi Cloud run, "cloud-manual" from "Check now".
  final String? origin;

  static AgentPending? fromJson(Object? json) {
    final j = asJsonMap(json);
    final enabled = jsonBool(j?['enabled']), raw = j?['items'];
    if (j == null || enabled == null || raw is! List) return null;
    final items = raw.map(AgentNote.fromJson).toList();
    if (items.contains(null)) return null;
    return AgentPending(
      enabled: enabled,
      headline: jsonString(j['headline']),
      items: items.whereType<AgentNote>().toList(),
      lookedAt: jsonDouble(j['lookedAt']),
      updatedAt: jsonDouble(j['updatedAt']),
      origin: jsonString(j['origin']),
    );
  }

  static AgentPending? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => _numbers({
    'enabled': enabled,
    'headline': ?headline,
    'items': [for (final item in items) item.toJson()],
    'lookedAt': ?lookedAt,
    'updatedAt': ?updatedAt,
    'origin': ?origin,
  });

  String toValue() => jsonEncode(toJson());
}

/// What one device marked done (`macDone` / `phoneDone`, JSON strings): Swift `AgentDoneList`. Each side keeps the
/// union.
class AgentDoneList {
  const AgentDoneList({this.ids = const {}});

  /// Note id → when it was marked done (Unix time).
  final Map<String, double> ids;

  static const int maxItems = 300;

  static AgentDoneList? fromJson(Object? json) {
    final ids = asJsonMap(asJsonMap(json)?['ids']);
    if (ids == null || ids.values.any((value) => value is! num)) return null;
    return AgentDoneList(ids: ids.map((id, at) => MapEntry(id, (at! as num).toDouble())));
  }

  static AgentDoneList? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  /// Both lists, keeping the later mark for an id marked on both.
  AgentDoneList union(AgentDoneList other) {
    final merged = {...ids};
    other.ids.forEach((id, at) => merged[id] = merged[id] == null || merged[id]! < at ? at : merged[id]!);
    return AgentDoneList(ids: merged);
  }

  /// The newest marks from the last week, few enough for one value (Swift `trimmed`).
  AgentDoneList trimmed({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000 - 7 * 86400;
    final kept = ids.entries.where((entry) => entry.value >= cutoff).toList()..sort((a, b) => b.value.compareTo(a.value));
    return AgentDoneList(ids: Map.fromEntries(kept.take(maxItems)));
  }

  Map<String, Object?> toJson() => {'ids': _numbers(ids)};

  String toValue() => jsonEncode(toJson());
}

// MARK: Messages and the smaller state values (maps)

/// A request to the computer (`command`, phone → host): for Mochi, or with [project]/[session] for that Claude
/// session.
class LinkCommand {
  const LinkCommand({required this.id, required this.text, required this.at, this.typed = false, this.project, this.session});

  final String id;
  final String text;
  final double at;

  /// Typed rather than spoken.
  final bool typed;
  final String? project;
  final String? session;

  static LinkCommand? fromJson(Object? json) {
    final j = asJsonMap(json);
    final id = jsonString(j?['id']), text = jsonString(j?['text']), at = jsonDouble(j?['at']);
    if (j == null || id == null || text == null || at == null) return null;
    return LinkCommand(
      id: id,
      text: text,
      at: at,
      typed: jsonBool(j['typed']) ?? false,
      project: jsonString(j['project']),
      session: jsonString(j['session']),
    );
  }

  static LinkCommand? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => _numbers({'id': id, 'text': text, 'at': at, 'typed': typed, 'project': ?project, 'session': ?session});

  Map<String, Object?> toValue() => toJson();
}

/// The computer's answer to a command (`reply`, host → phone), with the command's [id].
class LinkReply {
  const LinkReply({required this.id, required this.state, this.text, required this.at});

  final String id;

  /// working · done · failed
  final String state;
  final String? text;
  final double at;

  static LinkReply? fromJson(Object? json) {
    final j = asJsonMap(json);
    final id = jsonString(j?['id']), state = jsonString(j?['state']), at = jsonDouble(j?['at']);
    if (j == null || id == null || state == null || at == null) return null;
    return LinkReply(id: id, state: state, text: jsonString(j['text']), at: at);
  }

  static LinkReply? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => _numbers({'id': id, 'state': state, 'text': ?text, 'at': at});

  Map<String, Object?> toValue() => toJson();
}

/// A permission Claude asks for on the computer (`approval`, state; cleared once answered).
class ApprovalRequest {
  const ApprovalRequest({required this.id, this.command, required this.target, this.project, required this.message, required this.at});

  final String id;

  /// The command that led to it.
  final String? command;

  /// The Claude session it's for.
  final String target;
  final String? project;
  final String message;
  final double at;

  static ApprovalRequest? fromJson(Object? json) {
    final j = asJsonMap(json);
    final id = jsonString(j?['id']), target = jsonString(j?['target']), message = jsonString(j?['message']), at = jsonDouble(j?['at']);
    if (j == null || id == null || target == null || message == null || at == null) return null;
    return ApprovalRequest(
      id: id,
      command: jsonString(j['command']),
      target: target,
      project: jsonString(j['project']),
      message: message,
      at: at,
    );
  }

  static ApprovalRequest? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() =>
      _numbers({'id': id, 'command': ?command, 'target': target, 'project': ?project, 'message': message, 'at': at});

  Map<String, Object?> toValue() => toJson();
}

/// The answer to an [ApprovalRequest] (`verdict`, phone → host), with the request's [id].
class LinkVerdict {
  const LinkVerdict({required this.id, required this.allow, required this.at});

  final String id;
  final bool allow;
  final double at;

  static LinkVerdict? fromJson(Object? json) {
    final j = asJsonMap(json);
    final id = jsonString(j?['id']), allow = jsonBool(j?['allow']), at = jsonDouble(j?['at']);
    if (j == null || id == null || allow == null || at == null) return null;
    return LinkVerdict(id: id, allow: allow, at: at);
  }

  static LinkVerdict? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => _numbers({'id': id, 'allow': allow, 'at': at});

  Map<String, Object?> toValue() => toJson();
}

/// A pet, play or treat from the other side (`macInteraction` / `phoneInteraction`).
class LinkInteraction {
  const LinkInteraction({required this.id, required this.kind, required this.at});

  final String id;

  /// pet · play · treat
  final String kind;
  final double at;

  static LinkInteraction? fromJson(Object? json) {
    final j = asJsonMap(json);
    final id = jsonString(j?['id']), kind = jsonString(j?['kind']), at = jsonDouble(j?['at']);
    if (j == null || id == null || kind == null || at == null) return null;
    return LinkInteraction(id: id, kind: kind, at: at);
  }

  static LinkInteraction? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => _numbers({'id': id, 'kind': kind, 'at': at});

  Map<String, Object?> toValue() => toJson();
}

/// The computer ended its Live Activity (`activityEnded`, host → phone).
class ActivityEnded {
  const ActivityEnded({required this.at, this.since, this.dismissAt});

  final double at;

  /// The activity that ended began then (or earlier).
  final double? since;
  final double? dismissAt;

  static ActivityEnded? fromJson(Object? json) {
    final j = asJsonMap(json);
    final at = jsonDouble(j?['at']);
    if (j == null || at == null) return null;
    return ActivityEnded(at: at, since: jsonDouble(j['since']), dismissAt: jsonDouble(j['dismissAt']));
  }

  static ActivityEnded? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => _numbers({'at': at, 'since': ?since, 'dismissAt': ?dismissAt});

  Map<String, Object?> toValue() => toJson();
}

/// Mochi Cloud's trigger (`cloud`, state): the phone fires it directly for "Check now" and "Draft reply".
class CloudTrigger {
  const CloudTrigger({required this.url, required this.token});

  final String url;
  final String token;

  static CloudTrigger? fromJson(Object? json) {
    final j = asJsonMap(json);
    final url = jsonString(j?['url']), token = jsonString(j?['token']);
    if (url == null || token == null) return null;
    return CloudTrigger(url: url, token: token);
  }

  static CloudTrigger? fromValue(Object? value) => fromJson(jsonObjectValue(value));

  Map<String, Object?> toJson() => {'url': url, 'token': token};

  Map<String, Object?> toValue() => toJson();

  @override
  String toString() => 'CloudTrigger($url)';
}

/// Decodes the value of [key] (as [RelayLink.value] returns it) into its model: [PetLook], [ClaudeMirror],
/// [PhoneSessions], [AgentPending], [CloudTrigger], [ApprovalRequest], [AgentDoneList], [ActivityEnded],
/// [LinkInteraction], [LinkCommand], [LinkReply] or [LinkVerdict]. Null when it doesn't decode, and for
/// registration keys (plain strings and maps).
Object? decodeLinkValue(LinkKey key, Object? value) => switch (key) {
  LinkKey.look => PetLook.fromValue(value),
  LinkKey.claude => ClaudeMirror.fromValue(value),
  LinkKey.sessions => PhoneSessions.fromValue(value),
  LinkKey.agent => AgentPending.fromValue(value),
  LinkKey.cloud => CloudTrigger.fromValue(value),
  LinkKey.approval => ApprovalRequest.fromValue(value),
  LinkKey.macDone || LinkKey.phoneDone => AgentDoneList.fromValue(value),
  LinkKey.activityEnded => ActivityEnded.fromValue(value),
  LinkKey.macInteraction || LinkKey.phoneInteraction => LinkInteraction.fromValue(value),
  LinkKey.command => LinkCommand.fromValue(value),
  LinkKey.reply => LinkReply.fromValue(value),
  LinkKey.verdict => LinkVerdict.fromValue(value),
  LinkKey.pushToStart || LinkKey.updateTokens || LinkKey.deviceToken || LinkKey.tokensSavedAt => null,
};
