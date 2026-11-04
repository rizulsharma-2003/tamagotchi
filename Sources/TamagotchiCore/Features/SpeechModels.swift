import Foundation

/// Settings for Mochi's speech bubbles.
public struct SpeechSettings: Codable, Sendable, Equatable {
    public var enabled = true
    /// Use Apple Intelligence on this Mac (when available) for fresh lines; curated lines otherwise.
    public var useAppleIntelligence = true
    public var chattiness: Chattiness = .normal
    public init() {}
}

public enum Chattiness: String, Codable, Sendable, CaseIterable, Identifiable {
    case quiet, normal, chatty
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum SpeechSpeaker: String, Codable, Sendable {
    case pet, companion
}

/// A short line one of the characters is saying right now.
public struct SpeechBubble: Sendable, Equatable, Identifiable {
    public var id: Int
    public var text: String
    public var speaker: SpeechSpeaker
    /// World time (uptime) the bubble appeared.
    public var startedAt: TimeInterval
    public var duration: TimeInterval

    public init(id: Int, text: String, speaker: SpeechSpeaker, startedAt: TimeInterval, duration: TimeInterval) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.startedAt = startedAt
        self.duration = duration
    }

    public func isVisible(at time: TimeInterval) -> Bool { time >= startedAt && time < startedAt + duration }
}
