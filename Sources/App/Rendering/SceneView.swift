import QuartzCore
import SwiftUI
import TamagotchiCore

/// The animated two-character world. Animation frames are driven by a
/// TimelineView only while visible; state changes come from the world.
struct SceneView: View {
    enum Style { case popover, desktop }

    let world: CompanionWorld
    var style: Style = .popover
    var visible: Bool = true
    var showCompanion: Bool = true
    /// Pause when the hosting window is closed or covered. The popover passes false: its
    /// window never reports itself visible, and `visible` already tracks it exactly.
    var followsWindowVisibility = true
    /// Upper bound for the frame rate while something is happening.
    var maxFrameRate: Double = 30
    var onPetTap: (() -> Void)?
    var onCompanionTap: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var windowVisible = false
    /// A press on the pet that turns into petting (and purring) if held.
    @State private var hold: DispatchWorkItem?

    var body: some View {
        let snapshot = SceneSnapshot(world: world)
        GeometryReader { geometry in
            let layout = style == .popover
                ? SceneLayout.popover(width: geometry.size.width, height: geometry.size.height)
                : SceneLayout.desktop(height: geometry.size.height, withCompanion: showCompanion)
            // Full frame rate only while something is actually happening.
            let busy = snapshot.interaction != nil || snapshot.pet.duration != nil || snapshot.companion.duration != nil
            // The desktop pet is always on screen, so its calm loop runs at a lower rate; the popover
            // is only open briefly, so it always gets the full rate.
            let calm = style == .desktop ? 1.0 / 15 : (style == .popover ? 1.0 / maxFrameRate : 1.0 / min(maxFrameRate, 30))
            let interval = snapshot.reducedMotion ? 1.0 / 12 : (busy ? 1.0 / maxFrameRate : calm)
            let running = visible && (windowVisible || !followsWindowVisibility)
            TimelineView(.animation(minimumInterval: interval, paused: !running)) { timeline in
                // The frame must depend on the tick's date: SwiftUI skips redrawing a Canvas
                // whose captured inputs are unchanged, which froze the scene between state changes.
                let frameDate = timeline.date
                Canvas(rendersAsynchronously: false) { context, _ in
                    _ = frameDate
                    let start = CACurrentMediaTime()
                    let hour = Calendar.current.component(.hour, from: Date())
                    SceneRenderer.draw(snapshot, layout: layout, in: context, time: ProcessInfo.processInfo.systemUptime,
                                       dark: colorScheme == .dark, hour: hour, showCompanion: showCompanion)
                    if FrameStats.enabled {
                        MainActor.assumeIsolated {
                            FrameStats.shared.record(style == .popover ? "scene" : "desktop", drawStart: start, drawEnd: CACurrentMediaTime())
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                hitTargets(layout)
            }
            .overlay(alignment: .topLeading) {
                if style == .popover { SceneSpeechOverlay(world: world, layout: layout) }
            }
        }
        .background(WindowVisibilityReader(visible: $windowVisible))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private func hitTargets(_ layout: SceneLayout) -> some View {
        if let onPetTap {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: layout.petFrame.width, height: layout.petFrame.height)
                .offset(x: layout.petFrame.minX, y: layout.petFrame.minY)
                .gesture(petGesture(tap: onPetTap))
                .help("\(world.settings.petName) — click to pet, or press and hold")
        }
        if let onCompanionTap, world.companionPresent, showCompanion {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: layout.companionFrame.width, height: layout.companionFrame.height)
                .offset(x: layout.companionFrame.minX, y: layout.companionFrame.minY)
                .onTapGesture(perform: onCompanionTap)
                .help("\(world.settings.companionName) — your Claude Code companion")
        }
    }

    /// A click pets once; pressing and holding keeps petting, and the trackpad purrs.
    private func petGesture(tap: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard hold == nil else { return }
                let work = DispatchWorkItem { [world] in PurrSession.shared.begin(world: world) }
                hold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
            .onEnded { _ in
                hold?.cancel()
                hold = nil
                if PurrSession.shared.isPurring {
                    PurrSession.shared.end()
                } else {
                    tap()
                }
            }
    }

    private var accessibilityDescription: String {
        let petName = world.settings.petName
        let companionName = world.settings.companionName
        var text = "\(petName) is \(world.pet.current.animation.title.lowercased())."
        if world.companionPresent {
            text += " \(companionName) is \(world.companion.current.animation.title.lowercased())."
        }
        if let session = world.primarySession {
            text += " \(session.displayName): \(session.statusLine(now: Date()))."
        }
        return text
    }
}

/// Reports whether the hosting window is really on screen (not closed, hidden,
/// minimized or fully covered), so animations never run for nobody.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = { value in
            if visible != value { visible = value }
        }
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                                              NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            for name in names {
                let closing = name == NSWindow.willCloseNotification
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if closing { self?.report(false) } else { self?.update() }
                    }
                })
            }
            update()
        }

        private func update() {
            guard let window else { return report(false) }
            report(window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        private func report(_ value: Bool) {
            // Never mutate SwiftUI state during a view update.
            DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
        }

        override func removeFromSuperview() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            super.removeFromSuperview()
        }
    }
}

