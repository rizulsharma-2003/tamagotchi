import SwiftUI
import TamagotchiCore

/// Development: renders the pictures the iPhone Live Activity shows (`--render-live-activity <dir>`):
/// a small scene per phase (Patch at the laptop, Mochi beside it) and a crisp pixel Patch for the
/// Dynamic Island. The iPhone can't run the Mac's renderers, so the art ships as images.
@MainActor
enum LiveActivityArt {
    enum Phase: String, CaseIterable {
        case working, waiting, done, idle, error, asleep

        var companion: (CompanionAnimation, Double) {
            switch self {
            case .working: return (.typing, 1.3)
            case .waiting: return (.waiting, 1.3)
            case .done: return (.celebrate, CompanionAnimation.celebrate.defaultDuration * 0.45)
            case .idle: return (.idleAtDesk, 1.3)
            case .error: return (.concerned, CompanionAnimation.concerned.defaultDuration * 0.5)
            case .asleep: return (.sleep, 1.3)
            }
        }

        /// Seconds of animation between two frames (frames show for a second each).
        var step: Double {
            switch self {
            case .working: return 0.17
            case .waiting: return 0.3
            case .idle: return 0.8
            case .asleep: return 0.6
            case .done, .error: return 0.25
            }
        }

        var pet: (PetAnimation, Double) {
            switch self {
            case .working: return (.watch, 1.2)
            case .waiting: return (.leanForward, 0.8)
            case .done: return (.victory, 0.9)
            case .idle: return (.idle, 1.2)
            case .error: return (.concerned, 1.0)
            case .asleep: return (.curl, 0)
            }
        }
    }

    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for phase in Phase.allCases {
            SnapshotRenderer.write(scene(phase), to: directory.appendingPathComponent("scene-\(phase.rawValue).png"), scale: 3)
            SnapshotRenderer.write(sprite(phase), to: directory.appendingPathComponent("patch-\(phase.rawValue).png"), scale: 1)
        }
        renderAppIcon(to: directory.appendingPathComponent("AppIcon-1024.png"))
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for phase in Phase.allCases {
            for frame in 0..<10 {
                let scenePNG = frames.appendingPathComponent("scene-\(phase.rawValue)-\(frame).png")
                SnapshotRenderer.write(scene(phase, frame: frame), to: scenePNG, scale: 3)
                writeShape(of: scenePNG, cell: 3)
                let spritePNG = frames.appendingPathComponent("sprite-\(phase.rawValue)-\(frame).png")
                SnapshotRenderer.write(sprite(phase, frame: frame, pixel: 3), to: spritePNG, scale: 1)
                writeShape(of: spritePNG, cell: 3)
            }

        }
        print("Live Activity art written to \(directory.path)")
    }

    private static func companionPose(_ phase: Phase, frame: Int? = nil) -> CompanionPose {
        var (animation, elapsed) = phase.companion
        if let frame { elapsed = sampleTime(loop: animation.isLoop, duration: animation.defaultDuration, base: elapsed, frame: frame, step: phase.step) }
        return CompanionPoseEvaluator.pose(animation, elapsed: elapsed, context: PoseContext(time: 2.1 + Double(frame ?? 0) * phase.step),
                                           detail: CompanionDetail(waitingFor: .permission, subagents: 0))
    }

    private static func petPose(_ phase: Phase, frame: Int? = nil) -> PetPose {
        var (animation, elapsed) = phase.pet
        if let frame { elapsed = sampleTime(loop: animation.isLoop, duration: animation.defaultDuration, base: elapsed, frame: frame, step: phase.step) }
        return PetPoseEvaluator.pose(animation, elapsed: elapsed, context: PoseContext(time: 2.1 + Double(frame ?? 0) * phase.step))
    }

    /// Ten frames shown one per second: loops are sampled every `step` seconds (a slow, readable
    /// cycle), one-shot animations are spread across their whole length.
    private static func sampleTime(loop: Bool, duration: Double, base: Double, frame: Int, step: Double) -> Double {
        loop ? base + Double(frame) * step : duration * Double(frame) / 10
    }

    static func scene(_ phase: Phase, frame: Int? = nil) -> some View {
        Canvas { context, size in
            let floor = size.height - 3
            PetRenderer.draw(petPose(phase, frame: frame), in: context, at: CGPoint(x: size.width * 0.22, y: floor), scale: 0.6,
                             palette: PetPalette(.cream), accessory: nil, dark: false)
            CompanionRenderer.draw(companionPose(phase, frame: frame), in: context, at: CGPoint(x: size.width * 0.66, y: floor), scale: 0.76,
                                   accessory: nil, dark: false, time: 2.1 + Double(frame ?? 0) * phase.step) { desk in
                ThemeRenderer.deskFront(.cozyDesk, in: desk, dark: false, accessory: nil)
            }
        }
        .frame(width: 140, height: 72)
    }

    /// Writes the frame's silhouette next to it (`.runs.json`: rows of opaque cells), so the font can carry
    /// an outline too: where colour bitmaps aren't drawn, the animation still shows as a shape.
    static func writeShape(of png: URL, cell: Int) {
        guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: png)) ?? Data()) else { return }
        let columns = rep.pixelsWide / cell, rows = rep.pixelsHigh / cell
        var runs: [[Int]] = []
        for row in 0..<rows {
            var start: Int?
            for column in 0...columns {
                var opaque = false
                if column < columns, let color = rep.colorAt(x: column * cell + cell / 2, y: row * cell + cell / 2) {
                    opaque = color.alphaComponent > 0.5
                }
                if opaque, start == nil { start = column }
                if !opaque, let first = start {
                    runs.append([row, first, column - 1])
                    start = nil
                }
            }
        }
        let json = "{\"columns\":\(columns),\"rows\":\(rows),\"runs\":\(runs)}"
        try? json.write(to: png.deletingPathExtension().appendingPathExtension("runs.json"), atomically: true, encoding: .utf8)
    }

    /// The iPhone app's icon: full-bleed and opaque, as iOS wants it.
    static func renderAppIcon(to url: URL) {
        let view = Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [Color(red: 0.99, green: 0.91, blue: 0.84), Color(red: 0.95, green: 0.78, blue: 0.66)]),
                                               startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            let pet = PetPoseEvaluator.pose(.idle, elapsed: 1.2, context: PoseContext(time: 2.1))
            PetRenderer.draw(pet, in: context, at: CGPoint(x: size.width * 0.34, y: size.height * 0.76), scale: 6.3,
                             palette: PetPalette(.cream), accessory: nil, dark: false)
            var options = PixelMascot.Options()
            options.shadow = false
            options.snap = 1
            PixelMascot.draw(companionPose(.done), in: context, feet: CGPoint(x: size.width * 0.73, y: size.height * 0.76), pixel: 13,
                             time: 2.1, options: options)
        }
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cgImage = renderer.cgImage,
              let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        guard let opaque = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: opaque)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func sprite(_ phase: Phase, frame: Int? = nil, pixel: CGFloat = 1) -> some View {
        Canvas { context, size in
            var options = PixelMascot.Options()
            options.shadow = false
            options.snap = 1
            options.showsSpark = phase == .working
            options.headroom = 8
            PixelMascot.draw(companionPose(phase, frame: frame), in: context,
                             feet: CGPoint(x: size.width / 2 + 2 * pixel, y: size.height - pixel), pixel: pixel,
                             time: 2.1 + Double(frame ?? 0) * phase.step, options: options)
        }
        .frame(width: 34 * pixel, height: 30 * pixel)
    }
}
