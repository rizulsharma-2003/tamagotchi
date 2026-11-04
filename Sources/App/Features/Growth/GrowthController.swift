import AppKit
import TamagotchiCore

/// Keeps Mochi's drawn life stage in step with the friendship, and celebrates each new stage.
@MainActor
final class GrowthController {
    private unowned let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }
    private var timer: Timer?
    /// Development override from the debug request "grow:<stage>".
    private var forced: LifeStage?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func start() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        environment.debug.register("grow") { [weak self] argument in
            self?.forced = LifeStage.allCases.first { $0.title.lowercased().hasPrefix(argument.lowercased()) }
            self?.update()
        }
        update()
    }

    var stage: LifeStage {
        if let forced { return forced }
        guard world.settings.lifeStages else { return .grownUp }
        return LifeStage.stage(for: world.progress, now: Date())
    }

    func update() {
        let stage = self.stage
        PetRenderer.stage = stage
        guard world.settings.lifeStages, forced == nil else { return }
        let seen = world.settings.lifeStageSeen
        guard stage.rawValue > seen else { return }
        world.settings.lifeStageSeen = stage.rawValue
        let name = world.settings.petName
        if seen < 0 {
            // The first look: introduce the kitten; anything later is already at home.
            if stage == .kitten {
                world.showToast(title: "Meet kitten \(name)!", detail: "\(name) grows up as your friendship grows.", seconds: 8)
            }
            return
        }
        let detail = stage == .young ? "\(name) is a young cat now." : "\(name) is all grown up, and still your best friend."
        world.showToast(title: "\(name) grew up!", detail: detail, seconds: 8)
        world.playPet(.victory)
        world.say(stage == .young ? "Look how big I am!" : "All grown up! ✨")
    }
}
