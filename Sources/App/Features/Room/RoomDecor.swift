import SwiftUI
import TamagotchiCore

/// Maps placed furniture between normalized room positions and scene points.
struct RoomSpace {
    var layout: SceneLayout

    var width: CGFloat { layout.size.width }
    var height: CGFloat { layout.size.height }

    /// 0 at the back of the floor band, 1 at its front.
    func depth(_ kind: FurnitureKind, y: Double) -> CGFloat {
        let band = RoomLayout.band(for: kind)
        return CGFloat(Ease.clamp((y - band.lowerBound) / (band.upperBound - band.lowerBound)))
    }

    /// The scene's scale, a touch larger towards the front of the floor.
    func scale(_ kind: FurnitureKind, y: Double) -> CGFloat {
        kind.placement == .floor && !kind.isFlat ? layout.scale * (0.96 + 0.08 * depth(kind, y: y)) : layout.scale
    }

    /// Wall pieces and rugs: their centre. Floor pieces: the middle of their foot.
    func anchor(for item: PlacedFurniture, kind: FurnitureKind) -> CGPoint {
        let x = CGFloat(item.x) * width
        switch kind.placement {
        case .wall:
            return CGPoint(x: x, y: CGFloat(item.y) * height)
        case .floor:
            let d = depth(kind, y: item.y)
            let lift: CGFloat = kind.isFlat ? 6 + 7 * d : 0.5 + 7 * d
            return CGPoint(x: x, y: layout.ground + lift * layout.scale)
        }
    }

    func frame(for item: PlacedFurniture, kind: FurnitureKind) -> CGRect {
        frame(anchor: anchor(for: item, kind: kind), kind: kind, scale: scale(kind, y: item.y))
    }

    func frame(anchor a: CGPoint, kind: FurnitureKind, scale k: CGFloat) -> CGRect {
        let size = CGSize(width: kind.width * k, height: kind.height * k)
        if kind.placement == .floor, !kind.isFlat {
            return CGRect(x: a.x - size.width / 2, y: a.y - size.height, width: size.width, height: size.height)
        }
        return CGRect(x: a.x - size.width / 2, y: a.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The snapped normalized position for a piece whose anchor is dragged to `point`.
    func position(anchor point: CGPoint, kind: FurnitureKind) -> (x: Double, y: Double) {
        let x = Double(point.x / width)
        let y: Double
        switch kind.placement {
        case .wall:
            y = Double(point.y / height)
        case .floor:
            let band = RoomLayout.band(for: kind)
            let lift = (point.y - layout.ground) / layout.scale
            let d = kind.isFlat ? (lift - 6) / 7 : (lift - 0.5) / 7
            y = band.lowerBound + Ease.clamp(Double(d)) * (band.upperBound - band.lowerBound)
        }
        return RoomLayout.snapped(kind, x: x, y: y)
    }

    /// Where the anchor goes when the pointer holds a new piece by its middle.
    func anchor(holding kind: FurnitureKind, at pointer: CGPoint) -> CGPoint {
        guard kind.placement == .floor, !kind.isFlat else { return pointer }
        return CGPoint(x: pointer.x, y: pointer.y + kind.height * layout.scale / 2)
    }

    /// Snaps an anchor into the piece's band.
    func snapped(_ anchor: CGPoint, kind: FurnitureKind) -> (anchor: CGPoint, position: (x: Double, y: Double)) {
        let position = position(anchor: anchor, kind: kind)
        let item = PlacedFurniture(kind: kind.id, x: position.x, y: position.y)
        return (self.anchor(for: item, kind: kind), position)
    }
}

/// Draws the placed furniture into the scene, behind the characters.
enum RoomDecor {
    /// The piece the editor is carrying; the scene leaves it out meanwhile (main thread only).
    nonisolated(unsafe) static var liftedID: UUID?

    static func draw(_ room: RoomLayout, in g: GraphicsContext, layout: SceneLayout, dark: Bool, time: TimeInterval) {
        guard layout.background, !room.items.isEmpty else { return }
        for item in room.drawingOrder where item.id != liftedID {
            guard let kind = FurnitureCatalog.kind(item.kind) else { continue }
            drawPiece(item, kind: kind, in: g, layout: layout, dark: dark, time: time)
        }
    }

    static func drawPiece(_ item: PlacedFurniture, kind: FurnitureKind, in g: GraphicsContext, layout: SceneLayout, dark: Bool, time: TimeInterval) {
        let space = RoomSpace(layout: layout)
        let anchor = space.anchor(for: item, kind: kind)
        let k = space.scale(kind, y: item.y)
        var piece = g
        piece.translateBy(x: anchor.x, y: anchor.y)
        // The clock keeps its numbers the right way round.
        piece.scaleBy(x: item.flipped && kind.id != "clock" ? -k : k, y: k)
        FurnitureArt.draw(kind.id, in: piece, dark: dark, time: time)
    }
}
