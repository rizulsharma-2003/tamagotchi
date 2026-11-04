import ActivityKit
import Foundation

/// Mochi's Live Activity. The field names are the wire format: the Mac app writes exactly these
/// keys in its push payloads (`attributes` and `content-state`), so keep both sides in step.
struct MochiActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// working · waiting · done · idle · error · asleep
        var phase: String
        /// "Claude is working", "Claude needs you", …
        var title: String
        /// An optional second line (project and tool count, if the Mac is allowed to share them).
        var detail: String?
        /// Unix time the current turn or wait began; drives the live timer.
        var since: Double
        /// Which of the phase's ten poses to show. Each update moves it on and the system animates
        /// the change; Live Activities can't run animations of their own.
        var frame: Int?
    }

    var petName: String
    var companionName: String
}

extension MochiActivityAttributes.ContentState {
    static let phases: Set<String> = ["working", "waiting", "done", "idle", "error", "asleep"]

    var art: String { Self.phases.contains(phase) ? phase : "idle" }
    var sinceDate: Date { Date(timeIntervalSince1970: since) }
    var showsTimer: Bool { phase == "working" || phase == "waiting" }
}
