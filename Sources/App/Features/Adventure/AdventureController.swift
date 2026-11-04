import AppKit
import SwiftUI
import TamagotchiCore

/// Mochi's desktop adventures: leaving the menu bar to walk along window tops, sit on the Dock,
/// climb screen edges and hop back home.
///
/// Mochi sets off when you choose Explore, when you drag it down off the bar, or now and then by
/// itself while nothing is going on. While (and only while) it is out, the frames of other apps'
/// windows are read three times a second — position, layer, opacity and owning process, never
/// titles or contents — to find window tops to walk on. Everything is torn down once it is home.
@MainActor
final class AdventureController: MenuBarPointerHandling {
    private unowned let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }
    private var settings: AppSettings { environment.settingsStore.settings }

    /// One trip off the bar.
    private struct Outing {
        var screen: NSScreen
        var terrain: AdventureTerrain
        var metrics: AdventurePlanner.Metrics
        var scale: CGFloat
        /// The stretch of menu bar Mochi comes back to (screen x).
        var bar: ClosedRange<Double>
        /// Screen x of the roaming zone's origin (the status item's left edge in the in-item style).
        var barOrigin: Double
        var plan: AdventurePlan?
        var carry: Carry?
        var seed: UInt64
        var companionWasPresent: Bool
        var hurrying = false
        /// The last segment whose line was said.
        var spoken: TimeInterval = -.infinity
    }

    /// Mochi hanging from the pointer by the scruff.
    private struct Carry {
        var startedAt: TimeInterval
        var fromBar: Bool
        var facing: Double
        var swing = 0.0
        var swingSpeed = 0.0
        var lastX: Double
        var lastTime: TimeInterval
    }

    private var outing: Outing?
    private var panel: AdventurePanel?
    private let stage = AdventureStageView(frame: .zero)
    private var renderTimer: Timer?
    private var renderRate = 0.0
    private var surveyTimer: Timer?
    private var spontaneityTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var scheduler: AdventureScheduler
    private var lastConditionCheck: TimeInterval = 0
    /// A press on Mochi out on the desktop, and whether it became a drag.
    private var press: (start: CGPoint, lifted: Bool)?
    private var surveys = 0
    /// Development only: stands in for the pointer while carrying (debug requests).
    private var debugPointer: CGPoint?

    /// Surveys of other windows' frames while Mochi is out (per second).
    static let surveyRate = 3.0

    init(environment: AppEnvironment) {
        self.environment = environment
        scheduler = AdventureScheduler(seed: environment.world.seed, frequency: environment.settingsStore.settings.adventure.spontaneous)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.considerSettingOff() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        spontaneityTimer = timer
        registerDebugHooks()
    }

    var isExploring: Bool { outing != nil || environment.world.adventureActive }

    /// Explore from the popover or the menu; while Mochi is out, the same command calls it home.
    func beginAdventure() {
        if outing != nil {
            endAdventure()
            return
        }
        let name = settings.petName
        guard settings.adventure.enabled else {
            world.showToast(title: "Adventures are off", detail: "Turn them on in Settings › Fun to let \(name) explore.")
            return
        }
        guard !world.reducedMotion else {
            world.showToast(title: "\(name) stays home", detail: "Adventures rest while Reduce Motion is on.")
            return
        }
        if !setOff(carriedFrom: nil) {
            world.showToast(title: "Nowhere to explore", detail: "\(name) can only set off from a menu bar that is showing.")
        }
    }

    /// Mochi hurries home (one big leap back up into the menu bar).
    func endAdventure() {
        guard var outing else { return }
        if outing.carry != nil {
            finish(returningAt: nil)
            return
        }
        guard let plan = outing.plan, !outing.hurrying else { return }
        outing.plan = AdventurePlanner.hurryHome(plan, at: now, terrain: outing.terrain, metrics: outing.metrics)
        outing.hurrying = true
        self.outing = outing
        setRenderRate(30)
    }

    // MARK: Setting off

    /// The screen of Mochi's menu bar, the stretch of bar it may come back to, the zone's origin,
    /// and where on the bar Mochi is now (screen x).
    private func barPlace() -> (screen: NSScreen, bar: ClosedRange<Double>, origin: Double, x: Double)? {
        let statusItem = environment.statusItem
        let roamer = world.roamer
        if statusItem.activeStyle == .roam {
            guard let overlay = statusItem.overlay, overlay.isVisible, let geometry = overlay.geometry else { return nil }
            let frame = geometry.overlayFrame
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { return nil }
            return (screen, geometry.zone.minX...geometry.zone.maxX, 0, roamer.sample(at: now).x)
        }
        guard let item = statusItem.buttonScreenFrame, item.width > 1,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: item.midX, y: item.midY)) }) else { return nil }
        let origin = Double(item.minX)
        if let zone = roamer.zone {
            return (screen, (origin + zone.minX)...(origin + zone.maxX), origin, origin + roamer.sample(at: now).x)
        }
        return (screen, Double(item.minX)...Double(item.maxX), origin, Double(item.midX))
    }

    /// Opens the stage and sends Mochi out: hopping down out of the bar, or hanging from the pointer
    /// (`carriedFrom`, screen point) when it was lifted off. False when there is nowhere to go.
    @discardableResult
    private func setOff(carriedFrom point: CGPoint?) -> Bool {
        guard outing == nil, let place = barPlace() else { return false }
        let windows = Self.windowFrames()
        guard !AdventureTerrain.looksFullScreen(windows: windows, screen: place.screen.frame) else { return false }
        let scale = CGFloat(settings.desktopPetSize.height / 100 * 0.75)
        let metrics = AdventurePlanner.Metrics(halfWidth: Double(PetRenderer.bodyWidth * scale) / 2,
                                               height: Double(PetRenderer.bodyHeight * scale))
        let terrain = Self.terrain(on: place.screen, windows: windows, metrics: metrics)
        let seed = world.seed &+ UInt64(bitPattern: Int64((now * 1_000).rounded()))
        var outing = Outing(screen: place.screen, terrain: terrain, metrics: metrics, scale: scale, bar: place.bar, barOrigin: place.origin,
                            seed: seed, companionWasPresent: world.companionPresent)
        world.setAdventureActive(true, instantly: point != nil)
        scheduler.reset()
        if let point {
            outing.carry = Carry(startedAt: now, fromBar: true, facing: world.roamer.sample(at: now).facing, lastX: Double(point.x), lastTime: now)
        } else {
            // The adventure starts as Mochi drops out of sight through the bottom of the bar.
            let departure = world.roamer.awayDeparture
            let x = departure.map { place.origin + $0.x } ?? place.x
            let start = AdventurePoint(x: x, y: Double(place.screen.visibleFrame.maxY) + metrics.height * 0.6)
            outing.plan = AdventurePlanner.plan(from: start, at: departure?.time ?? now, terrain: terrain, bar: place.bar, seed: seed,
                                                metrics: metrics)
        }
        self.outing = outing
        showStage(on: place.screen)
        observeEndings()
        let survey = Timer(timeInterval: 1 / Self.surveyRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.survey() }
        }
        survey.tolerance = 0.1
        RunLoop.main.add(survey, forMode: .common)
        surveyTimer = survey
        setRenderRate(30)
        return true
    }

    private func showStage(on screen: NSScreen) {
        let frame = screen.visibleFrame
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.setFrame(frame, display: false)
        stage.frame = NSRect(origin: .zero, size: frame.size)
        if stage.superview !== panel.contentView {
            stage.removeFromSuperview()
            panel.contentView?.addSubview(stage)
        }
        stage.onPointer = { [weak self] event in self?.handle(event) }
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    private static func makePanel() -> AdventurePanel {
        let panel = AdventurePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.setAccessibilityElement(false)
        let content = NSView(frame: panel.contentLayoutRect)
        content.wantsLayer = true
        panel.contentView = content
        return panel
    }

    /// Back on the bar: the stage closes, every timer stops, and Mochi pops up through the bar at
    /// `x` (screen points; where it left when nil).
    private func finish(returningAt x: Double?) {
        guard let outing else { return }
        self.outing = nil
        press = nil
        debugPointer = nil
        setRenderRate(0)
        surveyTimer?.invalidate()
        surveyTimer = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        stage.clear()
        stage.onPointer = nil
        panel?.orderOut(nil)
        let back = x.map { min(outing.bar.upperBound, max(outing.bar.lowerBound, $0)) - outing.barOrigin }
        world.setAdventureActive(false, returningAt: back)
    }

    // MARK: Endings

    /// Locking the screen, sleep, another space, a display change: Mochi is simply home again.
    private func observeEndings() {
        let workspace = NSWorkspace.shared.notificationCenter
        let endings: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.screensDidSleepNotification), (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification), (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
        ]
        for (center, name) in endings {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(returningAt: nil) }
            }))
        }
    }

    /// Claude needs you, Patch arrived, adventures were turned off: Mochi hurries home.
    /// Reduced Motion, or the menu bar going away, ends it at once.
    private func checkConditions(at t: TimeInterval) {
        guard t - lastConditionCheck >= 0.25, let outing else { return }
        lastConditionCheck = t
        let style = environment.statusItem.activeStyle
        if world.reducedMotion || style == nil || (style == .roam && environment.statusItem.overlay?.geometry == nil) {
            finish(returningAt: nil)
            return
        }
        let arrived = world.companionPresent && !outing.companionWasPresent
        if world.menuBarStatus.mood == .waiting || arrived || !settings.adventure.enabled {
            endAdventure()
        }
    }

    // MARK: Spontaneous adventures

    /// Every few seconds: counts quiet time, and sets off by itself when it has been long enough.
    private func considerSettingOff() {
        let adventure = settings.adventure
        let context = world.roamContext
        let mode = world.roamer.mode
        let eligible = adventure.enabled && outing == nil && !world.adventureActive && context.activity == .idle && !context.quietHours
            && !context.paused && !context.reducedMotion && !context.popoverOpen && !world.petAsleep && world.interaction == nil
            && (mode == .free || mode == .companion || environment.statusItem.activeStyle == .icon)
        if scheduler.tick(now: now, eligible: eligible, frequency: adventure.spontaneous) {
            setOff(carriedFrom: nil)
        }
    }

    // MARK: Windows

    /// Other apps' normal windows on screen, front to back, in AppKit screen points. Reads only
    /// their bounds, layer, opacity and owning process — never names or contents.
    static func windowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        var frames: [CGRect] = []
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) != me }) ?? false,
                  ((entry[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            frames.append(CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height))
        }
        return frames
    }

    /// The screen's visible area, its floor (the Dock's top) and the window tops on it.
    static func terrain(on screen: NSScreen, windows: [CGRect], metrics: AdventurePlanner.Metrics) -> AdventureTerrain {
        let frame = screen.frame
        let visible = screen.visibleFrame
        // The Dock sits at the bottom when the visible area starts above the screen's bottom edge.
        let dockAtBottom = visible.minY > frame.minY + 8
        let half = Double(frame.width) * 0.28
        let dock = dockAtBottom ? (Double(frame.midX) - half)...(Double(frame.midX) + half) : nil
        return AdventureTerrain(bounds: visible, floorY: Double(visible.minY), dock: dock, windows: windows, headroom: metrics.height + 6)
    }

    /// A few times a second while out: windows moved, opened or closed? Re-route if the ground changed.
    private func survey() {
        guard var outing else { return }
        surveys += 1
        let windows = Self.windowFrames()
        if AdventureTerrain.looksFullScreen(windows: windows, screen: outing.screen.frame) {
            finish(returningAt: nil)
            return
        }
        let terrain = Self.terrain(on: outing.screen, windows: windows, metrics: outing.metrics)
        guard terrain != outing.terrain else { return }
        outing.terrain = terrain
        if let plan = outing.plan, let adapted = AdventurePlanner.adapt(plan, at: now, to: terrain, metrics: outing.metrics) {
            outing.plan = adapted
        }
        self.outing = outing
    }

    // MARK: Frames

    private func setRenderRate(_ rate: Double) {
        guard rate != renderRate || (rate > 0) != (renderTimer != nil) else { return }
        renderRate = rate
        renderTimer?.invalidate()
        renderTimer = nil
        guard rate > 0 else { return }
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1 / rate
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    private func tick() {
        let t = now
        checkConditions(at: t)
        guard var outing, let panel else { return }
        let origin = panel.frame.origin
        let look: AdventureLook
        var rate = 30.0
        if var carry = outing.carry {
            let pointer = debugPointer ?? NSEvent.mouseLocation
            // A pendulum: Mochi swings behind the pointer's sideways moves and settles.
            let dt = max(1.0 / 120, min(0.1, t - carry.lastTime))
            let velocity = (Double(pointer.x) - carry.lastX) / dt
            let target = max(-0.6, min(0.6, velocity * 0.0012))
            carry.swingSpeed += ((target - carry.swing) * 70 - carry.swingSpeed * 9) * dt
            carry.swing += carry.swingSpeed * dt
            carry.lastX = Double(pointer.x)
            carry.lastTime = t
            outing.carry = carry
            look = carriedLook(carry, outing: outing, at: CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y), time: t)
        } else if let plan = outing.plan {
            let sample = plan.sample(at: t)
            let top = Double(outing.screen.visibleFrame.maxY)
            if sample.finished || (sample.phase == .returning && sample.isAirborne && sample.point.y > top + outing.metrics.height * 0.15) {
                self.outing = outing
                finish(returningAt: plan.homeX)
                return
            }
            if let segment = plan.segment(at: t), let line = segment.line, segment.start > outing.spoken, t >= segment.start {
                outing.spoken = segment.start
                world.say(line)
            }
            look = sampleLook(sample, outing: outing, origin: origin, time: t)
            rate = sample.move == .hold ? (sample.duration == nil ? 12 : 20) : 30
            if sample.style == .land || sample.style == .crouch { rate = 30 }
        } else {
            return
        }
        self.outing = outing
        stage.render(look, palette: PetPalette(settings.petColor), accessory: settings.petAccessory,
                     dark: StatusItemController.isDark(NSApp.effectiveAppearance))
        // Clicks are let in only while the pointer is over Mochi (or holding it).
        let mouse = NSEvent.mouseLocation
        let over = press != nil || (stage.petRect.map { $0.offsetBy(dx: origin.x, dy: origin.y).contains(mouse) } ?? false)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        stage.acceptsPointer = over
        setRenderRate(outing.carry != nil || press != nil ? 30 : rate)
    }

    /// Mochi's pose and place for a moment of the plan.
    private func sampleLook(_ sample: AdventureSample, outing: Outing, origin: CGPoint, time: TimeInterval) -> AdventureLook {
        var context = PoseContext(time: time, reducedMotion: world.reducedMotion, intensity: settings.animationIntensity, seed: world.seed)
        let scale = outing.scale
        let gait: Double
        switch sample.animation {
        case .walk, .carry: gait = MenuBarPetCanvas.walkGaitSpeed
        case .run: gait = MenuBarPetCanvas.runGaitSpeed
        default: gait = 0
        }
        // Gaits run on the distance covered (scaled to Mochi's size here), so feet never skate.
        if gait > 0 { context.time = sample.odometer / (gait * Double(scale / 0.28)) }
        var pose = PetPoseEvaluator.pose(sample.animation, elapsed: sample.elapsed, duration: sample.duration, context: context)
        AdventureLook.accent(&pose, sample: sample)
        if sample.facing < 0 { pose.effects.removeAll { MenuBarPetCanvas.isGlyph($0.kind) } }
        let anchor = CGPoint(x: sample.point.x - Double(origin.x), y: sample.point.y - Double(origin.y))
        let dust = sample.style == .land ? 1 - sample.progress : 0
        return AdventureLook(pose: pose, anchor: anchor, hang: 0, rotation: sample.rotation, facing: sample.facing, scale: scale, dust: dust)
    }

    /// Hanging from the pointer by the scruff, legs paddling; out of the bar it grows to full size.
    private func carriedLook(_ carry: Carry, outing: Outing, at pointer: CGPoint, time: TimeInterval) -> AdventureLook {
        let held = time - carry.startedAt
        let context = PoseContext(time: time, reducedMotion: world.reducedMotion, intensity: settings.animationIntensity, seed: world.seed)
        var pose = PetPoseEvaluator.pose(.idle, elapsed: held, context: context)
        pose.eyes = held < 0.7 ? .wide : .happy
        pose.earPerk = 0.7
        pose.leftArm = 0.35
        pose.rightArm = 0.35
        pose.step = 0.5 * abs(sin(held * 7))
        pose.tailWag += 1.5 * sin(time * 5)
        pose.shadow = 0
        pose.effects.removeAll { MenuBarPetCanvas.isGlyph($0.kind) }
        let grow = carry.fromBar ? Ease.smooth(Ease.segment(held, 0, 0.3)) : 1
        let scale = CGFloat(Ease.lerp(0.28, Double(outing.scale), grow))
        return AdventureLook(pose: pose, anchor: pointer, hang: PetRenderer.bodyHeight * scale * 0.95, rotation: carry.swing,
                             facing: carry.facing, scale: scale, dust: 0)
    }

    // MARK: Pointer

    func menuBarPetClicked() { world.interact(.pet) }

    func menuBarPetCanBePickedUp() -> Bool {
        outing == nil && settings.adventure.enabled && !world.reducedMotion && world.roamer.mode != .frozen
    }

    func menuBarPetPickedUp(at point: CGPoint) {
        if setOff(carriedFrom: point) { tick() }
    }

    func menuBarPetReleased(at point: CGPoint) { release(at: point) }

    /// Let go: over the menu bar Mochi just goes back to it; below it, it drops onto what is there.
    private func release(at point: CGPoint) {
        guard var outing, let carry = outing.carry else { return }
        let visible = outing.screen.visibleFrame
        if point.y >= visible.maxY - 2 || !outing.screen.frame.contains(point) {
            finish(returningAt: Double(point.x))
            return
        }
        outing.terrain = Self.terrain(on: outing.screen, windows: Self.windowFrames(), metrics: outing.metrics)
        let feet = AdventurePoint(x: Double(point.x), y: Double(point.y) - outing.metrics.height * 0.95)
        outing.seed = outing.seed &+ 0x9E37
        outing.plan = AdventurePlanner.plan(from: feet, at: now, terrain: outing.terrain, bar: outing.bar, seed: outing.seed,
                                            metrics: outing.metrics, length: carry.fromBar ? 40...75 : 25...45, facing: carry.facing)
        outing.carry = nil
        outing.hurrying = false
        self.outing = outing
        setRenderRate(30)
    }

    /// Clicks on Mochi out on the desktop: a click pets it, a double-click sends it home, a drag picks it up.
    private func handle(_ event: AdventurePointerEvent) {
        switch event {
        case .down(let point, let clicks):
            press = (point, false)
            if clicks >= 2 {
                press = nil
                endAdventure()
            }
        case .dragged(let point):
            guard let current = press, !current.lifted, var outing, outing.carry == nil, let plan = outing.plan,
                  hypot(point.x - current.start.x, point.y - current.start.y) > 5 else { return }
            press = (current.start, true)
            outing.carry = Carry(startedAt: now, fromBar: false, facing: plan.sample(at: now).facing, lastX: Double(point.x), lastTime: now)
            outing.plan = nil
            self.outing = outing
            tick()
        case .up(let point):
            guard let current = press else { return }
            press = nil
            if current.lifted {
                release(at: point)
            } else if var outing, let plan = outing.plan {
                world.interact(.pet)
                if let petted = AdventurePlanner.interject(.happyBounce, into: plan, at: now) {
                    outing.plan = petted
                    self.outing = outing
                }
            }
        }
    }

    // MARK: Development

    private func registerDebugHooks() {
        let debug = environment.debug
        debug.register("adventure") { [weak self] argument in
            guard let self else { return }
            let parts = argument.split(separator: ":").map(String.init)
            switch parts.first ?? "" {
            case "start": self.beginAdventure()
            case "home": self.endAdventure()
            case "end": self.finish(returningAt: nil)
            case "spontaneous": self.setOff(carriedFrom: nil)
            case "pickup":
                // As if the pointer lifted Mochi off the bar where it stands.
                guard let place = self.barPlace(), let bar = self.environment.statusItem.overlay?.geometry?.overlayFrame else { return }
                let point = CGPoint(x: place.x, y: Double(bar.midY))
                self.debugPointer = point
                self.menuBarPetPickedUp(at: point)
            case "carry", "release":
                let numbers = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Double($0) }
                guard numbers.count == 2 else { return }
                let point = CGPoint(x: numbers[0], y: numbers[1])
                if parts.first == "carry" { self.debugPointer = point } else { self.release(at: point) }
            default: break
            }
        }
        debug.registerState("adventure") { [weak self] in
            guard let self else { return [:] }
            var state: [String: Any] = ["out": self.outing != nil, "worldActive": self.world.adventureActive, "fps": self.renderRate,
                                        "surveys": self.surveys, "spontaneous": ["accumulated": self.scheduler.accumulated.rounded(),
                                                                                  "threshold": self.scheduler.threshold.rounded()]]
            if let outing = self.outing {
                state["carried"] = outing.carry != nil
                state["ledges"] = outing.terrain.ledges.count
                state["bar"] = [outing.bar.lowerBound, outing.bar.upperBound]
                state["clickable"] = !(self.panel?.ignoresMouseEvents ?? true)
                if let plan = outing.plan {
                    let sample = plan.sample(at: self.now)
                    state["phase"] = sample.phase.title
                    state["move"] = sample.move.rawValue
                    state["animation"] = sample.animation.rawValue
                    state["x"] = (sample.point.x * 10).rounded() / 10
                    state["y"] = (sample.point.y * 10).rounded() / 10
                    state["rotation"] = (sample.rotation * 100).rounded() / 100
                    state["left"] = max(0, plan.end - self.now).rounded()
                    state["homeX"] = plan.homeX
                }
            }
            return state
        }
    }
}

// MARK: - Stage

/// A borderless panel that never takes focus.
final class AdventurePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum AdventurePointerEvent {
    case down(CGPoint, Int)
    case dragged(CGPoint)
    case up(CGPoint)
}

/// Everything one adventure frame draws.
struct AdventureLook {
    var pose: PetPose
    /// The feet, or the scruff while hanging from the pointer (view points, y up).
    var anchor: CGPoint
    /// From the scruff down to the feet while hanging.
    var hang: CGFloat
    /// Radians, clockwise on screen (on a wall, or swinging).
    var rotation: Double
    var facing: Double
    var scale: CGFloat
    /// 0…1: a landing puff at the feet.
    var dust: Double

    /// The body language the plan's styles ask for (crouches, take-offs, flight, landings).
    static func accent(_ pose: inout PetPose, sample: AdventureSample) {
        let p = sample.progress
        let m = sample.style == .plain ? 0.0 : 1.0
        switch sample.style {
        case .crouch:
            let amount = Ease.smooth(Ease.segment(p, 0, 0.6)) * m
            pose.scaleY *= 1 - 0.1 * amount
            pose.scaleX *= 1 + 0.06 * amount
            pose.earPerk = min(pose.earPerk, -0.2)
        case .launch:
            let push = max(0, 1 - sample.elapsed / 0.16)
            pose.scaleY *= 1 + 0.08 * push
            pose.scaleX *= 1 - 0.05 * push
            pose.earPerk = max(pose.earPerk, 0.6)
            pose.leftArm = max(pose.leftArm, 0.5)
            pose.rightArm = max(pose.rightArm, 0.5)
        case .drop:
            pose.scaleY *= 1.06
            pose.scaleX *= 0.96
            pose.leftArm = max(pose.leftArm, 0.55)
            pose.rightArm = max(pose.rightArm, 0.55)
            pose.earPerk = 0.9
            pose.eyes = .wide
        case .land:
            let squash = pow(1 - p, 1.5)
            pose.scaleY *= 1 - 0.14 * squash
            pose.scaleX *= 1 + 0.1 * squash
        case .notice:
            pose.earPerk = max(pose.earPerk, 0.85)
            pose.brows = .raised
            if p < 0.6 { pose.eyes = .wide }
        default:
            break
        }
        if sample.move == .climb {
            // Paw over paw up the edge, looking up where it is going, with a little heave each reach.
            let phase = sample.odometer / 10
            pose.leftArm = 0.78 + 0.22 * sin(phase)
            pose.rightArm = 0.78 - 0.22 * sin(phase)
            pose.y += 0.035 * abs(sin(phase))
            pose.lookX = 0.35
            pose.lookY = -0.55
            pose.earPerk = max(pose.earPerk, 0.5)
        }
        if sample.isAirborne { pose.shadow = 0.3 }
        if sample.phase == .climbing || sample.phase == .returning { pose.shadow = 0 }
    }
}

/// The adventure panel's content: Mochi as one sprite that moves (re-rendered only when the
/// drawing changes). Takes clicks only on Mochi, and only while the controller lets the pointer in.
@MainActor
final class AdventureStageView: NSView {
    private let sprite = SpriteSurface()
    /// Mochi's body in view points (y up), for clicks.
    private(set) var petRect: CGRect?
    var acceptsPointer = false
    var onPointer: ((AdventurePointerEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(sprite.layer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsPointer, let petRect else { return nil }
        return petRect.contains(convert(point, from: superview)) ? self : nil
    }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPointer?(.down(NSEvent.mouseLocation, event.clickCount)) }
    override func mouseDragged(with event: NSEvent) { onPointer?(.dragged(NSEvent.mouseLocation)) }
    override func mouseUp(with event: NSEvent) { onPointer?(.up(NSEvent.mouseLocation)) }

    func render(_ look: AdventureLook, palette: PetPalette, accessory: Accessory?, dark: Bool) {
        let backing = window?.backingScaleFactor ?? 2
        let width = PetRenderer.bodyWidth * look.scale
        let height = PetRenderer.bodyHeight * look.scale
        let half = ceil(height * 1.7 + look.hang)
        let rect = CGRect(x: look.anchor.x - half, y: look.anchor.y - half, width: 2 * half, height: 2 * half)
        var signature = PoseSignature(resolution: 0.35)
        signature.pet(look.pose)
        signature.add(look.rotation, 0.004)
        signature.add(look.facing, 1)
        signature.add(Double(look.scale), 0.002)
        signature.add(Double(look.hang), 0.25)
        signature.add(look.dust, 0.05)
        signature.add(dark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.update(frame: rect, scale: backing, signature: signature.values) { g in
            var g = g
            g.translateBy(x: half, y: half)
            g.rotate(by: .radians(look.rotation))
            g.translateBy(x: 0, y: look.hang)
            if look.dust > 0.02 {
                for side in [-1.0, 1.0] {
                    let puff = SceneProp(.dust, x: 0, y: 0, scale: 1.4 + 0.6 * (1 - look.dust), opacity: 0.8 * look.dust, variant: side > 0 ? 0 : 1)
                    EffectRenderer.drawProp(puff, in: g, at: CGPoint(x: CGFloat(side) * width * 0.48, y: -2), scale: look.scale, dark: dark)
                }
            }
            if look.facing < 0 { g.scaleBy(x: -1, y: 1) }
            PetRenderer.draw(look.pose, in: g, at: .zero, scale: look.scale, palette: palette, accessory: accessory, dark: dark)
        }
        CATransaction.commit()
        // The body, turned like the drawing, for clicks.
        let angle = -look.rotation
        let corners = [CGPoint(x: -width / 2, y: 0), CGPoint(x: width / 2, y: 0), CGPoint(x: -width / 2, y: height), CGPoint(x: width / 2, y: height)]
        let turned = corners.map { corner -> CGPoint in
            let y = corner.y - look.hang
            return CGPoint(x: look.anchor.x + corner.x * cos(angle) - y * sin(angle), y: look.anchor.y + corner.x * sin(angle) + y * cos(angle))
        }
        let xs = turned.map(\.x)
        let ys = turned.map(\.y)
        petRect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    func clear() {
        sprite.isHidden = true
        petRect = nil
        acceptsPointer = false
    }
}

// MARK: - Settings

struct AdventureSettingsSection: View {
    let environment: AppEnvironment
    @Bindable private var store: SettingsStore

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.settingsStore
    }

    var body: some View {
        let name = store.settings.petName
        Section("Adventures") {
            Toggle("\(name) explores the desktop", isOn: $store.settings.adventure.enabled)
            Picker("Sets off by itself", selection: $store.settings.adventure.spontaneous) {
                ForEach(AdventureFrequency.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!store.settings.adventure.enabled)
            Text("Drag \(name) down off the menu bar, or choose Explore. Out there it walks along window tops, sits on the Dock and climbs the screen's edge. Only where windows are is read — never what they show — and only while \(name) is out.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Explore Now") { environment.adventure.beginAdventure() }
                .disabled(!store.settings.adventure.enabled)
        }
    }
}
