import Foundation
import Observation
import TamagotchiCore
import TamagotchiWire

/// Mochi's world on the iPhone: the same characters, animations, play and treats as the Mac's panel.
/// It follows the Mac through Mochi Link: the look (names, colours, room), what Claude is doing (so the
/// companion works when Claude works there), and petting, play and treats in both directions.
@MainActor
@Observable
final class PhoneWorld: WorldEffects {
    static let shared = PhoneWorld()

    let world: CompanionWorld
    private(set) var friendshipLevel = 0
    private(set) var linkedToMac = false

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var timer: Timer?
    private var linkStore: LinkStore { MochiLink.store }
    @ObservationIgnored private var mirror = ClaudeMirror(phase: "none")
    @ObservationIgnored private var mirrorSession: String?
    @ObservationIgnored private var inTurn = false
    @ObservationIgnored private var eventCount = 0
    @ObservationIgnored private var seenInteractions = Set<String>()

    private init() {
        let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mochi", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        settingsStore = SettingsStore(fileURL: home.appendingPathComponent("settings.json"))
        let journal = EventJournal(fileURL: home.appendingPathComponent("history.jsonl"), retention: .init(days: 1), storeProjectPaths: false)
        let achievements = AchievementEngine(fileURL: home.appendingPathComponent("progress.json"))
        world = CompanionWorld(journal: journal, achievements: achievements, settingsStore: settingsStore)
        // On the phone the companion keeps Mochi company at the desk all the time.
        if settingsStore.settings.companionVisibility != .always { settingsStore.settings.companionVisibility = .always }
    }

    func start() {
        guard timer == nil else { return }
        world.effects = self
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.world.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(forName: .linkStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followMac() }
        }
        followMac()
    }

    // MARK: Buttons

    /// Pet, play or treat here; Mochi on the Mac does the same a moment later.
    func interact(_ kind: PetInteraction) {
        world.interact(kind)
        let id = UUID().uuidString
        seenInteractions.insert(id)
        linkStore.set(["id": id, "kind": kind.rawValue, "at": Date().timeIntervalSince1970], for: .phoneInteraction)
    }

    // MARK: Following the Mac

    func followMac() {
        if let json = linkStore.string(.look), let look = PetLook.decode(json) {
            var settings = settingsStore.settings
            look.apply(to: &settings)
            if settings != settingsStore.settings {
                settingsStore.settings = settings
                MacLink.shared.log("look: \(look.petName), \(look.theme.rawValue), level \(look.friendshipLevel)")
            }
            friendshipLevel = look.friendshipLevel
            linkedToMac = true
        }
        if let data = linkStore.dictionary(.claude), let phase = data["phase"] as? String {
            let next = ClaudeMirror(phase: phase, category: data["category"] as? String, resting: data["resting"] as? Bool ?? false)
            if next != mirror {
                if next.resting != mirror.resting { MacLink.shared.log(next.resting ? "the Mac is resting" : "the Mac is in use") }
                let claudeChanged = next.phase != mirror.phase || next.category != mirror.category
                mirror = next
                if claudeChanged {
                    MacLink.shared.log("claude on the Mac: \(next.phase) \(next.category ?? "")")
                    play(next)
                }
            }
            // Mochi sleeps here while the Mac rests, and wakes when it's in use again.
            if data["resting"] != nil {
                world.updateSystem(next.resting ? SystemActivity(idleSeconds: 86_400) : SystemActivity(idleSeconds: 0))
            }
        }
        if let data = linkStore.dictionary(.macInteraction), let id = data["id"] as? String, !seenInteractions.contains(id),
           let at = data["at"] as? Double, Date().timeIntervalSince1970 - at < 90,
           let raw = data["kind"] as? String, let kind = PetInteraction(rawValue: raw) {
            seenInteractions.insert(id)
            MacLink.shared.log("from the Mac: \(kind.rawValue)")
            world.interact(kind)
        }
    }

    /// Mirrors the Mac's Claude activity as simulated events (never kept, never counted).
    private func play(_ mirror: ClaudeMirror) {
        switch mirror.phase {
        case "none":
            if let session = mirrorSession { send("SessionEnd", session: session) }
            mirrorSession = nil
            inTurn = false
        case "working":
            let session = ensureSession()
            if !inTurn {
                send("UserPromptSubmit", session: session)
                inTurn = true
            }
            if mirror.category != "think" {
                let tool = ClaudeMirror.tool(for: mirror.category)
                let toolUse = "mirror-tool-\(eventCount)"
                send("PreToolUse", session: session, tool: tool, category: mirror.category, toolUse: toolUse)
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    self.send("PostToolUse", session: session, tool: tool, category: mirror.category, toolUse: toolUse)
                }
            }
        case "waiting":
            send("Notification", session: ensureSession(), notification: "permission_prompt")
        case "done":
            send("Stop", session: ensureSession())
            inTurn = false
        case "error":
            send("StopFailure", session: ensureSession())
            inTurn = false
        default:
            _ = ensureSession()
        }
    }

    private func ensureSession() -> String {
        if let mirrorSession { return mirrorSession }
        let session = "mac-mirror-\(UUID().uuidString.prefix(8))"
        mirrorSession = session
        send("SessionStart", session: session)
        return session
    }

    private func send(_ name: String, session: String, tool: String? = nil, category: String? = nil, toolUse: String? = nil,
                      notification: String? = nil) {
        eventCount += 1
        var event = WireEvent(id: "mirror-\(eventCount)-\(UUID().uuidString.prefix(6))", ts: Date().timeIntervalSince1970,
                              origin: .simulator, event: name, session: session)
        event.project = PocketLink.shared.host.yoursCapitalized
        event.projectKey = "macmirror0"
        if let tool {
            event.tool = tool
            event.toolCategory = category == "think" ? "other" : (category ?? "edit")
            event.toolUseId = toolUse
        }
        if let notification {
            event.notificationType = notification
            event.message = "Claude needs you"
        }
        if name == "StopFailure" { event.reason = "server_error" }
        world.ingest(event, delivery: .live)
    }

    // MARK: WorldEffects

    func play(_ sound: SoundCue) {}
    func postBanner(_ content: BannerContent, category: NotificationCategory, sessionID: String?) {}
}
