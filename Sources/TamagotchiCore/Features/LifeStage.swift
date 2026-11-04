import Foundation

/// Mochi grows up: kitten, then young, then grown-up, as the friendship grows over the weeks.
/// The inputs (affection points, days together, the first meeting) never go down, so neither does the stage.
public enum LifeStage: Int, Codable, Sendable, CaseIterable, Comparable {
    case kitten, young, grownUp

    public static func < (a: LifeStage, b: LifeStage) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .kitten: return "Kitten"
        case .young: return "Young"
        case .grownUp: return "Grown-up"
        }
    }

    public static func stage(for progress: ProgressState, now: Date) -> LifeStage {
        let days = progress.interactionDays.count
        let weeks = progress.firstMetAt.map { now.timeIntervalSince($0) / (7 * 86_400) } ?? 0
        let level = progress.friendshipLevel
        if level >= 4, days >= 10 || weeks >= 3 { return .grownUp }
        if level >= 2, days >= 3 || weeks >= 1 { return .young }
        return .kitten
    }

    /// What it takes to reach the next stage, in plain words (nil when fully grown).
    public static func nextStep(for progress: ProgressState, now: Date) -> String? {
        let current = stage(for: progress, now: now)
        guard current != .grownUp else { return nil }
        let (level, days, weeks) = current == .kitten ? (2, 3, 1) : (4, 10, 3)
        var needs: [String] = []
        if progress.friendshipLevel < level { needs.append("friendship level \(level)") }
        let together = progress.interactionDays.count
        let known = progress.firstMetAt.map { now.timeIntervalSince($0) / (7 * 86_400) } ?? 0
        if together < days, known < Double(weeks) {
            needs.append("\(days) days of play (\(together) so far) or \(weeks) week\(weeks == 1 ? "" : "s") together")
        }
        let next = LifeStage(rawValue: current.rawValue + 1)!.title.lowercased()
        return needs.isEmpty ? nil : "Grows \(next == "grown-up" ? "up" : "into a young cat") with " + needs.joined(separator: " and ")
    }
}
