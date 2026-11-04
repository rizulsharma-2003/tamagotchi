import CoreGraphics
import Foundation

/// Where the menu-bar overlay goes and which strip Mochi may use, computed from
/// plain screen geometry (global screen points, y up, as AppKit reports them).
public struct MenuBarGeometry: Equatable, Sendable {
    /// The overlay panel's frame: the menu-bar band over Mochi's zone and its bed.
    public var overlayFrame: CGRect
    /// The status item's on-screen frame (Mochi's home slot).
    public var homeSlot: CGRect
    public var zone: RoamZone

    public var bandHeight: Double { Double(overlayFrame.height) }
}

public enum RoamGeometry {
    /// Width of the status item in roaming mode: the bed, plus room for mini Patch.
    public static func homeSlotWidth(companion: Bool) -> Double { companion ? 54 : 30 }

    /// The bed sits at the end of the slot away from where status items grow, so it stays put
    /// when the slot widens for Patch (items grow towards the app menus).
    public static func bedX(inSlot slot: CGRect, rightToLeft: Bool = false) -> Double {
        rightToLeft ? Double(slot.minX) + 15 : Double(slot.maxX) - 15
    }

    /// Patch sits at the other end of the slot, beside the bed.
    public static func companionX(inSlot slot: CGRect, rightToLeft: Bool = false) -> Double {
        rightToLeft ? Double(slot.maxX) - 13 : Double(slot.minX) + 13
    }

    /// Mochi's centre stays this far inside the overlay so it is never cut off.
    public static let edgeMargin = 12.0

    /// The clock and Control Center (with the camera and microphone privacy dots) sit at the
    /// outer end of the bar. Mochi never goes there: it is the most-read part of the bar.
    public static let clockGuard = 180.0

    /// - Parameters:
    ///   - screenFrame: `NSScreen.frame` of the status item's screen.
    ///   - notchLeftArea: `NSScreen.auxiliaryTopLeftArea` (nil without a notch).
    ///   - notchRightArea: `NSScreen.auxiliaryTopRightArea` (nil without a notch).
    ///   - barWindowFrame: the status item's window frame (the menu-bar band).
    ///   - itemFrame: the status item button's frame on screen.
    ///   - range: how far Mochi may roam in all (centred on its bed); nil for the whole free bar.
    ///   - rightToLeft: the menu bar is laid out right to left (app menus on the right).
    /// - Returns: nil when the geometry makes no sense (item off-screen, hidden behind the
    ///   camera housing, no band).
    public static func compute(screenFrame: CGRect, notchLeftArea: CGRect? = nil, notchRightArea: CGRect?, barWindowFrame: CGRect,
                               itemFrame: CGRect, range: Double?, rightToLeft: Bool = false) -> MenuBarGeometry? {
        guard itemFrame.width > 4, barWindowFrame.height >= 18, barWindowFrame.height <= 60 else { return nil }
        // The item must really sit in this screen's menu bar (macOS parks items that do not fit off-screen).
        // On secondary displays the status-bar window can poke a couple of points above the screen.
        guard barWindowFrame.maxY >= screenFrame.maxY - 4, barWindowFrame.maxY <= screenFrame.maxY + 8,
              itemFrame.minX >= screenFrame.minX - 1, itemFrame.maxX <= screenFrame.maxX + 1,
              itemFrame.minY >= barWindowFrame.minY - 1, itemFrame.maxY <= barWindowFrame.maxY + 1 else { return nil }
        let bandTop = Swift.min(Double(barWindowFrame.maxY), Double(screenFrame.maxY))
        let bandBottom = Double(barWindowFrame.minY)
        guard bandTop - bandBottom >= 18 else { return nil }

        // Work in "outward" coordinates: u grows from the app menus towards the clock, so the
        // right-to-left layout is the same problem mirrored.
        let screenMin = Double(screenFrame.minX)
        let screenMax = Double(screenFrame.maxX)
        func u(_ x: Double) -> Double { rightToLeft ? screenMin + screenMax - x : x }
        let itemInner = rightToLeft ? u(Double(itemFrame.maxX)) : Double(itemFrame.minX)
        let itemOuter = rightToLeft ? u(Double(itemFrame.minX)) : Double(itemFrame.maxX)
        let home = u(bedX(inSlot: itemFrame, rightToLeft: rightToLeft))
        let patch = u(companionX(inSlot: itemFrame, rightToLeft: rightToLeft))

        // The camera housing: the gap between the two auxiliary areas, in outward coordinates.
        var housing: ClosedRange<Double>?
        if let right = notchRightArea {
            let left = notchLeftArea.map { Double($0.maxX) } ?? (screenMin + screenMax - Double(right.minX))
            let a = Swift.min(u(left), u(Double(right.minX)))
            let b = Swift.max(u(left), u(Double(right.minX)))
            if b > a { housing = a...b }
        }
        var inner: Double
        var outer = screenMax - clockGuard
        /// Which edge of the housing Mochi's strip starts at (outward coordinates), and on which side.
        var denEdge: (u: Double, inward: Double)?
        if let housing {
            // Hidden behind the camera housing: nothing to show.
            if itemOuter > housing.lowerBound + 1, itemInner < housing.upperBound - 1 { return nil }
            if itemOuter <= housing.lowerBound + 1 {
                // Left of the notch (a crowded bar, or a menu-bar manager showing hidden items):
                // never across the housing, never towards the app menus.
                inner = itemInner - 4
                outer = housing.lowerBound - 6
                denEdge = (housing.lowerBound, 1)
            } else {
                inner = housing.upperBound
                denEdge = (housing.upperBound, -1)
            }
        } else {
            // No notch: at most from the middle of the screen, and never left of the item
            // itself (the app menus may reach that far on a crowded bar).
            inner = Swift.min((screenMin + screenMax) / 2, itemInner - 4)
        }
        // Everything beyond the bed towards the clock is other apps' status items.
        outer = Swift.max(outer, itemOuter + 2)
        if let range {
            // The range is shared between both sides of the bed, the spare going to the roomier side.
            let half = range / 2
            let innerRoom = home - inner
            let outerRoom = outer - home
            let toInner = Swift.min(innerRoom, half + Swift.max(0, half - outerRoom))
            let toOuter = Swift.min(outerRoom, half + Swift.max(0, half - innerRoom))
            inner = Swift.max(inner, home - toInner)
            outer = Swift.min(outer, home + toOuter)
        }
        inner = Swift.min(inner, itemInner - 4)
        outer = Swift.max(outer, itemOuter + 2)
        let zoneInner = Swift.min(inner + edgeMargin, home)
        let zoneOuter = Swift.max(outer - edgeMargin, home)
        let occupied = itemOuter + 1 < zoneOuter + RoamZone.footprint ? [(itemOuter + 1)...(screenMax)] : []
        // The den is only Mochi's when the strip reaches all the way to the housing (a roaming range may stop short).
        var overlayInner = inner
        var overlayOuter = outer
        if let edge = denEdge {
            if edge.inward < 0, inner > edge.u + 0.5 { denEdge = nil }
            if edge.inward > 0, outer < edge.u - 6.5 { denEdge = nil }
        }
        if let edge = denEdge {
            // The overlay ends exactly at the housing, so Mochi is cut off right at its edge.
            if edge.inward < 0 { overlayInner = Swift.min(inner, edge.u) } else { overlayOuter = Swift.max(outer, edge.u) }
        }
        let den = denEdge.map { RoamDen(edgeX: u($0.u), inward: rightToLeft ? -$0.inward : $0.inward) }

        // Back to screen x.
        let zone: RoamZone
        let overlayMin: Double
        let overlayMax: Double
        if rightToLeft {
            zone = RoamZone(minX: u(zoneOuter), maxX: u(zoneInner), homeX: u(home), companionX: u(patch),
                            occupied: occupied.map { u($0.upperBound)...u($0.lowerBound) }, den: den)
            overlayMin = u(overlayOuter)
            overlayMax = u(overlayInner)
        } else {
            zone = RoamZone(minX: zoneInner, maxX: zoneOuter, homeX: home, companionX: patch, occupied: occupied, den: den)
            overlayMin = overlayInner
            overlayMax = overlayOuter
        }
        let left = Swift.min(overlayMin, Double(itemFrame.minX) - 4)
        let right = Swift.max(overlayMax, Double(itemFrame.maxX) + 4)
        let overlay = CGRect(x: left, y: bandBottom, width: right - left, height: bandTop - bandBottom)
        return MenuBarGeometry(overlayFrame: overlay, homeSlot: itemFrame, zone: zone)
    }

    /// The zone inside a status item that hosts the whole stage (`.stage` style), in the item's own points.
    public static func stageZone(width: Double) -> RoamZone {
        let margin = 8.0
        let home = width - 11
        return RoamZone(minX: margin, maxX: width - margin, homeX: home, companionX: Swift.max(7, home - 26))
    }
}
