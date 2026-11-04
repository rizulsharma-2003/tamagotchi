import SwiftUI
import TamagotchiCore

/// `--render-listening <dir>`: Mochi turning to listen (Mochi Pocket's hold-to-talk), frame by frame,
/// next to its ordinary pose, for checking the pose without a phone.
@MainActor
enum ListeningStrip {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = PoseContext(time: 3, reducedMotion: false, intensity: .normal, seed: 7)
        var poses = [PetPoseEvaluator.pose(.idle, elapsed: 3, context: context)]
        for elapsed in [0.15, 0.3, 0.45, 0.6] {
            poses.append(ListeningPose.pose(elapsed: elapsed, listening: false, time: 3 + elapsed))
        }
        for time in [4.0, 4.3] {
            poses.append(ListeningPose.pose(elapsed: 1, listening: true, time: time))
        }
        let strip = Canvas { context, size in
            let cell = size.width / CGFloat(poses.count)
            for (index, pose) in poses.enumerated() {
                PetRenderer.draw(pose, in: context, at: CGPoint(x: cell * (CGFloat(index) + 0.5), y: size.height - 14), scale: 1.6,
                                 palette: PetPalette(.cream), accessory: nil, dark: false)
            }
        }
        .frame(width: 150 * CGFloat(poses.count), height: 150)
        .background(Color(red: 1.0, green: 0.96, blue: 0.92))
        SnapshotRenderer.write(strip, to: directory.appendingPathComponent("listening.png"), scale: 2)
        let pair = Canvas { context, size in
            for (index, pose) in [poses[0], poses[poses.count - 2]].enumerated() {
                PetRenderer.draw(pose, in: context, at: CGPoint(x: size.width * (index == 0 ? 0.25 : 0.75), y: size.height - 24), scale: 3.4,
                                 palette: PetPalette(.cream), accessory: nil, dark: false)
            }
        }
        .frame(width: 640, height: 300)
        .background(Color(red: 1.0, green: 0.96, blue: 0.92))
        SnapshotRenderer.write(pair, to: directory.appendingPathComponent("before-after.png"), scale: 1)
        print("Listening strip written to \(directory.path)")
    }
}
