// W14: Catch the Treats, rock-paper-scissors and the game records against the Swift engine
// (link-spec/world/games.json), plus the Mac app's game rules (sounds, toasts, the stage), which have no Swift fixture.

import 'package:mochi_world/mochi_world.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

Map<String, Object?> _checkpoint(CatchGame g, int after) => {
  'after': after,
  'time': g.time,
  'phase': g.phase.name,
  'score': g.score,
  'combo': g.combo,
  'bestCombo': g.bestCombo,
  'caught': g.caught,
  'misses': g.misses,
  'level': g.level,
  'petX': g.petX,
  'petVelocity': g.petVelocity,
  'facing': g.facing,
  'treats': [
    for (final t in g.treats) [t.id, t.kind.name, t.x, t.y, t.speed, t.spin, t.age],
  ],
  'splashes': [
    for (final s in g.splashes) [s.kind.name, s.x, s.y, s.points, s.at],
  ],
  if (g.reaction case final r?) 'reaction': [r.kind.name, r.at],
};

List<Object?> _event(int step, CatchEvent e) => switch (e) {
  CatchCaught(:final kind, :final points, :final combo) => [step, 'caught', kind.name, points, combo],
  CatchMissed(:final kind) => [step, 'missed', kind.name],
  CatchFaster(:final level) => [step, 'faster', level],
  CatchGameOver(:final score) => [step, 'gameOver', score],
};

Map<String, Object?> _records(GameRecords r) => r.toJson();

void main() {
  final fixture = readWorldFixture('games.json');

  test('tables: combo multiplier, fall speed and spawn interval', () {
    final tables = obj(fixture['tables']);
    expect([for (var c = 0; c <= 41; c++) CatchGame.multiplier(c)], tables['multiplier']);
    expect(diffJson([for (var l = 1; l <= 8; l++) CatchGame.fallSpeed(l)], tables['fallSpeed']), isEmpty);
    expect(diffJson([for (var l = 1; l <= 8; l++) CatchGame.spawnInterval(l)], tables['spawnInterval']), isEmpty);
  });

  for (final c in cases(fixture, 'catch')) {
    test('Catch the Treats: ${c['note']}', () {
      final game = CatchGame(parseUnsigned(c['seed']))..autoSpawn = c['autoSpawn'] != false;
      final dts = (c['dts']! as List).map((d) => (d! as num).toDouble()).toList();
      final steps = c['steps']! as int;
      final every = c['every']! as int;
      final drops = (c['drops'] as List? ?? const []).cast<List<Object?>>();
      final keys = (c['keys'] as List?)?.cast<List<Object?>>();
      final drag = (c['drag'] as List?)?.cast<List<Object?>>();
      final events = <Object?>[];
      final checkpoints = <Object?>[];
      final expectedPoses = {for (final p in objs(c['poses'])) p['after']! as int: p};
      for (var i = 0; i < steps; i++) {
        for (final d in drops.where((d) => d[0] == i)) {
          game.drop(
            byName(TreatKind.values, d[1]),
            (d[2]! as num).toDouble(),
            y: (d[3]! as num).toDouble(),
            speed: (d[4] as num?)?.toDouble(),
          );
        }
        final CatchInput input;
        if (keys != null) {
          final segment = keys.lastWhere((s) => (s[0]! as int) <= i, orElse: () => [0, 0]);
          input = CatchInput(direction: (segment[1]! as num).toDouble());
        } else if (drag != null) {
          final segment = drag.lastWhere((s) => (s[0]! as int) <= i, orElse: () => [0, null]);
          input = CatchInput(targetX: (segment[1] as num?)?.toDouble());
        } else {
          CatchTreat? lowest;
          for (final t in game.treats) {
            if (lowest == null || t.y < lowest.y) lowest = t;
          }
          input = CatchInput(targetX: lowest?.x);
        }
        for (final e in game.step(dts[i % dts.length], input)) {
          events.add(_event(i, e));
        }
        if (i % every == every - 1 || i == steps - 1) checkpoints.add(_checkpoint(game, i));
        if (expectedPoses[i] case final p?) {
          final context = contextFromJson(obj(p['context']));
          expect(diffPet(game.petPose(context), obj(p['pose'])), isEmpty, reason: 'pose after step $i');
        }
      }
      expect(diffJson(events, c['events']), isEmpty, reason: 'events');
      expect(diffJson(checkpoints, c['checkpoints']), isEmpty, reason: 'checkpoints');
    });
  }

  for (final c in cases(fixture, 'rps')) {
    test('rock-paper-scissors, seed ${c['seed']}${c['withCompanion'] == true ? ' with Patch' : ''}', () {
      final match = RPSMatch(parseUnsigned(c['seed']), withCompanion: c['withCompanion'] == true);
      final records = GameRecords();
      final rounds = <Object?>[];
      for (var i = 0; i < 60; i++) {
        final round = match.playChoice(RPSChoice.values[(i * 7 + i ~/ 3) % 3]);
        final best = records.recordRPS(round, streak: match.streak);
        rounds.add([
          round.player.name,
          round.pet.name,
          round.companion?.name,
          round.vsPet,
          round.vsCompanion,
          round.isWin,
          round.isLoss,
          match.streak,
          best,
        ]);
      }
      expect(rounds, c['rounds']);
      expect([match.vsPet.wins, match.vsPet.losses, match.vsPet.draws], c['vsPet']);
      expect([match.vsCompanion.wins, match.vsCompanion.losses, match.vsCompanion.draws], c['vsCompanion']);
      expect(match.rounds, hasLength(c['kept']! as int));
      expect(_records(records), c['records']);
    });
  }

  test('Catch the Treats records, and the Mac\'s records JSON', () {
    final records = GameRecords();
    for (final step in (fixture['catchRecords']! as List).cast<List<Object?>>()) {
      final high = records.recordCatch(score: step[0]! as int, bestCombo: step[1]! as int);
      expect(high, step[2]);
      expect(_records(records), step[3]);
      expect(GameRecords.fromJson(step[3]), records);
    }
    expect(GameRecords.fromJson({'catchHighScore': 12}).toJson(), {...GameRecords().toJson(), 'catchHighScore': 12});
    expect(GameRecords().isEmpty, isTrue);
    expect(GameRecords().catchSummary, 'Not played yet');
    expect(records.catchSummary, 'Best 40 · best combo 30 · 6 played');
  });

  group('the Mac app\'s game rules', () {
    test('a finished game: a new high score celebrates, anything else is a soft sound', () {
      final records = GameRecords();
      final empty = CatchGame(1)..autoSpawn = false;
      for (final x in [0.05, 0.95, 0.9]) {
        empty.drop(TreatKind.cookie, x, y: 0.3);
      }
      while (empty.phase == CatchPhase.playing) {
        empty.step(1 / 60);
      }
      final (zeroRecord, zeroMoment) = empty.finish(records, petName: 'Mochi');
      expect(zeroRecord, isFalse, reason: 'a score of 0 is never a record');
      expect(zeroMoment.sound, SoundCue.sleep);
      expect(records.catchGamesPlayed, 1);

      final good = CatchGame(1)..autoSpawn = false;
      good.drop(TreatKind.golden, 0.5, y: 0.5);
      while (good.treats.isNotEmpty) {
        good.step(1 / 60);
      }
      final (record, moment) = good.finish(records, petName: 'Mochi');
      expect(record, isTrue);
      expect(moment.sound, SoundCue.celebration);
      expect(moment.pet, PetAnimation.excitedJump);
      expect(moment.toast, const FeatureToast('New high score: 5!', 'Mochi caught 1 treats. Yum!'));
      final again = good.finish(records, petName: 'Mochi');
      expect([again.$1, again.$2.isEmpty, records.catchGamesPlayed], [false, true, 2], reason: 'a game is recorded once');
      expect(CatchGame.momentFor(const CatchCaught(TreatKind.golden, points: 5, combo: 1))?.sound, SoundCue.success);
      expect(CatchGame.momentFor(const CatchCaught(TreatKind.fish, points: 1, combo: 1))?.sound, SoundCue.pop);
      expect(CatchGame.momentFor(const CatchMissed(TreatKind.fish)), isNull);
    });

    test('a revealed round: sounds, and a toast for a best streak of three or more', () {
      final records = GameRecords();
      const win = RPSRound(player: RPSChoice.rock, pet: RPSChoice.scissors, companion: RPSChoice.rock);
      const loss = RPSRound(player: RPSChoice.rock, pet: RPSChoice.paper);
      const draw = RPSRound(player: RPSChoice.rock, pet: RPSChoice.rock);
      expect(RPSMatch.reveal(win, streak: 1, records: records).sound, SoundCue.success);
      expect(RPSMatch.reveal(win, streak: 2, records: records).sound, SoundCue.success, reason: 'a best streak under 3 is quiet');
      final best = RPSMatch.reveal(win, streak: 3, records: records);
      expect(best.toast, const FeatureToast('New best streak: 3!', 'Rock, paper, scissors champion.'));
      expect(best.sound, SoundCue.celebration);
      expect(RPSMatch.reveal(loss, streak: 0, records: records).sound, SoundCue.investigate);
      expect(RPSMatch.reveal(draw, streak: 0, records: records).sound, SoundCue.pop);
      expect(records.rpsBestStreak, 3);
      expect(records.rpsSummary, '3 won · 1 lost · 4 drawn');
    });

    test('round results in words', () {
      String text(RPSRound r) {
        final t = r.result(petName: 'Mochi', companionName: 'Patch');
        return '${t.headline} ${t.detail}';
      }

      expect(
        text(const RPSRound(player: RPSChoice.rock, pet: RPSChoice.scissors, companion: RPSChoice.scissors)),
        'Clean sweep! You beat Mochi · you beat Patch',
      );
      expect(
        text(const RPSRound(player: RPSChoice.rock, pet: RPSChoice.scissors, companion: RPSChoice.rock)),
        'You win! You beat Mochi · a draw with Patch',
      );
      expect(text(const RPSRound(player: RPSChoice.rock, pet: RPSChoice.paper)), 'They got you! Mochi wins');
      expect(
        text(const RPSRound(player: RPSChoice.rock, pet: RPSChoice.paper, companion: RPSChoice.rock)),
        'Not this time! Mochi wins · a draw with Patch',
      );
      expect(text(const RPSRound(player: RPSChoice.paper, pet: RPSChoice.paper)), 'Great minds think alike! A draw with Mochi');
      expect(
        text(const RPSRound(player: RPSChoice.paper, pet: RPSChoice.rock, companion: RPSChoice.scissors)),
        'Split decision! You beat Mochi · Patch wins',
      );
      expect(rpsChoiceForKey('S'), RPSChoice.scissors);
      expect(rpsChoiceForKey('2'), RPSChoice.paper);
      expect(rpsChoiceForKey('x'), isNull);
      expect(RPSChoice.scissors.emoji, '✌️');
    });

    test('the stage: shake, hold, react, with the characters\' hands', () {
      final context = PoseContext(time: 50, seed: 3);
      const round = RPSRound(player: RPSChoice.rock, pet: RPSChoice.scissors, companion: RPSChoice.paper);
      expect(RPSStage.petPose(null, null, context).lookX, 0.5);
      expect(RPSStage.chant(0.2), 'Rock…');
      expect(RPSStage.chant(1.6), 'Shoot!');
      expect(RPSStage.chant(2.2), isNull);
      final shaking = RPSStage.petPose(round, 0.7, context);
      expect(shaking.held, isNull, reason: 'the hand is only shown at the reveal');
      final holding = RPSStage.petPose(round, RPSStage.shake + 0.2, context);
      expect(holding.held, HeldItem.scissors);
      expect(holding.eyes, PetEyes.wide);
      expect(holding.rightArm, greaterThanOrEqualTo(0.45));
      final patch = RPSStage.companionPose(round, RPSStage.shake + RPSStage.hold + 5, context);
      expect(patch.held, HeldItem.paper);
      expect(patch.eyes, VisorEyes.happy, reason: 'Patch beat you and keeps smiling');
      expect(RPSStage.companionPose(const RPSRound(player: RPSChoice.rock, pet: RPSChoice.rock), 2, context).held, isNull);
      expect(RPSStage.badge(1), 'Won!');
      expect(
        RPSStage.prompt(busy: false, withCompanion: true, petName: 'Mochi', companionName: 'Patch'),
        'Pick one: you play Mochi and Patch at once.',
      );
    });
  });
}
