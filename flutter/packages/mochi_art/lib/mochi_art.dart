/// Mochi, Patch and their room, drawn with Flutter's Canvas: a port of the Swift renderers
/// in Sources/App/Rendering, the room (Features/Room) and the seasonal art (Features/Seasons)
/// that the iPhone shares (iOS/SharedArt).
///
/// Start with the `CustomPainter`s in `painters.dart` (`PetPainter`, `CompanionPainter`,
/// `ScenePainter`, `FurniturePainter`), or draw into a [GContext] with the renderers directly
/// (`PetRenderer.draw`, `CompanionRenderer.draw`, `SceneRenderer.draw`, …). The model types
/// (`PetPose`, `CompanionPose`, `SceneConfig`, `RoomLayout`, …) read the JSON the Swift side
/// writes: enum names are the Swift raw values, keys the Swift property names.
///
/// Not ported yet (TODO):
/// - The pose evaluators (TamagotchiCore/Animation: `PetPoseEvaluator`, `CompanionPoseEvaluator`,
///   `PetIdleLife`, `PetPlay`/`PetTreat`/`PetAffection`, `InteractionLibrary`) and the world that
///   drives them. Poses come ready-made (from Swift, or recorded tracks as in the gallery).
/// - Menu-bar-only drawing (`MenuBarGlyph`, `MenuBarPetCanvas`, the bed), the popover's speech
///   bubbles (`SceneSpeechOverlay`) and the desktop pet; the seasonal calendar and greetings.
/// - Fonts: Swift draws z/?/! and the bunting letters in SF Pro Rounded; here they use
///   [MochiArtText.family] (the platform font by default). Bundle an OFL rounded font for
///   Android and Windows. SF Symbols in speech bubbles are vector approximations.
library;

export 'src/accessory_renderer.dart';
export 'src/companion_renderer.dart';
export 'src/drawing.dart';
export 'src/furniture_art.dart';
export 'src/item_renderer.dart';
export 'src/listening.dart';
export 'src/model/ease.dart';
export 'src/model/poses.dart';
export 'src/model/world.dart';
export 'src/painters.dart';
export 'src/palettes.dart';
export 'src/pet_renderer.dart';
export 'src/pet_tiny_fit.dart';
export 'src/pixel_mascot.dart';
export 'src/room_decor.dart';
export 'src/scene_layout.dart';
export 'src/scene_renderer.dart';
export 'src/season_art.dart';
export 'src/season_decor.dart';
export 'src/seasonal_treats.dart';
export 'src/theme_renderer.dart';
