// The settings, room and scene types the renderers take, ported from TamagotchiCore
// (Settings/AppSettings.swift, Progress/Customization.swift, Features/*.swift,
// Interactions/InteractionLibrary.swift, Animation/CharacterAnimations.swift).
// Enum case names equal the Swift raw values.

import 'ease.dart';
import 'json.dart';

enum PetColor {
  cream,
  peach,
  mint,
  sky,
  lavender,
  cocoa,
  midnight;

  String get title => name[0].toUpperCase() + name.substring(1);
}

enum OfficeTheme {
  cozyDesk('Cozy Desk'),
  cyberpunk('Cyberpunk Workstation'),
  spaceStation('Space Station'),
  gardenOffice('Tiny Garden Office');

  const OfficeTheme(this.title);
  final String title;
}

enum AccessorySlot { wearable, desk }

enum Accessory {
  partyHat('Party Hat'),
  beanie('Cozy Beanie'),
  graduationCap('Graduation Cap'),
  detectiveHat('Detective Hat'),
  santaHat('Festive Hat'),
  flowerCrown('Flower Crown'),
  witchHat('Witch Hat'),
  roundGlasses('Round Glasses'),
  headphones('Tiny Headphones'),
  hoodie('Developer Hoodie'),
  scarf('Knitted Scarf'),
  plant('Desk Plant'),
  coffeeMug('Coffee Mug'),
  rubberDuck('Rubber Duck'),
  pumpkin('Little Pumpkin'),
  trophy('Tiny Trophy'),
  lavaLamp('Lava Lamp');

  const Accessory(this.title);
  final String title;

  AccessorySlot get slot => switch (this) {
    Accessory.plant ||
    Accessory.coffeeMug ||
    Accessory.rubberDuck ||
    Accessory.pumpkin ||
    Accessory.trophy ||
    Accessory.lavaLamp => AccessorySlot.desk,
    _ => AccessorySlot.wearable,
  };
}

/// Mochi's life stage (Swift encodes it as its Int raw value: kitten 0, young 1, grownUp 2).
enum LifeStage {
  kitten('Kitten'),
  young('Young'),
  grownUp('Grown-up');

  const LifeStage(this.title);
  final String title;

  static LifeStage? fromJson(Object? value) =>
      value is int && value >= 0 && value < values.length ? values[value] : enumByName(values, value);
}

enum SeasonalEvent {
  halloween('Halloween'),
  diwali('Diwali'),
  christmas('Christmas'),
  newYear('New Year'),
  valentines("Valentine's Day"),
  userBirthday('Your birthday'),
  mochiBirthday("Pet's birthday");

  const SeasonalEvent(this.title);
  final String title;
}

/// How much detail to draw: `tiny` is menu-bar scale (about 12–16 pt tall).
enum RenderDetail { standard, tiny }

// MARK: - Animations (names and titles only; the pose evaluators are not ported yet)

enum PetAnimation {
  idle,
  sleep,
  watch,
  waveGently,
  lookAround,
  happyBounce,
  excitedJump,
  roll,
  dance,
  confusedTilt,
  concerned,
  victory,
  greet,
  petted,
  play,
  leanForward,
  nod,
  blep,
  yawn,
  treat,
  wakeUp,
  wave,
  walk,
  carry,
  offer,
  highFive,
  sit,
  rpsShake,
  curl,
  run,
  pounce,
  bat,
  tumble,
  sniff,
  stretch,
  scratch,
  shake,
  leapCatch,
  scripted;

  bool get isLoop => switch (this) {
    idle || sleep || watch || waveGently || walk || carry || sit || curl || run => true,
    _ => false,
  };

  String get title => switch (this) {
    waveGently => 'Gentle wave',
    lookAround => 'Look around',
    happyBounce => 'Happy bounce',
    excitedJump => 'Excited jump',
    confusedTilt => 'Confused tilt',
    leanForward => 'Lean forward',
    wakeUp => 'Wake up',
    highFive => 'High five',
    rpsShake => 'Rock-paper-scissors',
    leapCatch => 'Leap and catch',
    _ => name[0].toUpperCase() + name.substring(1),
  };
}

enum CompanionAnimation {
  absent,
  idleAtDesk,
  thinking,
  typing,
  reading,
  searching,
  runningCommand,
  browsing,
  delegating,
  waiting,
  detective,
  rest,
  sleep,
  offline,
  arrive,
  setup,
  readTaskCard,
  concerned,
  celebrate,
  trophy,
  packUp,
  depart,
  greet,
  nod,
  wakeUp,
  stretch,
  sip,
  dance,
  presentCode,
  highFive,
  catchBall,
  doubleTake,
  pat,
  rpsShake,
  scripted;

  String get title => switch (this) {
    idleAtDesk => 'Idle at desk',
    runningCommand => 'Watching a command',
    readTaskCard => 'Reading task card',
    packUp => 'Packing up',
    wakeUp => 'Waking up',
    presentCode => 'Showing code',
    highFive => 'High five',
    catchBall => 'Catching',
    doubleTake => 'Double take',
    _ => name[0].toUpperCase() + name.substring(1),
  };
}

// MARK: - Scene props

enum ScenePropKind { ball, orb, clap, confetti, sparkle, butterfly, yarn, leaf, dust, bubble, treat, crumb }

/// A prop an interaction places in the scene (`SceneProp`).
class SceneProp {
  SceneProp(this.kind, {this.x = 0, this.y = 0, this.scale = 1, this.opacity = 1, this.rotation = 0, this.variant = 0});

  factory SceneProp.fromJson(Map<String, Object?> j) => SceneProp(
    enumByName(ScenePropKind.values, j['kind']) ?? ScenePropKind.sparkle,
    x: dbl(j, 'x', 0),
    y: dbl(j, 'y', 0),
    scale: dbl(j, 'scale', 1),
    opacity: dbl(j, 'opacity', 1),
    rotation: dbl(j, 'rotation', 0),
    variant: integer(j, 'variant', 0),
  );

  ScenePropKind kind;

  /// 0 = the pet's home position, 1 = the companion's.
  double x;

  /// Height above the floor in pet body heights.
  double y;
  double scale, opacity, rotation;
  int variant;
}

// MARK: - Furniture and the room

enum FurniturePlacement { wall, floor }

class FurnitureKind {
  const FurnitureKind({
    required this.id,
    required this.title,
    required this.placement,
    this.isFlat = false,
    required this.width,
    required this.height,
    required this.defaultX,
  });

  /// Stable identifier, stored in `PlacedFurniture.kind`.
  final String id;
  final String title;
  final FurniturePlacement placement;

  /// Lies flat on the floor (a rug), so it goes under everything else.
  final bool isFlat;

  /// Size in scene points at scale 1 (the popover room is 360 × 178).
  final double width, height;
  final double defaultX;

  double get defaultY => switch (placement) {
    FurniturePlacement.wall => 0.36,
    FurniturePlacement.floor => isFlat ? RoomLayout.rugBand.$1 : RoomLayout.floorBand.$1,
  };
}

abstract final class FurnitureCatalog {
  static const double roomWidth = 360;
  static const double roomHeight = 178;

  static const List<FurnitureKind> all = [
    FurnitureKind(id: 'rug', title: 'Round Rug', placement: FurniturePlacement.floor, isFlat: true, width: 92, height: 15, defaultX: 0.47),
    FurnitureKind(id: 'cushion', title: 'Floor Cushion', placement: FurniturePlacement.floor, width: 30, height: 15, defaultX: 0.47),
    FurnitureKind(id: 'plant', title: 'Big Plant', placement: FurniturePlacement.floor, width: 34, height: 58, defaultX: 0.06),
    FurnitureKind(id: 'poster', title: 'Sunset Poster', placement: FurniturePlacement.wall, width: 30, height: 38, defaultX: 0.47),
    FurnitureKind(id: 'lamp', title: 'Floor Lamp', placement: FurniturePlacement.floor, width: 24, height: 84, defaultX: 0.94),
    FurnitureKind(id: 'bookshelf', title: 'Bookshelf', placement: FurniturePlacement.floor, width: 40, height: 64, defaultX: 0.07),
    FurnitureKind(id: 'beanbag', title: 'Beanbag', placement: FurniturePlacement.floor, width: 40, height: 26, defaultX: 0.93),
    FurnitureKind(id: 'catTree', title: 'Cat Tree', placement: FurniturePlacement.floor, width: 40, height: 86, defaultX: 0.07),
    FurnitureKind(id: 'clock', title: 'Wall Clock', placement: FurniturePlacement.wall, width: 24, height: 24, defaultX: 0.55),
    FurnitureKind(id: 'photo', title: 'Photo of the Two Friends', placement: FurniturePlacement.wall, width: 34, height: 27, defaultX: 0.4),
    FurnitureKind(id: 'fishBowl', title: 'Fish Bowl', placement: FurniturePlacement.floor, width: 26, height: 40, defaultX: 0.93),
    FurnitureKind(id: 'toyBox', title: 'Toy Box', placement: FurniturePlacement.floor, width: 30, height: 23, defaultX: 0.47),
  ];

  static FurnitureKind? kind(String id) {
    for (final kind in all) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

class PlacedFurniture {
  PlacedFurniture({required this.id, required this.kind, required this.x, required this.y, this.flipped = false});

  factory PlacedFurniture.fromJson(Map<String, Object?> j, [int index = 0]) => PlacedFurniture(
    id: string(j, 'id') ?? 'item-$index',
    kind: string(j, 'kind') ?? '',
    x: dbl(j, 'x', 0.5),
    y: dbl(j, 'y', 0.9),
    flipped: boolean(j, 'flipped', false),
  );

  /// The Swift side's UUID string (any unique string works here).
  final String id;

  /// Catalog identifier of the furniture kind.
  final String kind;

  /// Normalized position (x across the room, y from the back wall to the floor front).
  double x, y;
  bool flipped;
}

class RoomLayout {
  RoomLayout([List<PlacedFurniture>? items]) : items = items ?? [];

  factory RoomLayout.fromJson(Object? json) {
    final raw = json is Map ? asMap(json)['items'] : json;
    if (raw is! List) return RoomLayout();
    var index = 0;
    return RoomLayout(raw.whereType<Map<Object?, Object?>>().map((m) => PlacedFurniture.fromJson(asMap(m), index++)).toList());
  }

  final List<PlacedFurniture> items;

  static const int maxItems = 8;
  static const (double, double) wallBand = (0.26, 0.6);
  static const (double, double) floorBand = (0.87, 0.92);
  static const (double, double) rugBand = (0.9, 0.95);

  bool get isFull => items.length >= maxItems;

  static (double, double) band(FurnitureKind kind) => switch (kind.placement) {
    FurniturePlacement.wall => wallBand,
    FurniturePlacement.floor => kind.isFlat ? rugBand : floorBand,
  };

  static (double, double) snapped(FurnitureKind kind, double x, double y) {
    final half = (kind.width / 2 / FurnitureCatalog.roomWidth).clamp(0.0, 0.5);
    final safeX = x.isFinite ? x : kind.defaultX;
    final safeY = y.isFinite ? y : kind.defaultY;
    final b = band(kind);
    return (Ease.clamp(safeX, half, 1 - half), Ease.clamp(safeY, b.$1, b.$2));
  }

  /// Adds a piece at (x, y), snapped into its band. Returns null when the room is full.
  PlacedFurniture? add(FurnitureKind kind, double x, double y, {String? id, bool flipped = false}) {
    if (isFull) return null;
    final position = snapped(kind, x, y);
    final item = PlacedFurniture(id: id ?? 'item-${items.length}', kind: kind.id, x: position.$1, y: position.$2, flipped: flipped);
    items.add(item);
    return item;
  }

  /// Back-to-front drawing order: rugs, then the wall, then floor pieces from the back.
  List<PlacedFurniture> get drawingOrder {
    (int, double) rank(PlacedFurniture item) {
      final kind = FurnitureCatalog.kind(item.kind);
      if (kind == null) return (3, item.y);
      if (kind.isFlat) return (0, item.y);
      return (kind.placement == FurniturePlacement.wall ? 1 : 2, item.y);
    }

    final sorted = [...items];
    // A stable sort, like Swift's `sorted` for these keys.
    final indexed = sorted.asMap().entries.toList()
      ..sort((a, b) {
        final ra = rank(a.value);
        final rb = rank(b.value);
        if (ra.$1 != rb.$1) return ra.$1.compareTo(rb.$1);
        if (ra.$2 != rb.$2) return ra.$2.compareTo(rb.$2);
        return a.key.compareTo(b.key);
      });
    return indexed.map((e) => e.value).toList();
  }
}

// MARK: - Interactions (names and titles, for galleries)

enum InteractionID {
  coffeeDelivery('Coffee delivery'),
  showCode('Show and tell'),
  ballDistraction('Ball distraction'),
  rockPaperScissors('Rock, paper, scissors'),
  sleepWatch('Keeping watch'),
  chairSteal('Chair thief'),
  keyboardNap('Keyboard nap'),
  mysteryOrb('The mysterious glow'),
  welcome('Welcome'),
  highFive('High five'),
  victoryDance('Victory dance'),
  trophyCelebration('Tiny trophy'),
  caseClosed('Case closed'),
  detectiveHat('Detective mode'),
  graduation('Graduation'),
  syncDance('Synchronized dance');

  const InteractionID(this.title);
  final String title;
}
