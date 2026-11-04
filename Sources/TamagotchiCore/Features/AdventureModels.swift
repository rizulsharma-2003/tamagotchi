import Foundation

/// Settings for desktop adventures (Mochi leaving the menu bar to explore windows and the Dock).
public struct AdventureSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var spontaneous: AdventureFrequency = .sometimes
    public init() {}
}

public enum AdventureFrequency: String, Codable, Sendable, CaseIterable, Identifiable {
    case never, rarely, sometimes
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
