import CoreGraphics
import Foundation

/// A point in global screen points (y up, as AppKit reports them). During an adventure it is
/// where Mochi's feet are.
public struct AdventurePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: AdventurePoint) -> Double { hypot(other.x - x, other.y - y) }
}

/// A stretch of window top Mochi can walk along.
public struct AdventureLedge: Equatable, Sendable {
    public var minX: Double
    public var maxX: Double
    public var y: Double
    /// The window it belongs to (its index, front to back).
    public var window: Int

    public init(minX: Double, maxX: Double, y: Double, window: Int) {
        self.minX = minX
        self.maxX = maxX
        self.y = y
        self.window = window
    }

    public var width: Double { maxX - minX }
    public var midX: Double { (minX + maxX) / 2 }

    /// `x` kept `margin` inside the ledge (its middle when it is too short for that).
    func clamp(_ x: Double, margin: Double) -> Double {
        let lo = minX + margin
        let hi = maxX - margin
        guard lo <= hi else { return midX }
        return Swift.min(hi, Swift.max(lo, x))
    }
}

/// What Mochi can walk on during a desktop adventure: the floor (the top of the Dock, or the
/// bottom of the screen), the screen's side edges, and the tops of other apps' windows where
/// nothing in front of them hides them. Only window frames are known, never what they show.
public struct AdventureTerrain: Equatable, Sendable {
    /// Where Mochi may be: the screen's visible frame (under the menu bar, above the Dock).
    public var bounds: CGRect
    /// The floor: the top of the Dock, or the bottom of the screen when the Dock hides or sits at a side.
    public var floorY: Double
    /// The stretch of floor the Dock covers, when it sits at the bottom of the screen.
    public var dock: ClosedRange<Double>?
    /// Visible window tops, highest first.
    public var ledges: [AdventureLedge]

    /// Windows smaller than this are not worth climbing on (palettes, popovers, tooltips).
    public static let minimumWindow = CGSize(width: 160, height: 90)
    /// The shortest stretch of window top Mochi walks along.
    public static let minimumLedge = 56.0
    /// At most this many windows (front to back) are looked at.
    public static let maximumWindows = 16

    /// - Parameters:
    ///   - bounds: the screen's visible frame.
    ///   - floorY: the top of the Dock (the bottom of `bounds` when nil).
    ///   - dock: the Dock's stretch of floor, when it sits at the bottom.
    ///   - windows: other apps' window frames, front to back.
    ///   - headroom: Mochi's height plus a margin: window tops with less room above are skipped.
    public init(bounds: CGRect, floorY: Double? = nil, dock: ClosedRange<Double>? = nil, windows: [CGRect] = [], headroom: Double = 52) {
        self.bounds = bounds
        let floor = floorY ?? Double(bounds.minY)
        self.floorY = floor
        self.dock = dock
        ledges = Self.ledges(windows: windows, bounds: bounds, floorY: floor, headroom: headroom)
    }

    static func ledges(windows: [CGRect], bounds: CGRect, floorY: Double, headroom: Double) -> [AdventureLedge] {
        let considered = Array(windows.prefix(maximumWindows))
        var result: [AdventureLedge] = []
        for (index, window) in considered.enumerated() {
            guard window.width >= minimumWindow.width, window.height >= minimumWindow.height else { continue }
            let top = Double(window.maxY)
            // Room above it for Mochi (a maximised window's top is right under the menu bar), and off the floor.
            guard top <= Double(bounds.maxY) - headroom, top >= floorY + headroom else { continue }
            let lo = Swift.max(Double(window.minX), Double(bounds.minX))
            let hi = Swift.min(Double(window.maxX), Double(bounds.maxX))
            guard hi - lo >= minimumLedge else { continue }
            var spans: [ClosedRange<Double>] = [lo...hi]
            // Windows in front take away what they cover: Mochi would be standing inside them.
            for front in considered.prefix(index) where Double(front.minY) < top + headroom && Double(front.maxY) > top - 2 {
                spans = subtract((Double(front.minX) - 4)...(Double(front.maxX) + 4), from: spans)
            }
            for span in spans where span.upperBound - span.lowerBound >= minimumLedge {
                result.append(AdventureLedge(minX: span.lowerBound, maxX: span.upperBound, y: top, window: index))
            }
        }
        return result.sorted { $0.y != $1.y ? $0.y > $1.y : $0.minX < $1.minX }
    }

    static func subtract(_ cut: ClosedRange<Double>, from spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        spans.flatMap { span -> [ClosedRange<Double>] in
            if cut.upperBound <= span.lowerBound || cut.lowerBound >= span.upperBound { return [span] }
            var parts: [ClosedRange<Double>] = []
            if cut.lowerBound > span.lowerBound { parts.append(span.lowerBound...cut.lowerBound) }
            if cut.upperBound < span.upperBound { parts.append(cut.upperBound...span.upperBound) }
            return parts
        }
    }

    /// A window covering the whole screen, menu bar and all: a full-screen app is showing.
    public static func looksFullScreen(windows: [CGRect], screen: CGRect) -> Bool {
        windows.contains { $0.insetBy(dx: -1, dy: -1).contains(screen) }
    }

    /// The highest thing to land on at `point.x`, at or below `point.y` (the floor when there is nothing else).
    public func surface(below point: AdventurePoint) -> (y: Double, ledge: AdventureLedge?) {
        if let ledge = ledges.first(where: { $0.y <= point.y + 0.001 && point.x >= $0.minX && point.x <= $0.maxX }) {
            return (ledge.y, ledge)
        }
        return (floorY, nil)
    }

    /// The ledge Mochi stands on at `point` (nil on the floor or in the air).
    public func ledge(at point: AdventurePoint, tolerance: Double = 0) -> AdventureLedge? {
        ledges.first { abs($0.y - point.y) < 1.5 && point.x >= $0.minX - tolerance && point.x <= $0.maxX + tolerance }
    }

    /// Something holds Mochi up at `point`: the floor, or a window top.
    public func supports(_ point: AdventurePoint, tolerance: Double = 0) -> Bool {
        abs(point.y - floorY) < 1.5 || ledge(at: point, tolerance: tolerance) != nil
    }
}
