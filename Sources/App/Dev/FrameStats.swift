import Foundation
import QuartzCore

/// Development-only frame meter (enabled with MACTAMAGOTCHI_DEBUG_STATE=1): how often
/// each scene really draws and how long a draw takes. DebugHooks writes it out.
@MainActor
final class FrameStats {
    static let shared = FrameStats()
    static let enabled = ProcessInfo.processInfo.environment["MACTAMAGOTCHI_DEBUG_STATE"] == "1"

    struct Window {
        var frameTimes: [CFTimeInterval] = []
        var drawDurations: [CFTimeInterval] = []
    }

    private(set) var windows: [String: Window] = [:]

    func record(_ name: String, drawStart: CFTimeInterval, drawEnd: CFTimeInterval) {
        guard Self.enabled else { return }
        var window = windows[name] ?? Window()
        window.frameTimes.append(drawStart)
        window.drawDurations.append(drawEnd - drawStart)
        let cutoff = drawStart - 2
        while let first = window.frameTimes.first, first < cutoff {
            window.frameTimes.removeFirst()
            window.drawDurations.removeFirst()
        }
        windows[name] = window
    }

    /// Frames per second over the last two seconds, the average and worst draw time,
    /// and the worst gap between frames (a stutter).
    func summary(now: CFTimeInterval = CACurrentMediaTime()) -> [String: Any] {
        var result: [String: Any] = [:]
        for (name, window) in windows {
            let recent = zip(window.frameTimes, window.drawDurations).filter { now - $0.0 < 2 }
            guard recent.count > 1 else {
                result[name] = ["fps": 0]
                continue
            }
            let span = recent.last!.0 - recent.first!.0
            let gaps = zip(recent.dropFirst(), recent).map { $0.0 - $1.0 }
            result[name] = [
                "fps": span > 0 ? Double(recent.count - 1) / span : 0,
                "drawMsAvg": recent.map(\.1).reduce(0, +) / Double(recent.count) * 1000,
                "drawMsMax": (recent.map(\.1).max() ?? 0) * 1000,
                "worstGapMs": (gaps.max() ?? 0) * 1000,
            ]
        }
        return result
    }
}
