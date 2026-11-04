import Foundation

/// Holidays and personal days that decorate the world.
public enum SeasonalEvent: String, Codable, Sendable, CaseIterable, Identifiable {
    case halloween, diwali, christmas, newYear, valentines, userBirthday, mochiBirthday
    public var id: String { rawValue }

    /// A name for lists; the pet's birthday is named by the app, which knows the pet's name.
    public var title: String {
        switch self {
        case .halloween: return "Halloween"
        case .diwali: return "Diwali"
        case .christmas: return "Christmas"
        case .newYear: return "New Year"
        case .valentines: return "Valentine's Day"
        case .userBirthday: return "Your birthday"
        case .mochiBirthday: return "Pet's birthday"
        }
    }

    /// Wins when two events overlap: personal days first, then the bigger festivals.
    public var priority: Int {
        switch self {
        case .userBirthday: return 7
        case .mochiBirthday: return 6
        case .diwali: return 5
        case .halloween: return 4
        case .christmas: return 3
        case .newYear: return 2
        case .valentines: return 1
        }
    }
}

public struct SeasonalSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var birthdayMonth: Int?
    public var birthdayDay: Int?
    public var decorateMenuBar = true
    public init() {}
}

/// Which seasonal event (if any) is active on a date. Pure: everything depends on the arguments.
public enum SeasonCalendar {
    /// Diwali (Lakshmi Puja) by year. The festival follows the lunar calendar, so it is looked up,
    /// not computed; years missing here simply have no Diwali decorations.
    public static let diwaliDates: [Int: DateComponents] = [
        2025: DateComponents(year: 2025, month: 10, day: 20),
        2026: DateComponents(year: 2026, month: 11, day: 8),
        2027: DateComponents(year: 2027, month: 10, day: 29),
        2028: DateComponents(year: 2028, month: 10, day: 17),
        2029: DateComponents(year: 2029, month: 11, day: 5),
        2030: DateComponents(year: 2030, month: 10, day: 26),
    ]

    /// Diwali lights go up three days early and stay two days after.
    public static let diwaliWindow = -3...2

    /// The event to show on `date`: the highest-priority one whose window contains it.
    /// `mochiBirthday` is the day the pet was adopted; only its anniversaries count.
    public static func event(on date: Date, settings: SeasonalSettings, mochiBirthday: Date?, calendar: Calendar = .current) -> SeasonalEvent? {
        guard settings.enabled else { return nil }
        return activeEvents(on: date, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar).first
    }

    /// Every event whose window contains `date`, highest priority first (ignores `enabled`).
    public static func activeEvents(on date: Date, settings: SeasonalSettings, mochiBirthday: Date?, calendar: Calendar = .current) -> [SeasonalEvent] {
        let today = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = today.year, let month = today.month, let day = today.day else { return [] }
        var events: [SeasonalEvent] = []

        if let birthMonth = settings.birthdayMonth, let birthDay = settings.birthdayDay,
           isAnniversary(month: birthMonth, day: birthDay, on: today) {
            events.append(.userBirthday)
        }
        if let adopted = mochiBirthday {
            let first = calendar.dateComponents([.year, .month, .day], from: adopted)
            if let firstYear = first.year, let firstMonth = first.month, let firstDay = first.day, year > firstYear,
               isAnniversary(month: firstMonth, day: firstDay, on: today) {
                events.append(.mochiBirthday)
            }
        }
        if let offset = daysFromDiwali(to: date, year: year, calendar: calendar), diwaliWindow.contains(offset) {
            events.append(.diwali)
        }
        if (month == 10 && day >= 24) || (month == 11 && day == 1) { events.append(.halloween) }
        if month == 12 && (18...26).contains(day) { events.append(.christmas) }
        if (month == 12 && day == 31) || (month == 1 && day == 1) { events.append(.newYear) }
        if month == 2 && (13...14).contains(day) { events.append(.valentines) }
        return events.sorted { $0.priority > $1.priority }
    }

    /// The next time a different event begins after `date` (within about a year), and the day it starts.
    public static func nextEvent(after date: Date, settings: SeasonalSettings, mochiBirthday: Date?,
                                 calendar: Calendar = .current) -> (event: SeasonalEvent, starts: Date)? {
        guard settings.enabled else { return nil }
        var day = calendar.startOfDay(for: date)
        var previous = event(on: day, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar)
        for _ in 0..<370 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
            let current = event(on: day, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar)
            if let current, current != previous { return (current, day) }
            previous = current
        }
        return nil
    }

    /// The last day of the run of days showing `event` that contains `date` (nil if it isn't showing).
    public static func lastDay(of event: SeasonalEvent, from date: Date, settings: SeasonalSettings, mochiBirthday: Date?,
                               calendar: Calendar = .current) -> Date? {
        var day = calendar.startOfDay(for: date)
        guard self.event(on: day, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar) == event else { return nil }
        for _ in 0..<14 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  self.event(on: next, settings: settings, mochiBirthday: mochiBirthday, calendar: calendar) == event else { break }
            day = next
        }
        return day
    }

    /// Identifies one occurrence of an event (e.g. "halloween-2026"), so it is greeted only once.
    /// New Year's Eve and New Year's Day share the new year's key.
    public static func occasionKey(_ event: SeasonalEvent, on date: Date, calendar: Calendar = .current) -> String {
        let year = event == .newYear ? newYear(on: date, calendar: calendar) : calendar.component(.year, from: date)
        return "\(event.rawValue)-\(year)"
    }

    /// The New Year being welcomed (or just welcomed): next year from July on, this year before.
    public static func newYear(on date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 2000
        return (parts.month ?? 1) >= 7 ? year + 1 : year
    }

    /// Whole years since `start` on `date` (the pet's age on its birthday).
    public static func yearsSince(_ start: Date, on date: Date, calendar: Calendar = .current) -> Int {
        max(0, calendar.component(.year, from: date) - calendar.component(.year, from: start))
    }

    // MARK: Helpers

    /// Whether (month, day) falls on `today`; 29 February is kept on the 28th in other years.
    static func isAnniversary(month: Int, day: Int, on today: DateComponents) -> Bool {
        guard (1...12).contains(month), (1...31).contains(day), let year = today.year else { return false }
        if month == 2, day == 29, !isLeapYear(year) {
            return today.month == 2 && today.day == 28
        }
        return today.month == month && today.day == day
    }

    /// Gregorian leap years.
    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Days from this year's Diwali to `date` (negative before it), if the year is known.
    static func daysFromDiwali(to date: Date, year: Int, calendar: Calendar) -> Int? {
        guard var components = diwaliDates[year] else { return nil }
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        guard let diwali = calendar.date(from: components) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: diwali), to: calendar.startOfDay(for: date)).day
    }
}
