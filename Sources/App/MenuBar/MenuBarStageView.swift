import AppKit
import Observation
import QuartzCore
import SwiftUI
import TamagotchiCore

/// One sprite of the menu-bar stage: a CALayer whose contents are drawn with
/// SwiftUI's GraphicsContext (so the same PetRenderer/CompanionRenderer art is used)
/// through a reusable ImageRenderer into a reusable bitmap.
///
/// Rendering this way costs a fraction of a TimelineView-driven NSHostingView in a
/// status bar window, and frames whose quantized drawing state did not change are
/// skipped entirely.
@MainActor
final class SpriteSurface {
    let layer = CALayer()
    private var bitmap: CGContext?
    private var bitmapWidth = 0
    private var bitmapHeight = 0
    private var lastSignature: [Int32] = []
    private let renderer = ImageRenderer(content: SpriteCanvas.empty)
    private(set) var renders = 0

    init() {
        let none = NSNull()
        layer.actions = ["contents": none, "position": none, "bounds": none, "frame": none, "hidden": none, "opacity": none]
        layer.anchorPoint = .zero
        layer.contentsGravity = .resize
        layer.isHidden = true
    }

    var isHidden: Bool {
        get { layer.isHidden }
        set {
            guard layer.isHidden != newValue else { return }
            layer.isHidden = newValue
            if newValue {
                layer.contents = nil
                lastSignature = []
            }
        }
    }

    /// Forgets what was drawn, so the next update renders even if nothing seems to have changed
    /// (the old picture stays up until then — no blank frame).
    func invalidate() { lastSignature = [] }

    /// The legibility halo as the layer's own shadow: a soft ring in the bar's tone that the
    /// window server draws, so it costs the app nothing per frame.
    func setHalo(dark: Bool, enabled: Bool) {
        let color = dark ? NSColor.black.withAlphaComponent(0.6) : NSColor.white
        layer.shadowColor = enabled ? color.cgColor : nil
        layer.shadowOpacity = enabled ? (dark ? 0.9 : 1) : 0
        layer.shadowRadius = 1.1
        layer.shadowOffset = .zero
    }

    /// Places the sprite and redraws it if its signature changed. Returns true if it rendered.
    @discardableResult
    func update(frame rect: CGRect, scale: CGFloat, signature: [Int32], draw: @escaping (GraphicsContext) -> Void) -> Bool {
        let width = Int(ceil(rect.width * scale))
        let height = Int(ceil(rect.height * scale))
        guard width > 0, height > 0 else {
            isHidden = true
            return false
        }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let resized = width != bitmapWidth || height != bitmapHeight
        if !resized, !layer.isHidden, signature == lastSignature {
            if layer.position != rect.origin { layer.position = rect.origin }
            return false
        }
        if resized || bitmap == nil {
            bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            bitmapWidth = width
            bitmapHeight = height
        }
        guard let bitmap else { return false }
        bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
        renderer.content = SpriteCanvas(size: bounds.size, draw: draw)
        renderer.proposedSize = ProposedViewSize(bounds.size)
        bitmap.saveGState()
        bitmap.scaleBy(x: scale, y: scale)
        renderer.render(rasterizationScale: scale) { _, render in render(bitmap) }
        bitmap.restoreGState()
        // Geometry and contents change in the same transaction: the sprite never shows the old
        // picture in the new place.
        if layer.bounds != bounds { layer.bounds = bounds }
        if layer.position != rect.origin { layer.position = rect.origin }
        if layer.contentsScale != scale { layer.contentsScale = scale }
        layer.contents = bitmap.makeImage()
        layer.isHidden = false
        lastSignature = signature
        renders += 1
        return true
    }
}

struct SpriteCanvas: View {
    var size: CGSize
    var draw: (GraphicsContext) -> Void

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in draw(context) }
            .frame(width: size.width, height: size.height)
    }

    static let empty = SpriteCanvas(size: CGSize(width: 1, height: 1)) { _ in }
}

/// What the pointer does to Mochi on the bar (screen points).
enum MenuBarPointerEvent {
    case down(CGPoint)
    case dragged(CGPoint)
    case up(CGPoint)
}

/// The surface the menu-bar stage draws on: the overlay panel's content in the
/// `.roam` style, a subview of the status item button in the `.stage` style.
/// Takes clicks only on Mochi itself, and only while the overlay lets the pointer in.
@MainActor
final class MenuBarStageView: NSView {
    var layout: MenuBarLayout? {
        didSet {
            if layout != oldValue {
                homeSprite.invalidate()
                actorSprite.invalidate()
                onLayoutChange?()
            }
        }
    }
    /// Called after the layout changed, so the driver can draw the new frame at once.
    var onLayoutChange: (() -> Void)?
    /// Draw the legibility halo into the sprites (offscreen renders), or leave it to the layers'
    /// shadows (live: drawn by the window server, free for the app).
    var canvasHalo = false {
        didSet {
            guard canvasHalo != oldValue else { return }
            homeSprite.invalidate()
            actorSprite.invalidate()
            applyHalo()
        }
    }
    /// The bar is dark: the halo takes its tone.
    var darkBar = false {
        didSet { if darkBar != oldValue { applyHalo() } }
    }

    private func applyHalo() {
        homeSprite.setHalo(dark: darkBar, enabled: !canvasHalo)
        actorSprite.setHalo(dark: darkBar, enabled: !canvasHalo)
    }
    private let homeSprite = SpriteSurface()
    private let actorSprite = SpriteSurface()
    /// Where Mochi was last drawn (layout points), when it is on the bar to be clicked.
    private(set) var petRect: CGRect?
    /// The overlay lets the pointer in while it is over Mochi.
    var acceptsPointer = false
    var onPointer: ((MenuBarPointerEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(homeSprite.layer)
        layer?.addSublayer(actorSprite.layer)
        setAccessibilityElement(false)
        applyHalo()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsPointer, let petRect, layout?.isStage == false else { return nil }
        let local = convert(point, from: superview)
        return petRect.insetBy(dx: -3, dy: -3).contains(CGPoint(x: local.x, y: bounds.height - local.y)) ? self : nil
    }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPointer?(.down(NSEvent.mouseLocation)) }
    override func mouseDragged(with event: NSEvent) { onPointer?(.dragged(NSEvent.mouseLocation)) }
    override func mouseUp(with event: NSEvent) { onPointer?(.up(NSEvent.mouseLocation)) }

    var renders: Int { homeSprite.renders + actorSprite.renders }

    /// The pointer in layout coordinates (y down), when it is anywhere near the band.
    func pointerInLayout() -> CGPoint? {
        guard let window, let layout, !layout.isStage else { return nil }
        let mouse = NSEvent.mouseLocation
        let local = convert(window.convertPoint(fromScreen: mouse), from: nil)
        let point = CGPoint(x: local.x, y: bounds.height - local.y)
        guard point.x > -160, point.x < bounds.width + 160, point.y > -40, point.y < bounds.height + 140 else { return nil }
        return point
    }

    /// Draws one frame. Mochi near home shares one sprite with the bed and Patch; away
    /// from home it gets its own, so a static home costs nothing while Mochi plays.
    @discardableResult
    func render(_ snapshot: MenuBarSnapshot, time: TimeInterval, dark: Bool) -> MenuBarFrame? {
        guard let layout else { return nil }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var frame = MenuBarPetCanvas.frame(snapshot, layout: layout, time: time, pointer: pointerInLayout())
        // On device pixels: motion stays crisp (and sub-pixel creep never re-renders a sprite).
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        frame.petX = snap(frame.petX)
        frame.petLift = snap(frame.petLift)
        frame.patchOffset = snap(frame.patchOffset)
        frame.props = frame.props.map { ($0.prop, CGPoint(x: snap($0.point.x), y: snap($0.point.y))) }
        let den = MenuBarDen.look(snapshot, layout: layout, time: time)
        let denSignature = MenuBarDen.signature(den, time: time)
        let reduced = snapshot.reducedMotion
        /// Draws one part, cut off at the den's edge, with the den's z's and glow after Mochi.
        func paint(_ part: MenuBarPart, origin: CGPoint, in g: GraphicsContext) {
            var g = g
            if let den { g.clip(to: Path(den.visible.offsetBy(dx: -origin.x, dy: -origin.y))) }
            MenuBarPetCanvas.draw(frame, snapshot: snapshot, layout: layout, part: part, in: g, offset: origin, dark: dark, halo: canvasHalo)
            if let den, part != .home {
                var decor = g
                decor.translateBy(x: -origin.x, y: -origin.y)
                MenuBarDen.draw(den, layout: layout, time: time, dark: dark, reduced: reduced, in: decor)
            }
        }
        let body = CGRect(x: frame.petX - layout.petWidth * 0.55, y: layout.baseline - frame.petLift - layout.petHeight * 1.05,
                          width: layout.petWidth * 1.1, height: layout.petHeight * 1.1)
        let shown = den.map { body.intersection($0.visible) } ?? body
        petRect = frame.petOpacity > 0.5 && !shown.isNull && shown.width > 3 ? shown : nil
        // The layer is not flipped: sprites span the full band height, so only x matters.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if layout.isStage {
            let rect = CGRect(origin: .zero, size: layout.size)
            homeSprite.update(frame: rect, scale: scale,
                              signature: MenuBarPetCanvas.signature(frame, snapshot: snapshot, layout: layout, part: .all, origin: .zero, dark: dark, backingScale: scale)) { g in
                MenuBarPetCanvas.draw(frame, snapshot: snapshot, layout: layout, part: .all, in: g, dark: dark, halo: self.canvasHalo)
            }
            actorSprite.isHidden = true
            return frame
        }
        let homeRect = layout.homeRect
        var actorRect = MenuBarPetCanvas.actorBounds(frame, layout: layout)
        if let den, let decor = MenuBarDen.decorationRect(den, layout: layout) { actorRect = actorRect.union(decor) }
        if actorRect.insetBy(dx: -6, dy: 0).intersects(homeRect) {
            let rect = homeRect.union(actorRect)
            homeSprite.update(frame: rect, scale: scale,
                              signature: MenuBarPetCanvas.signature(frame, snapshot: snapshot, layout: layout, part: .all, origin: rect.origin, dark: dark, backingScale: scale) + denSignature) { g in
                paint(.all, origin: rect.origin, in: g)
            }
            actorSprite.isHidden = true
        } else {
            homeSprite.update(frame: homeRect, scale: scale,
                              signature: MenuBarPetCanvas.signature(frame, snapshot: snapshot, layout: layout, part: .home, origin: homeRect.origin, dark: dark, backingScale: scale)) { g in
                paint(.home, origin: homeRect.origin, in: g)
            }
            actorSprite.update(frame: actorRect, scale: scale,
                               signature: MenuBarPetCanvas.signature(frame, snapshot: snapshot, layout: layout, part: .actors, origin: actorRect.origin, dark: dark, backingScale: scale) + denSignature) { g in
                paint(.actors, origin: actorRect.origin, in: g)
            }
        }
        return frame
    }

    func clear() {
        homeSprite.isHidden = true
        actorSprite.isHidden = true
        petRect = nil
    }
}

/// Drives the stage: captures world state on changes, and renders with an adaptive
/// frame rate chosen from state (not per frame): ~30 fps for fast dashes, ~24 fps while
/// Mochi travels, plays or reacts, ~10 fps when calm (blinks and glances still show),
/// ~6 fps asleep, 0 when nothing is visible.
@MainActor
final class MenuBarStageDriver {
    private let world: CompanionWorld
    let view = MenuBarStageView(frame: .zero)
    private(set) var snapshot: MenuBarSnapshot
    private var timer: Timer?
    private(set) var fps: Double = 0
    private var nextRateCheck: TimeInterval = .infinity
    private var active = true
    private(set) var framesDrawn = 0

    var visible = false {
        didSet {
            guard visible != oldValue else { return }
            if !visible { view.clear() }
            reschedule()
        }
    }

    var dark = false {
        didSet {
            view.darkBar = dark
            if dark != oldValue, visible { tick() }
        }
    }

    init(world: CompanionWorld) {
        self.world = world
        snapshot = MenuBarSnapshot(world: world)
        view.onLayoutChange = { [weak self] in self?.tick() }
        observe()
    }

    func stop() {
        active = false
        visible = false
        timer?.invalidate()
        timer = nil
        fps = 0
    }

    private func observe() {
        guard active else { return }
        withObservationTracking {
            snapshot = MenuBarSnapshot(world: world)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.observe()
                self.reschedule()
            }
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func tick() {
        guard visible else { return }
        let t = now
        view.render(snapshot, time: t, dark: dark)
        framesDrawn += 1
        if t >= nextRateCheck { reschedule() }
    }

    func reschedule() {
        let t = now
        let choice = visible ? Self.frameRate(snapshot, time: t) : (fps: 0.0, until: TimeInterval.infinity)
        nextRateCheck = choice.until
        setFPS(choice.fps)
    }

    private func setFPS(_ rate: Double) {
        if rate == fps, (rate == 0) == (timer == nil) { return }
        fps = rate
        timer?.invalidate()
        timer = nil
        guard rate > 0 else { return }
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.12 / rate
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// The frame rate the current state needs, and when to look again (the next
    /// segment boundary, one-shot end or celebration end).
    static func frameRate(_ snapshot: MenuBarSnapshot, time: TimeInterval) -> (fps: Double, until: TimeInterval) {
        let roam = snapshot.roamer.sample(at: time)
        var until = roam.segmentEnd
        func soonest(_ t: TimeInterval) { if t > time { until = min(until, t) } }
        if let duration = snapshot.pet.duration { soonest(snapshot.pet.startedAt + duration) }
        if let duration = snapshot.companion.duration { soonest(snapshot.companion.startedAt + duration) }
        if let playback = snapshot.interaction { soonest(playback.startedAt + playback.duration) }
        if let burst = snapshot.burst { soonest(burst.startedAt + 2.6) }
        for track in snapshot.roamer.props { soonest(track.start); soonest(track.end) }
        let petOneShot = snapshot.petOneShotActive(at: time)
        let companionOneShot = snapshot.companion.duration.map { time < snapshot.companion.startedAt + $0 } ?? false
        let celebrating = snapshot.burst.map { time >= $0.startedAt && time - $0.startedAt < 2.6 } ?? false
        let busy = snapshot.interactionActive(at: time) || petOneShot || companionOneShot || celebrating
            || roam.isTravelling || roam.isOneShot || !roam.props.isEmpty || roam.style != .plain
        let sleeping = (roam.animation == .sleep || roam.animation == .curl) && !petOneShot
        let patchQuiet = !snapshot.companionPresent || [.sleep, .rest, .offline, .absent].contains(snapshot.companion.animation)
        // Dashes and zoomies move ~4 pt a frame at 24 fps; 30 keeps them from strobing. A walk is
        // smooth at 20. Calm still runs at 10 fps so blinks (0.17 s) always show; asleep needs only the Z's.
        let segment = snapshot.roamer.segments.last { $0.start <= time && time < $0.end }
        let travelling = (segment?.travels ?? false) && segment?.motion != .fade
        let fast = travelling && (segment?.cruiseSpeed ?? 0) > 95
        let walking = travelling && (segment?.cruiseSpeed ?? 0) < 50 && !snapshot.interactionActive(at: time) && !petOneShot
            && roam.props.isEmpty
        var rate: Double = fast ? 30 : (walking ? 20 : (busy ? 24 : (sleeping && patchQuiet ? 6 : 10)))
        if snapshot.reducedMotion { rate = min(rate, 10) }
        if roam.opacity < 0.01, roam.activity == .exploring {
            // Away on an adventure: only home (Patch, the badge, a celebration) is left to draw.
            let homeBusy = companionOneShot || celebrating || snapshot.interactionActive(at: time)
            rate = homeBusy ? 24 : (patchQuiet ? 2 : 8)
        }
        return (rate, until)
    }
}
