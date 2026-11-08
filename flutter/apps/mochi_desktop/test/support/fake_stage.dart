// A native stage that records what it's told (docs/SPRINT_2.md N1): the sprites it has (with their pixels), what each
// actor shows, every call, and pointer events a test sends as if the runner saw them.

import 'dart:async';

import 'package:mochi_desktop/src/platform/native_stage.dart';

class FakeNativeStage extends NativeStage {
  FakeNativeStage({this.supported = true});

  @override
  final bool supported;

  /// The sprites the stage has now.
  final Map<int, StageSpriteData> sprites = {};

  /// What each actor shows now (hidden ones keep their last shot in [lastShots]).
  final Map<int, StageShot> showing = {};
  final Map<int, StageShot> lastShots = {};

  /// Actors whose windows exist (shown at least once, not removed).
  final Set<int> windows = {};

  /// Every call, by name ("sprites", "drop", "show", "hide", "remove", "raise", "clear").
  final List<String> calls = [];

  /// Every shot sent, in order.
  final List<StageShot> shots = [];

  int definedSprites = 0;
  int droppedSprites = 0;

  final StreamController<StagePointer> _pointer = StreamController.broadcast(sync: true);
  final StreamController<void> _displays = StreamController.broadcast(sync: true);

  int callsTo(String name) => calls.where((call) => call == name).length;

  @override
  void defineSprites(List<StageSpriteData> sprites) {
    calls.add('sprites');
    for (final sprite in sprites) {
      assert(sprite.rgba.length == sprite.width * sprite.height * 4, 'a sprite is width × height × 4 bytes');
      this.sprites[sprite.id] = sprite;
      definedSprites++;
    }
  }

  @override
  void dropSprites(List<int> ids) {
    calls.add('drop');
    for (final id in ids) {
      if (sprites.remove(id) != null) droppedSprites++;
    }
  }

  @override
  void show(List<StageShot> shots) {
    calls.add('show');
    for (final shot in shots) {
      this.shots.add(shot);
      showing[shot.actor] = shot;
      lastShots[shot.actor] = shot;
      windows.add(shot.actor);
    }
  }

  @override
  void hide(List<int> actors) {
    calls.add('hide');
    for (final actor in actors) {
      showing.remove(actor);
    }
  }

  @override
  void remove(List<int> actors) {
    calls.add('remove');
    for (final actor in actors) {
      showing.remove(actor);
      windows.remove(actor);
    }
  }

  @override
  void raise(List<int> actors) => calls.add('raise');

  @override
  void clear() {
    calls.add('clear');
    sprites.clear();
    showing.clear();
    windows.clear();
  }

  /// The runner saw the pointer do [kind] on [actor] at [x], [y] in it ([screenX], [screenY] on the screen).
  void point(int actor, StagePointerKind kind, {int x = 0, int y = 0, int? screenX, int? screenY}) {
    final shot = lastShots[actor];
    _pointer.add(
      StagePointer(
        actor: actor,
        kind: kind,
        x: x,
        y: y,
        screenX: screenX ?? (shot?.left ?? 0) + x,
        screenY: screenY ?? (shot?.top ?? 0) + y,
      ),
    );
  }

  /// A display came or went.
  void displaysChangedNow() => _displays.add(null);

  @override
  Stream<StagePointer> get pointer => _pointer.stream;

  @override
  Stream<void> get displaysChanged => _displays.stream;

  @override
  Future<Map<String, Object?>> info() async => {'sprites': sprites.length, 'actors': windows.length, 'shown': showing.length};

  @override
  void dispose() {
    unawaited(_pointer.close());
    unawaited(_displays.close());
  }
}
