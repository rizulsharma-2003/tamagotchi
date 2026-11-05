import Foundation
import TamagotchiWire

/// What Claude did in one turn of a session: its closing message and the files it changed. Built
/// only while the user shares summaries with their iPhone, and held in memory only.
public struct TurnReport: Sendable, Equatable {
    public var sessionID: String
    public var project: String
    public var message: String?
    public var files: [String]
    public var at: Date

    public init(sessionID: String, project: String, message: String?, files: [String], at: Date) {
        self.sessionID = sessionID
        self.project = project
        self.message = message
        self.files = files
        self.at = at
    }
}

/// Follows hook events to collect each turn's changed files, and hands over the turn when Claude stops.
public struct SessionReports: Sendable {
    public static let maxFiles = 30
    private var files: [String: [String]] = [:]

    public init() {}

    public mutating func record(_ wire: WireEvent, now: Date = Date()) -> TurnReport? {
        guard wire.origin == .hook, let session = wire.session else { return nil }
        switch wire.event {
        case "UserPromptSubmit":
            files[session] = []
        case "PostToolUse":
            guard let file = wire.file else { break }
            var list = files[session] ?? []
            if !list.contains(file), list.count < Self.maxFiles { list.append(file) }
            files[session] = list
        case "Stop":
            let changed = files.removeValue(forKey: session) ?? []
            return TurnReport(sessionID: session, project: wire.project ?? "Claude", message: wire.summary, files: changed, at: now)
        case "SessionEnd":
            files[session] = nil
        default:
            break
        }
        return nil
    }
}

/// A finished turn as the iPhone shows it.
public struct TurnSummary: Codable, Sendable, Equatable {
    /// What Claude did or found this turn.
    public var done: String
    /// What the session is working on overall.
    public var session: String?
    /// Short requests the user might send next.
    public var next: [String]

    public init(done: String, session: String? = nil, next: [String] = []) {
        self.done = done
        self.session = session
        self.next = next
    }
}

/// Turns Claude's closing message into a short note with a one-off `claude -p` (Haiku, no tools,
/// none of the user's settings, nothing saved), or without it when Claude Code isn't there.
public enum TurnSummarizer {
    public static let model = "haiku"

    public static var arguments: [String] {
        ["-p", "--model", model, "--output-format", "json", "--setting-sources", "project", "--tools", "",
         "--strict-mcp-config", "--no-session-persistence", "--system-prompt", systemPrompt]
    }

    public static let systemPrompt = """
    You write short notes for a phone about what Claude, a coding assistant, just did in one of the user's \
    projects, so the user can decide what to ask next. Reply with JSON only, no code fence:
    {"done": "...", "session": "...", "next": ["..."]}
    - done: at most 160 characters. What Claude did or found this turn, the most important part first. \
    Plain words: no markdown, no file paths.
    - session: at most 110 characters. What this session is working on overall, using the earlier notes.
    - next: up to 2 requests of at most 40 characters the user could send next, in the user's voice \
    ("Run the tests", "Yes, do the migration too"). If Claude asked a question, offer the likely answers.
    Never invent work the message doesn't mention.
    """

    /// What the summarizer reads: the project, the changed files, earlier notes and Claude's message.
    public static func prompt(for report: TurnReport, earlier: [String]) -> String {
        var parts = ["Project: \(report.project)"]
        if !report.files.isEmpty { parts.append("Files changed: " + report.files.prefix(20).joined(separator: ", ")) }
        if !earlier.isEmpty {
            parts.append("Earlier notes on this session:\n" + earlier.suffix(3).map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("Claude's last message:\n" + (report.message ?? "(none)"))
        return parts.joined(separator: "\n\n")
    }

    /// The text of `claude -p --output-format json`'s result.
    public static func result(fromOutput data: Data) -> String? {
        guard let output = AnyJSON.parse(data), output["is_error"]?.boolValue != true else { return nil }
        return output["result"]?.stringValue
    }

    /// The note in the model's reply, tolerating a code fence or words around the JSON.
    public static func parse(_ text: String) -> TurnSummary? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = AnyJSON.parse(Data(text[start...end].utf8)),
              let done = json["done"]?.stringValue.flatMap({ WireText.clean($0, maxLength: 200) }) else { return nil }
        var next: [String] = []
        if case .array(let items)? = json["next"] {
            next = Array(items.compactMap { $0.stringValue.flatMap { WireText.clean($0, maxLength: 60) } }.prefix(2))
        }
        return TurnSummary(done: done, session: json["session"]?.stringValue.flatMap { WireText.clean($0, maxLength: 140) }, next: next)
    }

    /// Without the summarizer: the start of Claude's message, or the files it changed.
    public static func fallback(_ report: TurnReport) -> TurnSummary {
        let text = plainText(report.message ?? "")
        if !text.isEmpty { return TurnSummary(done: firstSentences(text, maxLength: 160)) }
        if !report.files.isEmpty { return TurnSummary(done: "Changed \(fileList(report.files)).") }
        return TurnSummary(done: "Claude finished.")
    }

    /// "A.swift, B.swift, C.swift and 2 more".
    public static func fileList(_ files: [String], shown: Int = 3) -> String {
        let named = files.prefix(shown).joined(separator: ", ")
        return files.count > shown ? "\(named) and \(files.count - shown) more" : named
    }

    /// Markdown as plain sentences: code blocks and tables go, links keep their words, list items
    /// and headings become sentences.
    public static func plainText(_ markdown: String) -> String {
        var sentences: [String] = []
        var inFence = false
        for raw in markdown.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence || line.hasPrefix("|") { continue }
            while line.hasPrefix("#") || line.hasPrefix(">") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) { line.removeFirst(marker.count) }
            if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber) {
                line = String(line[line.index(after: dot)...])
            }
            line = inlinePlain(line).trimmingCharacters(in: .whitespaces)
            guard let last = line.last else { continue }
            if !".!?:…".contains(last) { line += "." }
            sentences.append(line)
        }
        return sentences.joined(separator: " ")
    }

    static func inlinePlain(_ text: String) -> String {
        var line = text
        // [words](link) → words
        while let open = line.range(of: "["), let middle = line.range(of: "](", range: open.upperBound..<line.endIndex),
              let close = line.range(of: ")", range: middle.upperBound..<line.endIndex) {
            line.replaceSubrange(open.lowerBound..<close.upperBound, with: String(line[open.upperBound..<middle.lowerBound]))
        }
        for marker in ["**", "__", "~~", "`", "*"] { line = line.replacingOccurrences(of: marker, with: "") }
        return line
    }

    /// Whole sentences while they fit in `maxLength`, or the first one clipped.
    public static func firstSentences(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        var kept = ""
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next == text.endIndex || text[next] == " " {
                let candidate = kept + text[start..<next]
                guard candidate.trimmingCharacters(in: .whitespaces).count <= maxLength else { break }
                kept = candidate
                start = next
            }
            index = next
        }
        let trimmed = kept.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(text.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…" : trimmed
    }
}

/// A Claude session as Mochi Pocket lists it, with Claude's summary of its last turn.
public struct PhoneSessionCard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var project: String
    /// working · waiting · done · error · idle
    public var phase: String
    public var summary: TurnSummary?
    public var files: [String]
    /// When Claude finished the summarized turn (Unix time).
    public var finishedAt: Double?
    /// When the current phase began, so a newer finish from a notification can be told from an older one.
    public var phaseSince: Double?

    public init(id: String, project: String, phase: String, summary: TurnSummary? = nil, files: [String] = [],
                finishedAt: Double? = nil, phaseSince: Double? = nil) {
        self.id = id
        self.project = project
        self.phase = phase
        self.summary = summary
        self.files = files
        self.finishedAt = finishedAt
        self.phaseSince = phaseSince
    }

    /// This card with a finished turn that arrived some other way (a notification) folded in, when it's newer.
    public func merging(_ pushed: PhoneSessionCard) -> PhoneSessionCard {
        guard let finished = pushed.finishedAt, finished > (finishedAt ?? 0) else { return self }
        var card = self
        card.summary = pushed.summary
        card.files = pushed.files
        card.finishedAt = finished
        if finished >= (phaseSince ?? 0) {
            card.phase = pushed.phase
            card.phaseSince = finished
        }
        return card
    }

    /// The card a turn-finished notification carries.
    public static func decode(notification info: [AnyHashable: Any]) -> PhoneSessionCard? {
        guard let card = info["card"], JSONSerialization.isValidJSONObject(card),
              let data = try? JSONSerialization.data(withJSONObject: card) else { return nil }
        return try? JSONDecoder().decode(PhoneSessionCard.self, from: data)
    }
}

/// The `sessions` value on Mochi Link: whether the Mac shares summaries, and its sessions if so.
public struct PhoneSessions: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var sessions: [PhoneSessionCard]
    /// When the Mac wrote it, so the phone can tell it from newer news in a notification.
    public var updatedAt: Double?

    public init(enabled: Bool, sessions: [PhoneSessionCard] = [], updatedAt: Double? = nil) {
        self.enabled = enabled
        self.sessions = sessions
        self.updatedAt = updatedAt
    }

    public var json: String { JSONEncoder.stableString(self) }
    public static func decode(_ json: String) -> PhoneSessions? { try? JSONDecoder().decode(PhoneSessions.self, from: Data(json.utf8)) }
}
