import Foundation

/// The resolved way a single reaction may reach the user.
public struct DeliveryDecision: Equatable, Sendable {
    public var animate: Bool
    public var badge: Bool
    public var banner: Bool
    public var sound: Bool
    /// Quiet hours or quiet mode are softening this delivery.
    public var quiet: Bool

    public static let none = DeliveryDecision(animate: false, badge: false, banner: false, sound: false, quiet: false)
}

public struct NotificationContext: Sendable {
    public var now: Date
    public var popoverVisible: Bool
    public var reducedMotion: Bool
    public var isSimulated: Bool
    public var isLate: Bool
    /// A focus block is running: only sounds for things that need the user still play.
    public var focusing: Bool

    public init(now: Date, popoverVisible: Bool = false, reducedMotion: Bool = false, isSimulated: Bool = false, isLate: Bool = false,
                focusing: Bool = false) {
        self.now = now
        self.popoverVisible = popoverVisible
        self.reducedMotion = reducedMotion
        self.isSimulated = isSimulated
        self.isLate = isLate
        self.focusing = focusing
    }
}

public enum NotificationPolicy {
    public static func isQuiet(_ settings: AppSettings, at date: Date, calendar: Calendar = .current) -> Bool {
        settings.quietMode || settings.quietHours.isActive(at: date, calendar: calendar)
    }

    public static func decide(
        _ category: NotificationCategory,
        settings: AppSettings,
        context: NotificationContext,
        calendar: Calendar = .current
    ) -> DeliveryDecision {
        let preference = settings.delivery(for: category)
        let quiet = isQuiet(settings, at: context.now, calendar: calendar)

        // Late (spooled) events are history, not news: no reactions or alerts.
        if context.isLate { return .none }

        var decision = DeliveryDecision(
            animate: preference.animate,
            badge: preference.badge,
            banner: preference.banner,
            sound: preference.sound && settings.soundEnabled,
            quiet: quiet
        )
        if category == .toolActivity {
            decision.sound = preference.sound && settings.soundEnabled && settings.workSounds
        }
        if settings.pauseReactions {
            decision.animate = false
            decision.sound = false
            decision.banner = false
        }
        if quiet {
            decision.sound = false
            decision.banner = false
        }
        if context.focusing, category != .needsAttention {
            decision.sound = false
        }
        // The user is already looking at the popover.
        if context.popoverVisible {
            decision.banner = false
            decision.badge = false
        }
        if context.isSimulated {
            // Simulated activity never reaches Notification Center.
            decision.banner = false
        }
        return decision
    }
}

/// Batches repetitive banners: within the window only the first banner per key is
/// shown and later ones are counted, then summarized in the next banner.
public struct BannerCoalescer: Sendable {
    public var window: TimeInterval
    private var lastShown: [String: Date] = [:]
    private var suppressed: [String: Int] = [:]

    public init(window: TimeInterval = 45) {
        self.window = window
    }

    public enum Outcome: Equatable, Sendable {
        case show(suppressedSinceLast: Int)
        case suppress
    }

    public mutating func register(key: String, at now: Date) -> Outcome {
        if let last = lastShown[key], now.timeIntervalSince(last) < window {
            suppressed[key, default: 0] += 1
            return .suppress
        }
        lastShown[key] = now
        let count = suppressed[key] ?? 0
        suppressed[key] = 0
        return .show(suppressedSinceLast: count)
    }
}
