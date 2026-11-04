import AppKit
import TamagotchiCore

/// Press and hold on Mochi to pet it: it keeps purring, and a Force Touch trackpad purrs
/// along in soft bursts ("prrr… prrr…"). Haptics only play while a finger presses the trackpad.
@MainActor
final class PurrSession {
    static let shared = PurrSession()

    private var timer: Timer?
    private var startedAt = Date()
    private var lastPetAt = Date()
    private weak var world: CompanionWorld?

    var isPurring: Bool { timer != nil }

    func begin(world: CompanionWorld) {
        guard timer == nil else { return }
        self.world = world
        startedAt = Date()
        lastPetAt = startedAt
        world.interact(.pet)
        let timer = Timer(timeInterval: 0.065, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        timer?.invalidate()
        timer = nil
        world = nil
    }

    private func step() {
        guard let world else { return end() }
        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        // Bursts of about five soft taps, a breath apart.
        if world.settings.hapticPurr, elapsed.truncatingRemainder(dividingBy: 0.9) < 0.32 {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        if now.timeIntervalSince(lastPetAt) > 3 {
            lastPetAt = now
            world.interact(.pet)
        }
        // Nobody pets for half a minute without moving; stop rather than buzz forever.
        if elapsed > 30 { end() }
    }
}
