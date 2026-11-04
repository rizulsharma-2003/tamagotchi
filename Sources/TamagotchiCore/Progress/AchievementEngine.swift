import Foundation
import TamagotchiWire

public enum AchievementID: String, Codable, Sendable, CaseIterable, Identifiable {
    case firstSession
    case firstTurn
    case firstGreenBuild
    case firstMilestone
    case globetrotter
    case caseClosed
    case goodFriends
    case bestFriends

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .firstSession: return "Hello, Patch"
        case .firstTurn: return "First Finish"
        case .firstGreenBuild: return "Green Light"
        case .firstMilestone: return "Milestone Maker"
        case .globetrotter: return "Globetrotter"
        case .caseClosed: return "Case Closed"
        case .goodFriends: return "Good Friends"
        case .bestFriends: return "Best Friends"
        }
    }

    /// Exactly how it is earned, so progress is transparent.
    public var criteria: String {
        switch self {
        case .firstSession: return "Connect Claude Code and observe a first session."
        case .firstTurn: return "Observe Claude finishing a turn."
        case .firstGreenBuild: return "Receive a real passing build or test result."
        case .firstMilestone: return "Mark or report a milestone."
        case .globetrotter: return "Observe Claude Code sessions in 3 different projects."
        case .caseClosed: return "A turn finishes after the companion went into detective mode."
        case .goodFriends: return "Play with your pet on 7 different days (not necessarily in a row)."
        case .bestFriends: return "Reach friendship level 5."
        }
    }

    public var reward: Accessory? {
        Accessory.allCases.first { $0.unlock == .achievement(self) }
    }
}

/// Locally stored, transparent progress. Nothing here ever decreases, and the
/// pet never gets sick or sad because the app was closed.
public struct ProgressState: Codable, Sendable, Equatable {
    public var unlocked: [String: Date] = [:]
    public var affectionPoints = 0
    /// Distinct calendar days (yyyy-MM-dd) with at least one interaction.
    public var interactionDays: [String] = []
    /// Points earned per day per interaction type, for daily caps.
    public var dailyPoints: [String: Int] = [:]
    public var dailyPointsDay = ""
    /// Hashed project keys seen in real sessions (never names or paths).
    public var projectKeys: [String] = []
    public var observedSessions = 0
    public var observedTurns = 0
    public var milestones = 0
    public var firstMetAt: Date?

    public init() {}

    public var unlockedIDs: Set<AchievementID> {
        Set(unlocked.keys.compactMap(AchievementID.init(rawValue:)))
    }

    public static let levelThresholds = [0, 10, 30, 60, 100, 160]

    public var friendshipLevel: Int {
        ProgressState.levelThresholds.lastIndex { affectionPoints >= $0 } ?? 0
    }

    public var pointsToNextLevel: Int? {
        let level = friendshipLevel
        guard level + 1 < ProgressState.levelThresholds.count else { return nil }
        return ProgressState.levelThresholds[level + 1] - affectionPoints
    }
}

public enum PetInteraction: String, Codable, Sendable, CaseIterable {
    case pet, play, treat

    var points: Int {
        switch self {
        case .pet: return 1
        case .play: return 2
        case .treat: return 1
        }
    }

    /// Maximum points per day from this interaction, so affection cannot be farmed
    /// and there is never pressure to keep clicking.
    var dailyCap: Int {
        switch self {
        case .pet: return 8
        case .play: return 8
        case .treat: return 3
        }
    }
}

@MainActor
public final class AchievementEngine {
    public private(set) var state: ProgressState
    public let fileURL: URL?
    private let calendar: Calendar

    public init(fileURL: URL?, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.progress.decode(ProgressState.self, from: data) {
            state = decoded
        } else {
            state = ProgressState()
        }
    }

    public init(state: ProgressState, calendar: Calendar = .current) {
        self.state = state
        self.fileURL = nil
        self.calendar = calendar
    }

    /// Records an observed real event. Returns achievements unlocked by it.
    @discardableResult
    public func record(_ event: CompanionEvent, transition: SessionTransition?, session: SessionSnapshot?) -> [AchievementID] {
        // Simulated and late/restored events never count towards progress.
        guard !event.isSimulated, event.delivery == .live else { return [] }
        var unlockedNow: [AchievementID] = []
        let now = event.timestamp

        if transition?.isNewSession == true || event.kind == .sessionStarted {
            if transition?.isNewSession == true { state.observedSessions += 1 }
            unlockedNow += unlock(.firstSession, at: now)
            if let key = event.project?.key, !state.projectKeys.contains(key) {
                state.projectKeys.append(key)
                if state.projectKeys.count > 50 { state.projectKeys.removeFirst() }
            }
            if state.projectKeys.count >= 3 { unlockedNow += unlock(.globetrotter, at: now) }
        }
        switch event.kind {
        case .turnCompleted:
            state.observedTurns += 1
            unlockedNow += unlock(.firstTurn, at: now)
            if let session, session.investigatedThisTurn {
                unlockedNow += unlock(.caseClosed, at: now)
            }
        case .report where event.report?.kind == .milestone:
            state.milestones += 1
            unlockedNow += unlock(.firstMilestone, at: now)
        default:
            break
        }
        if let outcome = event.buildTestOutcome, outcome.passed {
            unlockedNow += unlock(.firstGreenBuild, at: now)
        }
        if !unlockedNow.isEmpty || event.kind == .sessionStarted || event.kind == .turnCompleted { save() }
        return unlockedNow
    }

    /// A milestone the user marked by hand.
    @discardableResult
    public func recordManualMilestone(at now: Date) -> [AchievementID] {
        state.milestones += 1
        let unlocked = unlock(.firstMilestone, at: now)
        save()
        return unlocked
    }

    public struct InteractionResult: Equatable, Sendable {
        public var pointsAwarded: Int
        public var levelUp: Bool
        public var unlocked: [AchievementID]
    }

    @discardableResult
    public func recordInteraction(_ interaction: PetInteraction, at now: Date) -> InteractionResult {
        let day = dayString(now)
        if state.firstMetAt == nil { state.firstMetAt = now }
        if state.dailyPointsDay != day {
            state.dailyPointsDay = day
            state.dailyPoints = [:]
        }
        let used = state.dailyPoints[interaction.rawValue] ?? 0
        let award = max(0, min(interaction.points, interaction.dailyCap - used))
        let levelBefore = state.friendshipLevel
        state.affectionPoints += award
        state.dailyPoints[interaction.rawValue] = used + award
        if !state.interactionDays.contains(day) {
            state.interactionDays.append(day)
            if state.interactionDays.count > 400 { state.interactionDays.removeFirst() }
        }
        var unlocked: [AchievementID] = []
        if state.interactionDays.count >= 7 { unlocked += unlock(.goodFriends, at: now) }
        if state.friendshipLevel >= 5 { unlocked += unlock(.bestFriends, at: now) }
        save()
        return InteractionResult(pointsAwarded: award, levelUp: state.friendshipLevel > levelBefore, unlocked: unlocked)
    }

    public func isUnlocked(_ id: AchievementID) -> Bool { state.unlocked[id.rawValue] != nil }

    public func reset() {
        state = ProgressState()
        save()
    }

    private func unlock(_ id: AchievementID, at date: Date) -> [AchievementID] {
        guard state.unlocked[id.rawValue] == nil else { return [] }
        state.unlocked[id.rawValue] = date
        return [id]
    }

    private func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func save() {
        guard let fileURL else { return }
        BridgePaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        guard let data = try? JSONEncoder.progress.encode(state) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        chmod(fileURL.path, 0o600)
    }
}

extension JSONEncoder {
    static var progress: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var progress: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
