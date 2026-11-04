import Foundation

/// Mochi turning to listen where it stands (hold-to-talk in Mochi Pocket): the head swivels so its
/// right ear and shoulder come forward, that ear stands up tall towards you and the other folds back.
public enum ListeningPose {
    /// How long the turn takes.
    public static let turnDuration = 0.55

    /// `elapsed` counts from the start of the turn; once `listening`, the turn is complete and Mochi
    /// concentrates: a slow sway of the head and small flicks of the listening ear.
    public static func pose(elapsed: Double, listening: Bool, time: Double) -> PetPose {
        let context = PoseContext(time: time, reducedMotion: false, intensity: .normal, seed: 7)
        let turn = listening ? 1 : Ease.smooth(min(1, elapsed / turnDuration))
        var pose = PetPoseEvaluator.pose(.idle, elapsed: time, context: context)
        pose.x = 0
        pose.y = 0
        pose.facing = 1
        pose.headTurn = turn
        pose.earListen = turn
        pose.earPerk = Ease.lerp(pose.earPerk, 0.9, turn)
        // The right shoulder leads: the body leans and tips towards the listening ear.
        pose.lean = -0.11 * turn
        pose.rotation = -0.1 * turn
        pose.tilt = -0.16 * turn
        // Concentrating: eyes up, brows raised.
        pose.lookX = 0.1 * turn
        pose.lookY = -0.35 * turn
        pose.brows = turn > 0.5 ? .raised : pose.brows
        pose.eyeScale = 1 + 0.05 * turn
        pose.mouth = .cat
        if listening {
            pose.tilt += 0.02 * sin(time * 1.6)
            pose.earLeft = -0.09 * Ease.bump((time * 0.7).truncatingRemainder(dividingBy: 1), 0, 0.14)
        } else {
            // A little settle as the turn finishes.
            pose.scaleY *= 1 - 0.03 * Ease.bump(elapsed, turnDuration * 0.7, turnDuration * 1.3)
        }
        return pose
    }
}
