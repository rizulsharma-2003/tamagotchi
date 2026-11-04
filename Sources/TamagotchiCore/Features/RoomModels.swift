import Foundation

/// The user's room decoration: furniture placed in the popover scene.
public struct RoomLayout: Codable, Sendable, Equatable {
    public var items: [PlacedFurniture] = []
    public init() {}
}

public struct PlacedFurniture: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Catalog identifier of the furniture kind.
    public var kind: String
    /// Position in the room, normalized 0…1 (x across the room, y from the back wall to the floor front).
    public var x: Double
    public var y: Double
    public var flipped: Bool

    public init(id: UUID = UUID(), kind: String, x: Double, y: Double, flipped: Bool = false) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.flipped = flipped
    }
}

// MARK: - Arranging the room

extension RoomLayout {
    /// At most this many pieces, so the room stays cosy rather than cluttered.
    public static let maxItems = 8
    /// Centre of a wall item, as a fraction of the room height.
    public static let wallBand: ClosedRange<Double> = 0.26...0.6
    /// Foot of a floor item, from the back of the floor (just behind the characters' feet) to a little forward.
    public static let floorBand: ClosedRange<Double> = 0.87...0.92
    /// Centre of a rug lying on the floor.
    public static let rugBand: ClosedRange<Double> = 0.9...0.95

    public var isFull: Bool { items.count >= Self.maxItems }

    /// The vertical band an item of `kind` may occupy.
    public static func band(for kind: FurnitureKind) -> ClosedRange<Double> {
        switch kind.placement {
        case .wall: return wallBand
        case .floor: return kind.isFlat ? rugBand : floorBand
        }
    }

    /// `(x, y)` moved into the room: wall items snap to the wall band, floor items to the floor,
    /// and nothing hangs over the left or right edge.
    public static func snapped(_ kind: FurnitureKind, x: Double, y: Double) -> (x: Double, y: Double) {
        let half = min(0.5, kind.width / 2 / FurnitureCatalog.roomWidth)
        let safeX = x.isFinite ? x : kind.defaultX
        let safeY = y.isFinite ? y : kind.defaultY
        let band = band(for: kind)
        return (min(max(safeX, half), 1 - half), min(max(safeY, band.lowerBound), band.upperBound))
    }

    /// Adds a piece, at `(x, y)` or at a free spot near its default place. Returns nil when the room is full.
    @discardableResult
    public mutating func add(_ kind: FurnitureKind, x: Double? = nil, y: Double? = nil, id: UUID = UUID()) -> PlacedFurniture? {
        guard !isFull else { return nil }
        let position: (x: Double, y: Double)
        if let x, let y {
            position = Self.snapped(kind, x: x, y: y)
        } else {
            position = freeSpot(for: kind)
        }
        let item = PlacedFurniture(id: id, kind: kind.id, x: position.x, y: position.y)
        items.append(item)
        return item
    }

    /// Moves a piece, snapping it into its band.
    public mutating func move(_ id: UUID, x: Double, y: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), let kind = FurnitureCatalog.kind(items[index].kind) else { return }
        let position = Self.snapped(kind, x: x, y: y)
        items[index].x = position.x
        items[index].y = position.y
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func toggleFlip(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].flipped.toggle()
    }

    /// The room as it should be drawn: unknown kinds (from a newer version) dropped, every piece back in
    /// its band, at most `maxItems`.
    public func sanitized() -> RoomLayout {
        var result = RoomLayout()
        for item in items where result.items.count < Self.maxItems {
            guard let kind = FurnitureCatalog.kind(item.kind) else { continue }
            var copy = item
            let position = Self.snapped(kind, x: item.x, y: item.y)
            copy.x = position.x
            copy.y = position.y
            result.items.append(copy)
        }
        return result
    }

    /// Back-to-front drawing order: rugs, then the wall, then floor pieces from the back.
    public var drawingOrder: [PlacedFurniture] {
        func rank(_ item: PlacedFurniture) -> (Int, Double) {
            guard let kind = FurnitureCatalog.kind(item.kind) else { return (3, item.y) }
            if kind.isFlat { return (0, item.y) }
            return (kind.placement == .wall ? 1 : 2, item.y)
        }
        return items.sorted { rank($0) < rank($1) }
    }

    /// The default spot for `kind`, nudged sideways when something already stands there.
    func freeSpot(for kind: FurnitureKind) -> (x: Double, y: Double) {
        let band = Self.band(for: kind)
        let step = max(0.06, kind.width / FurnitureCatalog.roomWidth)
        for offset in [0.0, 1, -1, 2, -2, 3, -3] {
            let candidate = Self.snapped(kind, x: kind.defaultX + offset * step, y: kind.defaultY)
            let crowded = items.contains { other in
                guard let otherKind = FurnitureCatalog.kind(other.kind), Self.band(for: otherKind) == band else { return false }
                return abs(other.x - candidate.x) < step * 0.6
            }
            if !crowded { return candidate }
        }
        return Self.snapped(kind, x: kind.defaultX, y: kind.defaultY)
    }
}
