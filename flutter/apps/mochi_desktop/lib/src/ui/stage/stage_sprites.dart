// The native stage's pictures (docs/SPRINT_2.md N1, W30): each picture an actor shows (a pose of Mochi's, a note, a
// piece of confetti) is drawn once, at the display's scale, exactly as the taskbar's pictures of poses are
// (PoseSprites.render), read back as premultiplied RGBA and handed to the runner as a numbered sprite. Every later frame
// with the same picture is just its number.
//
// - A picture's key is everything its drawing depends on besides the context (the pose, the note's text and state…);
//   the context is what all of them depend on (the display's scale, the coat, what's worn, light or dark): when it
//   changes, every picture goes at once.
// - At most [StageSprites.budget] bytes of pictures are kept; the least recently used go first (the runner forgets
//   them too; an actor showing one keeps showing it until it's given another).
// - Drawing is asynchronous (reading the pixels back takes a frame): [lookup] answers at once with what's there, and
//   [ensure] draws what isn't (once, however often it's asked for meanwhile).

import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../platform/native_stage.dart';
import '../pet/pose_sprites.dart';

/// A picture the runner has: its number, its size and where in it the art's origin is (physical pixels).
@immutable
class StageSprite {
  const StageSprite({required this.id, required this.width, required this.height, required this.originX, required this.originY});

  final int id;
  final int width;
  final int height;

  /// The pixel where the art's origin is (Mochi's feet, a note's top-left).
  final int originX;
  final int originY;

  int get bytes => width * height * 4;

  /// The shot that puts the art's origin at [x], [y] (physical pixels on the screen).
  StageShot at(int actor, int x, int y, {int alpha = 255, bool clickThrough = false, bool topmost = true, bool hand = false}) => StageShot(
    actor: actor,
    sprite: id,
    left: x - originX,
    top: y - originY,
    alpha: alpha,
    clickThrough: clickThrough,
    topmost: topmost,
    hand: hand,
  );

  @override
  String toString() => 'StageSprite($id, ${width}x$height, origin $originX,$originY)';
}

/// How to draw a picture: what [paint] draws around the origin (logical pixels) within [bounds], at [ratio] physical
/// pixels to a logical one.
@immutable
class SpriteRecipe {
  const SpriteRecipe({required this.bounds, required this.ratio, required this.paint});

  final Rect bounds;
  final double ratio;
  final void Function(Canvas canvas) paint;
}

class StageSprites {
  StageSprites(this.stage, {this.budget = 24 << 20});

  final NativeStage stage;

  /// Bytes of pictures kept at most.
  final int budget;

  final LinkedHashMap<String, StageSprite> _ready = LinkedHashMap();
  final Map<String, Future<StageSprite?>> _pending = {};
  String? _context;
  int _bytes = 0;
  int _generation = 0;
  bool _disposed = false;

  /// Pictures drawn and handed over, and found already there (the perf meter and tests).
  int drawn = 0;
  int reused = 0;

  int get bytes => _bytes;
  int get length => _ready.length;
  int get pending => _pending.length;
  String? get context => _context;

  /// The pictures are for [context] now: when it changes, the old ones go.
  void use(String context) {
    if (context == _context) return;
    clear();
    _context = context;
  }

  /// The picture for [key] if it's there (it becomes the most recently used).
  StageSprite? lookup(String key) {
    final sprite = _ready.remove(key);
    if (sprite == null) return null;
    _ready[key] = sprite;
    reused++;
    return sprite;
  }

  /// The picture for [key], drawn from [recipe] (once) if it isn't there yet; null if it couldn't be (or the context
  /// changed meanwhile).
  Future<StageSprite?> ensure(String key, SpriteRecipe recipe) {
    final ready = lookup(key);
    if (ready != null) return SynchronousFuture(ready);
    final waiting = _pending[key];
    if (waiting != null) return waiting;
    final future = _draw({key: recipe}).then((drawn) => drawn[key]);
    _pending[key] = future;
    unawaited(future.whenComplete(() => _settled(key, future)));
    return future;
  }

  /// Draws every recipe that isn't there yet and hands them over in one go (confetti's pieces, a walk's poses).
  Future<void> prepare(Map<String, SpriteRecipe> recipes) async {
    final missing = <String, SpriteRecipe>{
      for (final MapEntry(:key, :value) in recipes.entries)
        if (!_ready.containsKey(key) && !_pending.containsKey(key)) key: value,
    };
    if (missing.isEmpty) return;
    final future = _draw(missing);
    for (final key in missing.keys) {
      final one = future.then((drawn) => drawn[key]);
      _pending[key] = one;
      unawaited(one.whenComplete(() => _settled(key, one)));
    }
    await future;
  }

  void _settled(String key, Future<StageSprite?> future) {
    if (identical(_pending[key], future)) _pending.remove(key);
  }

  Future<Map<String, StageSprite>> _draw(Map<String, SpriteRecipe> recipes) async {
    final generation = _generation;
    final images = <String, (ui.Image, SpriteRecipe)>{
      for (final MapEntry(:key, :value) in recipes.entries)
        key: (PoseSprites.render(bounds: value.bounds, ratio: value.ratio, paint: value.paint), value),
    };
    final data = <String, StageSpriteData>{};
    final sprites = <String, StageSprite>{};
    for (final MapEntry(:key, value: (image, recipe)) in images.entries) {
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (bytes == null || _disposed || generation != _generation) continue;
        final (ox, oy) = PoseSprites.origin(recipe.bounds, recipe.ratio);
        final id = stage.newSprite();
        data[key] = StageSpriteData(id: id, width: image.width, height: image.height, rgba: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
        sprites[key] = StageSprite(id: id, width: image.width, height: image.height, originX: ox.round(), originY: oy.round());
      } finally {
        image.dispose();
      }
    }
    if (_disposed || generation != _generation || sprites.isEmpty) return const {};
    stage.defineSprites(data.values.toList());
    for (final MapEntry(:key, value: sprite) in sprites.entries) {
      final replaced = _ready.remove(key);
      if (replaced != null) _forget(replaced);
      _ready[key] = sprite;
      _bytes += sprite.bytes;
      drawn++;
    }
    _evict();
    return sprites;
  }

  void _forget(StageSprite sprite) {
    _bytes -= sprite.bytes;
    stage.dropSprites([sprite.id]);
  }

  void _evict() {
    final dropped = <int>[];
    while (_bytes > budget && _ready.length > 1) {
      final oldest = _ready.keys.first;
      final sprite = _ready.remove(oldest)!;
      _bytes -= sprite.bytes;
      dropped.add(sprite.id);
    }
    stage.dropSprites(dropped);
  }

  /// Every picture goes (here and in the runner); pictures being drawn are thrown away when they're done.
  void clear() {
    _generation++;
    stage.dropSprites([for (final sprite in _ready.values) sprite.id]);
    _ready.clear();
    _pending.clear();
    _bytes = 0;
  }

  void dispose() {
    clear();
    _disposed = true;
  }
}
