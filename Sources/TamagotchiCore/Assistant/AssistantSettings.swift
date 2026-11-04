import Foundation

/// Settings for Ask Mochi, the assistant.
public struct AssistantSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var shortcut: AssistantShortcut = .optionSpace
    public var model: AssistantModel = .fast
    /// Show every prompt for a Claude session and wait for Send. Off sends right away (still shown).
    public var confirmBeforeSending = true
    /// Hold the shortcut to talk (speech is turned into text on this Mac).
    public var voice = true
    /// Mochi reads answers aloud with a system voice.
    public var spokenReplies = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AssistantSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        shortcut = (try? container.decodeIfPresent(AssistantShortcut.self, forKey: .shortcut)) ?? defaults.shortcut
        model = (try? container.decodeIfPresent(AssistantModel.self, forKey: .model)) ?? defaults.model
        confirmBeforeSending = (try? container.decodeIfPresent(Bool.self, forKey: .confirmBeforeSending)) ?? defaults.confirmBeforeSending
        voice = (try? container.decodeIfPresent(Bool.self, forKey: .voice)) ?? defaults.voice
        spokenReplies = (try? container.decodeIfPresent(Bool.self, forKey: .spokenReplies)) ?? defaults.spokenReplies
    }
}

public enum AssistantShortcut: String, Codable, Sendable, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, controlOptionM, off
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .controlOptionM: return "⌃⌥ M"
        case .off: return "None"
        }
    }
}

public enum AssistantModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case fast, smart
    public var id: String { rawValue }
    /// The Claude Code model alias.
    public var alias: String { self == .fast ? "haiku" : "sonnet" }
    public var title: String { self == .fast ? "Fast (Haiku)" : "Smart (Sonnet)" }
}
