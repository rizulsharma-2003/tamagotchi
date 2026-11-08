// Mochi's native stage (docs/SPRINT_2.md N1): small windows of Mochi's own anywhere on any display, drawn natively by
// the Windows runner (windows/runner/native_stage.cpp) and directed from here over the `mochi/stage` channel. Mochi out
// on the desktop (the cursor buddy, roaming the screens), its sticky notes and its full-screen celebrations are
// actors on it, while the Flutter window stays the app (so Mochi can be out while Mochi's window is open: W26).
//
// How it works:
// - Dart keeps all the logic and the art. Each picture is drawn once, at the display's scale, into premultiplied RGBA
//   (ui/stage/stage_sprites.dart, the same way the taskbar's pictures of poses are made: PoseSprites) and handed over
//   as a numbered sprite.
// - A frame is then only "actor A shows sprite S with its top-left at x, y", in physical pixels on the virtual screen
//   ([show], six numbers an actor, many actors in one call). The runner keeps each actor in a layered window and
//   updates it with UpdateLayeredWindow: a new picture copies only that sprite's pixels, a move copies none.
// - Windows hit-tests each actor per pixel: clicks on its transparent pixels go to whatever is under it, and clicks
//   and drags on the character come back here ([pointer]). An actor can let every click through instead (confetti).
// - Actors never take the focus, aren't in the taskbar or Alt+Tab, and are topmost only when asked.
// - Nothing runs in the runner on its own: no frames are sent while nothing changes, and none while the screen can't
//   be seen (the callers stop with PcRhythm.unseen).
//
// The macOS development build has no stage ([NoNativeStage]); tests use a recording fake (test/support/fake_stage.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One actor's frame: its picture, where its top-left goes (physical pixels), how opaque it is and how it takes clicks.
@immutable
class StageShot {
  const StageShot({
    required this.actor,
    required this.sprite,
    required this.left,
    required this.top,
    this.alpha = 255,
    this.clickThrough = false,
    this.topmost = true,
    this.hand = false,
  });

  final int actor;
  final int sprite;
  final int left;
  final int top;

  /// 0 (invisible) to 255.
  final int alpha;

  /// Every click goes through it to whatever is under it (otherwise only its transparent pixels let clicks through).
  final bool clickThrough;

  /// Above other windows.
  final bool topmost;

  /// The pointer is a hand over it (it can be clicked).
  final bool hand;

  /// The runner's flags (windows/runner/native_stage.h).
  int get flags => (clickThrough ? 1 : 0) | (topmost ? 2 : 0) | (hand ? 4 : 0);

  StageShot copyWith({int? sprite, int? left, int? top, int? alpha, bool? clickThrough, bool? topmost, bool? hand}) => StageShot(
    actor: actor,
    sprite: sprite ?? this.sprite,
    left: left ?? this.left,
    top: top ?? this.top,
    alpha: alpha ?? this.alpha,
    clickThrough: clickThrough ?? this.clickThrough,
    topmost: topmost ?? this.topmost,
    hand: hand ?? this.hand,
  );

  @override
  bool operator ==(Object other) =>
      other is StageShot &&
      other.actor == actor &&
      other.sprite == sprite &&
      other.left == left &&
      other.top == top &&
      other.alpha == alpha &&
      other.flags == flags;

  @override
  int get hashCode => Object.hash(actor, sprite, left, top, alpha, flags);

  @override
  String toString() => 'StageShot($actor: sprite $sprite at $left,$top α$alpha flags $flags)';
}

/// What the pointer did on an actor.
enum StagePointerKind { down, move, up, enter, leave, rightDown, rightUp, cancel }

/// A pointer event on an actor: where in the actor's picture and where on the screen (physical pixels).
@immutable
class StagePointer {
  const StagePointer({required this.actor, required this.kind, required this.x, required this.y, required this.screenX, required this.screenY});

  final int actor;
  final StagePointerKind kind;
  final int x;
  final int y;
  final int screenX;
  final int screenY;

  /// The runner's kinds (windows/runner/native_stage.h).
  static StagePointerKind? kindOf(int code) => switch (code) {
    1 => StagePointerKind.down,
    2 => StagePointerKind.move,
    3 => StagePointerKind.up,
    4 => StagePointerKind.enter,
    5 => StagePointerKind.leave,
    6 => StagePointerKind.rightDown,
    7 => StagePointerKind.rightUp,
    9 => StagePointerKind.cancel,
    _ => null,
  };

  @override
  String toString() => 'StagePointer($actor ${kind.name} at $x,$y / $screenX,$screenY)';
}

/// A picture for the stage: [rgba] is [width] × [height] premultiplied RGBA, top row first.
@immutable
class StageSpriteData {
  const StageSpriteData({required this.id, required this.width, required this.height, required this.rgba});

  final int id;
  final int width;
  final int height;
  final Uint8List rgba;
}

/// The stage (the runner's on Windows, none on the macOS build, a fake in tests). Calls are sent in order and not
/// waited for: a sprite defined before a [show] that uses it is there when the show arrives.
abstract class NativeStage {
  NativeStage();

  /// False where there's no stage (the macOS development build): the extras that need it say so in Settings.
  bool get supported;

  int _actors = 0;
  int _sprites = 0;

  /// A new actor's id (an actor's window is made the first time it's shown).
  int newActor() => ++_actors;

  /// A new sprite's id.
  int newSprite() => ++_sprites;

  /// Hands pictures over (each id once; a picture with an id already given replaces it).
  void defineSprites(List<StageSpriteData> sprites);

  /// Forgets pictures (an actor showing one keeps showing it until it's given another).
  void dropSprites(List<int> ids);

  /// Shows actors as [shots] say, in one go.
  void show(List<StageShot> shots);

  /// Hides actors (their windows stay, for the next show).
  void hide(List<int> actors);

  /// Takes actors' windows down.
  void remove(List<int> actors);

  /// Puts actors back above other windows (another always-on-top window may have come over them).
  void raise(List<int> actors);

  /// Takes everything down: every actor and every picture.
  void clear();

  /// Pointer events on actors.
  Stream<StagePointer> get pointer;

  /// A display came or went, or the work area changed (look at the displays again).
  Stream<void> get displaysChanged;

  /// Numbers for the perf meter and tests (the runner's: sprites, their bytes, actors, frames drawn and moves).
  Future<Map<String, Object?>> info();

  void dispose();
}

/// The Windows runner's stage, over the `mochi/stage` channel.
class ChannelNativeStage extends NativeStage {
  ChannelNativeStage({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('mochi/stage') {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final StreamController<StagePointer> _pointer = StreamController.broadcast(sync: true);
  final StreamController<void> _displays = StreamController.broadcast();

  @override
  bool get supported => true;

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'pointer':
        final values = call.arguments;
        if (values is List && values.length >= 6) {
          final kind = StagePointer.kindOf(values[1] as int);
          if (kind != null && !_pointer.isClosed) {
            _pointer.add(
              StagePointer(
                actor: values[0] as int,
                kind: kind,
                x: values[2] as int,
                y: values[3] as int,
                screenX: values[4] as int,
                screenY: values[5] as int,
              ),
            );
          }
        }
      case 'displays':
        if (!_displays.isClosed) _displays.add(null);
    }
    return null;
  }

  void _send(String method, [Object? arguments]) {
    _channel.invokeMethod<void>(method, arguments).catchError((Object error) {
      debugPrint('Mochi: the stage refused $method (${error.runtimeType})');
    });
  }

  @override
  void defineSprites(List<StageSpriteData> sprites) {
    if (sprites.isEmpty) return;
    _send('sprites', {
      'ids': Int32List.fromList([for (final sprite in sprites) sprite.id]),
      'widths': Int32List.fromList([for (final sprite in sprites) sprite.width]),
      'heights': Int32List.fromList([for (final sprite in sprites) sprite.height]),
      'pixels': [for (final sprite in sprites) sprite.rgba],
    });
  }

  @override
  void dropSprites(List<int> ids) {
    if (ids.isNotEmpty) _send('drop', Int32List.fromList(ids));
  }

  @override
  void show(List<StageShot> shots) {
    if (shots.isEmpty) return;
    final values = Int32List(shots.length * 6);
    var i = 0;
    for (final shot in shots) {
      values
        ..[i++] = shot.actor
        ..[i++] = shot.sprite
        ..[i++] = shot.left
        ..[i++] = shot.top
        ..[i++] = shot.alpha
        ..[i++] = shot.flags;
    }
    _send('show', values);
  }

  @override
  void hide(List<int> actors) {
    if (actors.isNotEmpty) _send('hide', Int32List.fromList(actors));
  }

  @override
  void remove(List<int> actors) {
    if (actors.isNotEmpty) _send('remove', Int32List.fromList(actors));
  }

  @override
  void raise(List<int> actors) {
    if (actors.isNotEmpty) _send('raise', Int32List.fromList(actors));
  }

  @override
  void clear() => _send('clear');

  @override
  Stream<StagePointer> get pointer => _pointer.stream;

  @override
  Stream<void> get displaysChanged => _displays.stream;

  @override
  Future<Map<String, Object?>> info() async {
    try {
      return await _channel.invokeMapMethod<String, Object?>('info') ?? const {};
    } on Object {
      return const {};
    }
  }

  @override
  void dispose() {
    clear();
    _channel.setMethodCallHandler(null);
    unawaited(_pointer.close());
    unawaited(_displays.close());
  }
}

/// No stage (the macOS development build): nothing shows, and Settings says the extras are for Windows.
class NoNativeStage extends NativeStage {
  @override
  bool get supported => false;

  @override
  void defineSprites(List<StageSpriteData> sprites) {}

  @override
  void dropSprites(List<int> ids) {}

  @override
  void show(List<StageShot> shots) {}

  @override
  void hide(List<int> actors) {}

  @override
  void remove(List<int> actors) {}

  @override
  void raise(List<int> actors) {}

  @override
  void clear() {}

  @override
  Stream<StagePointer> get pointer => const Stream.empty();

  @override
  Stream<void> get displaysChanged => const Stream.empty();

  @override
  Future<Map<String, Object?>> info() async => const {};

  @override
  void dispose() {}
}

/// The runner's stage on Windows, none elsewhere.
NativeStage systemStage() => Platform.isWindows ? ChannelNativeStage() : NoNativeStage();
