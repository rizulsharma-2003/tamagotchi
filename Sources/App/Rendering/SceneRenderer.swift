import SwiftUI
import TamagotchiCore

/// Everything needed to draw one frame, captured from the world so the per-frame
/// Canvas never reads observable state directly.
struct SceneSnapshot {
    var pet: CharacterAnimator<PetAnimation>.Playing
    /// The loop the pet returns to after a one-shot, so endings settle onto it without a jump.
    var petBase: PetAnimation
    var companion: CharacterAnimator<CompanionAnimation>.Playing
    var companionPresent: Bool
    var interaction: InteractionPlayback?
    var detail: CompanionDetail
    var petColor: PetColor
    var petAccessory: Accessory?
    var companionAccessory: Accessory?
    var deskAccessory: Accessory?
    var theme: OfficeTheme
    var reducedMotion: Bool
    var intensity: AnimationIntensity
    var seed: UInt64
    var room: RoomLayout
    var season: SeasonalEvent?
    /// Mochi is out exploring the desktop.
    var petAway: Bool

    @MainActor
    init(world: CompanionWorld) {
        pet = world.pet.current
        petBase = world.pet.base
        companion = world.companion.current
        companionPresent = world.companionPresent
        interaction = world.interaction
        detail = world.companionDetail
        let settings = world.settings
        let season = SeasonDecor.currentEvent(world: world)
        self.season = season
        petColor = settings.petColor
        petAccessory = settings.petAccessory ?? SeasonDecor.costume(for: season, wearer: .pet)
        companionAccessory = settings.companionAccessory ?? SeasonDecor.costume(for: season, wearer: .companion)
        deskAccessory = settings.deskAccessory
        theme = settings.theme
        reducedMotion = world.reducedMotion
        intensity = settings.animationIntensity
        seed = world.seed
        room = settings.room
        petAway = world.adventureActive
    }
}

struct SceneLayout {
    var size: CGSize
    var ground: CGFloat
    var petHome: CGFloat
    var companionHome: CGFloat
    var scale: CGFloat
    var background: Bool
    /// Draw the workstation even when the companion is away.
    var emptyDesk: Bool

    var path: CGFloat { companionHome - petHome }

    static func popover(width: CGFloat, height: CGFloat) -> SceneLayout {
        SceneLayout(size: CGSize(width: width, height: height), ground: height - 24, petHome: width * 0.27,
                    companionHome: width * 0.69, scale: min(1.12, height / 158), background: true, emptyDesk: true)
    }

    static func desktop(height: CGFloat, withCompanion: Bool) -> SceneLayout {
        let scale = height / 100
        return SceneLayout(size: CGSize(width: height * 2.3, height: height), ground: height - 6 * scale, petHome: height * 0.42,
                           companionHome: height * 1.55, scale: scale, background: false, emptyDesk: false)
    }

    var petFrame: CGRect {
        CGRect(x: petHome - 34 * scale, y: ground - 62 * scale, width: 68 * scale, height: 64 * scale)
    }

    var companionFrame: CGRect {
        CGRect(x: companionHome + (CompanionRenderer.homeX - 32) * scale, y: ground - 74 * scale, width: 64 * scale, height: 54 * scale)
    }
}

enum SceneRenderer {
    struct Poses {
        var pet: PetPose
        var companion: CompanionPose
        var props: [SceneProp]
        var companionVisible: Bool
    }

    static func poses(_ snapshot: SceneSnapshot, time: TimeInterval) -> Poses {
        let petContext = PoseContext(time: time, reducedMotion: snapshot.reducedMotion, intensity: snapshot.intensity, seed: snapshot.seed)
        let companionContext = PoseContext(time: time, reducedMotion: snapshot.reducedMotion, intensity: snapshot.intensity, seed: snapshot.seed &+ 0x5EED)
        if let playback = snapshot.interaction,
           snapshot.pet.scriptID == playback.id.rawValue || snapshot.companion.scriptID == playback.id.rawValue {
            let frame = InteractionLibrary.frame(playback, elapsed: time - playback.startedAt, petContext: petContext,
                                                 companionContext: companionContext, detail: snapshot.detail)
            var pet = frame.pet
            var companion = frame.companion
            // A side that was interrupted plays its own animation, not the script.
            if snapshot.pet.scriptID != playback.id.rawValue { pet = singlePet(snapshot, time: time, context: petContext) }
            if snapshot.companion.scriptID != playback.id.rawValue { companion = singleCompanion(snapshot, time: time, context: companionContext) }
            return Poses(pet: pet, companion: companion, props: frame.props, companionVisible: snapshot.companionPresent)
        }
        return Poses(pet: singlePet(snapshot, time: time, context: petContext),
                     companion: singleCompanion(snapshot, time: time, context: companionContext),
                     props: [], companionVisible: snapshot.companionPresent)
    }

    static func singlePet(_ snapshot: SceneSnapshot, time: TimeInterval, context: PoseContext) -> PetPose {
        let animation = snapshot.pet.animation == .scripted ? .idle : snapshot.pet.animation
        var context = context
        context.returnLoop = snapshot.petBase
        return PetPoseEvaluator.pose(animation, elapsed: snapshot.pet.elapsed(at: time), duration: snapshot.pet.duration, context: context)
    }

    static func singleCompanion(_ snapshot: SceneSnapshot, time: TimeInterval, context: PoseContext) -> CompanionPose {
        let animation = snapshot.companion.animation == .scripted ? .idleAtDesk : snapshot.companion.animation
        return CompanionPoseEvaluator.pose(animation, elapsed: snapshot.companion.elapsed(at: time), duration: snapshot.companion.duration,
                                           context: context, detail: snapshot.detail)
    }

    /// `petOverride` lets a host adjust Mochi's pose for this frame (the iPhone's listening twirl).
    static func draw(_ snapshot: SceneSnapshot, layout: SceneLayout, in g: GraphicsContext, time: TimeInterval, dark: Bool, hour: Int,
                     showCompanion: Bool = true, petOverride: ((PetPose) -> PetPose)? = nil) {
        let poses = poses(snapshot, time: time)
        if layout.background {
            ThemeRenderer.background(snapshot.theme, in: g, size: layout.size, ground: layout.ground, dark: dark, time: time, hour: hour)
            SeasonDecor.drawRoom(snapshot.season, in: g, layout: layout, dark: dark, time: time)
            RoomDecor.draw(snapshot.room, in: g, layout: layout, dark: dark, time: time)
        }

        let companionVisible = showCompanion && poses.companionVisible && snapshot.companion.animation != .absent
        if companionVisible || layout.emptyDesk {
            var companion = poses.companion
            if !companionVisible {
                companion.opacity = 0
                companion.laptop.openness = 0.04
                companion.laptop.screen = .off
                companion.effects = []
                companion.held = nil
            }
            var speed: CGFloat = 0
            if companionVisible, snapshot.interaction != nil {
                // Only scripts move the mascot: its speed (for stepping legs) from a moment ago.
                let earlier = SceneRenderer.poses(snapshot, time: time - 0.06).companion
                speed = CGFloat(companion.x - earlier.x) * layout.path / 0.06
            }
            CompanionRenderer.draw(companion, in: g, at: CGPoint(x: layout.companionHome, y: layout.ground),
                                   offsetX: CGFloat(companion.x) * layout.path, scale: layout.scale,
                                   accessory: snapshot.companionAccessory, dark: dark, time: time, speed: speed,
                                   reduced: snapshot.reducedMotion) { desk in
                ThemeRenderer.deskFront(snapshot.theme, in: desk, dark: dark, accessory: snapshot.deskAccessory)
            }
            if companionVisible, snapshot.detail.subagents > 0 {
                let home = layout.companionHome + (CompanionRenderer.homeX + CGFloat(companion.x) * layout.path / layout.scale) * layout.scale
                drawHelpers(count: snapshot.detail.subagents, around: CGPoint(x: home, y: layout.ground + CompanionRenderer.deskTop * layout.scale),
                            scale: layout.scale, time: time, reduced: snapshot.reducedMotion, in: g)
            }
        }

        let pet = petOverride.map { $0(poses.pet) } ?? poses.pet
        if !snapshot.petAway {
            PetRenderer.draw(pet, in: g, at: CGPoint(x: layout.petHome + CGFloat(pet.x) * layout.path, y: layout.ground),
                             scale: layout.scale, palette: PetPalette(snapshot.petColor), accessory: snapshot.petAccessory, dark: dark)
        }

        for prop in poses.props {
            let point = CGPoint(x: layout.petHome + CGFloat(prop.x) * layout.path, y: layout.ground - CGFloat(prop.y) * PetRenderer.bodyHeight * layout.scale)
            EffectRenderer.drawProp(prop, in: g, at: point, scale: layout.scale, dark: dark)
        }
        SeasonDecor.drawForeground(snapshot.season, in: g, layout: layout, dark: dark, time: time, reduced: snapshot.reducedMotion)
    }

    /// Subagents are tiny mascots hopping around the big one, each on its own beat.
    static func drawHelpers(count: Int, around origin: CGPoint, scale: CGFloat, time: TimeInterval, reduced: Bool, in g: GraphicsContext) {
        for index in 0..<min(3, count) {
            let beat = reduced ? 0 : time * 2.2 + Double(index) * 1.3
            let hop = reduced ? 0 : CGFloat(Ease.hop(Ease.fract(beat))) * 5
            let x = origin.x + CGFloat(index - 1) * 17 * scale - 30 * scale
            var pose = CompanionPose()
            pose.eyeOpenness = Ease.blink(time + Double(index) * 1.7, seed: UInt64(index + 3), period: 3.9)
            pose.eyes = Ease.fract(beat) < 0.5 ? .normal : .happy
            pose.leftArm = index == 1 ? 0.8 : 0
            pose.rightArm = index == 1 ? 0 : 0.8
            var options = PixelMascot.Options()
            options.showsSpark = false
            options.reduced = reduced
            PixelMascot.draw(pose, in: g, feet: CGPoint(x: x, y: origin.y - (50 + hop) * scale), pixel: 0.95 * scale, time: time, options: options)
        }
    }
}
