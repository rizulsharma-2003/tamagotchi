// The native stage's actors as the runner last showed them (docs/SPRINT_2.md N1, W30): a frame sends only the actors
// whose picture, place, opacity or clicks changed, all in one call, and nothing at all when nothing changed.

import '../../platform/native_stage.dart';

class StageCast {
  StageCast(this.stage);

  final NativeStage stage;
  final Map<int, StageShot> _shown = {};
  final List<StageShot> _queued = [];
  final List<int> _hiding = [];

  /// Shots sent, and shots that changed nothing and weren't (tests, the perf meter).
  int sent = 0;
  int unchanged = 0;

  /// Calls to the runner (each [flush] with something to send is one).
  int calls = 0;

  /// What [actor] shows (null: hidden, or never shown).
  StageShot? shown(int actor) => _shown[actor];

  bool showing(int actor) => _shown.containsKey(actor);

  /// The actors showing now.
  Iterable<int> get actors => _shown.keys;

  /// [shot] goes at the next [flush], unless the actor shows exactly that already.
  void place(StageShot shot) {
    if (_shown[shot.actor] == shot) {
      unchanged++;
      return;
    }
    _shown[shot.actor] = shot;
    _queued.removeWhere((queued) => queued.actor == shot.actor);
    _queued.add(shot);
    _hiding.remove(shot.actor);
  }

  /// [actor] is hidden at the next [flush] (if it shows).
  void hide(int actor) {
    if (_shown.remove(actor) == null) return;
    _queued.removeWhere((queued) => queued.actor == actor);
    _hiding.add(actor);
  }

  /// Sends what changed since the last flush.
  void flush() {
    if (_queued.isNotEmpty) {
      stage.show(List.of(_queued));
      sent += _queued.length;
      calls++;
      _queued.clear();
    }
    if (_hiding.isNotEmpty) {
      stage.hide(List.of(_hiding));
      calls++;
      _hiding.clear();
    }
  }

  /// [actors]' windows go (they're shown afresh next time).
  void remove(List<int> actors) {
    if (actors.isEmpty) return;
    for (final actor in actors) {
      _shown.remove(actor);
      _queued.removeWhere((queued) => queued.actor == actor);
      _hiding.remove(actor);
    }
    stage.remove(actors);
  }

  /// Forgets what's showing (the runner's actors were cleared).
  void reset() {
    _shown.clear();
    _queued.clear();
    _hiding.clear();
  }
}
