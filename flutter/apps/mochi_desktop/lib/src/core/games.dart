// The mini-games on this PC (Sprint 2 W14): Catch the Treats and rock-paper-scissors with Mochi and Patch, as the
// Mac's GamesController (Sources/App/Features/Games) runs them. The games themselves are mochi_world's (`CatchGame`,
// `RPSMatch`, `RPSStage`, checked against the Mac's fixture); this keeps a game going, plays its moments in Mochi's
// world (a pop for a catch, a chime for a golden cookie, a jump, a note and a fanfare for a new record) and keeps the
// records in Settings under the Mac's key, `games`.
//
// Catch the Treats is stepped by its field on the screen, once a frame and only while a game is being played; it
// pauses when Mochi's window loses the focus or closes, when you switch to the other game, and when the screen can't
// be seen. A round of rock-paper-scissors is two short timers (the reveal at the shake, the end of the round).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'desktop_settings.dart';
import 'desktop_world.dart';

/// Which game shows in the Games window.
enum GameTab {
  catchTreats('Catch the Treats'),
  rps('Rock, Paper, Scissors');

  const GameTab(this.title);
  final String title;
}

/// Where a game of Catch the Treats is (the Mac's `CatchModel.Phase`).
enum CatchPhase { ready, playing, paused, over }

/// The running game and its input, moved on once a frame by the field (the Mac's CatchSession). Not a listenable: it
/// changes every frame and only the field reads it.
class CatchSession {
  CatchSession(int seed) : game = w.CatchGame(seed);

  final w.CatchGame game;

  /// ← or A, → or D held down.
  bool left = false;
  bool right = false;

  /// Where the pointer is while dragging (field units).
  double? dragX;

  double? _lastFrame;

  /// When the speed last went up (game time), for the "Faster!" note.
  double? fasterAt;

  w.CatchInput get input => w.CatchInput(direction: (right ? 1.0 : 0.0) - (left ? 1.0 : 0.0), targetX: dragX);

  /// Moves the game on to [time] (seconds, any steady clock). The first call only sets the clock.
  List<w.CatchEvent> advance(double time) {
    final last = _lastFrame;
    _lastFrame = time;
    if (last == null || !(time > last)) return const [];
    final events = game.step(time - last, input);
    if (events.any((event) => event is w.CatchFaster)) fasterAt = game.time;
    return events;
  }

  /// Forgets the last frame (after a pause, so no time jumps by) and lets go of the keys and the pointer.
  void resetClock() {
    _lastFrame = null;
    left = false;
    right = false;
    dragX = null;
  }
}

class DesktopGames extends ChangeNotifier {
  DesktopGames({required this.settings, required this.world, int Function()? seed}) : _seed = seed ?? _randomSeed {
    _match = w.RPSMatch(_seed(), withCompanion: companionPlays);
  }

  final DesktopSettings settings;
  final DesktopWorld world;
  final int Function() _seed;

  static final math.Random _random = math.Random.secure();

  /// A fresh, non-zero 64-bit seed (as a bit pattern), as the Mac picks one per game.
  static int _randomSeed() {
    final seed = (_random.nextInt(1 << 32) << 32) | _random.nextInt(1 << 32);
    return seed == 0 ? 1 : seed;
  }

  /// The game showing.
  GameTab _tab = GameTab.catchTreats;
  GameTab get tab => _tab;
  set tab(GameTab value) {
    if (value == _tab) return;
    _tab = value;
    // The Mac pauses the treats when you switch to the other game.
    if (value != GameTab.catchTreats) pauseCatch();
    notifyListeners();
  }

  /// The Games window was opened (at [tab], if given): a new sitting of rock-paper-scissors when Patch has started or
  /// stopped showing since the last one.
  void show([GameTab? tab]) {
    if (tab != null) this.tab = tab;
    if (!_busy && _match.withCompanion != companionPlays) _resetMatch();
  }

  /// The window closed or lost the focus: the treats pause (the Mac's resign-key).
  void leave() => pauseCatch();

  // MARK: Catch the Treats

  CatchPhase _phase = CatchPhase.ready;
  CatchPhase get catchPhase => _phase;

  CatchSession _session = CatchSession(1);

  /// Read at draw time: a new game swaps the session without changing the phase.
  CatchSession get session => _session;

  /// How the last game went (for the game-over card).
  int lastScore = 0;
  int lastCaught = 0;
  int lastBestCombo = 0;
  bool newRecord = false;

  /// The score of the game being played, for the screen reader (it changes with each catch, never each frame).
  final ValueNotifier<int> score = ValueNotifier(0);

  void startCatch() {
    _session = CatchSession(_seed());
    score.value = 0;
    _setPhase(CatchPhase.playing);
  }

  void pauseCatch() {
    if (_phase != CatchPhase.playing) return;
    _session.resetClock();
    _setPhase(CatchPhase.paused);
  }

  void resumeCatch() {
    if (_phase != CatchPhase.paused) return;
    _session.resetClock();
    _setPhase(CatchPhase.playing);
  }

  /// Space: play, pause, resume or play again.
  void toggleCatch() => switch (_phase) {
    CatchPhase.ready || CatchPhase.over => startCatch(),
    CatchPhase.playing => pauseCatch(),
    CatchPhase.paused => resumeCatch(),
  };

  /// One frame of the game being played at [time] (seconds on the world's clock).
  void frame(double time) {
    if (_phase != CatchPhase.playing) return;
    handle(_session.advance(time));
  }

  /// A step's events: a pop for a catch, a chime for a golden cookie, and the end of the game.
  @visibleForTesting
  void handle(List<w.CatchEvent> events) {
    for (final event in events) {
      world.apply(w.CatchGame.momentFor(event));
      switch (event) {
        case w.CatchCaught():
          score.value = _session.game.score;
        case w.CatchGameOver():
          _finishCatch();
        default:
          break;
      }
    }
  }

  void _finishCatch() {
    if (_phase != CatchPhase.playing) return;
    final game = _session.game;
    final records = settings.games;
    final (record, moment) = game.finish(records, petName: settings.petName);
    settings.games = records;
    lastScore = game.score;
    lastCaught = game.caught;
    lastBestCombo = game.bestCombo;
    newRecord = record;
    _setPhase(CatchPhase.over);
    world.apply(moment);
  }

  void _setPhase(CatchPhase phase) {
    if (phase == _phase) return;
    _phase = phase;
    notifyListeners();
  }

  // MARK: Rock, paper, scissors

  /// Patch plays too, unless he's set never to show.
  bool get companionPlays => settings.companionVisibility != CompanionVisibility.never;

  late w.RPSMatch _match;
  w.RPSMatch get match => _match;

  w.RPSRound? _round;

  /// The round on stage (the last one, between rounds).
  w.RPSRound? get round => _round;

  double? _startedAt;

  /// When the round began, on the world's clock.
  double? get roundStartedAt => _startedAt;

  bool _revealed = false;

  /// The round has been scored (the result line and the scores show).
  bool get revealed => _revealed;

  bool _busy = false;

  /// A round is being played: no new pick until it's over.
  bool get busy => _busy;

  Timer? _revealTimer;
  Timer? _endTimer;

  /// A pick (a button, R/P/S or 1/2/3): the characters' picks are fixed before the shake, scored at its end.
  void pick(w.RPSChoice choice) {
    if (_busy) return;
    final picks = _match.nextPicks();
    _round = w.RPSRound(player: choice, pet: picks.pet, companion: picks.companion);
    _startedAt = world.now();
    _revealed = false;
    _busy = true;
    _revealTimer = Timer(_seconds(w.RPSStage.shake), _reveal);
    _endTimer = Timer(_seconds(w.RPSStage.roundLength), () {
      _busy = false;
      notifyListeners();
    });
    notifyListeners();
  }

  static Duration _seconds(double seconds) => Duration(microseconds: (seconds * 1e6).round());

  void _reveal() {
    final round = _round;
    if (round == null || _revealed) return;
    _match.play(round);
    _revealed = true;
    final records = settings.games;
    final moment = w.RPSMatch.reveal(round, streak: _match.streak, records: records);
    settings.games = records;
    world.apply(moment);
    notifyListeners();
  }

  void _resetMatch() {
    _match = w.RPSMatch(_seed(), withCompanion: companionPlays);
    _round = null;
    _startedAt = null;
    _revealed = false;
    notifyListeners();
  }

  // MARK: Records

  /// Settings › Fun › Games › Reset Records: high scores and win counts start over.
  void resetRecords() => settings.games = w.GameRecords();

  @override
  void dispose() {
    _revealTimer?.cancel();
    _endTimer?.cancel();
    score.dispose();
    super.dispose();
  }
}
