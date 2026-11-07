// The settings types only the renderers take (the coat, the room's style, the detail level), from TamagotchiCore's
// Settings/AppSettings.swift. The rest of the model the renderers draw (the animations, interactions and scene props,
// accessories, life stages, holidays and the room's furniture) lives in mochi_world, Mochi's world in Dart, and is
// re-exported here: one set of types for the art, the world and the apps. Enum case names equal the Swift raw values.

export 'package:mochi_world/mochi_world.dart'
    show
        Accessory,
        AccessorySlot,
        CompanionAnimation,
        FurnitureCatalog,
        FurnitureKind,
        FurniturePlacement,
        InteractionID,
        LifeStage,
        PetAnimation,
        PlacedFurniture,
        RoomLayout,
        SceneProp,
        ScenePropKind,
        SeasonalEvent;

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

/// How much detail to draw: `tiny` is menu-bar scale (about 12–16 pt tall).
enum RenderDetail { standard, tiny }
