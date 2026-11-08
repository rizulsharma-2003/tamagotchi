// Mochi as an actor on the native stage (docs/SPRINT_2.md N1): out on the desktop, Mochi is the same Mochi as on the
// taskbar. Its pose comes from Mochi's world through the pet's director (world_poses.dart: the world's moments play
// over whatever it's doing, loops come round on the ring), and each pose is drawn once into a picture at the display's
// scale (stage_sprites.dart) and reused every time it comes round. A frame is sent only when the picture or the place
// changes; a fade (a hop) changes only the window's opacity.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Offset, Rect;

import 'package:mochi_art/mochi_art.dart';

import '../../core/desktop_settings.dart';
import '../../core/desktop_world.dart';
import '../../platform/native_stage.dart';
import '../pet/mochi_view.dart' show ArtReach;
import '../pet/pet_director.dart';
import '../pet/stroller.dart' show StrollSample;
import 'stage_cast.dart';
import 'stage_sprites.dart';

class StagePet {
  StagePet({required this.stage, required this.cast, required this.sprites, required this.world, required this.settings, this.dark = _never})
    : actor = stage.newActor(),
      director = PetDirector(world);

  final NativeStage stage;
  final StageCast cast;
  final StageSprites sprites;
  final DesktopWorld world;
  final DesktopSettings settings;

  /// Mochi is drawn for a dark background (the app's theme, as on the taskbar).
  final bool Function() dark;

  /// Its window on the stage.
  final int actor;

  /// Mochi's mood and its poses (the taskbar's director, on the world's clock).
  final PetDirector director;

  static bool _never() => false;

  /// The picture it shows now, and the one it's waiting for.
  StageSprite? _sprite;
  String? _wanted;

  /// Where its feet are now (physical pixels), and how it was last placed.
  (int, int)? _feet;
  int _alpha = 255;
  bool _through = false;

  /// Where Mochi's feet are on the screen (null while it isn't out).
  (int, int)? get feet => _feet;

  /// Mochi is on the stage.
  bool get shown => cast.showing(actor);

  /// The picture it shows (tests).
  StageSprite? get sprite => _sprite;

  /// Mochi's body on the screen right now (physical pixels): what takes clicks.
  Rect? get body {
    final feet = _feet;
    final sprite = _sprite;
    if (feet == null || sprite == null) return null;
    final left = feet.$1 - sprite.originX, top = feet.$2 - sprite.originY;
    return Rect.fromLTWH(left.toDouble(), top.toDouble(), sprite.width.toDouble(), sprite.height.toDouble());
  }

  /// Everything a picture depends on besides the pose: the display's scale, Mochi's size, its coat and what it wears,
  /// light or dark, its age and whether animations are calm.
  String _context(double ratio, double unit) {
    final now = DateTime.now();
    return 'pet|$ratio|$unit|${settings.petColor.name}|${settings.wornByPet(now)?.name}|${dark()}|${PetRenderer.stage.name}|${world.world.reducedMotion}';
  }

  /// Draws Mochi at [time] (the world's clock) doing [motion] (walking, running, sitting, a little moment of its own;
  /// null: the world's own loop), its feet at [feet] (physical pixels) on a display at [ratio], [unit] logical pixels
  /// to an art unit. [quantum]: the loops' grid (seconds). False while the picture is still being drawn (Mochi keeps
  /// the one it has, moved to the new place).
  bool draw({
    required double time,
    required StrollSample? motion,
    required (int, int) feet,
    required double ratio,
    double unit = 1.2,
    double? quantum = 1 / 15,
    bool clickThrough = false,
    double opacity = 1,
  }) {
    sprites.use(_context(ratio, unit));
    final frame = director.pose(time, roam: motion, quantum: quantum);
    final pose = frame.pose;
    // A fade is the window's opacity, so the picture stays the same.
    final fade = (pose.opacity * opacity).clamp(0.0, 1.0);
    pose.opacity = 1;
    final key = 'pet ${jsonEncode(pose.toJson())}';
    final alpha = (fade * 255).round();
    _feet = feet;
    _alpha = alpha;
    _through = clickThrough;
    final ready = sprites.lookup(key);
    if (ready != null) {
      _wanted = null;
      _sprite = ready;
      _place();
      return true;
    }
    _wanted = key;
    final bounds = Rect.fromLTRB(ArtReach.pet.left * unit, ArtReach.pet.top * unit, ArtReach.pet.right * unit, ArtReach.pet.bottom * unit);
    final palette = PetPalette(settings.petColor);
    final accessory = settings.wornByPet(DateTime.now());
    final darkNow = dark();
    unawaited(
      sprites
          .ensure(
            key,
            SpriteRecipe(
              bounds: bounds,
              ratio: ratio,
              paint: (canvas) => PetRenderer.draw(pose, GContext(canvas), Offset.zero, unit, palette, accessory: accessory, dark: darkNow),
            ),
          )
          .then((sprite) {
            if (sprite == null || _wanted != key || _feet == null) return;
            _wanted = null;
            _sprite = sprite;
            _place();
          }),
    );
    // Meanwhile the picture it has goes along.
    if (_sprite != null) _place();
    return false;
  }

  void _place() {
    final sprite = _sprite;
    final feet = _feet;
    if (sprite == null || feet == null) return;
    cast.place(sprite.at(actor, feet.$1, feet.$2, alpha: _alpha, clickThrough: _through, hand: !_through));
    cast.flush();
  }

  /// Mochi leaves the stage (its window stays, hidden, for next time).
  void hide() {
    _feet = null;
    _wanted = null;
    cast
      ..hide(actor)
      ..flush();
  }

  /// Puts Mochi back above other always-on-top windows.
  void raise() {
    if (shown) stage.raise([actor]);
  }

  void dispose() {
    _wanted = null;
    cast.remove([actor]);
  }
}
