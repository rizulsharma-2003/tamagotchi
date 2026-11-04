import AppKit
import SwiftUI
import TamagotchiCore
import TamagotchiWire
import WidgetKit

/// Feeds the desktop widget: a small status file and a picture of the scene in
/// `<home>/Widget/`, the one folder the sandboxed widget may read. Only the kind of work is
/// published (never project names, files or commands), and only when it changes.
@MainActor
final class WidgetPublisher {
    private unowned let environment: AppEnvironment
    private var world: CompanionWorld { environment.world }
    private var timer: Timer?
    private var lastKey: String?
    private var lastPictureAt = Date.distantPast
    private var lastReloadAt = Date.distantPast
    private var reloadPending = false

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var folder: URL { environment.paths.home.appendingPathComponent("Widget", isDirectory: true) }

    /// The widget ships inside the app bundle; without it (e.g. `swift run`) there is nothing to feed.
    static var widgetInstalled: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("MacTamagotchiWidgets.appex").path)
    }

    func start() {
        guard Self.widgetInstalled else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        publish()
    }

    private func publish() {
        let status = makeStatus()
        let key = "\(status.mood)|\(status.headline)|\(status.detail)|\(status.friendshipLevel)|\(status.petName)"
        let now = Date()
        let changed = key != lastKey
        guard changed || now.timeIntervalSince(lastPictureAt) > 15 * 60 || reloadPending else { return }
        if changed || now.timeIntervalSince(lastPictureAt) > 15 * 60 {
            lastKey = key
            write(status)
            writePicture()
            lastPictureAt = now
            reloadPending = true
        }
        // Widgets have a reload budget: at most one reload a minute, the latest state wins.
        if reloadPending, now.timeIntervalSince(lastReloadAt) > 60 {
            reloadPending = false
            lastReloadAt = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private struct Status: Encodable {
        var headline: String
        var detail: String
        var petName: String
        var companionName: String
        var mood: String
        var friendshipLevel: Int
        var updatedAt: Date
    }

    private func makeStatus() -> Status {
        let settings = world.settings
        let pet = settings.petName
        var status = Status(headline: "\(pet) is happy", detail: "Friendship level \(world.progress.friendshipLevel)", petName: pet,
                            companionName: settings.companionName, mood: "happy", friendshipLevel: world.progress.friendshipLevel,
                            updatedAt: Date())
        if let session = world.primarySession, !session.isStale(now: Date()), !session.isSimulated {
            switch session.phase {
            case .waitingForUser:
                status.headline = "Claude needs you"
                status.detail = session.waitingFor == .permission ? "Asking for permission" : "Waiting for your answer"
                status.mood = "waiting"
            case .promptSubmitted, .thinking, .runningTool:
                status.headline = "Claude is working"
                status.detail = Self.activity(session.currentTool?.category)
                status.mood = "working"
            case .turnCompleted:
                status.headline = "Claude finished"
                status.detail = session.lastTurnCompletedAt.map { "Done at \($0.formatted(date: .omitted, time: .shortened))" } ?? "All done"
                status.mood = "done"
            case .turnFailed:
                status.headline = "Claude hit a snag"
                status.detail = "Have a look when you can"
                status.mood = "snag"
            case .idle, .ended:
                break
            }
        } else if world.petAsleep {
            status.headline = "\(pet) is napping"
            status.detail = "Zzz…"
            status.mood = "napping"
        }
        if let focus = world.focus {
            status.detail = focus.phase == .focus ? "Focus time · \(Int(focus.remaining(at: Date()) / 60) + 1) min left" : "Break time"
        }
        return status
    }

    private static func activity(_ category: ToolCategory?) -> String {
        switch category {
        case .read?: return "Reading"
        case .search?: return "Searching"
        case .edit?: return "Editing files"
        case .shell?: return "Running a command"
        case .web?: return "Browsing the web"
        case .agent?: return "Working with helpers"
        case .plan?: return "Planning"
        default: return "Thinking"
        }
    }

    private func write(_ status: Status) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: folder.appendingPathComponent("status.json"), options: .atomic)
    }

    /// The popover scene as it looks right now, drawn offscreen (never a screen capture).
    private func writePicture() {
        let snapshot = SceneSnapshot(world: world)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hour = Calendar.current.component(.hour, from: Date())
        let time = ProcessInfo.processInfo.systemUptime
        let view = Canvas { context, size in
            SceneRenderer.draw(snapshot, layout: .popover(width: size.width, height: size.height), in: context, time: time, dark: dark, hour: hour)
        }
        .frame(width: 340, height: 150)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent("scene.png"), options: .atomic)
    }
}
