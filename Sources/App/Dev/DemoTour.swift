import AppKit
import SwiftUI
import TamagotchiCore

/// Development only (MACTAMAGOTCHI_DEBUG_STATE=1): a clean stage and captions for recording a
/// feature tour. "demo:backdrop:on|off" covers the desktop with a plain backdrop just above other
/// apps' windows (so nothing private ends up in a recording, whichever app becomes active);
/// "demo:backdrop:low" drops it to the normal level while other windows should show (desktop
/// adventures) and "demo:backdrop:high" raises it again. "demo:caption:<text>" / "demo:caption:off"
/// shows a caption; "demo:widget:on|off" shows what the desktop widget looks like.
@MainActor
final class DemoTour {
    private unowned let environment: AppEnvironment
    private var backdrop: NSWindow?
    private var caption: NSPanel?
    private var captionModel = CaptionModel()
    private var widget: NSPanel?
    private var raiser: Timer?
    /// Above every app's normal windows; the app's own windows go one higher.
    private static let stageLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    private static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 2)

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func start() {
        guard DebugHooks.isEnabled else { return }
        environment.debug.register("demo") { [weak self] argument in
            guard let self else { return }
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts.first ?? "" {
            case "backdrop":
                switch value {
                case "off": self.hideBackdrop()
                case "low": self.backdrop?.level = .normal
                case "high": self.backdrop?.level = Self.stageLevel
                default: self.showBackdrop()
                }
            case "caption": value.isEmpty || value == "off" ? self.hideCaption() : self.showCaption(value)
            case "widget": value == "off" ? self.hideWidget() : self.showWidget()
            default: break
            }
        }
    }

    private var screen: NSScreen? { NSScreen.screens.first }

    // MARK: Backdrop

    private func showBackdrop() {
        guard backdrop == nil, let screen else { return }
        let window = NSWindow(contentRect: screen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = Self.stageLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView = NSHostingView(rootView: Backdrop())
        window.orderFrontRegardless()
        backdrop = window
        // Keep the app's own windows (games, recap, settings, the desktop pet) above the stage.
        let raiser = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible && window.level.rawValue < Self.windowLevel.rawValue
                    && (window.styleMask.contains(.titled) || window is DesktopPetPanel) {
                    window.level = Self.windowLevel
                }
            }
        }
        RunLoop.main.add(raiser, forMode: .common)
        self.raiser = raiser
    }

    private func hideBackdrop() {
        raiser?.invalidate()
        raiser = nil
        backdrop?.orderOut(nil)
        backdrop = nil
    }

    // MARK: Caption

    private func showCaption(_ text: String) {
        guard let screen else { return }
        let panel = caption ?? makePanel(level: .floating)
        caption = panel
        if panel.contentView == nil {
            panel.contentView = NSHostingView(rootView: CaptionView(model: captionModel))
        }
        captionModel.text = text
        let width: CGFloat = 980
        let height: CGFloat = 92
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(x: visible.midX - width / 2, y: visible.minY + 18, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    private func hideCaption() {
        caption?.orderOut(nil)
    }

    // MARK: Widget preview

    private func showWidget() {
        guard let screen else { return }
        let panel = widget ?? makePanel(level: .floating)
        widget = panel
        let folder = environment.paths.home.appendingPathComponent("Widget", isDirectory: true)
        panel.contentView = NSHostingView(rootView: WidgetPreview(world: environment.world, scene: NSImage(contentsOf: folder.appendingPathComponent("scene.png"))))
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(x: visible.maxX - 400, y: visible.maxY - 240, width: 360, height: 200), display: true)
        panel.orderFrontRegardless()
    }

    private func hideWidget() {
        widget?.orderOut(nil)
    }

    private func makePanel(level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

@MainActor
@Observable
private final class CaptionModel {
    var text = ""
}

private struct CaptionView: View {
    let model: CaptionModel

    var body: some View {
        Text(model.text)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(Capsule().fill(Color(hex: 0x2B2233).opacity(0.86)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            .id(model.text)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.easeOut(duration: 0.25), value: model.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A soft, plain desktop for recordings.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xFCE7D6), Color(hex: 0xE9DDF7), Color(hex: 0xD6E8F5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(RadialGradient(colors: [Color.white.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 320))
                .frame(width: 640, height: 640)
                .offset(x: -380, y: -120)
            Circle().fill(RadialGradient(colors: [Color(hex: 0xFFD7B8).opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 280))
                .frame(width: 560, height: 560)
                .offset(x: 420, y: 200)
        }
        .ignoresSafeArea()
    }
}

/// What the medium desktop widget shows (the widget itself lives in the widget gallery).
private struct WidgetPreview: View {
    let world: CompanionWorld
    let scene: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let scene {
                Image(nsImage: scene).resizable().aspectRatio(contentMode: .fill)
                    .frame(height: 104).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            HStack(spacing: 6) {
                Circle().fill(Color(hex: 0xE2805A)).frame(width: 8, height: 8)
                Text(world.primarySession.map { $0.phase == .waitingForUser ? "Claude needs you" : "Claude is working" } ?? "\(world.settings.petName) is happy")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            Text("Mochi & Claude · desktop widget").font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 330, height: 190)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .padding(10)
    }
}
