import AppKit
import SwiftUI
import TamagotchiCore
import TamagotchiWire

/// Development tool: offscreen renders of Mochi's menu-bar life, so motion and
/// legibility can be judged without screen recording.
/// `MacTamagotchi --render-menubar <dir>` writes:
/// - `menubar-bands-light.png`, `menubar-bands-dark.png`: the whole bar right of the notch (with
///   plausible icons and the clock) at moments of a simulated afternoon and Claude Code session
/// - `menubar-activities.png`: each roaming activity as a strip of frames following Mochi
/// - `menubar-games.png`: Play, Treat and the popover follow-ups, as the user would start them
/// - `menubar-gait.png`: walking, running, a zoomies skid and the hop into bed, 3× at 30 fps
/// - `menubar-life.png`: ten seconds of a rest, 4×, every 0.25 s (blinks, breathing, glances)
/// - `menubar-patch-light.png`, `menubar-patch-dark.png`: home with mini Patch arriving, working,
///   waiting (wave, then a calm watch), celebrating
/// - `menubar-stage.png`: the in-status-item style at its three widths
/// - `menubar-zoom.png`: Mochi on the bar at 4×
/// - `menubar-timeline.png`: Mochi's position over 60 s and 10 min of roaming, icons shaded
/// and prints a few statistics (time over other apps' icons, rests, bursts).
@MainActor
enum MenuBarStageSnapshots {
    // The geometry measured on a notched MacBook (built-in display 1470 × 956 pt).
    static let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    static let notchLeft = CGRect(x: 0, y: 924, width: 645.5, height: 32)
    static let notchRight = CGRect(x: 824.5, y: 924, width: 645.5, height: 32)
    /// The visible bar in the sheets: from the notch to the screen's edge.
    static let barSpan = (minX: 824.5, maxX: 1470.0)

    static func geometry(companion: Bool, range: Double? = nil) -> MenuBarGeometry {
        let width = RoamGeometry.homeSlotWidth(companion: companion)
        let item = CGRect(x: 977 - width, y: 928.5, width: width, height: 22)
        let bar = CGRect(x: item.minX - 8, y: 923, width: width + 16, height: 33)
        return RoamGeometry.compute(screenFrame: screen, notchLeftArea: notchLeft, notchRightArea: notchRight, barWindowFrame: bar,
                                    itemFrame: item, range: range)!
    }

    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = simulateSession(workDirectory: directory.appendingPathComponent(".work"))
        for dark in [false, true] {
            SnapshotRenderer.write(bandSheet(session, dark: dark), to: directory.appendingPathComponent("menubar-bands-\(dark ? "dark" : "light").png"), scale: 2)
            SnapshotRenderer.write(patchSheet(session, dark: dark), to: directory.appendingPathComponent("menubar-patch-\(dark ? "dark" : "light").png"), scale: 2)
        }
        SnapshotRenderer.write(activitySheet(), to: directory.appendingPathComponent("menubar-activities.png"), scale: 2)
        SnapshotRenderer.write(gamesSheet(), to: directory.appendingPathComponent("menubar-games.png"), scale: 2)
        SnapshotRenderer.write(gaitSheet(), to: directory.appendingPathComponent("menubar-gait.png"), scale: 3)
        SnapshotRenderer.write(lifeSheet(), to: directory.appendingPathComponent("menubar-life.png"), scale: 4)
        SnapshotRenderer.write(stageSheet(), to: directory.appendingPathComponent("menubar-stage.png"), scale: 2)
        SnapshotRenderer.write(zoomSheet(session), to: directory.appendingPathComponent("menubar-zoom.png"), scale: 4)
        SnapshotRenderer.write(timelineSheet(), to: directory.appendingPathComponent("menubar-timeline.png"), scale: 2)
        printStatistics()
        benchmark()
        print("Menu bar stage snapshots written to \(directory.path)")
    }

    /// Times the live rendering path (signatures, ImageRenderer into reused bitmaps) for a rest at
    /// home at 12 fps and a ball game at 24 fps, with the halo drawn into the sprites or not.
    static func benchmark() {
        let geometry = geometry(companion: false)
        func run(_ title: String, fps: Double, seconds: Double, halo: Bool, prepare: (inout MenuBarRoamer, TimeInterval) -> Void) {
            let view = MenuBarStageView(frame: NSRect(origin: .zero, size: geometry.overlayFrame.size))
            view.canvasHalo = halo
            view.layout = MenuBarLayout.overlay(geometry)
            var roamer = MenuBarRoamer(seed: 9)
            var t = 1_000.0
            roamer.setZone(geometry.zone, now: t, context: RoamContext())
            prepare(&roamer, t)
            for _ in 0..<12 {
                t += 0.25
                roamer.update(now: t, context: RoamContext())
            }
            let start = ProcessInfo.processInfo.systemUptime
            var frames = 0
            var clock = t
            let end = t + seconds
            while t < end {
                if t >= clock + 0.25 {
                    clock = t
                    roamer.update(now: t, context: RoamContext())
                }
                view.render(blankSnapshot(roamer), time: t, dark: false)
                frames += 1
                t += 1 / fps
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            print(String(format: "Bench %@ (halo %@): %d frames, %d renders, %.2f ms per frame, %.2f ms per render, %.1f%% of a core at %.0f fps",
                         title, halo ? "on" : "off", frames, view.renders, elapsed / Double(frames) * 1000,
                         elapsed / Double(max(1, view.renders)) * 1000, elapsed / seconds * 100, fps))
        }
        // Which pose channels make a rest re-render (the busiest first).
        do {
            let layout = MenuBarLayout.overlay(geometry)
            var roamer = MenuBarRoamer(seed: 9)
            var t = 1_000.0
            roamer.setZone(geometry.zone, now: t, context: RoamContext())
            roamer.place(at: geometry.zone.homeX, now: t)
            for _ in 0..<12 {
                t += 0.25
                roamer.update(now: t, context: RoamContext())
            }
            var counts: [String: Int] = [:]
            var previous: [String: Int32] = [:]
            for _ in 0..<300 {
                t += 0.1
                let frame = MenuBarPetCanvas.frame(blankSnapshot(roamer), layout: layout, time: t)
                var current: [String: Int32] = [:]
                for child in Mirror(reflecting: frame.pet).children {
                    guard let label = child.label else { continue }
                    var one = PoseSignature()
                    if let value = child.value as? Double { one.add(value, PoseSignature.petSteps[label] ?? 0.02) } else { one.add(String(describing: child.value)) }
                    current[label] = one.values.first ?? 0
                }
                current["petX"] = Int32((Double(frame.petX) / 0.2).rounded())
                for (key, value) in current where previous[key] != nil && previous[key] != value { counts[key, default: 0] += 1 }
                previous = current
            }
            print("Rest changes per 30 s at 10 fps by channel: " + counts.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        for halo in [true, false] {
            run("rest", fps: 12, seconds: 30, halo: halo) { roamer, t in roamer.place(at: geometry.zone.homeX, now: t) }
            run("ball", fps: 24, seconds: 12, halo: halo) { roamer, t in roamer.force(.ballPlay, now: t, context: RoamContext()) }
            run("zoomies", fps: 30, seconds: 8, halo: halo) { roamer, t in roamer.force(.zoomies, now: t, context: RoamContext()) }
            run("wander", fps: 20, seconds: 10, halo: halo) { roamer, t in roamer.force(.wander, now: t, context: RoamContext()) }
        }
    }

    // MARK: A simulated session through the real world

    struct Moment {
        var title: String
        var time: TimeInterval
        var snapshot: MenuBarSnapshot
        var layout: MenuBarLayout
    }

    final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var uptime: TimeInterval = 1_000
        func advance(_ seconds: TimeInterval) {
            date = date.addingTimeInterval(seconds)
            uptime += seconds
        }
    }

    /// Runs a world with a manual clock: free roaming, the user's Play and Treat, then a
    /// Claude Code session (arrival, work, a permission prompt, completion, a tool failure).
    static func simulateSession(workDirectory work: URL) -> [Moment] {
        let clock = Clock()
        let journal = EventJournal(fileURL: work.appendingPathComponent("history.jsonl"), retention: .init(days: 1))
        let world = CompanionWorld(journal: journal, achievements: AchievementEngine(state: ProgressState()), settingsStore: SettingsStore(fileURL: nil),
                                   seed: 7, clock: { clock.date }, uptime: { clock.uptime })
        var companion = false
        var current = geometry(companion: false)
        world.setRoamZone(current.zone)
        var moments: [Moment] = []
        var toolCounter = 0

        func syncGeometry() {
            if world.companionPresent != companion {
                companion = world.companionPresent
                current = geometry(companion: companion)
                world.setRoamZone(current.zone)
            }
        }
        func run(_ seconds: TimeInterval) {
            var elapsed = 0.0
            while elapsed < seconds - 1e-9 {
                clock.advance(0.25)
                world.tick()
                syncGeometry()
                elapsed += 0.25
            }
        }
        func send(_ name: String, tool: String? = nil, configure: (inout WireEvent) -> Void = { _ in }) {
            var wire = WireEvent(id: UUID().uuidString, ts: clock.date.timeIntervalSince1970, origin: .simulator, event: name, session: "sim-menubar")
            wire.project = "InsideEdge"
            wire.projectKey = "insideedge"
            if let tool {
                toolCounter += 1
                wire.tool = tool
                wire.toolCategory = ToolCategoryClassifier.category(forTool: tool)
                wire.toolUseId = "toolu_\(toolCounter)"
            }
            configure(&wire)
            world.ingest(wire)
            world.tick()
            syncGeometry()
        }
        func capture(_ title: String, after delay: TimeInterval = 0) {
            if delay > 0 { run(delay) }
            moments.append(Moment(title: title, time: clock.uptime, snapshot: MenuBarSnapshot(world: world), layout: .overlay(current)))
        }

        capture("Launch: hopping into bed", after: 0.1)
        capture("Home", after: 1.2)
        // Free roaming: capture whatever Mochi gets up to, at varied moments.
        var lastActivity: RoamActivity?
        var steps = 0
        while steps < 900, moments.count < 10 {
            run(0.25)
            steps += 1
            let sample = world.roamer.sample(at: clock.uptime)
            if sample.activity != lastActivity, sample.activity != .rest {
                lastActivity = sample.activity
                run(1.6)
                capture(world.roamer.sample(at: clock.uptime).activity.title)
            }
        }
        run(40)
        capture("Resting (somewhere free)")
        for activity in [RoamActivity.ballPlay, .chaseButterfly, .zoomies] {
            world.forceRoamActivity(activity)
            capture(activity.title, after: activity == .zoomies ? 2.2 : 3.2)
            run(9)
        }
        // The user plays and gives a treat from the menu-bar item's menu.
        run(20)
        world.interact(.play)
        capture("You: Play (ball tossed from the bed)", after: 0.5)
        capture("Play: chase", after: 2.0)
        run(14)
        world.interact(.treat)
        capture("You: Treat (lands in front)", after: 0.55)
        capture("Treat: munching", after: 2.6)
        run(12)
        // A Claude Code session starts: Patch arrives and Mochi heads home.
        world.placeRoamer(at: 1_160)
        run(1)
        send("SessionStart") { $0.source = "startup" }
        capture("Session starts: Patch arrives", after: 0.6)
        capture("Mochi runs home", after: 1.0)
        capture("Hello, Patch", after: 1.6)
        run(4)
        send("UserPromptSubmit")
        send("PreToolUse", tool: "Edit")
        capture("Claude works: Mochi watches Patch", after: 2.0)
        capture("Working (antenna blinks)", after: 0.9)
        send("PostToolUse", tool: "Edit")
        send("PermissionRequest", tool: "Bash")
        send("Notification") {
            $0.notificationType = "permission_prompt"
            $0.message = "Claude needs your permission to use Bash"
        }
        capture("Claude waits: a wave", after: 2.5)
        capture("Still waiting: calm watch", after: 9)
        send("PostToolUse", tool: "Bash")
        run(2)
        send("Stop")
        capture("Turn complete: high five", after: 0.9)
        capture("Celebration", after: 0.6)
        run(8)
        send("UserPromptSubmit")
        send("PreToolUse", tool: "Bash")
        send("PostToolUseFailure", tool: "Bash") { $0.exitCode = 1 }
        capture("A tool failed", after: 0.7)
        send("Stop")
        run(30)
        capture("Patch around, Claude idle")
        try? FileManager.default.removeItem(at: work)
        return moments
    }

    // MARK: Drawing helpers

    struct Icon {
        var x: Double
        var symbol: String?
        var text: String?
    }

    /// Other apps' status items right of Mochi's (where the real ones are), and the clock.
    static let icons: [Icon] = [
        Icon(x: 990, symbol: "chevron.left.2"), Icon(x: 1018, symbol: "hand.raised"), Icon(x: 1048, symbol: "asterisk"),
        Icon(x: 1082, symbol: "record.circle"), Icon(x: 1118, symbol: "cloud.moon"), Icon(x: 1146, text: "23°C"),
        Icon(x: 1180, symbol: "wave.3.right"), Icon(x: 1208, symbol: "speaker.wave.2"), Icon(x: 1238, symbol: "link"),
        Icon(x: 1268, text: "91"), Icon(x: 1300, symbol: "switch.2"), Icon(x: 1392, text: "Tue 27 Oct  9:58 PM"),
        Icon(x: 1458, symbol: "circle.circle"),
    ]

    /// A plausible menu bar behind the stage: wallpaper-tinted band and other status icons.
    static func drawBar(_ g: GraphicsContext, size: CGSize, originX: CGFloat, dark: Bool) {
        let top = dark ? Color(hex: 0x262B36) : Color(hex: 0xEAF2F7)
        let bottom = dark ? Color(hex: 0x1D212A) : Color(hex: 0xDCE7EE)
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: .zero,
                                                                             endPoint: CGPoint(x: 0, y: size.height)))
        let ink = dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
        let mid = size.height / 2
        for icon in icons {
            let local = CGFloat(icon.x) - originX
            guard local > -80, local < size.width + 80 else { continue }
            if let symbol = icon.symbol {
                g.symbol(symbol, in: CGRect(x: local - 7, y: mid - 7, width: 14, height: 14), color: ink)
            }
            if let text = icon.text {
                g.draw(Text(text).font(.system(size: 12.5, weight: .medium)).foregroundColor(ink), at: CGPoint(x: local, y: mid), anchor: .center)
            }
        }
    }

    /// The status item's own picture in the roaming style (what the real item shows under the overlay).
    static func drawHomeImage(_ g: GraphicsContext, layout: MenuBarLayout, badge: AttentionLevel?, dark: Bool) {
        guard !layout.isStage else { return }
        let image = MenuBarLayout.homeImageLayout(slotWidth: layout.slot.width, slotHeight: layout.slot.height, roomy: layout.petScale >= 0.279)
        var item = g
        item.translateBy(x: layout.slot.minX, y: layout.slot.minY)
        MenuBarPetCanvas.drawBed(in: item, center: CGPoint(x: image.homeX, y: image.baseline), scale: image.toyScale, dark: dark)
        if let badge { MenuBarPetCanvas.drawBadge(badge, at: MenuBarPetCanvas.badgePoint(image), dark: dark, in: item) }
    }

    /// The whole visible bar (notch to screen edge) with the overlay drawn where it really is.
    static func band(_ moment: Moment, dark: Bool, time: TimeInterval? = nil, crop: CGRect? = nil, full: Bool = true) -> some View {
        let layout = moment.layout
        // Bar coordinates: x from the notch.
        let barWidth = CGFloat(barSpan.maxX - barSpan.minX)
        let overlayOffset = CGFloat(layout.originX - barSpan.minX)
        let rect = crop ?? CGRect(x: 0, y: 0, width: full ? barWidth : layout.size.width, height: layout.size.height)
        return Canvas { g, _ in
            var context = g
            context.translateBy(x: -rect.minX, y: -rect.minY)
            drawBar(context, size: CGSize(width: barWidth, height: layout.size.height), originX: CGFloat(barSpan.minX), dark: dark)
            var overlay = context
            overlay.translateBy(x: overlayOffset, y: 0)
            drawHomeImage(overlay, layout: layout, badge: moment.snapshot.status.badge, dark: dark)
            let t = time ?? moment.time
            let frame = MenuBarPetCanvas.frame(moment.snapshot, layout: layout, time: t)
            MenuBarPetCanvas.draw(frame, snapshot: moment.snapshot, layout: layout, part: .all, in: overlay, dark: dark)
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
    }

    /// Bar-coordinate x (from the notch) of a layout-local x.
    static func barX(_ local: CGFloat, layout: MenuBarLayout) -> CGFloat { local + CGFloat(layout.originX - barSpan.minX) }

    static func label(_ text: String, dark: Bool, width: CGFloat = 150) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.75))
            .frame(width: width, alignment: .leading)
    }

    // MARK: Sheets

    static func bandSheet(_ moments: [Moment], dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(moments.enumerated()), id: \.offset) { _, moment in
                HStack(spacing: 6) {
                    label(moment.title, dark: dark, width: 170)
                    band(moment, dark: dark)
                }
            }
        }
        .padding(6)
        .background(dark ? Color(hex: 0x111318) : Color.white)
    }

    static func patchSheet(_ moments: [Moment], dark: Bool) -> some View {
        let session = moments.filter { $0.snapshot.companionPresent || $0.title.hasPrefix("Session") }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(session.enumerated()), id: \.offset) { _, moment in
                HStack(spacing: 2) {
                    label(moment.title, dark: dark, width: 150)
                    ForEach(0..<6, id: \.self) { index in
                        let home = barX(moment.layout.homeX, layout: moment.layout)
                        let crop = CGRect(x: home - 78, y: 0, width: 110, height: moment.layout.size.height)
                        band(moment, dark: dark, time: moment.time + Double(index) * 0.25, crop: crop)
                    }
                }
            }
        }
        .padding(6)
        .background(dark ? Color(hex: 0x111318) : Color.white)
    }

    static func zoomSheet(_ moments: [Moment]) -> some View {
        let picks = Array(moments.prefix(10))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 2) {
                    ForEach(Array(picks.enumerated()), id: \.offset) { _, moment in
                        let frame = MenuBarPetCanvas.frame(moment.snapshot, layout: moment.layout, time: moment.time)
                        let x = barX(frame.petX, layout: moment.layout)
                        let crop = CGRect(x: x - 22, y: 0, width: 44, height: moment.layout.size.height)
                        band(moment, dark: dark, crop: crop)
                    }
                }
            }
        }
        .padding(3)
        .background(Color.gray.opacity(0.3))
    }

    // MARK: Following one activity

    struct Strip {
        var title: String
        var start: TimeInterval
        var duration: TimeInterval
        var frames: [(moment: Moment, time: TimeInterval, crop: CGRect)]
    }

    static func blankSnapshot(_ roamer: MenuBarRoamer, companion: Bool = false, working: Bool = false, badge: AttentionLevel? = nil) -> MenuBarSnapshot {
        let pet = CharacterAnimator<PetAnimation>(base: .idle, at: 0).current
        let patch = CharacterAnimator<CompanionAnimation>(base: companion ? (working ? .typing : .idleAtDesk) : .absent, at: 0).current
        let status = MenuBarStatus(mood: .content, companionVisible: companion, companionWorking: working, badge: badge,
                                   celebrationStartedAt: nil, simulated: false)
        return MenuBarSnapshot(roamer: roamer, pet: pet, companion: patch, companionPresent: companion, status: status)
    }

    /// Frames following Mochi through `run`, which is given a roamer that has been roaming a while.
    static func strip(_ title: String, seed: UInt64 = 3, frames count: Int = 12, cropWidth: CGFloat = 96, context: RoamContext = RoamContext(),
                      _ start: (inout MenuBarRoamer, TimeInterval) -> (activity: RoamActivity?, until: TimeInterval?)) -> Strip {
        let geometry = geometry(companion: context.companionPresent)
        let layout = MenuBarLayout.overlay(geometry)
        var roamer = MenuBarRoamer(seed: seed)
        var t = 1_000.0
        roamer.setZone(geometry.zone, now: t, context: context)
        for _ in 0..<8 {
            t += 0.25
            roamer.update(now: t, context: context)
        }
        let result = start(&roamer, t)
        let first = result.activity.flatMap { activity in roamer.segments.first { $0.activity == activity }?.start } ?? t
        let last = result.until ?? result.activity.flatMap { activity in roamer.segments.last { $0.activity == activity }?.end } ?? first + 4
        let duration = max(1, min(last, first + 60) - first)
        var frames: [(Moment, TimeInterval, CGRect)] = []
        var current = roamer
        var clock = t
        for index in 0..<count {
            let time = first + duration * Double(index) / Double(count - 1)
            while clock < time {
                clock += 0.25
                current.update(now: clock, context: context)
            }
            let snapshot = blankSnapshot(current, companion: context.companionPresent, working: context.activity == .working)
            let sample = current.sample(at: time)
            var focus = barX(layout.local(sample.x), layout: layout)
            if let prop = sample.props.first { focus = (focus + barX(layout.local(prop.x), layout: layout)) / 2 }
            let crop = CGRect(x: focus - cropWidth / 2, y: 0, width: cropWidth, height: layout.size.height)
            frames.append((Moment(title: title, time: time, snapshot: snapshot, layout: layout), time, crop))
        }
        return Strip(title: title, start: first, duration: duration, frames: frames.map { (moment: $0.0, time: $0.1, crop: $0.2) })
    }

    static func stripSheet(_ strips: [Strip], dark: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(strips.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 1) {
                    label("\(row.title) (\(String(format: "%.0f", row.duration)) s)", dark: dark, width: 130)
                    ForEach(Array(row.frames.enumerated()), id: \.offset) { _, frame in
                        VStack(spacing: 0) {
                            band(frame.moment, dark: dark, time: frame.time, crop: frame.crop)
                            Text(String(format: "%.1fs", frame.time - row.start)).font(.system(size: 6)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(dark ? Color(hex: 0x111318) : Color.white)
    }

    /// Each roaming activity, followed through time.
    static func activitySheet() -> some View {
        let activities: [RoamActivity] = [.wander, .sniffAround, .zoomies, .ballPlay, .yarnPlay, .chaseButterfly, .leafPlay, .fidget, .nap,
                                          .sleepAtHome, .trotHome]
        let strips = activities.map { activity in
            strip(activity.title) { roamer, t in
                roamer.force(activity, now: t, context: RoamContext())
                return (activity, nil)
            }
        }
        return stripSheet(strips)
    }

    /// The games the user starts: from the bed, and from out on the bar.
    static func gamesSheet() -> some View {
        var strips: [Strip] = []
        for (game, title) in [(RoamUserGame.play, "Play"), (.treat, "Treat"), (.playFollowUp, "After Play in the popover"),
                              (.treatFollowUp, "After a Treat in the popover")] {
            for away in [false, true] where !(away && (game == .playFollowUp || game == .treatFollowUp)) {
                strips.append(strip("\(title)\(away ? " (Mochi out on the bar)" : " (Mochi in bed)")", seed: 6, frames: 14, cropWidth: 120) { roamer, t in
                    if away { roamer.place(at: 1_150, now: t) } else { roamer.place(at: roamer.zone!.homeX, now: t) }
                    roamer.startUserGame(game, now: t, context: RoamContext())
                    return (game.activity, roamer.userGameUntil)
                })
            }
        }
        return stripSheet(strips)
    }

    /// Gaits and accents at 30 fps, following Mochi closely.
    static func gaitSheet() -> some View {
        func motion(_ title: String, seconds: Double, offset: Double = 0, _ start: @escaping (inout MenuBarRoamer, TimeInterval) -> Void) -> Strip {
            var made = strip(title, frames: 16, cropWidth: 48) { roamer, t in
                start(&roamer, t)
                return (nil, nil)
            }
            // Re-sample densely: 16 frames at 30 fps.
            guard let base = made.frames.first else { return made }
            var roamer = base.moment.snapshot.roamer
            let layout = base.moment.layout
            let t0 = made.start + offset
            var frames: [(moment: Moment, time: TimeInterval, crop: CGRect)] = []
            var clock = made.start
            for index in 0..<16 {
                let time = t0 + Double(index) / 30 * (seconds / (16.0 / 30))
                while clock < time {
                    clock += 0.25
                    roamer.update(now: clock, context: RoamContext())
                }
                let sample = roamer.sample(at: time)
                let x = barX(layout.local(sample.x), layout: layout)
                frames.append((Moment(title: title, time: time, snapshot: blankSnapshot(roamer), layout: layout), time,
                               CGRect(x: x - 24, y: 0, width: 48, height: layout.size.height)))
            }
            made.frames = frames
            made.start = t0
            made.duration = seconds
            return made
        }
        let strips = [
            motion("Walk (bob locked to steps)", seconds: 16.0 / 30, offset: 0.6) { roamer, t in
                roamer.place(at: 900, now: t)
                roamer.force(.wander, now: t, context: RoamContext())
            },
            motion("Zoomies: crouch, launch", seconds: 16.0 / 30, offset: 1.0) { roamer, t in
                roamer.place(at: 900, now: t)
                roamer.force(.zoomies, now: t, context: RoamContext())
            },
            motion("Zoomies: run", seconds: 16.0 / 30, offset: 1.6) { roamer, t in
                roamer.place(at: 900, now: t)
                roamer.force(.zoomies, now: t, context: RoamContext())
            },
            motion("Launch: the hop into bed", seconds: 1.0) { roamer, t in
                roamer.setZone(nil, now: t, context: RoamContext())
                roamer.setZone(geometry(companion: false).zone, now: t, context: RoamContext())
            },
        ]
        return stripSheet(strips)
    }

    /// Ten seconds of a rest, four frames a second: blinks, breathing, glances, ear and tail flicks.
    static func lifeSheet() -> some View {
        let geometry = geometry(companion: false)
        let layout = MenuBarLayout.overlay(geometry)
        var roamer = MenuBarRoamer(seed: 9)
        let context = RoamContext()
        var t = 1_000.0
        roamer.setZone(geometry.zone, now: t, context: context)
        roamer.place(at: 905, now: t)
        // A calm sit: Mochi rests at a free spot.
        for _ in 0..<12 {
            t += 0.25
            roamer.update(now: t, context: RoamContext(paused: true))
        }
        let snapshot = blankSnapshot(roamer)
        let sample = roamer.sample(at: t)
        let x = barX(layout.local(sample.x), layout: layout)
        let moment = Moment(title: "rest", time: t, snapshot: snapshot, layout: layout)
        return VStack(alignment: .leading, spacing: 2) {
            Text("A rest at home (paused), every 0.25 s for 10 s").font(.system(size: 6, weight: .semibold))
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 1) {
                    ForEach(0..<10, id: \.self) { column in
                        let time = t + Double(row * 10 + column) * 0.25
                        VStack(spacing: 0) {
                            band(moment, dark: false, time: time, crop: CGRect(x: x - 16, y: 0, width: 32, height: layout.size.height))
                            Text(String(format: "%.2f", time - t)).font(.system(size: 3.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(3)
        .background(Color.white)
    }

    /// The in-status-item style at its three widths, alone and with Patch.
    static func stageSheet() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach([false, true], id: \.self) { dark in
                ForEach(MenuBarStageWidth.allCases) { width in
                    HStack(spacing: 4) {
                        label("\(width.title) · \(Int(width.points)) pt", dark: dark, width: 80)
                        ForEach(0..<8, id: \.self) { index in
                            let moment = stageMoment(width: CGFloat(width.points), step: index, companion: index >= 5)
                            Canvas { g, size in
                                let top = dark ? Color(hex: 0x262B36) : Color(hex: 0xEAF2F7)
                                g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(top))
                                let frame = MenuBarPetCanvas.frame(moment.snapshot, layout: moment.layout, time: moment.time)
                                MenuBarPetCanvas.draw(frame, snapshot: moment.snapshot, layout: moment.layout, part: .all, in: g, dark: dark)
                            }
                            .frame(width: CGFloat(width.points), height: 22)
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(Color.gray.opacity(0.25))
    }

    static func stageMoment(width: CGFloat, step: Int, companion: Bool) -> Moment {
        let layout = MenuBarLayout.stage(width: width)
        let zone = RoamGeometry.stageZone(width: Double(width))
        var roamer = MenuBarRoamer(seed: 5)
        let context = RoamContext(companionPresent: companion, activity: companion && step == 6 ? .working : .idle)
        var t = 1_000.0
        roamer.setZone(zone, now: t, context: context)
        let activities: [RoamActivity] = [.wander, .ballPlay, .sniffAround, .zoomies, .nap]
        if !companion { roamer.force(activities[step % activities.count], now: t, context: context) }
        let target = t + 3.2 + Double(step) * 0.7
        while t < target {
            t += 0.25
            roamer.update(now: t, context: context)
        }
        let snapshot = blankSnapshot(roamer, companion: companion, working: companion && step == 6, badge: step == 7 ? .attention : nil)
        return Moment(title: "stage", time: t, snapshot: snapshot, layout: layout)
    }

    // MARK: Timeline and statistics

    static func timelineSheet() -> some View {
        let geometry = geometry(companion: false)
        let short = track(seconds: 60, zone: geometry.zone)
        let long = track(seconds: 600, zone: geometry.zone)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Mochi's x on the menu bar (bottom = notch edge, top = clock guard; dashed = bed; shaded = other apps' icons) — 60 s and 10 min, seed 7")
                .font(.system(size: 10, weight: .semibold))
            timeline(short, zone: geometry.zone, seconds: 60)
            timeline(long, zone: geometry.zone, seconds: 600)
            HStack(spacing: 10) {
                ForEach(legend, id: \.0) { item in
                    HStack(spacing: 3) {
                        Circle().fill(item.1).frame(width: 7, height: 7)
                        Text(item.0).font(.system(size: 8))
                    }
                }
            }
        }
        .padding(8)
        .background(Color.white)
    }

    static let legend: [(String, Color)] = [("rest", .gray), ("walk/sniff", .blue), ("play", .orange), ("zoomies", .red), ("nap/sleep", .purple),
                                            ("home/other", .green)]

    static func color(for activity: RoamActivity) -> Color {
        switch activity {
        case .rest, .pausedRest, .hold: return .gray
        case .wander, .sniffAround, .fidget: return .blue
        case .ballPlay, .yarnPlay, .chaseButterfly, .leafPlay, .userPlay, .followUpPlay: return .orange
        case .zoomies: return .red
        case .nap, .sleepAtHome: return .purple
        default: return .green
        }
    }

    static func track(seconds: Double, zone: RoamZone, seed: UInt64 = 7) -> [(Double, Double, RoamActivity, Double)] {
        var roamer = MenuBarRoamer(seed: seed)
        let context = RoamContext()
        roamer.setZone(zone, now: 0, context: context)
        var points: [(Double, Double, RoamActivity, Double)] = []
        var t = 0.0
        var nextTick = 0.0
        while t <= seconds {
            if t >= nextTick {
                roamer.update(now: t, context: context)
                nextTick += 0.25
            }
            let sample = roamer.sample(at: t)
            points.append((t, sample.x, sample.activity, sample.speed))
            t += 0.1
        }
        return points
    }

    static func timeline(_ points: [(Double, Double, RoamActivity, Double)], zone: RoamZone, seconds: Double) -> some View {
        Canvas { g, size in
            g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0xF6F7F9)))
            func y(_ x: Double) -> CGFloat { size.height - 4 - CGFloat((x - zone.minX) / zone.width) * (size.height - 8) }
            func x(_ t: Double) -> CGFloat { 4 + CGFloat(t / seconds) * (size.width - 8) }
            for block in zone.occupied {
                let top = y(min(zone.maxX, block.upperBound))
                let bottom = y(max(zone.minX, block.lowerBound))
                g.fill(Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)), with: .color(Color.orange.opacity(0.08)))
            }
            var home = Path()
            home.move(to: CGPoint(x: 0, y: y(zone.homeX)))
            home.addLine(to: CGPoint(x: size.width, y: y(zone.homeX)))
            g.stroke(home, with: .color(.green.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            for (a, b) in zip(points, points.dropFirst()) {
                var segment = Path()
                segment.move(to: CGPoint(x: x(a.0), y: y(a.1)))
                segment.addLine(to: CGPoint(x: x(b.0), y: y(b.1)))
                g.stroke(segment, with: .color(color(for: a.2)), lineWidth: 2)
            }
            let ticks = seconds <= 60 ? stride(from: 0.0, through: seconds, by: 10) : stride(from: 0.0, through: seconds, by: 60)
            for tick in ticks {
                g.draw(Text("\(Int(tick))s").font(.system(size: 7)).foregroundColor(.secondary), at: CGPoint(x: x(tick), y: size.height - 2), anchor: .bottom)
            }
        }
        .frame(width: 900, height: 120)
    }

    /// Prints how Mochi spends 30 minutes (five seeds): where it stands still, rests and bursts.
    static func printStatistics() {
        let zone = geometry(companion: false).zone
        var still = 0.0
        var stillOverIcons = 0.0
        var over = 0.0
        var total = 0.0
        var restRuns: [Double] = []
        var burstRuns: [Double] = []
        for seed in 1...5 as ClosedRange<UInt64> {
            var restRun = 0.0
            var burstRun = 0.0
            for point in track(seconds: 1_800, zone: zone, seed: seed) {
                total += 0.1
                if zone.isOccupied(point.1) { over += 0.1 }
                if point.3 < 0.5 {
                    still += 0.1
                    if zone.isOccupied(point.1) { stillOverIcons += 0.1 }
                }
                if point.2 == .rest {
                    restRun += 0.1
                    if burstRun > 0 { burstRuns.append(burstRun); burstRun = 0 }
                } else {
                    burstRun += 0.1
                    if restRun > 0 { restRuns.append(restRun); restRun = 0 }
                }
            }
        }
        func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
        print(String(format: "Roaming stats (5 × 30 min): over other icons %.1f%% of the time, still over icons %.1f%% of the still time; " +
                     "median rest %.0f s, median burst %.0f s", over / total * 100, stillOverIcons / max(1, still) * 100,
                     median(restRuns.filter { $0 > 3 }), median(burstRuns.filter { $0 > 1 })))
    }
}
