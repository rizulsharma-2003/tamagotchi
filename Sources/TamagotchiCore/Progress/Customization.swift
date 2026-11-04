import Foundation

public enum AccessorySlot: String, Codable, Sendable {
    case wearable
    case desk
}

public enum Accessory: String, Codable, Sendable, CaseIterable, Identifiable {
    // Wearables
    case partyHat, beanie, graduationCap, detectiveHat, santaHat, flowerCrown, witchHat
    case roundGlasses, headphones, hoodie, scarf
    // Desk
    case plant, coffeeMug, rubberDuck, pumpkin, trophy, lavaLamp

    public var id: String { rawValue }

    public var slot: AccessorySlot {
        switch self {
        case .plant, .coffeeMug, .rubberDuck, .pumpkin, .trophy, .lavaLamp: return .desk
        default: return .wearable
        }
    }

    public var title: String {
        switch self {
        case .partyHat: return "Party Hat"
        case .beanie: return "Cozy Beanie"
        case .graduationCap: return "Graduation Cap"
        case .detectiveHat: return "Detective Hat"
        case .santaHat: return "Festive Hat"
        case .flowerCrown: return "Flower Crown"
        case .witchHat: return "Witch Hat"
        case .roundGlasses: return "Round Glasses"
        case .headphones: return "Tiny Headphones"
        case .hoodie: return "Developer Hoodie"
        case .scarf: return "Knitted Scarf"
        case .plant: return "Desk Plant"
        case .coffeeMug: return "Coffee Mug"
        case .rubberDuck: return "Rubber Duck"
        case .pumpkin: return "Little Pumpkin"
        case .trophy: return "Tiny Trophy"
        case .lavaLamp: return "Lava Lamp"
        }
    }

    public enum Unlock: Sendable, Equatable {
        case always
        case achievement(AchievementID)
        /// Available during these months (1–12).
        case season(ClosedRange<Int>)
    }

    public var unlock: Unlock {
        switch self {
        case .beanie, .roundGlasses, .scarf, .plant, .coffeeMug, .rubberDuck: return .always
        case .headphones: return .achievement(.firstSession)
        case .partyHat: return .achievement(.firstTurn)
        case .trophy: return .achievement(.firstGreenBuild)
        case .graduationCap: return .achievement(.firstMilestone)
        case .detectiveHat: return .achievement(.caseClosed)
        case .hoodie: return .achievement(.goodFriends)
        case .lavaLamp: return .achievement(.globetrotter)
        case .flowerCrown: return .achievement(.bestFriends)
        case .pumpkin, .witchHat: return .season(10...11)
        case .santaHat: return .season(12...12)
        }
    }

    public func isAvailable(unlocked: Set<AchievementID>, date: Date, calendar: Calendar = .current) -> Bool {
        switch unlock {
        case .always: return true
        case .achievement(let id): return unlocked.contains(id)
        case .season(let months):
            return months.contains(calendar.component(.month, from: date))
        }
    }

    public var unlockHint: String {
        switch unlock {
        case .always: return "Available"
        case .achievement(let id): return "Unlock: \(id.title)"
        case .season(let months):
            let formatter = DateFormatter()
            let names = formatter.monthSymbols ?? []
            let first = names.indices.contains(months.lowerBound - 1) ? names[months.lowerBound - 1] : "\(months.lowerBound)"
            return "Seasonal (\(first))"
        }
    }
}
