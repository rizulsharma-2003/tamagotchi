import Foundation
import TamagotchiWire

/// Development-only event simulator.
///
/// Every event it produces has `origin = .simulator`, a `sim-` session id and a
/// "(Demo)" project name. The journal refuses such events, they never count
/// towards achievements, never reach Notification Center, and the UI labels them.
@MainActor
public final class EventSimulator {
    public enum Scenario: String, CaseIterable, Identifiable, Sendable {
        case fullTurn, toolFailures, permission, twoSessions, longTurn, explicitTests, subagents, apiError, sessionEnd

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .fullTurn: return "Full turn"
            case .toolFailures: return "Repeated tool errors"
            case .permission: return "Permission request"
            case .twoSessions: return "Two sessions"
            case .longTurn: return "Long turn (fast-forwarded)"
            case .explicitTests: return "Explicit test report"
            case .subagents: return "Subagents"
            case .apiError: return "API error"
            case .sessionEnd: return "Session ends"
            }
        }

        public var explanation: String {
            switch self {
            case .fullTurn: return "Session start, prompt, several tools (one succeeds while the turn continues), then Stop."
            case .toolFailures: return "Three tool errors in a row trigger detective mode; the turn then completes."
            case .permission: return "Claude asks permission for Bash, waits, then continues after you approve."
            case .twoSessions: return "Two projects at once: one waits for permission while the other completes."
            case .longTurn: return "A turn with timestamps 12 minutes apart, so completion plays the victory dance."
            case .explicitTests: return "A passing test report from a script, then a completed turn with a trophy."
            case .subagents: return "Claude delegates to two subagents that finish in turn."
            case .apiError: return "A turn ends with a rate-limit API error (StopFailure)."
            case .sessionEnd: return "The session ends; the companion packs up."
            }
        }
    }

    public struct Step: Sendable {
        public var delay: TimeInterval
        public var wire: WireEvent
        /// Keep the scripted timestamp instead of stamping the event when it is sent.
        public var fixedTimestamp = false
    }

    private weak var world: CompanionWorld?
    private var task: Task<Void, Never>?
    private var counter = 0
    public private(set) var running: Scenario?

    public init(world: CompanionWorld) {
        self.world = world
    }

    public func run(_ scenario: Scenario) {
        stop()
        let steps = Self.steps(for: scenario, now: Date(), counter: &counter)
        running = scenario
        world?.setSimulatorRunning(true)
        task = Task { [weak self] in
            for step in steps {
                try? await Task.sleep(for: .seconds(step.delay))
                guard !Task.isCancelled else { return }
                var wire = step.wire
                if !step.fixedTimestamp { wire.ts = Date().timeIntervalSince1970 }
                self?.world?.ingest(wire)
            }
            self?.running = nil
            self?.world?.setSimulatorRunning(false)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        running = nil
        world?.setSimulatorRunning(false)
    }

    /// Sends a single simulated hook event.
    public func send(_ eventName: String, tool: String? = nil, session: String = "sim-demo", project: String = "Demo Project",
                     notificationType: String? = nil, reason: String? = nil) {
        counter += 1
        var wire = Self.make(eventName, session: session, project: project, at: Date(), counter: counter)
        wire.tool = tool
        wire.toolCategory = tool.map(ToolCategoryClassifier.category(forTool:))
        wire.toolUseId = tool.map { _ in "sim-tool-\(counter)" }
        wire.notificationType = notificationType
        wire.reason = reason
        if eventName == "Notification", notificationType == "permission_prompt" {
            wire.message = "Claude needs your permission to use \(tool ?? "Bash")"
        }
        world?.ingest(wire)
    }

    static func make(_ event: String, session: String, project: String, at date: Date, counter: Int) -> WireEvent {
        var wire = WireEvent(id: "sim-\(counter)-\(UUID().uuidString.prefix(8).lowercased())", ts: date.timeIntervalSince1970,
                             origin: .simulator, event: event, session: session)
        wire.project = "\(project) (Demo)"
        wire.projectKey = "sim-\(ProjectIdentity.key(forPath: "/simulated/\(project)").prefix(8))"
        wire.helperVersion = "simulator"
        return wire
    }

    static func steps(for scenario: Scenario, now: Date, counter: inout Int) -> [Step] {
        var steps: [Step] = []
        var clock = now
        func add(_ delay: TimeInterval, _ event: String, session: String = "sim-alpha", project: String = "InsideEdge",
                 tool: String? = nil, configure: (inout WireEvent) -> Void = { _ in }) {
            counter += 1
            clock = clock.addingTimeInterval(delay)
            var wire = make(event, session: session, project: project, at: clock, counter: counter)
            if let tool {
                wire.tool = tool
                wire.toolCategory = ToolCategoryClassifier.category(forTool: tool)
                wire.toolUseId = "sim-tool-\(counter)"
            }
            configure(&wire)
            steps.append(Step(delay: delay, wire: wire))
        }
        func toolCall(_ tool: String, gap: TimeInterval = 1.4, run: TimeInterval = 2.4, fail: Bool = false, session: String = "sim-alpha",
                      project: String = "InsideEdge", configure: @escaping (inout WireEvent) -> Void = { _ in }) {
            add(gap, "PreToolUse", session: session, project: project, tool: tool, configure: configure)
            let id = steps.last!.wire.toolUseId
            add(run, fail ? "PostToolUseFailure" : "PostToolUse", session: session, project: project, tool: tool) { wire in
                wire.toolUseId = id
                if fail { wire.exitCode = 1 }
                configure(&wire)
            }
        }

        switch scenario {
        case .fullTurn:
            add(0.2, "SessionStart") { $0.source = "startup" }
            add(4.5, "UserPromptSubmit")
            toolCall("Read", gap: 2.4)
            toolCall("Grep")
            toolCall("Edit", run: 3.0)
            toolCall("Bash", run: 3.2)
            add(2.6, "Stop")

        case .toolFailures:
            add(0.2, "SessionStart") { $0.source = "resume" }
            add(3.5, "UserPromptSubmit")
            toolCall("Bash", gap: 2.0, fail: true)
            toolCall("Bash", fail: true)
            toolCall("Bash", fail: true)
            toolCall("Read", gap: 3.5)
            toolCall("Edit")
            add(2.0, "Stop")

        case .permission:
            add(0.2, "SessionStart")
            add(3.5, "UserPromptSubmit")
            add(1.8, "PreToolUse", tool: "Bash")
            let id = steps.last!.wire.toolUseId
            add(0.3, "PermissionRequest", tool: "Bash")
            add(0.2, "Notification") {
                $0.notificationType = "permission_prompt"
                $0.message = "Claude needs your permission to use Bash"
            }
            add(7.0, "PostToolUse", tool: "Bash") { $0.toolUseId = id }
            add(2.4, "Stop")

        case .twoSessions:
            add(0.2, "SessionStart", session: "sim-alpha", project: "InsideEdge")
            add(2.5, "SessionStart", session: "sim-beta", project: "Deskdrop")
            add(2.0, "UserPromptSubmit", session: "sim-alpha", project: "InsideEdge")
            add(1.2, "UserPromptSubmit", session: "sim-beta", project: "Deskdrop")
            toolCall("Edit", gap: 1.0, session: "sim-alpha", project: "InsideEdge")
            add(1.0, "PreToolUse", session: "sim-beta", project: "Deskdrop", tool: "Bash")
            add(0.3, "PermissionRequest", session: "sim-beta", project: "Deskdrop", tool: "Bash")
            toolCall("Read", gap: 2.0, session: "sim-alpha", project: "InsideEdge")
            add(2.5, "Stop", session: "sim-alpha", project: "InsideEdge")

        case .longTurn:
            // Timestamps are 12 minutes apart, so the turn is long by its own clock.
            let start = now.addingTimeInterval(-12 * 60)
            clock = start
            add(0, "SessionStart") { $0.source = "startup" }
            add(1, "UserPromptSubmit")
            steps = steps.map { var s = $0; s.delay = 0.2; s.fixedTimestamp = true; return s }
            clock = now
            toolCall("Edit", gap: 1.5)
            add(2.0, "Stop")

        case .explicitTests:
            add(0.2, "SessionStart")
            add(3.0, "UserPromptSubmit")
            toolCall("Edit", gap: 1.6)
            add(2.0, "Report") { wire in
                wire.origin = .simulator
                wire.report = WireReport(kind: "test", status: "passed", label: "swift test")
            }
            add(5.0, "Stop")

        case .subagents:
            add(0.2, "SessionStart")
            add(3.0, "UserPromptSubmit")
            add(1.5, "PreToolUse", tool: "Agent")
            add(0.4, "SubagentStart") { $0.agentId = "sim-agent-1"; $0.agentType = "Explore" }
            add(0.6, "SubagentStart") { $0.agentId = "sim-agent-2"; $0.agentType = "Plan" }
            add(4.0, "SubagentStop") { $0.agentId = "sim-agent-1"; $0.agentType = "Explore" }
            add(2.5, "SubagentStop") { $0.agentId = "sim-agent-2"; $0.agentType = "Plan" }
            add(1.0, "PostToolUse", tool: "Agent")
            add(2.0, "Stop")

        case .apiError:
            add(0.2, "SessionStart")
            add(3.0, "UserPromptSubmit")
            toolCall("Read", gap: 1.5)
            add(2.0, "StopFailure") { $0.reason = "rate_limit" }

        case .sessionEnd:
            add(0.2, "SessionEnd") { $0.reason = "prompt_input_exit" }
        }
        return steps
    }
}
