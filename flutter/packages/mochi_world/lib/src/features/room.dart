// W18, room makeover. Port of Sources/TamagotchiCore/Features/FurnitureCatalog.swift (the twelve pieces, their sizes
// and how each is earned) and RoomModels.swift (the placed furniture the Mac keeps in its `room` setting: snapping to
// the wall or floor band, finding a free spot, the size limit, drawing order and clean-up), plus the editor's rules
// from Sources/App/Features/Room/RoomEditorController.swift (only unlocked pieces can be added; a piece dropped on the
// tray is put away). Drawing and the scene geometry (`RoomSpace`) live in mochi_art.

import 'dart:math' as math;

import '../model/json.dart';
import '../progress/progress.dart';

/// Where a piece of furniture lives in the room.
enum FurniturePlacement {
  /// Hangs on the back wall (posters, clocks, photos).
  wall,

  /// Stands on the floor, behind the characters.
  floor,
}

/// How a piece of furniture is earned. Nothing is ever taken away again.
sealed class FurnitureUnlock {
  const FurnitureUnlock();

  bool isMet(ProgressState progress);

  /// How to earn it, for tooltips.
  String get hint;
}

class FurnitureAlways extends FurnitureUnlock {
  const FurnitureAlways();

  @override
  bool isMet(ProgressState progress) => true;

  @override
  String get hint => 'Available';
}

class FurnitureAtLevel extends FurnitureUnlock {
  const FurnitureAtLevel(this.level);
  final int level;

  @override
  bool isMet(ProgressState progress) => progress.friendshipLevel >= level;

  @override
  String get hint => 'Unlocks at friendship level $level';
}

class FurnitureForAchievement extends FurnitureUnlock {
  const FurnitureForAchievement(this.achievement);
  final AchievementID achievement;

  @override
  bool isMet(ProgressState progress) => progress.unlocked[achievement.name] != null;

  @override
  String get hint => 'Unlock: ${achievement.title} — ${achievement.criteria}';
}

/// One kind of furniture in the catalogue.
class FurnitureKind {
  const FurnitureKind({
    required this.id,
    required this.title,
    required this.placement,
    this.isFlat = false,
    required this.width,
    required this.height,
    required this.unlock,
    required this.defaultX,
  });

  /// Stable identifier, stored in [PlacedFurniture.kind].
  final String id;
  final String title;
  final FurniturePlacement placement;

  /// Lies flat on the floor (a rug), so it goes under everything else.
  final bool isFlat;

  /// Size in scene points at scale 1 (the Mac's popover room is 360 × 178).
  final double width;
  final double height;
  final FurnitureUnlock unlock;

  /// Where it goes when added with a click instead of a drag (normalized).
  final double defaultX;

  bool isUnlocked(ProgressState progress) => unlock.isMet(progress);

  /// How to earn it, for tooltips.
  String get unlockHint => unlock.hint;

  /// Default vertical position: a little above the middle of the wall, or at the back of the floor.
  double get defaultY => switch (placement) {
    FurniturePlacement.wall => 0.36,
    FurniturePlacement.floor => isFlat ? RoomLayout.rugBand.$1 : RoomLayout.floorBand.$1,
  };
}

/// The cosy furniture Mochi and the companion can decorate their room with.
abstract final class FurnitureCatalog {
  /// The room the sizes are designed for.
  static const double roomWidth = 360;
  static const double roomHeight = 178;

  static const List<FurnitureKind> all = [
    FurnitureKind(
      id: 'rug',
      title: 'Round Rug',
      placement: FurniturePlacement.floor,
      isFlat: true,
      width: 92,
      height: 15,
      unlock: FurnitureAlways(),
      defaultX: 0.47,
    ),
    FurnitureKind(
      id: 'cushion',
      title: 'Floor Cushion',
      placement: FurniturePlacement.floor,
      width: 30,
      height: 15,
      unlock: FurnitureAlways(),
      defaultX: 0.47,
    ),
    FurnitureKind(
      id: 'plant',
      title: 'Big Plant',
      placement: FurniturePlacement.floor,
      width: 34,
      height: 58,
      unlock: FurnitureAlways(),
      defaultX: 0.06,
    ),
    FurnitureKind(
      id: 'poster',
      title: 'Sunset Poster',
      placement: FurniturePlacement.wall,
      width: 30,
      height: 38,
      unlock: FurnitureAlways(),
      defaultX: 0.47,
    ),
    FurnitureKind(
      id: 'lamp',
      title: 'Floor Lamp',
      placement: FurniturePlacement.floor,
      width: 24,
      height: 84,
      unlock: FurnitureAtLevel(1),
      defaultX: 0.94,
    ),
    FurnitureKind(
      id: 'bookshelf',
      title: 'Bookshelf',
      placement: FurniturePlacement.floor,
      width: 40,
      height: 64,
      unlock: FurnitureAtLevel(2),
      defaultX: 0.07,
    ),
    FurnitureKind(
      id: 'beanbag',
      title: 'Beanbag',
      placement: FurniturePlacement.floor,
      width: 40,
      height: 26,
      unlock: FurnitureAtLevel(3),
      defaultX: 0.93,
    ),
    FurnitureKind(
      id: 'catTree',
      title: 'Cat Tree',
      placement: FurniturePlacement.floor,
      width: 40,
      height: 86,
      unlock: FurnitureAtLevel(4),
      defaultX: 0.07,
    ),
    FurnitureKind(
      id: 'clock',
      title: 'Wall Clock',
      placement: FurniturePlacement.wall,
      width: 24,
      height: 24,
      unlock: FurnitureForAchievement(AchievementID.firstSession),
      defaultX: 0.55,
    ),
    FurnitureKind(
      id: 'photo',
      title: 'Photo of the Two Friends',
      placement: FurniturePlacement.wall,
      width: 34,
      height: 27,
      unlock: FurnitureForAchievement(AchievementID.firstTurn),
      defaultX: 0.4,
    ),
    FurnitureKind(
      id: 'fishBowl',
      title: 'Fish Bowl',
      placement: FurniturePlacement.floor,
      width: 26,
      height: 40,
      unlock: FurnitureForAchievement(AchievementID.firstGreenBuild),
      defaultX: 0.93,
    ),
    FurnitureKind(
      id: 'toyBox',
      title: 'Toy Box',
      placement: FurniturePlacement.floor,
      width: 30,
      height: 23,
      unlock: FurnitureForAchievement(AchievementID.goodFriends),
      defaultX: 0.47,
    ),
  ];

  static FurnitureKind? kind(String id) {
    for (final kind in all) {
      if (kind.id == id) return kind;
    }
    return null;
  }

  static List<FurnitureKind> unlocked(ProgressState progress) => all.where((k) => k.isUnlocked(progress)).toList();
}

/// One placed piece.
class PlacedFurniture {
  PlacedFurniture({required this.id, required this.kind, required this.x, required this.y, this.flipped = false});

  /// A UUID string (the Mac's `UUID`).
  final String id;

  /// Catalogue identifier of the furniture kind.
  final String kind;

  /// Position in the room, normalized 0…1 (x across the room, y from the back wall to the floor front).
  double x;
  double y;
  bool flipped;

  PlacedFurniture copy() => PlacedFurniture(id: id, kind: kind, x: x, y: y, flipped: flipped);

  Map<String, Object?> toJson() => {'id': id, 'kind': kind, 'x': x, 'y': y, 'flipped': flipped};

  static PlacedFurniture? fromJson(Object? json) {
    final j = asMap(json);
    final id = string(j, 'id');
    final kind = string(j, 'kind');
    if (id == null || kind == null || j['x'] is! num || j['y'] is! num) return null;
    return PlacedFurniture(id: id, kind: kind, x: dbl(j, 'x', 0.5), y: dbl(j, 'y', 0.9), flipped: boolean(j, 'flipped', false));
  }
}

/// The user's room decoration (the Mac's `room` setting: `{"items": [...]}`).
class RoomLayout {
  RoomLayout({List<PlacedFurniture>? items, String Function()? newID}) : items = items ?? [], _newID = newID ?? randomUUID;

  final List<PlacedFurniture> items;
  final String Function() _newID;

  /// At most this many pieces, so the room stays cosy rather than cluttered.
  static const int maxItems = 8;

  /// Centre of a wall item, as a fraction of the room height.
  static const (double, double) wallBand = (0.26, 0.6);

  /// Foot of a floor item, from the back of the floor (just behind the characters' feet) to a little forward.
  static const (double, double) floorBand = (0.87, 0.92);

  /// Centre of a rug lying on the floor.
  static const (double, double) rugBand = (0.9, 0.95);

  bool get isFull => items.length >= maxItems;

  /// The vertical band an item of [kind] may occupy.
  static (double, double) band(FurnitureKind kind) => switch (kind.placement) {
    FurniturePlacement.wall => wallBand,
    FurniturePlacement.floor => kind.isFlat ? rugBand : floorBand,
  };

  /// (x, y) moved into the room: wall items snap to the wall band, floor items to the floor, and nothing hangs over
  /// the left or right edge.
  static (double, double) snapped(FurnitureKind kind, double x, double y) {
    final half = math.min(0.5, kind.width / 2 / FurnitureCatalog.roomWidth);
    final safeX = x.isFinite ? x : kind.defaultX;
    final safeY = y.isFinite ? y : kind.defaultY;
    final b = band(kind);
    return (math.min(math.max(safeX, half), 1 - half), math.min(math.max(safeY, b.$1), b.$2));
  }

  /// Adds a piece, at (x, y) or at a free spot near its default place. Returns null when the room is full.
  PlacedFurniture? add(FurnitureKind kind, {double? x, double? y, String? id}) {
    if (isFull) return null;
    final position = x != null && y != null ? snapped(kind, x, y) : freeSpot(kind);
    final item = PlacedFurniture(id: id ?? _newID(), kind: kind.id, x: position.$1, y: position.$2);
    items.add(item);
    return item;
  }

  /// The editor's add (the Mac's RoomEditorController): only pieces the friendship has unlocked.
  PlacedFurniture? addUnlocked(FurnitureKind kind, ProgressState progress, {double? x, double? y}) =>
      kind.isUnlocked(progress) ? add(kind, x: x, y: y) : null;

  /// Moves a piece, snapping it into its band.
  void move(String id, double x, double y) {
    final index = items.indexWhere((i) => i.id == id);
    if (index < 0) return;
    final kind = FurnitureCatalog.kind(items[index].kind);
    if (kind == null) return;
    final position = snapped(kind, x, y);
    items[index]
      ..x = position.$1
      ..y = position.$2;
  }

  void remove(String id) => items.removeWhere((i) => i.id == id);

  void toggleFlip(String id) {
    for (final item in items) {
      if (item.id == id) {
        item.flipped = !item.flipped;
        return;
      }
    }
  }

  void clear() => items.clear();

  /// Drops a dragged piece (the Mac's editor): a new one ([existing] null) is added if it's unlocked, a placed one
  /// moved, and anything dropped back on the tray is put away. Returns the piece that was added or moved.
  PlacedFurniture? drop(
    FurnitureKind kind, {
    String? existing,
    required bool overTray,
    required double x,
    required double y,
    required ProgressState progress,
  }) {
    if (existing != null) {
      if (overTray) {
        remove(existing);
        return null;
      }
      move(existing, x, y);
      for (final item in items) {
        if (item.id == existing) return item;
      }
      return null;
    }
    return overTray ? null : addUnlocked(kind, progress, x: x, y: y);
  }

  /// The room as it should be drawn: unknown kinds (from a newer version) dropped, every piece back in its band, at
  /// most [maxItems].
  RoomLayout sanitized() {
    final result = RoomLayout(newID: _newID);
    for (final item in items) {
      if (result.items.length >= maxItems) break;
      final kind = FurnitureCatalog.kind(item.kind);
      if (kind == null) continue;
      final position = snapped(kind, item.x, item.y);
      result.items.add(PlacedFurniture(id: item.id, kind: item.kind, x: position.$1, y: position.$2, flipped: item.flipped));
    }
    return result;
  }

  /// Back-to-front drawing order: rugs, then the wall, then floor pieces from the back.
  List<PlacedFurniture> get drawingOrder {
    (int, double) rank(PlacedFurniture item) {
      final kind = FurnitureCatalog.kind(item.kind);
      if (kind == null) return (3, item.y);
      if (kind.isFlat) return (0, item.y);
      return (kind.placement == FurniturePlacement.wall ? 1 : 2, item.y);
    }

    final indexed = items.indexed.toList()
      ..sort((a, b) {
        final ra = rank(a.$2);
        final rb = rank(b.$2);
        if (ra.$1 != rb.$1) return ra.$1.compareTo(rb.$1);
        if (ra.$2 != rb.$2) return ra.$2.compareTo(rb.$2);
        return a.$1.compareTo(b.$1);
      });
    return indexed.map((e) => e.$2).toList();
  }

  /// The default spot for [kind], nudged sideways when something already stands there.
  (double, double) freeSpot(FurnitureKind kind) {
    final b = band(kind);
    final step = math.max(0.06, kind.width / FurnitureCatalog.roomWidth);
    for (final offset in const [0.0, 1, -1, 2, -2, 3, -3]) {
      final candidate = snapped(kind, kind.defaultX + offset * step, kind.defaultY);
      final crowded = items.any((other) {
        final otherKind = FurnitureCatalog.kind(other.kind);
        if (otherKind == null || band(otherKind) != b) return false;
        return (other.x - candidate.$1).abs() < step * 0.6;
      });
      if (!crowded) return candidate;
    }
    return snapped(kind, kind.defaultX, kind.defaultY);
  }

  /// Settings › Room: "5 of 12 pieces unlocked · 3 of 8 placed".
  String summary(ProgressState progress) =>
      '${FurnitureCatalog.unlocked(progress).length} of ${FurnitureCatalog.all.length} pieces unlocked · ${items.length} of $maxItems placed';

  RoomLayout copy() => RoomLayout(items: [for (final i in items) i.copy()], newID: _newID);

  Map<String, Object?> toJson() => {
    'items': [for (final i in items) i.toJson()],
  };

  /// Reads the Mac's `room` setting (or a bare list of items); unusable items are skipped.
  static RoomLayout fromJson(Object? json, {String Function()? newID}) {
    final raw = json is Map ? asMap(json)['items'] : json;
    return RoomLayout(
      items: [
        if (raw is List)
          for (final entry in raw)
            if (PlacedFurniture.fromJson(entry) case final item?) item,
      ],
      newID: newID,
    );
  }
}

final math.Random _uuidRandom = math.Random.secure();

/// A random UUID string in the Mac's form (upper-case hex, version 4).
String randomUUID() {
  final bytes = List<int>.generate(16, (_) => _uuidRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
