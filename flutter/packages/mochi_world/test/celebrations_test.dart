// Sprint 2 G2: celebrations from real Claude events against the Swift engine (link-spec/world/celebrations.json): the
// session registry's transitions, the mapper's reactions, the notification policy, and the strict classifier.

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

Map<String, Object?> _reactionJson(Reaction r) => {
  'category': r.category.name,
  'pet': ?r.pet?.name,
  'companion': ?r.companion?.name,
  'interaction': ?r.interaction?.name,
  'priority': r.priority.name,
  'sound': ?r.sound?.name,
  'attention': ?r.attention?.name,
  if (r.banner case final b?) 'banner': {'title': b.title, 'body': b.body},
  'caption': ?r.caption,
  if (r.burst) 'burst': true,
  if (r.resultCard) 'resultCard': true,
};

String _statusLine(SessionSnapshot s, DateTime now) => s.statusLine(now);

void main() {
  final fixture = readWorldFixture('celebrations.json');

  for (final scenario in cases(fixture, 'scenarios')) {
    test(scenario['name'], () {
      final overrides = obj(scenario['settings']);
      final settings = const WorldSettings(soundEnabled: true).copyWith(
        celebrateCommandResults: overrides['celebrateCommandResults'] as bool?,
        longTurnMinutes: overrides['longTurnMinutes'] as int?,
      );
      final registry = SessionRegistry();
      var reached = scenario['milestoneReached'] == true;
      final celebrations = Celebrations(settings: settings, milestoneReached: reached);
      for (final (index, step) in objs(scenario['events']).indexed) {
        final where = '${scenario['name']} #$index (${obj(step['wire'])['event']})';
        final wire = obj(step['wire']);
        final received = DateTime.fromMicrosecondsSinceEpoch(((wire['ts']! as num) * 1e6).round(), isUtc: true);
        final delivery = byName(EventDelivery.values, step['delivery'] ?? 'live');
        final event = EventNormalizer.normalize(wire, receivedAt: received, delivery: delivery)!;
        expect(event.kind.name, step['kind'], reason: where);
        expect(event.summary, step['summary'], reason: where);

        // The raw pipeline, as CompanionWorld runs it.
        final previousPrimary = registry.primarySession(now: received)?.id;
        final transition = registry.apply(event);
        final session = transition == null ? null : registry[transition.sessionID];
        if (step['transition'] case final Map<Object?, Object?> t) {
          expect(transition, isNotNull, reason: where);
          expect(
            diffJson({
              'session': transition!.sessionID,
              'previousPhase': ?transition.previousPhase?.name,
              'phase': transition.phase.name,
              if (transition.isNewSession) 'isNewSession': true,
              if (transition.startedInvestigating) 'startedInvestigating': true,
              'turnDuration': ?transition.turnDuration,
              if (transition.turnDurationTrusted) 'turnDurationTrusted': true,
            }, t),
            isEmpty,
            reason: where,
          );
        } else {
          expect(transition, isNull, reason: where);
        }
        if (step['session'] case final Map<Object?, Object?> s) {
          final outcome = session!.buildTestThisTurn;
          expect(
            diffJson({
              'consecutiveFailures': session.consecutiveFailures,
              'investigatedThisTurn': session.investigatedThisTurn,
              'isInvestigating': session.isInvestigating,
              'turnsCompleted': session.turnsCompleted,
              if (outcome != null) 'buildTest': '${outcome.kind.name} ${outcome.passed ? 'passed' : 'failed'} (${outcome.source.name})',
              'statusLine': _statusLine(session, received),
            }, s),
            isEmpty,
            reason: where,
          );
        }
        Reaction? reaction;
        if (delivery == EventDelivery.live) {
          final firstMilestone = !event.isSimulated && event.kind == EventKind.report && event.report?.kind == ReportKind.milestone && !reached;
          if (firstMilestone) reached = true;
          final primaryID = registry.primarySession(now: received)?.id;
          reaction = EventToAnimationMapper.reaction(
            event,
            transition: transition,
            session: session,
            context: MapperContext(
              companionPresent: true,
              isPrimary: session == null || session.id == primaryID || previousPrimary == null,
              multipleLiveSessions: registry.all.where((s) => s.phase != SessionPhase.ended).length > 1,
              celebrateCommandResults: settings.celebrateCommandResults,
              longTurnThreshold: settings.longTurnMinutes * 60.0,
              firstMilestone: firstMilestone,
            ),
          );
        }
        if (step['reaction'] case final Map<Object?, Object?> r) {
          expect(reaction, isNotNull, reason: where);
          expect(diffJson(_reactionJson(reaction!), r), isEmpty, reason: where);
          final decision = NotificationPolicy.decide(
            reaction.category,
            settings: settings,
            context: NotificationContext(now: received, isSimulated: event.isSimulated, isLate: event.delivery != EventDelivery.live),
            calendar: const WorldCalendar.utc(),
          );
          final d = decision.toJson()..remove('quiet');
          expect(diffJson(d, step['decision']), isEmpty, reason: where);
        } else {
          expect(reaction, isNull, reason: where);
        }

        // The strict G2 classifier.
        final celebration = celebrations.observe(event);
        expect(celebration?.interaction.name, step['celebrates'], reason: where);
        if (celebration != null) {
          expect(event.isSimulated, isFalse);
          expect(event.delivery, EventDelivery.live);
        }
      }
    });
  }

  test('the reasons behind each celebration', () {
    final c = Celebrations();
    var ts = 1800000000.0;
    CompanionEvent e(String id, String name, {String origin = 'hook', String? session = 's1', Map<String, Object?> extra = const {}, double after = 1}) {
      ts += after;
      return EventNormalizer.normalize({
        'id': id,
        'ts': ts,
        'origin': origin,
        'event': name,
        'session': ?session,
        'project': 'P',
        'projectKey': 'kp',
        ...extra,
      }, receivedAt: DateTime.fromMicrosecondsSinceEpoch((ts * 1e6).round(), isUtc: true))!;
    }

    c.observe(e('1', 'SessionStart'));
    c.observe(e('2', 'UserPromptSubmit'));
    expect(c.observe(e('3', 'Stop', after: 5))?.reason, CelebrationReason.turnFinished);
    c.observe(e('4', 'UserPromptSubmit'));
    expect(c.observe(e('5', 'Stop', after: 700))?.reason, CelebrationReason.longTurn);
    c.observe(e('6', 'UserPromptSubmit'));
    c.observe(e('7', 'PostToolUse', extra: {'tool': 'Bash', 'toolCategory': 'shell', 'commandKind': 'test', 'commandReliable': true}));
    expect(c.observe(e('8', 'Stop'))?.reason, CelebrationReason.buildTestPassed);
    c.observe(e('9', 'UserPromptSubmit'));
    c.observe(e('10', 'PostToolUseFailure', extra: {'tool': 'Bash', 'toolCategory': 'shell'}));
    c.observe(e('11', 'PostToolUseFailure', extra: {'tool': 'Bash', 'toolCategory': 'shell'}));
    expect(c.observe(e('12', 'PostToolUseFailure', extra: {'tool': 'Bash', 'toolCategory': 'shell'}))?.reason, CelebrationReason.investigating);
    expect(c.observe(e('13', 'Stop'))?.reason, CelebrationReason.caseClosed);
    final milestone = {
      'report': {'kind': 'milestone', 'status': 'reached'},
    };
    expect(c.observe(e('14', 'Report', origin: 'report', session: null, extra: milestone))?.reason, CelebrationReason.firstMilestone);
    expect(c.observe(e('15', 'Report', origin: 'report', session: null, extra: milestone))?.reason, CelebrationReason.milestone);
    final commit = {
      'report': {'kind': 'commit', 'status': 'reached'},
    };
    expect(c.observe(e('16', 'Report', origin: 'report', session: null, extra: commit))?.reason, CelebrationReason.commit);
    // Simulated and late events never celebrate.
    c.observe(e('17', 'UserPromptSubmit', origin: 'simulator', session: 'sim'));
    expect(c.observe(e('18', 'Stop', origin: 'simulator', session: 'sim')), isNull);
    c.observe(e('19', 'UserPromptSubmit'));
    final late = EventNormalizer.normalize(
      {'id': '20', 'ts': ts + 2, 'origin': 'hook', 'event': 'Stop', 'session': 's1'},
      receivedAt: DateTime.utc(2030),
      delivery: EventDelivery.late,
    )!;
    expect(c.observe(late), isNull);
  });
}
