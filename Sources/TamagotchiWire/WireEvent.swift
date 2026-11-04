import Foundation

/// Where a wire event came from. The app treats these very differently:
/// only `hook` and `report` events can ever enter the real history.
public enum WireOrigin: String, Codable, Sendable {
    /// Forwarded by `mactamagotchi-hook claude-hook` from a Claude Code hook.
    case hook
    /// An explicit build/test/milestone result sent with `mactamagotchi-hook report`.
    case report
    /// Produced by the development event simulator. Never journaled.
    case simulator
    /// Connectivity check from `mactamagotchi-hook ping`. Never shown as activity.
    case ping
}

/// An explicit result reported by the user's own scripts.
public struct WireReport: Codable, Sendable, Equatable {
    public var kind: String
    public var status: String
    public var label: String?

    public init(kind: String, status: String, label: String? = nil) {
        self.kind = kind
        self.status = status
        self.label = label
    }
}

/// The sanitized envelope sent from the hook helper to the app over the local socket.
///
/// It deliberately has no fields for prompts, tool inputs, tool output, file
/// contents or transcript paths: the helper drops those before anything leaves the
/// hook process. Claude's closing message and the names of changed files are sent
/// only while the user shares summaries with their iPhone (`summary`, `file`).
public struct WireEvent: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var v: Int
    /// Deterministic digest of the raw hook payload, so a duplicated delivery of
    /// the same hook invocation produces the same id and can be ignored.
    public var id: String
    /// Unix time (seconds) at which the helper observed the event.
    public var ts: Double
    public var origin: WireOrigin
    /// The raw hook event name (e.g. "PreToolUse"), or "Report"/"Ping".
    public var event: String

    public var session: String?
    /// Last path component of the project directory, for display.
    public var project: String?
    /// Short one-way hash of the full project path, for telling projects apart.
    public var projectKey: String?
    /// Full project path. Kept in memory only, unless the user opts in to storing it.
    public var projectPath: String?

    public var tool: String?
    public var toolUseId: String?
    public var toolCategory: String?
    /// "test" / "build" when a Bash command is recognizably one; the command itself is never sent.
    public var commandKind: String?
    /// Whether the shell exit status can be trusted to reflect `commandKind`
    /// (false for pipelines, `|| true`, trailing `;` commands, background runs).
    public var commandReliable: Bool?
    public var backgrounded: Bool?
    public var exitCode: Int?
    public var isInterrupt: Bool?
    public var durationMs: Int?

    public var notificationType: String?
    /// Claude Code's own short notification text (e.g. "Claude needs your permission to use Bash").
    public var message: String?

    public var agentType: String?
    public var agentId: String?
    /// True when the hook fired inside a subagent.
    public var inSubagent: Bool?

    /// SessionStart `source` (startup/resume/clear/compact/fork).
    public var source: String?
    /// SessionEnd `reason`, or StopFailure error type (rate_limit, overloaded, ...).
    public var reason: String?
    public var model: String?
    public var permissionMode: String?
    /// Bundle identifier of the app the Claude session runs in (e.g. "com.microsoft.VSCode"), so
    /// Mochi can bring that window forward when asked. An identifier only, never anything typed.
    public var host: String?

    public var batchCount: Int?
    public var batchTools: [String]?

    public var report: WireReport?
    public var helperVersion: String?

    /// Claude's last message of a turn (Stop), only while the user shares summaries with their
    /// iPhone. The app summarizes it in memory; it is never journaled or spooled.
    public var summary: String?
    /// The name (never the folder or contents) of a file an editing tool changed, only while
    /// summaries are shared.
    public var file: String?

    public init(
        id: String,
        ts: Double,
        origin: WireOrigin,
        event: String,
        session: String? = nil
    ) {
        self.v = WireEvent.currentSchemaVersion
        self.id = id
        self.ts = ts
        self.origin = origin
        self.event = event
        self.session = session
    }

    /// The event without the summary fields, for anything that is kept.
    public var withoutSummary: WireEvent {
        var copy = self
        copy.summary = nil
        copy.file = nil
        return copy
    }

    public func encodedLine() throws -> Data {
        var data = try WireCoding.encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> WireEvent {
        try WireCoding.decoder.decode(WireEvent.self, from: data)
    }
}

enum WireCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()
}

public enum HelperInfo {
    public static let version = "1.1.0"
    public static let executableName = "mactamagotchi-hook"
    /// Subcommand used in installed hook commands. Together with the executable
    /// name it marks a hook entry as ours, so uninstall never touches anything else.
    public static let hookSubcommand = "claude-hook"
}
