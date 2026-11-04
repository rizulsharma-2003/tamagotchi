import CryptoKit
import Foundation

/// Turns a raw Claude Code hook payload (the JSON Claude Code writes to the hook's
/// stdin) into a minimal `WireEvent`.
///
/// This is an allow-list: only the fields below are read, and free text such as
/// `prompt`, `tool_input`, `tool_response`, `error`, `transcript_path` and
/// `custom_instructions` is never copied. Claude's `last_assistant_message` and the
/// name of a changed file are copied only with `includeSummary` (the user shares
/// summaries with their iPhone).
public enum HookPayloadSanitizer {
    /// Payloads larger than this (e.g. a huge `Write`) are not parsed; the
    /// event is still reported using a bounded scan of the payload's head.
    public static let maxParsedBytes = 8 * 1024 * 1024
    static let headScanBytes = 64 * 1024

    public static func sanitize(
        raw: Data,
        argumentEvent: String?,
        environment: [String: String],
        includeSummary: Bool = false,
        now: Date = Date()
    ) -> WireEvent {
        let id = digest(raw)
        let object: [String: Any]?
        if raw.count <= maxParsedBytes,
           let parsed = try? JSONSerialization.jsonObject(with: raw, options: []) as? [String: Any] {
            object = parsed
        } else {
            object = nil
        }

        let fallbackEvent = WireText.identifier(argumentEvent, maxLength: 40)
        guard let payload = object else {
            // Unparseable or oversized: report only what a bounded scan can find.
            let head = String(decoding: raw.prefix(headScanBytes), as: UTF8.self)
            let eventName = scanString(key: "hook_event_name", in: head).flatMap { WireText.identifier($0, maxLength: 40) }
                ?? fallbackEvent ?? "Unknown"
            var event = WireEvent(id: id, ts: now.timeIntervalSince1970, origin: .hook, event: eventName)
            event.session = scanString(key: "session_id", in: head).flatMap { WireText.identifier($0, maxLength: 128) }
            event.tool = scanString(key: "tool_name", in: head).flatMap { WireText.identifier($0, maxLength: 96) }
            event.toolCategory = event.tool.map(ToolCategoryClassifier.category(forTool:))
            applyProject(to: &event, cwd: scanString(key: "cwd", in: head), environment: environment)
            event.host = hostApp(environment)
            event.helperVersion = HelperInfo.version
            return event
        }

        let eventName = WireText.identifier(payload["hook_event_name"] as? String, maxLength: 40)
            ?? fallbackEvent ?? "Unknown"
        var event = WireEvent(id: id, ts: now.timeIntervalSince1970, origin: .hook, event: eventName)
        event.helperVersion = HelperInfo.version
        event.session = WireText.identifier(payload["session_id"] as? String, maxLength: 128)
        event.permissionMode = WireText.identifier(payload["permission_mode"] as? String, maxLength: 32)
        applyProject(to: &event, cwd: payload["cwd"] as? String, environment: environment)
        event.host = hostApp(environment)

        if let agentID = WireText.identifier(payload["agent_id"] as? String, maxLength: 64) {
            event.agentId = agentID
        }
        if let agentType = WireText.clean(payload["agent_type"] as? String, maxLength: 40) {
            event.agentType = agentType
        }

        switch eventName {
        case "SessionStart":
            event.source = WireText.identifier(payload["source"] as? String, maxLength: 24)
            event.model = WireText.clean(payload["model"] as? String, maxLength: 48)
        case "SessionEnd":
            event.reason = WireText.identifier(payload["reason"] as? String, maxLength: 40)
        case "Stop":
            if includeSummary {
                event.summary = WireText.paragraphs(payload["last_assistant_message"] as? String, maxLength: maxSummaryLength)
            }
        case "StopFailure":
            event.reason = WireText.identifier(payload["error"] as? String, maxLength: 40)
        case "Notification":
            event.notificationType = WireText.identifier(payload["notification_type"] as? String, maxLength: 40)
            event.message = WireText.clean(payload["message"] as? String, maxLength: 160)
        case "SubagentStart", "SubagentStop":
            break
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied":
            applyTool(to: &event, payload: payload)
            if includeSummary, eventName == "PostToolUse" {
                event.file = changedFile(tool: event.tool, payload: payload)
            }
        case "PostToolBatch":
            if let calls = payload["tool_calls"] as? [[String: Any]] {
                event.batchCount = calls.count
                var names: [String] = []
                for call in calls {
                    guard let name = WireText.identifier(call["tool_name"] as? String, maxLength: 96) else { continue }
                    if !names.contains(name) { names.append(name) }
                    if names.count == 8 { break }
                }
                event.batchTools = names
            }
        default:
            break
        }

        // Subagent context: the common agent_id/agent_type fields are only present
        // when the hook fires inside a subagent (or a `--agent` session).
        if eventName != "SubagentStart", eventName != "SubagentStop", event.agentId != nil {
            event.inSubagent = true
        }
        return event
    }

    private static func applyTool(to event: inout WireEvent, payload: [String: Any]) {
        guard let tool = WireText.identifier(payload["tool_name"] as? String, maxLength: 96) else { return }
        event.tool = tool
        event.toolCategory = ToolCategoryClassifier.category(forTool: tool)
        event.toolUseId = WireText.identifier(payload["tool_use_id"] as? String, maxLength: 96)
        if let duration = payload["duration_ms"] as? NSNumber {
            event.durationMs = max(0, min(duration.intValue, 86_400_000))
        }
        if let interrupted = payload["is_interrupt"] as? Bool {
            event.isInterrupt = interrupted
        }
        if let error = payload["error"] as? String {
            event.exitCode = leadingExitCode(error)
        }
        if tool == "Bash" || tool == "PowerShell", let input = payload["tool_input"] as? [String: Any] {
            let background = (input["run_in_background"] as? Bool) == true
            if background { event.backgrounded = true }
            if let command = input["command"] as? String {
                let result = CommandClassifier.classify(command)
                if let kind = result.kind {
                    event.commandKind = kind
                    event.commandReliable = result.reliable && !background
                }
            }
        }
    }

    /// Room for a long closing message; the app condenses it.
    public static let maxSummaryLength = 4000

    /// The name of the file an editing tool changed: never its folder or contents.
    static func changedFile(tool: String?, payload: [String: Any]) -> String? {
        guard let tool, ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool),
              let input = payload["tool_input"] as? [String: Any],
              let path = (input["file_path"] ?? input["notebook_path"]) as? String, !path.isEmpty else { return nil }
        return WireText.clean((path as NSString).lastPathComponent, maxLength: 96)
    }

    private static func applyProject(to event: inout WireEvent, cwd: String?, environment: [String: String]) {
        // Claude Code sets CLAUDE_PROJECT_DIR for hooks; it is the project root even
        // after Claude changes directory.
        let path = environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? cwd
        guard let path, path.hasPrefix("/"), path.utf8.count < 4096 else { return }
        event.project = ProjectIdentity.displayName(forPath: path)
        event.projectKey = ProjectIdentity.key(forPath: path)
        event.projectPath = URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// macOS sets `__CFBundleIdentifier` for processes started from an app; a hook inherits it
    /// from the editor or terminal that runs the Claude session.
    static func hostApp(_ environment: [String: String]) -> String? {
        WireText.identifier(environment["__CFBundleIdentifier"], maxLength: 96)
    }

    /// Claude Code formats Bash failures with a leading "Exit code N" line.
    static func leadingExitCode(_ error: String) -> Int? {
        let head = error.prefix(32)
        guard head.hasPrefix("Exit code ") else { return nil }
        let digits = head.dropFirst("Exit code ".count).prefix(while: { $0.isNumber || $0 == "-" })
        return Int(digits)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Finds `"key": "value"` in a JSON fragment without parsing all of it.
    static func scanString(key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        while index < text.endIndex, text[index] == " " || text[index] == ":" || text[index] == "\n" || text[index] == "\t" {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)
        var value = ""
        while index < text.endIndex, text[index] != "\"", value.count < 512 {
            if text[index] == "\\" { return nil }
            value.append(text[index])
            index = text.index(after: index)
        }
        return value
    }
}
