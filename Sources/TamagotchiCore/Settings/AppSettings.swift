import Foundation

public enum AnimationIntensity: String, Codable, Sendable, CaseIterable, Identifiable {
    case calm, normal, lively
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .calm: return "Calm"
        case .normal: return "Normal"
        case .lively: return "Lively"
        }
    }
    /// Multiplier applied to gaps between ambient behaviours.
    public var gapMultiplier: Double {
        switch self {
        case .calm: return 2.5
        case .normal: return 1
        case .lively: return 0.6
        }
    }
}

public enum ReducedMotionPreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, always, never
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return "Follow System Setting"
        case .always: return "Always Reduce Motion"
        case .never: return "Full Motion"
        }
    }
}

public enum MenuBarAnimation: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, subtle, full
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "Static"
        case .subtle: return "Subtle"
        case .full: return "Expressive"
        }
    }
}

/// How the pet lives in the menu bar.
public enum MenuBarStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Mochi in full colour, roaming along the whole menu bar from its bed at the status item.
    case roam
    /// Mochi plays inside a wider status item.
    case stage
    /// The original monochrome template glyph.
    case icon
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .roam: return "Roam the menu bar"
        case .stage: return "Play in the status item"
        case .icon: return "Classic icon"
        }
    }
}

/// How far from its bed Mochi may wander along the menu bar.
public enum MenuBarRoamRange: String, Codable, Sendable, CaseIterable, Identifiable {
    case near, wide, full
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .near: return "Near home"
        case .wide: return "Wide"
        case .full: return "Whole menu bar"
        }
    }
    /// Width of the stretch Mochi may use in all, shared between both sides of its bed;
    /// nil for the whole free bar (right of the notch, or the right half of the screen, up to the clock).
    public var points: Double? {
        switch self {
        case .near: return 200
        case .wide: return 420
        case .full: return nil
        }
    }
}

/// Width of the status item in the `.stage` style.
public enum MenuBarStageWidth: String, Codable, Sendable, CaseIterable, Identifiable {
    case small, medium, large
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var points: Double {
        switch self {
        case .small: return 40
        case .medium: return 64
        case .large: return 96
        }
    }
}

public enum CompanionVisibility: String, Codable, Sendable, CaseIterable, Identifiable {
    case duringSessions, always, never
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .duringSessions: return "When Claude Code is active"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

public enum DesktopPetSize: String, Codable, Sendable, CaseIterable, Identifiable {
    case small, medium, large
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// Height of the desktop window in points.
    public var height: Double {
        switch self {
        case .small: return 84
        case .medium: return 116
        case .large: return 156
        }
    }
}

public struct DesktopPetPosition: Codable, Sendable, Equatable {
    /// `NSScreenNumber` of the display the pet was on.
    public var screenID: UInt32?
    /// Position of the window's origin as a fraction of the screen's visible frame.
    public var relativeX: Double
    public var relativeY: Double

    public init(screenID: UInt32?, relativeX: Double, relativeY: Double) {
        self.screenID = screenID
        self.relativeX = relativeX
        self.relativeY = relativeY
    }
}

/// How a category of event may reach the user.
public struct CategoryDelivery: Codable, Sendable, Equatable {
    public var animate: Bool
    public var badge: Bool
    public var banner: Bool
    public var sound: Bool

    public init(animate: Bool = true, badge: Bool = false, banner: Bool = false, sound: Bool = false) {
        self.animate = animate
        self.badge = badge
        self.banner = banner
        self.sound = sound
    }
}

public enum NotificationCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case needsAttention
    case turnCompleted
    case toolFailure
    case turnError
    case buildTest
    case sessionLifecycle
    case toolActivity
    case milestone
    case achievement

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .needsAttention: return "Claude needs you"
        case .turnCompleted: return "Turn completed"
        case .toolFailure: return "Tool errors"
        case .turnError: return "API errors"
        case .buildTest: return "Build & test results"
        case .sessionLifecycle: return "Session start & end"
        case .toolActivity: return "Tool activity"
        case .milestone: return "Milestones"
        case .achievement: return "Achievements"
        }
    }

    public var explanation: String {
        switch self {
        case .needsAttention: return "Permission prompts, idle input requests and MCP dialogs."
        case .turnCompleted: return "Claude finished responding. Says nothing about builds or tests."
        case .toolFailure: return "A tool call reported an error. The turn usually continues."
        case .turnError: return "A turn ended because of an API error (rate limit, overload…)."
        case .buildTest: return "Explicit reports, or build/test commands with a trustworthy exit status."
        case .sessionLifecycle: return "A Claude Code session started or ended."
        case .toolActivity: return "Individual tool calls. Never sent as notifications."
        case .milestone: return "Milestones you mark or report."
        case .achievement: return "Friendship achievements unlocked."
        }
    }

    /// Tool activity is far too frequent for banners or badges.
    public var allowsBanner: Bool { self != .toolActivity }
    public var allowsBadge: Bool { self != .toolActivity && self != .sessionLifecycle }

    public var defaultDelivery: CategoryDelivery {
        switch self {
        case .needsAttention: return CategoryDelivery(animate: true, badge: true, banner: false, sound: true)
        case .turnCompleted: return CategoryDelivery(animate: true, badge: false, banner: false, sound: true)
        case .toolFailure: return CategoryDelivery(animate: true, badge: true, banner: false, sound: false)
        case .turnError: return CategoryDelivery(animate: true, badge: true, banner: false, sound: false)
        case .buildTest: return CategoryDelivery(animate: true, badge: false, banner: false, sound: true)
        case .sessionLifecycle: return CategoryDelivery(animate: true, badge: false, banner: false, sound: true)
        case .toolActivity: return CategoryDelivery(animate: true, badge: false, banner: false, sound: false)
        case .milestone: return CategoryDelivery(animate: true, badge: false, banner: false, sound: true)
        case .achievement: return CategoryDelivery(animate: true, badge: false, banner: false, sound: true)
        }
    }
}

public enum PetColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case cream, peach, mint, sky, lavender, cocoa, midnight
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum OfficeTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case cozyDesk, cyberpunk, spaceStation, gardenOffice
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cozyDesk: return "Cozy Desk"
        case .cyberpunk: return "Cyberpunk Workstation"
        case .spaceStation: return "Space Station"
        case .gardenOffice: return "Tiny Garden Office"
        }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    // General
    public var pauseReactions = false
    public var quietMode = false
    public var quietHours = QuietHours()
    public var animationIntensity: AnimationIntensity = .normal
    public var reducedMotion: ReducedMotionPreference = .system
    public var menuBarAnimation: MenuBarAnimation = .subtle
    public var menuBarStyle: MenuBarStyle = .roam
    public var menuBarRoamRange: MenuBarRoamRange = .full
    public var menuBarStageWidth: MenuBarStageWidth = .medium
    public var showOnboarding = true

    // Characters
    public var petName = "Mochi"
    public var companionName = "Patch"
    public var petColor: PetColor = .cream
    public var petAccessory: Accessory?
    public var companionAccessory: Accessory?
    public var deskAccessory: Accessory? = .plant
    public var theme: OfficeTheme = .cozyDesk
    public var companionVisibility: CompanionVisibility = .duringSessions
    public var companionLingerMinutes = 10
    public var companionSleepAfterMinutes = 6
    /// The pet sleeps while the Mac rests and is awake while you work.
    public var followSystem = true
    /// Minutes without input before the Mac counts as resting.
    public var restAfterMinutes = 5

    // Claude Code
    public var celebrateCommandResults = true
    public var longTurnMinutes = 10

    // Notifications & sound
    public var categoryDelivery: [String: CategoryDelivery] = [:]
    public var soundEnabled = false
    public var soundVolume = 0.45
    public var workSounds = false

    // Desktop pet
    public var desktopPetEnabled = false
    public var desktopPetAlwaysOnTop = true
    public var desktopPetSize: DesktopPetSize = .medium
    public var desktopPetClickThrough = false
    public var desktopPetShowsCompanion = true
    public var desktopPetPosition: DesktopPetPosition?

    // Privacy & history
    public var historyRetentionDays = 7
    public var storeProjectPaths = false
    public var keepNotificationText = true

    // Sessions
    public var pinnedSessionID: String?
    public var showResultCards = true

    // Developer
    public var developerMode = false

    // Features
    public var adventure = AdventureSettings()
    public var focus = FocusSettings()
    public var games = GameRecords()
    public var recap = RecapSettings()
    public var room = RoomLayout()
    public var seasonal = SeasonalSettings()
    public var speech = SpeechSettings()
    public var assistant = AssistantSettings()
    public var phone = PhoneSettings()
    public var agent = AgentSettings()
    public var hapticPurr = true
    public var notchDen = true
    public var lifeStages = true
    /// The life stage last celebrated (-1 before the first look).
    public var lifeStageSeen = -1

    public init() {}

    public func delivery(for category: NotificationCategory) -> CategoryDelivery {
        var delivery = categoryDelivery[category.rawValue] ?? category.defaultDelivery
        if !category.allowsBanner { delivery.banner = false }
        if !category.allowsBadge { delivery.badge = false }
        return delivery
    }

    public mutating func setDelivery(_ delivery: CategoryDelivery, for category: NotificationCategory) {
        categoryDelivery[category.rawValue] = delivery
    }

    // MARK: Tolerant decoding

    /// Decodes settings written by any version: unknown keys are ignored, missing
    /// keys take defaults, and a single bad value only resets that one setting.
    public static func decodeTolerantly(_ data: Data) -> AppSettings {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(AppSettings()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else {
            return AppSettings()
        }
        let decoder = JSONDecoder()
        // Upgrading from the classic icon: someone who chose a static icon keeps it rather than
        // suddenly getting a pet running along the bar.
        if stored["menuBarStyle"] == nil, (stored["menuBarAnimation"] as? String) == MenuBarAnimation.off.rawValue {
            merged["menuBarStyle"] = MenuBarStyle.icon.rawValue
        }
        func attempt(_ object: [String: Any]) -> AppSettings? {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? decoder.decode(AppSettings.self, from: data)
        }
        let everything = merged.merging(stored) { _, new in new }
        if let settings = attempt(everything) { return settings }
        for (key, value) in stored {
            var candidate = merged
            candidate[key] = value
            if attempt(candidate) != nil { merged = candidate }
        }
        return attempt(merged) ?? AppSettings()
    }
}
