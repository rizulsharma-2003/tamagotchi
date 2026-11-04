import AppKit
import SwiftUI
import TamagotchiCore

/// Development tool: renders motion strips — each animation as a row of frames
/// over time — so motion quality can be judged without running the app.
/// `MacTamagotchi --render-strips <dir>`
@MainActor
enum AnimationStrips {
    /// One row of a sheet: an animation (and variant) sampled over `length` seconds.
    struct Row: Hashable {
        var animation: PetAnimation
        var variant: Int?
        var length: Double
        var start: Double = 10
        var title: String
        /// Set the way a caller would after evaluating (e.g. walking left along the menu bar).
        var facing = 1.0

        init(_ animation: PetAnimation, variant: Int? = nil, length: Double? = nil, start: Double = 10, title: String? = nil) {
            self.animation = animation
            self.variant = variant
            self.length = length ?? (animation.isLoop ? 3.0 : animation.defaultDuration)
            self.start = start
            if let title {
                self.title = title
            } else if let variant, PetPoseEvaluator.variantCount(animation) > 1 {
                self.title = "\(animation.title) · \(PetPoseEvaluator.variantName(animation, variant))"
            } else {
                self.title = animation.title
            }
        }

        func times(_ frames: Int) -> [Double] {
            (0..<frames).map { length * Double($0) / Double(max(1, frames - 1)) }
        }

        func pose(at t: Double, reduced: Bool = false) -> PetPose {
            let context = PoseContext(time: start + t, reducedMotion: reduced, seed: 7)
            let pose = variant.map { PetPoseEvaluator.pose(animation, elapsed: t, context: context, variant: $0) }
                ?? PetPoseEvaluator.pose(animation, elapsed: t, context: context)
            // Facing left the way hosts must do it: mirror the whole pose.
            return facing < 0 ? pose.mirrored() : pose
        }

        func facingLeft() -> Row {
            var row = self
            row.facing = -1
            row.title += " ←"
            return row
        }
    }

    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func out(_ name: String) -> URL { directory.appendingPathComponent(name) }
        // `MACTAMAGOTCHI_STRIPS_ONLY=play` renders only the files whose name contains "play".
        let only = ProcessInfo.processInfo.environment["MACTAMAGOTCHI_STRIPS_ONLY"]
        timePoses()
        func write<V: View>(_ view: @autoclosure () -> V, to url: URL, scale: CGFloat) {
            if let only, !only.isEmpty, !url.lastPathComponent.contains(only) { return }
            SnapshotRenderer.write(view(), to: url, scale: scale)
        }

        // Overview of every animation.
        let pets = PetAnimation.allCases.filter { $0 != .scripted }
        for (index, chunk) in chunks(pets, 8).enumerated() {
            write(petSheet(chunk.map { Row($0, variant: 0) }, frames: 10), to: out("pet-strips-\(index + 1).png"), scale: 1.5)
        }
        // Every story of play, treat and petted, frame by frame.
        for animation in [PetAnimation.play, .treat, .petted] {
            let rows = (0..<PetPoseEvaluator.variantCount(animation)).map { Row(animation, variant: $0) }
            write(petSheet(rows, frames: 20, cell: 84, wide: true), to: out("pet-\(animation.rawValue).png"), scale: 2)
            for row in rows {
                let slug = PetPoseEvaluator.variantName(animation, row.variant ?? 0).lowercased().replacingOccurrences(of: " ", with: "-")
                write(gridSheet(row, frames: 24, columns: 6), to: out("pet-\(animation.rawValue)-\(slug).png"), scale: 2)
            }
        }
        // The stories inside the real popover layout (props are calibrated to it).
        write(sceneSheet(), to: out("pet-in-scene.png"), scale: 1.5)
        // Onion skins: every story as overlapping ghosts, to judge arcs and spacing.
        let stories = [PetAnimation.play, .treat, .petted].flatMap { animation in
            (0..<PetPoseEvaluator.variantCount(animation)).map { Row(animation, variant: $0) }
        } + [Row(.excitedJump), Row(.victory), Row(.pounce), Row(.tumble)]
        write(onionSheet(stories), to: out("pet-onion.png"), scale: 1.5)
        // Six seconds of idle life and of the calm loops.
        write(petSheet([Row(.idle, length: 6, start: 20, title: "Idle 0–6 s"), Row(.idle, length: 6, start: 26, title: "Idle 6–12 s"),
                                         Row(.idle, length: 6, start: 32, title: "Idle 12–18 s")], frames: 24, cell: 72),
                               to: out("pet-idle.png"), scale: 2)
        write(petSheet([Row(.sleep, length: 6), Row(.curl, length: 6), Row(.watch, length: 6), Row(.waveGently, length: 6)],
                                        frames: 20, cell: 72), to: out("pet-loops.png"), scale: 2)
        write(petSheet([Row(.sleep, length: 10, start: 40)], frames: 20, cell: 84), to: out("pet-sleep.png"), scale: 2)
        // Gait cycles: one run cycle and one walk cycle, finely sampled.
        write(petSheet([Row(.run, length: 1 / 3.4, title: "Run cycle"), Row(.walk, length: 1 / 2.2, title: "Walk cycle"),
                                         Row(.run, length: 1.2, title: "Run 1.2 s")], frames: 12, cell: 84),
                               to: out("pet-run.png"), scale: 2)
        // Building blocks and polished one-shots.
        let blocks: [PetAnimation] = [.pounce, .bat, .tumble, .sniff, .stretch, .scratch, .shake, .leapCatch]
        write(petSheet(blocks.map { Row($0) }, frames: 14, cell: 80, wide: true), to: out("pet-blocks.png"), scale: 2)
        let polish: [PetAnimation] = [.happyBounce, .excitedJump, .victory, .dance, .greet, .wave, .yawn, .wakeUp]
        write(petSheet(polish.map { Row($0) }, frames: 14, cell: 80), to: out("pet-oneshots.png"), scale: 2)
        // Reduced Motion versions of the stories.
        let calm = [PetAnimation.play, .treat, .petted].flatMap { animation in
            (0..<PetPoseEvaluator.variantCount(animation)).map { Row(animation, variant: $0) }
        }
        write(petSheet(calm, frames: 10, cell: 72, wide: true, reduced: true), to: out("pet-reduced.png"), scale: 1.5)
        // The pet at menu-bar size on light and dark bars (magnified and at Retina pixel size).
        write(tinySheet(), to: out("pet-tiny.png"), scale: 5)
        write(tinySheet(), to: out("pet-tiny-2x.png"), scale: 2)
        write(tinyFeatures(), to: out("pet-tiny-features.png"), scale: 4)
        write(tinyFeatures(), to: out("pet-tiny-features-2x.png"), scale: 2)
        // The menu bar at the roamer's real scales (0.235 in the overlay, 0.215 in the stage),
        // with the space above the bar hatched: anything drawn there would be clipped.
        let barBlocks: [BarClip] = [.init(.pounce), .init(.bat), .init(.tumble), .init(.sniff), .init(.stretch), .init(.scratch),
                                    .init(.shake), .init(.leapCatch), .init(.happyBounce), .init(.yawn), .init(.blep),
                                    .init(.lookAround), .init(.wakeUp), .init(.excitedJump), .init(.sit, length: 12),
                                    .init(.idle, length: 12)]
        let barStories = [PetAnimation.play, .treat, .petted].flatMap { animation in
            (0..<PetPoseEvaluator.variantCount(animation)).map { BarClip(animation, variant: $0) }
        }
        for (scale, tag) in [(CGFloat(0.235), "235"), (CGFloat(0.215), "215")] {
            write(barFilm(barBlocks, frames: 14, petScale: scale), to: out("pet-bar-blocks-\(tag).png"), scale: 2)
            write(barFilm(barBlocks, frames: 14, petScale: scale), to: out("pet-bar-blocks-\(tag)-x5.png"), scale: 5)
            write(barFilm(barStories, frames: 16, petScale: scale), to: out("pet-bar-stories-\(tag)-x5.png"), scale: 5)
            write(walkFilm(petScale: scale), to: out("pet-bar-walk-\(tag)-x5.png"), scale: 5)
        }
        write(idleFilm(petScale: 0.235), to: out("pet-bar-idle-235.png"), scale: 2)
        write(idleFilm(petScale: 0.235), to: out("pet-bar-idle-235-x6.png"), scale: 6)

        let companions = CompanionAnimation.allCases.filter { $0 != .scripted && $0 != .absent }
        for (index, chunk) in chunks(companions, 8).enumerated() {
            write(companionSheet(chunk, frames: 8), to: out("companion-strips-\(index + 1).png"), scale: 1.5)
        }
        print("Strips written to \(directory.path)")
    }

    /// Prints how long a pose takes to evaluate (it runs every frame, with several
    /// look-back samples for secondary motion).
    static func timePoses() {
        let clock = ContinuousClock()
        for animation in [PetAnimation.idle, .run, .play, .treat, .petted] {
            var sink = 0.0
            let count = 20_000
            let elapsed = clock.measure {
                for index in 0..<count {
                    let t = Double(index % 150) / 30
                    let pose = PetPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 10 + t, seed: 3), variant: index % 3)
                    sink += pose.y + Double(pose.effects.count)
                }
            }
            let micros = Double(elapsed.components.attoseconds) / 1e12 / Double(count) + Double(elapsed.components.seconds) * 1e6 / Double(count)
            print(String(format: "pose %@: %.2f µs", animation.rawValue, micros), sink.isFinite ? "" : "!")
        }
    }

    /// Each feature that must read in the menu bar, isolated: open, blink, ear twitch,
    /// tail swish, happy, sparkly, cheeks, asleep.
    static func tinyFeatures() -> some View {
        let base = PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: 20.4, seed: 7))
        var variants: [(String, PetPose)] = []
        var p = base; p.eyeOpenness = 1; variants.append(("open", p))
        p = base; p.eyeOpenness = 0.05; variants.append(("blink", p))
        p = base; p.earRight += 0.45; variants.append(("ear", p))
        p = base; p.tailWag = 1.6; p.tailCurl = 0.6; variants.append(("tail", p))
        p = base; p.eyes = .happy; p.mouth = .grin; p.blush = 0.9; variants.append(("happy", p))
        p = base; p.eyes = .wide; p.eyeSparkle = 1; p.eyeScale = 1.2; variants.append(("sparkle", p))
        p = base; p.cheekLeft = 1; p.cheekRight = 1; p.mouth = .tiny; variants.append(("cheeks", p))
        p = PetPoseEvaluator.pose(.sleep, elapsed: 0, context: PoseContext(time: 21, seed: 7)); variants.append(("sleep", p))
        p = PetPoseEvaluator.pose(.run, elapsed: 0, context: PoseContext(time: 21.1, seed: 7)); variants.append(("run", p))
        return VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 3) {
                    ForEach(Array(variants.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 0) {
                            Canvas { context, size in
                                PetRenderer.draw(item.1, in: context, at: CGPoint(x: size.width * 0.45, y: size.height - 2.5), scale: 0.3,
                                                 palette: PetPalette(.cream), accessory: nil, dark: dark, detail: .tiny)
                            }
                            .frame(width: 30, height: 22)
                            Text(item.0).font(.system(size: 4.5, weight: .medium)).foregroundStyle(dark ? Color.white.opacity(0.6) : Color.black.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(dark ? Color(hex: 0x2B2A30) : Color(hex: 0xF2F1F4))
            }
        }
    }

    /// Key moments of each story drawn in the popover scene (360 × 178) with the desk and Patch.
    static func sceneSheet() -> some View {
        let moments: [(PetAnimation, Int, Double)] = [
            (.play, 0, 1.2), (.play, 0, 1.62), (.play, 0, 2.5), (.play, 0, 3.62),
            (.play, 1, 2.2), (.play, 2, 3.4), (.play, 3, 1.65), (.treat, 0, 1.0),
            (.treat, 1, 2.0), (.treat, 2, 2.1), (.treat, 3, 1.9), (.petted, 1, 1.8),
        ]
        let columns = 3
        let lines = (moments.count + columns - 1) / columns
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<lines, id: \.self) { line in
                HStack(spacing: 6) {
                    ForEach(Array(moments[(line * columns)..<min(moments.count, (line + 1) * columns)].enumerated()), id: \.offset) { _, moment in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(PetPoseEvaluator.variantName(moment.0, moment.1)) · \(String(format: "%.2fs", moment.2))")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                            Canvas { context, size in
                                let ground = size.height - 24
                                let scale = min(1.12, size.height / 158)
                                let petHome = size.width * 0.27
                                let companionHome = size.width * 0.69
                                ThemeRenderer.background(.cozyDesk, in: context, size: size, ground: ground, dark: false, time: 30, hour: 14)
                                let companion = CompanionPoseEvaluator.pose(.idleAtDesk, elapsed: 1, context: PoseContext(time: 31, seed: 9))
                                CompanionRenderer.draw(companion, in: context, at: CGPoint(x: companionHome, y: ground), scale: scale,
                                                       accessory: nil, dark: false) { desk in
                                    ThemeRenderer.deskFront(.cozyDesk, in: desk, dark: false, accessory: .plant)
                                }
                                let pose = PetPoseEvaluator.pose(moment.0, elapsed: moment.2, context: PoseContext(time: 50 + moment.2, seed: 7),
                                                                 variant: moment.1)
                                PetRenderer.draw(pose, in: context, at: CGPoint(x: petHome + CGFloat(pose.x) * (companionHome - petHome), y: ground),
                                                 scale: scale, palette: PetPalette(.cream), accessory: nil, dark: false)
                            }
                            .frame(width: 360, height: 178)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0xF4EFEA))
    }

    /// Each row's frames drawn on top of each other with rising opacity (onion skin).
    static func onionSheet(_ rows: [Row], frames: Int = 16) -> some View {
        let columns = 3
        let lines = (rows.count + columns - 1) / columns
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<lines, id: \.self) { line in
                HStack(spacing: 6) {
                    ForEach(Array(rows[(line * columns)..<min(rows.count, (line + 1) * columns)].enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.title).font(.system(size: 9, weight: .semibold, design: .rounded))
                            Canvas { context, size in
                                let ground = size.height - 10
                                let scale: CGFloat = 0.9
                                let home = size.width * 0.36
                                context.fill(Path(CGRect(x: 0, y: ground + 1, width: size.width, height: 1)), with: .color(.black.opacity(0.15)))
                                let times = row.times(frames)
                                for (index, t) in times.enumerated() {
                                    var ghost = context
                                    ghost.opacity = 0.12 + 0.6 * Double(index) / Double(max(1, times.count - 1))
                                    let pose = row.pose(at: t)
                                    let offset = CGFloat(pose.x * PetPoseEvaluator.bodyWidthsPerPathUnit) * PetRenderer.bodyWidth * scale
                                    PetRenderer.draw(pose, in: ghost, at: CGPoint(x: home + offset, y: ground), scale: scale,
                                                     palette: PetPalette(.cream), accessory: nil, dark: false)
                                }
                            }
                            .frame(width: 300, height: 150)
                            .background(Color.white.opacity(0.4))
                            .clipped()
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0xFBF4EC))
    }

    static func chunks<T>(_ items: [T], _ size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min(items.count, $0 + size)]) }
    }

    /// One story as a grid of large frames in wide cells (props in world space stay in view).
    static func gridSheet(_ row: Row, frames: Int, columns: Int, cell: CGFloat = 96, dark: Bool = false) -> some View {
        let times = row.times(frames)
        let scale = cell / 78
        let rows = (times.count + columns - 1) / columns
        return VStack(alignment: .leading, spacing: 4) {
            Text(row.title).font(.system(size: 11, weight: .bold, design: .rounded))
            ForEach(0..<rows, id: \.self) { line in
                HStack(spacing: 4) {
                    ForEach(Array(times[(line * columns)..<min(times.count, (line + 1) * columns)].enumerated()), id: \.offset) { _, t in
                        VStack(spacing: 0) {
                            Canvas { context, size in
                                let ground = size.height - 8
                                context.fill(Path(CGRect(x: 0, y: ground + 1, width: size.width, height: 1)), with: .color(.black.opacity(0.12)))
                                let home = size.width * 0.36
                                context.fill(Path(CGRect(x: home - 0.5, y: ground + 1, width: 1, height: 4)), with: .color(.black.opacity(0.25)))
                                let pose = row.pose(at: t)
                                let offset = CGFloat(pose.x * PetPoseEvaluator.bodyWidthsPerPathUnit) * PetRenderer.bodyWidth * scale
                                PetRenderer.draw(pose, in: context, at: CGPoint(x: home + offset, y: ground), scale: scale,
                                                 palette: PetPalette(.cream), accessory: nil, dark: dark)
                            }
                            .frame(width: cell * 2.3, height: cell * 1.75)
                            .background(Color.white.opacity(0.35))
                            .clipped()
                            Text(String(format: "%.2fs", t)).font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0xFBF4EC))
    }

    static func petSheet(_ rows: [Row], frames: Int, cell: CGFloat = 78, wide: Bool = false, reduced: Bool = false) -> some View {
        let width = wide ? cell * 2.3 : cell
        let scale = cell / 78
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 0) {
                    Text(row.title)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .frame(width: 84, alignment: .leading)
                    ForEach(Array(row.times(frames).enumerated()), id: \.offset) { _, t in
                        VStack(spacing: 0) {
                            Canvas { context, size in
                                let ground = size.height - 7
                                context.fill(Path(CGRect(x: 0, y: ground + 1, width: size.width, height: 1)), with: .color(.black.opacity(0.12)))
                                let home = wide ? size.width * 0.36 : size.width / 2
                                context.fill(Path(CGRect(x: home - 0.5, y: ground + 1, width: 1, height: 3)), with: .color(.black.opacity(0.2)))
                                let pose = row.pose(at: t, reduced: reduced)
                                let offset = CGFloat(pose.x * PetPoseEvaluator.bodyWidthsPerPathUnit) * PetRenderer.bodyWidth * scale
                                PetRenderer.draw(pose, in: context, at: CGPoint(x: home + offset, y: ground), scale: scale,
                                                 palette: PetPalette(.cream), accessory: nil, dark: false)
                            }
                            .frame(width: width, height: cell * 1.12)
                            .clipped()
                            Text(String(format: "%.2fs", t)).font(.system(size: 7)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(Color(hex: 0xFBF4EC))
    }

    static func companionSheet(_ animations: [CompanionAnimation], frames: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(animations, id: \.self) { animation in
                HStack(spacing: 0) {
                    Text(animation.title)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .frame(width: 70, alignment: .leading)
                    let length = animation.isLoop ? 3.0 : animation.defaultDuration
                    ForEach(0..<frames, id: \.self) { frame in
                        let t = length * Double(frame) / Double(max(1, frames - 1))
                        Canvas { context, size in
                            let pose = CompanionPoseEvaluator.pose(animation, elapsed: t, context: PoseContext(time: 10 + t, seed: 7),
                                                                   detail: CompanionDetail(waitingFor: .permission, subagents: 0))
                            CompanionRenderer.draw(pose, in: context, at: CGPoint(x: size.width / 2 - 6, y: size.height - 4), scale: 0.95,
                                                   accessory: nil, dark: false) { desk in
                                ThemeRenderer.deskFront(.cozyDesk, in: desk, dark: false, accessory: nil)
                            }
                        }
                        .frame(width: 104, height: 112)
                    }
                }
            }
        }
        .padding(6)
        .background(Color(hex: 0xFBF4EC))
    }

    /// The pet at menu-bar scale (≈ 16 pt tall) on light and dark bars: a few frames of
    /// each animation so blinks, ear twitches and tail swishes can be judged at size.
    static func tinySheet() -> some View {
        let rows: [Row] = [
            Row(.idle, length: 6, start: 20, title: "Idle"),
            Row(.walk, length: 1 / 2.2, title: "Walk"),
            Row(.run, length: 1 / 3.4, title: "Run"),
            Row(.run, length: 1 / 3.4, title: "Run").facingLeft(),
            Row(.walk, length: 1 / 2.2, title: "Walk").facingLeft(),
            Row(.play, variant: 0, title: "Play ball"),
            Row(.play, variant: 2, title: "Butterfly"),
            Row(.treat, variant: 0, title: "Treat"),
            Row(.petted, variant: 0, title: "Petted"),
            Row(.sleep, length: 6, title: "Sleep"),
            Row(.happyBounce, title: "Bounce"),
        ]
        let frames = 10
        return VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 2) {
                            Text(row.title)
                                .font(.system(size: 5, weight: .semibold, design: .rounded))
                                .foregroundStyle(dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
                                .frame(width: 26, alignment: .leading)
                            ForEach(Array(row.times(frames).enumerated()), id: \.offset) { _, t in
                                Canvas { context, size in
                                    let pose = row.pose(at: t)
                                    let scale: CGFloat = 0.3
                                    let offset = CGFloat(pose.x * PetPoseEvaluator.bodyWidthsPerPathUnit) * PetRenderer.bodyWidth * scale
                                    PetRenderer.draw(pose, in: context, at: CGPoint(x: size.width * 0.4 + offset, y: size.height - 2.5), scale: scale,
                                                     palette: PetPalette(.cream), accessory: nil, dark: dark, detail: .tiny)
                                }
                                .frame(width: 34, height: 22)
                                .clipped()
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .background(dark ? Color(hex: 0x2B2A30) : Color(hex: 0xF2F1F4))
            }
        }
    }

    // MARK: Menu-bar films

    struct BarClip {
        var animation: PetAnimation
        var variant: Int
        var length: Double

        init(_ animation: PetAnimation, variant: Int = 0, length: Double? = nil) {
            self.animation = animation
            self.variant = variant
            self.length = length ?? animation.defaultDuration
        }

        var title: String {
            PetPoseEvaluator.variantCount(animation) > 1 ? PetPoseEvaluator.variantName(animation, variant) : animation.title
        }
    }

    static let barHeight: CGFloat = 24
    static let barHeadroom: CGFloat = 12

    /// One frame of the menu bar: a 24 pt bar with "desktop" (hatched) above it, Mochi's
    /// feet 4.5 pt above the bar's bottom as in the overlay layout.
    static func barCell(dark: Bool, width: CGFloat = 34, draw: @escaping (GraphicsContext, CGPoint) -> Void) -> some View {
        Canvas { context, size in
            let top = CGRect(x: 0, y: 0, width: size.width, height: barHeadroom)
            context.fill(Path(top), with: .color(dark ? Color(hex: 0x3A4A5C) : Color(hex: 0x9FB3C8)))
            var hatch = Path()
            for k in stride(from: -20.0, to: Double(size.width) + 20, by: 3) {
                hatch.move(to: CGPoint(x: k, y: Double(barHeadroom)))
                hatch.addLine(to: CGPoint(x: k + Double(barHeadroom), y: 0))
            }
            context.stroke(hatch, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            context.fill(Path(CGRect(x: 0, y: barHeadroom, width: size.width, height: barHeight)),
                         with: .color(dark ? Color(hex: 0x2B2A30) : Color(hex: 0xF2F1F4)))
            draw(context, CGPoint(x: size.width * 0.5, y: barHeadroom + barHeight - 4.5))
        }
        .frame(width: width, height: barHeadroom + barHeight)
    }

    /// Each clip sampled over its length in menu-bar cells (the host moves Mochi itself, so
    /// one-shot travel is shown at a body width per unit of `x`, as the bar track does).
    static func barFilm(_ clips: [BarClip], frames: Int, petScale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach([false, true], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(clips.enumerated()), id: \.offset) { _, clip in
                        HStack(spacing: 1) {
                            Text(clip.title)
                                .font(.system(size: 5, weight: .semibold))
                                .foregroundStyle(dark ? Color.white.opacity(0.75) : Color.black.opacity(0.65))
                                .frame(width: 30, alignment: .leading)
                            ForEach(0..<frames, id: \.self) { i in
                                let t = clip.length * Double(i) / Double(frames - 1)
                                barCell(dark: dark) { context, origin in
                                    var pose = PetPoseEvaluator.pose(clip.animation, elapsed: t, context: PoseContext(time: 60 + t, seed: 7),
                                                                     variant: clip.variant)
                                    let x = origin.x + CGFloat(pose.x) * PetRenderer.bodyWidth * petScale
                                    pose.x = 0
                                    PetRenderer.draw(pose, in: context, at: CGPoint(x: x, y: origin.y), scale: petScale,
                                                     palette: PetPalette(.cream), accessory: nil, dark: dark, detail: .tiny)
                                }
                            }
                        }
                    }
                }
                .padding(2)
                .background(dark ? Color(hex: 0x1C1C20) : Color(hex: 0xDADDE3))
            }
        }
    }

    /// Walk and run travelling along the bar at 15 fps, right and left: separate frames,
    /// then the same frames overlaid along the path (does the gait read, or slide?).
    static func walkFilm(petScale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([false, true], id: \.self) { dark in
                let gaits: [(PetAnimation, Double)] = [(.walk, 1), (.walk, -1), (.run, 1), (.run, -1)]
                ForEach(0..<gaits.count, id: \.self) { index in
                    walkRow(gaits[index].0, facing: gaits[index].1, dark: dark, petScale: petScale)
                }
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.35))
    }

    static func walkRow(_ animation: PetAnimation, facing: Double, dark: Bool, petScale: CGFloat) -> some View {
        func pose(_ g: Double) -> PetPose {
            let p = PetPoseEvaluator.pose(animation, elapsed: g - 50, context: PoseContext(time: g, seed: 7))
            return facing < 0 ? p.mirrored() : p
        }
        return HStack(spacing: 1) {
            Text("\(animation.title) \(facing < 0 ? "←" : "→")").font(.system(size: 5)).foregroundStyle(dark ? Color.white : Color.black)
                .frame(width: 22, alignment: .leading)
            ForEach(0..<10, id: \.self) { i in
                barCell(dark: dark) { context, origin in
                    PetRenderer.draw(pose(50 + Double(i) / 15), in: context, at: origin, scale: petScale, palette: PetPalette(.cream),
                                     accessory: nil, dark: dark, detail: .tiny)
                }
            }
            barCell(dark: dark, width: 70) { context, origin in
                let speed: CGFloat = animation == .walk ? 24 : 60
                for i in 0..<10 {
                    var ghost = context
                    ghost.opacity = 0.2 + 0.8 * Double(i) / 9
                    let dx = CGFloat(i) / 15 * speed * CGFloat(facing)
                    PetRenderer.draw(pose(50 + Double(i) / 15), in: ghost, at: CGPoint(x: (facing > 0 ? 10 : 60) + dx, y: origin.y),
                                     scale: petScale, palette: PetPalette(.cream), accessory: nil, dark: dark, detail: .tiny)
                }
            }
        }
    }

    /// Idle micro-events at bar scale and 30 fps: a blink, a slow blink, an ear flick, a
    /// "listen", a tail flick and a glance, found by scanning two minutes of idle.
    static func idleFilm(petScale: CGFloat) -> some View {
        let rows = idleMoments()
        return VStack(alignment: .leading, spacing: 2) {
            ForEach([false, true], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 1) {
                            Text(row.0).font(.system(size: 5)).foregroundStyle(dark ? Color.white.opacity(0.8) : Color.black.opacity(0.7))
                                .frame(width: 22, alignment: .leading)
                            ForEach(0..<16, id: \.self) { i in
                                let g = row.1 + Double(i) / 30 * (row.2 / 0.5)
                                barCell(dark: dark) { context, origin in
                                    let pose = PetPoseEvaluator.pose(row.3, elapsed: 0, context: PoseContext(time: g, seed: 7))
                                    PetRenderer.draw(pose, in: context, at: origin, scale: petScale, palette: PetPalette(.cream),
                                                     accessory: nil, dark: dark, detail: .tiny)
                                }
                            }
                        }
                    }
                }
                .padding(2)
                .background(dark ? Color(hex: 0x1C1C20) : Color(hex: 0xDADDE3))
            }
        }
    }

    /// (title, start time, length, loop) of a few idle and sit events.
    static func idleMoments() -> [(String, Double, Double, PetAnimation)] {
        var found: [String: (Double, Double, PetAnimation)] = [:]
        var wasOpen = true
        var previous: PetPose?
        for step in 0..<(180 * 30) {
            let g = 100 + Double(step) / 30
            let p = PetPoseEvaluator.pose(.idle, elapsed: 0, context: PoseContext(time: g, seed: 7))
            if p.eyeOpenness < 0.35, wasOpen, found["blink"] == nil { found["blink"] = (g - 0.07, 0.5, .idle) }
            wasOpen = p.eyeOpenness >= 0.35
            let event = PetPoseEvaluator.idleBehaviour(at: g, seed: 7)
            if event.name == "listen", event.local < 0.05, found["listen"] == nil { found["listen"] = (g - 0.1, 1.6, .idle) }
            if event.name == "tailFlick", event.local < 0.05, found["tail"] == nil { found["tail"] = (g - 0.05, 0.9, .idle) }
            if event.name == "tailCurl", event.local < 0.05, found["tail curl"] == nil { found["tail curl"] = (g, 2.4, .idle) }
            if event.name == "weightShift", event.local < 0.05, found["shift"] == nil { found["shift"] = (g, 2.2, .idle) }
            if let q = previous, event.name == "none" {
                if max(abs(p.earLeft), abs(p.earRight)) > 0.2, max(abs(q.earLeft), abs(q.earRight)) <= 0.2, found["ear"] == nil {
                    found["ear"] = (g - 0.07, 0.5, .idle)
                }
                if abs(p.lookX - q.lookX) > 0.12, found["glance"] == nil { found["glance"] = (g - 0.1, 1.0, .idle) }
            }
            previous = p
        }
        for step in 0..<(120 * 30) {
            let g = 300 + Double(step) / 30
            let p = PetPoseEvaluator.pose(.sit, elapsed: 0, context: PoseContext(time: g, seed: 7))
            if p.mouth == .blep, found["sit blep"] == nil { found["sit blep"] = (g - 0.2, 1.2, .sit) }
            if p.eyes == .happy, found["sit squint"] == nil { found["sit squint"] = (g - 0.3, 2.0, .sit) }
        }
        let order = ["blink", "ear", "listen", "glance", "tail", "tail curl", "shift", "sit blep", "sit squint"]
        return order.compactMap { name in found[name].map { (name, $0.0, $0.1, $0.2) } }
    }
}
