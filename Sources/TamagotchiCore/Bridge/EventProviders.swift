import Foundation
import TamagotchiWire

/// A source of real development events.
///
/// Claude Code hooks (and explicit `report` calls, which share the same local
/// bridge) are the first provider. Future providers — Xcode or Flutter build
/// results, test runners, git hooks, other coding agents with documented event
/// APIs — implement this protocol and deliver the same sanitized `WireEvent`s, so
/// sessions, history, privacy rules and reactions apply to them unchanged.
@MainActor
public protocol EventProvider: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    func start(deliver: @escaping @MainActor (WireEvent, EventDelivery) -> Void)
    func stop()
}

/// Receives Claude Code hook events over the local bridge, and drains the spool
/// of events that arrived while the app was not listening.
@MainActor
public final class ClaudeHookEventProvider: EventProvider {
    public let identifier = "claude-code-hooks"
    public let displayName = "Claude Code hooks"
    public let paths: BridgePaths
    public let bridge: LocalEventBridge

    public var onBridgeState: ((LocalEventBridge.State, LocalEventBridge.Stats) -> Void)?
    /// (delivered late, dropped or expired)
    public var onSpoolDrained: ((Int, Int) -> Void)?

    private var deliver: (@MainActor (WireEvent, EventDelivery) -> Void)?
    private var spoolTimer: Timer?

    public init(paths: BridgePaths) {
        self.paths = paths
        self.bridge = LocalEventBridge(socketURL: paths.socketFile)
    }

    public func start(deliver: @escaping @MainActor (WireEvent, EventDelivery) -> Void) {
        self.deliver = deliver
        BridgePaths.ensurePrivateDirectory(paths.home)
        // Events that arrived while we were not running come first, as late history.
        drainSpool()
        bridge.start(
            deliver: { wire in
                Task { @MainActor in deliver(wire, .live) }
            },
            stateChanged: { [weak self] state, stats in
                Task { @MainActor in self?.onBridgeState?(state, stats) }
            }
        )
        // If the bridge was briefly unavailable, hooks spool; pick those up too.
        spoolTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.drainSpool() }
        }
        spoolTimer?.tolerance = 10
    }

    public func stop() {
        spoolTimer?.invalidate()
        spoolTimer = nil
        bridge.stop()
    }

    @discardableResult
    public func drainSpool(now: Date = Date()) -> (delivered: Int, dropped: Int) {
        let drained = EventSpool.drain(paths.spoolFile)
        guard !drained.lines.isEmpty || drained.droppedCount > 0 else { return (0, 0) }
        var delivered = 0
        var dropped = drained.droppedCount
        for line in drained.lines {
            // Only the last day of missed events is worth showing.
            guard let wire = try? EventSchemaValidator.decode(line, now: now, maxAge: 86_400), wire.origin != .ping else {
                dropped += 1
                continue
            }
            deliver?(wire, .late)
            delivered += 1
        }
        onSpoolDrained?(delivered, dropped)
        return (delivered, dropped)
    }
}
