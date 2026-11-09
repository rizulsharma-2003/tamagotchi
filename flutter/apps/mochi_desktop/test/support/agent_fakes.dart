// Fakes for Mochi's agent (docs/SPRINT_2.md W23a): the `claude` process, the phones, the opener and the sign-in note.

import 'dart:async';
import 'dart:convert';

import 'package:mochi_desktop/src/core/agent/agent_command.dart';
import 'package:mochi_desktop/src/core/agent/agent_controller.dart';
import 'package:mochi_desktop/src/core/ask_mochi.dart' show UrlOpener;
import 'package:mochi_desktop/src/core/claude_cli.dart';
import 'package:mochi_link/mochi_link.dart';

/// A digest as `claude -p --output-format json` prints it.
String digestOutput({
  String headline = 'Headline',
  List<Map<String, Object?>> emails = const [],
  List<Map<String, Object?>> events = const [],
  List<Map<String, Object?>> tasks = const [],
}) => jsonEncode({
  'type': 'result',
  'is_error': false,
  'structured_output': {'headline': headline, 'emails': emails, 'events': events, 'tasks': tasks},
});

Map<String, Object?> mail(String id, {String from = 'Figma', String subject = 'Mention', String gist = 'Someone mentioned you', String urgency = 'normal', bool reply = false, String? address}) => {
  'id': id,
  'from': from,
  'subject': subject,
  'gist': gist,
  'urgency': urgency,
  'needs_reply': reply,
  'address': ?address,
};

Map<String, Object?> meeting(String id, DateTime start, {String title = 'Standup', String? link, String? where}) => {
  'id': id,
  'title': title,
  'start': start.toUtc().toIso8601String(),
  'link': ?link,
  'where': ?where,
};

String probeOutput({bool gmail = true, bool calendar = true, bool notion = true}) =>
    jsonEncode({'type': 'result', 'is_error': false, 'structured_output': {'gmail': gmail, 'calendar': calendar, 'notion': notion}});

/// `claude` for the agent: answers the connections probe and the checks from [check] and [probe], and records every run.
class AgentClaudeFake implements ClaudeRunner, StoppableRunner {
  String check = digestOutput();
  String probe = probeOutput();

  /// Probe outputs used first, one per probe run, before [probe].
  final List<String> probesFirst = [];
  bool timedOut = false;

  /// When set, a run waits for it (a check that is still going).
  Completer<ClaudeRun>? hold;
  int stops = 0;
  final List<({List<String> arguments, String input, Duration timeout})> runs = [];

  bool isProbe(List<String> arguments) => arguments.last == AgentConnections.probeSchema;
  List<({List<String> arguments, String input, Duration timeout})> get checks => [for (final run in runs) if (!isProbe(run.arguments)) run];
  List<({List<String> arguments, String input, Duration timeout})> get probes => [for (final run in runs) if (isProbe(run.arguments)) run];

  @override
  Future<ClaudeRun> run(List<String> arguments, {required String input, Duration timeout = const Duration(seconds: 90)}) async {
    runs.add((arguments: arguments, input: input, timeout: timeout));
    final waiting = hold;
    if (waiting != null) return waiting.future;
    if (timedOut) return const ClaudeRun(exitCode: -1, output: '', timedOut: true);
    if (isProbe(arguments) && probesFirst.isNotEmpty) return ClaudeRun(exitCode: 0, output: probesFirst.removeAt(0));
    return ClaudeRun(exitCode: 0, output: isProbe(arguments) ? probe : check);
  }

  @override
  void stop() {
    stops++;
    final waiting = hold;
    if (waiting != null && !waiting.isCompleted) waiting.complete(const ClaudeRun(exitCode: -15, output: ''));
  }
}

/// The phones: records what the agent shares, and lets a test mark things done "on a phone".
class AgentPhoneFake implements AgentPhone {
  @override
  bool canPush = true;

  @override
  AgentDoneList? phoneDone;

  final List<String> pendings = [];
  final List<AgentDoneList> macDones = [];
  final List<({String title, String body, AgentPending? pending, bool quietIfKnown})> news = [];
  final StreamController<void> _doneChanged = StreamController.broadcast(sync: true);
  final StreamController<void> _connected = StreamController.broadcast(sync: true);

  @override
  Stream<void> get phoneDoneChanged => _doneChanged.stream;

  @override
  Stream<void> get connected => _connected.stream;

  @override
  void publishPending(String json) => pendings.add(json);

  @override
  void publishMacDone(AgentDoneList list) => macDones.add(list);

  @override
  bool sendNews({required String title, required String body, AgentPending? pending, bool quietIfKnown = false}) {
    if (!canPush) return false;
    news.add((title: title, body: body, pending: pending, quietIfKnown: quietIfKnown));
    return true;
  }

  /// The last card shared.
  AgentPending? get card => pendings.isEmpty ? null : AgentPending.fromValue(pendings.last);

  void phoneMarked(Map<String, double> ids) {
    phoneDone = AgentDoneList(ids: ids);
    _doneChanged.add(null);
  }

  void linkCameBack() => _connected.add(null);
}

class OpenerFake implements UrlOpener {
  final List<Uri> opened = [];

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return true;
  }
}
