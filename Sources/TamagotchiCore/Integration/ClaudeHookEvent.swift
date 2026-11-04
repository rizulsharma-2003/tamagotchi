import Foundation

/// The Claude Code hook events MacTamagotchi listens to.
public enum ClaudeHookEvent: String, CaseIterable, Codable, Sendable, Identifiable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case postToolBatch = "PostToolBatch"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case sessionEnd = "SessionEnd"

    public var id: String { rawValue }

    /// Long-established events, assumed available when the installed version
    /// cannot be inspected.
    public var isCore: Bool {
        switch self {
        case .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .notification, .stop, .subagentStop, .sessionEnd:
            return true
        default:
            return false
        }
    }

    /// Plain-language explanation shown in the connection setup.
    public var purpose: String {
        switch self {
        case .sessionStart: return "A session starts, resumes or is cleared"
        case .userPromptSubmit: return "You submit a prompt (the prompt text is not kept)"
        case .preToolUse: return "A tool is about to run (tool name only)"
        case .postToolUse: return "A tool finished successfully"
        case .postToolUseFailure: return "A tool reported an error (exit code only)"
        case .postToolBatch: return "A batch of parallel tool calls finished"
        case .permissionRequest: return "Claude asks permission to use a tool"
        case .notification: return "Claude Code needs your attention"
        case .subagentStart: return "A subagent starts"
        case .subagentStop: return "A subagent finishes"
        case .stop: return "Claude finishes responding to a turn"
        case .stopFailure: return "A turn ends with an API error"
        case .sessionEnd: return "A session ends"
        }
    }

    /// SessionEnd hooks share a short budget; we keep Claude Code's default
    /// rather than raising it with a `timeout`.
    public var hookTimeoutSeconds: Int? {
        self == .sessionEnd ? nil : 5
    }
}
