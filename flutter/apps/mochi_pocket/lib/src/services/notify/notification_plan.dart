import 'dart:convert';

import 'package:mochi_link/mochi_link.dart';

/// The buttons a Mochi notification can have (iOS/MochiPocket/PhoneNotifications.swift, same ids):
///
/// - **Reply** on "Claude finished" (`claude-turn`): you type the session's next request in the notification.
/// - **Join** on a meeting heads-up with a video link (`mochi-meeting`): opens Meet, Zoom or Teams.
/// - **Open in Gmail** on "Reply drafted" (`mochi-draft`).
/// - **Mark done** on Mochi's news about mail, meetings and tasks (`mochi-agent`, `mochi-meeting`): the items it's
///   about, done here, on your computer and on your other phones, as the circle in "Waiting for you" does.
///
/// Reply and Mark done work without opening the app; Join and Open in Gmail open it, then the link.
enum AlertAction {
  reply('reply'),
  join('join'),
  openDraft('open-draft'),
  markDone('done');

  const AlertAction(this.id);

  /// The action's id in the notification (the iPhone's identifiers, plus `done`).
  final String id;

  /// Reply and Mark done run in the background; the others need the app in front to open their link.
  bool get opensApp => this == join || this == openDraft;

  static AlertAction? parse(String? id) => values.where((action) => action.id == id).firstOrNull;
}

/// What a notification's buttons need to act without the app's state, kept with the notification (Android's
/// notification payload, a JSON string). Never secrets: the room id says which pairing the action belongs to.
class NotificationPayload {
  const NotificationPayload({
    required this.alert,
    this.room,
    this.title,
    this.project,
    this.session,
    this.join,
    this.link,
    this.thread,
    this.ids = const [],
    this.names = const [],
  });

  /// The alert's id.
  final String alert;

  /// The room the alert came from: an action only goes to that room.
  final String? room;

  /// The notification's title, for the confirmation that replaces it.
  final String? title;

  /// The Claude session a reply goes to.
  final String? project;
  final String? session;

  /// A meeting's video link.
  final String? join;

  /// "Reply drafted": the draft in Gmail, and its thread (for the Gmail app).
  final String? link;
  final String? thread;

  /// The items Mark done marks, and their titles for the confirmation.
  final List<String> ids;
  final List<String> names;

  String encode() => jsonEncode({
    'v': 1,
    'alert': alert,
    'room': ?room,
    'title': ?title,
    'project': ?project,
    'session': ?session,
    'join': ?join,
    'link': ?link,
    'thread': ?thread,
    if (ids.isNotEmpty) 'ids': ids,
    if (names.isNotEmpty) 'names': names,
  });

  static NotificationPayload? decode(String? text) {
    if (text == null || text.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded['alert'] is! String) return null;
    final json = decoded;
    String? string(String key) => json[key] is String ? json[key] as String : null;
    List<String> strings(String key) => [if (json[key] is List) ...(json[key] as List).whereType<String>()];
    return NotificationPayload(
      alert: json['alert'] as String,
      room: string('room'),
      title: string('title'),
      project: string('project'),
      session: string('session'),
      join: string('join'),
      link: string('link'),
      thread: string('thread'),
      ids: strings('ids'),
      names: strings('names'),
    );
  }
}

/// How one alert shows: its buttons, in order, and the payload they act on.
class NotificationPlan {
  const NotificationPlan({required this.actions, required this.payload});

  final List<AlertAction> actions;
  final NotificationPayload payload;

  /// Mark done is offered for news about one to three things; a longer briefing isn't something to finish in one tap.
  static const int maxMarked = 3;

  /// Items noted within this long of the newest one came in together: what the notification is about.
  static const double batch = 180;

  /// The plan for [alert] from the room [room]. [isDone] leaves out items already marked done.
  ///
  /// The buttons follow what the alert carries (the Mac's and Mochi Cloud's payloads): `project` and `session` (a
  /// finished turn) give Reply; an https `join` gives Join; `kind: draft` with an https `link` gives Open in Gmail; and
  /// `kind: agent` with a card gives Mark done for the items that came in with it (the card's newest, not yet done).
  static NotificationPlan forAlert(LinkAlert alert, {String? room, bool Function(String id)? isDone}) {
    final info = alert.userInfo;
    String? string(String key) => info[key] is String && (info[key] as String).isNotEmpty ? info[key] as String : null;
    final project = string('project'), session = string('session');
    final join = _https(string('join'));
    final kind = string('kind');
    final draftLink = kind == 'draft' ? _https(string('link')) : null;
    final news = kind == 'agent' ? newest(AgentPending.fromJson(info['pending']), isDone: isDone) : const <AgentNote>[];
    final marked = news.length <= maxMarked ? news : const <AgentNote>[];
    return NotificationPlan(
      actions: [
        if (project != null && session != null) AlertAction.reply,
        if (join != null) AlertAction.join,
        if (draftLink != null) AlertAction.openDraft,
        if (marked.isNotEmpty) AlertAction.markDone,
      ],
      payload: NotificationPayload(
        alert: alert.id,
        room: room,
        title: alert.title,
        project: project,
        session: session,
        join: join,
        link: draftLink,
        thread: draftLink == null ? null : string('thread'),
        ids: [for (final note in marked) note.id],
        names: [for (final note in marked) note.title],
      ),
    );
  }

  /// The items a news card's notification is about: those noted together most recently (the Mac and Mochi Cloud
  /// stamp each check's finds with the same time), leaving out what's done.
  static List<AgentNote> newest(AgentPending? card, {bool Function(String id)? isDone}) {
    final open = [
      for (final note in card?.items ?? const <AgentNote>[])
        if (!(isDone?.call(note.id) ?? false)) note,
    ];
    if (open.isEmpty) return const [];
    final latest = open.map((note) => note.at).reduce((a, b) => a > b ? a : b);
    return [
      for (final note in open)
        if (latest - note.at <= batch) note,
    ];
  }

  /// The Mark done button's words: "Mark done", "Mark both done", "Mark all 3 done".
  static String markDoneTitle(int count) => switch (count) {
    <= 1 => 'Mark done',
    2 => 'Mark both done',
    _ => 'Mark all $count done',
  };

  static String? _https(String? link) {
    final uri = Uri.tryParse(link ?? '');
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty ? link : null;
  }
}
