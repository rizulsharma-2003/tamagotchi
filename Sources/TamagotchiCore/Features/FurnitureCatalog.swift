import Foundation

/// Where a piece of furniture lives in the room.
public enum FurniturePlacement: String, Codable, Sendable {
    /// Hangs on the back wall (posters, clocks, photos).
    case wall
    /// Stands on the floor, behind the characters.
    case floor
}

/// How a piece of furniture is earned. Nothing is ever taken away again.
public enum FurnitureUnlock: Sendable, Equatable {
    case always
    case friendshipLevel(Int)
    case achievement(AchievementID)
}

/// One kind of furniture in the catalog.
public struct FurnitureKind: Sendable, Equatable, Identifiable {
    /// Stable identifier, stored in `PlacedFurniture.kind`.
    public let id: String
    public let title: String
    public let placement: FurniturePlacement
    /// Lies flat on the floor (a rug), so it goes under everything else.
    public let isFlat: Bool
    /// Size in scene points at scale 1 (the popover room is 360 × 178).
    public let width: Double
    public let height: Double
    public let unlock: FurnitureUnlock
    /// Where it goes when added with a click instead of a drag (normalized).
    public let defaultX: Double

    public init(id: String, title: String, placement: FurniturePlacement, isFlat: Bool = false, width: Double, height: Double,
                unlock: FurnitureUnlock, defaultX: Double) {
        self.id = id
        self.title = title
        self.placement = placement
        self.isFlat = isFlat
        self.width = width
        self.height = height
        self.unlock = unlock
        self.defaultX = defaultX
    }

    public func isUnlocked(_ progress: ProgressState) -> Bool {
        switch unlock {
        case .always: return true
        case .friendshipLevel(let level): return progress.friendshipLevel >= level
        case .achievement(let id): return progress.unlocked[id.rawValue] != nil
        }
    }

    /// How to earn it, for tooltips.
    public var unlockHint: String {
        switch unlock {
        case .always: return "Available"
        case .friendshipLevel(let level): return "Unlocks at friendship level \(level)"
        case .achievement(let id): return "Unlock: \(id.title) — \(id.criteria)"
        }
    }

    /// Default vertical position: a little above the middle of the wall, or at the back of the floor.
    public var defaultY: Double {
        switch placement {
        case .wall: return 0.36
        case .floor: return isFlat ? RoomLayout.rugBand.lowerBound : RoomLayout.floorBand.lowerBound
        }
    }
}

/// The cosy furniture Mochi and the companion can decorate their room with.
public enum FurnitureCatalog {
    /// The popover room the sizes are designed for.
    public static let roomWidth = 360.0
    public static let roomHeight = 178.0

    public static let all: [FurnitureKind] = [
        FurnitureKind(id: "rug", title: "Round Rug", placement: .floor, isFlat: true, width: 92, height: 15, unlock: .always, defaultX: 0.47),
        FurnitureKind(id: "cushion", title: "Floor Cushion", placement: .floor, width: 30, height: 15, unlock: .always, defaultX: 0.47),
        FurnitureKind(id: "plant", title: "Big Plant", placement: .floor, width: 34, height: 58, unlock: .always, defaultX: 0.06),
        FurnitureKind(id: "poster", title: "Sunset Poster", placement: .wall, width: 30, height: 38, unlock: .always, defaultX: 0.47),
        FurnitureKind(id: "lamp", title: "Floor Lamp", placement: .floor, width: 24, height: 84, unlock: .friendshipLevel(1), defaultX: 0.94),
        FurnitureKind(id: "bookshelf", title: "Bookshelf", placement: .floor, width: 40, height: 64, unlock: .friendshipLevel(2), defaultX: 0.07),
        FurnitureKind(id: "beanbag", title: "Beanbag", placement: .floor, width: 40, height: 26, unlock: .friendshipLevel(3), defaultX: 0.93),
        FurnitureKind(id: "catTree", title: "Cat Tree", placement: .floor, width: 40, height: 86, unlock: .friendshipLevel(4), defaultX: 0.07),
        FurnitureKind(id: "clock", title: "Wall Clock", placement: .wall, width: 24, height: 24, unlock: .achievement(.firstSession), defaultX: 0.55),
        FurnitureKind(id: "photo", title: "Photo of the Two Friends", placement: .wall, width: 34, height: 27, unlock: .achievement(.firstTurn),
                      defaultX: 0.4),
        FurnitureKind(id: "fishBowl", title: "Fish Bowl", placement: .floor, width: 26, height: 40, unlock: .achievement(.firstGreenBuild),
                      defaultX: 0.93),
        FurnitureKind(id: "toyBox", title: "Toy Box", placement: .floor, width: 30, height: 23, unlock: .achievement(.goodFriends), defaultX: 0.47),
    ]

    public static func kind(_ id: String) -> FurnitureKind? {
        all.first { $0.id == id }
    }

    public static func unlocked(_ progress: ProgressState) -> [FurnitureKind] {
        all.filter { $0.isUnlocked(progress) }
    }
}
