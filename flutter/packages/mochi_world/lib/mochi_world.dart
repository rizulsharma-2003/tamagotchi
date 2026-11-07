/// Mochi's world in Dart: the Mac's pet-life engine (Sources/TamagotchiCore) for Mochi for Windows and Android.
///
/// Start with `MochiWorld`: give it a seed, a clock and settings, call `tick()` a few times a second, feed it Claude's
/// hook events (`ingestWire`) and the user's petting, play and treats (`interact`), and read what to draw with
/// `frame()` (both poses and the scene props), `speech`, `toast`, `caption` and `progress`. `toJson()` / `restore` keep
/// it across launches. The pieces underneath can be used on their own: the pose evaluators (`PetPoseEvaluator`,
/// `CompanionPoseEvaluator`), the interaction scripts (`InteractionLibrary`) and their seeded scheduler
/// (`InteractionScheduler`), the animation state machine (`CharacterAnimator`), friendship and achievements
/// (`AchievementEngine`, `LifeStage`) and the celebration rules for real Claude events (`Celebrations`).
///
/// The Sprint 2 features are here as logic too, for the apps to draw: what Mochi says (`SpeechLines`,
/// `SpeechDirector`), the mini-games (`CatchGame`, `RPSMatch`, `GameRecords`), the focus buddy (`FocusTimer`,
/// `FocusBuddy`), the daily recap (`DailyRecap`, `EventJournal`, `RecapSchedule`), the room makeover
/// (`FurnitureCatalog`, `RoomLayout`), holidays (`SeasonCalendar`, `SeasonTracker`) and growing up (`Growth`). Each
/// returns a `FeatureMoment` (a toast, a line, animations, a sound) where the Mac's controller would act.
///
/// Everything is deterministic for a seed and the injected clock, and checked against the Swift engine with the golden
/// fixtures in link-spec/world (see docs/MOCHI_WORLD.md).
library;

export 'src/animation/character_animator.dart';
export 'src/animation/choreography.dart' show Curve, Track;
export 'src/animation/companion_pose_evaluator.dart' show CompanionDetail, CompanionPoseEvaluator;
export 'src/animation/pet_pose_evaluator.dart';
export 'src/events/events.dart';
export 'src/features/focus.dart';
export 'src/features/games.dart';
export 'src/features/growth.dart';
export 'src/features/moment.dart';
export 'src/features/recap.dart';
export 'src/features/room.dart';
export 'src/features/seasons.dart';
export 'src/features/speech.dart';
export 'src/interactions/interaction_library.dart';
export 'src/model/animations.dart';
export 'src/model/ease.dart' show Ease, Keys, ieeeRemainder;
export 'src/model/poses.dart';
export 'src/model/random.dart';
export 'src/events/sessions.dart';
export 'src/interactions/interaction_scheduler.dart';
export 'src/progress/progress.dart';
export 'src/world/celebrations.dart';
export 'src/world/policy.dart';
export 'src/world/reactions.dart';
export 'src/world/settings.dart';
export 'src/world/world.dart';
