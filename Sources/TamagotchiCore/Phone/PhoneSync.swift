import Foundation

/// The pet's look, shared from the Mac with Mochi Pocket (through Mochi Link) so both rooms match.
public struct PetLook: Codable, Sendable, Equatable {
    public var petName: String
    public var companionName: String
    public var petColor: PetColor
    public var petAccessory: Accessory?
    public var companionAccessory: Accessory?
    public var deskAccessory: Accessory?
    public var theme: OfficeTheme
    public var room: RoomLayout
    public var seasonal: SeasonalSettings
    public var friendshipLevel: Int

    public init(settings: AppSettings, friendshipLevel: Int) {
        petName = settings.petName
        companionName = settings.companionName
        petColor = settings.petColor
        petAccessory = settings.petAccessory
        companionAccessory = settings.companionAccessory
        deskAccessory = settings.deskAccessory
        theme = settings.theme
        room = settings.room
        seasonal = settings.seasonal
        self.friendshipLevel = friendshipLevel
    }

    public func apply(to settings: inout AppSettings) {
        settings.petName = petName
        settings.companionName = companionName
        settings.petColor = petColor
        settings.petAccessory = petAccessory
        settings.companionAccessory = companionAccessory
        settings.deskAccessory = deskAccessory
        settings.theme = theme
        settings.room = room
        settings.seasonal = seasonal
    }

    public var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    public static func decode(_ json: String) -> PetLook? { try? JSONDecoder().decode(PetLook.self, from: Data(json.utf8)) }
}

/// What Claude is doing on the Mac, so the companion in Mochi Pocket's room does the same: only the
/// phase and the kind of tool (edit, read, shell…), never what it is working on.
public struct ClaudeMirror: Codable, Sendable, Equatable {
    /// none · idle · working · waiting · done · error
    public var phase: String
    public var category: String?
    /// The Mac is resting, so Mochi sleeps on the iPhone too.
    public var resting = false

    public init(phase: String, category: String? = nil, resting: Bool = false) {
        self.phase = phase
        self.category = category
        self.resting = resting
    }

    public static func from(sessions: [SessionSnapshot]) -> ClaudeMirror {
        let live = sessions.filter { !$0.isSimulated && $0.endedAt == nil && $0.phase != .ended }
        guard let session = live.max(by: { $0.lastEventAt < $1.lastEventAt }) else { return ClaudeMirror(phase: "none") }
        switch session.phase {
        case .promptSubmitted, .thinking: return ClaudeMirror(phase: "working", category: "think")
        case .runningTool: return ClaudeMirror(phase: "working", category: session.currentTool?.category.rawValue ?? "other")
        case .waitingForUser: return ClaudeMirror(phase: "waiting")
        case .turnCompleted: return ClaudeMirror(phase: "done")
        case .turnFailed: return ClaudeMirror(phase: "error")
        case .idle, .ended: return ClaudeMirror(phase: "idle")
        }
    }

    /// The tool a mirrored session "uses" for a category, so the companion picks the matching animation.
    public static func tool(for category: String?) -> String {
        switch category {
        case "read": return "Read"
        case "search": return "Grep"
        case "shell": return "Bash"
        case "web": return "WebFetch"
        case "agent": return "Task"
        default: return "Edit"
        }
    }
}
