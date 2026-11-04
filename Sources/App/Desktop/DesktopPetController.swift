import AppKit
import Observation
import SwiftUI
import TamagotchiCore

/// A borderless panel that never takes focus.
final class DesktopPetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class DesktopPetState {
    var visible = true
    var showsCompanion = false
}

/// The optional floating pet: transparent, frameless, draggable, never steals focus,
/// remembers its position per display and stays within the visible screen area.
@MainActor
final class DesktopPetController {
    private unowned let environment: AppEnvironment
    private var panel: DesktopPetPanel?
    private var builtClickThrough: Bool?
    private var builtSize: DesktopPetSize?
    private let state = DesktopPetState()
    private var observers: [NSObjectProtocol] = []

    init(environment: AppEnvironment) {
        self.environment = environment
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restorePosition() }
        })
        observeWorld()
    }

    private var world: CompanionWorld { environment.world }
    private var settings: AppSettings { environment.settingsStore.settings }

    /// Creates, rebuilds, shows or hides the panel to match settings.
    func applySettings() {
        guard settings.desktopPetEnabled else {
            panel?.orderOut(nil)
            environment.ui.desktopPetVisible = false
            return
        }
        // Click-through can only be turned off again by rebuilding the window:
        // once `ignoresMouseEvents` is set explicitly, transparent pixels stop passing clicks through.
        if panel == nil || builtClickThrough != settings.desktopPetClickThrough || builtSize != settings.desktopPetSize {
            panel?.orderOut(nil)
            panel = makePanel()
        }
        guard let panel else { return }
        panel.level = settings.desktopPetAlwaysOnTop ? .floating : .normal
        restorePosition()
        panel.orderFrontRegardless()
        environment.ui.desktopPetVisible = true
        updateCompanionVisibility()
    }

    func hide() {
        environment.settingsStore.settings.desktopPetEnabled = false
        applySettings()
    }

    private func makePanel() -> DesktopPetPanel {
        let height = CGFloat(settings.desktopPetSize.height)
        let layout = SceneLayout.desktop(height: height, withCompanion: true)
        let panel = DesktopPetPanel(contentRect: NSRect(origin: .zero, size: layout.size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.title = "\(settings.petName) (desktop pet)"
        if settings.desktopPetClickThrough {
            panel.ignoresMouseEvents = true
        }
        let root = DesktopPetView(world: world, state: state)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: layout.size)
        let container = DesktopPetContainerView(frame: NSRect(origin: .zero, size: layout.size), layout: layout)
        container.addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]
        container.onClick = { [weak self] point in self?.handleClick(at: point, layout: layout) }
        container.onDragEnded = { [weak self] in self?.savePosition() }
        container.onHold = { [weak self] point in
            guard let self, layout.petFrame.insetBy(dx: -4, dy: -4).contains(point) else { return }
            PurrSession.shared.begin(world: self.world)
        }
        container.onMenu = { [weak self] event, view in self?.showMenu(event: event, in: view) }
        container.isCompanionVisible = { [weak self] in self?.state.showsCompanion ?? false }
        panel.contentView = container

        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                self?.state.visible = panel?.occlusionState.contains(.visible) ?? false
            }
        })
        builtClickThrough = settings.desktopPetClickThrough
        builtSize = settings.desktopPetSize
        return panel
    }

    private func handleClick(at point: NSPoint, layout: SceneLayout) {
        // `point` is in flipped (top-left origin) view coordinates.
        if layout.petFrame.insetBy(dx: -4, dy: -4).contains(point) {
            world.interact(.pet)
        } else if state.showsCompanion, layout.companionFrame.contains(point) {
            world.pokeCompanion()
        }
    }

    private func showMenu(event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        let pet = NSMenuItem(title: "Pet \(settings.petName)", action: #selector(MenuTarget.pet), keyEquivalent: "")
        let play = NSMenuItem(title: "Play", action: #selector(MenuTarget.play), keyEquivalent: "")
        let top = NSMenuItem(title: "Always on Top", action: #selector(MenuTarget.toggleTop), keyEquivalent: "")
        top.state = settings.desktopPetAlwaysOnTop ? .on : .off
        let hide = NSMenuItem(title: "Hide Desktop Pet (\(HotKey.displayString))", action: #selector(MenuTarget.hide), keyEquivalent: "")
        let settingsItem = NSMenuItem(title: "Desktop Pet Settings…", action: #selector(MenuTarget.settings), keyEquivalent: "")
        let target = MenuTarget(controller: self)
        for item in [pet, play, top, hide, settingsItem] { item.target = target }
        menu.addItem(pet)
        menu.addItem(play)
        menu.addItem(.separator())
        menu.addItem(top)
        menu.addItem(hide)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        objc_setAssociatedObject(menu, &MenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    final class MenuTarget: NSObject {
        nonisolated(unsafe) static var key: UInt8 = 0
        weak var controller: DesktopPetController?
        init(controller: DesktopPetController) { self.controller = controller }
        @MainActor @objc func pet() { controller?.world.interact(.pet) }
        @MainActor @objc func play() { controller?.world.interact(.play) }
        @MainActor @objc func toggleTop() {
            controller?.environment.settingsStore.settings.desktopPetAlwaysOnTop.toggle()
            controller?.applySettings()
        }
        @MainActor @objc func hide() { controller?.hide() }
        @MainActor @objc func settings() { controller?.environment.windows.showSettings(tab: .desktop) }
    }

    // MARK: Companion visibility

    /// The companion appears for interesting moments and leaves again so the pet
    /// stays compact while you work.
    private func observeWorld() {
        withObservationTracking {
            _ = world.activeCaption
            _ = world.interaction
            _ = world.primarySession?.phase
            _ = world.companionPresent
            _ = settings.desktopPetShowsCompanion
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateCompanionVisibility()
                self?.observeWorld()
            }
        }
    }

    private func updateCompanionVisibility() {
        let interesting = world.activeCaption != nil || world.interaction != nil || world.primarySession?.phase == .waitingForUser
        let shows = settings.desktopPetShowsCompanion && world.companionPresent && interesting
        if state.showsCompanion != shows { state.showsCompanion = shows }
        // Captions expire on their own; check again shortly after.
        if shows {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.updateCompanionVisibility() }
            }
        }
    }

    // MARK: Position

    private func screenID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func savePosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = (panel.frame.minX - visible.minX) / max(1, visible.width - panel.frame.width)
        let y = (panel.frame.minY - visible.minY) / max(1, visible.height - panel.frame.height)
        environment.settingsStore.settings.desktopPetPosition = DesktopPetPosition(screenID: screenID(screen), relativeX: Double(x), relativeY: Double(y))
    }

    func restorePosition() {
        guard let panel else { return }
        let size = panel.frame.size
        let saved = settings.desktopPetPosition
        let screen = NSScreen.screens.first { saved?.screenID != nil && screenID($0) == saved?.screenID } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        var origin: NSPoint
        if let saved {
            origin = NSPoint(x: visible.minX + CGFloat(saved.relativeX) * (visible.width - size.width),
                             y: visible.minY + CGFloat(saved.relativeY) * (visible.height - size.height))
        } else {
            // Default: bottom-right corner, above the Dock.
            origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 12)
        }
        let layout = SceneLayout.desktop(height: size.height, withCompanion: true)
        panel.setFrameOrigin(Self.clamp(origin, size: size, visible: visible, layout: layout))
    }

    /// Keeps the pet itself fully on screen; the transparent area reserved for the
    /// companion may extend past the edge.
    static func clamp(_ origin: NSPoint, size: NSSize, visible: NSRect, layout: SceneLayout) -> NSPoint {
        let pet = layout.petFrame
        let minX = visible.minX - pet.minX
        let maxX = visible.maxX - pet.maxX
        // Flipped layout: pet.maxY is measured from the top of the window.
        let minY = visible.minY - (size.height - pet.maxY)
        let maxY = visible.maxY - size.height + max(0, pet.minY - 30)
        return NSPoint(x: min(max(origin.x, minX), maxX), y: min(max(origin.y, minY), maxY))
    }
}

/// Handles dragging, clicks and the context menu, so the window never needs focus.
final class DesktopPetContainerView: NSView {
    let layout: SceneLayout
    var onClick: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    /// The mouse stayed down without dragging (flipped view coordinates).
    var onHold: ((NSPoint) -> Void)?
    private var hold: DispatchWorkItem?
    var onMenu: ((NSEvent, NSView) -> Void)?
    var isCompanionVisible: (() -> Bool)?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var dragged = false

    init(frame: NSRect, layout: SceneLayout) {
        self.layout = layout
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only the characters are interactive; everything else is left alone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let pet = layout.petFrame.insetBy(dx: -6, dy: -6)
        let companion = layout.companionFrame
        if pet.contains(local) || (isCompanionVisible?() == true && companion.contains(local)) {
            return self
        }
        return nil
    }

    override func resetCursorRects() {
        addCursorRect(layout.petFrame, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        dragged = false
        let point = convert(event.locationInWindow, from: nil)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.dragged else { return }
            MainActor.assumeIsolated { self.onHold?(point) }
        }
        hold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStart.x
        let dy = now.y - dragStart.y
        if abs(dx) + abs(dy) > 3, !PurrSession.shared.isPurring { dragged = true }
        guard dragged else { return }
        hold?.cancel()
        NSCursor.closedHand.set()
        var origin = NSPoint(x: windowStart.x + dx, y: windowStart.y + dy)
        if let visible = (NSScreen.screens.first { $0.frame.contains(now) } ?? window.screen ?? NSScreen.main)?.visibleFrame {
            origin = MainActor.assumeIsolated {
                DesktopPetController.clamp(origin, size: window.frame.size, visible: visible, layout: layout)
            }
        }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            windowStart = nil
        }
        hold?.cancel()
        hold = nil
        if PurrSession.shared.isPurring {
            PurrSession.shared.end()
        } else if dragged {
            NSCursor.openHand.set()
            onDragEnded?()
        } else {
            onClick?(convert(event.locationInWindow, from: nil))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event, self)
    }
}

struct DesktopPetView: View {
    let world: CompanionWorld
    let state: DesktopPetState

    var body: some View {
        SceneView(world: world, style: .desktop, visible: state.visible, showCompanion: state.showsCompanion)
            .allowsHitTesting(false)
    }
}
