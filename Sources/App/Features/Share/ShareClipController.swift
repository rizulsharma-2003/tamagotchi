import AppKit
import ImageIO
import SwiftUI
import TamagotchiCore
import UniformTypeIdentifiers

/// Saves a short animated GIF of the scene, rendered offscreen from the app's own drawing.
///
/// Recording only takes cheap snapshots of the world in real time; the frames are drawn afterwards
/// (poses are pure functions of the snapshot and the time) and encoded off the main thread. Nothing
/// is captured from the screen.
@MainActor
final class ShareClipController {
    private unowned let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }

    static let duration: TimeInterval = 5
    static let framesPerSecond: Double = 20
    static let sceneSize = CGSize(width: 360, height: 178)
    /// 540 × 267 pixels: crisp enough to share, a few MB at most.
    static let pixelScale: CGFloat = 1.5

    private struct Frame {
        var snapshot: SceneSnapshot
        var time: TimeInterval
    }

    private struct Recording {
        var frames: [Frame] = []
        var nextFrameAt: TimeInterval
        var folder: URL
        var reveal: Bool
    }

    private var recording: Recording?
    private var timer: Timer?
    private var saving = false
    /// The last clip written (for debugging and tests of the pipeline).
    private(set) var lastClip: URL?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Registers the debug request "clip" (records into `<home>/clips`, never opens Finder).
    func start() {
        environment.debug.register("clip") { [weak self] _ in
            // Debug clips stay inside the app's own folder and never open Finder.
            guard let self else { return }
            self.capture(into: self.environment.paths.home.appendingPathComponent("clips", isDirectory: true), reveal: false)
        }
        environment.debug.registerState("clip") { [weak self] in
            ["recording": self?.recording != nil, "saving": self?.saving ?? false, "last": self?.lastClip?.lastPathComponent ?? "none"]
        }
    }

    var isBusy: Bool { recording != nil || saving }

    /// Records five seconds and saves the GIF to Downloads, then shows it in Finder.
    func captureClip() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        capture(into: downloads, reveal: true)
    }

    func capture(into folder: URL, reveal: Bool) {
        guard !isBusy else {
            world.showToast(title: "Already recording", detail: "Your clip is almost ready.", seconds: 2.5)
            return
        }
        // Show what's being recorded when asked from the menu.
        if reveal, !environment.ui.popoverVisible { environment.statusItem.showPopover() }
        recording = Recording(nextFrameAt: ProcessInfo.processInfo.systemUptime + 0.15, folder: folder, reveal: reveal)
        sayCheese()
        world.showToast(title: "Recording a clip…", detail: "5 seconds of \(names)", seconds: Self.duration)
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond / 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var names: String {
        let settings = world.settings
        return world.companionPresent ? "\(settings.petName) and \(settings.companionName)" : settings.petName
    }

    /// If nothing is happening, give the clip a moment worth sharing: a high five, or a wave.
    private func sayCheese() {
        guard world.interaction == nil, !world.pet.isPlayingOneShot, world.primarySession?.phase != .waitingForUser else { return }
        if world.companionPresent, world.startInteraction(.highFive, priority: .user) { return }
        world.playPet(.wave)
    }

    /// Takes a snapshot for every frame time that has passed (frame times are exact, so the GIF
    /// plays smoothly even when a timer tick is late).
    private func tick() {
        guard var current = recording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let total = Int(Self.duration * Self.framesPerSecond)
        while current.nextFrameAt <= now, current.frames.count < total {
            current.frames.append(Frame(snapshot: SceneSnapshot(world: world), time: current.nextFrameAt))
            current.nextFrameAt += 1 / Self.framesPerSecond
        }
        recording = current
        if current.frames.count >= total { finish() }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        guard let done = recording else { return }
        recording = nil
        saving = true
        world.showToast(title: "Saving your clip…", detail: "Turning \(done.frames.count) frames into a GIF", seconds: 8)
        let dark = StatusItemController.isDark(NSApp.effectiveAppearance)
        let hour = Calendar.current.component(.hour, from: Date())
        let label = "\(world.settings.petName) & \(world.settings.companionName)"
        let url = Self.uniqueURL(in: done.folder, petName: world.settings.petName)
        Task { @MainActor in
            var images: [CGImage] = []
            images.reserveCapacity(done.frames.count)
            for (index, frame) in done.frames.enumerated() {
                if let image = Self.render(frame.snapshot, time: frame.time, dark: dark, hour: hour, label: label) { images.append(image) }
                // Keep the popover responsive while drawing.
                if index % 4 == 3 { await Task.yield() }
            }
            let frames = RenderedFrames(images: images)
            let delay = 1 / Self.framesPerSecond
            let written = await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                return Self.writeGIF(frames.images, delay: delay, to: url)
            }.value
            self.saving = false
            self.saved(written ? url : nil, reveal: done.reveal)
        }
    }

    private func saved(_ url: URL?, reveal: Bool) {
        guard let url else {
            world.showToast(title: "Couldn't save the clip", detail: "Check that the Downloads folder is writable.", seconds: 5)
            return
        }
        lastClip = url
        world.showToast(title: "Saved!", detail: "\(url.lastPathComponent) is in \(url.deletingLastPathComponent().lastPathComponent).", seconds: 6)
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: Drawing and encoding

    /// One frame, drawn exactly as the popover draws it, plus a tiny label in the corner.
    static func render(_ snapshot: SceneSnapshot, time: TimeInterval, dark: Bool, hour: Int, label: String) -> CGImage? {
        let view = Canvas { context, size in
            SceneRenderer.draw(snapshot, layout: .popover(width: size.width, height: size.height), in: context, time: time, dark: dark, hour: hour)
            watermark(label, in: context, size: size, dark: dark || snapshot.theme == .cyberpunk)
        }
        .frame(width: sceneSize.width, height: sceneSize.height)
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = pixelScale
        renderer.isOpaque = true
        return renderer.cgImage
    }

    static func watermark(_ label: String, in g: GraphicsContext, size: CGSize, dark: Bool) {
        let text = Text("\(Image(systemName: "pawprint.fill")) \(label)")
            .font(.system(size: 7, weight: .semibold, design: .rounded))
            .foregroundColor(dark ? Color.white.opacity(0.6) : Color(hex: 0x5B4A5E).opacity(0.5))
        g.draw(text, at: CGPoint(x: size.width - 6, y: size.height - 5), anchor: .bottomTrailing)
    }

    struct RenderedFrames: @unchecked Sendable {
        let images: [CGImage]
    }

    /// An infinitely looping GIF with a fixed delay per frame.
    nonisolated static func writeGIF(_ images: [CGImage], delay: Double, to url: URL) -> Bool {
        guard !images.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil) else { return false }
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                               kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for image in images {
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        return CGImageDestinationFinalize(destination)
    }

    /// `Mochi-2026-10-28-153012.gif`, named after the pet, never overwriting an earlier clip.
    static func uniqueURL(in folder: URL, petName: String, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = petName.components(separatedBy: unsafe).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty || cleaned.hasPrefix(".") ? "Mochi" : String(cleaned.prefix(40))
        let base = "\(name)-\(formatter.string(from: date))"
        var url = folder.appendingPathComponent("\(base).gif")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(counter).gif")
            counter += 1
        }
        return url
    }
}
