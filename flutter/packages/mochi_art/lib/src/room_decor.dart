// Port of Sources/App/Features/Room/RoomDecor.swift.

import 'package:flutter/painting.dart';

import 'drawing.dart';
import 'furniture_art.dart';
import 'model/ease.dart';
import 'model/world.dart';
import 'scene_layout.dart';

/// Maps placed furniture between normalized room positions and scene points.
class RoomSpace {
  const RoomSpace(this.layout);

  final SceneLayout layout;

  double get width => layout.size.width;
  double get height => layout.size.height;

  /// 0 at the back of the floor band, 1 at its front.
  double depth(FurnitureKind kind, double y) {
    final band = RoomLayout.band(kind);
    return Ease.clamp((y - band.$1) / (band.$2 - band.$1));
  }

  /// The scene's scale, a touch larger towards the front of the floor.
  double scale(FurnitureKind kind, double y) =>
      kind.placement == FurniturePlacement.floor && !kind.isFlat ? layout.scale * (0.96 + 0.08 * depth(kind, y)) : layout.scale;

  /// Wall pieces and rugs: their centre. Floor pieces: the middle of their foot.
  Offset anchor(PlacedFurniture item, FurnitureKind kind) {
    final x = item.x * width;
    switch (kind.placement) {
      case FurniturePlacement.wall:
        return Offset(x, item.y * height);
      case FurniturePlacement.floor:
        final d = depth(kind, item.y);
        final lift = kind.isFlat ? 6 + 7 * d : 0.5 + 7 * d;
        return Offset(x, layout.ground + lift * layout.scale);
    }
  }

  Rect frame(PlacedFurniture item, FurnitureKind kind) => frameAt(anchor(item, kind), kind, scale(kind, item.y));

  Rect frameAt(Offset a, FurnitureKind kind, double k) {
    final size = Size(kind.width * k, kind.height * k);
    if (kind.placement == FurniturePlacement.floor && !kind.isFlat) {
      return Rect.fromLTWH(a.dx - size.width / 2, a.dy - size.height, size.width, size.height);
    }
    return Rect.fromLTWH(a.dx - size.width / 2, a.dy - size.height / 2, size.width, size.height);
  }

  /// The snapped normalized position for a piece whose anchor is dragged to `point`.
  (double, double) position(Offset point, FurnitureKind kind) {
    final x = point.dx / width;
    double y;
    switch (kind.placement) {
      case FurniturePlacement.wall:
        y = point.dy / height;
      case FurniturePlacement.floor:
        final band = RoomLayout.band(kind);
        final lift = (point.dy - layout.ground) / layout.scale;
        final d = kind.isFlat ? (lift - 6) / 7 : (lift - 0.5) / 7;
        y = band.$1 + Ease.clamp(d) * (band.$2 - band.$1);
    }
    return RoomLayout.snapped(kind, x, y);
  }
}

/// Draws the placed furniture into the scene, behind the characters.
abstract final class RoomDecor {
  /// The piece an editor is carrying; the scene leaves it out meanwhile.
  static String? liftedID;

  static void draw(RoomLayout room, GContext g, SceneLayout layout, {bool dark = false, double time = 0}) {
    if (!layout.background || room.items.isEmpty) return;
    for (final item in room.drawingOrder) {
      if (item.id == liftedID) continue;
      final kind = FurnitureCatalog.kind(item.kind);
      if (kind == null) continue;
      drawPiece(item, kind, g, layout, dark: dark, time: time);
    }
  }

  static void drawPiece(PlacedFurniture item, FurnitureKind kind, GContext g, SceneLayout layout, {bool dark = false, double time = 0}) {
    final space = RoomSpace(layout);
    final anchor = space.anchor(item, kind);
    final k = space.scale(kind, item.y);
    final piece = g.copy()
      ..translateBy(anchor.dx, anchor.dy)
      // The clock keeps its numbers the right way round.
      ..scaleBy(item.flipped && kind.id != 'clock' ? -k : k, k);
    FurnitureArt.draw(kind.id, piece, dark: dark, time: time);
  }
}
