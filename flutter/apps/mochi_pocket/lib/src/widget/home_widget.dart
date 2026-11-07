import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mochi_home_widget/mochi_home_widget.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/done_marks.dart';
import '../model/mochi_cloud.dart';
import '../model/pocket_model.dart';
import '../services/local_file.dart';

/// Claude as the widget last heard: the phase to draw, one of its ten poses, what to say, and when it was heard.
class WidgetClaude {
  const WidgetClaude({required this.art, required this.title, required this.at, this.frame});

  /// working · waiting · done · error · idle · asleep (the iPhone's scene art).
  final String art;
  final String title;
  final double at;
  final int? frame;

  static WidgetClaude? fromJson(Object? json) {
    if (json is! Map) return null;
    final art = json['art'], title = json['title'], at = json['at'], frame = json['frame'];
    if (art is! String || title is! String || at is! num) return null;
    return WidgetClaude(art: art, title: title, at: at.toDouble(), frame: frame is num ? frame.toInt() : null);
  }

  Map<String, Object?> toJson() => {'art': art, 'title': title, 'at': at, 'frame': ?frame};
}

/// What the home-screen widget knows (`home_widget.json` in the app's files): the app writes it from what it sees in
/// the room, and the push handler updates it from pushes while Mochi is closed (Mochi's news, a finished turn, Claude's
/// Live Activity). Only the room it shows takes updates, so a development build's test room never mixes with the
/// real one. Like the iPhone's widget snapshot, it stays on this phone.
class WidgetSnapshot {
  const WidgetSnapshot({
    this.room,
    this.petName = 'Mochi',
    this.host = 'your computer',
    this.hostAway = false,
    this.claude,
    this.sessions = const [],
    this.sessionsShared,
    this.card,
    this.updatedAt = 0,
  });

  /// The room it shows; null: this phone isn't paired.
  final String? room;
  final String petName;

  /// The computer, as the phone names it: "your Mac", "your PC".
  final String host;

  /// The computer isn't connected (asleep or off).
  final bool hostAway;
  final WidgetClaude? claude;

  /// Claude's sessions on the computer, when it shares summaries.
  final List<PhoneSessionCard> sessions;
  final bool? sessionsShared;

  /// "Waiting for you", as the app last had it (items you marked done are left out when it's drawn).
  final AgentPending? card;

  /// When it was last brought up to date (Unix time).
  final double updatedAt;

  static const String file = 'home_widget.json';

  /// At most this many sessions on the widget.
  static const int maxSessions = 3;

  bool get paired => room != null;

  /// From the app's model: everything the room shares right now. What the room hasn't said yet since the app started
  /// (the relay is still syncing, or out of reach) stays as [previous] had it, for the same room.
  static WidgetSnapshot fromModel(PocketModel model, {required double now, WidgetSnapshot? previous}) {
    final room = model.credentials?.room;
    if (!model.paired || room == null) return WidgetSnapshot(updatedAt: now);
    final before = previous?.room == room ? previous : null;
    final mirror = model.claude;
    final shared = model.summariesShared;
    return WidgetSnapshot(
      room: room,
      petName: model.look == null ? (before?.petName ?? model.petName) : model.petName,
      host: model.host.yours,
      // Away once the relay has listed the room and the computer isn't in it, not while that list is coming.
      hostAway: model.connection == MacConnection.macAway && model.mac != null,
      claude: mirror == null
          ? before?.claude
          : WidgetClaude(
              art: mirror.resting ? 'asleep' : _art(mirror.phase),
              title: mirror.resting ? '${model.petName} is napping' : titleFor(mirror.phase),
              at: now,
            ),
      sessions: shared == null ? (before?.sessions ?? const []) : model.sessions,
      sessionsShared: shared ?? before?.sessionsShared,
      card: model.agent ?? before?.card,
      updatedAt: now,
    );
  }

  /// "Claude is working", as the Live Activity says it.
  static String titleFor(String phase) => switch (phase) {
    'working' => 'Claude is working',
    'waiting' => 'Claude needs you',
    'done' => 'Claude finished!',
    'error' => 'Claude hit a snag',
    _ => 'Claude is idle',
  };

  static String _art(String phase) => LinkLiveActivity.phases.contains(phase) ? phase : 'idle';

  /// An alert opened by the push handler: the news card it carries (merged as the app merges it) and a finished turn's
  /// session card.
  WidgetSnapshot withAlert(LinkAlert alert, {required double now}) {
    var card = this.card;
    final pending = AgentPending.fromJson(alert.userInfo['pending']);
    if (pending != null && (card == null || (pending.updatedAt ?? 0) > (card.updatedAt ?? 0))) {
      card = card == null ? pending : AgentCards.merge(card, pending, now: now);
    }
    var sessions = this.sessions;
    var shared = sessionsShared;
    final turn = PhoneSessionCard.fromJson(alert.userInfo['card']);
    if (turn != null) {
      sessions = [turn, ...sessions.where((session) => session.id != turn.id)];
      shared = true;
    }
    return _copy(card: card, sessions: sessions, sessionsShared: shared, updatedAt: now);
  }

  /// Claude's Live Activity, opened by the push handler: Mochi's pose and what Claude is doing.
  WidgetSnapshot withLiveActivity(LinkLiveActivity activity, {required double now}) => _copy(
    claude: WidgetClaude(
      art: _art(activity.art),
      // A title that didn't open is only a placeholder: say it the widget's way instead.
      title: activity.opened ? activity.title : titleFor(activity.art),
      at: now,
      frame: activity.frame,
    ),
    hostAway: false,
    updatedAt: now,
  );

  WidgetSnapshot _copy({
    WidgetClaude? claude,
    List<PhoneSessionCard>? sessions,
    bool? sessionsShared,
    AgentPending? card,
    bool? hostAway,
    required double updatedAt,
  }) => WidgetSnapshot(
    room: room,
    petName: petName,
    host: host,
    hostAway: hostAway ?? this.hostAway,
    claude: claude ?? this.claude,
    sessions: sessions ?? this.sessions,
    sessionsShared: sessionsShared ?? this.sessionsShared,
    card: card ?? this.card,
    updatedAt: updatedAt,
  );

  static WidgetSnapshot? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final sessions = json['sessions'];
    return WidgetSnapshot(
      room: json['room'] as String?,
      petName: json['petName'] as String? ?? 'Mochi',
      host: json['host'] as String? ?? 'your computer',
      hostAway: json['hostAway'] == true,
      claude: WidgetClaude.fromJson(json['claude']),
      sessions: [if (sessions is List) ...sessions.map(PhoneSessionCard.fromJson).nonNulls],
      sessionsShared: json['sessionsShared'] as bool?,
      card: AgentPending.fromJson(json['card']),
      updatedAt: (json['updatedAt'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, Object?> toJson() => {
    'room': ?room,
    'petName': petName,
    'host': host,
    'hostAway': hostAway,
    'claude': ?claude?.toJson(),
    'sessions': [for (final session in sessions) session.toJson()],
    'sessionsShared': ?sessionsShared,
    'card': ?card?.toJson(),
    'updatedAt': updatedAt,
  };
}

/// What the widget draws, worked out here so the words are the app's (and name the real computer); the widget only
/// lays them out, formats times in the phone's style, and drops a meeting ten minutes after it starts.
abstract final class HomeWidgetView {
  /// Claude is working for a long time with no word from the computer: it's probably asleep mid-turn.
  static const Duration workingFor = Duration(minutes: 30);

  /// Claude can wait for you a long time (the Live Activity's eight hours).
  static const Duration waitingFor = Duration(hours: 8);

  static const int maxItems = 8;

  /// The map for the plugin (and the widget's provider in the app).
  static Map<String, Object?> of(WidgetSnapshot snapshot, {required bool Function(String id) isDone, required double now}) {
    final pet = snapshot.petName;
    if (!snapshot.paired) {
      return {
        'v': 1,
        'paired': false,
        'title': "$pet isn't paired yet",
        'text': 'Open Mochi and pair it with your Mac or PC.',
        'art': 'idle',
        'updatedMs': (now * 1000).round(),
      };
    }
    final host = snapshot.host;
    final where = 'On $host';
    final claude = snapshot.claude;
    final sessions = snapshot.sessionsShared == true
        ? snapshot.sessions.take(WidgetSnapshot.maxSessions).toList()
        : const <PhoneSessionCard>[];
    final busy = claude == null ? null : sessions.where((session) => session.phase == claude.art).firstOrNull;
    final String title, text, art;
    int? frame;
    double? staleAt;
    if (snapshot.hostAway) {
      title = '${_capitalized(host)} is away';
      text = '$pet is napping';
      art = 'asleep';
    } else if (claude == null) {
      title = '$pet & Claude';
      text = where;
      art = 'idle';
    } else {
      title = claude.title;
      text = busy == null ? where : '${busy.project} · on $host';
      art = claude.art;
      frame = claude.frame;
      staleAt = switch (claude.art) {
        'working' => claude.at + workingFor.inSeconds,
        'waiting' => claude.at + waitingFor.inSeconds,
        _ => null,
      };
    }
    final card = snapshot.card;
    final waitingKnown = card != null && card.enabled;
    final items = waitingKnown
        ? [
            for (final note in card.items)
              if (!isDone(note.id) && (note.due == null || note.due! > now - 600)) note,
          ].take(maxItems).toList()
        : const <AgentNote>[];
    return {
      'v': 1,
      'paired': true,
      'petName': pet,
      // The computer, by name ("your Mac"), for the Quick Settings tile's description too.
      'host': host,
      'title': title,
      'text': text,
      'art': art,
      'frame': ?frame,
      'staleAtMs': ?(staleAt == null ? null : (staleAt * 1000).round()),
      'restTitle': 'Claude is idle',
      'restText': where,
      'restArt': 'idle',
      'sessionsTitle': 'Claude on $host',
      'sessions': [
        for (final session in sessions) {'project': session.project, 'status': sessionStatus(session.phase), 'phase': _dot(session.phase)},
      ],
      'waitingKnown': waitingKnown,
      'waitingTitle': 'Waiting for you',
      'emptyText': 'Nothing waiting. $pet will tell you when something comes in.',
      'items': [for (final note in items) _item(note)],
      'updatedMs': (snapshot.updatedAt * 1000).round(),
    };
  }

  /// A session's status in a word or two, as its card in the app says it.
  static String sessionStatus(String phase) => switch (phase) {
    'working' => 'Working',
    'waiting' => 'Needs you',
    'done' => 'Finished',
    'error' => 'Hit a snag',
    _ => 'Idle',
  };

  static String _dot(String phase) => const {'working', 'waiting', 'done', 'error'}.contains(phase) ? phase : 'idle';

  /// One row: a meeting's title (the widget adds its time), who an email is from and what about, a task and its due.
  static Map<String, Object?> _item(AgentNote note) {
    final text = switch (note.source) {
      AgentSource.calendar => note.title,
      AgentSource.gmail => '${note.title}: ${note.subject ?? note.detail}',
      AgentSource.notion => note.detail.isEmpty ? note.title : '${note.title} · ${note.detail}',
    };
    return {
      'kind': note.source.name,
      'text': text,
      'vip': note.vip == true,
      'important': note.important,
      if (note.source == AgentSource.calendar && note.due != null) 'dueMs': (note.due! * 1000).round(),
      if (note.due != null) 'leavesMs': ((note.due! + 600) * 1000).round(),
    };
  }

  static String _capitalized(String text) => text.startsWith('your ') ? 'Y${text.substring(1)}' : text;
}

/// Where the widget's view goes: the plugin on the phone, a fake in tests.
abstract interface class WidgetSurface {
  /// Draws [view] on every widget on the home screen.
  Future<void> show(Map<String, Object?> view);

  /// Asks the launcher to add the widget. False when it can't be asked.
  Future<bool> pin();

  Future<HomeWidgetPlacement> status();
}

class PluginWidgetSurface implements WidgetSurface {
  const PluginWidgetSurface();

  @override
  Future<void> show(Map<String, Object?> view) => MochiHomeWidget.update(view);

  @override
  Future<bool> pin() => MochiHomeWidget.pin();

  @override
  Future<HomeWidgetPlacement> status() => MochiHomeWidget.status();
}

/// The home-screen widget, "Mochi & Claude" (A2): keeps [WidgetSnapshot] and shows it on [surface]. The app updates it
/// as the room changes ([HomeWidgetSync]); the push handler with [alertArrived], [liveActivityArrived] and
/// [doneChanged].
class HomeWidget {
  HomeWidget({required LocalDocument document, required this.surface, DateTime Function()? clock})
    : _document = document,
      _clock = clock ?? DateTime.now;

  final LocalDocument _document;
  final WidgetSurface surface;
  final DateTime Function() _clock;
  String? _shown;

  double get _now => _clock().millisecondsSinceEpoch / 1000;

  Future<WidgetSnapshot?> read() async {
    try {
      return WidgetSnapshot.fromJson(await _document.read());
    } on Object {
      return null;
    }
  }

  /// Keeps [snapshot] and draws it (unless the widget already shows exactly that).
  Future<void> publish(WidgetSnapshot snapshot, {required bool Function(String id) isDone, bool force = false}) async {
    try {
      await _document.write(snapshot.toJson());
    } on Object catch (error) {
      _log('the widget snapshot was not saved (${error.runtimeType})');
    }
    final view = HomeWidgetView.of(snapshot, isDone: isDone, now: _now);
    final key = jsonEncode({...view, 'updatedMs': null});
    if (!force && key == _shown) return;
    _shown = key;
    try {
      await surface.show(view);
    } on Object catch (error) {
      _log('the widget was not updated (${error.runtimeType})');
    }
  }

  /// [change] applied to what the widget knows, if it shows [room], then drawn. False when it shows another room or
  /// none.
  Future<bool> _apply(String room, WidgetSnapshot Function(WidgetSnapshot snapshot) change, {required LocalDocument done}) async {
    final snapshot = await read();
    if (snapshot == null || snapshot.room != room) return false;
    DoneMarks marks;
    try {
      marks = DoneMarks.fromJson(await done.read());
    } on Object {
      marks = DoneMarks();
    }
    await publish(change(snapshot), isDone: marks.isDone, force: true);
    return true;
  }

  /// An alert from [room] opened by the push handler (Mochi's news, a finished turn).
  Future<bool> alertArrived(String room, LinkAlert alert, {required LocalDocument done}) =>
      _apply(room, (snapshot) => snapshot.withAlert(alert, now: _now), done: done);

  /// Claude's Live Activity from [room], opened by the push handler (shown here even when the lock screen's is off).
  Future<bool> liveActivityArrived(String room, LinkLiveActivity activity, {required LocalDocument done}) =>
      _apply(room, (snapshot) => snapshot.withLiveActivity(activity, now: _now), done: done);

  /// Something was marked done from a notification while Mochi was closed: it leaves the widget too.
  Future<bool> doneChanged(String room, {required LocalDocument done}) => _apply(room, (snapshot) => snapshot, done: done);

  /// The app's own files: the snapshot beside done.json, and the plugin to draw it.
  static HomeWidget inFolder(String? folder) =>
      HomeWidget(document: AppFiles.document(folder, WidgetSnapshot.file), surface: const PluginWidgetSurface());

  static void _log(String message) {
    if (kDebugMode) debugPrint('Mochi: $message');
  }
}

/// The app's side: the widget follows the room while Mochi runs. Changes are gathered for a moment before drawing,
/// and it's drawn again every few minutes so Claude's status stays fresh while nothing else changes.
class HomeWidgetSync {
  HomeWidgetSync({
    required this.model,
    required this.widget,
    this.settle = const Duration(milliseconds: 400),
    this.refresh = const Duration(minutes: 10),
  });

  final PocketModel model;
  final HomeWidget widget;
  final Duration settle;
  final Duration refresh;
  Timer? _settle;
  Timer? _refresh;

  /// What the widget showed before the app started (read once), for what the room hasn't said yet.
  WidgetSnapshot? _previous;
  bool _readPrevious = false;

  void start() {
    model.addListener(_changed);
    _refresh = Timer.periodic(refresh, (_) => unawaited(publishNow(force: true)));
    _changed();
  }

  void _changed() {
    // Not before the saved pairing is read: the widget would say "not paired" for a moment.
    if (model.phase == PairingPhase.loading) return;
    _settle?.cancel();
    _settle = Timer(settle, () => unawaited(publishNow()));
  }

  Future<void> publishNow({bool force = false}) async {
    if (model.phase == PairingPhase.loading) return;
    if (!_readPrevious) {
      _readPrevious = true;
      _previous = await widget.read();
    }
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final snapshot = WidgetSnapshot.fromModel(model, now: now, previous: _previous);
    _previous = snapshot;
    await widget.publish(snapshot, isDone: model.isDone, force: force);
  }

  void dispose() {
    model.removeListener(_changed);
    _settle?.cancel();
    _refresh?.cancel();
  }
}
