import Foundation

/// Side effects the world asks the app layer to perform.
@MainActor
public protocol WorldEffects: AnyObject {
    func play(_ sound: SoundCue)
    func postBanner(_ content: BannerContent, category: NotificationCategory, sessionID: String?)
    /// A live event went through the reaction pipeline (for speech and similar flourishes).
    func worldDidReact(to event: CompanionEvent, session: SessionSnapshot?)
    /// The user petted, played with or fed the pet.
    func userDidInteract(_ kind: PetInteraction)
}

extension WorldEffects {
    public func worldDidReact(to event: CompanionEvent, session: SessionSnapshot?) {}
    public func userDidInteract(_ kind: PetInteraction) {}
}

public enum ClaudeAvailability: Equatable, Sendable {
    case unknown
    case notFound
    case found(version: String?)
}

public enum IntegrationState: Equatable, Sendable {
    case unknown
    case notInstalled
    case installed
    case needsUpdate(String)
    case blocked(String)
    case error(String)
}

/// Everything the UI needs to explain the real connection state.
public struct ConnectionStatus: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case good, waiting, setupNeeded, problem }

    public var claude: ClaudeAvailability = .unknown
    public var integration: IntegrationState = .unknown
    public var bridgeListening = false
    public var bridgeError: String?
    public var eventsAccepted = 0
    public var eventsRejected = 0
    public var lastRejection: String?
    public var refusedPeers = 0
    public var lastEventAt: Date?
    public var lastPingAt: Date?

    public init() {}

    public var level: Level {
        if bridgeError != nil { return .problem }
        switch integration {
        case .error, .blocked: return .problem
        case .notInstalled, .needsUpdate: return .setupNeeded
        case .unknown: return .waiting
        case .installed: return lastEventAt == nil ? .waiting : .good
        }
    }

    public var title: String {
        if let bridgeError { return "Event bridge unavailable — \(bridgeError)" }
        switch integration {
        case .unknown: return "Checking Claude Code connection…"
        case .notInstalled:
            if case .notFound = claude { return "Claude Code not found" }
            return "Claude Code not connected"
        case .needsUpdate: return "Connection needs an update"
        case .blocked(let reason): return reason
        case .error(let reason): return reason
        case .installed:
            return lastEventAt == nil ? "Connected — waiting for a Claude Code session" : "Connected to Claude Code"
        }
    }

    public var isConnected: Bool {
        integration == .installed && bridgeListening
    }
}

public struct AttentionBadge: Equatable, Sendable {
    public enum Kind: String, Sendable { case needsYou, toolError, apiError, buildFailed }

    public var kind: Kind
    public var level: AttentionLevel
    public var sessionID: String?
    public var summary: String
    public var at: Date
}

public struct ResultCard: Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var projectName: String
    public var projectPath: String?
    public var completedAt: Date
    public var statusLine: String
    public var buildTest: BuildTestOutcome?
    /// Only set when both ends of the turn were observed live.
    public var observedTurnDuration: TimeInterval?
    public var isSimulated: Bool
}

public struct SceneCaption: Equatable, Sendable {
    public var text: String
    public var until: TimeInterval
    public var isSimulated: Bool
}

public struct CelebrationBurst: Equatable, Sendable {
    public var startedAt: TimeInterval
    public var big: Bool
}

public struct MissedEventsNotice: Equatable, Sendable {
    public var delivered: Int
    public var dropped: Int
    public var at: Date
}

public struct WorldToast: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var until: TimeInterval
}

public struct WorldDiagnostics: Equatable, Sendable {
    public var duplicatesIgnored = 0
    public var unknownEvents = 0
    public var lastUnknownName: String?
    public var lateEvents = 0
    public var simulatedEvents = 0
}

public enum MenuBarMood: String, Sendable {
    case content, sleeping, watching, waiting, concerned, celebrating, offline, paused
}

public struct MenuBarStatus: Equatable, Sendable {
    public var mood: MenuBarMood
    public var companionVisible: Bool
    public var companionWorking: Bool
    public var badge: AttentionLevel?
    public var celebrationStartedAt: TimeInterval?
    public var simulated: Bool

    public init(mood: MenuBarMood, companionVisible: Bool, companionWorking: Bool, badge: AttentionLevel?,
                celebrationStartedAt: TimeInterval?, simulated: Bool) {
        self.mood = mood
        self.companionVisible = companionVisible
        self.companionWorking = companionWorking
        self.badge = badge
        self.celebrationStartedAt = celebrationStartedAt
        self.simulated = simulated
    }
}
