// Friendship, achievements and growing up against the Swift engine (link-spec/world/progress.json).

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

String _iso(DateTime date) {
  final s = date.toUtc().toIso8601String();
  return '${s.substring(0, s.indexOf('.') < 0 ? s.length - 1 : s.indexOf('.'))}Z';
}

Map<String, Object?> _summary(ProgressState state, DateTime date) => {
  'affectionPoints': state.affectionPoints,
  'level': state.friendshipLevel,
  'pointsToNextLevel': ?state.pointsToNextLevel,
  'interactionDays': state.interactionDays,
  'dailyPoints': {for (final key in state.dailyPoints.keys.toList()..sort()) key: state.dailyPoints[key]},
  'dailyPointsDay': state.dailyPointsDay,
  'unlocked': {
    for (final id in AchievementID.values)
      if (state.unlocked[id.name] case final at?) id.name: _iso(at),
  },
  'projectKeys': state.projectKeys,
  'observedSessions': state.observedSessions,
  'observedTurns': state.observedTurns,
  'milestones': state.milestones,
  'firstMetAt': ?(state.firstMetAt == null ? null : _iso(state.firstMetAt!)),
  'lifeStage': LifeStage.stage(state, date).title,
  'nextStep': ?LifeStage.nextStep(state, date),
};

void main() {
  test('progress.json: every step, in order, on one engine', () {
    final fixture = readWorldFixture('progress.json');
    final engine = AchievementEngine(calendar: const WorldCalendar.utc());
    final registry = SessionRegistry();
    var saves = 0;
    engine.onChange = (_) => saves += 1;
    for (final (index, step) in objs(fixture['steps']).indexed) {
      final List<AchievementID> unlocked;
      final DateTime date;
      if (step['interact'] case final String kind) {
        date = DateTime.parse(step['at']! as String);
        final result = engine.recordInteraction(byName(PetInteraction.values, kind), date);
        expect(result.pointsAwarded, step['pointsAwarded'], reason: 'step $index points');
        expect(result.levelUp, step['levelUp'], reason: 'step $index level up');
        unlocked = result.unlocked;
      } else {
        final wire = obj(step['wire']);
        date = DateTime.fromMicrosecondsSinceEpoch(((wire['ts']! as num) * 1e6).round(), isUtc: true);
        final delivery = byName(EventDelivery.values, step['delivery'] ?? 'live');
        final event = EventNormalizer.normalize(wire, receivedAt: date, delivery: delivery)!;
        final transition = registry.apply(event);
        final session = transition == null ? null : registry[transition.sessionID];
        unlocked = engine.record(event, transition: transition, session: session);
      }
      if (step.containsKey('unlocked')) {
        expect(unlocked.map((e) => e.name).toList(), step['unlocked'], reason: 'step $index unlocked');
      }
      expect(diffJson(_summary(engine.state, date), obj(step['state'])), isEmpty, reason: 'step $index state');
    }
    expect(saves, greaterThan(0));
  });

  test('progress survives a JSON round trip and reads the Mac\'s progress.json', () {
    final engine = AchievementEngine(calendar: const WorldCalendar.utc());
    final day = DateTime.utc(2027, 1, 15, 9);
    for (var i = 0; i < 12; i++) {
      engine.recordInteraction(PetInteraction.values[i % 3], day.add(Duration(days: i)));
    }
    final copy = ProgressState.fromJson(engine.state.toJson());
    expect(copy.toJson(), engine.state.toJson());
    final mac = ProgressState.fromJson({
      'affectionPoints': 42,
      'unlocked': {'firstTurn': '2027-01-15T08:00:00Z'},
      'interactionDays': ['2027-01-15'],
      'firstMetAt': '2027-01-14T10:00:00Z',
    });
    expect(mac.friendshipLevel, 2);
    expect(mac.unlockedIDs, {AchievementID.firstTurn});
    expect(AchievementID.firstTurn.reward, Accessory.partyHat);
  });

  test('nothing ever decreases and caps hold, however much you click', () {
    final engine = AchievementEngine(calendar: const WorldCalendar.utc());
    final day = DateTime.utc(2027, 3, 1, 12);
    var last = 0;
    for (var i = 0; i < 200; i++) {
      engine.recordInteraction(PetInteraction.values[i % 3], day.add(Duration(minutes: i)));
      expect(engine.state.affectionPoints, greaterThanOrEqualTo(last));
      last = engine.state.affectionPoints;
    }
    expect(engine.state.affectionPoints, 8 + 8 + 3);
  });
}
