import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart' show ClaudeMirror;
import 'package:mochi_wire/mochi_wire.dart';

import 'sessions.dart';

/// The app's Claude sessions: hook events in, the session list and every change out.
class SessionStore extends ChangeNotifier {
  SessionStore({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final SessionRegistry registry = SessionRegistry();
  final StreamController<SessionTransition> _transitions = StreamController.broadcast(sync: true);

  /// Every applied event, live or late.
  Stream<SessionTransition> get transitions => _transitions.stream;

  DateTime get now => _clock();

  /// Sessions that haven't ended, newest first.
  List<ClaudeSession> get live => registry.live;
  List<ClaudeSession> get all => registry.all;
  ClaudeSession? get primary => registry.primary(now);

  /// Events that came in late from the spool (the app wasn't running), and how many the spool had to drop.
  int lateEvents = 0;
  int droppedEvents = 0;

  /// When the last hook event arrived (null: none since launch).
  DateTime? lastEventAt;

  ClaudeMirror mirror({bool resting = false}) => registry.mirror(resting: resting, now: now);

  void apply(WireEvent event, {Delivery delivery = Delivery.live}) {
    final transition = registry.apply(event, delivery: delivery);
    if (transition == null) return;
    if (delivery == Delivery.late) {
      lateEvents++;
    } else {
      lastEventAt = now;
    }
    _transitions.add(transition);
    notifyListeners();
  }

  /// Drops ended and long-idle sessions.
  void prune() {
    final before = registry.all.length;
    registry.prune(now);
    if (registry.all.length != before) notifyListeners();
  }

  /// Something about a session changed outside the hooks (a summary arrived).
  void touched() => notifyListeners();

  /// "web is working (3 min) · api is waiting for you." (Swift `AssistantController.sessionsSummary`).
  String statusSummary() {
    final sessions = live.take(5).toList();
    if (sessions.isEmpty) return 'No Claude sessions right now.';
    return '${sessions.map((session) => '${session.project ?? 'A session'} is ${stateText(session)}').join(' · ')}.';
  }

  String stateText(ClaudeSession session) {
    switch (session.phase) {
      case SessionPhase.promptSubmitted || SessionPhase.thinking || SessionPhase.runningTool:
        final start = session.turnStartedAt;
        final minutes = start == null ? null : (now.difference(start).inSeconds / 60).floor().clamp(1, 1 << 20);
        return minutes == null ? 'working' : 'working ($minutes min)';
      case SessionPhase.waitingForUser:
        return 'waiting for you';
      case SessionPhase.turnFailed:
        return 'stopped with an error';
      case SessionPhase.turnCompleted || SessionPhase.idle:
        return 'idle';
      case SessionPhase.ended:
        return 'ended';
    }
  }

  @override
  void dispose() {
    unawaited(_transitions.close());
    super.dispose();
  }
}
