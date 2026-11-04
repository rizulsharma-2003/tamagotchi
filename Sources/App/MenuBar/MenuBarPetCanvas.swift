import SwiftUI
import TamagotchiCore

// MARK: - Snapshot

/// World state the menu-bar stage needs, captured on state changes (never per frame).
struct MenuBarSnapshot {
    var roamer: MenuBarRoamer
    var pet: CharacterAnimator<PetAnimation>.Playing
    /// The loop the pet returns to after a one-shot, so endings settle onto it without a jump.
    var petBase: PetAnimation
    var companion: CharacterAnimator<CompanionAnimation>.Playing
    var companionBase: CompanionAnimation
    var companionPresent: Bool
    var interaction: InteractionPlayback?
    var detail: CompanionDetail
    var petColor: PetColor
    var petAccessory: Accessory?
    var companionAccessory: Accessory?
    var reducedMotion: Bool
    var intensity: AnimationIntensity
    var seed: UInt64
    var status: MenuBarStatus
    var burst: CelebrationBurst?
    var season: SeasonalEvent?

    @MainActor
    init(world: CompanionWorld) {
        roamer = world.roamer
        pet = world.pet.current
        petBase = world.pet.base
        companion = world.companion.current
        companionBase = world.companion.base
        companionPresent = world.companionPresent
        interaction = world.interaction
        detail = world.companionDetail
        let settings = world.settings
        let season = SeasonDecor.currentEvent(world: world)
        self.season = season
        petColor = settings.petColor
        petAccessory = settings.petAccessory ?? SeasonDecor.costume(for: season, wearer: .pet)
        companionAccessory = settings.companionAccessory ?? SeasonDecor.costume(for: season, wearer: .companion)
        reducedMotion = world.reducedMotion
        intensity = settings.animationIntensity
        seed = world.seed
        status = world.menuBarStatus
        burst = world.burst
    }

    init(roamer: MenuBarRoamer, pet: CharacterAnimator<PetAnimation>.Playing, companion: CharacterAnimator<CompanionAnimation>.Playing,
         companionPresent: Bool, interaction: InteractionPlayback? = nil, status: MenuBarStatus, burst: CelebrationBurst? = nil,
         petColor: PetColor = .cream, reducedMotion: Bool = false, seed: UInt64 = 7) {
        self.roamer = roamer
        self.pet = pet
        self.petBase = .idle
        self.companion = companion
        self.companionBase = companion.animation
        self.companionPresent = companionPresent
        self.interaction = interaction
        self.detail = CompanionDetail()
        self.petColor = petColor
        self.petAccessory = nil
        self.companionAccessory = nil
        self.reducedMotion = reducedMotion
        self.intensity = .normal
        self.seed = seed
        self.status = status
        self.burst = burst
    }

    /// Whether the pet's own one-shot (a reaction, a user action or an ambient fidget) is playing.
    func petOneShotActive(at time: TimeInterval) -> Bool {
        guard let duration = pet.duration else { return false }
        return time < pet.startedAt + duration
    }

    func interactionActive(at time: TimeInterval) -> Bool {
        guard let playback = interaction else { return false }
        guard pet.scriptID == playback.id.rawValue || companion.scriptID == playback.id.rawValue else { return false }
        return !playback.isFinished(at: time)
    }
}

// MARK: - Layout

/// Geometry of one menu-bar stage in its own points (origin top-left, y down).
struct MenuBarLayout: Equatable {
    /// The drawing surface: the overlay band, or the status item in `.stage` style.
    var size: CGSize
    /// The roamer works in screen points (overlay) or item points (stage): x of the surface's left edge.
    var originX: Double
    /// y of Mochi's feet.
    var baseline: CGFloat
    var petScale: CGFloat
    var patchScale: CGFloat
    var homeX: CGFloat
    var companionX: CGFloat
    /// The status item (home slot), local.
    var slot: CGRect
    /// True when everything lives inside the status item.
    var isStage: Bool
    /// The overlay leaves the bed to the status item's own (static) image; the stage draws it.
    var drawsBed: Bool

    var petWidth: CGFloat { PetRenderer.bodyWidth * petScale }
    var petHeight: CGFloat { PetRenderer.bodyHeight * petScale }
    /// Toys and bed are sized for the roomy bar and shrink with the pet on smaller stages.
    var toyScale: CGFloat { petScale / 0.28 }

    func local(_ x: Double) -> CGFloat { CGFloat(x - originX) }

    /// The mascot faces left (towards the pet) as authored; on the bar it sits left of the bed, so it is mirrored.
    var patchMirrored: Bool { companionX < homeX }
    /// Points per art pixel of the mini mascot: whole points on a roomy bar keep it crisp.
    var mascotPixel: CGFloat { patchScale >= 0.19 ? 1 : 0.75 }

    /// Bed, Patch, celebration and badge.
    var homeRect: CGRect {
        let left = min(slot.minX, companionX - 12) - 10
        let right = max(slot.maxX, homeX + 14) + 8
        return CGRect(x: left, y: 0, width: right - left, height: size.height)
    }

    static func overlay(_ geometry: MenuBarGeometry) -> MenuBarLayout {
        let frame = geometry.overlayFrame
        let height = frame.height
        let roomy = height >= 30
        let item = geometry.homeSlot
        // Local y grows down from the top of the band.
        let slot = CGRect(x: item.minX - frame.minX, y: frame.maxY - item.maxY, width: item.width, height: item.height)
        // Feet a little above the bottom of the item, so Mochi walks "on" the row of status icons.
        return MenuBarLayout(size: frame.size, originX: Double(frame.minX), baseline: slot.maxY - 3.5,
                             petScale: roomy ? 0.28 : 0.235, patchScale: roomy ? 0.2 : 0.17,
                             homeX: CGFloat(geometry.zone.homeX - Double(frame.minX)),
                             companionX: CGFloat(geometry.zone.companionX - Double(frame.minX)), slot: slot, isStage: false,
                             drawsBed: false)
    }

    static func stage(width: CGFloat, height: CGFloat = 22) -> MenuBarLayout {
        let zone = RoamGeometry.stageZone(width: Double(width))
        return MenuBarLayout(size: CGSize(width: width, height: height), originX: 0, baseline: height - 3,
                             petScale: 0.215, patchScale: 0.155, homeX: CGFloat(zone.homeX), companionX: CGFloat(zone.companionX),
                             slot: CGRect(x: 0, y: 0, width: width, height: height), isStage: true, drawsBed: true)
    }

    /// The status item's own picture in the overlay style: the empty bed, drawn exactly where the
    /// overlay would. It shows on displays the overlay is not on, and under the overlay otherwise.
    static func homeImageLayout(slotWidth: CGFloat, slotHeight: CGFloat, roomy: Bool, rightToLeft: Bool = false) -> MenuBarLayout {
        let slot = CGRect(x: 0, y: 0, width: slotWidth, height: slotHeight)
        return MenuBarLayout(size: slot.size, originX: 0, baseline: slotHeight - 3.5, petScale: roomy ? 0.28 : 0.235, patchScale: 0.2,
                             homeX: CGFloat(RoamGeometry.bedX(inSlot: slot, rightToLeft: rightToLeft)),
                             companionX: CGFloat(RoamGeometry.companionX(inSlot: slot, rightToLeft: rightToLeft)),
                             slot: slot, isStage: false, drawsBed: true)
    }
}

// MARK: - Frame

/// Everything drawn at one instant, in layout points.
struct MenuBarFrame {
    /// Mochi's pose, always facing right; `petFlipped` mirrors the drawing.
    var pet: PetPose
    var petFlipped: Bool
    /// Text-like marks ("?", "!", notes) drawn unmirrored on top.
    var petGlyphs: [Effect]
    var petX: CGFloat
    var petLift: CGFloat
    var petOpacity: Double
    var sleeping: Bool
    var props: [(prop: SceneProp, point: CGPoint)]
    var patch: CompanionPose?
    var patchOffset: CGFloat
    var badge: AttentionLevel?
    /// Seconds into a celebration burst near home.
    var celebration: Double?
    var celebrationBig: Bool
    var time: TimeInterval
    var busy: Bool
}

enum MenuBarPart {
    case home, actors, all
}

/// Draws Mochi's menu-bar life: the bed at the status item, mini Patch while a
/// session is open, Mochi in full colour wherever the roamer (or a real reaction)
/// puts it, its toys, Z's, celebration sparkles and the attention badge.
enum MenuBarPetCanvas {
    /// Body widths per unit of `PetPose.x` (scene-path units), as in the popover scene
    /// (`PetPoseEvaluator.bodyWidthsPerPathUnit`): in-place hops look the same, and props the
    /// pet animations place in world space stay put.
    static let bodyWidthsPerPathUnit = 2.25

    /// Ground speeds at which the gaits' own cadence matches the feet (points per second):
    /// a walk bobs every ~9 pt, a run bounds every ~16 pt.
    static let walkGaitSpeed = 18 * 2.2
    static let runGaitSpeed = 32 * 3.4

    // MARK: Evaluation (pure)

    static func frame(_ snapshot: MenuBarSnapshot, layout: MenuBarLayout, time: TimeInterval, pointer: CGPoint? = nil) -> MenuBarFrame {
        let petContext = PoseContext(time: time, reducedMotion: snapshot.reducedMotion, intensity: snapshot.intensity, seed: snapshot.seed)
        let companionContext = PoseContext(time: time, reducedMotion: snapshot.reducedMotion, intensity: snapshot.intensity,
                                           seed: snapshot.seed &+ 0x5EED)
        let roam = snapshot.roamer.sample(at: time)
        let x0 = layout.local(roam.x)
        var props: [(prop: SceneProp, point: CGPoint)] = []
        var pose: PetPose
        var flipped = roam.facing < 0
        var petX = x0
        let lift = CGFloat(roam.lift)
        var opacity = roam.opacity
        var patch: CompanionPose?
        var patchOffset: CGFloat = 0
        var busy = roam.isTravelling || roam.isOneShot || !roam.props.isEmpty || roam.style != .plain
        /// Points per unit of the pose's own x offset.
        var unit = CGFloat(bodyWidthsPerPathUnit) * layout.petWidth
        var usedRoamer = false

        let worldOneShot = snapshot.petOneShotActive(at: time)
            && (snapshot.pet.priority >= .reaction || (!roam.isTravelling && !roam.isOneShot && roam.props.isEmpty))
        if snapshot.interactionActive(at: time), let playback = snapshot.interaction {
            // An interaction beside Patch: script path units span the gap between Mochi and Patch, so they
            // meet with paws touching but bodies apart (a short local hop when Mochi is somehow still far away).
            let gap = layout.companionX - x0
            let side: CGFloat = gap >= 0 ? 1 : -1
            let reach = max(6, (abs(gap) - 17) / CGFloat(InteractionLibrary.meet))
            let path: CGFloat = abs(gap) > 100 ? side * 24 : side * min(abs(gap), reach)
            let frame = InteractionLibrary.frame(playback, elapsed: time - playback.startedAt, petContext: petContext,
                                                 companionContext: companionContext, detail: snapshot.detail)
            if snapshot.pet.scriptID == playback.id.rawValue {
                pose = frame.pet
                petX = x0 + CGFloat(pose.x) * path
                pose.x = 0
                // Scripts face the pet towards Patch (+1) or back home (-1) by flag only.
                let beatFacing: CGFloat = pose.facing >= 0 ? 1 : -1
                if beatFacing < 0 {
                    pose.facing = 1
                    pose.lookX = -pose.lookX
                }
                flipped = side * beatFacing < 0
            } else {
                pose = worldPose(snapshot, time: time, context: petContext)
            }
            if snapshot.companion.scriptID == playback.id.rawValue {
                patch = frame.companion
                patchOffset = CGFloat(frame.companion.x) * path
            }
            for prop in frame.props {
                props.append((prop, CGPoint(x: x0 + CGFloat(prop.x) * path, y: layout.baseline - CGFloat(prop.y) * layout.petHeight)))
            }
            unit = 0
            opacity = 1
            busy = true
        } else if worldOneShot, !roam.activity.overridesWorldPose {
            // A real reaction (travel is frozen, on the bed cushion if that is where Mochi was) or an
            // ambient fidget the world started during a rest.
            pose = worldPose(snapshot, time: time, context: petContext)
            busy = true
        } else {
            usedRoamer = true
            pose = roamerPose(roam, context: petContext)
            if let held = roam.held { pose.held = held }
            accent(&pose, roam: roam, time: time, reduced: snapshot.reducedMotion)
            MenuBarLife.enliven(&pose, roam: roam, time: time, seed: snapshot.seed, reduced: snapshot.reducedMotion)
            if let pointer, layout.isStage == false {
                MenuBarLife.follow(&pose, pointer: pointer, petX: x0, layout: layout, flipped: flipped, roam: roam)
            }
            if roam.activity == .lookUp {
                pose.lookX = 0.1
                pose.lookY = -0.25
                pose.earPerk = max(pose.earPerk, 0.45)
            }
            for prop in roam.props {
                let scene = SceneProp(prop.kind, x: 0, y: 0, scale: prop.scale, opacity: prop.opacity, rotation: prop.rotation, variant: prop.variant)
                props.append((scene, CGPoint(x: layout.local(prop.x), y: layout.baseline - CGFloat(prop.y) * layout.toyScale)))
            }
            props += footDust(roam, petX: x0, layout: layout, reduced: snapshot.reducedMotion)
        }
        // Small in-place offsets of one-shots (a pounce forward, a roll), in the pose's facing.
        petX += CGFloat(pose.x) * unit * (flipped ? -1 : 1)
        pose.x = 0
        let markedAsleep = (pose.eyes == .closed || pose.eyes == .sleepy) && pose.effects.contains { $0.kind == .z }
        let roamAsleep = usedRoamer && (roam.animation == .sleep || roam.animation == .curl)
        let sleeping = markedAsleep || roamAsleep
        pose.effects = tidyEffects(pose.effects, pose: pose, layout: layout)
        var glyphs: [Effect] = []
        if flipped {
            // Text can't be mirrored: those marks are drawn on their own, the right way round.
            glyphs = pose.effects.filter { isGlyph($0.kind) }
            pose.effects.removeAll { isGlyph($0.kind) }
        }

        // Mini Patch at home.
        if patch == nil, snapshot.companionPresent || snapshot.companion.animation == .depart,
           snapshot.companion.animation != .absent {
            let animation = snapshot.companion.animation == .scripted ? snapshot.companionBase : snapshot.companion.animation
            if animation != .absent {
                var p = CompanionPoseEvaluator.pose(animation, elapsed: snapshot.companion.elapsed(at: time),
                                                    duration: snapshot.companion.duration, context: companionContext, detail: snapshot.detail)
                if snapshot.companion.duration != nil { busy = true }
                if !snapshot.status.companionWorking {
                    // Idle at home: he keeps half an eye on Mochi (scene left = towards the pet).
                    p.lookX = -(abs(p.lookX) * 0.6 + 0.25)
                }
                patch = p
            }
        }
        if var p = patch {
            p.laptop.screen = p.laptop.screen == .off ? .off : .idle
            p.effects = p.effects.compactMap { effect in
                switch effect.kind {
                case .z, .sparkle, .heart, .star, .confetti, .exclamation, .question, .note, .sweat:
                    var e = effect
                    e.scale *= 1.35
                    e.y = min(e.y, 1.55)
                    return e
                default:
                    return nil
                }
            }
            if snapshot.status.companionWorking {
                // Claude Code's spinner over its head is the honest "Claude is working" signal at home.
                p.antennaGlow = 0.9
                p.antennaTint = .working
            }
            patch = p
        }

        var celebration: Double?
        if let burst = snapshot.burst, time - burst.startedAt < 2.6, time >= burst.startedAt {
            celebration = time - burst.startedAt
            busy = true
        }
        return MenuBarFrame(pet: pose, petFlipped: flipped, petGlyphs: glyphs, petX: petX, petLift: lift, petOpacity: opacity,
                            sleeping: sleeping, props: props, patch: patch, patchOffset: patchOffset, badge: snapshot.status.badge,
                            celebration: celebration, celebrationBig: snapshot.burst?.big ?? false, time: time, busy: busy)
    }

    static func worldPose(_ snapshot: MenuBarSnapshot, time: TimeInterval, context: PoseContext) -> PetPose {
        let animation = snapshot.pet.animation == .scripted ? .idle : snapshot.pet.animation
        var context = context
        context.returnLoop = snapshot.petBase
        return PetPoseEvaluator.pose(animation, elapsed: snapshot.pet.elapsed(at: time), duration: snapshot.pet.duration, context: context)
    }

    /// The roamer's pose. Gaits run on Mochi's odometer instead of the clock, so each step
    /// lands where the feet are (no skating), with a bolder bob and lean at menu-bar size.
    static func roamerPose(_ roam: RoamSample, context: PoseContext) -> PetPose {
        var gaitContext = context
        let gait: Bool
        switch roam.animation {
        case .walk, .carry:
            gaitContext.time = roam.odometer / walkGaitSpeed
            gait = true
        case .run:
            gaitContext.time = roam.odometer / runGaitSpeed
            gait = true
        default:
            gait = false
        }
        var pose = PetPoseEvaluator.pose(roam.animation, elapsed: roam.elapsed, duration: roam.duration, context: gait ? gaitContext : context)
        if gait, !context.reducedMotion {
            let running = roam.animation == .run
            pose.y *= 1.5
            pose.step *= 1.25
            pose.rotation += running ? 0.1 : 0.055
            if running, roam.speed > 95 {
                // A one-frame smear at top speed.
                let s = Ease.clamp((roam.speed - 95) / 30)
                pose.scaleX *= 1 + 0.12 * s
                pose.scaleY *= 1 - 0.04 * s
            }
            // A walk that is really a brake (out of a run) slows the legs with it.
            if roam.style == .skid { pose.step *= 0.5 }
        }
        return pose
    }

    /// The renderer's half of the roamer's body language (crouches, skids, landings, ears up).
    static func accent(_ pose: inout PetPose, roam: RoamSample, time: TimeInterval, reduced: Bool) {
        let p = roam.progress
        let m = reduced ? 0.0 : 1.0
        switch roam.style {
        case .plain:
            break
        case .crouch:
            let amount = Ease.smooth(Ease.segment(p, 0, 0.6)) * m
            pose.scaleY *= 1 - 0.1 * amount
            pose.scaleX *= 1 + 0.06 * amount
            pose.earPerk = min(pose.earPerk, -0.2)
            pose.lookX = 0.85
        case .launch:
            let push = max(0, 1 - roam.elapsed / 0.14) * m
            pose.scaleY *= 1 + 0.08 * push
            pose.scaleX *= 1 - 0.05 * push
        case .skid:
            let lean = Ease.bump(p, 0, 1.0) * m
            pose.rotation -= 0.14 * lean
            pose.scaleY *= 1 - 0.05 * lean
            pose.earPerk = max(pose.earPerk, 0.5)
            pose.eyes = .wide
        case .drop:
            pose.scaleY *= 1 + 0.07 * m
            pose.scaleX *= 1 - 0.05 * m
            pose.leftArm = max(pose.leftArm, 0.55)
            pose.rightArm = max(pose.rightArm, 0.55)
            pose.earPerk = 0.9
            pose.eyes = .wide
        case .land:
            let squash = pow(1 - p, 1.5) * m
            pose.scaleY *= 1 - 0.14 * squash
            pose.scaleX *= 1 + 0.1 * squash
        case .notice:
            pose.earPerk = max(pose.earPerk, 0.85)
            pose.lookX = 0.85
            pose.lookY = -0.05
            pose.brows = .raised
            if p < 0.6 { pose.eyes = .wide }
            pose.tilt += 0.06 * Ease.bump(p, 0, 1) * m
        case .attentive:
            pose.lookX = 0.02
            pose.lookY = -0.12
            pose.earPerk = max(pose.earPerk, 0.4)
            if pose.eyes == .happy { pose.eyes = .open }
        case .munch:
            let phase = 2 * Double.pi * 2.6 * roam.elapsed
            pose.mouth = sin(phase) > 0 ? .nom : .cat
            pose.scaleY *= 1 - 0.025 * abs(sin(phase)) * m
            pose.scaleX *= 1 + 0.015 * abs(sin(phase)) * m
            pose.blush = max(pose.blush, 0.65)
            pose.earPerk = max(pose.earPerk, 0.3)
            pose.leftArm = max(pose.leftArm, 0.45)
            pose.rightArm = max(pose.rightArm, 0.45)
            if pose.eyes == .open, Ease.fract(roam.elapsed / 1.3) > 0.55 { pose.eyes = .happy }
        }
    }

    /// Little dust puffs at the feet when skidding or landing.
    static func footDust(_ roam: RoamSample, petX: CGFloat, layout: MenuBarLayout, reduced: Bool) -> [(prop: SceneProp, point: CGPoint)] {
        guard !reduced, roam.style == .skid || roam.style == .land else { return [] }
        let behind: CGFloat = roam.facing >= 0 ? -1 : 1
        let life = roam.style == .skid ? Ease.bump(roam.progress, 0, 1) : 1 - roam.progress
        guard life > 0.05 else { return [] }
        let y = layout.baseline - 1.2 * layout.toyScale
        var puffs = [(SceneProp(.dust, x: 0, y: 0, scale: 0.9 + 0.4 * (1 - life), opacity: 0.75 * life),
                      CGPoint(x: petX + behind * layout.petWidth * 0.45, y: y))]
        if roam.style == .land {
            puffs.append((SceneProp(.dust, x: 0, y: 0, scale: 0.9 + 0.4 * (1 - life), opacity: 0.75 * life, variant: 1),
                          CGPoint(x: petX - behind * layout.petWidth * 0.45, y: y)))
        }
        return puffs
    }

    static func isGlyph(_ kind: EffectKind) -> Bool {
        switch kind {
        case .question, .exclamation, .note, .z, .speechDots, .speechLock, .speechQuestion, .plug, .thinkingDots: return true
        default: return false
        }
    }

    /// Effects legible at 16 pt and kept inside the menu-bar band; Z's are drawn separately.
    static func tidyEffects(_ effects: [Effect], pose: PetPose, layout: MenuBarLayout) -> [Effect] {
        let ceiling = Double((layout.baseline - 3) / layout.petHeight) - pose.y
        return effects.compactMap { effect in
            var e = effect
            switch effect.kind {
            case .z: return nil
            case .heart, .sparkle, .star, .note, .question, .exclamation, .sweat, .confetti:
                e.scale *= 1.35
            default:
                break
            }
            e.y = min(e.y, ceiling)
            return e
        }
    }

    // MARK: Drawing

    static func haloColor(dark: Bool) -> Color { dark ? Color.black.opacity(0.55) : Color.white.opacity(0.85) }

    /// Draws `content` with a soft ring in the bar's own tone around it, which lifts Mochi, Patch and
    /// the toys off the icons underneath (and keeps a cream Mochi crisp on a pale bar).
    static func withHalo(_ g: GraphicsContext, dark: Bool, enabled: Bool = true, _ content: (inout GraphicsContext) -> Void) {
        guard enabled else {
            var plain = g
            content(&plain)
            return
        }
        var outer = g
        let color = haloColor(dark: dark)
        outer.addFilter(.shadow(color: color, radius: 0.8))
        outer.addFilter(.shadow(color: color, radius: 0.5))
        outer.drawLayer { layer in content(&layer) }
    }

    static func draw(_ frame: MenuBarFrame, snapshot: MenuBarSnapshot, layout: MenuBarLayout, part: MenuBarPart,
                     in context: GraphicsContext, offset: CGPoint = .zero, dark: Bool, halo: Bool = true) {
        var g = context
        g.translateBy(x: -offset.x, y: -offset.y)
        let home = part != .actors
        let actors = part != .home
        if home {
            if layout.drawsBed {
                drawBed(in: g, center: CGPoint(x: layout.homeX, y: layout.baseline), scale: layout.toyScale, dark: dark)
            }
            SeasonDecor.drawMenuBarAccent(snapshot.season, in: g, near: CGPoint(x: layout.homeX, y: layout.baseline), scale: layout.toyScale, dark: dark)
            if let patch = frame.patch {
                let origin = CGPoint(x: layout.companionX, y: layout.baseline)
                withHalo(g, dark: dark, enabled: halo) { layer in
                    drawPatch(patch, mirrored: layout.patchMirrored, origin: origin, offset: frame.patchOffset, pixel: layout.mascotPixel,
                              accessory: snapshot.companionAccessory, dark: dark, time: frame.time, reduced: snapshot.reducedMotion, in: layer)
                }
            }
        }
        if actors {
            withHalo(g, dark: dark, enabled: halo) { layer in
                for (prop, point) in frame.props where prop.kind != .dust {
                    EffectRenderer.drawProp(prop, in: layer, at: point, scale: layout.petScale, dark: dark)
                }
                var petContext = layer
                petContext.opacity = frame.petOpacity
                let feet = CGPoint(x: frame.petX, y: layout.baseline - frame.petLift)
                if frame.petFlipped {
                    petContext.translateBy(x: feet.x, y: 0)
                    petContext.scaleBy(x: -1, y: 1)
                    petContext.translateBy(x: -feet.x, y: 0)
                }
                PetRenderer.draw(frame.pet, in: petContext, at: feet, scale: layout.petScale,
                                 palette: PetPalette(snapshot.petColor), accessory: snapshot.petAccessory, dark: dark, detail: .tiny)
            }
            for (prop, point) in frame.props where prop.kind == .dust {
                EffectRenderer.drawProp(prop, in: g, at: point, scale: layout.petScale, dark: dark)
            }
            if !frame.petGlyphs.isEmpty {
                var marks = g
                marks.opacity = frame.petOpacity
                marks.translateBy(x: frame.petX, y: layout.baseline - frame.petLift)
                marks.scaleBy(x: layout.petScale, y: layout.petScale)
                marks.translateBy(x: 0, y: -CGFloat(frame.pet.y) * PetRenderer.bodyHeight)
                for glyph in frame.petGlyphs {
                    var e = glyph
                    e.x = -e.x
                    e.rotation = -e.rotation
                    EffectRenderer.draw(e, in: marks, unitX: PetRenderer.bodyWidth, unitY: PetRenderer.bodyHeight, dark: dark)
                }
            }
            if frame.sleeping {
                let side: CGFloat = frame.petFlipped ? -1 : 1
                let head = CGPoint(x: frame.petX, y: layout.baseline - frame.petLift - layout.petHeight * 0.8)
                drawZs(time: frame.time, from: head, side: side, layout: layout, dark: dark, reduced: snapshot.reducedMotion, in: g)
            }
        }
        if home {
            if let elapsed = frame.celebration {
                drawCelebration(elapsed, big: frame.celebrationBig, around: CGPoint(x: (layout.homeX + layout.companionX) / 2, y: layout.baseline),
                                layout: layout, reduced: snapshot.reducedMotion, in: g)
            }
            if let badge = frame.badge {
                drawBadge(badge, at: badgePoint(layout), dark: dark, in: g)
            }
        }
    }

    static func badgePoint(_ layout: MenuBarLayout) -> CGPoint {
        CGPoint(x: layout.slot.maxX - 3.5, y: max(3.6, layout.slot.minY + 3.2))
    }

    /// The mascot standing on the bar, mirrored when it sits left of Mochi (scripts are authored
    /// with the pet on its left). Text-like marks are drawn unmirrored on top.
    static func drawPatch(_ patch: CompanionPose, mirrored: Bool, origin: CGPoint, offset: CGFloat, pixel: CGFloat, accessory: Accessory?,
                          dark: Bool, time: TimeInterval, reduced: Bool, in g: GraphicsContext) {
        var pose = patch
        let glyphs = mirrored ? pose.effects.filter { isGlyph($0.kind) } : []
        if mirrored { pose.effects.removeAll { isGlyph($0.kind) } }
        let feet = CGPoint(x: origin.x + offset, y: origin.y)
        var body = g
        if mirrored {
            body.translateBy(x: feet.x, y: 0)
            body.scaleBy(x: -1, y: 1)
            body.translateBy(x: -feet.x, y: 0)
        }
        var options = PixelMascot.Options()
        options.accessory = accessory
        options.reduced = reduced
        options.snap = 0.5 / pixel
        // No floor shadow on the bar: it would read as a smudge.
        options.shadow = false
        options.headroom = feet.y / pixel - PixelMascot.bodyRows - PixelMascot.legRows
        PixelMascot.draw(pose, in: body, feet: feet, pixel: pixel, time: time, options: options)
        // Marks are authored around a floor 22.5 units below the mascot's desk.
        let local = pixel / CompanionRenderer.pixel
        func marks(_ effects: [Effect], in context: GraphicsContext, flip: Bool) {
            guard !effects.isEmpty, pose.opacity > 0.01 else { return }
            var m = context
            m.opacity = pose.opacity
            m.translateBy(x: feet.x, y: feet.y)
            m.scaleBy(x: local, y: local)
            m.translateBy(x: 0, y: -CGFloat(pose.y) * CompanionRenderer.unit - CompanionRenderer.deskTop)
            for effect in effects {
                var e = effect
                if flip {
                    e.x = -e.x
                    e.rotation = -e.rotation
                }
                EffectRenderer.draw(e, in: m, unitX: 60, unitY: CompanionRenderer.unit, dark: dark)
            }
        }
        marks(pose.effects, in: body, flip: false)
        marks(glyphs, in: g, flip: true)
    }

    /// A small round cushion with a rim: Mochi's bed at the status item.
    static func drawBed(in g: GraphicsContext, center: CGPoint, scale: CGFloat, dark: Bool) {
        var bed = g
        bed.translateBy(x: center.x, y: center.y)
        bed.scaleBy(x: scale, y: scale)
        let rimColor = Color(hex: 0xC97B8E)
        let cushion = Color(hex: 0xF4B3C2)
        let seat = Color(hex: 0xFFDCE5)
        // Soft contact shadow.
        bed.fill(.ellipse(CGPoint(x: 0, y: 0.6), 23, 3.2), Color.black.opacity(dark ? 0.35 : 0.14))
        // The rim (a puffy ring seen from the side).
        let rim = Path.roundedRect(CGRect(x: -11.5, y: -6.2, width: 23, height: 6.6), 3.3)
        bed.fill(rim, cushion)
        bed.stroke(rim, rimColor, 0.9)
        // The seat inside, lighter.
        bed.fill(.ellipse(CGPoint(x: 0, y: -5.3), 17.5, 3.4), seat)
        bed.stroke(.ellipse(CGPoint(x: 0, y: -5.3), 17.5, 3.4), rimColor.opacity(0.55), 0.6)
        // Knitted stitches along the front.
        for index in 0..<4 {
            let x = -6.6 + CGFloat(index) * 4.4
            var stitch = Path()
            stitch.move(to: CGPoint(x: x - 1, y: -2.7))
            stitch.addQuadCurve(to: CGPoint(x: x + 1, y: -2.7), control: CGPoint(x: x, y: -1.6))
            bed.stroke(stitch, Color.white.opacity(0.75), 0.6)
        }
        bed.fill(.ellipse(CGPoint(x: -6.5, y: -4.4), 4, 1.1), Color.white.opacity(0.5))
    }

    static func drawZs(time: TimeInterval, from head: CGPoint, side: CGFloat, layout: MenuBarLayout, dark: Bool, reduced: Bool,
                       in g: GraphicsContext) {
        let ink = dark ? Color(hex: 0xEDE7F6) : Color(hex: 0x5E5070)
        for index in 0..<3 {
            let p = reduced ? Double(index) / 3 + 0.15 : Ease.fract(time / 2.8 + Double(index) / 3)
            let x = head.x + side * (4 + 8 * CGFloat(p))
            let y = max(3.5, head.y - 1 - 7.5 * CGFloat(p))
            let size = 4.2 + 2.8 * CGFloat(p)
            var z = g
            z.opacity = reduced ? 0.85 : sin(.pi * p)
            z.text("z", at: CGPoint(x: x, y: y), size: size, weight: .heavy, color: ink)
        }
    }

    static func drawCelebration(_ elapsed: Double, big: Bool, around center: CGPoint, layout: MenuBarLayout, reduced: Bool, in g: GraphicsContext) {
        let fade = 1 - Ease.segment(elapsed, 1.9, 2.6)
        let count = big ? 16 : 10
        let spread: CGFloat = layout.isStage ? 14 : 40
        for index in 0..<count {
            let seed: UInt64 = 0xC0FE
            let x0 = center.x + (CGFloat(Ease.hash(index, seed)) - 0.5) * 2 * spread
            let drift = CGFloat(sin(elapsed * 3 + Double(index))) * (reduced ? 0 : 1.8)
            let speed = 8 + 6 * CGFloat(Ease.hash(index + 5, seed))
            let start = 1 + 5 * CGFloat(Ease.hash(index + 9, seed))
            let y = reduced ? start + 6 : start + speed * CGFloat(elapsed)
            guard y < layout.baseline + 1 else { continue }
            var piece = g
            piece.opacity = fade
            piece.translateBy(x: x0 + drift, y: y)
            piece.rotate(by: .radians(reduced ? Double(index) : elapsed * 7 + Double(index)))
            let color = ConfettiPalette.colors[index % ConfettiPalette.colors.count]
            piece.fill(.roundedRect(CGRect(x: -1.6, y: -0.9, width: 3.2, height: 1.8), 0.5), color)
        }
        for index in 0..<3 {
            let local = elapsed - Double(index) * 0.28
            let life = Ease.bump(local, 0, 0.75)
            guard life > 0 else { continue }
            let x = center.x + CGFloat([-14.0, 12.0, 1.0][index]) * (layout.isStage ? 0.6 : 1)
            let y = layout.baseline - layout.petHeight * CGFloat([0.95, 1.1, 1.3][index])
            g.fill(.sparkle(CGPoint(x: x, y: max(3, y)), radius: 2.2 + 1.6 * CGFloat(life)), Color(hex: 0xFFD166).opacity(life))
        }
    }

    static func drawBadge(_ level: AttentionLevel, at point: CGPoint, dark: Bool, in g: GraphicsContext) {
        let color: Color
        switch level {
        case .info: color = Color(hex: 0x9A93A6)
        case .attention: color = Color(hex: 0xFF9F0A)
        case .alert: color = Color(hex: 0xFF453A)
        }
        let dot = Path.ellipse(point, 6.4, 6.4)
        g.fill(.ellipse(point, 8.2, 8.2), dark ? Color.black.opacity(0.55) : Color.white.opacity(0.92))
        g.fill(dot, color)
    }

    // MARK: Bounds and change detection

    /// The area Mochi, its effects and toys cover (layout points, full band height).
    static func actorBounds(_ frame: MenuBarFrame, layout: MenuBarLayout) -> CGRect {
        var minX = frame.petX - layout.petWidth * 0.95
        var maxX = frame.petX + layout.petWidth * 0.95
        if frame.sleeping { maxX += 14; minX -= 14 }
        for (_, point) in frame.props {
            minX = min(minX, point.x - 8)
            maxX = max(maxX, point.x + 8)
        }
        return CGRect(x: floor(minX), y: 0, width: ceil(maxX - minX) + 1, height: layout.size.height)
    }

    /// Quantized drawing state: equal signatures draw identically (to the pixel),
    /// so the stage skips re-rendering frames where nothing visibly changed.
    static func signature(_ frame: MenuBarFrame, snapshot: MenuBarSnapshot, layout: MenuBarLayout, part: MenuBarPart, origin: CGPoint,
                          dark: Bool, backingScale: CGFloat = 2) -> [Int32] {
        var s = PoseSignature(resolution: max(1, 2 / Double(max(backingScale, 0.5))))
        s.add(dark)
        s.add(Double(backingScale), 0.5)
        s.add(Double(layout.petScale), 0.001)
        s.add(Double(layout.baseline - origin.y), 0.1)
        if part != .home {
            s.add(snapshot.petColor.rawValue)
            s.add(snapshot.petAccessory?.rawValue ?? "-")
            s.add(Double(frame.petX - origin.x), 0.2)
            s.add(Double(frame.petLift), 0.2)
            s.add(frame.petOpacity, 0.04)
            s.add(frame.petFlipped)
            s.pet(frame.pet)
            s.effects(frame.petGlyphs)
            s.add(frame.sleeping)
            if frame.sleeping { s.add(frame.time, 1.0 / 12) }
            s.add(frame.props.count)
            for (prop, point) in frame.props {
                s.add(prop.kind.rawValue)
                s.add(Double(point.x - origin.x), 0.2)
                s.add(Double(point.y), 0.2)
                s.add(prop.rotation, 0.08)
                s.add(prop.opacity, 0.04)
                s.add(prop.scale, 0.02)
                s.add(prop.variant)
            }
        }
        if part != .actors {
            s.add(Double(origin.x), 0.5)
            s.add(snapshot.season?.rawValue ?? "-")
            s.add(snapshot.companionAccessory?.rawValue ?? "-")
            s.add(snapshot.status.companionWorking)
            if let patch = frame.patch {
                s.add(1)
                s.add(Double(frame.patchOffset), 0.2)
                s.companion(patch)
                s.add(PixelMascot.sparkFrame(patch, time: frame.time, reduced: snapshot.reducedMotion) ?? -1)
            } else {
                s.add(0)
            }
            s.add(frame.badge.map { $0.rawValue + 1 } ?? 0)
            if let celebration = frame.celebration { s.add(celebration, 1.0 / 24) } else { s.add(-1) }
        }
        return s.values
    }
}

// MARK: - Micro life

/// Small, constant signs of life that read at 16 pt: crisp blinks (sometimes double),
/// visible breathing, glances that turn the head, ear flicks, tail flicks and weight
/// shifts. Pure functions of time and seed, layered on calm poses only.
enum MenuBarLife {
    static let calm: Set<PetAnimation> = [.idle, .sit, .watch, .waveGently]

    static func enliven(_ pose: inout PetPose, roam: RoamSample, time: TimeInterval, seed: UInt64, reduced: Bool) {
        let animation = roam.animation
        guard calm.contains(animation), roam.speed < 0.5 else { return }
        let motion = reduced ? 0.0 : 1.0

        // Eyes open when sitting (a content ^^ squint only now and then, and just after settling).
        if animation == .sit, pose.eyes == .happy, !contentMoment(roam: roam, time: time, seed: seed) { pose.eyes = .open }

        // Crisp blinks: fully shut for 0.17 s (two frames even at 12 fps), every 1.5–7 s, a fifth of them double.
        if pose.eyes == .open || pose.eyes == .wide { pose.eyeOpenness = blink(time, seed: seed) }

        // Breathing you can see: ±3 % in a few steps (each step is a visible pixel, never a shimmer).
        let phase = Ease.hash(1, seed) * 6.28
        let breath = (sin(2 * .pi * time / 3.6 + phase) * 2).rounded() / 2
        pose.scaleY += 0.032 * breath * (reduced ? 0.5 : 1)
        pose.scaleX -= 0.016 * breath * (reduced ? 0.5 : 1)

        // An ear flick every 6–10 s (both ears swivel ~20° for a quarter of a second).
        let earPeriod = 8.0
        let earCycle = floor(time / earPeriod)
        let earAt = 1 + Ease.hash(Int(earCycle), seed &+ 11) * (earPeriod - 2)
        let earLocal = time - earCycle * earPeriod - earAt
        pose.earPerk += 1.05 * Ease.bump(earLocal, 0, 0.32) - 0.35 * Ease.bump(earLocal, 0.3, 0.52)

        // A tail flick now and then: the tip travels a couple of points.
        if !reduced {
            let tailPeriod = 7.3
            let tailCycle = floor(time / tailPeriod)
            let tailAt = Ease.hash(Int(tailCycle), seed &+ 23) * (tailPeriod - 1.6)
            let tailLocal = time - tailCycle * tailPeriod - tailAt
            pose.tailWag += 2.0 * sin(tailLocal * 9) * Ease.bump(tailLocal, 0, 1.2)
        }

        // Glances: the head turns and the eyes follow, held for a second or two, then back.
        guard animation != .waveGently else { return }
        let glancePeriod = 6.5
        let glanceCycle = floor(time / glancePeriod)
        let hold = 1.2 + 0.8 * Ease.hash(Int(glanceCycle), seed &+ 47)
        let glanceAt = Ease.hash(Int(glanceCycle), seed &+ 37) * (glancePeriod - hold - 0.6)
        let glanceLocal = time - glanceCycle * glancePeriod - glanceAt
        let strength = Ease.smooth(Ease.segment(glanceLocal, 0, 0.22)) * (1 - Ease.smooth(Ease.segment(glanceLocal, hold, hold + 0.3)))
        if strength > 0 {
            let targetX = (Ease.hash(Int(glanceCycle), seed &+ 41) - 0.5) * 1.8
            let targetY = (Ease.hash(Int(glanceCycle), seed &+ 43) - 0.6) * 0.7
            let amount = animation == .watch ? strength * 0.5 : strength
            pose.lookX = Ease.lerp(pose.lookX, targetX, amount)
            pose.lookY = Ease.lerp(pose.lookY, targetY, amount)
            pose.tilt += 0.1 * (targetX >= 0 ? 1 : -1) * amount * motion
        }

        // A weight shift every 8–15 s: a lean to one side for a few seconds.
        let shiftPeriod = 11.0
        let shiftCycle = floor(time / shiftPeriod)
        let shiftAt = Ease.hash(Int(shiftCycle), seed &+ 61) * 6
        let shiftLocal = time - shiftCycle * shiftPeriod - shiftAt
        let lean = Ease.smooth(Ease.segment(shiftLocal, 0, 0.4)) * (1 - Ease.smooth(Ease.segment(shiftLocal, 3, 3.5))) * motion
        if lean > 0 {
            let side = Ease.hash(Int(shiftCycle), seed &+ 67) > 0.5 ? 1.0 : -1.0
            pose.rotation += 0.05 * side * lean
            pose.x += 0.5 / (MenuBarPetCanvas.bodyWidthsPerPathUnit * 16.8) * side * lean
        }
    }

    /// The ^^ content squint: for the first moments after sitting down, and a few seconds every half minute.
    static func contentMoment(roam: RoamSample, time: TimeInterval, seed: UInt64) -> Bool {
        if roam.elapsed < 1.2 { return true }
        let period = 28.0
        let cycle = floor(time / period)
        let at = Ease.hash(Int(cycle), seed &+ 71) * (period - 3)
        let local = time - cycle * period - at
        return local >= 0 && local < 2.6
    }

    /// Eye openness for crisp, menu-bar-legible blinks.
    static func blink(_ time: TimeInterval, seed: UInt64) -> Double {
        let slot = 4.4
        let cycle = floor(time / slot)
        let start = cycle * slot + 0.5 + Ease.hash(Int(cycle), seed &+ 51) * (slot - 1.4)
        let local = time - start
        if local >= 0, local < 0.17 { return 0.05 }
        if Ease.hash(Int(cycle), seed &+ 53) < 0.2 {
            let second = local - 0.3
            if second >= 0, second < 0.15 { return 0.05 }
        }
        return 1
    }

    /// Mochi watches the pointer when it comes near (within ~150 pt along the bar).
    static func follow(_ pose: inout PetPose, pointer: CGPoint, petX: CGFloat, layout: MenuBarLayout, flipped: Bool, roam: RoamSample) {
        guard calm.contains(roam.animation), roam.speed < 0.5, roam.animation != .waveGently else { return }
        let dx = pointer.x - petX
        guard abs(dx) < 150 else { return }
        let headY = layout.baseline - layout.petHeight * 0.6
        let dy = pointer.y - headY
        let strength = 1 - Ease.smooth(Ease.segment(Double(abs(dx)), 90, 150))
        let lookX = Double(max(-1, min(1, dx / 40))) * (flipped ? -1 : 1)
        let lookY = Double(max(-0.6, min(0.9, dy / 60)))
        pose.lookX = Ease.lerp(pose.lookX, lookX, strength)
        pose.lookY = Ease.lerp(pose.lookY, lookY, strength)
    }
}
