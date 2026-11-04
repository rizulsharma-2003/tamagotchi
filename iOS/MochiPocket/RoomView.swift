import SwiftUI
import TamagotchiCore

/// Mochi's room — the same scene as the Mac's panel, with the companion at the desk. Tap Mochi to
/// pet it; press and hold Mochi to talk: it turns its right ear and shoulder towards you and listens.
struct RoomView: View {
    let phone: PhoneWorld
    let talk: TalkModel
    @State private var pressStart: Date?

    var body: some View {
        let snapshot = SceneSnapshot(world: phone.world)
        GeometryReader { geometry in
            // The Mac panel's room, scaled up for a phone.
            let layout = SceneLayout(size: geometry.size, ground: geometry.size.height - 26, petHome: geometry.size.width * 0.26,
                                     companionHome: geometry.size.width * 0.70, scale: min(1.55, geometry.size.height / 170),
                                     background: true, emptyDesk: true)
            TimelineView(.animation) { timeline in
                let frameDate = timeline.date
                Canvas { context, _ in
                    _ = frameDate
                    let time = ProcessInfo.processInfo.systemUptime
                    let hour = Calendar.current.component(.hour, from: Date())
                    let phase = talk.phase
                    let elapsed = max(0, Date().timeIntervalSince(talk.phaseStart))
                    SceneRenderer.draw(snapshot, layout: layout, in: context, time: time, dark: false, hour: hour,
                                       petOverride: phase.overridesPet ? { Self.pose($0, phase: phase, elapsed: elapsed, time: time) } : nil)
                    if phase == .listening || phase == .approaching {
                        Self.drawSoundWaves(in: context, layout: layout, time: time,
                                            appear: phase == .listening ? 1 : min(1, elapsed / ListeningPose.turnDuration))
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: layout.petFrame.width + 24, height: layout.petFrame.height + 24)
                    .offset(x: layout.petFrame.minX - 12, y: layout.petFrame.minY - 12)
                    .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 60) {
                        talk.earHeld()
                    } onPressingChanged: { pressing in
                        if pressing {
                            pressStart = Date()
                        } else {
                            let quick = (pressStart.map { Date().timeIntervalSince($0) } ?? 1) < 0.35
                            pressStart = nil
                            if talk.isHolding {
                                talk.earReleased()
                            } else if quick {
                                talk.isBusy ? talk.cancel() : phone.interact(.pet)
                            }
                        }
                    }
                    .accessibilityLabel("\(phone.world.settings.petName). Tap to pet, press and hold to talk.")
            }
        }
    }

    /// Mochi's pose while talking: it turns to listen where it stands, then nods, waits and answers.
    static func pose(_ pose: PetPose, phase: TalkModel.Phase, elapsed: Double, time: Double) -> PetPose {
        let context = PoseContext(time: time, reducedMotion: false, intensity: .normal, seed: 7)
        var pose = pose
        switch phase {
        case .approaching, .listening:
            pose = ListeningPose.pose(elapsed: elapsed, listening: phase == .listening, time: time)
        case .sending:
            pose = PetPoseEvaluator.pose(.nod, elapsed: min(elapsed, 0.9), duration: 1.0, context: context)
            pose.earPerk = 0.8
        case .waiting:
            pose = PetPoseEvaluator.pose(.lookAround, elapsed: elapsed.truncatingRemainder(dividingBy: 2.6), context: context)
            pose.earPerk = 0.7
        case .replied:
            if elapsed < 1 {
                pose = PetPoseEvaluator.pose(.happyBounce, elapsed: elapsed, duration: 1, context: context)
            } else {
                pose.eyes = .happy
                pose.mouth = .smile
                pose.blush = 0.85
            }
        case .failed:
            pose = PetPoseEvaluator.pose(.concerned, elapsed: min(elapsed, 2.2), context: context)
        case .idle:
            break
        }
        return pose
    }

    /// Sound arriving at Mochi's listening ear.
    static func drawSoundWaves(in context: GraphicsContext, layout: SceneLayout, time: Double, appear: Double) {
        let ear = CGPoint(x: layout.petHome - 20 * layout.scale, y: layout.ground - 55 * layout.scale)
        for index in 0..<3 {
            let phase = (time * 0.85 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let radius = (10 + CGFloat(1 - phase) * 30) * layout.scale
            var arc = Path()
            arc.addArc(center: ear, radius: radius, startAngle: .degrees(148), endAngle: .degrees(212), clockwise: false)
            context.stroke(arc, with: .color(MochiStyle.accent.opacity(0.6 * sin(.pi * phase) * appear)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }
}
