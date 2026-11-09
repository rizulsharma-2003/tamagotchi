// Mochi's agent on this PC: the Mac's AgentController and AgentRunner (Sources/App/Features/Agent). While it's on, a
// light tick (every 20 seconds) starts a short `claude -p` (Haiku, read-only tools, your own Claude subscription) now
// and then, to read what's new in Gmail, Google Calendar and Notion through the connectors in your Claude account, and
// Mochi tells you what matters: in its speech bubble, with the badge and, if you like, on your phones. A morning
// briefing sums up the day. While it's off nothing runs and no timer exists.
//
// Privacy: nothing here logs or prints a subject, a sender, a title, a gist or a token; the log carries counts and
// outcomes. What's kept (agent.json) is what the Mac's AgentMemory keeps.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart' show AgentDoneList, AgentNote, AgentPending, AgentSource;

import '../ask_mochi.dart' show AskOutcome, UrlOpener;
import '../claude_cli.dart';
import '../desktop_settings.dart';
import '../json_store.dart';
import '../notifications.dart' show AttentionLevel;
import 'agent_command.dart';
import 'agent_news.dart';
import 'agent_settings.dart';

/// What the agent shares with the phones (Mochi Link): the Mac's PhoneController, agent parts.
abstract interface class AgentPhone {
  /// A phone can be reached (a device is paired with this PC).
  bool get canPush;

  /// What the phones marked done (`phoneDone`).
  AgentDoneList? get phoneDone;

  /// Fires when a phone's done list changed, or the link is back (publish afresh).
  Stream<void> get phoneDoneChanged;
  Stream<void> get connected;

  /// The Pending card (`agent`), a JSON string.
  void publishPending(String json);

  /// What's done on this PC (and everything it heard of): `macDone`.
  void publishMacDone(AgentDoneList list);

  /// A notification with the card riding along. False when no phone can be reached.
  bool sendNews({required String title, required String body, AgentPending? pending, bool quietIfKnown = false});
}

/// The runner the agent's checks use: `claude` with the agent's environment (the Mac's
/// `AgentCommand.environment(from: BrainSession.environment())`): the app's own environment without anything that ties
/// a run to another Claude session or bills it to an API key, and with the connectors made ready before the model looks.
abstract final class AgentClaude {
  static ProcessClaudeRunner runner({
    required String executable,
    required String workingDirectory,
    required Map<String, String> baseEnvironment,
    required bool windows,
  }) => ProcessClaudeRunner(
    executable: executable,
    workingDirectory: workingDirectory,
    environment: AgentCommand.environment(ClaudeLocator.cleanEnvironment(baseEnvironment, windows: windows)),
  );
}

/// Why a run started (the Mac's `AgentController.Reason`).
enum AgentReason { scheduled, morning, asked, settings }

class AgentController extends ChangeNotifier {
  AgentController({
    required this.settings,
    required this.store,
    required ClaudeRunner? Function() runner,
    required this.phone,
    required this.say,
    this.opener,
    DateTime Function()? clock,
    AgentZone Function()? zone,
    File Function()? signInNotes,
    void Function(String message)? log,
    bool Function()? lookingAtMochi,
    String Function()? petName,
    this.tickEvery = const Duration(seconds: 20),
    this.firstTickAfter = const Duration(seconds: 10),
    this.checkTimeout = const Duration(seconds: 180),
    this.probeTimeout = const Duration(seconds: 90),
  }) : _runner = runner,
       _clock = clock ?? DateTime.now,
       _zone = zone ?? (() => AgentZone('UTC', DateTime.now().timeZoneOffset)),
       _signInNotes = signInNotes,
       _log = log,
       _lookingAtMochi = lookingAtMochi,
       _petName = petName ?? (() => settings.petName);

  final DesktopSettings settings;

  /// `agent.json` in Mochi's folder.
  final JsonStore store;
  final AgentPhone phone;
  final UrlOpener? opener;
  final Duration tickEvery;
  final Duration firstTickAfter;
  final Duration checkTimeout;
  final Duration probeTimeout;

  /// Mochi's speech bubble (the line, for how many seconds).
  final void Function(String line, int seconds) say;
  final ClaudeRunner? Function() _runner;
  final DateTime Function() _clock;
  final AgentZone Function() _zone;
  final File Function()? _signInNotes;
  final void Function(String message)? _log;
  final bool Function()? _lookingAtMochi;
  final String Function() _petName;

  AgentMemory _memory = AgentMemory();
  Timer? _timer;
  Timer? _first;
  StreamSubscription<void>? _connectedSub;
  StreamSubscription<void>? _phoneDoneSub;
  AgentSettings _last = const AgentSettings();
  bool _started = false;
  bool _disposed = false;

  /// Bumped whenever the agent stops: a run that was started before it finds out and leaves quietly.
  int _generation = 0;
  Object? _active;

  Map<AgentSource, AgentConnection> _connections = {};
  bool _checkingConnections = false;
  bool _running = false;
  DateTime? _lastRunAt;
  String? _lastResult;
  String? _lastError;
  DateTime _lastConnectionCheck = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _watchConnectionsUntil;
  AttentionLevel? _badge;
  final Set<String> _nudgedMeetings = {};
  String? _publishedPending;
  DateTime _pendingPublishedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _publishedMacDone;

  // MARK: State, for Settings and the badge

  AgentSettings get agent => settings.agent;
  Map<AgentSource, AgentConnection> get connections => Map.unmodifiable(_connections);
  bool get checkingConnections => _checkingConnections;
  bool get running => _running;

  /// A check, a briefing or a connections look is under way: only one at a time.
  bool get busy => _running || _checkingConnections;
  DateTime? get lastRunAt => _lastRunAt;
  String? get lastResult => _lastResult;
  String? get lastError => _lastError;

  /// What Mochi told you, newest first.
  List<AgentNote> get notes => List.unmodifiable(_memory.notes);

  /// What's waiting for you now.
  List<AgentNote> get pending => List.unmodifiable(_memory.pending);
  bool isDone(String id) => _memory.done[id] != null;
  int get doneCount => _memory.done.length;

  /// The dot on Mochi (with Claude's own badge, the higher of the two shows), until you've looked.
  AttentionLevel? get badge => _badge;

  /// Whether the tick is running (only while the agent is on).
  bool get ticking => _timer != null;

  /// Watched and connected.
  List<AgentSource> get activeSources => [
    for (final source in agent.watched)
      if (_connections[source] == AgentConnection.connected) source,
  ];

  double get _now => _clock().millisecondsSinceEpoch / 1000;
  DateTime? get _lastCheck => _memory.lastCheckAt == null ? null : DateTime.fromMillisecondsSinceEpoch((_memory.lastCheckAt! * 1000).round());

  // MARK: Starting and stopping

  /// At launch: what Mochi remembers, the card (disabled while the agent is off), and the tick if it's on.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _memory = AgentMemory.fromJson(store.read())..prune(now: _clock());
    _last = agent;
    settings.addListener(_settingsChanged);
    _connectedSub = phone.connected.listen((_) => _republish());
    publishPending(force: true);
    if (_last.enabled) _turnOn();
  }

  void _settingsChanged() {
    if (_disposed) return;
    final now = agent;
    if (now == _last) return;
    final was = _last;
    _last = now;
    if (now.enabled && !was.enabled) {
      _turnOn();
    } else if (!now.enabled && was.enabled) {
      _turnOff();
    }
    // The card follows the switch, "On my phones" and the VIPs (the Mac's tick does it within 20 seconds).
    publishPending(force: true);
    notifyListeners();
  }

  void _turnOn() {
    _timer ??= Timer.periodic(tickEvery, (_) => tick());
    _first?.cancel();
    _first = Timer(firstTickAfter, tick);
    _phoneDoneSub ??= phone.phoneDoneChanged.listen((_) => phoneDoneChanged());
    phoneDoneChanged();
  }

  /// Off: no timer, nothing running, no badge, and the card says so.
  void _turnOff() {
    _timer?.cancel();
    _timer = null;
    _first?.cancel();
    _first = null;
    _watchConnectionsUntil = null;
    _stopRunning();
    unawaited(_phoneDoneSub?.cancel());
    _phoneDoneSub = null;
    _setBadge(null);
    _lastError = null;
  }

  /// Ends whatever is running (the agent was turned off, or Mochi is quitting).
  void _stopRunning() {
    _generation++;
    final active = _active;
    if (active is StoppableRunner) active.stop();
    _active = null;
  }

  /// Mochi is quitting: no check is left running.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _first?.cancel();
    _first = null;
    _stopRunning();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    settings.removeListener(_settingsChanged);
    stop();
    unawaited(_connectedSub?.cancel());
    unawaited(_phoneDoneSub?.cancel());
    super.dispose();
  }

  // MARK: The tick

  /// What a tick does (the agent is on): meetings that have started leave the card, the next meeting gets its nudge,
  /// and a briefing or a check starts when one is due.
  @visibleForTesting
  void tick() {
    if (_disposed || !agent.enabled) return;
    final now = _clock();
    // Opening Mochi counts as having seen the news.
    if (_badge != null && (_lookingAtMochi?.call() ?? false)) _setBadge(null);
    if (_memory.prunePending(now: now)) _save();
    publishPending();
    _nudgeBeforeMeetings();
    final until = _watchConnectionsUntil;
    if (until != null) {
      if (now.isAfter(until)) {
        _watchConnectionsUntil = null;
      } else if (!busy && now.difference(_lastConnectionCheck) > const Duration(seconds: 20)) {
        unawaited(refreshConnections(forgetNotes: true));
      }
    }
    if (busy) return;
    if (AgentSchedule.briefingDue(agent, lastBriefingDay: _memory.lastBriefingDay, now: now)) {
      unawaited(_run(const AgentBriefing(), AgentReason.morning));
    } else if (AgentSchedule.checkDue(agent, lastCheck: _lastCheck, now: now)) {
      unawaited(_run(AgentCheck(AgentSchedule.since(lastCheck: _lastCheck, now: now)), AgentReason.scheduled));
    }
  }

  // MARK: Connections

  /// Opens the Claude account's connectors in the browser; while the agent is on, Mochi keeps looking until they're
  /// connected (off, press Check Connections when you're back: nothing runs by itself).
  Future<void> connect() async {
    final notes = _signInNotes;
    if (notes != null) AgentConnections.forgetSignInNotes(notes());
    final opened = await opener?.open(AgentConnections.connectURL) ?? false;
    if (!opened) _lastError = 'Couldn\'t open your browser. Go to claude.ai/customize/connectors.';
    if (agent.enabled) _watchConnectionsUntil = _clock().add(const Duration(minutes: 5));
    notifyListeners();
  }

  /// Looks again at which connectors Claude can reach: a short Haiku run that only looks. One run at a time.
  Future<void> refreshConnections({bool forgetNotes = false}) async {
    if (busy || _disposed) return;
    await _probe(forgetNotes: forgetNotes);
  }

  Future<void> _probe({bool forgetNotes = false}) async {
    if (_checkingConnections) return;
    final generation = _generation;
    final runner = _runner();
    if (runner == null) {
      _lastError = '${_petName()} can\'t reach your connectors: Claude Code isn\'t installed on this PC.';
      _log?.call('agent: connections claude not found');
      notifyListeners();
      return;
    }
    _checkingConnections = true;
    _active = runner;
    notifyListeners();
    try {
      final notes = _signInNotes;
      if (forgetNotes && notes != null) AgentConnections.forgetSignInNotes(notes());
      _lastConnectionCheck = _clock();
      final run = await runner.run(AgentConnections.probeArguments, input: AgentConnections.probePrompt, timeout: probeTimeout);
      if (generation != _generation || _disposed) return;
      final states = run.output.isEmpty ? null : AgentConnections.parse(run.output);
      if (states == null) {
        _lastError = run.timedOut
            ? 'Checking the connections took too long.'
            : (run.output.isEmpty ? null : AgentDigest.failure(run.output)) ?? 'Couldn\'t check the connections just now.';
        _log?.call('agent: connections ${run.timedOut ? 'timed out' : 'failed'}');
        return;
      }
      _connections = states;
      _lastError = null;
      _log?.call('agent: connections ${[for (final source in AgentSource.values) '${source.name}=${states[source]!.name}'].join(' ')}');
      if (_watchConnectionsUntil != null && agent.watched.every((source) => states[source] == AgentConnection.connected)) {
        _watchConnectionsUntil = null;
      }
    } finally {
      if (identical(_active, runner)) _active = null;
      _checkingConnections = false;
      if (!_disposed) notifyListeners();
    }
  }

  // MARK: Checking

  /// Settings › Agent › Check Now.
  Future<void> checkNow() => _run(AgentCheck(AgentSchedule.since(lastCheck: _lastCheck, now: _clock())), AgentReason.settings);

  /// Settings › Agent › Briefing Now.
  Future<void> briefNow() => _run(const AgentBriefing(), AgentReason.settings);

  /// Ask Mochi's "what's pending?" (typed, or a phone's "Check now"): the day at a glance, said out loud. It always
  /// looks afresh, as the Mac's does.
  Future<AskOutcome> answer() async {
    final name = _petName();
    if (!agent.enabled) return AskOutcome('Turn on $name\'s agent in Settings › Agent first.', ok: false);
    if (busy) return const AskOutcome('I\'m checking right now — give me a moment.');
    final digest = await _run(const AgentBriefing(), AgentReason.asked);
    if (digest == null) return AskOutcome(_lastError ?? 'I couldn\'t check just now.', ok: false);
    final everything = AgentNews(emails: digest.emails, events: digest.events, tasks: digest.tasks, vips: agent.vips);
    final extra = everything.parts(_zone()).take(2).where((part) => !digest.headline.contains(part));
    return AskOutcome([digest.headline, ...extra].join('. '));
  }

  /// The development switch (`MOCHI_DESKTOP_AGENT=check|brief|connections`): once, whether or not the agent is on. It
  /// looks and logs counts; while the agent is off it tells nobody.
  Future<void> debugRun(String what) async {
    switch (what) {
      case 'check':
        await checkNow();
      case 'brief':
        await briefNow();
      case 'connections':
        await refreshConnections(forgetNotes: true);
    }
  }

  Future<AgentDigest?> _run(AgentMode mode, AgentReason reason) async {
    if (busy || _disposed) return null;
    final generation = _generation;
    final kind = mode is AgentCheck ? 'check' : 'brief';
    _running = true;
    notifyListeners();
    try {
      if (_runner() == null) {
        _lastError = 'Claude Code isn\'t installed on this PC.';
        _log?.call('agent: $kind skipped, claude not found');
        return null;
      }
      if (_connections.isEmpty || _clock().difference(_lastConnectionCheck) > const Duration(hours: 6)) await _probe();
      if (generation != _generation || _disposed) return null;
      final sources = activeSources;
      if (sources.isEmpty) {
        _lastError = 'Connect Gmail, Google Calendar or Notion first.';
        _log?.call('agent: $kind skipped, no connected source');
        if (mode is AgentCheck) _memory.lastCheckAt = _now;
        return null;
      }
      final runner = _runner();
      if (runner == null) {
        _lastError = 'Claude Code isn\'t installed on this PC.';
        _log?.call('agent: $kind skipped, claude not found');
        return null;
      }
      final started = _clock();
      _active = runner;
      final run = await runner.run(
        AgentCommand.arguments(sources),
        input: AgentCommand.prompt(mode: mode, sources: sources, now: started, zone: _zone()),
        timeout: checkTimeout,
      );
      if (identical(_active, runner)) _active = null;
      if (generation != _generation || _disposed) return null;
      _lastRunAt = _clock();
      if (mode is AgentCheck) _memory.lastCheckAt = started.millisecondsSinceEpoch / 1000;
      final digest = run.output.isEmpty ? null : AgentDigest.parse(run.output);
      if (digest == null) {
        _lastError = (run.output.isEmpty ? null : AgentDigest.failure(run.output)) ?? 'The check didn\'t finish in time.';
        _log?.call(
          'agent: $kind failed (${run.timedOut
              ? 'timed out'
              : run.output.isEmpty
              ? 'no output'
              : 'claude reported a problem'})',
        );
        _save();
        return null;
      }
      _lastError = null;
      _log?.call('agent: $kind ok, ${digest.emails.length} mail, ${digest.events.length} event, ${digest.tasks.length} tasks');
      final zone = _zone();
      switch (mode) {
        case AgentCheck():
          final news = _memory.news(digest, now: started, vips: agent.vips);
          _memory.updatePending(news.notes(started, zone), replacing: false, now: started);
          _lastResult = news.isEmpty ? 'Nothing new' : news.line(zone);
          _tell(news);
        case AgentBriefing():
          _memory.markSeen(digest, now: started);
          final done = _memory.done;
          final everything = AgentNews(
            emails: [
              for (final email in digest.emails)
                if (done['mail:${email.id}'] == null) email,
            ],
            events: [
              for (final event in digest.events)
                if (done['event:${event.id}'] == null) event,
            ],
            tasks: [
              for (final task in digest.tasks)
                if (done['task:${task.id}'] == null) task,
            ],
            vips: agent.vips,
          );
          _lastResult = digest.headline;
          _memory.remember(everything.notes(started, zone));
          _memory.updatePending(everything.notes(started, zone), replacing: true, headline: digest.headline, now: started);
          if (reason == AgentReason.morning) {
            _memory.lastBriefingDay = AgentSchedule.dayKey(started);
            _tell(everything, headline: digest.headline, phoneTitle: 'Your day');
          } else if (reason == AgentReason.settings) {
            _tell(everything, headline: digest.headline, phoneTitle: 'Your day', toPhone: false);
          }
      }
      _save();
      publishPending(force: true);
      return digest;
    } finally {
      _running = false;
      if (!_disposed) notifyListeners();
    }
  }

  // MARK: Telling

  /// About ten minutes before a meeting on the card, Mochi says so (the phones get Mochi Cloud's heads-up).
  void _nudgeBeforeMeetings() {
    if (!agent.enabled || !agent.tellInBubble) return;
    final now = _now;
    for (final note in _memory.pending) {
      if (note.source != AgentSource.calendar || _memory.done[note.id] != null) continue;
      final due = note.due;
      if (due == null || due - now < 300 || due - now > 660) continue;
      if (!_nudgedMeetings.add('${note.id}@${due.toInt()}')) continue;
      final minutes = ((due - now) / 60).round().clamp(1, 1 << 20);
      say('${note.title} in $minutes minutes${note.link != null ? ' — the link\'s on the card' : ''}', 10);
      if (agent.tellWithBadge) _setBadge(AttentionLevel.attention);
      break;
    }
  }

  /// What Mochi tells you, as each setting allows: the bubble, the badge, the phones. With the agent off (a
  /// development run) it tells nobody.
  void _tell(AgentNews news, {String? headline, String? phoneTitle, bool toPhone = true}) {
    if (!agent.enabled) return;
    if (news.isEmpty && headline == null) return;
    final zone = _zone();
    _memory.remember(news.notes(_clock(), zone));
    final line = headline ?? news.line(zone);
    if (agent.tellInBubble && line.isNotEmpty) say(line, 8);
    final level = news.attention;
    if (agent.tellWithBadge && level != null) {
      final current = _badge;
      _setBadge(current == null || level.index > current.index ? level : current);
    }
    if (!toPhone || !agent.tellPhone) return;
    if (headline == null && !news.worthPhone(skippingLow: agent.phoneSkipsLowPriority)) return;
    final notification = news.notification(zone);
    var body = notification.body;
    if (headline != null) body = body.isEmpty ? headline : '$headline\n$body';
    phone.sendNews(
      title: phoneTitle ?? notification.title,
      body: body,
      pending: _pendingCard(stamped: true),
      quietIfKnown: headline == null,
    );
  }

  void _setBadge(AttentionLevel? level) {
    if (level == _badge) return;
    _badge = level;
    if (!_disposed) notifyListeners();
  }

  /// You opened Mochi's window or popover: the news has been seen.
  void acknowledge() => _setBadge(null);

  // MARK: Done

  /// Done here (Settings › Agent › Recent): off the card on every device.
  void markDone(AgentNote note) {
    if (!_memory.markDone({note.id: _now.roundToDouble()})) return;
    _save();
    publishPending(force: true);
    _publishMacDone();
    notifyListeners();
  }

  /// A phone's done list changed (through Mochi Link): the union is kept.
  void phoneDoneChanged() {
    if (!_started || _disposed || !agent.enabled) return;
    final list = phone.phoneDone;
    if (list == null) return;
    if (!_memory.markDone(list.trimmed(now: _clock()).ids)) return;
    _save();
    publishPending(force: true);
    _publishMacDone();
    if (_memory.pending.isEmpty) _setBadge(null);
    notifyListeners();
  }

  void _publishMacDone({bool force = false}) {
    final json = doneList(_memory, now: _clock()).toValue();
    if (!force && json == _publishedMacDone) return;
    _publishedMacDone = json;
    phone.publishMacDone(doneList(_memory, now: _clock()));
  }

  // MARK: The phones' Pending card

  /// What's waiting for you, shared only while the agent is on with "On my phones".
  AgentPending _pendingCard({required bool stamped}) {
    final shared = agent.enabled && agent.tellPhone;
    final looked = _lastRunAt == null ? _memory.lastCheckAt : _lastRunAt!.millisecondsSinceEpoch / 1000;
    return AgentPending(
      enabled: shared,
      headline: shared ? _memory.pendingHeadline : null,
      items: shared ? List.of(_memory.pending) : const [],
      lookedAt: shared && looked != null ? looked.roundToDouble() : null,
      updatedAt: stamped ? (_now).ceilToDouble() : null,
    );
  }

  /// At most every half minute unless something was just found: the card only changes when Mochi looks.
  @visibleForTesting
  void publishPending({bool force = false}) {
    final json = _pendingCard(stamped: false).toValue();
    if (json == _publishedPending) return;
    if (!force && _clock().difference(_pendingPublishedAt) < const Duration(seconds: 30)) return;
    _publishedPending = json;
    _pendingPublishedAt = _clock();
    phone.publishPending(_pendingCard(stamped: true).toValue());
  }

  /// The link came (back): everything is published afresh.
  void _republish() {
    _publishedPending = null;
    publishPending(force: true);
    if (agent.enabled) {
      _publishMacDone(force: true);
      phoneDoneChanged();
    }
  }

  // MARK: Forgetting and saving

  /// Forgets what Mochi has told you (so the next check reports everything again).
  void forgetNews() {
    _memory = AgentMemory();
    _lastResult = null;
    _nudgedMeetings.clear();
    _save();
    _setBadge(null);
    publishPending(force: true);
    notifyListeners();
  }

  void _save() {
    _memory.prune(now: _clock());
    store.write(_memory.toJson());
    if (!_disposed) notifyListeners();
  }
}
