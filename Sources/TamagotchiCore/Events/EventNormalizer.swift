import Foundation
import TamagotchiWire

/// Converts validated wire envelopes into `CompanionEvent`s with honest summaries.
public enum EventNormalizer {
    public static func normalize(_ wire: WireEvent, receivedAt: Date = Date(), delivery: EventDelivery = .live) -> CompanionEvent {
        let origin: EventOrigin
        switch wire.origin {
        case .hook, .ping: origin = .claudeHook
        case .report: origin = .explicitReport
        case .simulator: origin = .simulator
        }

        let project: ProjectRef? = {
            guard let key = wire.projectKey ?? wire.projectPath.map(ProjectIdentity.key(forPath:)) else { return nil }
            let name = wire.project ?? wire.projectPath.map(ProjectIdentity.displayName(forPath:)) ?? "Project"
            return ProjectRef(displayName: name, key: key, path: wire.projectPath)
        }()

        var metadata: [String: String] = [:]
        metadata["source"] = wire.source
        metadata["reason"] = wire.reason
        metadata["notificationType"] = wire.notificationType
        metadata["agentType"] = wire.agentType
        metadata["agentId"] = wire.agentId
        metadata["model"] = wire.model
        metadata["permissionMode"] = wire.permissionMode
        metadata["host"] = wire.host
        if let count = wire.batchCount { metadata["batchCount"] = String(count) }
        if let tools = wire.batchTools, !tools.isEmpty { metadata["batchTools"] = tools.joined(separator: ",") }
        if let duration = wire.durationMs { metadata["durationMs"] = String(duration) }
        if wire.backgrounded == true { metadata["background"] = "true" }

        let kind = kind(for: wire)
        let category = wire.tool.map { _ in ToolCategory(wire: wire.toolCategory) }
        let report: ExplicitReport? = wire.report.flatMap { report in
            guard let kind = ExplicitReport.Kind(rawValue: report.kind),
                  let status = ExplicitReport.Status(rawValue: report.status) else { return nil }
            return ExplicitReport(kind: kind, status: status, label: report.label)
        }
        let commandKind = wire.commandKind.flatMap(CommandKind.init(rawValue:))

        var event = CompanionEvent(
            id: wire.id,
            kind: kind,
            rawName: wire.event,
            timestamp: Date(timeIntervalSince1970: wire.ts),
            receivedAt: receivedAt,
            sessionID: wire.session,
            project: project,
            toolName: wire.tool,
            toolCategory: category,
            toolUseID: wire.toolUseId,
            attention: attentionKind(for: wire),
            report: report,
            commandKind: commandKind,
            commandReliable: wire.commandReliable == true && wire.backgrounded != true,
            exitCode: wire.exitCode,
            interrupted: wire.isInterrupt == true,
            inSubagent: wire.inSubagent == true,
            metadata: metadata,
            message: wire.message,
            origin: origin,
            delivery: delivery,
            schemaVersion: wire.v,
            confidence: commandKind != nil ? .derived : .reported,
            summary: ""
        )
        event.summary = summary(for: event)
        return event
    }

    static func kind(for wire: WireEvent) -> EventKind {
        if wire.origin == .report || (wire.event == "Report" && wire.report != nil) { return .report }
        switch wire.event {
        case "SessionStart": return .sessionStarted
        case "UserPromptSubmit": return .promptSubmitted
        case "PreToolUse": return .toolStarting
        case "PostToolUse": return .toolSucceeded
        case "PostToolUseFailure": return .toolFailed
        case "PostToolBatch": return .toolBatchFinished
        case "PermissionRequest": return .permissionRequested
        case "PermissionDenied": return .permissionDenied
        case "Notification": return attentionKind(for: wire) != nil ? .attentionNeeded : .notification
        case "SubagentStart": return .subagentStarted
        case "SubagentStop": return .subagentStopped
        case "Stop": return .turnCompleted
        case "StopFailure": return .turnFailed
        case "SessionEnd": return .sessionEnded
        default: return .unknown
        }
    }

    static func attentionKind(for wire: WireEvent) -> AttentionKind? {
        switch wire.event {
        case "PermissionRequest":
            return .permission
        case "Notification":
            switch wire.notificationType {
            case "permission_prompt": return .permission
            case "idle_prompt": return .input
            case "elicitation_dialog", "elicitation_url_dialog": return .mcpDialog
            case "agent_needs_input": return .backgroundAgent
            default: return nil
            }
        default:
            return nil
        }
    }

    static func summary(for event: CompanionEvent) -> String {
        let tool = event.toolName.map(friendlyToolName) ?? "a tool"
        switch event.kind {
        case .sessionStarted:
            switch event.metadata["source"] {
            case "resume": return "Session resumed"
            case "clear": return "Session cleared and restarted"
            case "compact": return "Context compacted; session continues"
            case "fork": return "Session forked"
            default: return "Claude Code session started"
            }
        case .promptSubmitted:
            return "A prompt was submitted"
        case .toolStarting:
            if event.metadata["background"] == "true" { return "Starting \(tool) in the background" }
            return "About to use \(tool)"
        case .toolSucceeded:
            if event.metadata["background"] == "true" { return "\(tool) started a background task" }
            if let outcome = event.buildTestOutcome { return outcome.summary }
            return "\(tool) finished"
        case .toolFailed:
            if event.interrupted { return "\(tool) was interrupted" }
            if let outcome = event.buildTestOutcome { return outcome.summary + (event.exitCode.map { " (exit code \($0))" } ?? "") }
            if let code = event.exitCode { return "\(tool) reported an error (exit code \(code))" }
            return "\(tool) reported an error"
        case .toolBatchFinished:
            let count = event.metadata["batchCount"].flatMap(Int.init) ?? 0
            return count == 1 ? "1 tool call finished" : "\(count) tool calls finished"
        case .permissionRequested:
            return "Claude is asking permission to use \(tool)"
        case .permissionDenied:
            return "Auto mode declined a \(tool) call"
        case .attentionNeeded:
            switch event.attention {
            case .permission: return event.message ?? "Claude needs your permission"
            case .input: return "Claude is waiting for your input"
            case .mcpDialog: return "An MCP server is asking for input"
            case .backgroundAgent: return "A background agent needs input"
            case nil: return event.message ?? "Claude needs your attention"
            }
        case .notification:
            switch event.metadata["notificationType"] {
            case "auth_success": return "Authentication succeeded"
            case "agent_completed": return "A background agent finished"
            default: return event.message ?? "Notification from Claude Code"
            }
        case .subagentStarted:
            if let type = event.metadata["agentType"], !type.isEmpty { return "Subagent started (\(type))" }
            return "Subagent started"
        case .subagentStopped:
            if let type = event.metadata["agentType"], !type.isEmpty { return "Subagent finished (\(type))" }
            return "Subagent finished"
        case .turnCompleted:
            return "Claude finished responding"
        case .turnFailed:
            if let reason = event.metadata["reason"] { return "Turn ended with an API error (\(reason.replacingOccurrences(of: "_", with: " ")))" }
            return "Turn ended with an API error"
        case .sessionEnded:
            switch event.metadata["reason"] {
            case "clear": return "Session cleared"
            case "resume": return "Switched to another session"
            case "logout": return "Logged out; session ended"
            case "prompt_input_exit": return "Session exited"
            default: return "Session ended"
            }
        case .report:
            guard let report = event.report else { return "Report received" }
            let label = report.label.map { " — \($0)" } ?? ""
            switch (report.kind, report.status) {
            case (.build, .failed): return "Build failed\(label)"
            case (.build, _): return "Build passed\(label)"
            case (.test, .failed): return "Tests failed\(label)"
            case (.test, _): return "Tests passed\(label)"
            case (.milestone, _): return "Milestone reached\(label)"
            case (.commit, _): return "Commit recorded\(label)"
            }
        case .unknown:
            return "Unrecognized event “\(event.rawName)”"
        }
    }

    public static func friendlyToolName(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.components(separatedBy: "__").filter { !$0.isEmpty }
            if parts.count >= 3 { return "\(parts[2...].joined(separator: "_")) (MCP)" }
            return "an MCP tool"
        }
        return name
    }
}
