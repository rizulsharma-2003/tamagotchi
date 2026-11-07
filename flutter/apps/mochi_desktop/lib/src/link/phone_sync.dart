// What this PC shares with the phones in its room and how it answers them: the Dart counterpart of the Mac's
// PhoneController (Sources/App/Features/Phone/PhoneController.swift), Link parts only. The values and their shapes are
// the Mac's, so the iPhone and Android apps work unchanged against a Windows host:
//
// - state `look` (PetLook JSON string), `claude` (ClaudeMirror), `sessions` (PhoneSessions JSON string);
// - message `reply` to each `command`, `macInteraction` when Mochi is petted here;
// - sealed `alert`s for finished turns (title = project, subtitle "Claude finished", body = the summary, userInfo
//   {session, project, card}, category `claude-turn`, thread = the session).
//
// Not on Windows yet (v2): Live Activities (`liveActivity`, `activityEnded`), the agent (`agent`, `macDone`, agent
// news), approvals (`approval`/`verdict`), and commands addressed to one Claude session.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_wire/mochi_wire.dart';

import '../core/ask_mochi.dart';
import '../core/desktop_settings.dart';
import '../core/pet_cues.dart';
import '../core/session_store.dart';
import '../core/sessions.dart';
import '../core/turn_summaries.dart';
import 'link_host.dart';

/// Writes Claude's closing message up as a short note (null: use [TurnSummarizer.fallback]).
typedef TurnSummaryMaker = Future<TurnSummary?> Function(TurnReport report, List<String> earlier);

/// The Mac's default look (link-spec/fixtures/look.json): what a fresh install shares.
const PetLook defaultLook = PetLook(
  petName: 'Mochi',
  companionName: 'Patch',
  petColor: 'cream',
  deskAccessory: 'plant',
  theme: 'cozyDesk',
  friendshipLevel: 0,
);

/// The look this PC shares (`look`), from Settings › General and Characters, so the phones' rooms match: names, the
/// coat, what Mochi and the companion wear, the desk and the room's theme, and the holiday settings. Windows keeps no
/// friendship or furniture yet: level 0 and an empty room.
PetLook petLook(DesktopSettings settings) => PetLook(
  petName: settings.petName,
  companionName: settings.companionName,
  petColor: settings.petColor.name,
  petAccessory: settings.petAccessory?.name,
  companionAccessory: settings.companionAccessory?.name,
  deskAccessory: settings.deskAccessory?.name,
  theme: settings.officeTheme.name,
  seasonal: {
    'enabled': settings.holidays,
    'birthdayMonth': ?settings.birthdayMonth,
    'birthdayDay': ?settings.birthdayDay,
    'decorateMenuBar': true,
  },
  friendshipLevel: 0,
);

class PhoneSync {
  PhoneSync({
    required this.host,
    required this.sessions,
    required this.settings,
    required this.ask,
    required this.summariesFlagFile,
    required void Function(PetCue cue) cue,
    TurnSummaryMaker? summarize,
    this.look,
    DateTime Function()? clock,
    this.tickInterval = const Duration(seconds: 2),
    bool? Function()? away,
    bool Function()? resting,
  }) : _cue = cue,
       _summarize = summarize,
       _clock = clock ?? DateTime.now,
       _away = away,
       _resting = resting;

  /// You're away from this PC (null: Mochi can't tell), for "Only notify me when I'm away from this PC".
  final bool? Function()? _away;

  /// The PC is resting: Mochi sleeps on the phones too (the room's `claude.resting`).
  final bool Function()? _resting;

  final LinkHost host;
  final SessionStore sessions;
  final DesktopSettings settings;
  final AskMochi ask;

  /// Present while summaries are shared: the hook helper includes Claude's closing message only then.
  final String summariesFlagFile;

  /// A fixed look (tests); otherwise [petLook] of the settings.
  final PetLook? look;
  final Duration tickInterval;
  final void Function(PetCue cue) _cue;
  final TurnSummaryMaker? _summarize;
  final DateTime Function() _clock;

  final SessionReports _reports = SessionReports();

  /// The last few notes per session, so the next summary knows what the session is about.
  final Map<String, List<String>> _notes = {};
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Set<String> _seenInteractions = {};
  Timer? _timer;

  String? _publishedLook;
  ClaudeMirror? _publishedMirror;
  DateTime _mirrorPublishedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _publishedSessions;
  DateTime _sessionsPublishedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool? _summaryFlag;

  /// The last summary made, for the main window ("web: Fixed the login bug").
  String? lastSummary;

  /// Summaries kept off the phones because you were at this PC ("Only notify me when I'm away").
  int skippedWhileHere = 0;

  double get _now => _clock().millisecondsSinceEpoch / 1000;

  void start() {
    _subscriptions.addAll([
      host.incoming.listen(_received),
      // After every (re)connect, everything is published afresh.
      host.connected.listen((_) => tick(force: true)),
    ]);
    settings.addListener(_settingsChanged);
    _timer = Timer.periodic(tickInterval, (_) => tick());
    tick(force: true);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    settings.removeListener(_settingsChanged);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  /// A setting changed: the summaries switch takes effect at once; a new name or look goes out with the next tick
  /// (within [tickInterval]), so typing a name doesn't send every letter.
  void _settingsChanged() {
    _syncSummaryFlag();
    if (host.paired) _publishSessions(force: true);
  }

  /// Publishes what changed (every [tickInterval], and right away when [force]d).
  void tick({bool force = false}) {
    _syncSummaryFlag();
    if (!host.paired) return;
    if (force) {
      _publishedLook = null;
      _publishedMirror = null;
      _publishedSessions = null;
    }
    _publishLook();
    _publishMirror(force: force);
    _publishSessions(force: force);
  }

  void _publishLook() {
    final value = (look ?? petLook(settings)).toValue();
    if (value == _publishedLook) return;
    _publishedLook = value;
    host.set(value, LinkKey.look);
  }

  /// A new phase goes out within seconds; a different tool alone only now and then (Swift `publishShared`).
  void _publishMirror({required bool force}) {
    final mirror = sessions.mirror(resting: _resting?.call() ?? false);
    final published = _publishedMirror;
    final same =
        published != null &&
        published.phase == mirror.phase &&
        published.category == mirror.category &&
        published.resting == mirror.resting;
    if (same) return;
    final spacing = published != null && published.phase == mirror.phase && published.resting == mirror.resting
        ? const Duration(seconds: 20)
        : const Duration(seconds: 4);
    if (!force && _clock().difference(_mirrorPublishedAt) < spacing) return;
    _publishedMirror = mirror;
    _mirrorPublishedAt = _clock();
    host.set(mirror.toValue(), LinkKey.claude);
  }

  /// The phones' list of sessions: each live session's phase and the summary of its last turn (at most six).
  void _publishSessions({bool force = false}) {
    final share = settings.shareSummaries;
    final cards = <PhoneSessionCard>[];
    if (share) {
      for (final session in sessions.live.take(6)) {
        cards.add(_card(session));
      }
    }
    final value = PhoneSessions(enabled: share, sessions: cards).toValue();
    if (value == _publishedSessions) return;
    if (!force && _clock().difference(_sessionsPublishedAt) < const Duration(seconds: 3)) return;
    _publishedSessions = value;
    _sessionsPublishedAt = _clock();
    host.set(PhoneSessions(enabled: share, sessions: cards, updatedAt: _now.ceilToDouble()).toValue(), LinkKey.sessions);
  }

  PhoneSessionCard _card(ClaudeSession session, {String? phase}) => PhoneSessionCard(
    id: session.id,
    project: session.project ?? 'Claude',
    phase: phase ?? session.phoneSessionPhase,
    summary: session.summary,
    files: session.summaryFiles.take(12).toList(),
    finishedAt: session.summaryAt == null ? null : (session.summaryAt!.millisecondsSinceEpoch / 1000).roundToDouble(),
    phaseSince: (session.phaseSince.millisecondsSinceEpoch / 1000).roundToDouble(),
  );

  /// The hook helper includes Claude's words only while this file exists: while summaries are shared and a phone can get
  /// them (the Mac's `syncSummaryFlag`), so nothing of what Claude says is read, or summarized, for nobody.
  void _syncSummaryFlag() {
    final on = settings.shareSummaries && host.paired;
    if (on == _summaryFlag) return;
    _summaryFlag = on;
    try {
      final file = File(summariesFlagFile);
      if (on) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('');
      } else {
        if (file.existsSync()) file.deleteSync();
        _reports.clear();
        _notes.clear();
        for (final session in sessions.all) {
          session
            ..summary = null
            ..summaryAt = null
            ..summaryFiles = const [];
        }
        lastSummary = null;
      }
    } on FileSystemException catch (error) {
      debugPrint('Mochi: the summaries flag could not be changed (${error.message})');
    }
  }

  // MARK: Claude's summaries

  /// Every live hook event: collects each turn's changed files and, when Claude stops, summarizes the turn.
  void record(WireEvent wire) {
    if (!settings.shareSummaries) return;
    final report = _reports.record(wire, now: _clock());
    if (report != null) unawaited(_summarizeTurn(report));
  }

  Future<void> _summarizeTurn(TurnReport report) async {
    TurnSummary? summary;
    final make = _summarize;
    if (make != null && report.message != null) {
      try {
        summary = await make(report, _notes[report.sessionId] ?? const []);
      } on Object {
        summary = null;
      }
    }
    deliver(summary ?? TurnSummarizer.fallback(report), report);
  }

  /// Keeps [summary] on its session, republishes the list, and tells the phones.
  @visibleForTesting
  void deliver(TurnSummary summary, TurnReport report) {
    if (!settings.shareSummaries) return;
    final notes = [...?_notes[report.sessionId], summary.done];
    _notes[report.sessionId] = notes.length > 3 ? notes.sublist(notes.length - 3) : notes;
    final session = sessions.registry[report.sessionId];
    if (session != null) {
      session
        ..summary = summary
        ..summaryAt = report.at
        ..summaryFiles = report.files.take(12).toList();
      sessions.touched();
    }
    lastSummary = '${report.project}: ${summary.done}';
    _publishSessions(force: true);
    if (!host.paired) return;
    // "Only notify me when I'm away from this PC": the card is up to date on the phones, but they don't ring while
    // you're here (the Mac: 3 minutes without input).
    if (settings.notifyOnlyWhenAway && _away?.call() == false) {
      skippedWhileHere++;
      return;
    }
    final card = PhoneSessionCard(
      id: report.sessionId,
      project: report.project,
      phase: 'done',
      summary: summary,
      files: report.files.take(12).toList(),
      finishedAt: (report.at.millisecondsSinceEpoch / 1000).roundToDouble(),
    );
    host.sendAlert(
      {
        'title': report.project,
        'subtitle': 'Claude finished',
        'body': summary.done,
        'userInfo': {'session': report.sessionId, 'project': report.project, 'card': card.toJson()},
      },
      category: 'claude-turn',
      threadId: report.sessionId,
    );
  }

  // MARK: From the phones

  void _received(LinkIncoming message) {
    switch (message.key) {
      case LinkKey.command:
        unawaited(_command(message));
      case LinkKey.phoneInteraction:
        final interaction = LinkInteraction.fromValue(message.value);
        if (interaction == null || !_seenInteractions.add(interaction.id) || _now - interaction.at >= 90) return;
        final cue = switch (interaction.kind) {
          'pet' => PetCue.pet,
          'play' => PetCue.play,
          'treat' => PetCue.treat,
          _ => null,
        };
        if (cue != null) _cue(cue);
      case LinkKey.verdict:
        // No approvals on Windows yet: nothing asked for one.
        break;
      default:
        break;
    }
  }

  /// What you told Mochi on a phone runs here, as if typed on this PC (Swift `readCommands`).
  Future<void> _command(LinkIncoming message) async {
    final command = LinkCommand.fromValue(message.value);
    if (command == null || settings.wasHandled(command.id)) return;
    final text = command.text.trim();
    if (text.isEmpty || _now - command.at >= 180) {
      settings.markHandled(command.id);
      return;
    }
    settings.markHandled(command.id);
    if (!settings.acceptCommands) {
      _reply(command.id, "This PC doesn't take requests from phones right now (Mochi's Settings › Phones).", ok: false);
      return;
    }
    _reply(command.id, null, working: true);
    if (command.project != null) {
      // A reply to one Claude session: on the Mac that goes through an approval card into the session. Not yet here.
      _reply(command.id, "Mochi on Windows can't pass messages to a Claude session yet. Reply on the PC for now.", ok: false);
      return;
    }
    final outcome = await ask.ask(text, spoken: !command.typed, fromPhone: true);
    _reply(command.id, outcome.text, ok: outcome.ok);
  }

  void _reply(String id, String? text, {bool ok = true, bool working = false}) {
    final state = working ? 'working' : (ok ? 'done' : 'failed');
    host.set(LinkReply(id: id, state: state, text: text, at: _now).toValue(), LinkKey.reply);
  }

  /// Petting, play and treats here show on the phones too.
  void interacted(String kind) {
    if (!host.paired) return;
    final id = RelayLink.newId();
    _seenInteractions.add(id);
    host.set(LinkInteraction(id: id, kind: kind, at: _now).toValue(), LinkKey.macInteraction);
  }

  /// Settings › Phones: a sealed test notification through the relay, to check the whole path.
  void sendTestNotification() {
    host.sendAlert({
      'title': 'Hello from ${host.hostName}',
      'subtitle': 'Mochi Link test',
      'body': 'This notification came through your relay, end-to-end encrypted: only your phones could read it.',
      'userInfo': <String, Object?>{},
    });
  }
}
