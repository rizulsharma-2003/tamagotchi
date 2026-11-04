// Exports Mochi's and Patch's poses from TamagotchiCore as JSON for the Flutter port.
//
//   swift run pose_export <flutter dir>
//
// Writes
//   <flutter>/packages/mochi_art/test/fixtures/reference_poses.json — the exact subjects the
//       Swift `--render-snapshots` / `--render-strips` tools draw, for the golden tests;
//   <flutter>/apps/mochi_gallery/assets/pose_tracks.json.deflate — every animation sampled over
//       time (raw DEFLATE-compressed JSON), so the gallery can play them before the pose
//       evaluators are ported to Dart.
//
// Keys are the Swift property names and enum raw values; values equal to the Swift defaults
// are left out (the Dart model has the same defaults).

import Foundation
import TamagotchiCore
import TamagotchiWire

// MARK: - JSON

/// Significant digits written for numbers (the gallery's tracks need fewer than the goldens).
nonisolated(unsafe) var digits = 6

func fmt(_ x: Double) -> String {
    guard x.isFinite else { return "0" }
    if x == x.rounded(), abs(x) < 1e9 { return String(Int(x)) }
    let text = String(format: "%.\(digits)g", x)
    return text == "-0" ? "0" : text
}

func quote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

struct Obj {
    var parts: [String] = []
    mutating func raw(_ key: String, _ value: String) { parts.append("\(quote(key)):\(value)") }
    mutating func num(_ key: String, _ value: Double, _ fallback: Double? = nil) {
        if let fallback, value == fallback { return }
        raw(key, fmt(value))
    }
    mutating func int(_ key: String, _ value: Int, _ fallback: Int? = nil) {
        if let fallback, value == fallback { return }
        raw(key, String(value))
    }
    mutating func str(_ key: String, _ value: String?, _ fallback: String? = nil) {
        guard let value, value != fallback else { return }
        raw(key, quote(value))
    }
    mutating func bool(_ key: String, _ value: Bool, _ fallback: Bool? = nil) {
        if let fallback, value == fallback { return }
        raw(key, value ? "true" : "false")
    }
    mutating func list(_ key: String, _ items: [String], omitEmpty: Bool = true) {
        if omitEmpty, items.isEmpty { return }
        raw(key, "[" + items.joined(separator: ",") + "]")
    }
    var json: String { "{" + parts.joined(separator: ",") + "}" }
}

func array(_ items: [String], pretty: Bool = false) -> String {
    pretty ? "[\n" + items.joined(separator: ",\n") + "\n]" : "[" + items.joined(separator: ",") + "]"
}

func json(_ e: Effect) -> String {
    var o = Obj()
    o.str("kind", e.kind.rawValue)
    o.num("x", e.x)
    o.num("y", e.y)
    o.num("scale", e.scale, 1)
    o.num("opacity", e.opacity, 1)
    o.num("rotation", e.rotation, 0)
    o.int("variant", e.variant, 0)
    o.num("stretch", e.stretch, 0)
    o.num("phase", e.phase, 0)
    o.num("x2", e.x2, 0)
    o.num("y2", e.y2, 0)
    o.bool("followsFacing", e.followsFacing, false)
    o.bool("worldSpace", e.worldSpace, false)
    return o.json
}

func json(_ p: PetPose) -> String {
    var o = Obj()
    o.num("x", p.x, 0)
    o.num("y", p.y, 0)
    o.num("scaleX", p.scaleX, 1)
    o.num("scaleY", p.scaleY, 1)
    o.num("rotation", p.rotation, 0)
    o.num("tilt", p.tilt, 0)
    o.num("facing", p.facing, 1)
    o.str("eyes", p.eyes.rawValue, "open")
    o.num("eyeOpenness", p.eyeOpenness, 1)
    o.num("lookX", p.lookX, 0.15)
    o.num("lookY", p.lookY, 0)
    o.str("brows", p.brows.rawValue, "none")
    o.str("mouth", p.mouth.rawValue, "cat")
    o.num("blush", p.blush, 0.35)
    o.num("earPerk", p.earPerk, 0)
    o.num("leftArm", p.leftArm, 0)
    o.num("rightArm", p.rightArm, 0)
    o.num("tailWag", p.tailWag, 0)
    o.num("step", p.step, 0)
    o.str("held", p.held?.rawValue)
    o.str("hat", p.hat?.rawValue)
    o.list("effects", p.effects.map(json))
    o.num("shadow", p.shadow, 1)
    o.num("opacity", p.opacity, 1)
    o.num("earLeft", p.earLeft, 0)
    o.num("earRight", p.earRight, 0)
    o.num("tailCurl", p.tailCurl, 0)
    o.num("tailLift", p.tailLift, 0)
    o.num("lean", p.lean, 0)
    o.num("breath", p.breath, 0)
    o.num("cheekLeft", p.cheekLeft, 0)
    o.num("cheekRight", p.cheekRight, 0)
    o.num("eyeSparkle", p.eyeSparkle, 0)
    o.num("eyeScale", p.eyeScale, 1)
    o.num("crossEyed", p.crossEyed, 0)
    o.num("stride", p.stride, 0)
    o.num("kick", p.kick, 0)
    o.num("pawToMouth", p.pawToMouth, 0)
    o.num("holdFront", p.holdFront, 0)
    o.num("headTurn", p.headTurn, 0)
    o.num("earListen", p.earListen, 0)
    return o.json
}

func json(_ p: CompanionPose) -> String {
    var o = Obj()
    o.num("x", p.x, 0)
    o.num("y", p.y, 0)
    o.num("scaleX", p.scaleX, 1)
    o.num("scaleY", p.scaleY, 1)
    o.num("rotation", p.rotation, 0)
    o.num("facing", p.facing, -1)
    o.str("eyes", p.eyes.rawValue, "normal")
    o.num("eyeOpenness", p.eyeOpenness, 1)
    o.num("lookX", p.lookX, 0)
    o.num("lookY", p.lookY, 0)
    o.str("mouth", p.mouth.rawValue, "none")
    o.num("visorBrightness", p.visorBrightness, 1)
    o.num("antennaGlow", p.antennaGlow, 0.35)
    o.str("antennaTint", p.antennaTint.rawValue, "calm")
    o.num("antennaBend", p.antennaBend, 0)
    o.num("leftArm", p.leftArm, 0)
    o.num("rightArm", p.rightArm, 0)
    o.num("reach", p.reach, 0)
    o.str("held", p.held?.rawValue)
    o.str("hat", p.hat?.rawValue)
    var laptop = Obj()
    laptop.bool("visible", p.laptop.visible, true)
    laptop.num("openness", p.laptop.openness, 1)
    laptop.str("screen", p.laptop.screen.rawValue, "idle")
    laptop.num("scroll", p.laptop.scroll, 0)
    if !laptop.parts.isEmpty { o.raw("laptop", laptop.json) }
    o.list("effects", p.effects.map(json))
    o.num("shadow", p.shadow, 1)
    o.num("opacity", p.opacity, 1)
    return o.json
}

func json(_ p: SceneProp) -> String {
    var o = Obj()
    o.str("kind", p.kind.rawValue)
    o.num("x", p.x)
    o.num("y", p.y)
    o.num("scale", p.scale, 1)
    o.num("opacity", p.opacity, 1)
    o.num("rotation", p.rotation, 0)
    o.int("variant", p.variant, 0)
    return o.json
}

// MARK: - Worlds (mirrors Sources/App/Dev/SnapshotRenderer.swift)

@MainActor
func makeWorld(theme: OfficeTheme, configure: (inout AppSettings) -> Void = { _ in }) -> (CompanionWorld, () -> Void, (Double) -> Void) {
    var settings = AppSettings()
    settings.theme = theme
    configure(&settings)
    let store = SettingsStore(fileURL: nil, initial: settings)
    let journal = EventJournal(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pose-export-\(UUID().uuidString).jsonl"),
                               retention: .init(days: 0))
    final class Clock { var uptime: Double = 100; var date = Date() }
    let clock = Clock()
    let world = CompanionWorld(journal: journal, achievements: AchievementEngine(state: ProgressState()), settingsStore: store, seed: 9,
                               clock: { clock.date }, uptime: { clock.uptime })
    return (world, { world.tick() }, { seconds in clock.uptime += seconds; clock.date += seconds })
}

@MainActor
func sim(_ world: CompanionWorld, _ event: String, tool: String? = nil) {
    var wire = WireEvent(id: UUID().uuidString, ts: Date().timeIntervalSince1970, origin: .simulator, event: event, session: "sim-a")
    wire.project = "InsideEdge (Demo)"
    wire.projectKey = "simkey"
    if let tool {
        wire.tool = tool
        wire.toolCategory = ToolCategoryClassifier.category(forTool: tool)
        wire.toolUseId = UUID().uuidString
    }
    world.ingest(wire)
}

/// One frame of the scene as `SceneRenderer.poses` computes it (Sources/App/Rendering/SceneRenderer.swift).
@MainActor
func sceneFrame(_ world: CompanionWorld, time: Double) -> Obj {
    let pet = world.pet.current
    let petBase = world.pet.base
    let companion = world.companion.current
    let interaction = world.interaction
    let detail = world.companionDetail
    let reduced = world.reducedMotion
    let intensity = world.settings.animationIntensity
    let seed = world.seed

    func poses(_ time: Double) -> (PetPose, CompanionPose, [SceneProp]) {
        let petContext = PoseContext(time: time, reducedMotion: reduced, intensity: intensity, seed: seed)
        let companionContext = PoseContext(time: time, reducedMotion: reduced, intensity: intensity, seed: seed &+ 0x5EED)
        func singlePet() -> PetPose {
            let animation = pet.animation == .scripted ? .idle : pet.animation
            var context = petContext
            context.returnLoop = petBase
            return PetPoseEvaluator.pose(animation, elapsed: pet.elapsed(at: time), duration: pet.duration, context: context)
        }
        func singleCompanion() -> CompanionPose {
            let animation = companion.animation == .scripted ? .idleAtDesk : companion.animation
            return CompanionPoseEvaluator.pose(animation, elapsed: companion.elapsed(at: time), duration: companion.duration,
                                               context: companionContext, detail: detail)
        }
        if let playback = interaction, pet.scriptID == playback.id.rawValue || companion.scriptID == playback.id.rawValue {
            let frame = InteractionLibrary.frame(playback, elapsed: time - playback.startedAt, petContext: petContext,
                                                 companionContext: companionContext, detail: detail)
            let p = pet.scriptID != playback.id.rawValue ? singlePet() : frame.pet
            let c = companion.scriptID != playback.id.rawValue ? singleCompanion() : frame.companion
            return (p, c, frame.props)
        }
        return (singlePet(), singleCompanion(), [])
    }

    let (p, c, props) = poses(time)
    let visible = world.companionPresent && companion.animation != .absent
    var velocity = 0.0
    if visible, interaction != nil {
        velocity = (c.x - poses(time - 0.06).1.x) / 0.06
    }
    var o = Obj()
    o.raw("pet", json(p))
    o.raw("companion", json(c))
    o.list("props", props.map(json))
    o.bool("companionVisible", visible)
    o.num("companionVelocity", velocity, 0)
    o.int("subagents", detail.subagents, 0)
    o.bool("petAway", world.adventureActive, false)
    o.bool("reducedMotion", reduced, false)
    return o
}

@MainActor
func roomJSON(_ room: RoomLayout) -> String {
    array(room.items.map { item in
        var o = Obj()
        o.str("kind", item.kind)
        o.num("x", item.x)
        o.num("y", item.y)
        o.bool("flipped", item.flipped, false)
        return o.json
    })
}

@MainActor
func scene(name: String, world: CompanionWorld, theme: OfficeTheme, dark: Bool, hour: Int, time: Double, width: Double, height: Double,
           room: RoomLayout = RoomLayout(), season: SeasonalEvent? = nil, reduced: Bool? = nil) -> String {
    var o = sceneFrame(world, time: time)
    o.str("name", name)
    o.str("theme", theme.rawValue)
    let settings = world.settings
    o.str("petColor", settings.petColor.rawValue)
    o.str("petAccessory", settings.petAccessory?.rawValue)
    o.str("companionAccessory", settings.companionAccessory?.rawValue)
    o.raw("deskAccessory", settings.deskAccessory.map { quote($0.rawValue) } ?? "null")
    o.bool("dark", dark)
    o.int("hour", hour)
    o.num("time", time)
    o.num("width", width)
    o.num("height", height)
    if !room.items.isEmpty { o.raw("room", roomJSON(room)) }
    o.str("season", season?.rawValue)
    if let reduced { o.bool("reducedMotion", reduced, false) }
    return o.json
}

// MARK: - Reference subjects (Sources/App/Dev/SnapshotRenderer.swift, AnimationStrips.swift, DecorSnapshots.swift)

@MainActor
func reference() -> String {
    var root = Obj()

    // pet-gallery.png
    let pets = PetAnimation.allCases.filter { $0 != .scripted }
    root.list("petGallery", pets.map { animation in
        let t = animation.isLoop ? 1.3 : animation.defaultDuration * 0.45
        var pose = PetPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 3.3))
        pose.x = 0
        var o = Obj()
        o.str("animation", animation.rawValue)
        o.str("title", animation.title)
        o.raw("pose", json(pose))
        return o.json
    })

    // companion-gallery.png
    let companions = CompanionAnimation.allCases.filter { $0 != .scripted && $0 != .absent }
    root.list("companionGallery", companions.map { animation in
        let t = animation.isLoop ? 1.3 : animation.defaultDuration * 0.5
        let pose = CompanionPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 2.1),
                                               detail: CompanionDetail(waitingFor: .permission, subagents: 0))
        var o = Obj()
        o.str("animation", animation.rawValue)
        o.str("title", animation.title)
        o.num("time", 2.1)
        o.raw("pose", json(pose))
        return o.json
    })

    // life-stages.png
    var stagePose = PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: 1.1))
    stagePose.eyeOpenness = 1
    root.raw("lifeStagePose", json(stagePose))

    // accessories.png
    root.raw("accessoryPetPose", json(PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: 0.5))))
    root.raw("accessoryCompanionPose", json(CompanionPoseEvaluator.pose(.idleAtDesk, elapsed: 0, context: PoseContext(time: 0.5))))

    // The framed photo's still (FurnitureArt.Photo.pet).
    var photo = PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: 0.4))
    photo.eyeOpenness = 1
    photo.lookX = 0.35
    photo.blush = 0.7
    photo.mouth = .smile
    root.raw("photoPetPose", json(photo))

    // pet-tiny-features.png: the base idle pose, asleep and running (the sheet derives the rest).
    root.raw("tinyBasePose", json(PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: 20.4, seed: 7))))
    root.raw("tinySleepPose", json(PetPoseEvaluator.pose(.sleep, elapsed: 0, context: PoseContext(time: 21, seed: 7))))
    root.raw("tinyRunPose", json(PetPoseEvaluator.pose(.run, elapsed: 0, context: PoseContext(time: 21.1, seed: 7))))

    // pet-strips-N.png: every animation, variant 0, 10 frames, start 10, seed 7.
    root.list("petStrips", pets.map { animation in
        let length = animation.isLoop ? 3.0 : animation.defaultDuration
        let frames = (0..<10).map { index -> String in
            let t = length * Double(index) / 9
            let pose = PetPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 10 + t, seed: 7), variant: 0)
            var o = Obj()
            o.num("t", t)
            o.raw("pose", json(pose))
            return o.json
        }
        var o = Obj()
        o.str("animation", animation.rawValue)
        o.str("title", animation.title)
        o.num("length", length)
        o.list("frames", frames)
        return o.json
    }, omitEmpty: false)

    // companion-strips-N.png: 8 frames each.
    root.list("companionStrips", companions.map { animation in
        let length = animation.isLoop ? 3.0 : animation.defaultDuration
        let frames = (0..<8).map { index -> String in
            let t = length * Double(index) / 7
            let pose = CompanionPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 10 + t, seed: 7),
                                                   detail: CompanionDetail(waitingFor: .permission, subagents: 0))
            var o = Obj()
            o.num("t", t)
            o.num("time", 10 + t)
            o.raw("pose", json(pose))
            return o.json
        }
        var o = Obj()
        o.str("animation", animation.rawValue)
        o.str("title", animation.title)
        o.num("length", length)
        o.list("frames", frames)
        return o.json
    })

    // scene-<theme>-<light|dark>.png
    var scenes: [String] = []
    for theme in OfficeTheme.allCases {
        for dark in [false, true] {
            let (world, tick, advance) = makeWorld(theme: theme)
            sim(world, "SessionStart")
            advance(5); tick()
            sim(world, "UserPromptSubmit")
            advance(2.5); tick()
            sim(world, "PreToolUse", tool: theme == .cyberpunk ? "Bash" : (theme == .spaceStation ? "Grep" : "Edit"))
            advance(1.2); tick()
            scenes.append(scene(name: "scene-\(theme.rawValue)-\(dark ? "dark" : "light")", world: world, theme: theme, dark: dark,
                                hour: dark ? 22 : 14, time: 101 + 8.7, width: 360, height: 176))
        }
    }
    root.list("scenes", scenes)

    // interactions.png
    let cases: [(InteractionID, Double, Int)] = [
        (.welcome, 1.2, 0), (.coffeeDelivery, 3.0, 0), (.highFive, 1.3, 0), (.victoryDance, 2.0, 0),
        (.trophyCelebration, 1.2, 0), (.caseClosed, 2.3, 0), (.ballDistraction, 1.6, 0), (.rockPaperScissors, 2.6, 4),
        (.sleepWatch, 8, 0), (.chairSteal, 4.0, 0), (.keyboardNap, 6, 0), (.mysteryOrb, 3.5, 0), (.graduation, 3.0, 0), (.showCode, 2.8, 1),
    ]
    root.list("interactions", cases.map { entry in
        let (world, tick, advance) = makeWorld(theme: .cozyDesk) { $0.companionVisibility = .always }
        tick()
        _ = world.startInteraction(entry.0, priority: .critical, variant: entry.2)
        advance(entry.1)
        return scene(name: entry.0.title, world: world, theme: .cozyDesk, dark: false, hour: 14, time: 100 + entry.1, width: 300, height: 150)
    })

    // room-furnished.png
    var room = RoomLayout()
    let picks: [(String, Double, Double, Bool)] = [("rug", 0.47, 0.92, false), ("bookshelf", 0.06, 0.87, false), ("plant", 0.15, 0.88, false),
                                                  ("poster", 0.47, 0.34, false), ("clock", 0.57, 0.27, false), ("lamp", 0.95, 0.87, false),
                                                  ("photo", 0.38, 0.3, false), ("fishBowl", 0.87, 0.9, true)]
    for (id, x, y, flipped) in picks {
        if let kind = FurnitureCatalog.kind(id), let item = room.add(kind, x: x, y: y), flipped { room.toggleFlip(item.id) }
    }
    var rooms: [String] = []
    for theme in OfficeTheme.allCases {
        for dark in [false, true] {
            let (world, tick, _) = makeWorld(theme: theme) { settings in
                settings.companionVisibility = .always
                settings.room = room
            }
            tick()
            rooms.append(scene(name: "room-\(theme.rawValue)-\(dark ? "dark" : "light")", world: world, theme: theme, dark: dark,
                               hour: dark ? 22 : 14, time: 103.1, width: 360, height: 178, room: room))
        }
    }
    root.list("rooms", rooms)

    // season-<event>.png: 4 themes light/dark, then Reduced Motion and another moment.
    var seasons: [String] = []
    for event in SeasonalEvent.allCases where event != .mochiBirthday {
        var shots: [(OfficeTheme, Bool, Double, Bool)] = []
        for theme in OfficeTheme.allCases {
            for dark in [false, true] { shots.append((theme, dark, 101.3 + (dark ? 2.2 : 0), false)) }
        }
        shots.append((.cozyDesk, false, 107.9, true))
        shots.append((.cozyDesk, true, 104.6, false))
        for (index, shot) in shots.enumerated() {
            let (world, tick, _) = makeWorld(theme: shot.0) { $0.companionVisibility = .always }
            tick()
            seasons.append(scene(name: "season-\(event.rawValue)-\(index)", world: world, theme: shot.0, dark: shot.1, hour: shot.1 ? 22 : 14,
                                 time: shot.2, width: 360, height: 178, season: event, reduced: shot.3))
        }
    }
    root.list("seasons", seasons)

    // season-treat-story.png: the cookie-catch treat at 0.7 s and 1.3 s.
    root.list("treatStory", [0.7, 1.3].map { t in
        var pose = PetPoseEvaluator.pose(.treat, elapsed: t, context: PoseContext(time: 50 + t), variant: 0)
        pose.x = 0
        var o = Obj()
        o.num("t", t)
        o.raw("pose", json(pose))
        return o.json
    })

    return root.json
}

// MARK: - Tracks for the gallery

@MainActor
func tracks(fps: Double) -> String {
    var root = Obj()
    root.num("fps", fps)
    let pets = PetAnimation.allCases.filter { $0 != .scripted }
    var petTracks: [String] = []
    for animation in pets {
        for variant in 0..<PetPoseEvaluator.variantCount(animation) {
            let length = animation.isLoop ? 4.0 : animation.defaultDuration
            let count = Int((length * fps).rounded()) + 1
            let frames = (0..<count).map { index -> String in
                let t = min(length, Double(index) / fps)
                return json(PetPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 10 + t, seed: 7), variant: variant))
            }
            var o = Obj()
            o.str("animation", animation.rawValue)
            o.int("variant", variant)
            o.str("title", PetPoseEvaluator.variantCount(animation) > 1
                ? "\(animation.title) · \(PetPoseEvaluator.variantName(animation, variant))" : animation.title)
            o.bool("loop", animation.isLoop)
            o.num("length", length)
            o.raw("frames", array(frames))
            petTracks.append(o.json)
        }
    }
    root.raw("pet", array(petTracks, pretty: true))

    let companions = CompanionAnimation.allCases.filter { $0 != .scripted && $0 != .absent }
    root.raw("companion", array(companions.map { animation in
        let length = animation.isLoop ? 4.0 : animation.defaultDuration
        let count = Int((length * fps).rounded()) + 1
        let frames = (0..<count).map { index -> String in
            let t = min(length, Double(index) / fps)
            return json(CompanionPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 10 + t, seed: 7),
                                                    detail: CompanionDetail(waitingFor: .permission, subagents: 0)))
        }
        var o = Obj()
        o.str("animation", animation.rawValue)
        o.str("title", animation.title)
        o.bool("loop", animation.isLoop)
        o.num("length", length)
        o.raw("frames", array(frames))
        return o.json
    }, pretty: true))

    // Whole interactions in the cozy room, the way the scene plays them.
    var interactions: [String] = []
    for id in InteractionID.allCases {
        let (world, tick, advance) = makeWorld(theme: .cozyDesk) { $0.companionVisibility = .always }
        tick()
        _ = world.startInteraction(id, priority: .critical, variant: 0)
        let length = InteractionLibrary.script(id, variant: 0).duration + 0.6
        let count = Int((length * fps).rounded()) + 1
        var frames: [String] = []
        for index in 0..<count {
            if index > 0 { advance(1 / fps); tick() }
            frames.append(sceneFrame(world, time: world.now).json)
        }
        var o = Obj()
        o.str("interaction", id.rawValue)
        o.str("title", id.title)
        o.raw("deskAccessory", world.settings.deskAccessory.map { quote($0.rawValue) } ?? "null")
        o.num("length", length)
        o.raw("frames", array(frames))
        interactions.append(o.json)
    }
    root.raw("interactions", array(interactions, pretty: true))
    return root.json
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: pose_export <flutter dir>")
    exit(2)
}
let flutter = URL(fileURLWithPath: arguments[1])
let fixtures = flutter.appendingPathComponent("packages/mochi_art/test/fixtures")
let assets = flutter.appendingPathComponent("apps/mochi_gallery/assets")
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try reference().write(to: fixtures.appendingPathComponent("reference_poses.json"), atomically: true, encoding: .utf8)
digits = 5
let packed = try (Data(tracks(fps: 15).utf8) as NSData).compressed(using: .zlib) as Data
try packed.write(to: assets.appendingPathComponent("pose_tracks.json.deflate"))
print("Wrote \(fixtures.path)/reference_poses.json and \(assets.path)/pose_tracks.json.deflate")
