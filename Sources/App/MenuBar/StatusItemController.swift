import AppKit
import Observation
import SwiftUI
import TamagotchiCore

/// The menu-bar home of the app, in one of three styles:
///
/// - `.roam` (default): the status item is Mochi's home slot (a little bed, plus
///   mini Patch during sessions) and a click-through overlay lets Mochi, in full
///   colour, walk, run and play along the whole menu bar.
/// - `.stage`: the same stage, inside a wider status item.
/// - `.icon`: the classic animated template glyph.
///
/// In every style a click opens the popover and a right-click shows the quick menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private unowned let environment: AppEnvironment
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let badge = CALayer()
    private var status: MenuBarStatus?
    private var frame = MenuBarGlyph.Frame(phase: 0, blink: false, bounce: 0)
    private var animationTimer: Timer?
    private var nextBlink = Date().addingTimeInterval(4)
    private var celebrationStart: Date?

    // The living menu bar.
    private(set) var activeStyle: MenuBarStyle?
    private(set) var driver: MenuBarStageDriver?
    private(set) var overlay: MenuBarOverlayController?
    private let system = SystemActivityMonitor()
    private var appearanceObservation: NSKeyValueObservation?
    private var stageObservers: [NSObjectProtocol] = []
    /// Why the overlay can't be used right now (nil when it can); the stage stands in meanwhile.
    private var overlayUnavailable: String?
    private var styleTimer: Timer?
    private var homeImageKey: String?
    /// The stage's item is parked out of sight (no room beside the notch).
    private var stageHidden = false

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    private var world: CompanionWorld { environment.world }

    /// The status item's frame on screen (global points), for things that point at it.
    var buttonScreenFrame: CGRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        badge.bounds = CGRect(x: 0, y: 0, width: 6.5, height: 6.5)
        badge.cornerRadius = 3.25
        badge.isHidden = true
        badge.borderWidth = 1
        button.layer?.addSublayer(badge)

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView(environment: environment))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        appearanceObservation = button.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] button, _ in
            MainActor.assumeIsolated {
                self?.driver?.dark = Self.isDark(button.effectiveAppearance)
                self?.redraw()
            }
        }
        system.onChange = { [weak self] name in
            guard let self else { return }
            // Waking screens and new spaces are good moments to try the overlay again.
            if name == NSWorkspace.screensDidWakeNotification || name == NSWorkspace.activeSpaceDidChangeNotification {
                self.retryOverlay()
            }
            self.overlay?.refresh()
            self.updateStageVisibility()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryOverlay() }
        }
        // The user may switch menu-bar auto-hiding on or off at any time; a fallback to the
        // stage is retried here too.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryOverlay()
                self?.applyStyle()
                self?.updateStageVisibility()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        styleTimer = timer

        statusChanged()
        applyStyle()
        observe()
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
    }

    // MARK: Status observation

    private func observe() {
        withObservationTracking {
            _ = world.menuBarStatus
            let settings = world.settings
            _ = settings.menuBarAnimation
            _ = settings.menuBarStyle
            _ = settings.menuBarRoamRange
            _ = settings.menuBarStageWidth
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.statusChanged()
                self?.applyStyle()
                self?.observe()
            }
        }
    }

    private func statusChanged() {
        let newStatus = world.menuBarStatus
        if newStatus.mood == .celebrating, status?.mood != .celebrating {
            celebrationStart = Date()
        }
        guard newStatus != status else { return }
        status = newStatus
        if activeStyle == .roam { updateHomeSlotWidth() }
        redraw()
        if activeStyle == .icon { animationStep() }
    }

    // MARK: Styles

    /// The style that can actually work right now.
    private var effectiveStyle: MenuBarStyle {
        let wanted = world.settings.menuBarStyle
        if wanted == .roam, MenuBarOverlayController.menuBarAutoHides || overlayUnavailable != nil { return .stage }
        return wanted
    }

    /// Why roaming is standing in with the stage right now (shown in Settings), or nil.
    var roamFallbackReason: String? {
        if world.settings.menuBarStyle == .stage, stageHidden {
            return "The menu bar is too full to show a \(Int(world.settings.menuBarStageWidth.points)) pt item beside the notch, so macOS hides it. Try a smaller width, or let \(world.settings.petName) roam."
        }
        guard world.settings.menuBarStyle == .roam else { return nil }
        if MenuBarOverlayController.menuBarAutoHides { return "Your menu bar hides automatically, so \(world.settings.petName) plays inside the menu-bar item instead." }
        return overlayUnavailable
    }

    /// A fallback to the stage is temporary: once the status item has a screen again, roam.
    private func retryOverlay() {
        guard overlayUnavailable != nil, world.settings.menuBarStyle == .roam else { return }
        if MenuBarOverlayController.currentGeometry(of: statusItem, range: world.settings.menuBarRoamRange.points).screenFound {
            overlayUnavailable = nil
            publishFallback()
            applyStyle()
        }
    }

    private func publishFallback() {
        let reason = roamFallbackReason
        if environment.ui.menuBarNote != reason { environment.ui.menuBarNote = reason }
    }

    private func applyStyle() {
        guard let item = statusItem, let button = item.button else { return }
        let style = effectiveStyle
        publishFallback()
        if style != activeStyle {
            tearDown()
            activeStyle = style
            switch style {
            case .icon: setUpIcon()
            case .stage: setUpStage(item: item, button: button)
            case .roam: setUpRoam(item: item)
            }
            redraw()
        } else {
            switch style {
            case .roam:
                overlay?.setRange(world.settings.menuBarRoamRange.points)
                updateHomeSlotWidth()
            case .stage:
                let width = CGFloat(world.settings.menuBarStageWidth.points)
                if item.length != width { setUpStage(item: item, button: button) }
            case .icon:
                break
            }
        }
    }

    private func tearDown() {
        animationTimer?.invalidate()
        animationTimer = nil
        badge.isHidden = true
        homeImageKey = nil
        stageHidden = false
        overlay?.deactivate()
        overlay = nil
        stageObservers.forEach(NotificationCenter.default.removeObserver)
        stageObservers = []
        driver?.view.removeFromSuperview()
        driver?.visible = false
        world.setRoamZone(nil)
    }

    private func ensureDriver() -> MenuBarStageDriver {
        if let driver { return driver }
        let driver = MenuBarStageDriver(world: world)
        if let button = statusItem?.button { driver.dark = Self.isDark(button.effectiveAppearance) }
        self.driver = driver
        return driver
    }

    private func setUpIcon() {
        statusItem?.length = NSStatusItem.variableLength
        scheduleFrame(after: 0.2)
    }

    private func setUpStage(item: NSStatusItem, button: NSStatusBarButton) {
        let width = CGFloat(world.settings.menuBarStageWidth.points)
        item.length = width
        button.image = nil
        let driver = ensureDriver()
        let height = max(18, button.bounds.height)
        driver.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        driver.view.autoresizingMask = [.height]
        if driver.view.superview !== button {
            driver.view.removeFromSuperview()
            button.addSubview(driver.view)
        }
        driver.view.layout = MenuBarLayout.stage(width: width, height: height)
        world.setRoamZone(RoamGeometry.stageZone(width: Double(width)))
        stageObservers.forEach(NotificationCenter.default.removeObserver)
        stageObservers = []
        if let window = button.window {
            stageObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                                         queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStageVisibility() }
            })
        }
        updateStageVisibility()
    }

    /// The stage only draws while its item is really on a menu bar: macOS keeps "visible" items
    /// that do not fit beside the notch (or overflow) parked out of sight, still claiming to be visible.
    private func updateStageVisibility() {
        guard activeStyle == .stage, let driver else { return }
        let window = statusItem?.button?.window
        let reading = MenuBarOverlayController.currentGeometry(of: statusItem, range: nil)
        let onBar = reading.geometry != nil || !reading.screenFound
        stageHidden = !onBar
        publishFallback()
        driver.visible = onBar && system.allowsDrawing && (window?.isVisible ?? false) && (window?.occlusionState.contains(.visible) ?? false)
    }

    private func setUpRoam(item: NSStatusItem) {
        updateHomeSlotWidth()
        let driver = ensureDriver()
        let overlay = MenuBarOverlayController(stageView: driver.view, system: system)
        overlay.onGeometryChange = { [weak self] geometry in
            self?.world.setRoamZone(geometry?.zone)
        }
        overlay.onVisibilityChange = { [weak self] visible in
            self?.driver?.visible = visible
        }
        overlay.onUnavailable = { [weak self] in
            // No usable screen for a while: play inside the status item until there is one again.
            guard let self else { return }
            self.overlayUnavailable = "The menu bar's screen can't be found right now, so \(self.world.settings.petName) plays inside the menu-bar item until it is back."
            self.applyStyle()
        }
        self.overlay = overlay
        overlay.pointer = environment.adventure
        overlay.activate(item: item, range: world.settings.menuBarRoamRange.points)
    }

    private func updateHomeSlotWidth() {
        guard activeStyle == .roam, let item = statusItem else { return }
        let width = CGFloat(RoamGeometry.homeSlotWidth(companion: world.companionPresent))
        if item.length != width { item.length = width }
        updateHomeImage()
    }

    /// In the roaming style the status item's own picture is Mochi's empty bed (and the badge),
    /// drawn exactly where the overlay draws: other displays' menu bars show it, and the overlay
    /// covers it with the living scene on this one.
    private func updateHomeImage() {
        guard activeStyle == .roam, let button = statusItem?.button else { return }
        let width = CGFloat(RoamGeometry.homeSlotWidth(companion: world.companionPresent))
        let height = max(18, button.bounds.height > 1 ? button.bounds.height : NSStatusBar.system.thickness)
        let dark = Self.isDark(button.effectiveAppearance)
        let badge = status?.badge
        // Sized like the overlay draws Mochi: the roomy scale in a tall (notched) menu bar.
        let roomy = (button.window?.frame.height ?? 24) >= 30
        let key = "\(width)x\(height)-\(dark)-\(roomy)-\(badge.map { "\($0.rawValue)" } ?? "none")"
        guard key != homeImageKey || button.image == nil else { return }
        homeImageKey = key
        button.image = Self.homeImage(width: width, height: height, roomy: roomy, dark: dark, badge: badge)
    }

    static func homeImage(width: CGFloat, height: CGFloat, roomy: Bool, dark: Bool, badge: AttentionLevel?) -> NSImage? {
        let layout = MenuBarLayout.homeImageLayout(slotWidth: width, slotHeight: height, roomy: roomy,
                                                   rightToLeft: NSApp.userInterfaceLayoutDirection == .rightToLeft)
        let renderer = ImageRenderer(content: Canvas { g, _ in
            MenuBarPetCanvas.drawBed(in: g, center: CGPoint(x: layout.homeX, y: layout.baseline), scale: layout.toyScale, dark: dark)
            if let badge { MenuBarPetCanvas.drawBadge(badge, at: MenuBarPetCanvas.badgePoint(layout), dark: dark, in: g) }
        }.frame(width: width, height: height))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        image.isTemplate = false
        return image
    }

    // MARK: Classic icon

    private func startAnimationTimer() {
        scheduleFrame(after: 0.5)
    }

    /// One-shot timer, re-armed only for the next visible change (a blink, an
    /// antenna pulse or a celebration frame), so an idle menu bar costs nothing.
    private func scheduleFrame(after delay: TimeInterval) {
        animationTimer?.invalidate()
        let timer = Timer(timeInterval: max(1.0 / 15, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.animationStep() }
        }
        timer.tolerance = min(0.25, delay * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func animationStep() {
        guard activeStyle == .icon, let status else { return }
        let style = world.settings.menuBarAnimation
        let now = Date()
        var next = MenuBarGlyph.Frame(phase: 0.25, blink: false, bounce: 0)
        var wake: TimeInterval = .infinity

        if style == .off || world.reducedMotion {
            frame = next
            redraw()
            animationTimer?.invalidate()
            return
        }
        // Natural, occasional blinks.
        if now >= nextBlink.addingTimeInterval(0.14) {
            nextBlink = now.addingTimeInterval(Double.random(in: 3.5...7.5))
        }
        if now >= nextBlink {
            next.blink = true
            wake = min(wake, nextBlink.addingTimeInterval(0.14).timeIntervalSince(now))
        } else {
            wake = min(wake, nextBlink.timeIntervalSince(now))
        }
        // Gentle antenna pulse while Claude works (on/off every 0.8 s — never flashing).
        if status.companionWorking {
            let cycle = now.timeIntervalSinceReferenceDate / 1.6
            next.phase = Ease.fract(cycle) < 0.5 ? 0.25 : 0.75
            wake = min(wake, (0.5 - Ease.fract(cycle * 2) * 0.5) * 1.6 + 0.01)
        }
        if status.mood == .celebrating, let start = celebrationStart {
            let t = now.timeIntervalSince(start)
            let hops = style == .full ? 3.0 : 2.0
            if t < hops * 0.42 {
                next.bounce = (2.4 * abs(sin(.pi * t / 0.42)) * 10).rounded() / 10
                next.phase = Ease.fract(t * 1.5)
                wake = 1.0 / 12
            } else if t < 2.6 {
                next.phase = Ease.fract(t * 1.5)
                wake = 1.0 / 8
            }
        }
        if next != frame {
            frame = next
            redraw()
        }
        scheduleFrame(after: wake.isFinite ? wake : 5)
    }

    private func redraw() {
        guard let status, let button = statusItem?.button else { return }
        button.setAccessibilityLabel(MenuBarGlyph.description(for: status))
        button.toolTip = tooltip()
        guard activeStyle == .icon else {
            // The stage draws the pet (and the badge) itself; while roaming the item shows the bed.
            badge.isHidden = true
            if activeStyle == .roam {
                updateHomeImage()
            } else if button.image != nil {
                button.image = nil
            }
            return
        }
        let image = MenuBarGlyph.image(for: status, frame: frame)
        button.image = image
        if let level = status.badge {
            badge.isHidden = false
            let color: NSColor
            switch level {
            case .info: color = .secondaryLabelColor
            case .attention: color = .systemOrange
            case .alert: color = .systemRed
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            badge.backgroundColor = color.cgColor
            badge.borderColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
            let imageWidth = image.size.width
            let x = (button.bounds.width - imageWidth) / 2 + 15
            // Top-right of the pet's head; the button's layer geometry may be flipped.
            let flipped = button.layer?.isGeometryFlipped ?? button.isFlipped
            let inset = (button.bounds.height - MenuBarGlyph.height) / 2 + 3.5
            badge.position = CGPoint(x: x, y: flipped ? inset : button.bounds.height - inset)
            CATransaction.commit()
        } else {
            badge.isHidden = true
        }
    }

    private func tooltip() -> String {
        var lines = [world.settings.petName]
        if let session = world.primarySession {
            lines.append("\(session.displayName): \(session.statusLine(now: Date()))")
        } else {
            lines.append(world.connection.title)
        }
        return lines.joined(separator: " — ")
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidShow(_ notification: Notification) {
        environment.ui.popoverVisible = true
        world.setPopoverVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        environment.ui.popoverVisible = false
        world.setPopoverVisible(false)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let settings = world.settings
        if settings.assistant.enabled {
            let ask = menu.addItem(withTitle: "Ask \(settings.petName)…", action: #selector(askAction), keyEquivalent: "")
            ask.target = self
            if settings.assistant.shortcut == .optionSpace {
                ask.keyEquivalent = " "
                ask.keyEquivalentModifierMask = [.option]
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Pet \(settings.petName)", action: #selector(petAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Play with \(settings.petName)", action: #selector(playAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Give \(settings.petName) a Treat", action: #selector(treatAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: environment.adventure.isExploring ? "Bring \(settings.petName) Home" : "Explore the Desktop",
                     action: #selector(exploreAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: environment.focus.menuTitle, action: #selector(focusAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Games…", action: #selector(gamesAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Today's Recap…", action: #selector(recapAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Share a Clip", action: #selector(clipAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Decorate the Room…", action: #selector(decorateAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let desktop = menu.addItem(withTitle: settings.desktopPetEnabled ? "Hide Desktop Pet" : "Show Desktop Pet", action: #selector(toggleDesktop), keyEquivalent: "")
        desktop.target = self
        let styleItem = menu.addItem(withTitle: "Menu Bar", action: nil, keyEquivalent: "")
        let styles = NSMenu(title: "Menu Bar")
        for style in MenuBarStyle.allCases {
            let entry = styles.addItem(withTitle: style.title, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = style.rawValue
            entry.state = settings.menuBarStyle == style ? .on : .off
        }
        styleItem.submenu = styles
        let quiet = menu.addItem(withTitle: "Quiet Mode", action: #selector(toggleQuiet), keyEquivalent: "")
        quiet.target = self
        quiet.state = settings.quietMode ? .on : .off
        let pause = menu.addItem(withTitle: "Pause Reactions", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = settings.pauseReactions ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Activity…", action: #selector(openActivity), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacTamagotchi", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left click opens the popover again.
        statusItem?.menu = nil
    }

    @objc private func petAction() { world.interact(.pet) }
    @objc private func playAction() { world.interact(.play) }
    @objc private func treatAction() { world.interact(.treat) }
    @objc private func toggleDesktop() { environment.toggleDesktopPet() }
    @objc private func toggleQuiet() { world.settings.quietMode.toggle() }
    @objc private func togglePause() { world.settings.pauseReactions.toggle() }
    @objc private func openActivity() { environment.windows.showActivity() }
    @objc private func openSettings() { environment.windows.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func exploreAction() { environment.adventure.beginAdventure() }
    @objc private func focusAction() { environment.focus.toggle() }
    @objc private func gamesAction() { environment.games.show() }
    @objc private func recapAction() { environment.recap.show() }
    @objc private func askAction() { environment.assistant.showPanel() }
    @objc private func clipAction() { environment.shareClip.captureClip() }
    @objc private func decorateAction() { environment.roomEditor.beginEditing() }

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = MenuBarStyle(rawValue: raw) else { return }
        world.settings.menuBarStyle = style
    }

    // MARK: Diagnostics

    var diagnostics: [String: Any] {
        var info: [String: Any] = ["style": activeStyle?.rawValue ?? "none", "wanted": world.settings.menuBarStyle.rawValue,
                                   "autoHide": MenuBarOverlayController.menuBarAutoHides]
        if let driver {
            info["fps"] = driver.fps
            info["visible"] = driver.visible
            info["framesDrawn"] = driver.framesDrawn
            info["renders"] = driver.view.renders
            info["dark"] = driver.dark
        }
        if let overlay {
            info["overlayReport"] = overlay.lastReport
            info["overlayVisible"] = overlay.isVisible
        }
        info["fallback"] = overlayUnavailable ?? NSNull()
        if let geometry = overlay?.geometry {
            info["overlay"] = [geometry.overlayFrame.minX, geometry.overlayFrame.minY, geometry.overlayFrame.width, geometry.overlayFrame.height]
            info["zone"] = [geometry.zone.minX, geometry.zone.maxX, geometry.zone.homeX, geometry.zone.companionX]
        }
        return info
    }
}
