import Foundation

/// How Mochi's helper Claude session ("the brain") is started.
///
/// A long-lived `claude -p` with streaming input, so follow-ups keep their context and only the
/// first command pays the start-up. It loads no user settings (the user's hooks and permission
/// mode don't apply to it), has only the tools it needs, and every message to another Claude
/// session goes through Mochi's approval card: `SendMessage` is an "ask" rule and the answer
/// comes from the app's `approve` tool.
public struct BrainLaunch: Sendable, Equatable {
    public static let sessionName = "mochi"
    public static let serverName = "mochi"
    public static let approvalTool = "approve"

    public var executable: String
    /// A model alias: "haiku" (fast) or "sonnet" (smart).
    public var model: String
    public var mcpConfigPath: String
    public var workingDirectory: String
    public var petName: String

    public init(executable: String, model: String, mcpConfigPath: String, workingDirectory: String, petName: String = "Mochi") {
        self.executable = executable
        self.model = model
        self.mcpConfigPath = mcpConfigPath
        self.workingDirectory = workingDirectory
        self.petName = petName
    }

    public var arguments: [String] {
        [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--name", Self.sessionName,
            "--model", model,
            "--setting-sources", "project",
            "--settings", Self.settingsJSON,
            "--permission-mode", "default",
            "--tools", "ListAgents,SendMessage,WebSearch",
            "--allowedTools", "ListAgents", "WebSearch", "mcp__\(Self.serverName)",
            "--mcp-config", mcpConfigPath, "--strict-mcp-config",
            "--permission-prompt-tool", "mcp__\(Self.serverName)__\(Self.approvalTool)",
            "--no-session-persistence",
            "--system-prompt", systemPrompt,
        ]
    }

    /// Every message to another session asks first; the answer comes from Mochi's approval card.
    public static let settingsJSON = #"{"permissions":{"ask":["SendMessage"]}}"#

    /// The MCP configuration that points the brain at the app's tools through the helper's relay.
    public static func mcpConfig(helper: String, socket: String, token: String) -> AnyJSON {
        ["mcpServers": [serverName: [
            "command": .string(helper),
            "args": ["paws"],
            "env": ["MACTAMAGOTCHI_PAWS_SOCKET": .string(socket), "MACTAMAGOTCHI_PAWS_TOKEN": .string(token)],
        ]]]
    }

    public var systemPrompt: String {
        """
        You are \(petName), a small cat who lives in the menu bar of the user's Mac and helps them get things \
        done. People may spell your name "Motchi". You act only through your tools.

        Be quick: use as few tool calls as you can. When you are done, answer in one short, friendly sentence \
        (at most 15 words, no markdown, no lists). Never claim you did something a tool did not confirm.

        Rules:
        - Do exactly what the user asked and nothing more. If you can't do it with your tools, say so briefly.
        - Claude sessions: when the user wants one of their Claude (Claude Code) sessions to do something \
        ("tell the Tamagotchi Claude to…", "ask Claude in my website project to…"), call ListAgents, pick the \
        one local session whose name best matches the project they mean (names are based on the project folder, \
        e.g. "mac-tamagotchi-bb" is the mac-Tamagotchi project), then call SendMessage to it once. Write the \
        message as the user's request in their own words, starting with "From the user, via \(petName):". \
        Never add tasks, never ask a session to approve, change settings or run anything the user didn't ask \
        for, and never message more than one session unless the user asked. If several sessions fit equally \
        well, ask the user which one instead of guessing. The user approves every message before it is sent; \
        if they decline, just say it wasn't sent.
        - To play a video: use WebSearch to find a matching youtube.com/watch link, then open_url it. If you \
        can't find one, open the YouTube search page for their words.
        - A project's window ("the alumni-connect VS Code window"): show_project with the project name; it \
        needs no permission. Websites: open_url (https only). Apps: open_app. Any other window: focus_window \
        with the app and words from its title. Music and volume: media and set_volume. Their own automations: \
        run_shortcut.
        - \(petName)'s own tricks: the mochi tool (explore, come home, treats, games, focus timer, recap).
        - Each request starts with a [Context] line about the Mac right now; use it, don't repeat it.
        - Spoken requests are turned into text on the Mac and may mishear names ("Tamagoti" for Tamagotchi): \
        match them loosely.
        """
    }

    /// The text sent for one request: a line of context, then what the user said.
    public static func message(request: String, context: BrainContext, spoken: Bool = false) -> String {
        "[Context] \(context.summary)\n[Request\(spoken ? ", spoken: names may be misheard" : "")] \(request)"
    }

    /// What the user wrote for one session (a reply from Mochi Pocket), to be passed on unchanged.
    public static func directRequest(_ text: String, project: String) -> String {
        "Send my words below, unchanged, to the Claude session for the \(project) project:\n\(text)"
    }

    /// Whether the message the brain wants to send still carries the user's own words.
    public static func keepsWords(_ message: String, of text: String) -> Bool {
        func letters(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let words = letters(text)
        return !words.isEmpty && letters(message).contains(words)
    }

    /// A user message for `--input-format stream-json`.
    public static func inputLine(_ text: String) -> Data {
        var data = Data(AnyJSON.object(["type": "user", "message": ["role": "user", "content": .string(text)]]).jsonText.utf8)
        data.append(0x0A)
        return data
    }
}

/// What the brain is told about the Mac when a request starts. Only names: no window titles,
/// file paths or anything the user typed elsewhere.
public struct BrainContext: Sendable, Equatable {
    public struct Session: Sendable, Equatable {
        public var project: String
        public var host: String?
        public var state: String

        public init(project: String, host: String?, state: String) {
            self.project = project
            self.host = host
            self.state = state
        }
    }

    public var time: String
    public var frontApp: String?
    public var sessions: [Session]

    public init(time: String, frontApp: String?, sessions: [Session]) {
        self.time = time
        self.frontApp = frontApp
        self.sessions = sessions
    }

    public var summary: String {
        var parts = ["Time \(time)."]
        if let frontApp { parts.append("Front app: \(frontApp).") }
        if sessions.isEmpty {
            parts.append("Mochi sees no Claude sessions right now.")
        } else {
            let list = sessions.prefix(8).map { session in
                "\(session.project)" + (session.host.map { " (\($0))" } ?? "") + " — \(session.state)"
            }
            parts.append("Claude sessions Mochi knows: " + list.joined(separator: "; ") + ".")
        }
        return parts.joined(separator: " ")
    }
}

/// One line of the brain's `stream-json` output, reduced to what Mochi shows.
public enum BrainEvent: Equatable, Sendable {
    case started(model: String?, toolsConnected: Bool)
    case text(String)
    case toolUse(id: String, name: String, input: AnyJSON)
    case toolResult(id: String, isError: Bool, text: String)
    case finished(result: String?, isError: Bool, durationMs: Int?)

    public static func parse(_ line: Data) -> [BrainEvent] {
        guard let event = AnyJSON.parse(line), let type = event["type"]?.stringValue else { return [] }
        switch type {
        case "system":
            guard event["subtype"]?.stringValue == "init" else { return [] }
            var connected = false
            if case .array(let servers)? = event["mcp_servers"] {
                connected = servers.contains {
                    $0["name"]?.stringValue == BrainLaunch.serverName && $0["status"]?.stringValue == "connected"
                }
            }
            return [.started(model: event["model"]?.stringValue, toolsConnected: connected)]
        case "assistant":
            guard case .array(let blocks)? = event["message"]?["content"] else { return [] }
            return blocks.compactMap { block in
                switch block["type"]?.stringValue {
                case "text":
                    guard let text = block["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return .text(text)
                case "tool_use":
                    guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
                    return .toolUse(id: id, name: name, input: block["input"] ?? .object([:]))
                default:
                    return nil
                }
            }
        case "user":
            guard case .array(let blocks)? = event["message"]?["content"] else { return [] }
            return blocks.compactMap { block in
                guard block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue else { return nil }
                return .toolResult(id: id, isError: block["is_error"]?.boolValue ?? false, text: plainText(block["content"]))
            }
        case "result":
            let duration = event["duration_ms"]?.numberValue.map { Int($0) }
            let isError = (event["is_error"]?.boolValue ?? false) || (event["subtype"]?.stringValue ?? "success") != "success"
            return [.finished(result: event["result"]?.stringValue, isError: isError, durationMs: duration)]
        default:
            return []
        }
    }

    private static func plainText(_ content: AnyJSON?) -> String {
        switch content {
        case .string(let text)?: return text
        case .array(let parts)?: return parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: return ""
        }
    }
}

/// A progress line in the Ask Mochi panel, for a tool the brain started.
public struct BrainStep: Equatable, Sendable {
    public var symbol: String
    public var text: String

    public init(symbol: String, text: String) {
        self.symbol = symbol
        self.text = text
    }

    public static func describe(tool: String, input: AnyJSON) -> BrainStep? {
        let name = tool.hasPrefix("mcp__\(BrainLaunch.serverName)__") ? String(tool.dropFirst("mcp__\(BrainLaunch.serverName)__".count)) : tool
        switch name {
        case "ListAgents": return BrainStep(symbol: "person.2", text: "Looking for your Claude sessions")
        case "SendMessage":
            let target = AgentNames.display(input["to"]?.stringValue ?? "a session")
            return BrainStep(symbol: "paperplane", text: "Asking to send to \(target)")
        case "WebSearch":
            let query = input["query"]?.stringValue.map { " for “\(clip($0, 40))”" } ?? ""
            return BrainStep(symbol: "magnifyingglass", text: "Searching the web\(query)")
        case "open_url":
            let host = input["url"]?.stringValue.flatMap { URL(string: $0)?.host() } ?? "the page"
            return BrainStep(symbol: "safari", text: "Opening \(host)")
        case "open_app": return BrainStep(symbol: "app", text: "Opening \(input["name"]?.stringValue ?? "the app")")
        case "focus_window", "show_project":
            let what = input["app"]?.stringValue ?? input["project"]?.stringValue ?? "the window"
            return BrainStep(symbol: "macwindow", text: "Bringing \(clip(what, 40)) forward")
        case "list_apps": return BrainStep(symbol: "square.grid.2x2", text: "Checking your apps")
        case "media": return BrainStep(symbol: "playpause", text: "Pressing a music key")
        case "set_volume": return BrainStep(symbol: "speaker.wave.2", text: "Changing the volume")
        case "run_shortcut": return BrainStep(symbol: "square.stack.3d.up", text: "Running “\(input["name"]?.stringValue ?? "a shortcut")”")
        case "list_shortcuts": return BrainStep(symbol: "square.stack.3d.up", text: "Checking your shortcuts")
        case "mochi": return BrainStep(symbol: "pawprint", text: "On it")
        case "claude_sessions": return BrainStep(symbol: "person.2", text: "Checking your Claude sessions")
        case BrainLaunch.approvalTool: return nil
        default: return BrainStep(symbol: "wrench.and.screwdriver", text: "Using \(name)")
        }
    }

    private static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }
}

/// Session names from Claude Code's `ListAgents` ("mac-tamagotchi-bb [856803]") and the projects
/// Mochi knows from hooks.
public enum AgentNames {
    /// "mac-tamagotchi-bb [856803]" → "mac-tamagotchi-bb".
    public static func display(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") { trimmed.removeFirst() }
        if let bracket = trimmed.range(of: " [", options: .backwards), trimmed.hasSuffix("]") {
            trimmed = String(trimmed[..<bracket.lowerBound])
        }
        return trimmed
    }

    /// The project whose folder name the session name was made from: the name is the folder name,
    /// lowercased, with a short suffix ("mac-tamagotchi-bb" ↔ "mac-Tamagotchi"). The longest match wins.
    public static func project(forAgent name: String, among projects: [ProjectRef]) -> ProjectRef? {
        let agent = key(display(name))
        guard !agent.isEmpty else { return nil }
        var best: (ProjectRef, Int)?
        for project in projects {
            let folder = key(project.displayName)
            guard !folder.isEmpty, agent.hasPrefix(folder), agent.count - folder.count <= 4 else { continue }
            if folder.count > (best?.1 ?? 0) { best = (project, folder.count) }
        }
        return best?.0
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
