import Foundation
import Observation
import SwiftUI
import TamagotchiCore

/// The debug override, plus a revision the controller bumps when the day's event changes so views
/// that captured the event (scene, menu bar) read it again.
@MainActor
@Observable
final class SeasonState {
    static let shared = SeasonState()

    enum Override: Equatable, CustomStringConvertible {
        case calendar, off, event(SeasonalEvent)
        var description: String {
            switch self {
            case .calendar: return "calendar"
            case .off: return "off"
            case .event(let event): return event.rawValue
            }
        }
    }

    var override: Override = .calendar
    var revision = 0

    private struct CacheKey: Equatable {
        var minute: Int
        var settings: SeasonalSettings
        var adopted: Date?
    }

    @ObservationIgnored private var cache: (key: CacheKey, event: SeasonalEvent?)?

    /// The calendar's event for now, worked out at most once a minute.
    func calendarEvent(settings: SeasonalSettings, adopted: Date?, now: Date = Date()) -> SeasonalEvent? {
        let key = CacheKey(minute: Int(now.timeIntervalSince1970 / 60), settings: settings, adopted: adopted)
        if let cache, cache.key == key { return cache.event }
        let event = SeasonCalendar.event(on: now, settings: settings, mochiBirthday: adopted)
        cache = (key, event)
        return event
    }
}

/// What per-frame drawing needs but isn't handed (the theme, Reduced Motion, the menu-bar switch,
/// the pet's colour for the photo on the wall).
/// Recorded on the main actor whenever a snapshot asks for the current event — once per state
/// change, never per frame — and only read while drawing on the main thread.
enum SeasonRenderContext {
    nonisolated(unsafe) static var theme: OfficeTheme = .cozyDesk
    nonisolated(unsafe) static var reducedMotion = false
    nonisolated(unsafe) static var decorateMenuBar = true
    /// The year New Year's decorations welcome.
    nonisolated(unsafe) static var newYear = 2027
    /// Candles on the birthday cake.
    nonisolated(unsafe) static var candles = 3
    /// The pet's coat, for the framed photo in the room.
    nonisolated(unsafe) static var petColor: PetColor = .cream
}

enum SeasonDecor {
    enum Wearer { case pet, companion }

    /// The costume for an event, worn when the user hasn't chosen an accessory.
    static func costume(for event: SeasonalEvent?, wearer: Wearer) -> Accessory? {
        switch event {
        case .halloween?: return .witchHat
        case .christmas?: return .santaHat
        case .newYear?, .userBirthday?, .mochiBirthday?: return .partyHat
        case .diwali?: return .flowerCrown
        case .valentines?, nil: return nil
        }
    }

    /// The seasonal event to show right now, if any (nil when decorations are off).
    @MainActor
    static func currentEvent(world: CompanionWorld) -> SeasonalEvent? {
        let state = SeasonState.shared
        _ = state.revision // observed, so views refresh when the day's event changes
        let settings = world.settings
        let adopted = world.progress.firstMetAt
        let now = Date()
        SeasonRenderContext.theme = settings.theme
        SeasonRenderContext.petColor = settings.petColor
        SeasonRenderContext.reducedMotion = world.reducedMotion
        SeasonRenderContext.decorateMenuBar = settings.seasonal.decorateMenuBar
        SeasonRenderContext.newYear = SeasonCalendar.newYear(on: now)
        let event: SeasonalEvent?
        switch state.override {
        case .off: event = nil
        case .event(let forced): event = forced
        case .calendar: event = state.calendarEvent(settings: settings.seasonal, adopted: adopted, now: now)
        }
        if event == .mochiBirthday {
            SeasonRenderContext.candles = adopted.map { min(5, max(1, SeasonCalendar.yearsSince($0, on: now))) } ?? 1
        } else {
            SeasonRenderContext.candles = 3
        }
        return event
    }

    /// Room decorations, drawn over the theme background and behind the characters.
    static func drawRoom(_ event: SeasonalEvent?, in g: GraphicsContext, layout: SceneLayout, dark: Bool, time: TimeInterval) {
        guard let event, layout.background else { return }
        SeasonArt.room(event, in: g, layout: layout, dark: dark, time: time, theme: SeasonRenderContext.theme,
                       reduced: SeasonRenderContext.reducedMotion)
    }

    /// Weather and sky effects in front of everything (snow, fireworks).
    static func drawForeground(_ event: SeasonalEvent?, in g: GraphicsContext, layout: SceneLayout, dark: Bool, time: TimeInterval,
                               reduced: Bool) {
        // Only the popover room: on the transparent desktop pet a patch of snow would look like a box.
        guard let event, layout.background, !reduced else { return }
        SeasonArt.foreground(event, in: g, layout: layout, dark: dark, time: time)
    }

    /// A tiny decoration beside the menu-bar bed (a pumpkin, a diya, a little tree).
    static func drawMenuBarAccent(_ event: SeasonalEvent?, in g: GraphicsContext, near point: CGPoint, scale: CGFloat, dark: Bool) {
        guard let event, SeasonRenderContext.decorateMenuBar else { return }
        SeasonArt.menuBarAccent(event, in: g, at: CGPoint(x: point.x + 15.5 * scale, y: point.y), scale: scale, dark: dark)
    }

    struct Greeting {
        var title: String
        var detail: String
        var line: String
        var animation: PetAnimation
    }

    static func greeting(for event: SeasonalEvent, settings: AppSettings, adopted: Date?) -> Greeting {
        let pet = settings.petName
        let companion = settings.companionName
        switch event {
        case .halloween:
            return Greeting(title: "Happy Halloween!", detail: "\(pet) and \(companion) dressed up. Treats are candy this week.",
                            line: "Trick or treat!", animation: .excitedJump)
        case .diwali:
            return Greeting(title: "Happy Diwali!", detail: "Diyas, lights and a rangoli — and laddoos for treats.",
                            line: "So many lights!", animation: .dance)
        case .christmas:
            return Greeting(title: "Merry Christmas!", detail: "Snow outside, a tree inside, gingerbread for treats.",
                            line: "Is that… snow?!", animation: .happyBounce)
        case .newYear:
            return Greeting(title: "Happy New Year!", detail: "Here's to \(SeasonCalendar.newYear(on: Date())) together.",
                            line: "Happy New Year!", animation: .victory)
        case .valentines:
            return Greeting(title: "Happy Valentine's Day!", detail: "\(pet) baked heart cookies.",
                            line: "You're my favourite human.", animation: .greet)
        case .userBirthday:
            return Greeting(title: "Happy Birthday!", detail: "\(pet) and \(companion) threw you a little party.",
                            line: "Happy birthday to you!", animation: .dance)
        case .mochiBirthday:
            let years = adopted.map { max(1, SeasonCalendar.yearsSince($0, on: Date())) } ?? 1
            return Greeting(title: "Happy Birthday, \(pet)!", detail: "\(years) year\(years == 1 ? "" : "s") together today.",
                            line: "It's my birthday!", animation: .victory)
        }
    }

    /// The event's name as the user sees it.
    static func title(_ event: SeasonalEvent, petName: String) -> String {
        event == .mochiBirthday ? "\(petName)'s birthday" : event.title
    }
}
