import Foundation

/// What actually happened, normalized from a hook event or explicit report.
///
/// These kinds are intentionally *not* interchangeable: a successful tool call is
/// not a finished turn, and a finished turn says nothing about builds or tests.
public enum EventKind: String, Codable, Sendable, CaseIterable {
    case sessionStarted
    case promptSubmitted
    case toolStarting
    case toolSucceeded
    case toolFailed
    case toolBatchFinished
    case permissionRequested
    case permissionDenied
    /// Claude Code is waiting on the user (permission prompt, idle input, MCP dialog).
    case attentionNeeded
    /// Informational notification (e.g. auth success, background agent finished).
    case notification
    case subagentStarted
    case subagentStopped
    /// `Stop`: Claude finished responding to the turn.
    case turnCompleted
    /// `StopFailure`: the turn ended because of an API error.
    case turnFailed
    case sessionEnded
    /// An explicit build/test/milestone/commit result from `mactamagotchi-hook report`.
    case report
    /// Recognized wire envelope, unknown event name. Recorded for diagnostics only.
    case unknown
}

public enum EventOrigin: String, Codable, Sendable {
    case claudeHook
    case explicitReport
    case simulator
}

public enum EventDelivery: String, Codable, Sendable {
    /// Delivered while it happened.
    case live
    /// Spooled while the app was not running and delivered afterwards.
    case late
    /// Replayed from history at launch to rebuild session state.
    case restored
}

/// How much the event says on its own.
public enum EventConfidence: String, Codable, Sendable {
    /// Directly reported by Claude Code or by the user's explicit report.
    case reported
    /// Derived from reported fields (e.g. a Bash command recognized as a test run).
    case derived
}

public enum ToolCategory: String, Codable, Sendable, CaseIterable {
    case read, search, edit, shell, web, agent, plan, ask, skill, mcp, other

    public init(wire: String?) {
        self = wire.flatMap(ToolCategory.init(rawValue:)) ?? .other
    }
}

public enum AttentionKind: String, Codable, Sendable {
    case permission
    case input
    case mcpDialog
    case backgroundAgent
}

public enum CommandKind: String, Codable, Sendable {
    case build, test
}

public struct ExplicitReport: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case build, test, milestone, commit }
    public enum Status: String, Codable, Sendable { case passed, failed, reached }

    public var kind: Kind
    public var status: Status
    public var label: String?

    public var isSuccess: Bool { status != .failed }
}

public struct ProjectRef: Codable, Sendable, Hashable {
    public var displayName: String
    public var key: String
    /// Full path; held in memory for "Reveal in Finder". Stripped before the event
    /// is written to history unless the user opts in.
    public var path: String?

    public init(displayName: String, key: String, path: String? = nil) {
        self.displayName = displayName
        self.key = key
        self.path = path
    }
}

public struct CompanionEvent: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var kind: EventKind
    public var rawName: String
    public var timestamp: Date
    public var receivedAt: Date
    public var sessionID: String?
    public var project: ProjectRef?
    public var toolName: String?
    public var toolCategory: ToolCategory?
    public var toolUseID: String?
    public var attention: AttentionKind?
    public var report: ExplicitReport?
    public var commandKind: CommandKind?
    /// Whether the command's exit status reflects the build/test result.
    public var commandReliable: Bool
    public var exitCode: Int?
    public var interrupted: Bool
    public var inSubagent: Bool
    /// Small, sanitized extras such as `source`, `reason`, `notificationType`, `agentType`, `model`.
    public var metadata: [String: String]
    /// Claude Code's short notification text, if any.
    public var message: String?
    public var origin: EventOrigin
    public var delivery: EventDelivery
    public var schemaVersion: Int
    public var confidence: EventConfidence
    /// A short, honest description of what was observed.
    public var summary: String

    public var isSimulated: Bool { origin == .simulator }

    /// A build/test outcome this event genuinely carries, if any.
    public var buildTestOutcome: BuildTestOutcome? {
        if let report, report.kind == .build || report.kind == .test {
            return BuildTestOutcome(
                kind: report.kind == .build ? .build : .test,
                passed: report.status != .failed,
                source: .explicitReport,
                label: report.label,
                at: timestamp
            )
        }
        if let commandKind, commandReliable, kind == .toolSucceeded || kind == .toolFailed, !interrupted {
            return BuildTestOutcome(kind: commandKind, passed: kind == .toolSucceeded, source: .claudeCommand, label: nil, at: timestamp)
        }
        return nil
    }
}

public struct BuildTestOutcome: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// Sent by the user's script with `mactamagotchi-hook report`.
        case explicitReport
        /// A Bash command Claude ran, recognized as a build/test, with a trustworthy exit status.
        case claudeCommand
    }

    public var kind: CommandKind
    public var passed: Bool
    public var source: Source
    public var label: String?
    public var at: Date

    public var summary: String {
        let noun = kind == .test ? "Test" : "Build"
        switch source {
        case .explicitReport:
            let name = label.map { " (\($0))" } ?? ""
            return passed ? "\(noun) passed\(name) — reported by your script" : "\(noun) failed\(name) — reported by your script"
        case .claudeCommand:
            return passed
                ? "A \(noun.lowercased()) command Claude ran exited successfully"
                : "A \(noun.lowercased()) command Claude ran exited with an error"
        }
    }
}
