// W12, growing up: the rest of Sources/App/Features/Growth/GrowthController.swift (the stage itself is
// `LifeStage.stage`). Celebrates each new stage once, remembering the last one seen in the Mac's `lifeStageSeen`
// setting (-1 before the first look).

import '../model/animations.dart';
import '../progress/progress.dart';
import 'moment.dart';

/// The result of a growth check: the stage to draw, the `lifeStageSeen` value to store, and what to show (if any).
class GrowthUpdate {
  const GrowthUpdate({required this.stage, required this.seen, this.moment});
  final LifeStage stage;

  /// Store it when it changed (the Mac's `lifeStageSeen`, the stage's index).
  final int seen;
  final FeatureMoment? moment;
}

abstract final class Growth {
  /// Checks the stage (the Mac does it every minute). With life stages off Mochi is drawn grown up and nothing is
  /// announced. The first look introduces the kitten; a stage reached later is celebrated with a toast, a victory and a
  /// line.
  static GrowthUpdate check(ProgressState progress, DateTime now, {required bool lifeStages, required int seen, required String petName}) {
    if (!lifeStages) return GrowthUpdate(stage: LifeStage.grownUp, seen: seen);
    final stage = LifeStage.stage(progress, now);
    if (stage.index <= seen) return GrowthUpdate(stage: stage, seen: seen);
    if (seen < 0) {
      // The first look: introduce the kitten; anything later is already at home.
      return GrowthUpdate(
        stage: stage,
        seen: stage.index,
        moment: stage == LifeStage.kitten
            ? FeatureMoment(toast: FeatureToast('Meet kitten $petName!', '$petName grows up as your friendship grows.', seconds: 8))
            : null,
      );
    }
    final young = stage == LifeStage.young;
    return GrowthUpdate(
      stage: stage,
      seen: stage.index,
      moment: FeatureMoment(
        toast: FeatureToast(
          '$petName grew up!',
          young ? '$petName is a young cat now.' : '$petName is all grown up, and still your best friend.',
          seconds: 8,
        ),
        pet: PetAnimation.victory,
        line: FeatureLine(young ? 'Look how big I am!' : 'All grown up! ✨'),
      ),
    );
  }
}
