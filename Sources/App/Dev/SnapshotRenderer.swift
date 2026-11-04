import AppKit
import SwiftUI
import TamagotchiCore
import TamagotchiWire

/// Development tool: renders characters, scenes and the app icon offscreen so art
/// and layout can be reviewed without screen recording.
/// `MacTamagotchi --render-snapshots <dir>`
@MainActor
enum SnapshotRenderer {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        renderPetGallery(to: directory.appendingPathComponent("pet-gallery.png"))
        renderCompanionGallery(to: directory.appendingPathComponent("companion-gallery.png"))
        for theme in OfficeTheme.allCases {
            for dark in [false, true] {
                renderScene(theme: theme, dark: dark, to: directory.appendingPathComponent("scene-\(theme.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        renderInteractionStrip(to: directory.appendingPathComponent("interactions.png"))
        renderAccessories(to: directory.appendingPathComponent("accessories.png"))
        renderMenuBarGlyphs(to: directory.appendingPathComponent("menubar.png"))
        renderLifeStages(to: directory.appendingPathComponent("life-stages.png"))
        DecorSnapshots.render(to: directory)
        print("Snapshots written to \(directory.path)")
    }

    static func write<V: View>(_ view: V, to url: URL, scale: CGFloat = 2) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            print("failed to render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }

    static func label(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
    }

    static func renderPetGallery(to url: URL) {
        let animations = PetAnimation.allCases.filter { $0 != .scripted }
        let columns = 8
        let view = VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<((animations.count + columns - 1) / columns), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(animations[(row * columns)..<min(animations.count, (row + 1) * columns)], id: \.self) { animation in
                        VStack(spacing: 0) {
                            Canvas { context, size in
                                let t = animation.isLoop ? 1.3 : animation.defaultDuration * 0.45
                                var pose = PetPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 3.3))
                                pose.x = 0
                                PetRenderer.draw(pose, in: context, at: CGPoint(x: size.width / 2, y: size.height - 8), scale: 1.25,
                                                 palette: PetPalette(.cream), accessory: nil, dark: false)
                            }
                            .frame(width: 104, height: 104)
                            label(animation.title)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0xFBF4EC))
        write(view, to: url)
    }

    static func renderCompanionGallery(to url: URL) {
        let animations = CompanionAnimation.allCases.filter { $0 != .scripted && $0 != .absent }
        let columns = 8
        let view = VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<((animations.count + columns - 1) / columns), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(animations[(row * columns)..<min(animations.count, (row + 1) * columns)], id: \.self) { animation in
                        VStack(spacing: 0) {
                            Canvas { context, size in
                                let t = animation.isLoop ? 1.3 : animation.defaultDuration * 0.5
                                let pose = CompanionPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 2.1),
                                                                       detail: CompanionDetail(waitingFor: .permission, subagents: 0))
                                CompanionRenderer.draw(pose, in: context, at: CGPoint(x: size.width / 2, y: size.height - 6), scale: 1.1,
                                                       accessory: nil, dark: false, time: 2.1) { desk in
                                    ThemeRenderer.deskFront(.cozyDesk, in: desk, dark: false, accessory: nil)
                                }
                            }
                            .frame(width: 150, height: 124)
                            label(animation.title)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0xFBF4EC))
        write(view, to: url)
    }

    static func renderLifeStages(to url: URL) {
        let view = HStack(spacing: 6) {
            ForEach(LifeStage.allCases, id: \.self) { stage in
                VStack(spacing: 2) {
                    Canvas { context, size in
                        PetRenderer.stage = stage
                        var pose = PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: 1.1))
                        pose.eyeOpenness = 1
                        PetRenderer.draw(pose, in: context, at: CGPoint(x: size.width / 2, y: size.height - 8), scale: 1.6,
                                         palette: PetPalette(.cream), accessory: nil, dark: false)
                        PetRenderer.stage = .grownUp
                    }
                    .frame(width: 140, height: 120)
                    label(stage.title)
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0xFBF4EC))
        write(view, to: url)
    }

    static func makeWorld(theme: OfficeTheme, configure: (inout AppSettings) -> Void = { _ in }) -> (CompanionWorld, () -> Void, (Double) -> Void) {
        var settings = AppSettings()
        settings.theme = theme
        configure(&settings)
        let store = SettingsStore(fileURL: nil, initial: settings)
        let journal = EventJournal(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).jsonl"),
                                   retention: .init(days: 0))
        final class Clock { var uptime: Double = 100; var date = Date() }
        let clock = Clock()
        let world = CompanionWorld(journal: journal, achievements: AchievementEngine(state: ProgressState()), settingsStore: store, seed: 9,
                                   clock: { clock.date }, uptime: { clock.uptime })
        return (world, { world.tick() }, { seconds in clock.uptime += seconds; clock.date += seconds })
    }

    static func sim(_ world: CompanionWorld, _ event: String, tool: String? = nil, configure: (inout WireEvent) -> Void = { _ in }) {
        var wire = WireEvent(id: UUID().uuidString, ts: Date().timeIntervalSince1970, origin: .simulator, event: event, session: "sim-a")
        wire.project = "InsideEdge (Demo)"
        wire.projectKey = "simkey"
        if let tool {
            wire.tool = tool
            wire.toolCategory = ToolCategoryClassifier.category(forTool: tool)
            wire.toolUseId = UUID().uuidString
        }
        configure(&wire)
        world.ingest(wire)
    }

    static func renderScene(theme: OfficeTheme, dark: Bool, to url: URL) {
        let (world, tick, advance) = makeWorld(theme: theme)
        sim(world, "SessionStart")
        advance(5); tick()
        sim(world, "UserPromptSubmit")
        advance(2.5); tick()
        sim(world, "PreToolUse", tool: theme == .cyberpunk ? "Bash" : (theme == .spaceStation ? "Grep" : "Edit"))
        advance(1.2); tick()
        let snapshot = SceneSnapshot(world: world)
        let view = Canvas { context, size in
            SceneRenderer.draw(snapshot, layout: .popover(width: size.width, height: size.height), in: context, time: 101 + 8.7,
                               dark: dark, hour: dark ? 22 : 14)
        }
        .frame(width: 360, height: 176)
        .environment(\.colorScheme, dark ? .dark : .light)
        write(view, to: url)
    }

    static func renderInteractionStrip(to url: URL) {
        let cases: [(InteractionID, Double, Int)] = [
            (.welcome, 1.2, 0), (.coffeeDelivery, 3.0, 0), (.highFive, 1.3, 0), (.victoryDance, 2.0, 0),
            (.trophyCelebration, 1.2, 0), (.caseClosed, 2.3, 0), (.ballDistraction, 1.6, 0), (.rockPaperScissors, 2.6, 4),
            (.sleepWatch, 8, 0), (.chairSteal, 4.0, 0), (.keyboardNap, 6, 0), (.mysteryOrb, 3.5, 0), (.graduation, 3.0, 0), (.showCode, 2.8, 1),
        ]
        let view = VStack(spacing: 6) {
            ForEach(0..<((cases.count + 2) / 3), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(cases[(row * 3)..<min(cases.count, row * 3 + 3)], id: \.0) { entry in
                        VStack(spacing: 2) {
                            Canvas { context, size in
                                let (world, tick, advance) = makeWorld(theme: .cozyDesk) { $0.companionVisibility = .always }
                                tick()
                                world.startInteraction(entry.0, priority: .critical, variant: entry.2)
                                advance(entry.1)
                                let snapshot = SceneSnapshot(world: world)
                                SceneRenderer.draw(snapshot, layout: .popover(width: size.width, height: size.height), in: context,
                                                   time: 100 + entry.1, dark: false, hour: 14)
                            }
                            .frame(width: 300, height: 150)
                            label(entry.0.title)
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(Color.white)
        write(view, to: url, scale: 1.5)
    }

    static func renderAccessories(to url: URL) {
        let wearables = Accessory.allCases.filter { $0.slot == .wearable }
        let colors = PetColor.allCases
        let view = VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(Array(wearables.enumerated()), id: \.offset) { index, accessory in
                    VStack(spacing: 0) {
                        Canvas { context, size in
                            var pose = PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: 0.5))
                            pose.eyes = index % 3 == 0 ? .happy : .open
                            PetRenderer.draw(pose, in: context, at: CGPoint(x: size.width / 2, y: size.height - 6), scale: 1.1,
                                             palette: PetPalette(colors[index % colors.count]), accessory: accessory, dark: false)
                        }
                        .frame(width: 84, height: 96)
                        Canvas { context, size in
                            let pose = CompanionPoseEvaluator.pose(.idleAtDesk, elapsed: 0, context: PoseContext(time: 0.5))
                            CompanionRenderer.draw(pose, in: context, at: CGPoint(x: size.width / 2, y: size.height - 8), scale: 1.25,
                                                   accessory: accessory, dark: false, time: 0.5, workstation: false) { _ in }
                        }
                        .frame(width: 84, height: 110)
                        label(accessory.title)
                    }
                }
            }
        }
        .padding(6)
        .background(Color(hex: 0xF4F1EC))
        write(view, to: url)
    }

    static func renderMenuBarGlyphs(to url: URL) {
        let moods: [(MenuBarMood, Bool, AttentionLevel?)] = [
            (.content, false, nil), (.sleeping, false, nil), (.watching, true, nil), (.waiting, true, .attention),
            (.concerned, true, .info), (.celebrating, true, nil), (.offline, true, .alert), (.paused, false, nil),
        ]
        let view = VStack(spacing: 6) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 14) {
                    ForEach(Array(moods.enumerated()), id: \.offset) { index, mood in
                        let status = MenuBarStatus(mood: mood.0, companionVisible: mood.1, companionWorking: mood.0 == .watching,
                                                   badge: mood.2, celebrationStartedAt: nil, simulated: false)
                        let image = MenuBarGlyph.image(for: status, frame: MenuBarGlyph.Frame(phase: 0.3, blink: false, bounce: mood.0 == .celebrating ? 2 : 0))
                        VStack(spacing: 2) {
                            Image(nsImage: image)
                                .renderingMode(.template)
                                .foregroundStyle(dark ? Color.white : Color.black)
                                .scaleEffect(2)
                                .frame(width: 60, height: 44)
                            Text(mood.0.rawValue).font(.system(size: 8)).foregroundStyle(dark ? Color.white : Color.black)
                        }
                    }
                }
                .padding(8)
                .background(dark ? Color(hex: 0x2B2B30) : Color(hex: 0xEDEDED))
            }
        }
        write(view, to: url)
    }
}

/// Renders the app icon from the same vector characters.
@MainActor
enum IconRenderer {
    static func renderIconset(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = CGFloat(size * scale)
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                SnapshotRenderer.write(icon(size: pixels), to: directory.appendingPathComponent(name), scale: 1)
            }
        }
        print("Iconset written to \(directory.path)")
    }

    static func icon(size: CGFloat) -> some View {
        Canvas { context, canvas in
            let s = canvas.width / 1024
            let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            let shape = Path(roundedRect: tile, cornerRadius: 185 * s, style: .continuous)
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.25), radius: 18 * s, y: 10 * s))
            shadowed.fill(shape, with: .linearGradient(Gradient(colors: [Color(hex: 0xFFF1E2), Color(hex: 0xF9C9A4)]),
                                                     startPoint: CGPoint(x: tile.minX, y: tile.minY), endPoint: CGPoint(x: tile.maxX, y: tile.maxY)))
            var inside = context
            inside.clip(to: shape)
            inside.fill(Path(CGRect(x: tile.minX, y: tile.minY + tile.height * 0.76, width: tile.width, height: tile.height * 0.24)),
                        Color(hex: 0xEDB58C).opacity(0.55))
            var pose = PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: 0.4))
            pose.eyeOpenness = 1
            pose.lookX = 0.35
            pose.blush = 0.7
            pose.mouth = .smile
            PetRenderer.draw(pose, in: inside, at: CGPoint(x: tile.minX + tile.width * 0.42, y: tile.minY + tile.height * 0.86),
                             scale: 7.8 * s, palette: PetPalette(.cream), accessory: nil, dark: false)
            var companion = CompanionPose()
            companion.eyes = .normal
            companion.rightArm = 0.8
            companion.antennaTint = .working
            companion.antennaGlow = 1
            var options = PixelMascot.Options()
            options.shadow = false
            PixelMascot.draw(companion, in: inside, feet: CGPoint(x: tile.minX + tile.width * 0.83, y: tile.minY + tile.height * 0.9),
                             pixel: 11 * s, time: 0.35, options: options)
            context.stroke(shape, Color.white.opacity(0.5), 3 * s)
        }
        .frame(width: size, height: size)
    }
}
