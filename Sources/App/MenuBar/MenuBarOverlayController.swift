import AppKit
import TamagotchiCore

/// A transparent, click-through panel over the menu-bar band. It never becomes key
/// or main, sits just above the status bar (below menus), and does not follow the
/// user into full-screen spaces.
final class MenuBarOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Screen sleep and fast-user-switching, for pausing the menu-bar stage.
@MainActor
final class SystemActivityMonitor {
    private(set) var screensAsleep = false
    private(set) var sessionActive = true
    /// Called with the notification that changed something.
    var onChange: ((Notification.Name) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let name = notification.name
                MainActor.assumeIsolated { self?.handle(name) }
            })
        }
    }

    private func handle(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionActive = false
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionActive = true
        default: break
        }
        onChange?(name)
    }

    var allowsDrawing: Bool { !screensAsleep && sessionActive }

    func invalidate() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }
}

/// Whoever answers Mochi being clicked, picked up and let go of on the bar (screen points).
@MainActor
protocol MenuBarPointerHandling: AnyObject {
    func menuBarPetClicked()
    /// Whether a drag may lift Mochi off the bar right now.
    func menuBarPetCanBePickedUp() -> Bool
    func menuBarPetPickedUp(at point: CGPoint)
    func menuBarPetReleased(at point: CGPoint)
}

/// Owns the overlay panel that lets Mochi walk along the menu bar: places it over the
/// band of the status item's screen (right of the notch, or the right half of a screen
/// without one), follows the status item when it moves, and hides it (pausing
/// rendering) when the menu bar is not on screen.
///
/// The panel lets every click through, except while the pointer is over Mochi itself
/// (out of its bed, where clicks belong to the status item): then a click pets it and a
/// drag downwards lifts it off the bar. Only the pointer's position is read, a few times
/// a second (more often when it is near the bar), and never kept.
@MainActor
final class MenuBarOverlayController {
    private weak var item: NSStatusItem?
    private let stageView: MenuBarStageView
    private let system: SystemActivityMonitor
    private var panel: MenuBarOverlayPanel?
    private var range: Double?
    private var windowObservers: [NSObjectProtocol] = []
    private var globalObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private var sanityTimer: Timer?
    private(set) var geometry: MenuBarGeometry?
    private(set) var isVisible = false
    /// What the last refresh saw (diagnostics, only kept with the debug hooks on).
    private(set) var lastReport: [String: Any] = [:]
    /// Since when no usable screen could be found (nil while things are fine).
    private var failingSince: TimeInterval?
    /// A move to another display waits a moment, so a quick focus flip doesn't bounce Mochi around.
    private var pendingMove: (geometry: MenuBarGeometry, since: TimeInterval)?
    private var moveTimer: Timer?

    /// Clicks and drags on Mochi go here.
    weak var pointer: MenuBarPointerHandling?
    private var pointerTimer: Timer?
    private var pointerRate: Double = 0
    /// A press on Mochi, and whether it has become a drag that lifted it off the bar.
    private var press: (start: CGPoint, lifted: Bool)?

    /// The geometry changed (nil: nothing to show on right now).
    var onGeometryChange: ((MenuBarGeometry?) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    /// No usable screen for a while: the caller falls back to the stage until it recovers.
    var onUnavailable: (() -> Void)?

    /// How long geometry may fail before the overlay gives up (displays coming and going
    /// produce short bursts of nonsense).
    static let failureGrace: TimeInterval = 5
    static let displayMoveDelay: TimeInterval = 1

    init(stageView: MenuBarStageView, system: SystemActivityMonitor) {
        self.stageView = stageView
        self.system = system
    }

    /// The user turned on "Automatically hide and show the menu bar": nothing to walk on.
    static var menuBarAutoHides: Bool {
        let value = CFPreferencesCopyAppValue("_HIHideMenuBar" as CFString, kCFPreferencesAnyApplication)
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func activate(item: NSStatusItem, range: Double?) {
        self.item = item
        self.range = range
        if panel == nil { panel = makePanel() }
        if stageView.superview !== panel?.contentView {
            stageView.removeFromSuperview()
            panel?.contentView?.addSubview(stageView)
        }
        stageView.onPointer = { [weak self] event in self?.handle(event) }
        let center = NotificationCenter.default
        globalObservers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        if let panel {
            globalObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            })
        }
        // A cheap safety net for moves no notification reports (e.g. ⌘-dragging status items).
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        sanityTimer = timer
        refresh()
    }

    func setRange(_ range: Double?) {
        guard range != self.range else { return }
        self.range = range
        refresh()
    }

    func deactivate() {
        sanityTimer?.invalidate()
        sanityTimer = nil
        setPointerRate(0)
        press = nil
        stageView.acceptsPointer = false
        stageView.onPointer = nil
        moveTimer?.invalidate()
        moveTimer = nil
        pendingMove = nil
        removeWindowObservers()
        globalObservers.forEach(NotificationCenter.default.removeObserver)
        globalObservers = []
        panel?.orderOut(nil)
        stageView.removeFromSuperview()
        geometry = nil
        if isVisible {
            isVisible = false
            onVisibilityChange?(false)
        }
    }

    private func makePanel() -> MenuBarOverlayPanel {
        let panel = MenuBarOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // Not .fullScreenAuxiliary: Mochi stays off full-screen apps.
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

    private func observeStatusWindow(_ window: NSWindow) {
        guard window !== observedWindow else { return }
        removeWindowObservers()
        observedWindow = window
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                          NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification]
        for name in names {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func removeWindowObservers() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        observedWindow = nil
    }

    /// Reads the geometry the status item has right now (nil when it can't be determined).
    static func currentGeometry(of item: NSStatusItem?, range: Double?) -> (geometry: MenuBarGeometry?, screenFound: Bool, window: NSWindow?) {
        guard let item, let button = item.button, let window = button.window else { return (nil, false, nil) }
        let itemFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(window.frame) }
        let rightToLeft = NSApp.userInterfaceLayoutDirection == .rightToLeft
        let computed = screen.flatMap { screen in
            RoamGeometry.compute(screenFrame: screen.frame, notchLeftArea: screen.auxiliaryTopLeftArea, notchRightArea: screen.auxiliaryTopRightArea,
                                 barWindowFrame: window.frame, itemFrame: itemFrame, range: range, rightToLeft: rightToLeft)
        }
        return (computed, screen != nil, window)
    }

    /// Re-reads the geometry and repositions the panel.
    func refresh() {
        guard panel != nil else { return }
        let reading = Self.currentGeometry(of: item, range: range)
        if let window = reading.window { observeStatusWindow(window) }
        if DebugHooks.isEnabled { report(reading) }
        if reading.geometry == nil, !reading.screenFound {
            // Off-screen is normal while macOS hides an item that does not fit; a missing screen is not.
            if failingSince == nil { failingSince = now }
            if let since = failingSince, now - since >= Self.failureGrace {
                failingSince = nil
                onUnavailable?()
                return
            }
        } else {
            failingSince = nil
        }
        apply(reading.geometry)
    }

    private func report(_ reading: (geometry: MenuBarGeometry?, screenFound: Bool, window: NSWindow?)) {
        guard let window = reading.window, let item, let button = item.button else {
            lastReport = ["window": false]
            return
        }
        let itemFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        lastReport = [
            "barWindow": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
            "item": [itemFrame.minX, itemFrame.minY, itemFrame.width, itemFrame.height],
            "screen": window.screen.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
            "windowVisible": window.isVisible,
            "itemVisible": item.isVisible,
            "occlusionVisible": window.occlusionState.contains(.visible),
            "panelVisible": panel?.isVisible ?? false,
            "geometry": reading.geometry != nil,
            "pendingMove": pendingMove != nil,
        ]
    }

    private func apply(_ computed: MenuBarGeometry?) {
        guard let panel else { return }
        if let computed, let current = geometry, !computed.overlayFrame.insetBy(dx: -40, dy: -40).intersects(current.overlayFrame) {
            // Another display: wait a moment before following, hidden meanwhile.
            if pendingMove == nil || pendingMove?.geometry.overlayFrame.intersects(computed.overlayFrame) == false {
                pendingMove = (computed, now)
                scheduleMoveCheck()
            }
            if now - (pendingMove?.since ?? now) < Self.displayMoveDelay {
                setVisible(false)
                return
            }
            pendingMove = nil
        } else {
            pendingMove = nil
        }
        if computed != geometry {
            geometry = computed
            if let computed {
                panel.setFrame(computed.overlayFrame, display: false)
                stageView.frame = NSRect(origin: .zero, size: computed.overlayFrame.size)
                stageView.layout = MenuBarLayout.overlay(computed)
            }
            onGeometryChange?(computed)
        }
        updateVisibility()
    }

    private func scheduleMoveCheck() {
        moveTimer?.invalidate()
        let timer = Timer(timeInterval: Self.displayMoveDelay + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        moveTimer = timer
    }

    func updateVisibility() {
        guard panel != nil else { return }
        if pendingMove != nil {
            setVisible(false)
            return
        }
        let itemShown = geometry != nil && (item?.isVisible ?? false) && (item?.button?.window?.isVisible ?? false)
        setVisible(itemShown && system.allowsDrawing)
    }

    private func setVisible(_ show: Bool) {
        guard let panel else { return }
        if show {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
        // In a full-screen space the panel is not there: its occlusion state says so.
        let visible = show && panel.occlusionState.contains(.visible)
        if visible != isVisible {
            isVisible = visible
            onVisibilityChange?(visible)
        }
        setPointerRate(isVisible ? max(pointerRate, 4) : 0)
    }

    // MARK: Pointer

    /// Mochi's rect on screen while it is out of its bed on the bar (nil otherwise).
    var petScreenRect: CGRect? {
        guard let panel, let local = stageView.petRect, let geometry else { return nil }
        let frame = panel.frame
        let rect = CGRect(x: frame.minX + local.minX, y: frame.maxY - local.maxY, width: local.width, height: local.height)
        // In (or right over) the bed, clicks belong to the status item.
        let slot = geometry.homeSlot
        return rect.midX > slot.minX - 2 && rect.midX < slot.maxX + 2 ? nil : rect
    }

    private func setPointerRate(_ rate: Double) {
        guard rate != pointerRate || (rate > 0) != (pointerTimer != nil) else { return }
        pointerRate = rate
        pointerTimer?.invalidate()
        pointerTimer = nil
        if rate == 0 {
            if let panel, !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            stageView.acceptsPointer = false
            return
        }
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        timer.tolerance = 0.2 / rate
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    /// Lets the pointer in only while it is over Mochi (or holding it); polls faster near the bar.
    private func pollPointer() {
        guard let panel, isVisible else { return setPointerRate(0) }
        let mouse = NSEvent.mouseLocation
        let over = press != nil || (petScreenRect?.insetBy(dx: -2, dy: -2).contains(mouse) ?? false)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        if stageView.acceptsPointer != over { stageView.acceptsPointer = over }
        setPointerRate(panel.frame.insetBy(dx: -60, dy: -60).contains(mouse) ? 15 : 4)
    }

    private func handle(_ event: MenuBarPointerEvent) {
        switch event {
        case .down(let point):
            press = (point, false)
        case .dragged(let point):
            guard let current = press, !current.lifted else { return }
            let dx = point.x - current.start.x
            let dy = point.y - current.start.y
            // Downwards (y grows up), or far enough in any direction.
            guard (dy < -4 && hypot(dx, dy) > 5) || hypot(dx, dy) > 14, pointer?.menuBarPetCanBePickedUp() == true else { return }
            press = (current.start, true)
            pointer?.menuBarPetPickedUp(at: point)
        case .up(let point):
            guard let current = press else { return }
            press = nil
            if current.lifted { pointer?.menuBarPetReleased(at: point) } else { pointer?.menuBarPetClicked() }
            pollPointer()
        }
    }
}
